# Session Monitor

A local workspace for understanding your AI chats. Explore token statistics, search recorded conversation text, inspect chat relationships, and query the data with SQL.

The workspace opens in a full-window **Project atlas**. Drag project/model networks, switch to chord diagrams, or open **Conversation lab** to explore the length and shape of your conversations. One tab strip at the top switches between every view (keys **1**–**8**; the address bar and browser history follow the view). Shared filters stay above every view. **Filters** collapses them to a one-line selection summary to give the graphics more room.

The main interface is now a web analytics workspace. It runs with Python 3.11 or later and the standard library. No Swift build, Node install, hosted service, or model inference is required. The existing [Swift client](docs/NATIVE_APP.md), provider adapters, and harness reporting contract remain available.

## Run the analytics workspace

From the repository root, run:

```sh
python3 -m analytics.server
```

Open **http://127.0.0.1:8765**. Stop the server with **Ctrl+C**.

The workspace discovers local T3 Code, Codex, Claude Code, Hermes, and harness reports. **Connections** shows each source's path, availability, loaded record count, and coverage. The default limit is 500 recent chats per source, or per Hermes profile. Refresh sources to reread the files.

To change a source folder, port, or record limit:

```sh
python3 -m analytics.server --port 8766 --limit 1000 \
  --t3-home ~/.t3 --codex-home ~/.codex --claude-home ~/.claude
```

The other path flags are `--hermes-home` and `--harness-home`. Defaults honor `T3CODE_HOME`, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `HERMES_HOME`, and `SESSIONMONITOR_HARNESS_DIR`.

## Explore your chats

- The shared header selects project, activity dates, model, provider or instance, harness or connection, search text, and subagents. The selection stays in place across every tab. **All connections** compares your conversations across harnesses.
- **Project atlas** maps observed project-to-model or project-to-harness connections. Drag and zoom the network, switch to chord diagrams, and change the measure between conversations, messages, and recorded tokens. Select a node or ribbon to inspect the project paths, message counts, models, and underlying chats. Use the inspector's project action to apply a shared filter.
- **Conversation lab** answers average conversation length, messages you send per chat, and average prompt and response lengths. Brush distributions, select prompt/response bubbles, and compare projects, models, or harnesses. Lengths are visible-text message counts and characters. They do not measure response latency or active work time.
- **Overview** shows recorded lifetime tokens, conversation counts, model usage, counter coverage, and dated consumption.
- **Conversations** supports search across titles, projects, models, and loaded message text. Sort by usage, recency, or title. Open a chat to inspect token counters, sampled messages, recurring terms in your messages, and explicit relationships.
- **Explorer** uses D3 for a model-by-harness matrix, a zoomable conversation map, and a recorded-activity calendar. Switch between tokens and conversation or event counts. Select marks to inspect the chats behind them.
- **Constellation** uses Three.js to arrange conversations in project, model, or harness groups. Orbit, zoom, follow recorded links, and click a chat to read it. Size represents recorded lifetime tokens on a logarithmic scale. Position does not imply semantic similarity. A keyboard-accessible conversation list is available, including when WebGL is unavailable.
- **Query studio** provides read-only SQLite queries over `chats`, `conversation_stats`, `messages`, `usage_events`, `relationships`, and `connections`. Examples cover project statistics, model connections, daily consumption, message length, text search, and lineage. Queries use the shared header's selection and refresh when you change that selection after running a query.
- **Export table** downloads the selected conversations or current query results as CSV.

Project names come from recorded T3 metadata where available. Git common-directory identities connect verified worktrees across sources. Unrelated folders are not merged just because their names match. Missing project metadata remains **Unknown project**.

Conversation measurements are separate from the reader's bounded text sample. T3 and Hermes use all available local visible messages for the selected chats. Codex and Claude measure the complete parsed portion of each transcript, bounded at 32 MiB and labelled partial when needed. Missing Codex transcripts and latest-message-only reports have unknown conversation statistics. Averages use measured chats and message-weighted character totals; unknown records do not become zero.

Analysis uses recorded metadata and local statistics. There is no semantic topic classifier, quality score, or model-generated analysis.

## Understand the counters

Lifetime counters remain on the chat record. Daily charts use recorded consumption events with known timestamps. The workspace never assigns a chat's lifetime total to its last-active day. The activity filter selects chats by last activity; their lifetime counters can span an earlier period.

T3 and Claude supply dated usage events. Codex and Hermes currently supply lifetime counters. Missing values remain unknown. Zero means a recorded zero. T3 context-window snapshots are excluded from consumption. Cache and reasoning retain their provider semantics.

The same conversation can appear in T3, a native provider, and an imported snapshot. **Group exact copies** groups recorded T3/provider identities and snapshots whose original IDs match a loaded record. It prefers measured T3 counters, then measured native records, rather than adding both. Turn grouping off to inspect all source records. Unknown identity matches and forked histories can still overlap. Counter presence includes partial records and does not prove complete coverage. Tokens are not billing amounts.

See the [analytics data reference](docs/ANALYTICS.md) for source limits, field semantics, and query examples.

## Reuse the existing wiring

The original harness reporter works with the new workspace:

```sh
python3 script/report_session.py --id example --namespace evaluations \
  --title 'Evaluation run' --state ended \
  --input-tokens 1200 --output-tokens 300 --total-tokens 1500 \
  --last-message 'Evaluation completed'
```

An existing native build can also export a snapshot for inspection as a separate connection:

```sh
.build/debug/SessionMonitor --snapshot > /tmp/sessionmonitor-snapshot.json
python3 -m analytics.server --snapshot /tmp/sessionmonitor-snapshot.json
```

The analytics workspace reads provider databases in read-only transactions. It keeps its projection in memory and binds to loopback. It loads bounded user and assistant text locally, excludes tool output and hidden reasoning, and makes no external requests. CSV exports and snapshot files contain private chat data when you create them.

## Verify analytics changes

```sh
python3 -m unittest discover -s analytics/tests -v
node --check analytics/web/app.js
```

Optional browser checks use Playwright, installed separately from the app runtime:

```sh
node analytics/tests/browser.cjs
```

The browser script starts isolated synthetic sources and checks combined identities, global filtering, scoped SQL, D3 and Three.js views, messages, search, CSV export, refresh, mobile overflow, and content security policy. Set `PLAYWRIGHT_MODULE` to an installed Playwright module path if it is not on Node's module search path.

D3 and Three.js are vendored locally. There are no runtime CDN requests or package installs. See [visualization dependency notices](DEPENDENCIES.md#analytics-visualizations).

For the retained native app, see [native setup and verification](docs/NATIVE_APP.md).
