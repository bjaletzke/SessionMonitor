import SwiftUI

struct SidebarView: View {
    @Bindable var store: SessionStore
    var body: some View {
        List(selection: $store.scope) {
            Section("Workspace") {
                scopeRow("All sessions", icon: "tray", count: store.recentSessions.count, scope: .all)
                scopeRow("Needs attention", icon: "exclamationmark.bubble", count: store.attentionCount, scope: .attention)
                scopeRow("Response ready", icon: "checkmark.bubble", count: store.reviewCount, scope: .review)
                scopeRow("Running", icon: "play.circle", count: store.runningCount, scope: .running)
                scopeRow("Bookmarks", icon: "star", count: store.bookmarks.count, scope: .bookmarks)
            }
            if !store.projects.isEmpty {
                Section("Projects") {
                    ForEach(store.projects) { project in
                        scopeRow(project.name, icon: "folder", count: project.sessionCount, scope: .project(project.name))
                            .help(project.paths.joined(separator: "\n"))
                    }
                }
            }
            Section("Applications") {
                ForEach(AgentApp.allCases) { app in
                    scopeRow(app.rawValue, icon: app.symbol, count: store.recentSessions.filter { $0.app == app }.count, scope: .app(app))
                }
            }
            Section("Related work") {
                scopeRow("Worktrees", icon: "arrow.triangle.branch", count: store.recentSessions.filter { $0.worktree?.isLinked == true }.count, scope: .worktrees)
                scopeRow("Subagents", icon: "person.2", count: store.recentIncludingSubagents.filter(\.isSubagent).count, scope: .subagents)
            }
            Section("Library") {
                Button { store.showingUsage = true } label: { Label("Overall usage", systemImage: "chart.bar") }
                Button { store.showingSources = true } label: { Label("Sources & setup", systemImage: "externaldrive") }
            }.buttonStyle(.plain)
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .large)
        .navigationTitle("Session Monitor")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                Text("On this Mac")
                Spacer()
                if !store.autoRefresh { Image(systemName: "pause.circle").help("Auto refresh paused") }
            }.font(.caption).foregroundStyle(.secondary).padding(16)
        }
    }
    private func scopeRow(_ title: String, icon: String, count: Int, scope: SidebarScope) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: icon).lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 { Text(count.formatted()).monospacedDigit().foregroundStyle(.secondary).font(.caption) }
        }.padding(.vertical, 3).tag(scope)
    }
}
