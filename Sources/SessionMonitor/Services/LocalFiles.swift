import Foundation
import Darwin

enum LocalFiles {
    static func children(_ path: String) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    }
    /// Nonblocking open plus fstat rejects FIFOs/devices before any read. Only regular
    /// files up to the declared cap are accepted; never read an unbounded stream.
    static func boundedData(_ url: URL, maximum: Int) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count >= 0, count <= maximum else { return nil }
        return Data(bytes.prefix(count))
    }
    static func object(_ url: URL) -> [String: Any]? {
        guard let data = boundedData(url, maximum: 2_000_000),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
    static func modification(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    static func expanded(_ path: String) -> String { (path as NSString).expandingTildeInPath }
    static func date(_ value: Any?) -> Date? {
        if let value = value as? NSNumber {
            let number = value.doubleValue
            guard number.isFinite, number > 0 else { return nil }
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        }
        if let value = value as? String {
            if let number = Double(value) { return date(NSNumber(value: number)) }
            return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)) ??
                (try? Date.ISO8601FormatStyle().parse(value))
        }
        return nil
    }
    static func boundedTitle(_ text: String?, fallback: String) -> String {
        let clean = (text ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return clean.isEmpty ? fallback : String(clean.prefix(180))
    }
}

/// A single process snapshot per refresh verifies local registry PIDs and Claude's PID start time.
struct ProcessInventory {
    var starts: [Int32: String] = [:]
    init() {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,lstart="]
        // Claude stores ps lstart in UTC, independently of the Mac's display timezone.
        process.environment = ProcessInfo.processInfo.environment.merging(["TZ": "UTC", "LC_ALL": "C"]) { _, value in value }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 6, let pid = Int32(fields[0]) else { continue }
            starts[pid] = fields.dropFirst().joined(separator: " ")
        }
    }
    func matches(pid: Int32, start: String? = nil) -> Bool {
        guard pid > 0, let actual = starts[pid] else { return false }
        guard let start, !start.isEmpty else { return true }
        return start.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") == actual
    }
}

struct TranscriptSummary: Sendable {
    var title = ""
    var model = ""
    var workspace = ""
    var state: SessionState = .unknown
    var confidence: StatusConfidence = .unavailable
    var evidence = "No recognizable lifecycle event in the bounded transcript tail."
    var lastEvent: Date?
    var completedAt: Date?
    var question = ""
    var usage: TokenUsage?
    var quota: QuotaSnapshot?
    var lastMessage: MessagePreview?
    var gitBranch = ""
    var agentName = ""
    var agentRole = ""
    var provider = ""
    var parentID: String?
    var forkedFromID: String?
    var record = SessionRecord()
}

/// Cache only extracted metadata, not raw messages or tool outputs.
final class TranscriptReader {
    private struct Entry { var size: UInt64; var modified: Date; var summary: TranscriptSummary }
    private var cache: [String: Entry] = [:]
    static let refreshBytes = 131_072
    static let detailBytes = 8 * 1_048_576
    func summary(path: String, app: AgentApp, now: Date, expanded: Bool = false) -> TranscriptSummary {
        let url = URL(fileURLWithPath: path)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return TranscriptSummary(evidence: "The transcript is missing or unreadable.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            return TranscriptSummary(evidence: "The transcript is not a regular file.")
        }
        let size = UInt64(info.st_size)
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        let cap = expanded ? Self.detailBytes : Self.refreshBytes
        let key = "\(app.rawValue):\(cap):\(path)"
        var raw: TranscriptSummary
        if let cached = cache[key], cached.size == size, cached.modified == modified {
            raw = cached.summary
        } else {
            let offset = size > UInt64(cap) ? size - UInt64(cap) : 0
            do {
                try file.seek(toOffset: offset)
                let data = try file.read(upToCount: cap) ?? Data()
                let objects = Self.objects(data, skipFirst: offset > 0)
                raw = Self.reduce(objects: objects, app: app, completeFile: offset == 0)
                // Startup identity has independent coverage. Never merge old lifecycle or token
                // events into recent state, or count head and tail messages twice.
                if offset > 0 {
                    try file.seek(toOffset: 0)
                    let head = try file.read(upToCount: Self.refreshBytes) ?? Data()
                    let metadata = Self.reduce(objects: Self.objects(head, skipFirst: false), app: app)
                    raw.record.startedAt = metadata.record.startedAt
                    raw.record.firstObservedAt = metadata.record.firstObservedAt
                    raw.record.providerVersion = raw.record.providerVersion ?? metadata.record.providerVersion
                    raw.record.agentPath = raw.record.agentPath ?? metadata.record.agentPath
                    raw.record.depth = raw.record.depth ?? metadata.record.depth
                    raw.parentID = raw.parentID ?? metadata.parentID
                    raw.forkedFromID = raw.forkedFromID ?? metadata.forkedFromID
                    if raw.agentName.isEmpty { raw.agentName = metadata.agentName }
                    if raw.agentRole.isEmpty { raw.agentRole = metadata.agentRole }
                    if raw.model.isEmpty {
                        raw.model = metadata.model
                        if !metadata.model.isEmpty { raw.record.modelSource = "Startup transcript · may predate a model change" }
                    }
                    if raw.provider.isEmpty { raw.provider = metadata.provider }
                    if raw.workspace.isEmpty { raw.workspace = metadata.workspace }
                    if raw.title.isEmpty { raw.title = metadata.title }
                }
                raw.record.transcriptBytes = size
                raw.record.transcriptModifiedAt = modified
                raw.record.readCoverage = offset == 0 ? "Entire available file (\(size.formatted()) bytes)" : "Recent \(cap.formatted()) bytes of \(size.formatted()); startup metadata read separately"
                if raw.lastMessage != nil {
                    raw.lastMessage?.coverage = offset == 0 ? "Last conversation message in the available file" : "Last conversation message found in the bounded transcript tail"
                }
                if cache.count > 1800 { cache.removeAll(keepingCapacity: true) }
                cache[key] = Entry(size: size, modified: modified, summary: raw)
            } catch { return TranscriptSummary(evidence: "The transcript could not be read.") }
        }
        return Self.age(raw, now: now)
    }
    private static func objects(_ data: Data, skipFirst: Bool) -> [[String: Any]] {
        var lines = data.split(separator: 10, omittingEmptySubsequences: true)
        if skipFirst, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    static func age(_ raw: TranscriptSummary, now: Date) -> TranscriptSummary {
        var result = raw
        if raw.state == .running,
           raw.lastEvent == nil || now.timeIntervalSince(raw.lastEvent!) > 600 || now.timeIntervalSince(raw.lastEvent!) < -60 {
            result.state = .unknown
            result.confidence = .unavailable
            result.evidence = "The last activity signal is over 10 minutes old; current state cannot be verified."
        }
        return result
    }

    static func reduce(objects: [[String: Any]], app: AgentApp, completeFile: Bool = false) -> TranscriptSummary {
        var result = TranscriptSummary()
        var pending: [String: String] = [:]
        var claudeUsage: [String: [String: Int64]] = [:]
        func clearCompletion() { result.completedAt = nil; result.question = ""; result.record.outcome = nil }
        func ready(_ timestamp: Date?) {
            pending.removeAll(); result.question = ""
            result.state = .responseReady; result.confidence = .historical
            result.completedAt = timestamp ?? result.completedAt
            result.record.outcome = "Response completed"
            result.evidence = "The last recorded response finished and is available for review. This does not prove the overall task is complete."
        }
        func question(_ arguments: Any?) -> String {
            var object = arguments as? [String: Any]
            if let text = arguments as? String, let data = text.data(using: .utf8) {
                object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            let questions = object?["questions"] as? [[String: Any]] ?? []
            return String(questions.compactMap { $0["question"] as? String ?? $0["title"] as? String }.joined(separator: "\n").prefix(1200))
        }
        for object in objects {
            let type = object["type"] as? String ?? ""
            let payload = object["payload"] as? [String: Any] ?? [:]
            let timestamp = LocalFiles.date(object["timestamp"])
            if let timestamp {
                result.lastEvent = max(result.lastEvent ?? .distantPast, timestamp)
                result.record.firstObservedAt = min(result.record.firstObservedAt ?? .distantFuture, timestamp)
            }
            if app == .codex, type == "session_meta" {
                result.record.startedAt = LocalFiles.date(payload["timestamp"]) ?? timestamp
                result.record.providerVersion = payload["cli_version"] as? String
                result.provider = payload["model_provider"] as? String ?? ""
                result.workspace = payload["cwd"] as? String ?? result.workspace
                let source = payload["source"] as? [String: Any]
                let subagent = source?["subagent"] as? [String: Any]
                let spawn = subagent?["thread_spawn"] as? [String: Any] ?? [:]
                result.parentID = payload["parent_thread_id"] as? String ?? spawn["parent_thread_id"] as? String
                result.forkedFromID = payload["forked_from_id"] as? String
                result.agentName = payload["agent_nickname"] as? String ?? spawn["agent_nickname"] as? String ?? ""
                result.agentRole = payload["agent_role"] as? String ?? spawn["agent_role"] as? String ?? ""
                result.record.agentPath = payload["agent_path"] as? String ?? spawn["agent_path"] as? String
                result.record.depth = TokenUsage.number(spawn["depth"]).flatMap { Int(exactly: $0) }
            }
            if app == .codex, type == "token_usage_record" {
                if let usage = payload["thread_token_usage"] as? [String: Any] {
                    result.usage = TokenUsage.codex(usage)
                    result.usage?.coverage = "Recorded thread cumulative counters · token_usage_record"
                }
                if let usage = payload["turn_token_usage"] as? [String: Any] {
                    result.record.lastTurnUsage = TokenUsage.codex(usage)
                    result.record.lastTurnUsage?.coverage = "Last recorded turn cumulative counters · may be in progress"
                }
            }
            if app == .claude, let version = object["version"] as? String { result.record.providerVersion = version }
            if let cwd = object["cwd"] as? String { result.workspace = cwd }
            if let branch = object["gitBranch"] as? String { result.gitBranch = branch }
            if type == "agent-name", let name = object["agentName"] as? String { result.agentName = name }
            if app == .codex, type == "response_item", payload["type"] as? String == "message",
               payload["channel"] as? String != "analysis", let role = payload["role"] as? String,
               let preview = MessageText.preview(MessageText.extract(payload["content"]), role: role, at: timestamp) {
                result.lastMessage = preview
            }
            if app == .codex, type == "event_msg" {
                let eventType = payload["type"] as? String ?? ""
                if ["user_message", "agent_message"].contains(eventType),
                   let preview = MessageText.preview(payload["message"] as? String, role: eventType == "user_message" ? "user" : "assistant", at: timestamp) {
                    result.lastMessage = preview
                }
                if eventType == "task_complete", let preview = MessageText.preview(payload["last_agent_message"] as? String, role: "assistant", at: timestamp) { result.lastMessage = preview }
            }
            if app == .codex {
                if type == "turn_context", let model = payload["model"] as? String {
                    result.model = model; result.record.modelSource = "Last recorded turn context"
                }
                if type == "event_msg" {
                    switch payload["type"] as? String {
                    case "task_started", "user_message":
                        clearCompletion(); pending.removeAll()
                        result.state = .running; result.confidence = .estimated
                        result.evidence = "A turn started in the local event log; runtime connection is unavailable."
                    case "task_complete": ready(timestamp)
                    case "turn_aborted":
                        clearCompletion(); pending.removeAll()
                        result.state = .idle; result.confidence = .historical
                        result.record.outcome = "Turn interrupted"
                        result.evidence = "The last recorded turn was interrupted."
                    case "exec_approval_request", "apply_patch_approval_request":
                        clearCompletion(); result.state = .approvalNeeded; result.confidence = .estimated
                        result.evidence = "An approval request was recorded; its current resolution is unverified."
                    case "token_count":
                        if let info = payload["info"] as? [String: Any], let usage = info["total_token_usage"] as? [String: Any] {
                            result.usage = TokenUsage.codex(usage)
                        }
                        if let limits = payload["rate_limits"] as? [String: Any], let timestamp {
                            result.quota = QuotaSnapshot.parse(limits, recordedAt: timestamp)
                        }
                    default: break
                    }
                }
                if type == "response_item", let kind = payload["type"] as? String {
                    if kind == "message", payload["role"] as? String == "assistant", payload["channel"] as? String == "final" {
                        ready(timestamp)
                    } else if kind == "function_call", (payload["name"] as? String ?? "").hasSuffix("request_user_input"), let id = payload["call_id"] as? String {
                        clearCompletion(); pending[id] = question(payload["arguments"])
                        result.state = .waitingForAnswer; result.confidence = .estimated
                        result.question = pending[id] ?? ""
                        result.evidence = "A structured question has no matching tool result in the recorded tail; its current resolution is unverified."
                    } else if ["function_call_output", "custom_tool_call_output"].contains(kind), let id = payload["call_id"] as? String, pending.removeValue(forKey: id) != nil {
                        result.question = pending.values.joined(separator: "\n")
                        result.state = pending.isEmpty ? .running : .waitingForAnswer
                        result.confidence = .estimated
                        result.evidence = pending.isEmpty ? "The recorded question received a result; the turn may still be running." : "Another recorded question is unresolved."
                    } else if result.state == .unknown, ["reasoning", "function_call", "custom_tool_call"].contains(kind) {
                        result.state = .running; result.confidence = .estimated
                        result.evidence = "Recent model or tool activity in the local event log; current state is estimated."
                    }
                }
            } else if app == .claude {
                if type == "custom-title", let title = object["customTitle"] as? String { result.title = title }
                let message = object["message"] as? [String: Any] ?? [:]
                if let model = message["model"] as? String { result.model = model; result.record.modelSource = "Last recorded assistant message" }
                let content = message["content"] as? [[String: Any]] ?? []
                if ["user", "assistant"].contains(type), object["isMeta"] as? Bool != true,
                   let preview = MessageText.preview(MessageText.extract(message["content"]), role: type, at: timestamp) {
                    result.lastMessage = preview
                }
                if type == "assistant", let usage = message["usage"] as? [String: Any], let id = message["id"] as? String {
                    var counters = claudeUsage[id] ?? [:]
                    for key in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
                        if let n = TokenUsage.number(usage[key]) { counters[key] = max(counters[key] ?? 0, n) }
                    }
                    claudeUsage[id] = counters
                }
                if type == "assistant", ["end_turn", "stop_sequence"].contains(message["stop_reason"] as? String ?? "") {
                    ready(timestamp)
                } else if type == "user" || type == "assistant" {
                    clearCompletion()
                    for block in content {
                        if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String { pending.removeValue(forKey: id) }
                        if block["type"] as? String == "tool_use", block["name"] as? String == "AskUserQuestion", let id = block["id"] as? String {
                            pending[id] = question(block["input"])
                        }
                    }
                    result.question = pending.values.joined(separator: "\n")
                    result.state = pending.isEmpty ? .unknown : .waitingForAnswer
                    result.confidence = pending.isEmpty ? .unavailable : .estimated
                    result.evidence = pending.isEmpty ? "A transcript exists, but no verified live process reports this session's state." : "A structured AskUserQuestion request has no matching result in the recorded tail."
                }
            }
        }
        if app == .claude, !claudeUsage.isEmpty {
            func sum(_ key: String) -> Int64? {
                let values = claudeUsage.values.compactMap { $0[key] }
                return TokenUsage.sum(values.map { Optional($0) })
            }
            let incomplete = claudeUsage.values.contains { counters in
                ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].contains { counters[$0] == nil }
            }
            let input = sum("input_tokens"), output = sum("output_tokens"), read = sum("cache_read_input_tokens"), write = sum("cache_creation_input_tokens")
            result.usage = TokenUsage(input: input, output: output, cacheRead: read, cacheWrite: write,
                                      total: TokenUsage.sum([input, output, read, write]),
                                      coverage: completeFile ? "Available transcript · deduplicated messages" : "Recent transcript tail only · partial session",
                                      note: "Claude records cached input separately. Total includes input, output, cache read and cache write. Duplicate message IDs count once. Subscription charges are unavailable.\(incomplete ? " Some counter fields are missing; the displayed total is a recorded subtotal." : "")", totalIsPartial: incomplete)
        }
        return result
    }
}
