import XCTest
import SQLite3
import Darwin
@testable import SessionMonitor

final class StatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCompletedCodexTurnIsHistoryRatherThanRunning() {
        let result = TranscriptReader.reduce(objects: [
            event("task_started"), event("task_complete"), event("item_completed")
        ], app: .codex)
        XCTAssertEqual(result.state, .responseReady)
        XCTAssertEqual(result.confidence, .historical)
    }

    func testNewTurnReplacesPreviousCompletion() {
        let result = TranscriptReader.reduce(objects: [event("task_complete"), event("task_started")], app: .codex)
        XCTAssertEqual(result.state, .running)
        XCTAssertEqual(result.confidence, .estimated)
    }

    func testStaleCodexActivityBecomesUnknown() {
        let raw = TranscriptReader.reduce(objects: [event("task_started")], app: .codex)
        XCTAssertEqual(TranscriptReader.age(raw, now: now.addingTimeInterval(601)).state, .unknown)
        XCTAssertEqual(TranscriptReader.age(raw, now: now.addingTimeInterval(10)).state, .running)
        XCTAssertEqual(TranscriptReader.age(raw, now: now.addingTimeInterval(-120)).state, .unknown)
    }

    func testInterruptedTurnDoesNotClaimConversationEnded() {
        let result = TranscriptReader.reduce(objects: [event("task_started"), event("turn_aborted")], app: .codex)
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.confidence, .historical)
    }

    func testUnknownClaudeStatusFailsToUnknown() {
        XCTAssertEqual(ClaudeAdapter.runtimeState("some_new_provider_state"), .unknown)
        XCTAssertEqual(ClaudeAdapter.runtimeState("busy"), .running)
        XCTAssertEqual(ClaudeAdapter.runtimeState("waiting_for_permission"), .approvalNeeded)
    }

    func testStaleAndFutureHarnessReportsCannotClaimRunning() {
        var object: [String: Any] = ["session_id": "one", "state": "running", "observed_at": now.timeIntervalSince1970]
        XCTAssertEqual(HarnessAdapter.parse(object, path: "fixture", now: now)?.state, .running)
        XCTAssertEqual(HarnessAdapter.parse(object, path: "fixture", now: now.addingTimeInterval(181))?.state, .unknown)
        XCTAssertEqual(HarnessAdapter.parse(object, path: "fixture", now: now.addingTimeInterval(-120))?.state, .unknown)
        object["state"] = "ended"
        XCTAssertEqual(HarnessAdapter.parse(object, path: "fixture", now: now.addingTimeInterval(10_000))?.state, .ended)
    }

    func testHarnessNamespacesKeepSameIDsDistinct() {
        let base: [String: Any] = ["session_id": "same", "state": "idle", "observed_at": now.timeIntervalSince1970]
        let a = HarnessAdapter.parse(base.merging(["namespace": "first"]) { _, new in new }, path: "a", now: now)
        let b = HarnessAdapter.parse(base.merging(["namespace": "second"]) { _, new in new }, path: "b", now: now)
        XCTAssertNotEqual(a?.id, b?.id)
    }

    func testMalformedHarnessReportsAreRejected() {
        XCTAssertNil(HarnessAdapter.parse(["session_id": "x", "state": "running"], path: "fixture", now: now))
        XCTAssertNil(HarnessAdapter.parse(["session_id": "x", "state": "new-state", "observed_at": 1800000000], path: "fixture", now: now))
    }

    func testTranscriptTailSkipsTruncatedAndMalformedLinesAndCacheStillAges() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("session.jsonl")
        var data = Data(String(repeating: "x", count: 180000).utf8)
        data.append(Data("\nnot-json\n".utf8))
        data.append(try JSONSerialization.data(withJSONObject: event("task_started")))
        data.append(10)
        try data.write(to: path)
        let reader = TranscriptReader()
        XCTAssertEqual(reader.summary(path: path.path, app: .codex, now: now).state, .running)
        XCTAssertEqual(reader.summary(path: path.path, app: .codex, now: now.addingTimeInterval(601)).state, .unknown)
    }

    func testReadOnlyDatabaseCannotWriteOrCreate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("fixture.db").path
        try createDatabase(path, sql: "CREATE TABLE sample(id INTEGER); INSERT INTO sample VALUES(1);")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let db = try ReadOnlyDatabase(path: path)
        XCTAssertEqual(try db.rows("SELECT COUNT(*) AS count FROM sample").first?["count"], "1")
        XCTAssertThrowsError(try db.rows("INSERT INTO sample VALUES(2)"))
        XCTAssertEqual(before, try Data(contentsOf: URL(fileURLWithPath: path)))
        let missing = root.appendingPathComponent("missing.db").path
        XCTAssertThrowsError(try ReadOnlyDatabase(path: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    func testHermesExpiredLeaseAndUnendedRowAreNotProofOfRunning() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createDatabase(root.appendingPathComponent("state.db").path, sql: hermesSchema + """
        INSERT INTO sessions VALUES('old', 'Old', 1799999900, NULL, NULL, NULL, NULL);
        INSERT INTO session_turn_leases VALUES('old', 1799999999);
        """)
        let sessions = try HermesAdapter.scan(home: root.path, limit: 20, processes: ProcessInventory(), now: now)
        XCTAssertEqual(sessions.first?.state, .unknown)
    }

    func testHermesCompressionChildUsesConversationLease() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createDatabase(root.appendingPathComponent("state.db").path, sql: hermesSchema + """
        INSERT INTO sessions VALUES('root', 'Root', 1799999800, 1799999900, 'compression', NULL, NULL);
        INSERT INTO sessions VALUES('child', 'Child', 1799999900, NULL, NULL, 'root', NULL);
        INSERT INTO session_turn_leases VALUES('root', 1800000100);
        """)
        let sessions = try HermesAdapter.scan(home: root.path, limit: 20, processes: ProcessInventory(), now: now)
        XCTAssertEqual(sessions.first { $0.sessionID == "child" }?.state, .running)
        XCTAssertEqual(sessions.first { $0.sessionID == "child" }?.confidence, .estimated)
        XCTAssertEqual(sessions.first { $0.sessionID == "root" }?.state, .ended)
    }

    func testBrokenHermesProfileDoesNotHideOtherSessions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createDatabase(root.appendingPathComponent("state.db").path, sql: hermesSchema + "INSERT INTO sessions VALUES('good', 'Good', 1799999900, NULL, NULL, NULL, NULL);")
        let broken = root.appendingPathComponent("profiles/broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: broken.appendingPathComponent("state.db"))
        let result = try HermesAdapter.scanWithHealth(home: root.path, limit: 20, processes: ProcessInventory(), now: now)
        XCTAssertEqual(result.sessions.map(\.sessionID), ["good"])
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testClaudeRegistryRequiresMatchingProcessIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inventory = ProcessInventory(), pid = getpid()
        var object: [String: Any] = ["sessionId": "fixture", "pid": pid, "status": "busy", "procStart": inventory.starts[pid] ?? ""]
        let path = directory.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        var result = try ClaudeAdapter.scan(home: root.path, limit: 20, reader: TranscriptReader(), processes: inventory, now: now)
        XCTAssertEqual(result.first?.state, .running)
        XCTAssertTrue(result.first?.isOpen == true)
        object["procStart"] = "a reused PID with the wrong start time"
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        result = try ClaudeAdapter.scan(home: root.path, limit: 20, reader: TranscriptReader(), processes: inventory, now: now)
        XCTAssertEqual(result.first?.state, .ended)
        XCTAssertFalse(result.first?.isOpen == true)
    }

    private func event(_ type: String) -> [String: Any] {
        ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now), "payload": ["type": type]]
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SessionMonitorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func createDatabase(_ path: String, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw DatabaseError.failure("Fixture database failed to open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.failure(String(cString: sqlite3_errmsg(db))) }
    }
    private var hermesSchema: String {
        """
        CREATE TABLE sessions(id TEXT PRIMARY KEY,title TEXT,started_at REAL,ended_at REAL,end_reason TEXT,parent_session_id TEXT,last_activity_at REAL);
        CREATE TABLE session_turn_leases(conversation_id TEXT PRIMARY KEY,expires_at REAL);
        """
    }
}
