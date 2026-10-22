import XCTest
import SQLite3
@testable import SessionMonitor

final class T3AdapterTests: XCTestCase {
    private let environment = "00000000-0000-4000-8000-000000000001"
    private let stamp = "2026-10-23T12:00:00Z"
    private var now: Date { LocalFiles.date(stamp)! }

    func testV2DiscoveryUsesHostTitlesWorkspaceModelAndBoundedConversationMessages() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try thread(root, id: "chat", payload: ["worktreePath": "/example/worktree", "branch": "feature/example"])
        try run(root, thread: "chat", id: "active", status: "running")
        try message(root, thread: "chat", role: "assistant", text: String(repeating: "a", count: 9000), streaming: true)
        try message(root, thread: "chat", role: "tool", text: "Never display tool output", id: "z-tool")
        let before = try Data(contentsOf: database(root))
        let scan = try T3Adapter.scan(home: root.path, limit: 20, processes: inventory(), now: now)
        let session = try XCTUnwrap(scan.sessions.first)
        XCTAssertEqual(session.title, "Synthetic T3 chat")
        XCTAssertEqual(session.app, .t3)
        XCTAssertEqual(session.workspace, "/example/worktree")
        XCTAssertEqual(session.gitBranch, "feature/example")
        XCTAssertEqual(session.model, "synthetic-model")
        XCTAssertEqual(session.provider, "codex")
        XCTAssertEqual(session.environmentID, environment)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.confidence, .reported)
        XCTAssertEqual(session.lastMessage?.text.count, 8000)
        XCTAssertEqual(session.lastMessage?.truncated, true)
        XCTAssertTrue(session.lastMessage?.coverage.contains("streaming") == true)
        XCTAssertNil(session.usage, "Context occupancy must never become cumulative usage")
        XCTAssertEqual(try Data(contentsOf: database(root)), before, "Discovery must not change provider records")
        XCTAssertEqual(try T3Adapter.scan(home: root.appendingPathComponent("userdata").path, limit: 20, processes: inventory(), now: now).sessions.count, 1)
    }

    func testActiveRunOutranksQueuedFollowUpAndCompletedHistory() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try thread(root, id: "chat")
        try run(root, thread: "chat", id: "old", status: "completed", ordinal: 1)
        try run(root, thread: "chat", id: "active", status: "running", ordinal: 2)
        try run(root, thread: "chat", id: "queued", status: "queued", ordinal: 3)
        XCTAssertEqual(try scan(root).sessions.first?.state, .running)
        try execute(root, "UPDATE orchestration_v2_projection_runs SET status='completed' WHERE run_id='active'")
        let queued = try XCTUnwrap(scan(root).sessions.first)
        XCTAssertEqual(queued.state, .idle)
        XCTAssertTrue(queued.evidence.contains("queued"))
    }

    func testBlockingRequestsApprovalsAndPrivateInputHaveSeparateStates() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for id in ["question", "approval", "private", "background", "auth"] {
            try thread(root, id: id); try run(root, thread: id, id: id, status: "running")
        }
        try request(root, thread: "question", kind: "user_input")
        try request(root, thread: "approval", kind: "file-change")
        try request(root, thread: "background", kind: "user_input", response: "message")
        try request(root, thread: "auth", kind: "auth_refresh")
        try execute(root, "INSERT INTO orchestration_v2_projection_turn_items VALUES('private','private','secret_request','waiting')")
        let sessions = Dictionary(try scan(root).sessions.map { ($0.sessionID, $0.state) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(sessions["question"], .waitingForAnswer)
        XCTAssertEqual(sessions["approval"], .approvalNeeded)
        XCTAssertEqual(sessions["private"], .waitingForAnswer)
        XCTAssertEqual(sessions["background"], .running, "Nonblocking message input must not mark active work as waiting for the user")
        XCTAssertEqual(sessions["auth"], .needsAttention)
        try execute(root, "UPDATE orchestration_v2_projection_runtime_requests SET status='resolved'")
        XCTAssertEqual(try scan(root).sessions.first { $0.sessionID == "question" }?.state, .running)
    }

    func testStoppedOrReusedServerPIDCannotClaimActiveOrPendingChatsAreLive() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try thread(root, id: "active"); try run(root, thread: "active", id: "active", status: "running")
        try thread(root, id: "failed"); try run(root, thread: "failed", id: "failed", status: "failed")
        var processes = inventory(); processes.starts = [:]
        let sessions = try T3Adapter.scan(home: root.path, limit: 20, processes: processes, now: now).sessions
        XCTAssertEqual(sessions.first { $0.sessionID == "active" }?.state, .unknown)
        XCTAssertEqual(sessions.first { $0.sessionID == "failed" }?.state, .error)
        processes.starts = [12345: "Fri Oct 23 12:00:01 2026"]
        XCTAssertFalse(T3Adapter.serverIsRunning(directory: root.appendingPathComponent("userdata"), processes: processes, now: now))
        processes.starts = [12345: "Fri Oct 23 11:00:00 2026"]
        XCTAssertFalse(T3Adapter.serverIsRunning(directory: root.appendingPathComponent("userdata"), processes: processes, now: now))
    }

    func testArchivedAndDeletedChatsAreExcludedWhileSettledCompletionsAreIdle() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try thread(root, id: "ready"); try run(root, thread: "ready", id: "ready", status: "completed")
        try thread(root, id: "settled", payload: ["settledOverride": "settled"])
        try run(root, thread: "settled", id: "settled", status: "completed")
        try thread(root, id: "archived", payload: ["archivedAt": stamp])
        try thread(root, id: "deleted")
        try execute(root, "UPDATE orchestration_v2_projection_threads SET deleted_at=\(sqlLiteral(stamp)) WHERE thread_id='deleted'")
        let sessions = try scan(root).sessions
        XCTAssertEqual(Set(sessions.map(\.sessionID)), ["ready", "settled"])
        XCTAssertEqual(sessions.first { $0.sessionID == "ready" }?.state, .responseReady)
        XCTAssertNotNil(sessions.first { $0.sessionID == "ready" }?.completedAt)
        XCTAssertEqual(sessions.first { $0.sessionID == "settled" }?.state, .idle)
    }

    func testLineageDistinguishesForksAndSubagentsAndAllowsPinnedRelatedReads() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try thread(root, id: "parent", updated: "2026-10-20T12:00:00Z")
        try thread(root, id: "child", payload: ["lineage": ["parentThreadId": "parent", "relationshipToParent": "subagent"]])
        try thread(root, id: "fork", payload: ["lineage": ["parentThreadId": "parent", "relationshipToParent": "fork"]])
        let result = try scan(root)
        XCTAssertTrue(result.sessions.first { $0.sessionID == "child" }?.isSubagent == true)
        XCTAssertFalse(result.sessions.first { $0.sessionID == "fork" }?.isSubagent == true)
        XCTAssertEqual(result.sessions.first { $0.sessionID == "fork" }?.relations.first?.kind, .forkedFrom)
        let parentKey = "t3:\(environment):parent"
        let limited = try T3Adapter.scan(home: root.path, limit: 1, processes: inventory(), now: now, requestedIDs: [parentKey])
        XCTAssertEqual(limited.sessions.count, 2)
        XCTAssertTrue(limited.sessions.contains { $0.id == parentKey })
    }

    func testOnlyUnambiguousStrongNativeReferencesLinkProviderRecords() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try thread(root, id: "host")
        try native(root, thread: "host", id: "native-one", strength: "strong")
        try native(root, thread: "host", id: "weak", strength: "weak")
        try native(root, thread: "host", id: "worker", strength: "strong", owner: "worker-node")
        let result = try scan(root)
        XCTAssertEqual(result.nativeOwners.keys.sorted(), ["codex:native-one"])
        let provider = Session(id: "codex:native-one", sessionID: "native-one", app: .codex, title: "Native record", updatedAt: now, usage: TokenUsage(total: 50))
        var sessions = result.sessions + [provider]
        T3Adapter.linkNativeSessions(&sessions, owners: result.nativeOwners)
        XCTAssertEqual(sessions.last?.hostSessionID, sessions.first?.id)
        XCTAssertEqual(sessions.first?.relations.last?.kind, .providerSession)
        XCTAssertEqual(sessions.last?.usage?.total, 50)
        XCTAssertTrue(SessionArchive.unavailableReason(sessions.last!, codexHome: root.path, executablePath: "/example/codex")?.contains("T3 Code") == true)
        XCTAssertNil(sessions.first?.usage)
        XCTAssertEqual(DailyTokenUsage.buckets(sessions: sessions, now: now).reduce(0) { $0 + $1.value }, 50)
        var ambiguous = result.sessions + [provider]
        T3Adapter.linkNativeSessions(&ambiguous, owners: [provider.id: [result.sessions[0].id, "another-host"]])
        XCTAssertNil(ambiguous.last?.hostSessionID)
    }

    @MainActor func testCombinedListShowsHostOnceAndNativeCountersRemainSelectable() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "T3Fixture-" + UUID().uuidString))
        let store = SessionStore(library: SessionLibrary(url: root.appendingPathComponent("library.json")), reviewDefaults: defaults)
        store.preferences = MonitorPreferences(defaults: defaults)
        store.preferences.days = 0
        let host = Session(id: "t3:host", sessionID: "host", app: .t3, title: "Host", state: .running, updatedAt: now)
        var provider = Session(id: "codex:native", sessionID: "native", app: .codex, title: "Native", state: .running, updatedAt: now)
        provider.hostSessionID = host.id
        store.snapshot.sessions = [host, provider]
        XCTAssertEqual(store.visibleSessions.map(\.id), [host.id])
        XCTAssertEqual(store.runningCount, 1)
        store.scope = .app(.codex)
        XCTAssertEqual(store.visibleSessions.map(\.id), [provider.id])
        store.selectRelated(provider.id)
        XCTAssertEqual(store.selectedSession?.id, provider.id)
        XCTAssertEqual(store.visibleSessions.map(\.id), [provider.id])
        store.snapshot.sessions = [provider]; store.scope = .all
        XCTAssertEqual(store.visibleSessions.map(\.id), [provider.id], "Without a loaded host, the native record must remain visible")
        var childHost = host; childHost.id = "t3:child"; childHost.isSubagent = true
        var childProvider = provider; childProvider.id = "codex:child"; childProvider.isSubagent = true; childProvider.hostSessionID = childHost.id
        store.snapshot.sessions = [host, childHost, childProvider]; store.scope = .subagents
        XCTAssertEqual(store.recentSubagents.count, 1)
        XCTAssertEqual(store.visibleSessions.map(\.id), [childHost.id])
        store.selectRelated(childProvider.id)
        XCTAssertEqual(store.visibleSessions.map(\.id), [childProvider.id])
    }

    func testT3LinksValidateIdentityAndNeverResumeProviderCLI() throws {
        var session = Session(id: "t3:chat", sessionID: "chat-1", app: .t3, title: "Host", updatedAt: now, environmentID: environment)
        XCTAssertEqual(DesktopActions.sessionURL(session)?.absoluteString, "t3code://threads/\(environment)/chat-1")
        XCTAssertNil(DesktopActions.resumeCommand(session))
        session.sessionID = "chat?prompt=unwanted"
        XCTAssertNil(DesktopActions.sessionURL(session))
        session.sessionID = "../chat"
        XCTAssertNil(DesktopActions.sessionURL(session))
        session.sessionID = "chat"; session.environmentID = "invalid/environment"
        XCTAssertNil(DesktopActions.sessionURL(session))
    }

    func testMissingV2DoesNotReadTheStaleLegacyDatabase() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.moveItem(at: database(root), to: root.appendingPathComponent("userdata/state.sqlite"))
        XCTAssertThrowsError(try scan(root)) { XCTAssertTrue($0.localizedDescription.contains("V2")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: database(root).path))
    }

    private func inventory() -> ProcessInventory {
        var result = ProcessInventory(); result.starts = [12345: "Fri Oct 23 12:00:00 2026"]; return result
    }
    private func scan(_ root: URL) throws -> T3Adapter.ScanResult { try T3Adapter.scan(home: root.path, limit: 20, processes: inventory(), now: now) }
    private func database(_ root: URL) -> URL { root.appendingPathComponent("userdata/statev2.sqlite") }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("T3Fixture-" + UUID().uuidString)
        let data = root.appendingPathComponent("userdata")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(environment.utf8).write(to: data.appendingPathComponent("environment-id"))
        try JSONSerialization.data(withJSONObject: ["pid": 12345, "startedAt": stamp]).write(to: data.appendingPathComponent("server-runtime.json"))
        try execute(root, """
        CREATE TABLE projection_projects(project_id TEXT PRIMARY KEY,workspace_root TEXT);
        INSERT INTO projection_projects VALUES('project','/example/project');
        CREATE TABLE orchestration_v2_projection_threads(thread_id TEXT PRIMARY KEY,project_id TEXT,title TEXT,created_at TEXT,updated_at TEXT,archived_at TEXT,deleted_at TEXT,payload_json TEXT);
        CREATE TABLE orchestration_v2_projection_runs(run_id TEXT PRIMARY KEY,thread_id TEXT,ordinal INTEGER,status TEXT,requested_at TEXT,completed_at TEXT,payload_json TEXT);
        CREATE TABLE orchestration_v2_projection_messages(message_id TEXT PRIMARY KEY,thread_id TEXT,role TEXT,streaming INTEGER,created_at TEXT,updated_at TEXT,payload_json TEXT);
        CREATE TABLE orchestration_v2_projection_runtime_requests(thread_id TEXT,status TEXT,kind TEXT,created_at TEXT,payload_json TEXT);
        CREATE TABLE orchestration_v2_projection_turn_items(thread_id TEXT,run_id TEXT,type TEXT,status TEXT);
        CREATE TABLE orchestration_v2_projection_provider_threads(thread_id TEXT,owner_node_id TEXT,payload_json TEXT);
        """)
        return root
    }
    private func thread(_ root: URL, id: String, payload: [String: Any] = [:], updated: String? = nil) throws {
        var object: [String: Any] = ["modelSelection": ["instanceId": "codex", "model": "synthetic-model"]]
        object.merge(payload) { _, new in new }
        try execute(root, "INSERT INTO orchestration_v2_projection_threads VALUES(\(sqlLiteral(id)),'project','Synthetic T3 chat',\(sqlLiteral(stamp)),\(sqlLiteral(updated ?? stamp)),NULL,NULL,\(try json(object)))")
    }
    private func run(_ root: URL, thread: String, id: String, status: String, ordinal: Int = 1) throws {
        try execute(root, "INSERT INTO orchestration_v2_projection_runs VALUES(\(sqlLiteral(id)),\(sqlLiteral(thread)),\(ordinal),\(sqlLiteral(status)),\(sqlLiteral(stamp)),\(status == "completed" ? sqlLiteral(stamp) : "NULL"),'{}')")
    }
    private func message(_ root: URL, thread: String, role: String, text: String, id: String = "message", streaming: Bool = false) throws {
        try execute(root, "INSERT INTO orchestration_v2_projection_messages VALUES(\(sqlLiteral(id)),\(sqlLiteral(thread)),\(sqlLiteral(role)),\(streaming ? 1 : 0),\(sqlLiteral(stamp)),\(sqlLiteral(stamp)),\(try json(["text": text])))")
    }
    private func request(_ root: URL, thread: String, kind: String, response: String = "live") throws {
        try execute(root, "INSERT INTO orchestration_v2_projection_runtime_requests VALUES(\(sqlLiteral(thread)),'pending',\(sqlLiteral(kind)),\(sqlLiteral(stamp)),\(try json(["responseCapability": ["type": response]])))")
    }
    private func native(_ root: URL, thread: String, id: String, strength: String, owner: String? = nil) throws {
        try execute(root, "INSERT INTO orchestration_v2_projection_provider_threads VALUES(\(sqlLiteral(thread)),\(owner.map(sqlLiteral) ?? "NULL"),\(try json(["nativeThreadRef": ["driver": "codex", "nativeId": id, "strength": strength], "contextUsage": ["usedTokens": 999]])))")
    }
    private func json(_ value: [String: Any]) throws -> String { sqlLiteral(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)) }
    private func execute(_ root: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database(root).path, &db) == SQLITE_OK else { throw DatabaseError.failure("Fixture open failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.failure(String(cString: sqlite3_errmsg(db))) }
    }
}
