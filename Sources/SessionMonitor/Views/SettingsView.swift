import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: MonitorPreferences
    let store: SessionStore
    var body: some View {
        Form {
            Section("Data folders") {
                TextField("Codex home", text: $preferences.codexHome)
                TextField("Claude Code home", text: $preferences.claudeHome)
                TextField("Hermes home", text: $preferences.hermesHome)
                TextField("T3 Code home", text: $preferences.t3Home)
                TextField("Harness reports", text: $preferences.harnessDirectory)
                Text("Use absolute paths or ~. Hermes named profiles are discovered inside its home folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Optional CLI paths") {
                TextField("Codex executable", text: $preferences.codexExecutable)
                TextField("Claude executable", text: $preferences.claudeExecutable)
                TextField("Hermes executable", text: $preferences.hermesExecutable)
                Text("Leave blank to search PATH and standard installation folders. Finder may not inherit your shell PATH. Use an absolute executable path for other installations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Monitoring") {
                Picker("Refresh every", selection: $preferences.refreshSeconds) {
                    Text("2 seconds").tag(2)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                }
                Picker("Recent records per source/profile", selection: $preferences.sessionLimit) {
                    Text("50").tag(50)
                    Text("200").tag(200)
                    Text("1,000").tag(1000)
                    Text("2,000").tag(2000)
                }
            }
            Section {
                HStack {
                    Text("Local monitoring only. No API keys required.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh now") { Task { await store.refresh() } }.disabled(store.refreshing)
                }
            }
        }.formStyle(.grouped).padding(10).frame(width: 620, height: 650)
    }
}
