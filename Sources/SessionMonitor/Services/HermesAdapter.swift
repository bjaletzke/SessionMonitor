import Foundation

enum HermesAdapter {
    static func scan(home: String, limit: Int, processes: ProcessInventory, now: Date) throws -> [Session] {
        try scanWithHealth(home: home, limit: limit, processes: processes, now: now).sessions
    }

    static func scanWithHealth(home: String, limit: Int, processes: ProcessInventory, now: Date, requestedIDs: Set<String> = []) throws -> (sessions: [Session], warnings: [String]) {
        var homes = [URL(fileURLWithPath: home)]
        homes += LocalFiles.children(home + "/profiles").filter { LocalFiles.exists($0.appendingPathComponent("state.db").path) }
        var sessions: [Session] = [], errors: [String] = []
        for root in homes where LocalFiles.exists(root.appendingPathComponent("state.db").path) {
            do { sessions += try scanProfile(root: root, limit: limit, processes: processes, now: now, requestedIDs: requestedIDs) }
            catch { errors.append("\(root.lastPathComponent): \(error.localizedDescription)") }
        }
        guard !homes.allSatisfy({ !LocalFiles.exists($0.appendingPathComponent("state.db").path) }) else {
            throw DatabaseError.failure("No Hermes state.db found in the root or named profiles.")
        }
        return (sessions, errors)
    }

    private static func scanProfile(root: URL, limit: Int, processes: ProcessInventory, now: Date, requestedIDs: Set<String>) throws -> [Session] {
        let path = root.appendingPathComponent("state.db").path
        let db = try ReadOnlyDatabase(path: path), cols = try db.columns("sessions")
        guard cols.contains("id"), cols.contains("started_at") else { throw DatabaseError.failure("Unrecognized Hermes session schema.") }
        let wanted = ["id", "title", "display_name", "model", "billing_provider", "cwd", "git_repo_root", "source", "started_at", "ended_at", "end_reason", "last_activity_at", "last_activity_description", "parent_session_id", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens", "estimated_cost_usd", "actual_cost_usd", "cost_status", "cost_source", "git_branch", "profile_name"]
        // Delegated workers may inherit the parent's UI transport source. The stored
        // _delegate_from marker identifies them without loading other model configuration.
        let delegate = cols.contains("model_config") ? "CASE WHEN length(s.model_config)<=65536 AND json_valid(s.model_config) THEN json_extract(s.model_config,'$._delegate_from') END" : "NULL"
        let delegateField = ", \(delegate) AS delegate_parent"
        let fields = wanted.filter { cols.contains($0) }.map { "s.\($0)" }.joined(separator: ",")
        let filters = ["archived", "hidden"].filter { cols.contains($0) }.map { "COALESCE(s.\($0),0)=0" }
        let whereSQL = filters.isEmpty ? "WHERE 1=1" : "WHERE " + filters.joined(separator: " AND ")
        let order = cols.contains("last_activity_at") ? "COALESCE(s.last_activity_at,s.started_at)" : "s.started_at"
        let tables = try db.tables()
        let hasMessages = tables.contains("messages")
        let messageCols = hasMessages ? try db.columns("messages") : []
        let canReadMessages = messageCols.isSuperset(of: ["id", "session_id"])
        let messageFields = ["role", "finish_reason", "timestamp"].filter { canReadMessages && messageCols.contains($0) }.map {
            ", (SELECT \($0) FROM messages m WHERE m.session_id=s.id ORDER BY m.id DESC LIMIT 1) AS last_\($0)"
        }.joined()
        var previewFields = ""
        if messageCols.isSuperset(of: ["role", "content", "timestamp", "id", "session_id"]) {
            let filter = "m.session_id=s.id AND m.role IN ('user','assistant') AND TRIM(COALESCE(m.content,''))<>''"
            previewFields = ["role", "timestamp", "substr(content,1,20000)", "length(content)"].enumerated().map { index, field in
                ", (SELECT \(field) FROM messages m WHERE \(filter) ORDER BY m.id DESC LIMIT 1) AS preview_\(index)"
            }.joined()
        }
        var rows = try db.rows("SELECT \(fields)\(delegateField)\(messageFields)\(previewFields) FROM sessions s \(whereSQL) ORDER BY \(order) DESC LIMIT \(max(1, min(2000, limit)))")
        let prefix = "hermes:\(root.path):"
        let requested = requestedIDs.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        if !requested.isEmpty {
            let loaded = Set(rows.compactMap { $0["id"] })
            rows += try db.rows("SELECT \(fields)\(delegateField)\(messageFields)\(previewFields) FROM sessions s \(whereSQL) AND s.id IN (\(requested.sorted().prefix(32).map(sqlLiteral).joined(separator: ",")))").filter { !loaded.contains($0["id"] ?? "") }
        }
        var leases: [String: Date] = [:]
        if tables.contains("session_turn_leases"),
           (try? db.columns("session_turn_leases").isSuperset(of: ["conversation_id", "expires_at"])) == true {
            for row in (try? db.rows("SELECT conversation_id,expires_at FROM session_turn_leases WHERE expires_at>\(now.timeIntervalSince1970) LIMIT 2000")) ?? [] {
                if let id = row["conversation_id"], let date = LocalFiles.date(row["expires_at"]), date > now { leases[id] = date }
            }
        }
        var parents: [String: String] = [:], compressionParents = Set<String>()
        var lineage: [[String: String]] = []
        var titles: [String: String] = [:]
        if cols.contains("parent_session_id") {
            let ids = rows.compactMap { $0["id"] }.map(sqlLiteral).joined(separator: ",")
            if !ids.isEmpty {
                let title = cols.contains("title") ? "s.title" : "s.id AS title"
                let rawSource = cols.contains("source") ? "s.source" : "NULL"
                let source = "CASE WHEN \(delegate) IS NOT NULL AND \(delegate)<>'' THEN 'subagent' ELSE \(rawSource) END AS source"
                let endReason = cols.contains("end_reason") ? "s.end_reason" : "NULL AS end_reason"
                // Ancestors are needed for compression leases; cap recursive depth and direct children.
                lineage = (try? db.rows("WITH RECURSIVE family(id,parent_session_id,end_reason,title,source,depth) AS (SELECT s.id,s.parent_session_id,\(endReason),\(title),\(source),0 FROM sessions s WHERE s.id IN (\(ids)) UNION ALL SELECT s.id,s.parent_session_id,\(endReason),\(title),\(source),f.depth+1 FROM sessions s JOIN family f ON s.id=f.parent_session_id WHERE f.depth<32) SELECT DISTINCT id,parent_session_id,end_reason,title,source FROM family LIMIT 4000")) ?? []
                lineage += (try? db.rows("SELECT s.id,s.parent_session_id,\(endReason),\(title),\(source) FROM sessions s WHERE parent_session_id IN (\(ids)) LIMIT 4000")) ?? []
                var seen = Set<String>()
                lineage = lineage.filter { seen.insert($0["id"] ?? "").inserted }
            }
            for row in lineage {
                if let id = row["id"] {
                    parents[id] = row["parent_session_id"]
                    titles[id] = LocalFiles.boundedTitle(row["title"], fallback: "Hermes \(id.prefix(20))")
                    if row["end_reason"] == "compression" { compressionParents.insert(id) }
                }
            }
        }
        var openPIDs: [String: Int32] = [:]
        if let registry = LocalFiles.object(root.appendingPathComponent("runtime/active_sessions.json")),
           let entries = registry["entries"] as? [[String: Any]] {
            for entry in entries {
                if let id = entry["session_id"] as? String, let pid = (entry["pid"] as? NSNumber)?.int32Value,
                   processes.matches(pid: pid) { openPIDs[id] = pid }
            }
        }
        let profile = root.lastPathComponent == "profiles" ? "default" : root.deletingLastPathComponent().lastPathComponent == "profiles" ? root.lastPathComponent : "default"
        var relations: [String: [RelatedSession]] = [:]
        for item in lineage {
            guard let child = item["id"], let parent = item["parent_session_id"], !parent.isEmpty else { continue }
            let compression = compressionParents.contains(parent)
            relations[child, default: []].append(RelatedSession(id: "hermes:\(root.path):\(parent)", title: titles[parent] ?? "Hermes \(parent.prefix(20))", kind: compression ? .continuedFrom : .parent))
            relations[parent, default: []].append(RelatedSession(id: "hermes:\(root.path):\(child)", title: titles[child] ?? "Hermes \(child.prefix(20))", kind: compression ? .continuedAs : item["source"] == "subagent" ? .subagent : .child))
        }
        return rows.compactMap { row in
            guard let id = row["id"] else { return nil }
            let updated = [LocalFiles.date(row["last_activity_at"]), LocalFiles.date(row["last_timestamp"]), LocalFiles.date(row["started_at"])].compactMap { $0 }.max() ?? .distantPast
            var session = Session(id: "hermes:\(root.path):\(id)", sessionID: id, app: .hermes,
                                  title: LocalFiles.boundedTitle(row["title"]?.nilIfEmpty ?? row["display_name"], fallback: "Hermes \(id.prefix(20))"),
                                  model: row["model"] ?? "", provider: row["billing_provider"] ?? "",
                                  workspace: row["cwd"]?.nilIfEmpty ?? row["git_repo_root"] ?? "", origin: "\(profile) · \(row["source"] ?? "local")",
                                  updatedAt: updated, sourcePath: path, pid: openPIDs[id], parentID: row["parent_session_id"]?.nilIfEmpty ?? row["delegate_parent"]?.nilIfEmpty, isOpen: openPIDs[id] != nil)
            var rootID = id, visited = Set<String>()
            while let parent = parents[rootID], compressionParents.contains(parent), visited.insert(rootID).inserted { rootID = parent }
            if LocalFiles.date(row["ended_at"]) != nil {
                session.state = row["end_reason"]?.lowercased().contains("error") == true ? .error : .ended
                session.confidence = .historical
                session.evidence = "Hermes recorded an end time\(row["end_reason"].map { " (\($0))" } ?? "")."
            } else if let expiry = leases[rootID] ?? leases[id] {
                session.state = .running; session.confidence = .estimated
                session.evidence = "Hermes holds a turn lease until \(expiry.formatted(date: .omitted, time: .standard)); this indicates ownership, not a live heartbeat."
            } else if row["last_role"] == "assistant", ["stop", "end_turn", "stop_sequence"].contains(row["last_finish_reason"] ?? "") {
                session.state = .responseReady; session.confidence = .historical
                session.completedAt = LocalFiles.date(row["last_timestamp"]) ?? updated
                session.evidence = "The last stored Hermes response finished and is available for review; no active turn lease was found."
            } else {
                session.state = .unknown; session.confidence = .unavailable
                session.evidence = session.isOpen ? "A local Hermes process has this session open, but its current turn state is unavailable." : "The stored session has no end time or active turn lease. Current state is unverified."
            }
            session.usage = TokenUsage(input: TokenUsage.number(row["input_tokens"]), output: TokenUsage.number(row["output_tokens"]),
                                       cacheRead: TokenUsage.number(row["cache_read_tokens"]), cacheWrite: TokenUsage.number(row["cache_write_tokens"]),
                                       reasoning: TokenUsage.number(row["reasoning_tokens"]),
                                       estimatedCostUSD: TokenUsage.cost(row["estimated_cost_usd"]), actualCostUSD: TokenUsage.cost(row["actual_cost_usd"]),
                                       costStatus: row["cost_status"] ?? "", coverage: "Stored session counters",
                                       note: "Tokens column is input + output. Cache and reasoning counters are separate provider records and are not added to that figure. Costs are labelled as stored; included means covered by a subscription.")
            session.record = SessionRecord(startedAt: LocalFiles.date(row["started_at"]), endedAt: LocalFiles.date(row["ended_at"]),
                                           outcome: row["end_reason"]?.nilIfEmpty,
                                           activity: row["last_activity_description"].map { String($0.prefix(1200)) },
                                           modelSource: row["model"]?.nilIfEmpty == nil ? nil : "Stored session model",
                                           costSource: row["cost_source"]?.nilIfEmpty,
                                           readCoverage: "Stored session counters and last conversation message",
                                           relationshipCoverage: "Direct relationships and up to 32 ancestors; reads capped at 4,000 rows")
            session.gitBranch = row["git_branch"] ?? ""
            session.relations = relations[id] ?? []
            if let parent = row["parent_session_id"]?.nilIfEmpty ?? row["delegate_parent"]?.nilIfEmpty {
                session.parentKey = "hermes:\(root.path):\(parent)"
                if !session.relations.contains(where: { $0.id == session.parentKey }) {
                    session.relations.append(RelatedSession(id: "hermes:\(root.path):\(parent)", title: titles[parent] ?? "Hermes \(parent.prefix(20))", kind: .parent, note: "Recorded delegation parent"))
                }
            }
            session.isSubagent = row["source"] == "subagent" || row["delegate_parent"]?.nilIfEmpty != nil
            if let text = row["preview_2"] {
                session.lastMessage = MessageText.stored(text, role: row["preview_0"] ?? "", at: LocalFiles.date(row["preview_1"]), sourceTruncated: (Int(row["preview_3"] ?? "0") ?? 0) > 20000)
            }
            return session
        }
    }
}
