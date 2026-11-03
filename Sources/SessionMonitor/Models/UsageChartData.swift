import Foundation

struct TokenSegment: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case input = "Input", output = "Output", cacheRead = "Cache read"
        case cacheWrite = "Cache write", reasoning = "Reasoning", recordedTotal = "Recorded total"

        func label(for app: AgentApp) -> String {
            if app == .codex || app == .t3 {
                if self == .input { return "Uncached input" }
                if self == .output { return "Visible output" }
            }
            return rawValue
        }
    }
    let kind: Kind
    let value: Int64
    var id: Kind { kind }
}

struct DailyTokenUsage: Identifiable {
    let day: Date
    let app: AgentApp
    var value: Double
    var id: String { "\(day.timeIntervalSince1970)-\(app.rawValue)" }

    static func buckets(sessions: [Session], now: Date = Date(), calendar: Calendar = .current) -> [DailyTokenUsage] {
        let today = calendar.startOfDay(for: now)
        let days = (-6...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        guard let start = days.first else { return [] }
        var totals: [Date: [AgentApp: Double]] = [:]
        let childHosts = Set(sessions.filter { $0.app == .t3 && $0.isSubagent }.map(\.id))
        let measuredHosts = Set(sessions.filter {
            $0.app == .t3 && !$0.isSubagent && $0.updatedAt >= start && $0.updatedAt <= now && $0.usage?.displayCount != nil
        }.map(\.id))
        for session in sessions where !session.isSubagent && session.updatedAt >= start && session.updatedAt <= now {
            if let host = session.hostSessionID, measuredHosts.contains(host) || childHosts.contains(host) { continue }
            guard let count = session.usage?.displayCount, count > 0 else { continue }
            let day = calendar.startOfDay(for: session.updatedAt)
            // Doubles avoid integer overflow when aggregating many cumulative counters.
            totals[day, default: [:]][session.app, default: 0] += Double(count)
        }
        return days.flatMap { day in
            AgentApp.allCases.map { DailyTokenUsage(day: day, app: $0, value: totals[day]?[$0] ?? 0) }
        }
    }
}
