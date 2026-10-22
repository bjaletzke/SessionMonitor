import SwiftUI

struct MessagePreviewCard: View {
    let session: Session
    @Bindable var store: SessionStore
    var body: some View {
        GroupBox("Last message") {
            VStack(alignment: .leading, spacing: 10) {
                if let message = session.lastMessage {
                    HStack {
                        Text(message.roleLabel).fontWeight(.medium)
                        Spacer()
                        if let date = message.recordedAt { Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                    }.font(.caption)
                    Text(message.text).font(.callout).lineLimit(7).textSelection(.enabled)
                    Button("Read message…") { store.showingMessage = true }
                    Text(message.coverage + (message.truncated ? " · preview truncated" : "")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No conversation message found in the available local data.").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(5).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MessagePreviewView: View {
    let session: Session
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Last message").font(.title2.weight(.semibold))
                    Text(session.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(22)
            Divider()
            if let message = session.lastMessage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(message.roleLabel).fontWeight(.semibold)
                            Spacer()
                            if let date = message.recordedAt { Text(date.formatted()).foregroundStyle(.secondary) }
                        }.font(.callout)
                        MessageBodyView(text: message.text)
                        Text(message.coverage + (message.truncated ? ". Limited to an 8,000-character preview." : "."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Copy message") { DesktopActions.copy(message.text) }
                    }.padding(22)
                }
            } else {
                ContentUnavailableView("No message available", systemImage: "text.bubble", description: Text("The bounded local transcript may not contain a conversation message."))
            }
        }.frame(width: 650, height: 560)
    }
}
