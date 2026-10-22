import XCTest
@testable import SessionMonitor

final class ProjectGroupingTests: XCTestCase {
    @MainActor func testSameNamedProjectsCombineProvidersAndExcludeSubagents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(library: SessionLibrary(url: root.appendingPathComponent("library.json")))
        let first = session("first", workspace: "/projects/main/Example")
        var second = session("second", workspace: "/worktrees/feature/Example"); second.app = .claude
        let third = session("third", workspace: first.workspace)
        let other = session("other", workspace: "/projects/Other")
        var child = session("child", workspace: first.workspace); child.isSubagent = true
        let unlocated = session("unlocated", workspace: "")
        store.snapshot.sessions = [first, second, third, other, child, unlocated]

        XCTAssertEqual(store.projects.map(\.name), ["Example", "Other"])
        XCTAssertEqual(store.projects.first?.sessionCount, 3)
        XCTAssertEqual(Set(store.projects.first?.paths ?? []), Set([first.workspace, second.workspace]))
        store.scope = .project("Example")
        XCTAssertEqual(Set(store.visibleSessions.map(\.id)), Set([first.id, second.id, third.id]))
        store.search = "second"
        XCTAssertEqual(store.visibleSessions.map(\.id), [second.id])
    }

    @MainActor func testGroupSelectionSurvivesWorkspaceReplacementAndIncludesNewLocations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(library: SessionLibrary(url: root.appendingPathComponent("library.json")))
        let first = session("first", workspace: "/projects/old/Example")
        let second = session("second", workspace: "/projects/new/Example")
        store.snapshot.sessions = [first]; store.scope = .project("Example"); store.selectedID = first.id
        store.snapshot.sessions = [second]; store.reconcileSelection()
        XCTAssertEqual(store.scope, .project("Example"))
        XCTAssertEqual(store.selectedID, second.id)
        store.snapshot.sessions.append(session("third", workspace: "/projects/another/Example"))
        XCTAssertEqual(store.visibleSessions.count, 2)
        XCTAssertEqual(store.projects.count, 1)
    }

    func testGroupingUsesWholeFolderNameAndRemainsIndependentOfInputOrder() {
        let sessions = [session("one", workspace: "/projects/Example"), session("two", workspace: "/projects/MyExample"), session("three", workspace: "/elsewhere/Example/")]
        let forward = ProjectGroup.groups(for: sessions)
        let reversed = ProjectGroup.groups(for: sessions.reversed())
        XCTAssertEqual(forward.map(\.id), reversed.map(\.id))
        XCTAssertEqual(forward.map(\.paths), reversed.map(\.paths))
        XCTAssertEqual(forward.first(where: { $0.name == "Example" })?.sessionCount, 2)
        XCTAssertEqual(forward.first(where: { $0.name == "MyExample" })?.sessionCount, 1)
    }

    private func session(_ id: String, workspace: String) -> Session {
        Session(id: id, sessionID: id, app: .codex, title: id, workspace: workspace,
                state: .responseReady, confidence: .historical, updatedAt: Date())
    }
}
