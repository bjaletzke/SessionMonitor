import SwiftUI
import AppKit

@main enum SessionMonitorEntry {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--usage") || CommandLine.arguments.contains("--diagnostics") {
            let collector = SessionCollector()
            let result = await collector.scan(MonitorPreferences.defaultConfiguration)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data: Data?
            if CommandLine.arguments.contains("--diagnostics") { data = try? encoder.encode(result.sources) }
            else if CommandLine.arguments.contains("--usage") { data = try? encoder.encode(result.usage) }
            else { data = try? encoder.encode(result.sessions) }
            if let data {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            for source in result.sources {
                let message = "\(source.app.rawValue): \(source.available ? "available" : "unavailable"), \(source.count) sessions — \(source.message)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
            return
        }
        SessionMonitorApp.main()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct SessionMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = SessionStore()
    var body: some Scene {
        WindowGroup("Session Monitor", id: "sessions") {
            ContentView(store: store)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh sessions") { Task { await store.refresh() } }.keyboardShortcut("r")
                Button("Open selected session") { store.openSelected() }.keyboardShortcut("o")
                    .disabled(store.selectedSession == nil || store.selectedSession?.app == .harness)
                Button("Bookmark selected session") {
                    if let session = store.selectedSession { store.toggleBookmark(session) }
                }.keyboardShortcut("d").disabled(store.selectedSession == nil || !store.library.canEdit)
                Button("Show bookmarks") { store.scope = .bookmarks }.keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Show latest message") { store.detailSection = .latest }.keyboardShortcut("l").disabled(store.selectedSession == nil)
                Button("Edit session notes") { store.detailSection = .notes }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(store.selectedSession == nil)
                Button("Read last message separately") { store.showingMessage = true }.disabled(store.selectedSession == nil)
                Button("Session info") { store.showingInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                Button("Overall usage") { store.showingUsage = true }
                Button("Sources & setup") { store.showingSources = true }
            }
        }
        Settings { SettingsView(preferences: store.preferences, store: store) }
        MenuBarExtra {
            MonitorMenu(store: store)
        } label: {
            Label(store.menuTitle, systemImage: "rectangle.stack.badge.play")
        }
    }
}

private struct MonitorMenu: View {
    @Bindable var store: SessionStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("\(store.runningCount) running · \(store.attentionCount) need attention")
        Text("Includes activity estimates")
        Divider()
        Button("Open sessions") {
            openWindow(id: "sessions")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Bookmarks") {
            store.scope = .bookmarks
            openWindow(id: "sessions")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh") { Task { await store.refresh() } }.keyboardShortcut("r")
        Toggle("Auto refresh", isOn: $store.autoRefresh)
        Divider()
        Button("Quit Session Monitor") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
