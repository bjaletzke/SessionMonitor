# Repeatable local setup

1. Install Xcode with the macOS SDK and select it with `xcode-select`. Swift 6.2+ is required by Swift Markdown 0.9.0; the validated build environment is Xcode 27 / Swift 6.4 / macOS SDK 27. The application deployment minimum is macOS 14. Other toolchains and older macOS runtime behavior require separate verification.
2. Clone/copy the source, including `Package.swift`, `Package.resolved`, `Sources`, `Tests`, `script` and `DEPENDENCIES.md`. From the repository root run `swift package resolve` (network needed once), then `swift test`.
3. Run `./script/build_and_run.sh --verify`. It builds, packages and locally signs `dist/SessionMonitor.app`, checks its linked SDK, launches it and confirms a process exists. `--build-only` packages without stopping/launching the app. The native SwiftPM backend is deliberate for SDK metadata on the validated toolchain; a native-backend deprecation warning is expected. No private app bundle or developer-specific toolchain path is used.
4. Install and run whichever providers you want to inspect. None is mandatory. Choose **Sources & setup** for current coverage/failures and **Settings** (`⌘,`) for data and CLI paths. Missing providers are shown as unavailable and do not block others. Saved history can be inspected without installing a CLI. Native open/resume/archive actions require the corresponding app/CLI.

## Data folders

| Source | Default | Environment override |
| --- | --- | --- |
| Codex | `~/.codex` | `CODEX_HOME` |
| Claude Code | `~/.claude` | `CLAUDE_CONFIG_DIR` |
| Hermes | `~/.hermes` | `HERMES_HOME` |
| Harness reports | `~/Library/Application Support/SessionMonitor/events` | `SESSIONMONITOR_HARNESS_DIR` |

On first launch, inherited environment values override standard defaults. Empty environment values use defaults. Values saved in Settings take precedence on later launches. Absolute paths and `~/` are supported. GUI apps opened from Finder often do not inherit shell variables: set paths in Settings when needed. Command-line snapshot/diagnostic modes use environment/defaults, independent of GUI preferences. For example:

```sh
CODEX_HOME=/absolute/path/to/codex-home .build/debug/SessionMonitor --diagnostics
```

Hermes scans the selected home and `profiles/*/state.db` immediately beneath it. Pointing at a named profile reads that profile; it does not imply discovery of sibling profiles. Profile IDs stay separate. No auth files are needed. Runtime registries are optional/version-dependent and do not create a live runtime connection.

## Executables and native apps

For each CLI, discovery uses the optional Settings executable path, then `SESSIONMONITOR_CODEX_EXECUTABLE`, `SESSIONMONITOR_CLAUDE_EXECUTABLE` or `SESSIONMONITOR_HERMES_EXECUTABLE`, then absolute directories in inherited `PATH` and standard user/Homebrew/local directories. Overrides are single absolute executable paths (or `~/...`), not shell commands. An invalid explicit override fails rather than selecting another CLI. Use Settings for version-manager or custom installs that are absent from GUI `PATH`.

No CLI is launched for scanning. User-invoked resume commands preserve configured Codex/Claude homes and Hermes profiles and quote executable/home/workspace/session arguments. Native apps are found through Launch Services, not hard-coded `/Applications` or private resource paths. Codex thread deep links are documented; Claude's optional desktop route and Hermes app identity are version-dependent. See [provider support](PROVIDER_SUPPORT.md).

## Diagnose and verify

```sh
swift test
./script/build_and_run.sh --build-only
.build/debug/SessionMonitor --diagnostics
./script/build_and_run.sh --verify
```

`--diagnostics` prints source health, counts and configured paths without conversation bodies or titles. It still contains private filesystem paths. `--snapshot` prints private session metadata/previews and `--usage` prints local archive aggregates; keep their output private. The fixture tests build without installed provider apps or authenticated accounts. Dependencies resolve from their pinned public SwiftPM repositories.

The app does not change provider records while scanning. Explicit Codex archive and CLI resume are separate user actions. Follow-up sending/queuing is not implemented. Distribution requires the owner's project-license choice and separate release/signing work; see [dependency inventory](../DEPENDENCIES.md). No repository is published by these steps.
