import Foundation
import Darwin

/// Explicit user actions go through the provider's protocol, never SQL writes.
enum SessionArchive {
    static func executable() -> String? {
        ProviderDiscovery.executable(.codex)
    }
    static func unavailableReason(_ session: Session, codexHome: String, executablePath: String? = executable()) -> String? {
        guard session.app == .codex else {
            return session.app == .hermes
                ? "Hermes exposes bulk archive filters, but this installed CLI has no exact session-ID archive action. Open Hermes to archive this chat."
                : "This provider has no supported archive interface connected to Session Monitor. Archive the chat in its original app."
        }
        guard !session.savedBookmark else { return "Refresh this chat from its source before archiving it." }
        guard !session.isSubagent else { return "Archive the parent chat in Codex; individual worker chats are managed by their parent." }
        guard [.idle, .responseReady, .done, .ended].contains(session.detectedState ?? session.state) else {
            return "Only inactive chats with a known state can be archived here. Open Codex to manage a running chat."
        }
        guard UUID(uuidString: session.sessionID) != nil else { return "This chat does not have a valid Codex thread ID." }
        let root = URL(fileURLWithPath: LocalFiles.expanded(codexHome)).standardizedFileURL.resolvingSymlinksInPath().path
        let source = URL(fileURLWithPath: session.sourcePath).standardizedFileURL.resolvingSymlinksInPath().path
        guard source.hasPrefix(root + "/") else { return "This chat is outside the configured Codex home." }
        guard executablePath != nil else { return "Install the Codex CLI to enable native archiving." }
        return nil
    }
    static func archive(_ session: Session, codexHome: String, executablePath: String? = executable()) async throws {
        if let reason = unavailableReason(session, codexHome: codexHome, executablePath: executablePath) { throw Failure.message(reason) }
        guard let executable = executablePath else { throw Failure.message("Codex CLI is unavailable.") }
        let home = LocalFiles.expanded(codexHome)
        try await Task.detached(priority: .userInitiated) {
            try requestArchive(executable: executable, home: home, threadID: session.sessionID)
        }.value
    }
    /// One bounded stdio connection. No model turn, resume command or automatic retries.
    static func requestArchive(executable: String, home: String, threadID: String, timeout: TimeInterval = 15) throws {
        guard UUID(uuidString: threadID) != nil else { throw Failure.message("Invalid thread ID.") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        var buffer = Data(), total = 0, dispatched = false
        let deadline = Date().addingTimeInterval(timeout)
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func receive(_ id: Int) throws -> [String: Any] {
            while Date() < deadline {
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["id"] as? Int == id else { continue }
                    if let error = object["error"] as? [String: Any] {
                        throw Failure.message("Codex rejected the archive action: \(error["message"] as? String ?? "Unknown error")")
                    }
                    guard let result = object["result"] as? [String: Any] else { throw Failure.message("Codex returned an invalid response. Check the chat in Codex before retrying.") }
                    return result
                }
                var chunk = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(descriptor, &chunk, chunk.count)
                if count > 0 {
                    total += count
                    guard total <= 1_048_576 else { throw Failure.message("Codex returned too much data. Check the chat in Codex before retrying.") }
                    buffer.append(contentsOf: chunk.prefix(count)); continue
                }
                if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { break }
                Thread.sleep(forTimeInterval: 0.015)
            }
            throw Failure.message(dispatched
                ? "The archive request was sent, but no acknowledgment arrived. Its outcome is unknown. Check the chat in Codex before retrying."
                : "Could not initialize the Codex archive interface. No archive request was sent.")
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "session_monitor", "title": "Session Monitor", "version": "0.5.0"]]])
        _ = try receive(1)
        try send(["method": "initialized", "params": [:]])
        // Treat even an interrupted write as ambiguous; never retry automatically.
        dispatched = true
        do { try send(["id": 2, "method": "thread/archive", "params": ["threadId": threadID]]) }
        catch { throw Failure.message("The archive request may have been sent. Check the chat in Codex before retrying.") }
        _ = try receive(2)
    }
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { switch self { case .message(let value): value } }
    }
}
