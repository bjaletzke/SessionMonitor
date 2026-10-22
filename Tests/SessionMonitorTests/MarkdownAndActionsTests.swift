import XCTest
import Markdown
@testable import SessionMonitor

final class MarkdownAndActionsTests: XCTestCase {
    func testTablePreservesCellsInlineFormattingAndEscapedPipes() throws {
        let document = Document(parsing: """
        | Item | Count | Detail |
        | :--- | ---: | :---: |
        | **One** | 12 | A\\|B |
        | Two | 3 | [Reference](https://example.com) |
        """)
        let table = try XCTUnwrap(document.child(at: 0) as? Markdown.Table)
        XCTAssertEqual(table.maxColumnCount, 3)
        XCTAssertEqual(table.body.childCount, 2)
        XCTAssertEqual(table.columnAlignments, [.left, .right, .center])
        let cells = Array(Array(table.body.rows)[0].cells)
        XCTAssertEqual(String(MarkdownText.inline(cells[2]).characters), "A|B")
        XCTAssertTrue(MarkdownText.inline(cells[0]).runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        let reference = Array(Array(table.body.rows)[1].cells)[2]
        XCTAssertEqual(MarkdownText.inline(reference).runs.first?.link?.absoluteString, "https://example.com")
    }
    func testNestedListsTaskListsAndFencedCodeStayStructured() throws {
        let document = Document(parsing: """
        - [x] First task
          - Nested *item*
        - [ ] Second task

        ```swift
        let pipe = "|"
        ```
        """)
        let list = try XCTUnwrap(document.child(at: 0) as? UnorderedList)
        XCTAssertEqual(Array(list.listItems)[0].checkbox, .checked)
        XCTAssertEqual(Array(list.listItems)[1].checkbox, .unchecked)
        XCTAssertTrue(Array(list.listItems)[0].children.contains { $0 is UnorderedList })
        let code = try XCTUnwrap(document.child(at: 1) as? CodeBlock)
        XCTAssertEqual(code.language, "swift")
        XCTAssertEqual(code.code, "let pipe = \"|\"\n")
    }
    func testNestedEmphasisAndUnsafeLinks() throws {
        let paragraph = try XCTUnwrap(Document(parsing: "**Bold and *italic*** [unsafe](file:///tmp/test) ![remote](https://example.com/image.png)").child(at: 0))
        let rendered = MarkdownText.inline(paragraph)
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains([.stronglyEmphasized, .emphasized]) == true })
        XCTAssertFalse(rendered.runs.contains { $0.link?.scheme == "file" })
        XCTAssertTrue(String(rendered.characters).contains("[Image: remote]"))
        XCTAssertNil(MarkdownText.safeLink("javascript:alert(1)"))
        XCTAssertNil(MarkdownText.safeLink("codex://threads/abc"))
    }
    @MainActor func testBulkReviewRespectsFiltersAndNewCompletionReappears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "SessionMonitorTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(library: SessionLibrary(url: root.appendingPathComponent("library.json")), reviewDefaults: defaults)
        let completed = Date()
        var first = session("first"); first.title = "Match"; first.completedAt = completed
        var hidden = session("hidden"); hidden.title = "Other"; hidden.completedAt = completed
        var child = first; child.id = "child"; child.isSubagent = true
        store.snapshot.sessions = [first, hidden, child]; store.search = "Match"
        XCTAssertEqual(store.visibleReviewableCount, 1)
        store.markVisibleReviewed()
        XCTAssertEqual(store.session(for: first.id)?.state, .idle)
        XCTAssertEqual(store.session(for: hidden.id)?.state, .responseReady)
        XCTAssertEqual(store.session(for: child.id)?.state, .responseReady)
        XCTAssertNil(store.library.annotation(for: first.id).statusOverride)
        store.snapshot.sessions[0].completedAt = completed.addingTimeInterval(60)
        XCTAssertEqual(store.session(for: first.id)?.state, .responseReady)
    }
    @MainActor func testConfirmationDoesNotReviewANewResponseArrivingWhileDialogIsOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "SessionMonitorTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(library: SessionLibrary(url: root.appendingPathComponent("library.json")), reviewDefaults: defaults)
        var first = session("new-response"); first.completedAt = Date()
        store.snapshot.sessions = [first]
        store.prepareReview()
        store.snapshot.sessions[0].completedAt = first.completedAt!.addingTimeInterval(10)
        store.markPreparedReviewed()
        XCTAssertEqual(store.session(for: first.id)?.state, .responseReady)
    }
    @MainActor func testSourceArchiveKeepsNotesAndBookmarkButRemovesMainListEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(url: root.appendingPathComponent("library.json"))
        let original = session("archived-bookmark")
        library.toggleBookmark(original); library.setNotes("Keep these notes", session: original)
        library.setOverride(.responseReady, session: original)
        library.recordSourceArchive(original); library.flush()
        let reloaded = SessionLibrary(url: root.appendingPathComponent("library.json"))
        let store = SessionStore(library: reloaded)
        XCTAssertFalse(store.recentSessions.contains { $0.id == original.id })
        XCTAssertEqual(store.bookmarks.map(\.id), [original.id])
        XCTAssertEqual(store.session(for: original.id)?.state, .unknown)
        XCTAssertEqual(reloaded.annotation(for: original.id).notes, "Keep these notes")
        XCTAssertNotNil(reloaded.annotation(for: original.id).archivedInSourceAt)
        reloaded.remember([original])
        XCTAssertNil(reloaded.annotation(for: original.id).archivedInSourceAt)
        reloaded.flush()
    }
    func testArchiveProtocolWaitsForInitializeThenTargetsOnlyChosenThread() throws {
        let root = try fixtureProcess(response: "{'id':2,'result':{}}")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        try SessionArchive.requestArchive(executable: root.appendingPathComponent("codex").path, home: root.path, threadID: id, timeout: 3)
        let lines = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
        let objects = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(objects.compactMap { $0["method"] as? String }, ["initialize", "initialized", "thread/archive"])
        XCTAssertEqual((objects[2]["params"] as? [String: String])?["threadId"], id)
    }
    func testArchiveRejectionIsNotReportedAsSuccess() throws {
        let root = try fixtureProcess(response: "{'id':2,'error':{'message':'Worker is active'}}")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SessionArchive.requestArchive(executable: root.appendingPathComponent("codex").path, home: root.path, threadID: UUID().uuidString, timeout: 3)) {
            XCTAssertTrue($0.localizedDescription.contains("Worker is active"))
        }
    }
    func testArchiveLostAcknowledgementHasUnknownOutcomeAndDoesNotRetry() throws {
        let root = try fixtureProcess(response: "{'method':'unrelated/event','params':{}}")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SessionArchive.requestArchive(executable: root.appendingPathComponent("codex").path, home: root.path, threadID: UUID().uuidString, timeout: 3)) {
            XCTAssertTrue($0.localizedDescription.contains("outcome is unknown"))
        }
        let data = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        let methods = data.split(separator: "\n").compactMap { line in (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["method"] as? String }
        XCTAssertEqual(methods.filter { $0 == "thread/archive" }.count, 1)
    }
    func testArchiveRefusesMalformedIDBeforeLaunchingAnything() {
        XCTAssertThrowsError(try SessionArchive.requestArchive(executable: "/does/not/exist", home: "/tmp", threadID: "bad/id")) {
            XCTAssertEqual($0.localizedDescription, "Invalid thread ID.")
        }
    }
    private func fixtureProcess(response: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("codex")
        let script = """
        #!/usr/bin/python3
        import sys,json,os,time
        with open(os.path.join(os.environ['CODEX_HOME'],'requests.jsonl'),'w') as log:
            for line in sys.stdin:
                log.write(line); log.flush()
                message=json.loads(line)
                if message.get('method')=='initialize':
                    print(json.dumps({'id':1,'result':{'userAgent':'test'}}),flush=True)
                elif message.get('method')=='thread/archive':
                    print(json.dumps(\(response)),flush=True)
                    break
        """
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return root
    }
    private func session(_ id: String) -> Session {
        Session(id: id, sessionID: UUID().uuidString, app: .codex, title: id, state: .responseReady, confidence: .reported, evidence: "fixture", updatedAt: Date(), sourcePath: "/tmp/fixture")
    }
}
