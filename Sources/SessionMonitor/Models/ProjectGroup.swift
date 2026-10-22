import Foundation

/// A sidebar grouping by display name, without asserting that its folders are one repository.
struct ProjectGroup: Identifiable {
    let name: String
    let paths: [String]
    let sessionCount: Int
    var id: String { name }

    static func workspaceName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    static func groups(for sessions: [Session]) -> [ProjectGroup] {
        Dictionary(grouping: sessions.filter { !$0.workspace.isEmpty }, by: { workspaceName($0.workspace) })
            .map { name, sessions in
                ProjectGroup(name: name, paths: Set(sessions.map(\.workspace)).sorted(), sessionCount: sessions.count)
            }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
            }
    }
}
