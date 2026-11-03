import Foundation

actor SessionCollector {
    private let reader = TranscriptReader()
    private let worktrees = WorktreeReader()
    private var usageCache: [UsageOverview] = []
    private var usageReadAt = Date.distantPast
    private var usagePaths = ""
    func expandedDetails(_ session: Session) -> ExpandedRecord? {
        guard [.codex, .claude].contains(session.app), !session.savedBookmark else { return nil }
        let summary = reader.summary(path: session.sourcePath, app: session.app, now: Date(), expanded: true)
        guard summary.record.transcriptBytes != nil else { return nil }
        return ExpandedRecord(summary: summary)
    }
    func scan(_ configuration: ScanConfiguration, requestedRelated: Set<String> = []) -> SessionSnapshot {
        let start = Date(), processes = ProcessInventory()
        var snapshot = SessionSnapshot(scannedAt: start)
        let limit = min(2000, max(20, configuration.limit))
        let sources: [(AgentApp, String)] = [(.codex, configuration.codexHome), (.claude, configuration.claudeHome), (.hermes, configuration.hermesHome), (.t3, configuration.t3Home), (.harness, configuration.harnessDirectory)]
        var nativeOwners: [String: Set<String>] = [:]
        for (app, rawPath) in sources {
            let path = LocalFiles.expanded(rawPath)
            do {
                let sessions: [Session]
                var warnings: [String] = []
                switch app {
                case .codex: sessions = try CodexAdapter.scan(home: path, limit: limit, reader: reader, now: start, requestedIDs: Set(requestedRelated.filter { $0.hasPrefix("codex:") }.map { String($0.dropFirst(6)) }))
                case .claude: sessions = try ClaudeAdapter.scan(home: path, limit: limit, reader: reader, processes: processes, now: start)
                case .hermes:
                    let result = try HermesAdapter.scanWithHealth(home: path, limit: limit, processes: processes, now: start, requestedIDs: requestedRelated)
                    sessions = result.sessions
                    warnings = result.warnings
                case .harness: sessions = try HarnessAdapter.scan(directory: path, limit: limit, now: start)
                case .t3:
                    let result = try T3Adapter.scan(home: path, limit: limit, processes: processes, now: start, requestedIDs: requestedRelated)
                    sessions = result.sessions
                    nativeOwners = result.nativeOwners
                }
                snapshot.sessions += sessions
                let note: String
                switch app {
                case .codex: note = "Read-only session index + bounded event tails. Live state is estimated; no control socket is used."
                case .claude: note = "Local runtime registries with process identity checks + recent transcript metadata. Claude Code sessions and recent parent-linked subagent transcripts."
                case .hermes: note = "Read-only databases for the root and named profiles. Turn leases are activity estimates."
                case .t3: note = "Read-only V2 chats, runs, messages and recorded turn consumption. Active states require a matching local server process. Exact provider records are linked; T3 usage is a hosting view that overlaps provider archive totals."
                case .harness: note = sessions.isEmpty ? "Ready for reports. Connect your harness using script/report_session.py." : "Local JSON reports with heartbeat expiry."
                }
                let message = warnings.isEmpty ? note : note + " Some profiles are unavailable: " + warnings.joined(separator: "; ")
                snapshot.sources.append(SourceHealth(app: app, count: sessions.count, available: warnings.isEmpty, message: message, path: path))
            } catch {
                snapshot.sources.append(SourceHealth(app: app, count: 0, available: false, message: error.localizedDescription, path: path))
            }
        }
        T3Adapter.linkNativeSessions(&snapshot.sessions, owners: nativeOwners)
        // Add reverse startup/fork lineage only when the target is actually loaded.
        let positions = Dictionary(snapshot.sessions.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { old, _ in old })
        let originals = snapshot.sessions
        for session in originals {
            for relation in session.relations where [.parent, .forkedFrom].contains(relation.kind) {
                guard let index = positions[relation.id], !snapshot.sessions[index].relations.contains(where: { $0.id == session.id }) else { continue }
                snapshot.sessions[index].relations.append(RelatedSession(id: session.id, title: session.title, kind: relation.kind == .parent ? .subagent : .forkedAs, note: relation.note))
            }
        }
        for index in snapshot.sessions.indices {
            snapshot.sessions[index].worktree = worktrees.inspect(workspace: snapshot.sessions[index].workspace, now: start)
        }
        snapshot.sessions.sort {
            $0.state.priority == $1.state.priority ? $0.updatedAt > $1.updatedAt : $0.state.priority < $1.state.priority
        }
        let paths = [configuration.codexHome, configuration.claudeHome, configuration.hermesHome, configuration.t3Home].joined(separator: "\u{0}")
        if start.timeIntervalSince(usageReadAt) >= 60 || paths != usagePaths {
            usageCache = UsageReader.scan(configuration); usageReadAt = start; usagePaths = paths
        }
        snapshot.usage = usageCache
        snapshot.duration = Date().timeIntervalSince(start)
        return snapshot
    }
}
