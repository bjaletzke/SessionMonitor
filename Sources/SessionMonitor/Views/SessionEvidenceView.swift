import SwiftUI

/// Supplementary source information, kept separate from reading and notes.
struct SessionEvidenceView: View {
    let session: Session
    @Bindable var store: SessionStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Session info").font(.headline)
                    Spacer()
                    Button { store.showingInspector = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Close session info")
                }
                StateBadge(session: session)
                Text(session.evidence).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Picker("Local status", selection: Binding<SessionState?>(get: { store.library.annotation(for: session.id).statusOverride }, set: { store.setOverride($0, session: session) })) {
                    Text("Follow source").tag(nil as SessionState?)
                    ForEach(SessionState.allCases, id: \.rawValue) { Text($0.label).tag(Optional($0)) }
                }.disabled(!store.library.canEdit)
                Text("Overrides are saved on this Mac. The detected source state remains visible.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                field("Model", session.displayModel)
                if !session.provider.isEmpty { field("Provider", session.provider) }
                field("Origin", session.origin)
                field("Session ID", session.sessionID)
                if let pid = session.pid { field("Process", "PID \(pid)\(session.isOpen ? " · open" : "")") }
                field("Source file", session.sourcePath.isEmpty ? "Not recorded" : session.sourcePath)
                Button("Copy session ID") { DesktopActions.copy(session.sessionID) }
                if let command = store.resumeCommand(session) { Button("Copy resume command") { DesktopActions.copy(command) } }
                Button("Reveal source in Finder") { DesktopActions.reveal(session.sourcePath) }.disabled(session.sourcePath.isEmpty)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
