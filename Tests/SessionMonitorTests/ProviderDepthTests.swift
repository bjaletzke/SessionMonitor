import XCTest
import SQLite3
import Darwin
@testable import SessionMonitor

final class ProviderDepthTests: XCTestCase {
    func testNewCodexCountersUseThreadCumulativeRatherThanResponseOrTurn() throws {
        let summary = TranscriptReader.reduce(objects: try objects("codex-worker.jsonl"), app: .codex, completeFile: true)
        XCTAssertEqual(summary.usage?.total, 120)
        XCTAssertEqual(summary.usage?.cacheRead, 50)
        XCTAssertEqual(summary.record.lastTurnUsage?.total, 12)
        XCTAssertEqual(summary.agentRole, "reviewer")
        XCTAssertEqual(summary.agentName, "Reviewer")
        XCTAssertEqual(summary.record.agentPath, "/root/reviewer")
        XCTAssertEqual(summary.record.depth, 1)
        XCTAssertEqual(summary.record.providerVersion, "fixture-version")
        XCTAssertEqual(summary.parentID, "00000000-0000-4000-8000-000000000001")
        XCTAssertNotNil(summary.record.startedAt)
        XCTAssertEqual(summary.record.outcome, "Response completed")
        XCTAssertEqual(summary.state, .responseReady)
    }
    func testResponseOnlyCodexCountersAreNotPresentedAsSessionTotals() {
        let summary = TranscriptReader.reduce(objects: [["type": "token_usage_record", "payload": ["usage": ["total_tokens": 50]]]], app: .codex)
        XCTAssertNil(summary.usage)
    }
    func testStartupMetadataSurvivesTailWithoutReplayingOldLifecycleOrCounters() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("worker.jsonl")
        var data = try Data(contentsOf: fixture("codex-worker.jsonl"))
        data.append(Data((String(repeating: "{\"type\":\"unknown\",\"padding\":\"" + String(repeating: "x", count: 500) + "\"}\n", count: 400)).utf8))
        data.append(Data("{\"type\":\"event_msg\",\"timestamp\":\"2026-01-01T10:01:00Z\",\"payload\":{\"type\":\"task_started\"}}\n".utf8))
        try data.write(to: file)
        let summary = TranscriptReader().summary(path: file.path, app: .codex, now: try XCTUnwrap(LocalFiles.date("2026-01-01T10:01:01Z")))
        XCTAssertEqual(summary.record.agentPath, "/root/reviewer")
        XCTAssertNotNil(summary.record.startedAt)
        XCTAssertEqual(summary.model, "example-model")
        XCTAssertTrue(summary.record.modelSource?.contains("Startup") == true)
        XCTAssertEqual(summary.state, .running)
        XCTAssertNil(summary.completedAt)
        XCTAssertNil(summary.usage, "Head counters must never be counted as recent totals")
    }
    func testClaudeExpandedReadRecoversUsageAndInvalidatesAfterSourceChange() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("worker.jsonl")
        var data = try Data(contentsOf: fixture("claude-worker.jsonl"))
        data.append(Data(String(repeating: "{\"type\":\"unknown\",\"padding\":\"" + String(repeating: "x", count: 500) + "\"}\n", count: 400).utf8))
        try data.write(to: file)
        let reader = TranscriptReader()
        let normal = reader.summary(path: file.path, app: .claude, now: Date())
        XCTAssertNil(normal.usage)
        let deep = reader.summary(path: file.path, app: .claude, now: Date(), expanded: true)
        XCTAssertEqual(deep.usage?.total, 35, "Duplicate streamed message IDs count once")
        XCTAssertTrue(deep.usage?.coverage.contains("Available transcript") == true)
        var session = Session(id: "fixture", sessionID: "fixture", app: .claude, title: "Fixture", updatedAt: Date(), record: normal.record)
        let expanded = ExpandedRecord(summary: deep)
        XCTAssertEqual(expanded.apply(to: session).usage?.total, 35)
        data.append(Data("{\"type\":\"unknown\"}\n".utf8)); try data.write(to: file)
        session.record = reader.summary(path: file.path, app: .claude, now: Date()).record
        XCTAssertFalse(expanded.matches(session))
        XCTAssertNil(expanded.apply(to: session).usage)
    }
    func testExpandedReadStillLabelsFilesOverEightMiBAsPartial() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.jsonl")
        var data = Data(String(repeating: " ", count: TranscriptReader.detailBytes + 1).utf8)
        data.append(10); data.append(try Data(contentsOf: fixture("claude-worker.jsonl")))
        try data.write(to: file)
        let summary = TranscriptReader().summary(path: file.path, app: .claude, now: Date(), expanded: true)
        XCTAssertEqual(summary.usage?.total, 35)
        XCTAssertTrue(summary.usage?.coverage.contains("partial") == true)
        XCTAssertTrue(summary.record.readCoverage?.contains("startup metadata") == true)
    }
    func testClaudeSidecarRoleAndActualModelAreIndependentOfRequestedModel() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/example"), agents = project.appendingPathComponent("parent/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data(contentsOf: fixture("claude-worker.jsonl")).write(to: project.appendingPathComponent("parent.jsonl"))
        try Data(contentsOf: fixture("claude-worker.jsonl")).write(to: agents.appendingPathComponent("agent-worker.jsonl"))
        try Data(contentsOf: fixture("claude-worker.meta.json")).write(to: agents.appendingPathComponent("agent-worker.meta.json"))
        let sessions = try ClaudeAdapter.scan(home: root.path, limit: 20, reader: TranscriptReader(), processes: ProcessInventory(), now: Date())
        let worker = try XCTUnwrap(sessions.first { $0.isSubagent })
        XCTAssertEqual(worker.agentRole, "Explore")
        XCTAssertEqual(worker.record?.taskDescription, "Inspect the synthetic example.")
        XCTAssertEqual(worker.record?.depth, 2)
        XCTAssertEqual(worker.model, "example-actual-model")
        XCTAssertTrue(worker.provider.isEmpty, "Claude model does not identify the billing provider")
        XCTAssertEqual(worker.usage?.total, 35)
        XCTAssertFalse(worker.isOpen)
    }
    func testCodexRelatedLookupDoesNotRaiseHistoryLimit() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try database(root.appendingPathComponent("state_5.sqlite"), sql: """
        CREATE TABLE threads(id TEXT,title TEXT,updated_at REAL,archived INTEGER,tokens_used INTEGER);
        CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT,status TEXT);
        INSERT INTO threads VALUES('parent','Parent',100,0,NULL),('worker','Worker',200,0,0),('unrelated','Unrelated',50,0,99);
        INSERT INTO thread_spawn_edges VALUES('parent','worker','completed');
        """)
        let rows = try CodexAdapter.scan(home: root.path, limit: 1, reader: TranscriptReader(), now: Date(), requestedIDs: ["parent"])
        XCTAssertEqual(Set(rows.map(\.sessionID)), Set(["parent", "worker"]))
        XCTAssertNil(rows.first { $0.sessionID == "parent" }?.usage)
        XCTAssertEqual(rows.first { $0.sessionID == "worker" }?.usage?.total, 0)
        XCTAssertTrue(rows.first { $0.sessionID == "worker" }?.relations.first?.note.contains("not live") == true)
    }
    func testHermesLifecycleCostAndContinuationSeparateFromSubagents() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try database(root.appendingPathComponent("state.db"), sql: String(contentsOf: fixture("hermes.sql"), encoding: .utf8))
        let rows = try HermesAdapter.scan(home: root.path, limit: 20, processes: ProcessInventory(), now: Date())
        let worker = try XCTUnwrap(rows.first { $0.sessionID == "worker" })
        XCTAssertTrue(worker.isSubagent)
        XCTAssertEqual(worker.record?.outcome, "completed")
        XCTAssertEqual(worker.record?.activity, "Synthetic completion")
        XCTAssertEqual(worker.record?.endedAt, Date(timeIntervalSince1970: 350))
        XCTAssertEqual(worker.usage?.displayCount, 35)
        XCTAssertEqual(worker.usage?.actualCostUSD, 0.01)
        let continuation = try XCTUnwrap(rows.first { $0.sessionID == "continuation" })
        XCTAssertFalse(continuation.isSubagent)
        XCTAssertEqual(continuation.relations.first { $0.id.hasSuffix(":parent") }?.kind, .continuedFrom)
        XCTAssertEqual(continuation.relations.first { $0.id.hasSuffix(":worker") }?.kind, .subagent)
        XCTAssertEqual(continuation.usage?.actualCostUSD, 0)
    }
    func testHermesNamedProfilesAndOptionalSchemaDrift() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("profiles/example")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try database(profile.appendingPathComponent("state.db"), sql: """
        CREATE TABLE sessions(id TEXT,started_at REAL);
        CREATE TABLE messages(new_schema TEXT);
        CREATE TABLE session_turn_leases(new_schema TEXT);
        INSERT INTO sessions VALUES('one',100),('older',50);
        """)
        let discoveredProfile = try XCTUnwrap(LocalFiles.children(root.path + "/profiles").first)
        let result = try HermesAdapter.scanWithHealth(home: root.path, limit: 1, processes: ProcessInventory(), now: Date(), requestedIDs: ["hermes:\(discoveredProfile.path):older"])
        XCTAssertEqual(result.sessions.count, 2, "Paths: \(result.sessions.map(\.id)); expected \(discoveredProfile.path)")
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(result.sessions.allSatisfy { $0.id.hasPrefix("hermes:\(discoveredProfile.path):") })
    }
    func testPortableHomesRespectDefaultsEmptyValuesAndOverrides() {
        let defaults = ProviderDiscovery.configuration(environment: [:], home: "/example/home")
        XCTAssertEqual(defaults.codexHome, "/example/home/.codex")
        XCTAssertEqual(defaults.claudeHome, "/example/home/.claude")
        XCTAssertEqual(defaults.hermesHome, "/example/home/.hermes")
        let overrides = ProviderDiscovery.configuration(environment: ["CODEX_HOME": "~/custom", "CLAUDE_CONFIG_DIR": "", "HERMES_HOME": "/example/profile", "SESSIONMONITOR_HARNESS_DIR": "/example/reports"], home: "/example/home")
        XCTAssertEqual(overrides.codexHome, "/example/home/custom")
        XCTAssertEqual(overrides.claudeHome, defaults.claudeHome)
        XCTAssertEqual(overrides.hermesHome, "/example/profile")
        XCTAssertEqual(overrides.harnessDirectory, "/example/reports")
    }
    func testExecutableDiscoveryPATHExplicitOverrideAndMissingCLI() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("custom bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("codex")
        try Data("fixture".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        XCTAssertEqual(ProviderDiscovery.executable(.codex, environment: ["PATH": bin.path], home: root.path), cli.path)
        XCTAssertEqual(ProviderDiscovery.executable(.codex, environment: ["SESSIONMONITOR_CODEX_EXECUTABLE": cli.path], home: root.path), cli.path)
        XCTAssertNil(ProviderDiscovery.executable(.codex, override: "/missing/explicit", environment: ["PATH": bin.path], home: root.path))
        XCTAssertNil(ProviderDiscovery.executable(.codex, override: "codex --dangerous", environment: [:], home: root.path))
        XCTAssertNil(ProviderDiscovery.executable(.codex, override: bin.path, environment: [:], home: root.path))
        XCTAssertNil(ProviderDiscovery.executable(.harness, environment: [:], home: root.path))
    }
    func testConfiguredResumeUsesCorrectProviderHomeAndQuotedExecutable() {
        let session = Session(id: "fixture", sessionID: "example", app: .codex, title: "Example", updatedAt: Date())
        let command = DesktopActions.resumeCommand(session, executable: "/example/custom bin/codex", providerHome: "/example/custom home")
        XCTAssertEqual(command, "CODEX_HOME='/example/custom home' '/example/custom bin/codex' resume 'example'")
    }
    func testOldSavedSessionsDecodeWithoutNewRecordFields() throws {
        let original = Session(id: "fixture", sessionID: "fixture", app: .codex, title: "Example", updatedAt: Date())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "record")
        let decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.record)
        XCTAssertEqual(decoded.id, original.id)
    }
    func testInvalidCountersCostsAndMissingValuesNeverBecomeZeroOrOverflow() {
        XCTAssertNil(TokenUsage.number(true))
        XCTAssertNil(TokenUsage.number(3.5))
        XCTAssertNil(TokenUsage.number(Double.infinity))
        XCTAssertNil(TokenUsage.number(-1))
        XCTAssertEqual(TokenUsage.number(0), 0)
        XCTAssertNil(TokenUsage(input: 5).displayCount)
        XCTAssertNil(TokenUsage.sum([Int64.max, 1]))
        XCTAssertNil(TokenUsage.cost("nan"))
        XCTAssertNil(TokenUsage.cost("-1"))
        XCTAssertEqual(TokenUsage.cost("0"), 0)
    }
    func testSpecialFilesCannotBlockMetadataOrTranscriptReads() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let fifo = git.appendingPathComponent("HEAD")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertNil(LocalFiles.boundedData(fifo, maximum: 4096))
        XCTAssertNil(LocalFiles.object(fifo))
        XCTAssertTrue(WorktreeReader.read(workspace: root.path, now: Date())?.branch.isEmpty == true)
        XCTAssertNil(TranscriptReader().summary(path: fifo.path, app: .codex, now: Date()).record.transcriptBytes)
    }
    func testMissingClaudeCounterFieldsProduceExplicitSubtotal() {
        let summary = TranscriptReader.reduce(objects: [["type": "assistant", "message": ["id": "fixture", "usage": ["input_tokens": 10]]]], app: .claude, completeFile: true)
        XCTAssertEqual(summary.usage?.total, 10)
        XCTAssertEqual(summary.usage?.totalIsPartial, true)
        XCTAssertNil(summary.usage?.output)
        XCTAssertNil(summary.usage?.cacheWrite)
        XCTAssertTrue(summary.usage?.note.contains("subtotal") == true)
    }
    func testCodexNullableMillisecondTimestampFallsBackToLegacySeconds() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try database(root.appendingPathComponent("state_5.sqlite"), sql: """
        CREATE TABLE threads(id TEXT,updated_at REAL,updated_at_ms REAL);
        INSERT INTO threads VALUES('newer',200,NULL),('older',100,100000);
        """)
        let sessions = try CodexAdapter.scan(home: root.path, limit: 1, reader: TranscriptReader(), now: Date())
        XCTAssertEqual(sessions.first?.sessionID, "newer")
    }
    func testHermesParentLineageSurvivesMissingOptionalEndReasonColumn() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try database(root.appendingPathComponent("state.db"), sql: """
        CREATE TABLE sessions(id TEXT,started_at REAL,parent_session_id TEXT);
        INSERT INTO sessions VALUES('parent',100,NULL),('child',200,'parent');
        """)
        let sessions = try HermesAdapter.scan(home: root.path, limit: 1, processes: ProcessInventory(), now: Date())
        XCTAssertEqual(sessions.first?.relations.first?.kind, .parent)
        XCTAssertTrue(sessions.first?.relations.first?.id.hasSuffix(":parent") == true)
        XCTAssertFalse(sessions.first?.isSubagent == true)
    }
    func testHermesDelegateMarkerIdentifiesWorkerWithInheritedDesktopSource() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try database(root.appendingPathComponent("state.db"), sql: """
        CREATE TABLE sessions(id TEXT,started_at REAL,parent_session_id TEXT,source TEXT,model_config TEXT);
        INSERT INTO sessions VALUES('parent',100,NULL,'desktop','{}'),('worker',200,'parent','desktop','{"_delegate_from":"parent"}');
        """)
        let sessions = try HermesAdapter.scan(home: root.path, limit: 20, processes: ProcessInventory(), now: Date())
        XCTAssertTrue(sessions.first { $0.sessionID == "worker" }?.isSubagent == true)
        XCTAssertFalse(sessions.first { $0.sessionID == "parent" }?.isSubagent == true)
        XCTAssertEqual(sessions.first { $0.sessionID == "parent" }?.relations.first?.kind, .subagent)
        XCTAssertEqual(sessions.first { $0.sessionID == "worker" }?.parentID, "parent")
    }
    private func fixture(_ name: String) -> URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name) }
    private func objects(_ name: String) throws -> [[String: Any]] {
        try Data(contentsOf: fixture(name)).split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionMonitorFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }
    private func database(_ url: URL, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw DatabaseError.failure("Fixture open failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.failure(String(cString: sqlite3_errmsg(db))) }
    }
}
