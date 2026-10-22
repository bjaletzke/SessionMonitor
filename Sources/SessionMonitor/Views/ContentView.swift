import SwiftUI

struct ContentView: View {
    @Bindable var store: SessionStore
    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 260, ideal: 270, max: 340)
        } content: {
            SessionTable(store: store)
                .navigationSplitViewColumnWidth(min: 340, ideal: 380, max: 520)
        } detail: {
            Group {
                if let session = store.selectedSession {
                    SessionDetailView(session: session, store: store).id(session.id)
                } else {
                    ContentUnavailableView("Your conversations, in one place", systemImage: "text.bubble",
                        description: Text("Select a session to read its latest message, keep notes, and return to your work."))
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .navigationTitle("Session Monitor")
        .searchable(text: $store.search, placement: .toolbar, prompt: "Search sessions and notes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.refreshing || store.archivingID != nil).help("Refresh sessions (⌘R)")
            }
            if #available(macOS 26.0, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.showingInspector.toggle() } label: { Label("Session info", systemImage: "info.circle") }
                    .help("State evidence and source details (⌘⌥I)")
                    .popover(isPresented: $store.showingInspector, arrowEdge: .bottom) {
                        if let session = store.selectedSession {
                            SessionEvidenceView(session: session, store: store).frame(width: 360, height: 580)
                        } else { Text("Select a session").padding(24) }
                    }
                Menu {
                    Toggle("Auto refresh", isOn: $store.autoRefresh)
                    Button("Mark \(store.visibleReviewableCount) responses reviewed") { store.prepareReview() }
                        .disabled(store.visibleReviewableCount == 0)
                    Divider()
                    Button("Overall usage") { store.showingUsage = true }
                    Button("Sources & setup") { store.showingSources = true }
                    SettingsLink { Text("Settings…") }
                } label: { Label("Workspace options", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $store.showingSources) { SourcesView(store: store) }
        .sheet(isPresented: $store.showingUsage) { UsageView(store: store) }
        .sheet(isPresented: $store.showingMessage) {
            if let session = store.selectedSession { MessagePreviewView(session: session) }
        }
        .onChange(of: store.visibleSessions.map(\.id), initial: true) { _, _ in store.reconcileSelection() }
        .confirmationDialog("Archive in \(store.archiveCandidate?.app.rawValue ?? "original app")?", isPresented: Binding(get: { store.archiveCandidate != nil }, set: { if !$0 { store.archiveCandidate = nil } }), titleVisibility: .visible, presenting: store.archiveCandidate) { candidate in
            Button("Archive in \(candidate.app.rawValue)") { Task { await store.archive(candidate) } }
        } message: { candidate in
            Text("\(candidate.title) will be archived in \(candidate.app.rawValue). Codex may also archive its spawned descendants. You can restore it there. Saved notes and bookmarks are kept in Session Monitor.")
        }
        .confirmationDialog("Mark \(store.reviewCandidates.count) responses reviewed?", isPresented: $store.showingReviewConfirmation, titleVisibility: .visible) {
            Button("Mark responses reviewed") { store.markPreparedReviewed() }
        } message: { Text("Applies to response-ready chats in the current list. New responses will appear here again. This does not archive chats in their original app.") }
        .alert("Action unavailable", isPresented: Binding(get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } })) {
            Button("OK") { store.actionError = nil }
        } message: { Text(store.actionError ?? "") }
        .task { store.start() }
        .frame(minWidth: 1180, minHeight: 680)
    }
}
