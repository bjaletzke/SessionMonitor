import Foundation

/// Small database aggregates and provider-owned caches. No full transcript scans or account requests.
enum UsageReader {
    static func scan(_ config: ScanConfiguration) -> [UsageOverview] {
        [codex(home: LocalFiles.expanded(config.codexHome)),
         claude(home: LocalFiles.expanded(config.claudeHome)),
         hermes(home: LocalFiles.expanded(config.hermesHome)),
         T3UsageReader.overview(home: LocalFiles.expanded(config.t3Home))]
    }
    static func codex(home: String) -> UsageOverview {
        do {
            let files = LocalFiles.children(home).filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
                .sorted { (Int($0.deletingPathExtension().lastPathComponent.dropFirst(6)) ?? 0) > (Int($1.deletingPathExtension().lastPathComponent.dropFirst(6)) ?? 0) }
            guard let file = files.first else { throw DatabaseError.failure("No session index") }
            let db = try ReadOnlyDatabase(path: file.path), cols = try db.columns("threads")
            guard cols.contains("tokens_used") else { throw DatabaseError.failure("Token totals unavailable in this schema") }
            let row = try db.rows("SELECT COUNT(*) AS sessions, SUM(tokens_used) AS total, COUNT(tokens_used) AS covered FROM threads").first ?? [:]
            let usage = TokenUsage(total: TokenUsage.number(row["total"]), coverage: "\(row["covered"] ?? "0") indexed records with counters",
                                   note: "All indexed threads, including archived records. Forks or shared history may overlap; this is recorded activity, not billing or your account allowance.")
            return UsageOverview(app: .codex, sessions: Int(row["sessions"] ?? "0") ?? 0, usage: usage, scope: "Entire local session index", recordedAt: "Read from disk now")
        } catch { return unavailable(.codex, error.localizedDescription) }
    }
    static func claude(home: String) -> UsageOverview {
        guard let object = LocalFiles.object(URL(fileURLWithPath: home + "/stats-cache.json")), let models = object["modelUsage"] as? [String: [String: Any]] else {
            return unavailable(.claude, "No overall stats-cache.json; per-session transcript counters may still be available.")
        }
        func sum(_ key: String) -> Int64? {
            let values = models.values.compactMap { TokenUsage.number($0[key]) }
            return TokenUsage.sum(values.map { Optional($0) })
        }
        let incomplete = models.values.contains { model in
            ["inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"].contains { TokenUsage.number(model[$0]) == nil }
        }
        let input = sum("inputTokens"), output = sum("outputTokens"), read = sum("cacheReadInputTokens"), write = sum("cacheCreationInputTokens")
        let usage = TokenUsage(input: input, output: output, cacheRead: read, cacheWrite: write,
                               total: TokenUsage.sum([input, output, read, write]),
                               coverage: "Provider-owned stats cache", note: "Snapshot only; may omit newer sessions. Claude cache input is counted separately and included in this total. Cached costUSD is not treated as a subscription bill.\(incomplete ? " Some counters are missing; the displayed total is a recorded subtotal." : "")", totalIsPartial: incomplete)
        return UsageOverview(app: .claude, sessions: (object["totalSessions"] as? NSNumber)?.intValue ?? 0, usage: usage,
                             scope: "Claude's cached overall statistics", recordedAt: "Computed through \(object["lastComputedDate"] as? String ?? "unknown date")")
    }
    static func hermes(home: String) -> UsageOverview {
        var roots = [URL(fileURLWithPath: home)]
        roots += LocalFiles.children(home + "/profiles").filter { LocalFiles.exists($0.appendingPathComponent("state.db").path) }
        var count = 0, covered = 0, actualCovered = 0, errors = 0, found = false
        var sums: [String: Int64] = [:], costs: [String: Double] = [:]
        for root in roots where LocalFiles.exists(root.appendingPathComponent("state.db").path) {
            do {
                let db = try ReadOnlyDatabase(path: root.appendingPathComponent("state.db").path), cols = try db.columns("sessions")
                let tokens = ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens"].filter { cols.contains($0) }
                let costFields = ["estimated_cost_usd", "actual_cost_usd"].filter { cols.contains($0) }
                var fields = ["COUNT(*) AS sessions"] + (tokens + costFields).map { "SUM(\($0)) AS \($0)" }
                if cols.contains("input_tokens") { fields.append("COUNT(input_tokens) AS covered") }
                if cols.contains("actual_cost_usd") { fields.append("COUNT(actual_cost_usd) AS actual_covered") }
                let row = try db.rows("SELECT \(fields.joined(separator: ",")) FROM sessions").first ?? [:]
                found = true; count += Int(row["sessions"] ?? "0") ?? 0; covered += Int(row["covered"] ?? "0") ?? 0
                actualCovered += Int(row["actual_covered"] ?? "0") ?? 0
                for key in tokens { if let n = TokenUsage.number(row[key]) { sums[key, default: 0] += n } }
                for key in costFields { if let n = row[key].flatMap(Double.init), n.isFinite { costs[key, default: 0] += n } }
            } catch { errors += 1 }
        }
        guard found else { return unavailable(.hermes, "No readable session usage database") }
        let usage = TokenUsage(input: sums["input_tokens"], output: sums["output_tokens"], cacheRead: sums["cache_read_tokens"], cacheWrite: sums["cache_write_tokens"], reasoning: sums["reasoning_tokens"],
                               estimatedCostUSD: costs["estimated_cost_usd"], actualCostUSD: costs["actual_cost_usd"],
                               coverage: "\(covered) records with input counters; \(actualCovered) with actual cost",
                               note: "All stored records across profiles, including ended/archived records. Input + output excludes separately stored cache counters. Estimated and actual cost cover different subsets; do not add them.\(errors > 0 ? " \(errors) profiles could not be read; aggregate is partial." : "")")
        return UsageOverview(app: .hermes, sessions: count, usage: usage, scope: "Entire local archive · root and profiles", recordedAt: "Read from disk now")
    }
    private static func unavailable(_ app: AgentApp, _ reason: String) -> UsageOverview {
        UsageOverview(app: app, sessions: 0, scope: reason, recordedAt: "Unavailable")
    }
}
