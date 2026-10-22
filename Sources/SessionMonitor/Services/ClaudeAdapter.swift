import Foundation

enum ClaudeAdapter {
    static func scan(home: String, limit: Int, reader: TranscriptReader, processes: ProcessInventory, now: Date) throws -> [Session] {
        guard LocalFiles.exists(home) else { throw DatabaseError.failure("Claude Code data folder not found.") }
        var runtime: [String: [String: Any]] = [:]
        for file in LocalFiles.children(home + "/sessions") where file.pathExtension == "json" {
            guard let object = LocalFiles.object(file), let id = object["sessionId"] as? String else { continue }
            runtime[id] = object
        }
        var indexed: [String: [String: Any]] = [:]
        var transcripts: [String: URL] = [:]
        for directory in LocalFiles.children(home + "/projects") {
            let indexURL = directory.appendingPathComponent("sessions-index.json")
            if let object = LocalFiles.object(indexURL), let entries = object["entries"] as? [[String: Any]] {
                for entry in entries {
                    guard let id = entry["sessionId"] as? String, entry["isSidechain"] as? Bool != true else { continue }
                    indexed[id] = entry
                    if let path = entry["fullPath"] as? String { transcripts[id] = URL(fileURLWithPath: path) }
                }
            }
            // Top-level chats; parent-scoped subagents are discovered separately below.
            for file in LocalFiles.children(directory.path) where file.pathExtension == "jsonl" {
                transcripts[file.deletingPathExtension().lastPathComponent] = file
            }
        }
        let recentIDs = transcripts.keys.sorted {
            LocalFiles.modification(transcripts[$0]!) > LocalFiles.modification(transcripts[$1]!)
        }.prefix(limit)
        let ids = Set(recentIDs).union(runtime.keys)
        var sessions = ids.map { id in
            let live = runtime[id], index = indexed[id]
            let path = transcripts[id]?.path ?? ""
            let summary = reader.summary(path: path, app: .claude, now: now)
            let cwd = live?["cwd"] as? String ?? index?["projectPath"] as? String ?? summary.workspace
            let title = LocalFiles.boundedTitle(live?["name"] as? String ?? summary.title.nilIfEmpty ?? index?["summary"] as? String,
                                                fallback: "\(cwd.isEmpty ? "Claude session" : URL(fileURLWithPath: cwd).lastPathComponent) · \(id.prefix(8))")
            var session = Session(id: "claude:\(id)", sessionID: id, app: .claude, title: title,
                                  model: summary.model, provider: "", workspace: cwd,
                                  origin: live?["entrypoint"] as? String ?? "local transcript",
                                  state: summary.state, confidence: summary.confidence, evidence: summary.evidence,
                                  updatedAt: summary.lastEvent ?? LocalFiles.date(index?["modified"]) ?? transcripts[id].map(LocalFiles.modification) ?? .distantPast,
                                  sourcePath: path, completedAt: summary.completedAt, question: summary.question,
                                  usage: summary.usage, desktopSessionID: live?["hostSessionId"] as? String ?? "",
                                  lastMessage: summary.lastMessage, gitBranch: summary.gitBranch, record: summary.record)
            if let live, let pid = (live["pid"] as? NSNumber)?.int32Value {
                session.pid = pid
                session.record?.startedAt = LocalFiles.date(live["startedAt"])
                if processes.matches(pid: pid, start: live["procStart"] as? String) {
                    session.isOpen = true
                    session.state = runtimeState(live["status"] as? String)
                    session.confidence = session.state == .unknown ? .unavailable : .reported
                    if session.state == .idle, summary.state == .responseReady {
                        session.state = .responseReady; session.confidence = .historical
                    } else if [.idle, .running].contains(session.state), summary.state == .waitingForAnswer {
                        session.state = .waitingForAnswer; session.confidence = .estimated
                    }
                    let identity = live["procStart"] as? String != nil ? "PID \(pid) and UTC process start time were checked" : "PID \(pid) is present; this registry does not record a process start time"
                    session.evidence = "Claude Code reports ‘\(live["status"] as? String ?? "unavailable")’; \(identity)."
                    if [.responseReady, .waitingForAnswer].contains(session.state) { session.evidence += " " + summary.evidence }
                    session.updatedAt = max(session.updatedAt, LocalFiles.date(live["statusUpdatedAt"] ?? live["updatedAt"]) ?? .distantPast)
                } else {
                    session.state = .ended; session.confidence = .reported
                    session.evidence = "The process registered for this session is no longer running with the same identity."
                }
            }
            return session
        }
        // Subagent identity is scoped to its parent, never merged with an unrelated CLI session.
        var candidates: [(parent: String, file: URL)] = []
        for id in ids {
            guard let transcript = transcripts[id] else { continue }
            let folder = transcript.deletingPathExtension().appendingPathComponent("subagents")
            candidates += LocalFiles.children(folder.path).filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") }.map { (id, $0) }
        }
        let parentIndex = Dictionary(sessions.enumerated().map { ($0.element.sessionID, $0.offset) }, uniquingKeysWith: { old, _ in old })
        for candidate in candidates.sorted(by: { LocalFiles.modification($0.file) > LocalFiles.modification($1.file) }).prefix(limit) {
            guard let index = parentIndex[candidate.parent] else { continue }
            let parent = sessions[index]
            let agentID = String(candidate.file.deletingPathExtension().lastPathComponent.dropFirst(6))
            let key = "claude:\(candidate.parent):subagent:\(agentID)"
            let summary = reader.summary(path: candidate.file.path, app: .claude, now: now)
            let sidecar = LocalFiles.object(candidate.file.deletingPathExtension().appendingPathExtension("meta.json")) ?? [:]
            let role = sidecar["agentType"] as? String ?? summary.agentRole
            let description = String((sidecar["description"] as? String ?? "").prefix(1200))
            let title = LocalFiles.boundedTitle(summary.agentName.nilIfEmpty ?? description.nilIfEmpty, fallback: "Subagent · \(agentID)")
            var record = summary.record
            record.taskDescription = description.nilIfEmpty
            record.depth = TokenUsage.number(sidecar["spawnDepth"]).flatMap { Int(exactly: $0) }
            if summary.model.isEmpty, sidecar["model"] as? String != nil { record.modelSource = "Subagent sidecar · requested model" }
            sessions[index].relations.append(RelatedSession(id: key, title: title, kind: .subagent))
            sessions.append(Session(id: key, sessionID: agentID, app: .claude, title: title,
                                    model: summary.model.nilIfEmpty ?? sidecar["model"] as? String ?? "", provider: "", workspace: summary.workspace.nilIfEmpty ?? parent.workspace,
                                    origin: "subagent transcript", state: summary.state, confidence: summary.confidence, evidence: summary.evidence,
                                    updatedAt: summary.lastEvent ?? LocalFiles.modification(candidate.file), sourcePath: candidate.file.path,
                                    completedAt: summary.completedAt, question: summary.question, usage: summary.usage,
                                    lastMessage: summary.lastMessage, gitBranch: summary.gitBranch,
                                    relations: [RelatedSession(id: parent.id, title: parent.title, kind: .parent)],
                                    agentRole: role, agentNickname: summary.agentName, parentKey: parent.id, isSubagent: true, record: record))
        }
        return sessions
    }

    static func runtimeState(_ value: String?) -> SessionState {
        switch value?.lowercased() {
        case "busy", "running", "working", "thinking": .running
        case "idle": .idle
        case "waiting_for_permission", "waiting_permission", "permission", "permission_prompt": .approvalNeeded
        case "waiting_for_input", "waiting_for_answer": .waitingForAnswer
        case "needs_attention": .needsAttention
        case "error", "failed": .error
        case "ended", "exited", "stopped": .ended
        default: .unknown
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
