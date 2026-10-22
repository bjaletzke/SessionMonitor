import SwiftUI

/// A keyboard-selectable conversation list. The selected conversation owns the reading pane.
struct SessionTable: View {
    @Bindable var store: SessionStore
    var body: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            List(selection: $store.selectedID) {
                ForEach(store.visibleSessions) { session in
                    SessionRow(session: session, store: store).tag(session.id)
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                        .listRowSeparator(.visible)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { selection in
                if let id = selection.first, let session = store.session(for: id) {
                    Button(store.openLabel(session)) { store.selectedID = id; store.openSelected() }
                        .disabled(session.app == .harness)
                    Button("Read last message") { store.selectedID = id; store.showingMessage = true }
                    Button(store.library.annotation(for: id).bookmarked ? "Remove bookmark" : "Bookmark session") { store.toggleBookmark(session) }
                        .disabled(!store.library.canEdit)
                    Menu("Set local status") {
                        Button("Follow source") { store.setOverride(nil, session: session) }
                        Divider()
                        ForEach(SessionState.allCases, id: \.rawValue) { state in
                            Button(state.label) { store.setOverride(state, session: session) }
                        }
                    }.disabled(!store.library.canEdit)
                    Button("Show context") { store.selectedID = id; store.detailSection = .context }
                    if session.state == .responseReady {
                        Button("Mark reviewed") { store.markReviewed(session) }.disabled(session.completedAt == nil)
                    }
                    Divider()
                    Button("Archive in \(session.app.rawValue)…") { store.archiveCandidate = session }
                        .disabled(store.archiveReason(session) != nil || store.archivingID != nil)
                    Button("Copy session ID") { DesktopActions.copy(session.sessionID) }
                    if let command = store.resumeCommand(session) {
                        Button("Copy resume command") { DesktopActions.copy(command) }
                    }
                    Button("Reveal source in Finder") { DesktopActions.reveal(session.sourcePath) }.disabled(session.sourcePath.isEmpty)
                }
            } primaryAction: { selection in
                if let id = selection.first { store.selectedID = id; store.openSelected() }
            }
            .overlay {
                if store.visibleSessions.isEmpty {
                    if store.refreshing {
                        ProgressView("Reading local sessions…")
                    } else {
                        ContentUnavailableView(store.scope == .bookmarks && store.search.isEmpty ? "No bookmarks yet" : "No sessions found",
                            systemImage: store.scope == .bookmarks ? "star" : "tray",
                            description: Text(store.search.isEmpty ? "Choose another view or time range, or check Sources & setup." : "Try a title, project, application, model, or note."))
                    }
                }
            }
            Divider()
            HStack(spacing: 5) {
                if store.refreshing { ProgressView().controlSize(.mini) }
                Text(store.refreshing ? "Refreshing…" : "Updated " + store.snapshot.scannedAt.formatted(date: .omitted, time: .shortened))
                Spacer()
                if let error = store.library.storageError {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red).help(error)
                }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
    }
    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text((store.scope ?? .all).title).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(store.visibleSessions.count.formatted()).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text(store.scope == .bookmarks ? "All dates · search includes notes" : "Attention first · then recent activity")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if store.scope != .bookmarks {
                    Picker("Time range", selection: $store.preferences.days) {
                        Text("24 hours").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("All loaded").tag(0)
                    }.labelsHidden().fixedSize().controlSize(.large)
                        .help("Open and actionable sessions remain visible. All loaded respects the source record limit.")
                }
            }
            if store.scope == .review && store.visibleReviewableCount > 0 {
                Button("Mark \(store.visibleReviewableCount) responses reviewed…") { store.prepareReview() }
                    .buttonStyle(.borderless).font(.callout)
            }
        }.padding(24)
    }
}

private struct SessionRow: View {
    let session: Session
    @Bindable var store: SessionStore
    private var notes: String { store.library.annotation(for: session.id).notes }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: session.app.symbol)
                Text(session.app.rawValue).fontWeight(.medium)
                Text("·")
                Text(session.workspaceName).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button { store.toggleBookmark(session) } label: {
                    Image(systemName: store.library.annotation(for: session.id).bookmarked ? "star.fill" : "star")
                }.buttonStyle(.borderless).disabled(!store.library.canEdit)
                    .accessibilityLabel(store.library.annotation(for: session.id).bookmarked ? "Remove bookmark" : "Bookmark session")
                    .help("Bookmark session (⌘D)")
            }.font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 5) {
                if session.isSubagent { Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary) }
                Text(session.title).font(.body.weight(.semibold)).lineLimit(2)
            }
            if session.isSubagent {
                HStack(spacing: 6) {
                    Text([session.agentRole, session.model].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1)
                    Spacer(minLength: 0)
                    if let usage = session.usage, let tokens = usage.displayCount {
                        Text("\(tokens.formatted()) \(usage.totalIsPartial == true || usage.coverage.localizedCaseInsensitiveContains("partial") ? "partial tokens" : "tokens")")
                            .lineLimit(1).help(usage.coverage)
                    }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Text(MarkdownText.preview(preview))
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            if let tree = session.worktree, tree.isLinked {
                Label(tree.branch.isEmpty ? tree.name : tree.branch, systemImage: "arrow.triangle.branch")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 5) {
                Label(store.library.annotation(for: session.id).archivedInSourceAt != nil ? "Archived in " + session.app.rawValue : session.state.label,
                      systemImage: store.library.annotation(for: session.id).archivedInSourceAt != nil ? "archivebox" : session.state.symbol).foregroundStyle(store.selectedID == session.id ? Color.primary : session.state.color)
                Spacer(minLength: 4)
                Text(session.updatedAt, style: .relative).foregroundStyle(.secondary)
            }.font(.caption)
            HStack {
                Text(session.detectedState.map { "Local override · source: " + $0.label } ?? session.confidence.label)
                    .foregroundStyle(store.selectedID == session.id ? Color.primary : session.detectedState?.needsAction == true ? Color.orange : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                let count = session.relations.filter { $0.kind == .subagent }.count
                if count > 0 {
                    Button("\(count) subagents") {
                        store.selectedID = session.id
                        store.detailSection = .context
                    }.buttonStyle(.borderless).help("Show recorded related agents; scan limits apply")
                }
            }.font(.caption2)
        }
        .padding(.vertical, 2)
        .help(session.workspace + "\n" + session.evidence)
    }
    private var preview: String {
        if store.scope == .bookmarks, !notes.isEmpty { return notes }
        if !session.question.isEmpty { return session.question }
        return session.lastMessage?.text ?? "No message preview available"
    }
}
