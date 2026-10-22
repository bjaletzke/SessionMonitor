import Foundation

enum CodexAdapter {
    static func scan(home: String, limit: Int, reader: TranscriptReader, now: Date, requestedIDs: Set<String> = []) throws -> [Session] {
        let databases = LocalFiles.children(home).filter {
            $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite"
        }.sorted { version($0) > version($1) }
        guard let path = databases.first?.path else { throw DatabaseError.failure("No Codex session database found. Run Codex once or choose its data folder in Settings.") }
        let db = try ReadOnlyDatabase(path: path), columns = try db.columns("threads")
        guard columns.contains("id") else { throw DatabaseError.failure("Unrecognized Codex session schema.") }
        let wanted = ["id", "rollout_path", "updated_at", "updated_at_ms", "created_at", "created_at_ms", "title", "name", "model", "model_provider", "cwd", "source", "agent_role", "agent_nickname", "agent_path", "cli_version", "tokens_used", "git_branch"]
        let fields = wanted.filter { columns.contains($0) }.joined(separator: ",")
        let whereClause = columns.contains("archived") ? "WHERE archived=0" : "WHERE 1=1"
        let order: String
        if columns.contains("updated_at_ms") {
            order = columns.contains("updated_at") ? "ORDER BY COALESCE(updated_at_ms,updated_at*1000) DESC" : "ORDER BY updated_at_ms DESC"
        } else { order = columns.contains("updated_at") ? "ORDER BY updated_at DESC" : "" }
        var rows = try db.rows("SELECT \(fields) FROM threads \(whereClause) \(order) LIMIT \(max(1, min(2000, limit)))")
        if !requestedIDs.isEmpty {
            let ids = requestedIDs.sorted().prefix(32).map(sqlLiteral).joined(separator: ",")
            let loaded = Set(rows.compactMap { $0["id"] })
            rows += try db.rows("SELECT \(fields) FROM threads \(whereClause) AND id IN (\(ids))").filter { !loaded.contains($0["id"] ?? "") }
        }
        guard !rows.isEmpty else { return [] }
        var relations: [String: [RelatedSession]] = [:], parents: [String: String] = [:]
        let ids = rows.compactMap { $0["id"] }.map(sqlLiteral).joined(separator: ",")
        var edges: [[String: String]] = []
        if (try? db.tables().contains("thread_spawn_edges")) == true,
           let edgeColumns = try? db.columns("thread_spawn_edges"), edgeColumns.isSuperset(of: ["parent_thread_id", "child_thread_id"]) {
            // Bound relation reads to loaded threads rather than scan the entire history on every poll.
            edges = (try? db.rows("SELECT parent_thread_id,child_thread_id\(edgeColumns.contains("status") ? ",status" : "") FROM thread_spawn_edges WHERE parent_thread_id IN (\(ids)) OR child_thread_id IN (\(ids)) LIMIT 4001")) ?? []
        }
        let capped = edges.count > 4000
        let edgeIDs = Set(edges.prefix(4000).flatMap { [$0["parent_thread_id"], $0["child_thread_id"]].compactMap { $0 } })
        let titleRows = edgeIDs.isEmpty ? [] : (try? db.rows("SELECT id,\(columns.contains("title") ? "title" : "id AS title") FROM threads WHERE id IN (\(edgeIDs.sorted().map(sqlLiteral).joined(separator: ",")))")) ?? []
        let titles = Dictionary(titleRows.compactMap { row -> (String, String)? in
            guard let id = row["id"] else { return nil }
            return (id, LocalFiles.boundedTitle(row["title"], fallback: "Codex \(id.prefix(8))"))
        }, uniquingKeysWith: { old, _ in old })
        for edge in edges.prefix(4000) {
            guard let parent = edge["parent_thread_id"], let child = edge["child_thread_id"], parent != child else { continue }
            parents[child] = parent
            let note = edge["status"].map { "Recorded spawn status: \($0) · not live activity" } ?? "Recorded spawn edge"
            relations[parent, default: []].append(RelatedSession(id: "codex:\(child)", title: titles[child] ?? "Codex \(child.prefix(8))", kind: .subagent, note: note))
            relations[child, default: []].append(RelatedSession(id: "codex:\(parent)", title: titles[parent] ?? "Codex \(parent.prefix(8))", kind: .parent, note: note))
        }
        return rows.compactMap { row in
            guard let id = row["id"] else { return nil }
            let summary = reader.summary(path: row["rollout_path"] ?? "", app: .codex, now: now)
            let parent = parents[id] ?? summary.parentID
            var links = relations[id] ?? []
            if let parent, parent != id, !links.contains(where: { $0.id == "codex:\(parent)" }) {
                links.append(RelatedSession(id: "codex:\(parent)", title: titles[parent] ?? "Codex \(parent.prefix(8))", kind: .parent, note: "Recorded startup parent identity"))
            } else if parent == nil, let fork = summary.forkedFromID, fork != id {
                links.append(RelatedSession(id: "codex:\(fork)", title: titles[fork] ?? "Codex \(fork.prefix(8))", kind: .forkedFrom, note: "Recorded shared-history origin; token totals may overlap"))
            }
            var record = summary.record
            record.startedAt = LocalFiles.date(row["created_at_ms"]) ?? LocalFiles.date(row["created_at"]) ?? record.startedAt
            record.agentPath = row["agent_path"]?.nilIfEmpty ?? record.agentPath
            record.providerVersion = row["cli_version"]?.nilIfEmpty ?? record.providerVersion
            if row["model"]?.nilIfEmpty != nil { record.modelSource = "Session index" }
            record.relationshipCoverage = capped ? "Partial: relationship read capped at 4,000 edges" : "Spawn edges for loaded chats, plus available startup lineage"
            var usage = summary.usage
            if usage == nil, let total = TokenUsage.number(row["tokens_used"]) {
                usage = TokenUsage(total: total, coverage: "Session index total", note: "The event tail has no token breakdown. Recorded activity is not a bill.")
            } else if let index = TokenUsage.number(row["tokens_used"]), let total = usage?.total, index != total {
                usage?.note += " The session index separately records \(index.formatted()) tokens; its scope or update time differs."
            }
            return Session(id: "codex:\(id)", sessionID: id, app: .codex,
                           title: LocalFiles.boundedTitle(row["name"]?.nilIfEmpty ?? row["title"], fallback: "Codex \(id.prefix(8))"),
                           model: row["model"]?.nilIfEmpty ?? summary.model, provider: row["model_provider"]?.nilIfEmpty ?? summary.provider,
                           workspace: row["cwd"]?.nilIfEmpty ?? summary.workspace, origin: row["source"] ?? "local",
                           state: summary.state, confidence: summary.confidence, evidence: summary.evidence,
                           updatedAt: max(summary.lastEvent ?? .distantPast, LocalFiles.date(row["updated_at_ms"]) ?? LocalFiles.date(row["updated_at"]) ?? record.startedAt ?? .distantPast),
                           sourcePath: row["rollout_path"] ?? path, parentID: parent,
                           completedAt: summary.completedAt, question: summary.question, usage: usage,
                           quota: summary.quota, lastMessage: summary.lastMessage, gitBranch: row["git_branch"] ?? summary.gitBranch,
                           relations: links, agentRole: row["agent_role"]?.nilIfEmpty ?? summary.agentRole,
                           agentNickname: row["agent_nickname"]?.nilIfEmpty ?? summary.agentName,
                           parentKey: parent.map { "codex:\($0)" }, isSubagent: parent != nil, record: record)
        }
    }
    private static func version(_ url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "state_", with: "")) ?? 0
    }
}
