import SwiftUI
import AppKit

extension SessionState {
    var color: Color {
        switch self {
        case .running: .green
        case .needsAttention, .waitingForAnswer, .approvalNeeded: .orange
        case .responseReady: .blue
        case .error: .red
        case .idle: .blue
        case .done: .secondary
        case .ended, .unknown: .secondary
        }
    }
    var symbol: String {
        switch self {
        case .running: "circle.fill"
        case .needsAttention: "hand.raised.fill"
        case .waitingForAnswer: "questionmark.bubble.fill"
        case .approvalNeeded: "lock.circle.fill"
        case .responseReady: "checkmark.bubble"
        case .error: "exclamationmark.circle.fill"
        case .idle: "pause.circle"
        case .done: "checkmark.circle.fill"
        case .ended: "checkmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

enum DesktopActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    static func reveal(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: LocalFiles.expanded(path))])
    }
    static func openFolder(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: LocalFiles.expanded(path)))
    }
    static func applicationURL(_ app: AgentApp) -> URL? {
        switch app {
        case .codex: return URL(string: "codex://").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        case .claude: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")
        case .hermes: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.nousresearch.hermes.setup")
        case .t3: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code")
        case .harness: return nil
        }
    }
    static func openApplication(_ app: AgentApp) throws {
        guard let url = applicationURL(app), NSWorkspace.shared.open(url) else {
            throw ActionError.failed("Could not find or open \(app.rawValue) on this Mac.")
        }
    }
    static func sessionURL(_ session: Session) -> URL? {
        var url = URLComponents()
        switch session.app {
        case .codex:
            // Thread IDs are UUIDs. Refuse arbitrary path/query content from a source file.
            guard UUID(uuidString: session.sessionID) != nil else { return nil }
            url.scheme = "codex"; url.host = "threads"; url.path = "/" + session.sessionID
        case .claude:
            guard session.desktopSessionID.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else { return nil }
            url.scheme = "claude"; url.host = "code"; url.path = "/continue"
            url.queryItems = [URLQueryItem(name: "session", value: session.desktopSessionID)]
        case .t3:
            guard let environment = session.environmentID, UUID(uuidString: environment) != nil,
                  session.sessionID.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil else { return nil }
            url.scheme = "t3code"; url.host = "threads"; url.path = "/\(environment)/\(session.sessionID)"
        case .hermes, .harness: return nil
        }
        return url.url
    }
    static func openLabel(_ session: Session) -> String {
        if let url = sessionURL(session), NSWorkspace.shared.urlForApplication(toOpen: url) != nil { return "Open session" }
        if session.app == .t3 { return "Open T3 Code" }
        return resumeCommand(session) == nil ? "Open unavailable" : "Resume in Terminal"
    }
    static func openSession(_ session: Session, executable: String? = nil, providerHome: String? = nil, allowDiscovery: Bool = true) throws {
        if let url = sessionURL(session), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            guard NSWorkspace.shared.open(url) else { throw ActionError.failed("The application could not open this session link.") }
            return
        }
        if session.app == .t3 { try openApplication(.t3); return }
        guard let executable = executable ?? (allowDiscovery ? ProviderDiscovery.executable(session.app) : nil) else { throw ActionError.failed("CLI not found. Set an executable path in Settings or install the provider CLI.") }
        guard let command = resumeCommand(session, executable: executable, providerHome: providerHome) else { throw ActionError.failed("This source has no session-opening action.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionMonitor-commands", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent(UUID().uuidString + ".command")
        let extraPath = [".local/bin", ".bun/bin"].map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path }
        let pathPrefix = (extraPath + ["/opt/homebrew/bin", "/usr/local/bin"]).joined(separator: ":")
        let script = "#!/bin/zsh\nexport PATH=" + shellQuote(pathPrefix) + ":\"$PATH\"\nrm -- " + shellQuote(file.path) + "\n" + command + "\n"
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        guard NSWorkspace.shared.open(file) else { throw ActionError.failed("Terminal could not open the resume command.") }
    }
    enum ActionError: LocalizedError {
        case failed(String)
        var errorDescription: String? { switch self { case .failed(let message): message } }
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func resumeCommand(_ session: Session, executable: String? = nil, providerHome: String? = nil) -> String? {
        if session.app == .claude && session.isSubagent { return nil }
        let command: String
        switch session.app {
        case .codex: command = (providerHome.map { "CODEX_HOME=\(shellQuote($0)) " } ?? "") + "\(executable.map(shellQuote) ?? "codex") resume \(shellQuote(session.sessionID))"
        case .claude: command = (providerHome.map { "CLAUDE_CONFIG_DIR=\(shellQuote($0)) " } ?? "") + "\(executable.map(shellQuote) ?? "claude") --resume \(shellQuote(session.sessionID))"
        case .hermes:
            let root = URL(fileURLWithPath: session.sourcePath).deletingLastPathComponent().path
            command = "HERMES_HOME=\(shellQuote(providerHome ?? root)) \(executable.map(shellQuote) ?? "hermes") --resume \(shellQuote(session.sessionID))"
        case .t3, .harness: return nil
        }
        return session.workspace.isEmpty ? command : "cd \(shellQuote(session.workspace)) && \(command)"
    }
}

struct StateBadge: View {
    let session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(session.state.label, systemImage: session.state.symbol)
                .font(.callout.weight(.medium)).foregroundStyle(session.state.color)
            Text(session.detectedState.map { "Source: " + $0.label } ?? session.confidence.label)
                .font(.caption2).foregroundStyle(session.detectedState?.needsAction == true ? Color.orange : Color.secondary).lineLimit(1)
        }
        .help(session.evidence)
    }
}
