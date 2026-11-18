# Analytics data reference

`analytics/data.py` reads local sources into an in-memory SQLite projection. `analytics/selection.py` defines the shared selection and exact-identity grouping. `analytics/server.py` serves the selected projection and static web interface. Source failures roll back that connection's imported records and appear under **Connections**. Other connections remain available. Refresh replaces the projection and rereads all configured sources.

## Shared selection

Project, activity dates, model, provider or instance, connection, text search, and subagent filters apply across every tab. **All connections** selects across sources. Connections cards show selected and loaded counts separately. Model and provider filters use recorded values without guessing equivalence between provider instance names.

**Group exact copies** groups explicit, unambiguous T3/provider identity links and snapshot IDs that exactly match a loaded record. Grouping prefers records with counters, then direct sources over snapshots, then T3 over native provider records. A measured native record remains available when its T3 host lacks counters. It does not add two records' counters. Filtering happens before the representative is selected, so a source, model, or provider filter can select a different record from the same identity group.

Grouping does not infer identity from titles, workspace names, text similarity, or fork ancestry. Unknown identity mappings can still overlap. The selection summary reports the number of matching source records suppressed by grouping. Turn grouping off to inspect all matching source records.

The date control selects chats by last activity. Their lifetime counters can span earlier periods. Dated usage events additionally respect the date window. Unknown event timestamps remain queryable with **All loaded history** and do not appear in dated charts.

## Connections

| Connection | Input | Consumption and content |
| --- | --- | --- |
| T3 Code | `userdata/statev2.sqlite`, or `statev2.sqlite` when configured with the userdata folder | V2 chats, explicit lineage, local user and assistant messages, and normalized main-agent provider-turn usage. Includes archived chats and excludes deleted chats. Strong native identities produce provider-session links when unambiguous among loaded chats. |
| Codex | Highest numbered `state_*.sqlite`, with referenced rollout files | Indexed lifetime totals, available cumulative transcript breakdowns, recorded spawn edges, and sampled user and assistant text. Includes archived indexed chats. No daily usage events are inferred. |
| Claude Code | `projects/*/*.jsonl` | Top-level transcripts. Assistant message IDs deduplicate streaming usage counters by maximum recorded field. Event timestamps are the observed message timestamps. Parent-scoped subagent transcripts are outside this reader's scope. |
| Hermes | Root and `profiles/*/state.db` | Stored lifetime counters and up to 200 user and assistant messages per chat. Stored parent IDs appear as relationships; the reader does not classify them as delegation or compression. |
| Harness | JSON reports from `script/report_session.py` | Reported cumulative usage and last-message text. The reporter defines counter semantics. |
| Snapshot | Existing Swift `--snapshot` JSON array | Cumulative usage, latest-message previews, and recorded relationships. Each file is a separate connection and can overlap direct sources. |

The normal chat limit is 500, configurable from 1 to 2,000. Hermes applies this limit per profile. A missing database or unrecognized schema produces an unavailable connection. No fallback to T3's legacy V1 database occurs.

T3 reads at most 20,000 recent user and assistant messages across loaded chats, with text limited to 12,000 characters per message. It reads at most 50,000 main-agent provider-turn records ordered by turn identity. If either limit is reached, the connection reports it. Missing, worker, imported, and inherited consumption can leave incomplete totals. `turnTokenUsage.usageStatus` and `usageScope` determine whether a recorded turn contributes. Context snapshots never contribute.

Claude and Codex read the first 32 MiB of each regular transcript file and retain at most 200 text messages from the sampled portion. Larger transcripts are labelled partial. Codex retains its index total when the transcript sample is partial. Claude sums deduplicated counters from the sampled portion. The text sample can omit messages even when the token counters are available. T3 and Hermes message text is bounded before leaving the provider database. Device and pipe transcript paths are rejected.

## Tables

The exact schema is in [analytics/schema.sql](../analytics/schema.sql) and the Query studio's schema panel.

| Table | Purpose |
| --- | --- |
| `connections` | Configured path, availability, coverage description, and imported chat count. |
| `chats` | Chat identity, connection, model selection, workspace, dates, lineage, source path, lifetime token counters, and coverage. |
| `conversation_stats` | Full available visible-message counts, character sums, averages, first/last message times, wall-clock span, and coverage, independent of the reader's display sample. |
| `messages` | Sampled user and assistant text, timestamps, and truncation flags. Tools and hidden reasoning are excluded. |
| `usage_events` | Recorded T3 turn consumption or deduplicated Claude message usage. An event with no known timestamp remains queryable but is excluded from the timeline. |
| `relationships` | Directed parent, subagent, fork, provider-session, or imported relationship edges. A target may be outside loaded history. |

Dates are UTC ISO 8601 strings. Unknown dates and counters are SQL `NULL`. A value of zero is retained. `host_chat_id` on a native chat records its exact T3 host identity where available. It does not remove either source record.

## Token semantics

| Source | Lifetime total | Cache and reasoning |
| --- | --- | --- |
| T3 | Sum of available main-agent input and output counters. Partial components remain partial. | Cache read and creation are included in input. Reasoning is included in output. |
| Codex | Recorded index total, replaced by a recorded cumulative transcript total when the bounded read contains the complete file. | Cache read is included in input. Reasoning is included in output. |
| Claude | Sum of available input, output, cache read, and cache creation fields, deduplicated by assistant message ID. | Cache fields are separate. Hidden thinking text is not imported. |
| Hermes | Input plus output when both are known. | Cache and reasoning fields are separate stored counters. The total excludes those separate fields. |
| Harness and snapshot | Explicit reported total, if present. | Original counter semantics remain in the coverage description. |

The timeline compares input and output only. Claude's separate cache consumption is available in tables, chat details, and SQL. **Usage by model** groups chat lifetime counters by the chat's recorded model selection. A chat can have used several models, so this chart does not establish per-turn model attribution.

## Query limits

Queries can select only from the in-memory projection. SQLite authorization rejects writes, schema changes, attachments, and pragmas. A progress handler interrupts long-running queries after approximately two seconds. Queries contain at most 20,000 characters. SQLite limits each value to 1,000,000 bytes.

Results contain at most 500 rows and approximately 4 MiB of encoded row data. Text and blob cells are truncated at 32,000 characters, with a visible marker. Blobs display as hexadecimal. The result panel identifies truncation. CSV export includes the displayed result and neutralizes spreadsheet formula prefixes in text cells.

Query studio applies the same shared selection through temporary views over all six tables. `chats` contains the selected representative records with conversation-statistics columns joined in. `conversation_stats` contains their full available measurements. `messages` contains sampled display text, and `usage_events` contains events in the selected date window. `relationships` remaps grouped endpoints to their selected representatives. `connections` contains the selected connection or all connections. Its `chat_count` field remains the source's loaded count. Direct access to the unfiltered `main` tables is rejected for scoped queries.

Changing header filters clears stale query results and reruns a previously successful query while Query studio is visible. Additional SQL conditions can further restrict the global selection. Keep `connection_id` in grouped output when inspecting source attribution.

For example, this query examines daily T3 consumption for loaded main chats:

```sql
SELECT substr(e.recorded_at, 1, 10) AS day,
       SUM(e.total_tokens) AS recorded_tokens,
       COUNT(*) AS measured_turns
FROM usage_events e
JOIN chats c ON c.id = e.chat_id
WHERE c.connection_id = 't3'
  AND c.is_subagent = 0
  AND e.recorded_at IS NOT NULL
GROUP BY day
ORDER BY day;
```

## Local chat analysis

T3 aggregates message counts and full text lengths directly from all stored local user and assistant records for loaded chats. Streaming and unreadable records mark the statistics partial. Hermes measures all stored visible active user and assistant messages, excluding hidden/inactive records. Neither source's statistics are limited by the display sample.

Codex and Claude measure visible messages across the parsed first 32 MiB of each transcript. Claude assistant IDs combine streaming revisions. Codex pairs mirrored event/response records by stable ID or matching text and nearby timestamp, retaining unmatched older entries. Unresolved mixed histories are marked partial. Character sums use text before display truncation. Hidden reasoning, tool output, system content, and empty text are excluded. Harness and snapshot latest-message previews do not establish conversation length, so their statistics remain unknown.

The average conversation length is total visible messages divided by chats with known counts, including recorded empty chats. Average user messages uses that same denominator. Average prompt and response lengths divide each role's character sum by its message count. These are message-weighted averages rather than averages of chat averages. The median conversation length uses measured per-chat message counts. A median of individual response lengths cannot be recovered from per-chat sums and is not reported. The distribution lens for response lengths explicitly plots each chat's average response size.

`span_seconds` is the wall-clock interval between the first and last recorded visible message timestamps. It is not active work time or response latency. Counts cover the selected chats' available local histories; the activity date filter does not cut those histories into daily message totals. Recurring terms in the detail view remain word counts in sampled user text.

Projects use recorded T3 project titles and roots. `analytics/projects.py` reads Git administrative files to identify the canonical common directory of linked worktrees. Verified identities can connect those worktrees across sources, and recorded T3 titles propagate across that identity. Exact workspace-to-project assignments recorded by T3 also preserve project identity for historical worktree paths that no longer exist, when that assignment is unambiguous. Without those records or Git verification, exact recorded workspace roots or namespaced source project identities are used. Equal folder basenames do not establish identity. Missing workspace metadata remains unknown.

The server binds to `127.0.0.1`. Requests require a localhost or loopback Host header on the server's port and a matching Origin when present. API POST requests require JSON. The static interface uses no external assets. Source databases are opened with `mode=ro` and `query_only`, inside read transactions. The analytical projection exists only in the server process. Stopping it discards imported text and counters. No provider authentication files are read and no provider process is started.

## Interactive visualization views

Project atlas is the initial full-window view. Its network connects projects to models or harnesses actually recorded in their chats. The chord diagram uses those same memberships as symmetric weighted ribbons. Measures are conversation count, recorded message count, or known lifetime token sum. The network displays at most 45 projects and 24 named endpoint groups. The chord displays at most 18 projects and 12 named endpoint groups. Additional endpoints use an explicit Other group; omitted projects are counted in the caption. Inspector actions isolate locally, apply a shared project filter, and open underlying chats. These edges describe membership, not semantic similarity or a directed transfer.

Conversation lab provides a brushable histogram of message counts or per-chat average response size, a prompt-versus-response bubble map colored by project, and message-weighted prompt/response comparisons by project, model, or harness. Comparisons display up to 16 groups with the most responses. Inspector lists display up to 35 selected chats. Its coverage strip reports measured and partial counts. Global filters apply to every lens.

All views share one layout: a top tab strip, the shared filters, and the view. Number keys 1–8 select views in tab order, and the URL hash (for example `#/lab`) records the view, so reload and browser back/forward return to it. On desktop, Project atlas, Conversation lab, and Constellation fill the remaining window; other views scroll within it. The **Filters** control collapses the filter fields to the one-line selection summary; that choice persists across views and reloads in local browser storage. Phones start with filters collapsed. Layout, measure, and grouping choices inside each visualization persist while switching views during a session. Interactive modules clean up their observers, force simulations, and graphics when switching views.

Explorer uses locally vendored D3. Its matrix compares lifetime tokens or chat counts across recorded model selections and hosting applications. The matrix shows the highest-ranked 14 model names and groups the rest under Other models. The conversation map plots last activity against lifetime counters with a symmetric logarithmic scale that supports zero. The activity calendar uses recorded event dates and displays at most the latest 366-day interval in its selection. Its caption identifies the limit. Chat and event counts include unknown token counters; known token sums retain partial coverage.

Constellation lazily loads locally vendored Three.js and OrbitControls. It displays up to 600 selected chats with the largest recorded token counters, grouping by project identity, model, or harness. Node sizes use a clamped logarithmic scale. Edges represent only recorded relationships between displayed endpoints. Position and distance do not infer semantic similarity. The scene renders on interaction, resize, or data change. Leaving the tab or changing the selection disposes its graphics resources. WebGL-unavailable users can use the conversation directory instead.
