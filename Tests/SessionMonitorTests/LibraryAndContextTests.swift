import XCTest
import SQLite3
@testable import SessionMonitor

final class LibraryAndContextTests: XCTestCase {
    @MainActor func testBookmarksNotesAndOverrideSurviveRelaunch() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        let library = SessionLibrary(url: url)
        let session = fixture("one")
        library.toggleBookmark(session)
        library.setNotes("Review the PR\nCheck the migration", session: session)
        library.setOverride(.done, session: session)
        library.flush()
        let reloaded = SessionLibrary(url: url)
        XCTAssertTrue(reloaded.annotation(for: session.id).bookmarked)
        XCTAssertEqual(reloaded.annotation(for: session.id).notes, "Review the PR\nCheck the migration")
        XCTAssertEqual(reloaded.annotation(for: session.id).statusOverride, .done)
        XCTAssertEqual(reloaded.apply(to: session).state, .done)
        XCTAssertEqual(reloaded.apply(to: session).detectedState, .responseReady)
        XCTAssertEqual(session.state, .responseReady)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    @MainActor func testOverridePreservesNewDetectedStateAndCanBeCleared() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(url: root.appendingPathComponent("library.json"))
        var session = fixture("one")
        library.setOverride(.idle, session: session)
        session.state = .approvalNeeded
        let displayed = library.apply(to: session)
        XCTAssertEqual(displayed.state, .idle)
        XCTAssertEqual(displayed.detectedState, .approvalNeeded)
        XCTAssertEqual(displayed.confidence, .manual)
        library.setOverride(nil, session: session)
        XCTAssertEqual(library.apply(to: session).state, .approvalNeeded)
        XCTAssertNil(library.apply(to: session).detectedState)
        library.flush()
    }
    @MainActor func testSavedBookmarksIgnoreDateRangeAndRemainSearchableByNotes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(url: root.appendingPathComponent("library.json"))
        var old = fixture("old"); old.updatedAt = .distantPast
        library.toggleBookmark(old); library.setNotes("Remember the database migration", session: old); library.flush()
        let store = SessionStore(library: library)
        store.snapshot.sessions = []; store.scope = .bookmarks; store.search = "database migration"
        XCTAssertEqual(store.visibleSessions.map(\.id), [old.id])
        XCTAssertEqual(store.visibleSessions.first?.state, .unknown)
        XCTAssertTrue(store.visibleSessions.first?.savedBookmark == true)
        XCTAssertFalse(store.visibleSessions.first?.isOpen == true)
        store.search = "unrelated"
        XCTAssertTrue(store.visibleSessions.isEmpty)
        library.toggleBookmark(old); library.flush(); store.search = ""
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertEqual(library.annotation(for: old.id).notes, "Remember the database migration")
    }
    @MainActor func testFirstNoteBookmarksAndDoesNotOverwriteCorruptLibrary() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        let library = SessionLibrary(url: url)
        library.setNotes("Keep this", session: fixture("one")); library.flush()
        XCTAssertTrue(library.annotation(for: "one").bookmarked)
        let corrupt = Data("do not overwrite this".utf8); try corrupt.write(to: url)
        let broken = SessionLibrary(url: url)
        broken.toggleBookmark(fixture("two")); broken.flush()
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertNotNil(broken.storageError)
        XCTAssertFalse(broken.canEdit)
    }
    @MainActor func testBulkIdleChangesOnlyVisibleReadySessions() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(url: root.appendingPathComponent("library.json")), store = SessionStore(library: library)
        var running = fixture("running"); running.state = .running
        var child = fixture("child"); child.isSubagent = true
        store.snapshot.sessions = [fixture("ready"), running, child]
        store.markVisibleReadyIdle()
        XCTAssertEqual(library.annotation(for: "ready").statusOverride, .idle)
        XCTAssertNil(library.annotation(for: "running").statusOverride)
        XCTAssertNil(library.annotation(for: "child").statusOverride)
        library.flush()
    }
    @MainActor func testFollowSourceAlsoClearsEarlierReviewAcknowledgement() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(url: root.appendingPathComponent("library.json")), store = SessionStore(library: library)
        var session = fixture("reviewed-then-overridden"); session.completedAt = Date()
        store.snapshot.sessions = [session]
        store.reviews.dates[session.id] = session.completedAt!.timeIntervalSince1970
        store.setOverride(.done, session: session)
        XCTAssertEqual(store.session(for: session.id)?.detectedState, .responseReady)
        store.setOverride(nil, session: session)
        XCTAssertEqual(store.session(for: session.id)?.state, .responseReady)
        XCTAssertNil(store.reviews.dates[session.id])
        library.flush()
    }
    func testLinkedWorktreeUsesCommmonDirectoryAndSubmoduleIsNotMislabelled() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo"), checkout = root.appendingPathComponent("feature")
        let git = repository.appendingPathComponent(".git"), worktreeGit = git.appendingPathComponent("worktrees/feature")
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try "gitdir: \(worktreeGit.path)\n".write(to: checkout.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: worktreeGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature/session-monitor\n".write(to: worktreeGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let result = WorktreeReader.read(workspace: checkout.path, now: Date())
        XCTAssertTrue(result?.isLinked == true)
        XCTAssertEqual(result?.repository, repository.path)
        XCTAssertEqual(result?.branch, "feature/session-monitor")
        try FileManager.default.removeItem(at: worktreeGit.appendingPathComponent("commondir"))
        XCTAssertFalse(WorktreeReader.read(workspace: checkout.path, now: Date())?.isLinked == true)
    }
    func testMessagePreviewExcludesReasoningToolOutputsAndPreservesParagraphs() {
        let objects: [[String: Any]] = [
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "channel": "final", "content": [["type": "output_text", "text": "Response\n\nSecond paragraph"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "channel": "analysis", "content": [["type": "output_text", "text": "Private reasoning"]]]],
            ["type": "response_item", "payload": ["type": "function_call_output", "output": "A tool result"]]
        ]
        let summary = TranscriptReader.reduce(objects: objects, app: .codex)
        XCTAssertEqual(summary.lastMessage?.text, "Response\n\nSecond paragraph")
        let text = String(repeating: "a", count: 9000)
        let preview = MessageText.preview(text, role: "assistant", at: nil)
        XCTAssertEqual(preview?.text.count, 8000); XCTAssertTrue(preview?.truncated == true)
        XCTAssertNil(MessageText.extract([["type": "thinking", "thinking": "hidden"]]))
        XCTAssertNil(MessageText.preview("tool", role: "tool", at: nil))
    }
    func testClaudeSubagentHasScopedIdentityAndNeverGetsDirectResumeCommand() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/demo"), agents = project.appendingPathComponent("parent/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let message: [String: Any] = ["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: Date()), "message": ["model": "test", "stop_reason": "end_turn", "content": [["type": "text", "text": "Finished the review"]]]]
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        try data.write(to: project.appendingPathComponent("parent.jsonl")); try data.write(to: agents.appendingPathComponent("agent-child.jsonl"))
        let sessions = try ClaudeAdapter.scan(home: root.path, limit: 20, reader: TranscriptReader(), processes: ProcessInventory(), now: Date())
        let child = try XCTUnwrap(sessions.first { $0.isSubagent })
        XCTAssertEqual(child.id, "claude:parent:subagent:child")
        XCTAssertEqual(child.parentKey, "claude:parent")
        XCTAssertEqual(child.lastMessage?.text, "Finished the review")
        XCTAssertNil(DesktopActions.resumeCommand(child))
        XCTAssertFalse(child.isOpen)
        XCTAssertEqual(sessions.first { $0.id == "claude:parent" }?.relations.first?.id, child.id)
    }
    func testCodexRelatedParentIsKeptEvenOutsideLoadLimit() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try database(root.appendingPathComponent("state_5.sqlite"), sql: """
        CREATE TABLE threads(id TEXT,title TEXT,updated_at REAL,archived INTEGER);
        CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT,status TEXT);
        INSERT INTO threads VALUES('parent','Parent title',100,0),('child','Child title',200,0);
        INSERT INTO thread_spawn_edges VALUES('parent','child','completed');
        """)
        let sessions = try CodexAdapter.scan(home: root.path, limit: 1, reader: TranscriptReader(), now: Date())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions.first?.isSubagent == true)
        XCTAssertEqual(sessions.first?.parentKey, "codex:parent")
        XCTAssertEqual(sessions.first?.relations.first?.title, "Parent title")
    }
    func testHermesCompressionIsContinuationAndPreviewSkipsToolMessage() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try database(root.appendingPathComponent("state.db"), sql: """
        CREATE TABLE sessions(id TEXT,title TEXT,started_at REAL,ended_at REAL,end_reason TEXT,parent_session_id TEXT);
        CREATE TABLE messages(id INTEGER,session_id TEXT,role TEXT,content TEXT,timestamp REAL,finish_reason TEXT);
        INSERT INTO sessions VALUES('root','Root',100,200,'compression',NULL),('child','Child',200,NULL,NULL,'root');
        INSERT INTO messages VALUES(1,'child','assistant','Final answer',300,'stop'),(2,'child','tool','Tool output',301,NULL);
        """)
        let sessions = try HermesAdapter.scan(home: root.path, limit: 20, processes: ProcessInventory(), now: Date())
        let child = try XCTUnwrap(sessions.first { $0.sessionID == "child" })
        XCTAssertEqual(child.relations.first?.kind, .continuedFrom)
        XCTAssertFalse(child.isSubagent)
        XCTAssertEqual(child.lastMessage?.text, "Final answer")
    }
    func testMissingOptionalSpawnSchemaDoesNotHideCodexSessions() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try database(root.appendingPathComponent("state_5.sqlite"), sql: """
        CREATE TABLE threads(id TEXT,title TEXT,updated_at REAL);
        CREATE TABLE thread_spawn_edges(new_unknown_schema TEXT);
        INSERT INTO threads VALUES('one','Still discoverable',100);
        """)
        let sessions = try CodexAdapter.scan(home: root.path, limit: 20, reader: TranscriptReader(), now: Date())
        XCTAssertEqual(sessions.map(\.sessionID), ["one"])
        XCTAssertTrue(sessions.first?.relations.isEmpty == true)
    }
    @MainActor func testProjectScopeUsesExactLocationAndExcludesChildren() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(library: SessionLibrary(url: root.appendingPathComponent("library.json")))
        var first = fixture("first"); first.workspace = "/work/one/project"
        var second = fixture("second"); second.workspace = "/work/two/project"
        var child = fixture("child"); child.workspace = first.workspace; child.isSubagent = true
        store.snapshot.sessions = [first, second, child]
        store.scope = .workspace(first.workspace)
        XCTAssertEqual(store.visibleSessions.map(\.id), [first.id])
        XCTAssertEqual(Set(store.workspaces), Set([first.workspace, second.workspace]))
    }
    @MainActor func testSelectionSurvivesRefreshAndFollowsFilteredResults() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(library: SessionLibrary(url: root.appendingPathComponent("library.json")))
        let first = fixture("first"), second = fixture("second")
        store.snapshot.sessions = [first, second]; store.selectedID = second.id
        store.reconcileSelection()
        XCTAssertEqual(store.selectedID, second.id)
        store.search = "Session first"; store.reconcileSelection()
        XCTAssertEqual(store.selectedID, first.id)
        store.search = "No matching conversation"; store.reconcileSelection()
        XCTAssertNil(store.selectedID)
    }
    private func fixture(_ id: String) -> Session {
        Session(id: id, sessionID: id, app: .codex, title: "Session \(id)", state: .responseReady, confidence: .historical, updatedAt: Date())
    }
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("SessionMonitorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    private func database(_ url: URL, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw DatabaseError.failure("Fixture open failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.failure(String(cString: sqlite3_errmsg(db))) }
    }
}
