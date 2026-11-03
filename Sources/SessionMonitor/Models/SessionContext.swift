import Foundation

struct MessagePreview: Codable, Sendable, Equatable {
    var text: String
    var role: String
    var recordedAt: Date?
    var truncated = false
    var coverage = "Last message found in the recent transcript tail"
    var roleLabel: String { role == "assistant" ? "Assistant" : "You" }
}

struct WorktreeInfo: Codable, Sendable, Equatable {
    var root: String
    var repository: String
    var branch: String
    var isLinked: Bool
    var inspectedAt: Date
    var name: String { URL(fileURLWithPath: root).lastPathComponent }
    var repositoryName: String { URL(fileURLWithPath: repository).lastPathComponent }
}

enum SessionRelationKind: String, Codable, Sendable {
    case parent, subagent, continuedFrom, continuedAs, child, forkedFrom, forkedAs, providerSession, host
    var label: String {
        switch self {
        case .parent: "Parent"
        case .subagent: "Subagent"
        case .continuedFrom: "Continued from"
        case .continuedAs: "Continued as"
        case .child: "Child session"
        case .forkedFrom: "Forked from"
        case .forkedAs: "Forked as"
        case .providerSession: "Provider record"
        case .host: "Host chat"
        }
    }
    var isChild: Bool { [.subagent, .child, .continuedAs].contains(self) }
}
struct RelatedSession: Identifiable, Codable, Sendable, Equatable {
    var id: String
    var title: String
    var kind: SessionRelationKind
    var note = ""
}

struct SessionAnnotation: Codable, Sendable, Equatable {
    var bookmarked = false
    var bookmarkedAt: Date?
    var notes = ""
    var statusOverride: SessionState?
    var savedSession: Session?
    var archivedInSourceAt: Date?
}

/// Optional in Session so annotations saved by older releases remain readable.
/// Every field comes from provider records; absent values are not zero or live state.
struct SessionRecord: Codable, Sendable, Equatable {
    var startedAt: Date?
    var endedAt: Date?
    var firstObservedAt: Date?
    var outcome: String?
    var activity: String?
    var agentPath: String?
    var depth: Int?
    var taskDescription: String?
    var providerVersion: String?
    var modelSource: String?
    var costSource: String?
    var lastTurnUsage: TokenUsage?
    var transcriptBytes: UInt64?
    var transcriptModifiedAt: Date?
    var readCoverage: String?
    var relationshipCoverage: String?
}

struct ExpandedRecord: Sendable {
    var summary: TranscriptSummary
    func matches(_ session: Session) -> Bool {
        summary.record.transcriptBytes == session.record?.transcriptBytes &&
        summary.record.transcriptModifiedAt == session.record?.transcriptModifiedAt
    }
    func apply(to original: Session) -> Session {
        guard matches(original) else { return original }
        var result = original
        if let usage = summary.usage { result.usage = usage }
        if let message = summary.lastMessage { result.lastMessage = message }
        result.record?.lastTurnUsage = summary.record.lastTurnUsage
        result.record?.readCoverage = summary.record.readCoverage
        return result
    }
}
