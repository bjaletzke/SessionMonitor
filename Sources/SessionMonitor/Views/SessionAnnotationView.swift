import SwiftUI

struct SessionAnnotationView: View {
    let session: Session
    @Bindable var store: SessionStore
    private var annotation: SessionAnnotation { store.library.annotation(for: session.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your notes").font(.title2.weight(.semibold))
            Text("Keep reminders and context alongside this conversation.").font(.callout).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { annotation.notes }, set: { store.setNotes($0, session: session) }))
                    .font(.body).scrollContentBackground(.hidden).padding(10).frame(minHeight: 300)
                if annotation.notes.isEmpty {
                    Text("Reminders, context, or things to revisit…")
                        .font(.body).foregroundStyle(.tertiary).padding(15).allowsHitTesting(false)
                }
            }.overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            if let error = store.library.storageError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else {
                Text(store.library.hasUnsavedChanges ? "Saving locally…" : "Saved locally · adding your first note bookmarks the session")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(!store.library.canEdit)
    }
}
