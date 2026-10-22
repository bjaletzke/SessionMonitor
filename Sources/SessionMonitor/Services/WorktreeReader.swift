import Foundation

/// Read Git's small metadata files directly. Never run Git or change a checkout.
final class WorktreeReader {
    private struct Entry { var readAt: Date; var info: WorktreeInfo? }
    private var cache: [String: Entry] = [:]
    func inspect(workspace: String, now: Date) -> WorktreeInfo? {
        guard !workspace.isEmpty else { return nil }
        if let entry = cache[workspace], now.timeIntervalSince(entry.readAt) < 60 { return entry.info }
        let info = Self.read(workspace: workspace, now: now)
        if cache.count > 2000 { cache.removeAll() }
        cache[workspace] = Entry(readAt: now, info: info)
        return info
    }
    static func read(workspace: String, now: Date) -> WorktreeInfo? {
        var directory = URL(fileURLWithPath: LocalFiles.expanded(workspace)).standardizedFileURL
        for _ in 0..<25 {
            let marker = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                let git: URL
                if isDirectory.boolValue { git = marker }
                else {
                    guard let line = smallText(marker), line.hasPrefix("gitdir:") else { return nil }
                    let path = String(line.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !path.isEmpty else { return nil }
                    git = resolve(path, relativeTo: directory)
                }
                guard FileManager.default.fileExists(atPath: git.appendingPathComponent("HEAD").path) else { return nil }
                let commonPath = smallText(git.appendingPathComponent("commondir"))
                let common = commonPath.map { resolve($0, relativeTo: git) } ?? git
                // A .git file alone can also be a submodule; commondir establishes a linked worktree.
                let linked = commonPath != nil && common != git && FileManager.default.fileExists(atPath: common.path)
                let repository = linked && common.lastPathComponent == ".git" ? common.deletingLastPathComponent() : directory
                let head = smallText(git.appendingPathComponent("HEAD")) ?? ""
                let branch = head.hasPrefix("ref: refs/heads/") ? String(head.dropFirst(16)) : head.isEmpty ? "" : "Detached · \(head.prefix(8))"
                return WorktreeInfo(root: directory.path, repository: repository.path, branch: branch, isLinked: linked, inspectedAt: now)
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
    }
    private static func resolve(_ path: String, relativeTo root: URL) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
    }
    private static func smallText(_ url: URL) -> String? {
        guard let data = LocalFiles.boundedData(url, maximum: 4096),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
