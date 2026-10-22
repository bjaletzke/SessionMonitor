import SwiftUI

struct SessionContextView: View {
    let session: Session
    @Bindable var store: SessionStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Recorded session context") {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 9) {
                        metadata("Application", session.app.rawValue)
                        metadata("Model", session.displayModel)
                        metadata("Provider", session.provider.isEmpty ? "Not recorded" : session.provider)
                        metadata("Origin", session.origin.isEmpty ? "Not recorded" : session.origin)
                        metadata("Session type", session.isSubagent ? "Subagent" : session.relations.contains(where: { $0.kind == .continuedFrom }) ? "Continuation" : "Main chat")
                        metadata("Session ID", session.sessionID)
                        if let environment = session.environmentID { metadata("T3 environment", environment) }
                        if !session.agentRole.isEmpty { metadata("Agent role", session.agentRole) }
                        if !session.agentNickname.isEmpty { metadata("Agent name", session.agentNickname) }
                        if let path = session.record?.agentPath { metadata("Agent path", path) }
                        if let depth = session.record?.depth { metadata("Spawn depth", String(depth)) }
                        if let version = session.record?.providerVersion { metadata("Recorded provider version", version) }
                        if let source = session.record?.modelSource { metadata("Model evidence", source) }
                        if let started = session.record?.startedAt { metadata("Started", started.formatted(date: .abbreviated, time: .standard)) }
                        else if let first = session.record?.firstObservedAt { metadata("First observed in file", first.formatted(date: .abbreviated, time: .standard)) }
                        if let ended = session.record?.endedAt { metadata("Ended", ended.formatted(date: .abbreviated, time: .standard)) }
                        if let outcome = session.record?.outcome { metadata("Recorded outcome", outcome) }
                        if let activity = session.record?.activity { metadata("Recorded activity", activity) }
                        metadata("Last activity", session.updatedAt.formatted(date: .abbreviated, time: .standard))
                        if let completion = session.completedAt { metadata("Last completion", completion.formatted(date: .abbreviated, time: .standard)) }
                    }.font(.callout)
                    if let task = session.record?.taskDescription {
                        Text(task).font(.callout).textSelection(.enabled)
                    }
                    Divider()
                    if let coverage = session.record?.readCoverage { Text(coverage).font(.caption).foregroundStyle(.secondary) }
                    if [.codex, .claude].contains(session.app), !session.savedBookmark {
                        Button(store.hasExpandedDetails(session) ? "Reload deeper record details" : "Load deeper record details") {
                            Task { await store.loadDetails(session) }
                        }.disabled(store.loadingDetailsID != nil)
                        Text("Reads up to 8 MiB of this transcript on demand. Larger files still have partial coverage. Cached until the source changes.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(session.lastMessage?.coverage ?? "No message found in the available local records.")
                        .font(.caption).foregroundStyle(.secondary)
                    if session.lastMessage?.truncated == true { Text("Latest message preview is limited to 8,000 characters.").font(.caption).foregroundStyle(.secondary) }
                    Text("These are recorded metadata and recent transcript excerpts. Full prompts, loaded files and live context-window occupancy are not available from this scan.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let tree = session.worktree {
                GroupBox(tree.isLinked ? "Linked worktree" : "Repository") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(tree.repositoryName, systemImage: tree.isLinked ? "arrow.triangle.branch" : "folder").font(.callout.weight(.medium))
                        if tree.isLinked { Text("Worktree: \(tree.name)").font(.callout) }
                        if !tree.branch.isEmpty { Text("Current branch: \(tree.branch)").font(.callout).textSelection(.enabled) }
                        if !session.gitBranch.isEmpty, session.gitBranch != tree.branch {
                            Text("Recorded session branch: \(session.gitBranch)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(tree.root).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Git metadata checked \(tree.inspectedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        Button("Open \(tree.isLinked ? "worktree" : "repository")") { DesktopActions.openFolder(tree.root) }
                    }.padding(5).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !session.gitBranch.isEmpty {
                Label("Recorded branch: \(session.gitBranch)", systemImage: "arrow.triangle.branch").font(.callout).foregroundStyle(.secondary)
            }
            if !session.agentRole.isEmpty || !session.agentNickname.isEmpty {
                Label([session.agentNickname, session.agentRole].filter { !$0.isEmpty }.joined(separator: " · "), systemImage: "person.crop.circle")
                    .font(.callout).textSelection(.enabled)
            }
            if !session.relations.isEmpty {
                GroupBox("Related sessions") {
                    VStack(alignment: .leading, spacing: 14) {
                        let children = session.relations.filter { $0.kind == .subagent || $0.kind == .child }
                        let loaded = children.compactMap { store.session(for: $0.id) }.filter { !$0.savedBookmark }
                        if !children.isEmpty {
                            Text("\(children.count) recorded agents · \(loaded.count) loaded · \(loaded.filter { $0.state == .running }.count) show Running · \(loaded.filter { $0.state.needsAction }.count) need attention")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let coverage = session.record?.relationshipCoverage { Text(coverage).font(.caption2).foregroundStyle(.secondary) }
                        ForEach(session.relations.sorted { $0.kind.rawValue < $1.kind.rawValue }) { relation in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(relation.kind.label).font(.caption).foregroundStyle(.secondary)
                                if let related = store.session(for: relation.id) {
                                    Button { store.selectRelated(relation.id) } label: {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(relation.title).lineLimit(2).multilineTextAlignment(.leading)
                                            Spacer(minLength: 4)
                                            Image(systemName: "arrow.right")
                                        }
                                    }.buttonStyle(.link)
                                    HStack {
                                        Label(related.state.label, systemImage: related.state.symbol).foregroundStyle(related.state.color)
                                        Text("· " + related.confidence.label).foregroundStyle(.secondary)
                                        Spacer(minLength: 4)
                                        Text(related.updatedAt, style: .relative).foregroundStyle(.secondary)
                                    }.font(.caption)
                                    Text([related.agentNickname, related.agentRole, related.displayModel].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !related.question.isEmpty {
                                        Label(related.question, systemImage: "questionmark.bubble").font(.callout).foregroundStyle(.orange).lineLimit(3)
                                    } else if let message = related.lastMessage {
                                        Text(MarkdownText.preview(message.text)).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                    if let usage = related.usage {
                                        Text(usage.displayCount.map { "\($0.formatted()) \(usage.totalIsPartial == true ? "recorded token subtotal" : "tokens") · " + usage.coverage } ?? "Token total not recorded · " + usage.coverage)
                                            .font(.caption2).foregroundStyle(.secondary)
                                        if let cost = usage.actualCostUSD ?? usage.estimatedCostUSD {
                                            Text("\(usage.actualCostUSD != nil ? "Recorded actual" : "Estimated") cost: \(cost.formatted(.currency(code: "USD")))")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    } else { Text("Token counters not recorded").font(.caption2).foregroundStyle(.secondary) }
                                    if let outcome = related.record?.outcome { Text("Recorded outcome: " + outcome).font(.caption2).foregroundStyle(.secondary) }
                                    if related.savedBookmark {
                                        Text("Saved history · current activity unverified").font(.caption2).foregroundStyle(.secondary)
                                        if [.codex, .hermes, .t3].contains(related.app) {
                                            Button("Load current source records") { Task { await store.loadRelated(relation.id) } }
                                                .disabled(store.loadingRelatedID != nil || store.refreshing)
                                        }
                                    }
                                } else {
                                    Text(relation.title).font(.callout).lineLimit(2)
                                    Text("Outside current scan · activity and usage unknown").font(.caption2).foregroundStyle(.secondary)
                                    if [.codex, .hermes, .t3].contains(session.app) {
                                        Button("Load this related chat") { Task { await store.loadRelated(relation.id) } }
                                            .disabled(store.loadingRelatedID != nil || store.refreshing)
                                    } else { Text("Increase the load limit to inspect").font(.caption2).foregroundStyle(.secondary) }
                                }
                                if !relation.note.isEmpty { Text(relation.note).font(.caption).foregroundStyle(.secondary) }
                            }
                            if relation.id != session.relations.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }).last?.id { Divider() }
                        }
                    }.padding(5).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Label("No related sessions found in available records", systemImage: "person.2").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private func metadata(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
