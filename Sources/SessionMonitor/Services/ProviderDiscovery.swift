import Foundation

/// Discovery is pure and injectable: tests never depend on the developer's home or PATH.
enum ProviderDiscovery {
    static func configuration(environment: [String: String], home: String) -> ScanConfiguration {
        func value(_ name: String, _ fallback: String) -> String {
            guard let raw = environment[name], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
            return expand(raw, home: home)
        }
        return ScanConfiguration(codexHome: value("CODEX_HOME", home + "/.codex"),
                                 claudeHome: value("CLAUDE_CONFIG_DIR", home + "/.claude"),
                                 hermesHome: value("HERMES_HOME", home + "/.hermes"),
                                 harnessDirectory: value("SESSIONMONITOR_HARNESS_DIR", home + "/Library/Application Support/SessionMonitor/events"), limit: 200,
                                 t3Home: value("T3CODE_HOME", home + "/.t3"))
    }
    private static func isExecutable(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return FileManager.default.isExecutableFile(atPath: resolved) &&
            (try? FileManager.default.attributesOfItem(atPath: resolved)[.type] as? FileAttributeType) == .typeRegular
    }
    static func expand(_ path: String, home: String) -> String {
        path == "~" ? home : path.hasPrefix("~/") ? home + String(path.dropFirst()) : path
    }
    static func executable(_ app: AgentApp, override: String = "", environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String? {
        let name: String
        switch app {
        case .codex: name = "codex"
        case .claude: name = "claude"
        case .hermes: name = "hermes"
        case .t3, .harness: return nil
        }
        let configured = override.nilIfEmpty ?? environment["SESSIONMONITOR_" + name.uppercased() + "_EXECUTABLE"]?.nilIfEmpty
        if let configured {
            let path = expand(configured, home: home)
            // A bad explicit override fails visibly; never silently run a different executable.
            return path.hasPrefix("/") && isExecutable(path) ? path : nil
        }
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) +
            [home + "/.local/bin", home + "/.bun/bin", home + "/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return directories.filter { $0.hasPrefix("/") }.map { $0 + "/" + name }.first { isExecutable($0) }
    }
}
