import Foundation

/// Reads only bounded V2 projection records. Never starts T3, replays events,
/// reads authentication, or treats context-window occupancy as cumulative usage.
enum T3Adapter {
    struct ScanResult {
        var sessions: [Session]
        var nativeOwners: [String: Set<String>] = [:]
    }
    private static let threads = "orchestration_v2_projection_threads"
    private static let runs = "orchestration_v2_projection_runs"
    private static let messages = "orchestration_v2_projection_messages"
    private static let requests = "orchestration_v2_projection_runtime_requests"
    private static let providerThreads = "orchestration_v2_projection_provider_threads"

    static func scan(home: String, limit: Int, processes: ProcessInventory, now: Date, requestedIDs: Set<String> = []) throws -> ScanResult {
        guard !home.isEmpty else { return ScanResult(sessions: []) }
        let root = URL(fileURLWithPath: home)
        let nested = root.appendingPathComponent("userdata/statev2.sqlite")
        let file = LocalFiles.exists(nested.path) ? nested : root.appendingPathComponent("statev2.sqlite")
        guard LocalFiles.exists(file.path) else {
            throw DatabaseError.failure("No T3 Code V2 database found. Open T3 Code V2 once, or select its home (or userdata) folder in Settings. Legacy state.sqlite is not used.")
        }
        let directory = file.deletingLastPathComponent()
        let db = try ReadOnlyDatabase(path: file.path)
        _ = try db.rows("BEGIN DEFERRED TRANSACTION")
        defer { _ = try? db.rows("ROLLBACK") }
        let required: [(String, Set<String>)] = [
            (threads, ["thread_id", "project_id", "title", "created_at", "updated_at", "archived_at", "deleted_at", "payload_json"]),
            (runs, ["run_id", "thread_id", "ordinal", "status", "requested_at", "completed_at", "payload_json"]),
            (messages, ["message_id", "thread_id", "role", "streaming", "created_at", "updated_at", "payload_json"])
        ]
        for (table, columns) in required {
            guard try db.columns(table).isSuperset(of: columns) else { throw DatabaseError.failure("Unrecognized T3 Code V2 projection schema (\(table)).") }
        }
        let tables = try db.tables()
        let environment = LocalFiles.boundedData(directory.appendingPathComponent("environment-id"), maximum: 128)
            .flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentID = environment.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
        let prefix = "t3:\(environmentID ?? directory.standardizedFileURL.path):"
        let serverRunning = serverIsRunning(directory: directory, processes: processes, now: now)
        let activeFilter = "deleted_at IS NULL AND archived_at IS NULL AND CASE WHEN json_valid(payload_json) THEN json_extract(payload_json,'$.archivedAt') IS NULL AND json_extract(payload_json,'$.deletedAt') IS NULL ELSE 1 END"
        let fields = "thread_id, project_id, substr(title,1,1000) AS title, created_at, updated_at, substr(payload_json,1,65536) AS payload_json"
        var rows = try db.rows("SELECT \(fields) FROM \(threads) WHERE \(activeFilter) ORDER BY updated_at DESC,thread_id LIMIT \(max(1, min(2000, limit)))")
        let pinned = requestedIDs.filter { $0.hasPrefix(prefix) }.sorted().prefix(32).map { sqlLiteral(String($0.dropFirst(prefix.count))) }
        if !pinned.isEmpty {
            let loaded = Set(rows.compactMap { $0["thread_id"] })
            rows += try db.rows("SELECT \(fields) FROM \(threads) WHERE \(activeFilter) AND thread_id IN (\(pinned.joined(separator: ",")))")
                .filter { !loaded.contains($0["thread_id"] ?? "") }
        }
        let titles = Dictionary(rows.compactMap { row -> (String, String)? in
            guard let id = row["thread_id"] else { return nil }; return (id, LocalFiles.boundedTitle(row["title"], fallback: "T3 chat"))
        }, uniquingKeysWith: { first, _ in first })
        let projects = try tables.contains("projection_projects") && db.columns("projection_projects").isSuperset(of: ["project_id", "workspace_root"])
        let hasRequests = try tables.contains(requests) && db.columns(requests).isSuperset(of: ["thread_id", "status", "kind", "created_at", "payload_json"])
        let items = "orchestration_v2_projection_turn_items"
        let hasItems = try tables.contains(items) && db.columns(items).isSuperset(of: ["thread_id", "run_id", "type", "status"])
        var usage: [String: T3UsageReader.Totals] = [:], usageError: String?
        do { usage = try T3UsageReader.read(db: db, threadIDs: rows.compactMap { $0["thread_id"] }) }
        catch { usageError = error.localizedDescription }
        var result = ScanResult(sessions: [])
        for row in rows {
            guard let id = row["thread_id"] else { continue }
            let key = prefix + id, literal = sqlLiteral(id), payload = object(row["payload_json"])
            // An active run outranks a queued follow-up, which outranks completed history.
            let run = try db.rows("SELECT run_id,status,requested_at,completed_at,substr(payload_json,1,16384) AS payload_json FROM \(runs) WHERE thread_id=\(literal) ORDER BY CASE WHEN status IN ('preparing','starting','running','waiting') THEN 0 WHEN status='queued' THEN 1 ELSE 2 END, ordinal DESC LIMIT 1").first ?? [:]
            let runPayload = object(run["payload_json"])
            let active = ["preparing", "starting", "running", "waiting"].contains(run["status"] ?? "")
            let message = try db.rows("SELECT role,streaming,created_at,updated_at,CASE WHEN json_valid(payload_json) THEN substr(json_extract(payload_json,'$.text'),1,8001) END AS text FROM \(messages) WHERE thread_id=\(literal) AND role IN ('user','assistant') ORDER BY created_at DESC,message_id DESC LIMIT 1").first
            let pending = hasRequests ? try db.rows("SELECT kind,CASE WHEN json_valid(payload_json) THEN json_extract(payload_json,'$.responseCapability.type') END AS response_type FROM \(requests) WHERE thread_id=\(literal) AND status='pending' ORDER BY created_at DESC LIMIT 32") : []
            let secretPending = hasItems && active && run["run_id"] != nil ? !(try db.rows("SELECT 1 FROM \(items) WHERE thread_id=\(literal) AND run_id=\(sqlLiteral(run["run_id"]!)) AND type='secret_request' AND status='waiting' LIMIT 1")).isEmpty : false
            var workspace = payload["worktreePath"] as? String ?? ""
            if workspace.isEmpty, projects, let project = row["project_id"] {
                workspace = try db.rows("SELECT substr(workspace_root,1,4096) AS workspace_root FROM projection_projects WHERE project_id=\(sqlLiteral(project)) LIMIT 1").first?["workspace_root"] ?? ""
            }
            let completed = run["status"] == "completed" ? LocalFiles.date(run["completed_at"]) : nil
            let updated = [LocalFiles.date(row["updated_at"]), LocalFiles.date(message?["updated_at"]),
                           LocalFiles.date(run["requested_at"]), LocalFiles.date(run["completed_at"])].compactMap { $0 }.max() ?? .distantPast
            let runSelection = runPayload["modelSelection"] as? [String: Any] ?? [:]
            let selection = payload["modelSelection"] as? [String: Any] ?? [:]
            var session = Session(id: key, sessionID: id, app: .t3, title: titles[id] ?? "T3 chat",
                                  model: runSelection["model"] as? String ?? selection["model"] as? String ?? "",
                                  provider: runSelection["instanceId"] as? String ?? selection["instanceId"] as? String ?? payload["providerInstanceId"] as? String ?? "",
                                  workspace: workspace, origin: "T3 Code V2", updatedAt: updated,
                                  sourcePath: file.path, completedAt: completed, usage: usage[id]?.usage, gitBranch: payload["branch"] as? String ?? "",
                                  record: SessionRecord(startedAt: LocalFiles.date(row["created_at"]), outcome: run["status"],
                                                        modelSource: "T3 Code run / thread selection",
                                                        readCoverage: "Read-only T3 V2 projections and latest local message (up to 8,000 characters). Inherited fork history may be absent. Usage sums recorded turn consumption; context occupancy is not a cumulative token total.\(usageError.map { " Consumption unavailable: " + $0 } ?? "")",
                                                        relationshipCoverage: "Explicit lineage for loaded T3 chats and strong native-thread references"),
                                  environmentID: environmentID)
            let blockingInput = pending.contains { $0["kind"] == "user_input" && ($0["response_type"] != "message" || !active) }
            let approvals = pending.contains { ["command", "file-read", "file-change", "mcp-elicitation", "permission"].contains($0["kind"] ?? "") }
            session.confidence = serverRunning ? .reported : .historical
            session.evidence = "T3 Code recorded \(run["status"] ?? "no run") in its local V2 projections. "
            if blockingInput || secretPending { session.state = .waitingForAnswer }
            else if approvals { session.state = .approvalNeeded }
            else if pending.contains(where: { $0["kind"] == "auth_refresh" }) { session.state = .needsAttention }
            else {
                switch run["status"] {
                case "preparing", "starting", "running", "waiting": session.state = .running
                case "completed": session.state = completed == nil || payload["settledOverride"] as? String == "settled" ? .idle : .responseReady
                case "failed": session.state = .error
                case "queued", "interrupted", "cancelled", "rolled_back": session.state = .idle
                case nil: session.state = .idle
                default: session.state = .unknown; session.confidence = .unavailable
                }
            }
            if serverRunning {
                session.evidence += "The recorded local server PID and start time match a running process; this is the app's reported state, not independent proof of provider activity."
                session.isOpen = active || session.state == .waitingForAnswer || session.state == .approvalNeeded
            } else {
                session.evidence += "The local server process could not be verified; active or pending states may be stale."
                if active || blockingInput || secretPending || approvals || pending.contains(where: { $0["kind"] == "auth_refresh" }) {
                    session.state = .unknown; session.confidence = .unavailable
                }
            }
            if run["status"] == "queued" { session.evidence += " The next run is queued; it has not started." }
            if let snoozed = LocalFiles.date(payload["snoozedUntil"]), snoozed > now { session.evidence += " Snoozed in T3 Code." }
            if let message {
                session.lastMessage = MessageText.preview(message["text"], role: message["role"] ?? "assistant", at: LocalFiles.date(message["updated_at"]),
                                                          coverage: "Latest local T3 Code message\(message["streaming"] == "1" ? " · streaming / incomplete" : "")")
            }
            let lineage = payload["lineage"] as? [String: Any] ?? [:]
            if let parent = lineage["parentThreadId"] as? String, parent != id {
                session.parentID = parent; session.parentKey = prefix + parent
                session.isSubagent = lineage["relationshipToParent"] as? String == "subagent"
                session.relations.append(RelatedSession(id: prefix + parent, title: titles[parent] ?? "T3 parent chat", kind: session.isSubagent ? .parent : .forkedFrom, note: "Explicit T3 chat lineage"))
            }
            result.sessions.append(session)
        }
        if tables.contains(providerThreads), try db.columns(providerThreads).isSuperset(of: ["thread_id", "owner_node_id", "payload_json"]), !rows.isEmpty {
            let ids = rows.compactMap { $0["thread_id"] }.map(sqlLiteral).joined(separator: ",")
            let nativeRows = try db.rows("SELECT thread_id,substr(payload_json,1,16384) AS payload_json FROM \(providerThreads) WHERE thread_id IN (\(ids)) AND owner_node_id IS NULL LIMIT 4001")
            for row in nativeRows.prefix(4000) {
                guard let host = row["thread_id"], let ref = object(row["payload_json"])["nativeThreadRef"] as? [String: Any],
                      ref["strength"] as? String == "strong", let native = ref["nativeId"] as? String, !native.isEmpty,
                      let driver = ref["driver"] as? String, ["codex", "claudeAgent", "claude", "claude-code"].contains(driver) else { continue }
                let app = driver == "codex" ? "codex" : "claude"
                result.nativeOwners[app + ":" + native, default: []].insert(prefix + host)
            }
            if nativeRows.count > 4000 {
                for index in result.sessions.indices { result.sessions[index].record?.relationshipCoverage = "Partial: native-thread references capped at 4,000" }
            }
        }
        return result
    }

    static func linkNativeSessions(_ sessions: inout [Session], owners: [String: Set<String>]) {
        let positions = Dictionary(sessions.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for index in sessions.indices where sessions[index].app != .t3 {
            guard let matches = owners[sessions[index].id], matches.count == 1,
                  let hostID = matches.first, let host = positions[hostID], sessions[host].app == .t3 else { continue }
            sessions[index].hostSessionID = hostID
            sessions[index].relations.append(RelatedSession(id: hostID, title: sessions[host].title, kind: .host, note: "Exact native-thread identity reported by T3 Code"))
            sessions[host].relations.append(RelatedSession(id: sessions[index].id, title: sessions[index].title, kind: .providerSession, note: "Provider counters and transcript metadata; the T3 chat supplies the host's title and run state"))
        }
    }

    static func serverIsRunning(directory: URL, processes: ProcessInventory, now: Date) -> Bool {
        guard let runtime = LocalFiles.object(directory.appendingPathComponent("server-runtime.json")),
              let rawPID = runtime["pid"] as? NSNumber, let pid = Int32(exactly: rawPID.int64Value), pid > 0,
              let recorded = LocalFiles.date(runtime["startedAt"]), recorded <= now.addingTimeInterval(60),
              let rawStart = processes.starts[pid] else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard let start = formatter.date(from: rawStart) else { return false }
        // Runtime metadata is written shortly after process creation. Reject PID reuse.
        return (0...120).contains(recorded.timeIntervalSince(start))
    }

    private static func object(_ text: String?) -> [String: Any] {
        guard let text, let data = text.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
