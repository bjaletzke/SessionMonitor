import Foundation
import Observation

@MainActor @Observable final class MonitorPreferences {
    var codexHome: String { didSet { defaults.set(codexHome, forKey: "codexHome") } }
    var claudeHome: String { didSet { defaults.set(claudeHome, forKey: "claudeHome") } }
    var hermesHome: String { didSet { defaults.set(hermesHome, forKey: "hermesHome") } }
    var t3Home: String { didSet { defaults.set(t3Home, forKey: "t3Home") } }
    var harnessDirectory: String { didSet { defaults.set(harnessDirectory, forKey: "harnessDirectory") } }
    var codexExecutable: String { didSet { defaults.set(codexExecutable, forKey: "codexExecutable") } }
    var claudeExecutable: String { didSet { defaults.set(claudeExecutable, forKey: "claudeExecutable") } }
    var hermesExecutable: String { didSet { defaults.set(hermesExecutable, forKey: "hermesExecutable") } }
    var refreshSeconds: Int { didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") } }
    var sessionLimit: Int { didSet { defaults.set(sessionLimit, forKey: "sessionLimit") } }
    var days: Int { didSet { defaults.set(days, forKey: "days") } }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let paths = Self.defaultConfiguration
        codexHome = defaults.string(forKey: "codexHome") ?? paths.codexHome
        claudeHome = defaults.string(forKey: "claudeHome") ?? paths.claudeHome
        hermesHome = defaults.string(forKey: "hermesHome") ?? paths.hermesHome
        t3Home = defaults.string(forKey: "t3Home") ?? paths.t3Home
        harnessDirectory = defaults.string(forKey: "harnessDirectory") ?? paths.harnessDirectory
        codexExecutable = defaults.string(forKey: "codexExecutable") ?? ""
        claudeExecutable = defaults.string(forKey: "claudeExecutable") ?? ""
        hermesExecutable = defaults.string(forKey: "hermesExecutable") ?? ""
        refreshSeconds = max(2, defaults.object(forKey: "refreshSeconds") as? Int ?? 5)
        sessionLimit = defaults.object(forKey: "sessionLimit") as? Int ?? 200
        days = defaults.object(forKey: "days") as? Int ?? 7
    }
    static var defaultConfiguration: ScanConfiguration {
        ProviderDiscovery.configuration(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }
    func executable(_ app: AgentApp) -> String? {
        let override: String
        switch app {
        case .codex: override = codexExecutable
        case .claude: override = claudeExecutable
        case .hermes: override = hermesExecutable
        case .t3, .harness: override = ""
        }
        return ProviderDiscovery.executable(app, override: override)
    }
    func providerHome(_ session: Session) -> String? {
        switch session.app {
        case .codex: LocalFiles.expanded(codexHome)
        case .claude: LocalFiles.expanded(claudeHome)
        case .hermes: URL(fileURLWithPath: session.sourcePath).deletingLastPathComponent().path
        case .t3, .harness: nil
        }
    }
    var configuration: ScanConfiguration {
        ScanConfiguration(codexHome: codexHome, claudeHome: claudeHome, hermesHome: hermesHome, harnessDirectory: harnessDirectory, limit: sessionLimit, t3Home: t3Home)
    }
}
