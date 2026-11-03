# Session Monitor

A small native macOS app that lists local Codex, Claude Code, Hermes, T3 Code, and instrumented harness sessions. SwiftUI, Swift Charts, Foundation, the system SQLite library, and Swift Markdown 0.9.0 (pinned with its cmark-gfm dependency). No hosted monitor service or model inference calls. Dependency licenses and notices are included in the app bundle.

Requires macOS 14+ to run and Swift 6.2+ to build its pinned dependencies. Build with Xcode 27 (the toolchain validated for this version). The generated app runs without a Swift toolchain.

## Version 0.5.0

Richer recorded worker information: Codex cumulative thread/turn usage and startup lineage, Claude subagent roles/task descriptions, Hermes lifecycle/activity/cost provenance, clearer coverage and missing-data labels, bounded on-demand deeper transcript reads, visible worker counters, and exact related-chat loading. Optional CLI paths now support Settings, environment overrides and PATH; user-invoked resumes preserve each provider home/profile.

Start with [repeatable setup](docs/SETUP.md), the [provider-by-provider audit and limitations](docs/PROVIDER_SUPPORT.md), and [dependency licenses](DEPENDENCIES.md). Automated tests include synthetic provider fixtures and special-file read safeguards. The project license is pending owner selection.

## Build and open

```sh
./script/build_and_run.sh
```

This creates `dist/SessionMonitor.app`, signs it locally, and opens it. The script explicitly selects the installed SDK and checks the executable’s linked SDK version. It currently uses SwiftPM’s native backend because the default Swift Build backend stamps the deployment target as the SDK version on this toolchain; native-backend deprecation warnings are expected until that toolchain issue is resolved. You can subsequently open that bundle in Finder. The Codex Run action invokes the same script. `--build-only` builds without launching; `--verify` also checks that the process launched. `--debug` and `--logs` support local diagnosis. This development bundle is not notarized for distribution.

The main window is a native three-pane workspace: a sidebar for attention, saved sessions, projects and applications; a selectable conversation list; and a reading area. Application and project identity appear in each row and above the selected conversation. Projects with the same folder name share one sidebar entry and a combined chat count across workspace paths and providers. Selecting that entry shows their chats together; hover to see the individual paths, and use Context to inspect a chat's exact location. This is a display grouping, not a claim that the folders are the same repository. The list keeps the existing attention/state priority and activity ordering; changing scope/search selects a visible result, while refresh preserves an existing visible selection.

**Latest** shows the last bounded user/assistant message with GitHub-flavored Markdown tables, nested lists, task lists, block quotes, headings, links and fenced code, plus its timestamp and coverage. Wide tables and code scroll horizontally. HTML is shown as text; remote images appear as links and are never fetched automatically. **Notes** opens a large autosaving local notepad (**⌘⇧N**). **Context** contains recorded application/model/provider/origin, activity and completion times, message coverage, workspace, current/recorded branch, worktree and related-session navigation. The **Usage** button in the session header opens a popover retaining provider counter semantics and coverage; Usage no longer occupies a content tab. The larger segmented control uses the system accent selection. Modern Macs use native glass action buttons, capsule search and grouped toolbar controls, with spacious sidebar rows. The **Session info** toolbar button (**⌘⌥I**) opens a popover for state evidence, local overrides, model, origin and source identifiers. It leaves navigation, list and reader widths unchanged. **⌘L** returns to Latest. Search includes notes. The list header owns the date range; Bookmarks always includes all dates. Overall usage and Sources & setup are in the sidebar and Workspace options menu. Use Settings (**⌘,**) for data folders, refresh frequency and record limits; refresh manually with **⌘R**.

Single-click or use arrow keys to select and read. Double-click a row, press **⌘O**, or choose the primary session action to open it. Codex opens its native thread link; Claude desktop opens its registered `local_` session identity using the installed desktop route. Other Claude/Hermes sessions offer **Resume in Terminal**, which starts a new CLI process; Hermes commands preserve the source profile. Copying the resume command is also available. The monitor never resumes an agent automatically. Closing the window leaves monitoring running in the menu bar; Quit stops it.

### Design references

The layout adapts [Intercom’s inbox on Mobbin](https://mobbin.com/screens/6651eeee-af04-4b98-a423-cd75800b43f1): keep navigation, conversation selection and reading adjacent, with source details secondary. The [Slite document-insights screen](https://mobbin.com/screens/30128a6f-dc52-4591-b361-30e29be9294c) informed separating activity/metadata from the main content. Both desktop web screens were inspected visually in the browser; these are structural references, not native Mac component specifications.

[Apple’s current Layout HIG](https://developer.apple.com/design/human-interface-guidelines/layout) informs reading order, progressive disclosure, adaptable panes and separation of controls from content. [Apple’s macOS 27 UI kit](https://www.figma.com/community/file/1651309434229735362/macos-27), linked from [Apple Design Resources](https://developer.apple.com/design/resources/), was verified on its public resource page and cover preview (updated July 24, 2026); the full component library was not imported. Native SwiftUI split views, sidebar selection, toolbar, segmented controls and popovers use the system’s appearance. macOS 14 remains the minimum. Version 0.3.1 corrects the linked SDK metadata (27.0, separately from the macOS 14 minimum), adopts native glass actions, larger capsule segmented controls and sidebar rows, and uses one stable app title with grouped toolbar actions. The supplied macOS 27 control screenshots guided the sizes and shapes. A resize-triggered SwiftUI constraint cycle was removed by giving the reader a stable minimum width and simplifying its header layout. The repeat native quarter-window resize passed at 1460 × 820 points. Latest, project filtering, Notes, Usage and the source inspector have been exercised on macOS 27.0.1. Version 0.4.0 adds GFM rendering, header Usage and non-resizing Session info popovers, expanded recorded context and related-agent details, filtered one-completion review, and native Codex archiving. The 0.4.0 baseline had 48 passing tests. A real isolated Codex fixture was archived through the installed app-server without a model turn. Native accessibility checks confirm parsed tables, three content tabs, the info popover and unchanged split-column widths; the Markdown table was inspected visually before its final width expansion. Final table sizing, Usage/Context visuals, dark mode and older macOS versions remain visually unverified because native automation disconnected. The app remains running and its signature and SDK metadata verify.


## Coverage and state accuracy

| Application | Discovery | State evidence |
| --- | --- | --- |
| Codex | Latest `~/.codex/state_*.sqlite`, non-archived threads | Bounded JSONL event tails. Activity is **Estimated**; completed turns are **Last recorded**. No runtime control connection is made. |
| Claude Code | `~/.claude/sessions/*.json`, project indexes and top-level/recent subagent JSONL files | Runtime registry status is **Reported** when its PID and recorded start time match the process inventory. Includes Code sessions started from Claude desktop where these files exist. Transcript-only states are historical/unverified. |
| Hermes | `~/.hermes/state.db` and named-profile databases | Recorded end times, last-message metadata, unexpired conversation turn leases, and optional active-session registry. Turn leases are ownership estimates, not proof of active computation. |
| T3 Code | `~/.t3/userdata/statev2.sqlite` | V2 chat titles, project/worktree, model selection, run states, pending approvals/input, explicit lineage and latest local user/assistant message. Active states require the recorded server PID/start time to match a local process. |
| Your harness | Local JSON snapshot directory | Explicit state reports with expiry. Requires integrating the included reporter. |

**Reported** means the application or harness reported the state; it is not an independent guarantee of useful progress. **Last recorded** is stored history, not evidence that a session is still open. **Unknown** means there is insufficient current evidence. A finished response becomes **Response ready**, indicating a response available for review, not overall task completion. **Mark reviewed** acknowledges that one response locally and displays it as idle; a later completion becomes ready again. Review acknowledgements persist in the monitor's preferences and never alter provider data. **Waiting for answer** requires a structured unresolved question or a runtime report; question-like prose is not sufficient. **Approval needed** requires an explicit approval signal. Recorded unresolved questions remain estimates until a matching result or a subsequent lifecycle event is observed. Bounded tails may omit the request/resolution; the scanner does not have a live control connection. Codex activity estimates expire after ten minutes without timestamped events. Harness reports expire after 180 seconds by default unless completed/terminal (`response_ready`, `ended` or `error`). Unknown application statuses are not treated as running.

Defaults: refresh every five seconds, load up to 200 recent records per source/profile, plus up to 200 Claude subagent transcripts linked to loaded parents, and show the last seven days plus registered open Claude/Hermes sessions. “Today” means the last 24 hours; “All loaded” still respects the record limit. Increase the limit in Settings to inspect more history. Old open sessions can consume a history slot; the app does not claim to enumerate every active session beyond these source limits.

Data paths and optional CLI executable overrides can be changed in Settings. On first launch the defaults honor `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `HERMES_HOME`, and `SESSIONMONITOR_HARNESS_DIR` when inherited. Database schemas and runtime registries are implementation details and may change with provider updates; Sources & setup reports adapter failures.

All provider databases are opened read-only with a short busy timeout. Scanning never launches, resumes, interrupts, changes other agents, takes writer locks, alters their configuration, or reads authentication files. Opening/resuming and native archive requests occur only on an explicit user action. A user-invoked Codex archive starts its app-server interface, which loads its own provider configuration and may use its normal authentication/startup behavior; Session Monitor does not handle those credentials. It sends no model turn. It reads bounded startup metadata and transcript tails to extract lifecycle/model/title/usage metadata and structured pending-question text. It displays that extracted question text in details, not complete transcripts, tool output, or hidden reasoning. Last-message previews are limited to 8,000 characters and labelled when truncated or drawn from bounded tails. Extracted metadata stays in memory, apart from local review acknowledgements and saved session snapshots attached to annotations. Bookmarks/notes may retain an 8,000-character last-message preview locally. Temporary private `.command` files are created for user-invoked Terminal resumes and remove themselves when executed. Session titles/paths are local private metadata.

This version does not discover ordinary ChatGPT/Claude web conversations, remote machines, or remote-only subagents. Your harness is a separate application identity regardless of its model provider. The monitor's own session can appear in the Codex list while you build it.

## T3 Code chats

**T3 Code** appears under Applications and in the combined list. Its home defaults to `~/.t3`, honors `T3CODE_HOME` on first launch, and can be changed in Settings. Either the home folder or its `userdata` folder is accepted. The adapter reads only the V2 database; it never falls back to the old `state.sqlite` left by migration, since the two histories can diverge. [T3's migration documentation](https://github.com/pingdotgg/t3code/blob/main/docs/user/thread-migration.md) explains that separation.

The chat's T3 title, model, workspace/branch, latest local message, run outcome and relationships appear in the normal reader and Context. Completed runs appear as Response ready; settled completions are idle. A queued follow-up does not hide an already running turn. Structured pending input and approvals have distinct states. If the recorded local server process cannot be verified, active or pending records become Unknown. A running server is evidence of T3's reported state, not independent verification of useful provider work. Archived and deleted T3 chats are excluded.

Open session uses the installed desktop route `t3code://threads/<environment-id>/<thread-id>` on an explicit action; without a valid environment ID it offers to open the T3 app. It never resumes an underlying provider CLI. T3 archiving and sending are not connected.

When a strong native-thread identity matches a loaded Codex or Claude record and has exactly one T3 owner, the combined list shows the T3 chat once. Context links the provider record, which retains its own counters, annotations and preview. Provider application filters also retain those native records. Ambiguous or missing mappings are kept separate. Only the selected local T3 environment is scanned; remote environments and legacy V1-only installs are not supported.

T3 session Usage and the Overall usage card sum persisted `turnTokenUsage` consumption across root provider turns, including provider switches. T3 normalizes input to include both cache reads and cache writes, and output to include reasoning. The charts subtract those subsets before stacking. Active turns, imported history and worker usage may be missing, so the counters carry coverage and partial labels. Context-window occupancy (`tokenUsage` or `contextUsage`) is never added to consumption.

The overall T3 card is a **hosting view** of recorded main-chat turns, including archived chats; separate subagent chats and provider worker turns are excluded. It overlaps the existing native-provider archive totals, which retain their original scope. Do not add those overall bars together. In the seven-day loaded-session chart, a measured T3 host replaces its exact matched native records; if T3 consumption is missing, native counters remain available as a fallback. Unknown or ambiguous identity mappings may still overlap. Forks and imported histories can have incomplete local message or usage coverage.

## Bookmarks, notes and your status

Click the star beside any session, use the reading area's Bookmark button, or press **⌘D**. **Bookmarks** in the sidebar (also **⌘⇧B**) shows marked sessions across all dates and applications. Search includes your notes, and each bookmarked row shows a note preview. Older bookmarks remain available when a session falls outside the load limit or its source is missing; their saved metadata/message is clearly labelled historical and current state is unknown.

The Notes view has an autosaving editor. Adding your first note bookmarks the session. Removing a bookmark preserves its notes. Notes are a free-form per-session notepad supporting multiple paragraphs.

**Local status** in Session info and the row's **Set local status** menu let you choose Idle, Done, or another state. Overrides persist until **Follow source** is selected. The source state remains visible underneath, including a new Running/Approval state, and provider files are unchanged. **Mark responses reviewed** in the Response ready list and Workspace options menu acknowledges the current filtered list, after a count confirmation. It uses one-completion acknowledgements rather than persistent status overrides. Running, hidden and subagent rows outside the view are excluded, as are responses without a completion timestamp. A response arriving while the confirmation is open remains unreviewed.

Annotations and saved session snapshots live in `~/Library/Application Support/SessionMonitor/library.json`, with a private directory and file permissions. Writes are atomic and debounced; pending edits are flushed on normal app termination. Failed saves are displayed. An unreadable library is preserved and editing disabled rather than overwritten.

## Last messages, worktrees and related agents

Latest and the separate-message action show the last available user/assistant conversation message, with role, timestamp and coverage. Previews exclude tool results and hidden reasoning. Codex/Claude read bounded transcript tails; Hermes reads the last stored conversation message; harnesses can report `last_message`. A saved bookmark may show an older saved preview, explicitly labelled.

**Open session** uses the native routes described above. **Open [application] app** opens the relevant installed app without resuming a CLI session. Claude subagents open/resume their parent session; they are never treated as standalone resumable CLI IDs.

Worktrees are identified from `.git` / `commondir` metadata, not directory-name heuristics. The **Worktrees** sidebar view shows linked worktrees, with current branch/repository context in details. Metadata is cached for one minute. A `.git` file for a submodule alone does not establish a linked worktree. Recorded session branches are distinguished from current checkout branches.

The main list excludes subagents by default. Parent rows show recorded subagent counts, and **Subagents** lists recent loaded children. **Related sessions** links parents and children in Context. Codex uses explicit spawn edges; Claude uses its parent-scoped subagent transcript layout. Hermes compression continuations are labelled Continued from/as rather than subagents. For Codex/Hermes, related records outside the history limit can be loaded individually and refreshed through temporary inspection pins (up to 32). Archived/deleted records can still be unavailable. Claude relationships use loaded parent-scoped transcripts; increase the record limit when needed. Counts are recorded relationships, not proof that all children are running. Context separates recorded agents from loaded agents, with current loaded-state counts, role/model, last excerpt, relative activity and recorded token counters. Full prompts, loaded files and live context-window occupancy are not inferred from cumulative token totals.

## Archive and follow-up controls

**Archive in Codex…** is available in a chat's header actions and row menu. It requires the Codex CLI, a valid local thread ID under the configured Codex home, and a known inactive main chat. After confirmation, the monitor refreshes the source and invokes the supported `thread/archive` app-server method. The request targets the selected parent thread; Codex may also archive its spawned descendants, as stated in the confirmation. No direct database edits, bulk provider archive filters or automatic retries are used. Rejections are shown; missing acknowledgements are reported as an unknown outcome and require checking Codex before retrying. Restore archived chats in Codex. Saved annotations/bookmarks remain available; archived saved records are excluded from the main list and labelled in Bookmarks. An external restore seen by the scanner clears the saved archive marker.

Claude archiving is not connected. The installed Hermes CLI has bulk archive filters but no exact session-ID archive option; its gateway does expose `session.archive`, but a provider gateway connection is not yet wired into this app. Those archive actions are disabled with an explanation. No existing chats were archived or reviewed during development.

Follow-up sending/queuing is not implemented in this release. Read-only inspection of the installed Codex protocol confirms experimental `thread/queue/add`, `list`, `update`, `delete`, `reorder` and `start` methods; `turn/steer` requires the active turn ID, and `turn/start` can steer an active turn rather than queue a later one. A queue integration must connect to the app-server that owns the running session and retain provider item IDs, acknowledgements and an unknown-outcome state across interruptions. Hermes has gateway prompt submission/queue and steering support, also requiring a connection to its owning runtime. Claude Agent SDK streaming input is for SDK-managed sessions; arbitrary existing desktop-session attachment remains unverified. Local editable drafts, native queue delivery and immediate steering should be distinct actions.

References: [Codex app-server source](https://github.com/openai/codex/tree/main/codex-rs/app-server), [Hermes session contracts](https://github.com/NousResearch/hermes-agent/blob/main/tui_gateway/contracts/sessions.py), [Claude streaming input](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode). Installed Codex CLI-generated stable and experimental JSON schemas and installed Hermes source were inspected on 8 October 2026; API presence alone does not establish live cross-app delivery.

## Usage

Use Overall usage in the sidebar or **File → Overall usage** for local archive aggregates, independent of the list's date range/load limit:

Native Swift Charts show stacked token breakdowns above the existing counter grids in session usage, last-turn details and overall app cards. Segment colours stay consistent: input blue, output green, cache read teal, cache write orange, reasoning purple, and a total without a recorded breakdown grey. Codex charts subtract cached input and reasoning from their parent counters; Claude and Hermes retain their separate cache/reasoning counters. Partial records are labelled, and hovering the bar or legend shows formatted counters.

The **By app** chart compares recorded archive counters with a logarithmic axis that supports zero, abbreviated ticks and value labels so smaller apps remain visible. Segment widths on this axis are not proportional. Its scopes differ by provider; it does not imply comparable billing or complete coverage. **Last 7 days (loaded sessions)** excludes subagents and sums each session's `displayCount` on the calendar day of its last activity. Approximate: each session's cumulative total is counted on its last-activity day; only sessions in the current load window are included. It is not a daily consumption history.

- **Codex:** `threads.tokens_used` across the local index, including archived threads. Per-session event counters supply input/output/cache/reasoning when present in the bounded tail, including newer `token_usage_record.thread_token_usage`. Last-turn cumulative usage is displayed separately. Cache input and reasoning are subsets and are not added twice. Forks/shared histories may overlap in archive sums.
- **Claude Code:** overall statistics come from `stats-cache.json` and display `lastComputedDate` prominently. This cache can be old. Per-session usage is deduplicated by message ID in the available 128 KiB tail and explicitly labelled partial for truncated files. **Load deeper counters** reads up to 8 MiB on demand and remains partial for larger files. Claude's separately recorded cache tokens are included in its total. A zero cached cost is not a subscription bill.
- **Hermes:** root/profile session counters, separately stored cache/reasoning, and explicitly labelled estimated/actual costs where recorded. The displayed token count is input + output, excluding separate cache fields. Aggregate cost counters can cover different record subsets; coverage is displayed.
- **T3 Code:** recorded normalized main-agent turn consumption in the local V2 archive, with cache read/write included in input and reasoning included in output. The T3 hosting view overlaps native provider archive totals; its card labels that overlap. Per-chat usage follows loaded chats, while the overall card includes archived main chats and excludes separate subagent chats. Active, imported and worker usage can be absent. Exact matched native records are omitted from the seven-day chart when their T3 host has consumption counters.
- **Harness:** optional reported `usage` counters (input/output/cache/total/actual cost) in each JSON snapshot. Your harness defines their semantics.

There is deliberately no combined cross-provider total: scopes and cache semantics differ. Codex allowance windows are the latest locally recorded snapshots per limit ID, with recording/reset times. Expired windows show current allowance as unknown. No account requests are made. Archive aggregates refresh at most once a minute; per-session metadata follows the normal refresh interval.

## Connect a harness

```sh
python3 script/report_session.py --id run-123 --namespace evaluations \
  --title 'Evaluation run' --state running --provider 'OpenAI + Anthropic' \
  --model 'Your configured models' --cwd /absolute/path/to/project

# Send every ~60 seconds while work continues:
python3 script/report_session.py --id run-123 --namespace evaluations --heartbeat

# When the run finishes:
python3 script/report_session.py --id run-123 --namespace evaluations --state ended
```

Reports default to `~/Library/Application Support/SessionMonitor/events`. If you change the app's Harness reports folder, supply the same `--directory` to the reporter. Accepted states: `running`, `needs_attention`, `waiting_for_answer`, `approval_needed`, `response_ready`, `idle`, `ended`, `error`, `unknown`. Provider and model are descriptive strings; one harness run may use multiple providers without creating duplicate sessions.

To report a completed response that needs review, use `--state response_ready`. The reporter includes a stable `completed_at` value across heartbeats. Use `--question 'Your question' --state waiting_for_answer` for a blocking question, and `--input-tokens`, `--output-tokens`, `--total-tokens` for usage. Use `--last-message 'Your final response'` to publish a preview; its recorded timestamp survives heartbeats. Python callers can pass a `usage` dictionary for additional counters.

Python harnesses may import `report_session` from `script/report_session.py` and call it directly. Re-reporting updates one namespaced session atomically. Use `try/finally` to send a terminal state and a periodic heartbeat while executing. No harness integration or Claude/Codex hook is installed automatically.

## Verify

```sh
swift test
./script/build_and_run.sh --verify
```

For read-only setup diagnostics without conversation bodies/titles (configured paths are still private):

```sh
.build/debug/SessionMonitor --diagnostics
```

For session metadata and previews without a GUI:

```sh
.build/debug/SessionMonitor --snapshot > /tmp/sessionmonitor-snapshot.json
```

`--usage` prints archive usage as JSON instead.

This prints session metadata as JSON and source diagnostics on stderr. The output contains private local session names, IDs, and paths; store it locally.

## Application routes

Codex thread links follow the [official command/deep-link reference](https://learn.chatgpt.com/docs/reference/commands). The existing Claude Code desktop `code/continue` route and its `local_` ID validation were verified against the installed Claude desktop code; this route is an implementation detail that could change. Hermes offers an explicit profile-preserving CLI resume because its generic desktop route does not establish the correct profile.
