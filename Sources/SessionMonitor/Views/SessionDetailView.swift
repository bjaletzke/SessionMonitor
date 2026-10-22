import SwiftUI

enum SessionDetailSection: String, CaseIterable, Identifiable {
    case latest = "Latest", notes = "Notes", context = "Context"
    var id: String { rawValue }
}

struct SessionDetailView: View {
    let session: Session
    @Bindable var store: SessionStore
    @State private var showingSessionUsage = false
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Label(session.app.rawValue, systemImage: session.app.symbol)
                    Text("/").foregroundStyle(.tertiary)
                    Label(session.workspaceName, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button { showingSessionUsage.toggle() } label: {
                        Label("Usage", systemImage: "chart.bar")
                    }.buttonStyle(.borderless).help("Session token usage")
                        .popover(isPresented: $showingSessionUsage, arrowEdge: .bottom) {
                            SessionUsagePopover(session: session, store: store)
                        }
                    Menu {
                        Button("Archive in \(session.app.rawValue)…", systemImage: "archivebox") { store.archiveCandidate = session }
                            .disabled(store.archiveReason(session) != nil || store.archivingID != nil)
                        if let reason = store.archiveReason(session) { Text(reason) }
                        Divider()
                        Button("Copy session ID") { DesktopActions.copy(session.sessionID) }
                        Button("Show session info") { store.showingInspector = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize().help("Session actions")
                    Button { store.toggleBookmark(session) } label: {
                        Image(systemName: store.library.annotation(for: session.id).bookmarked ? "star.fill" : "star")
                    }.buttonStyle(.borderless).disabled(!store.library.canEdit)
                        .help("Bookmark session (⌘D)")
                        .accessibilityLabel(store.library.annotation(for: session.id).bookmarked ? "Remove bookmark" : "Bookmark session")
                }.font(.callout).foregroundStyle(.secondary)
                Text(session.title).font(.system(size: 24, weight: .semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .center) {
                    if store.library.annotation(for: session.id).archivedInSourceAt != nil {
                        Label("Archived in \(session.app.rawValue)", systemImage: "archivebox").font(.callout).foregroundStyle(.secondary)
                    } else { StateBadge(session: session) }
                    Spacer(minLength: 12)
                    actions
                }
                contentPicker.frame(maxWidth: 560, alignment: .leading)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch store.detailSection {
                    case .latest: latest
                    case .notes: SessionAnnotationView(session: session, store: store)
                    case .context:
                        SessionContextView(session: session, store: store)
                        workspace
                        contextActions

                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(24)
            }
        }
    }
    private var actions: some View {
        HStack(spacing: 8) {
            if session.state == .responseReady {
                Button("Mark reviewed") { store.markReviewed(session) }
                    .disabled(session.completedAt == nil)
                    .workspaceAction()
            }
            Button { store.openSelected() } label: {
                Label(store.openLabel(session), systemImage: "arrow.up.forward.app")
            }.workspaceAction(prominent: true).disabled(session.app == .harness)
                .help("Open or resume only when you choose this action (⌘O)")
        }
    }
    private var contentPicker: some View {
        Picker("Session content", selection: $store.detailSection) {
            ForEach(SessionDetailSection.allCases) { section in
                Text(section.rawValue + (section == .notes && !store.library.annotation(for: session.id).notes.isEmpty ? " •" : "")).tag(section)
            }
        }.labelsHidden().pickerStyle(.segmented).controlSize(.large).tint(.accentColor)
    }
    @ViewBuilder private var latest: some View {
        if !session.question.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Recorded question", systemImage: "questionmark.bubble").font(.headline)
                MessageBodyView(text: session.question)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
        if let message = session.lastMessage {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(message.roleLabel, systemImage: message.role == "user" ? "person.crop.circle" : session.app.symbol).font(.headline)
                    Spacer()
                    if let date = message.recordedAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                MessageBodyView(text: message.text)
                Divider()
                Text(message.coverage + (message.truncated ? " · Limited to an 8,000-character preview" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy message") { DesktopActions.copy(message.text) }.workspaceAction()
                    Button("Read in separate view…") { store.showingMessage = true }.workspaceAction()
                }
            }
        } else {
            ContentUnavailableView("No message available", systemImage: "text.bubble",
                description: Text("The available local data doesn’t contain a user or assistant message. Open the session to continue."))
        }
        let notes = store.library.annotation(for: session.id).notes
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Label("Your notes", systemImage: "note.text").font(.headline); Spacer(); Button("Edit notes") { store.detailSection = .notes } }
                Text(notes).lineLimit(3).foregroundStyle(.secondary)
            }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private var workspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Location").font(.headline)
            Text(session.workspace.isEmpty ? "Workspace not recorded" : session.workspace).textSelection(.enabled)
            Text(session.origin).font(.callout).foregroundStyle(.secondary)
            Text("Last activity " + session.updatedAt.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var contextActions: some View {
        HStack {
            Button("Open workspace") { DesktopActions.openFolder(session.workspace) }
                .disabled(session.workspace.isEmpty || !LocalFiles.exists(session.workspace))
                .workspaceAction()
            if session.app != .harness { Button("Open \(session.app.rawValue) app") { store.openApplication(session.app) }.workspaceAction() }
        }
    }
}
