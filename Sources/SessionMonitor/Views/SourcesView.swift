import SwiftUI

struct SourcesView: View {
    @Bindable var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Sources & setup").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Reads local metadata. No model calls or hosted backend. Source files are never modified.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(store.snapshot.sources) { source in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Label(source.app.rawValue, systemImage: source.app.symbol).font(.headline)
                                    Spacer()
                                    Text(source.available ? "\(source.count) loaded" : source.count > 0 ? "\(source.count) loaded · partial" : "Unavailable").font(.caption)
                                        .foregroundStyle(source.available ? Color.secondary : Color.orange)
                                }
                                Text(source.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                                if source.app != .harness {
                                    Text(store.preferences.executable(source.app).map { "CLI: " + $0 } ?? "CLI unavailable · reading local history still works; set its path in Settings for actions")
                                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Text(source.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                        }
                    }
                    GroupBox("First run") {
                        Text("Install and run whichever providers you use, then choose their data folders in Settings (⌘,). Missing providers are optional. Saved history can be read without a CLI. Runtime registries and database schemas vary by provider version; no live runtime connection is configured.")
                            .font(.callout).padding(5).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Connect your harness") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Use the included script/report_session.py to publish a session's state. Send a heartbeat during long runs; reports expire after 180 seconds by default.")
                            Text("State files go in the Harness reports folder configured in Settings. The harness adapter is ready; existing harness runs require this integration.")
                                .foregroundStyle(.secondary)
                        }.font(.callout).padding(5).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Loads up to \(store.preferences.sessionLimit) recent records per source/profile, plus registered Claude sessions and recent parent-linked Claude subagent transcripts. “Last recorded” describes stored history. “Estimated” is inferred activity. Plain Claude web chats and remote hosts are outside this version's coverage.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(24).frame(width: 630, height: 680)
    }
}
