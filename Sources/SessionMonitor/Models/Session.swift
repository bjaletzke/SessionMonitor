import Foundation
import CoreFoundation

enum AgentApp: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex = "Codex", claude = "Claude Code", hermes = "Hermes", t3 = "T3 Code", harness = "Harness"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .codex: "terminal"
        case .claude: "asterisk"
        case .hermes: "paperplane"
        case .t3: "bubble.left.and.bubble.right"
        case .harness: "point.3.connected.trianglepath.dotted"
        }
    }
}

enum SessionState: String, CaseIterable, Codable, Sendable {
    case running, needsAttention = "needs_attention", waitingForAnswer = "waiting_for_answer", approvalNeeded = "approval_needed", responseReady = "response_ready", idle, done, ended, error, unknown
    var label: String {
        switch self {
        case .running: "Running"
        case .needsAttention: "Needs attention"
        case .waitingForAnswer: "Waiting for answer"
        case .approvalNeeded: "Approval needed"
        case .responseReady: "Response ready"
        case .idle: "Idle"
        case .done: "Done"
        case .ended: "Ended"
        case .error: "Error"
        case .unknown: "Unknown"
        }
    }
    var priority: Int {
        switch self {
        case .needsAttention, .waitingForAnswer, .approvalNeeded: 0
        case .error: 1
        case .running: 2
        case .responseReady: 3
        case .idle: 4
        case .unknown: 5
        case .done: 6
        case .ended: 7
        }
    }
    var needsAction: Bool { [.needsAttention, .waitingForAnswer, .approvalNeeded, .error].contains(self) }
}

enum StatusConfidence: String, Codable, Sendable {
    case reported, estimated, historical, unavailable, manual
    var label: String {
        switch self {
        case .reported: "Reported"
        case .estimated: "Estimated"
        case .historical: "Last recorded"
        case .unavailable: "Unverified"
        case .manual: "Local override"
        }
    }
}

struct Session: Identifiable, Codable, Sendable, Equatable {
    var id: String
    var sessionID: String
    var app: AgentApp
    var title: String
    var model: String = ""
    var provider: String = ""
    var workspace: String = ""
    var origin: String = ""
    var state: SessionState = .unknown
    var confidence: StatusConfidence = .unavailable
    var evidence: String = "No runtime signal is available."
    var updatedAt: Date
    var sourcePath: String = ""
    var pid: Int32?
    var parentID: String?
    var isOpen = false
    var completedAt: Date?
    var question: String = ""
    var usage: TokenUsage?
    var quota: QuotaSnapshot?
    var desktopSessionID: String = ""
    var detectedState: SessionState?
    var lastMessage: MessagePreview?
    var gitBranch = ""
    var worktree: WorktreeInfo?
    var relations: [RelatedSession] = []
    var agentRole = ""
    var agentNickname = ""
    var parentKey: String?
    var isSubagent = false
    var savedBookmark = false
    var record: SessionRecord?
    var environmentID: String?
    /// Exact native-thread ownership reported by a loaded host chat.
    var hostSessionID: String?

    var workspaceName: String {
        workspace.isEmpty ? "No workspace" : URL(fileURLWithPath: workspace).lastPathComponent
    }
    var displayModel: String { model.isEmpty ? "Not recorded" : model }
    var searchText: String { [title, app.rawValue, model, provider, workspace, sessionID, origin, state.label, question, gitBranch, worktree?.branch ?? "", agentRole, agentNickname].joined(separator: " ") }
}

struct SourceHealth: Identifiable, Codable, Sendable {
    var app: AgentApp
    var count: Int
    var available: Bool
    var message: String
    var path: String
    var id: AgentApp { app }
}

struct SessionSnapshot: Sendable {
    var sessions: [Session] = []
    var sources: [SourceHealth] = []
    var scannedAt = Date()
    var duration: TimeInterval = 0
    var usage: [UsageOverview] = []
}

struct ScanConfiguration: Sendable {
    var codexHome: String
    var claudeHome: String
    var hermesHome: String
    var harnessDirectory: String
    var limit: Int
    var t3Home = ""
}

/// Counters retain provider semantics. Cached input/reasoning may be subsets;
/// never add them to provider totals a second time.
struct TokenUsage: Codable, Sendable, Equatable {
    var input: Int64?
    var output: Int64?
    var cacheRead: Int64?
    var cacheWrite: Int64?
    var reasoning: Int64?
    var total: Int64?
    var estimatedCostUSD: Double?
    var actualCostUSD: Double?
    var costStatus: String = ""
    var coverage: String = ""
    var note: String = ""
    var totalIsPartial: Bool?
    var displayCount: Int64? {
        if let total { return total }
        guard let input, let output else { return nil }
        let (sum, overflow) = input.addingReportingOverflow(output)
        return overflow ? nil : sum
    }
    /// Chart parts are disjoint: Codex cache/reasoning counters are subsets,
    /// while Claude and Hermes record those counters separately.
    func chartSegments(for app: AgentApp) -> [TokenSegment] {
        let parts: [(TokenSegment.Kind, Int64?)]
        if app == .codex {
            let uncached = input.map { max(0, $0) - min(max(0, $0), max(0, cacheRead ?? 0)) }
            let visible = output.map { max(0, $0) - min(max(0, $0), max(0, reasoning ?? 0)) }
            parts = [(.input, uncached), (.cacheRead, cacheRead), (.output, visible), (.reasoning, reasoning)]
        } else {
            parts = [(.input, input), (.output, output), (.cacheRead, cacheRead), (.cacheWrite, cacheWrite), (.reasoning, reasoning)]
        }
        let segments = parts.compactMap { kind, value -> TokenSegment? in
            guard let value, value > 0 else { return nil }
            return TokenSegment(kind: kind, value: value)
        }
        // Index-only records (including Codex archive totals) have no breakdown.
        if segments.isEmpty, let total, total > 0 {
            return [TokenSegment(kind: .recordedTotal, value: total)]
        }
        return segments
    }
    static func cost(_ value: String?) -> Double? {
        guard let value, let number = Double(value), number.isFinite, number >= 0 else { return nil }
        return number
    }
    static func sum(_ values: [Int64?]) -> Int64? {
        let recorded = values.compactMap { $0 }
        guard !recorded.isEmpty else { return nil }
        var result: Int64 = 0
        for value in recorded {
            let (next, overflow) = result.addingReportingOverflow(value)
            guard !overflow else { return nil }
            result = next
        }
        return result
    }
    static func number(_ value: Any?) -> Int64? {
        let n: Int64?
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue < Double(Int64.max), value.doubleValue.rounded(.towardZero) == value.doubleValue else { return nil }
            n = value.int64Value
        }
        else if let value = value as? String { n = Int64(value) }
        else { n = nil }
        return n.flatMap { $0 >= 0 ? $0 : nil }
    }
    static func codex(_ value: [String: Any]) -> TokenUsage {
        TokenUsage(input: number(value["input_tokens"]), output: number(value["output_tokens"]),
                   cacheRead: number(value["cached_input_tokens"]), cacheWrite: number(value["cache_write_input_tokens"]),
                   reasoning: number(value["reasoning_output_tokens"]), total: number(value["total_tokens"]),
                   coverage: "Session cumulative counters", note: "Cached input is included in input; reasoning is included in output. Recorded token activity is not a bill.")
    }
}

struct QuotaWindow: Codable, Sendable, Equatable {
    var usedPercent: Double
    var minutes: Int
    var resetsAt: Date
    var label: String {
        if minutes % 1440 == 0 { return "\(minutes / 1440) day window" }
        if minutes % 60 == 0 { return "\(minutes / 60) hour window" }
        return "\(minutes) minute window"
    }
}
struct QuotaSnapshot: Codable, Sendable, Equatable {
    var recordedAt: Date
    var windows: [QuotaWindow]
    var limitID: String
    static func parse(_ object: [String: Any], recordedAt: Date) -> QuotaSnapshot? {
        let windows = ["primary", "secondary"].compactMap { key -> QuotaWindow? in
            guard let window = object[key] as? [String: Any], let used = window["used_percent"] as? Double,
                  used.isFinite, (0...100).contains(used), let minutes = TokenUsage.number(window["window_minutes"]), minutes > 0, minutes <= 525600,
                  let reset = LocalFiles.date(window["resets_at"]) else { return nil }
            return QuotaWindow(usedPercent: used, minutes: Int(minutes), resetsAt: reset)
        }
        return windows.isEmpty ? nil : QuotaSnapshot(recordedAt: recordedAt, windows: windows, limitID: object["limit_id"] as? String ?? "codex")
    }
}
struct UsageOverview: Identifiable, Codable, Sendable {
    var app: AgentApp
    var sessions: Int
    var usage: TokenUsage?
    var scope: String
    var recordedAt: String
    var id: AgentApp { app }
}

/// Review is a local acknowledgement of one completed response, never of the task's correctness.
struct ReviewAcknowledgements {
    var dates: [String: Double] = [:]
    func apply(to original: Session) -> Session {
        var session = original
        if session.state == .responseReady, let completed = session.completedAt,
           let reviewed = dates[session.id], reviewed >= completed.timeIntervalSince1970 {
            session.state = .idle
            session.evidence += " You marked this response reviewed in Session Monitor."
        }
        return session
    }
}
