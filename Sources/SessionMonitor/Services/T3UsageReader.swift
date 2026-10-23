import Foundation

/// T3's normalized `turnTokenUsage` is consumption. `tokenUsage.usedTokens`
/// and provider-thread `contextUsage` are context snapshots and are never summed.
enum T3UsageReader {
    struct Totals {
        var usage: TokenUsage?
        var chats: Int
    }
    private static let threadTable = "orchestration_v2_projection_threads"
    private static let providerTable = "orchestration_v2_projection_provider_threads"
    private static let turnTable = "orchestration_v2_projection_provider_turns"

    static func overview(home: String) -> UsageOverview {
        do {
            let root = URL(fileURLWithPath: home)
            let nested = root.appendingPathComponent("userdata/statev2.sqlite")
            let path = LocalFiles.exists(nested.path) ? nested.path : root.appendingPathComponent("statev2.sqlite").path
            guard !home.isEmpty, LocalFiles.exists(path) else { throw DatabaseError.failure("No T3 Code V2 usage database found") }
            let db = try ReadOnlyDatabase(path: path)
            let totals = try read(db: db, threadIDs: nil).first?.value
            return UsageOverview(app: .t3, sessions: totals?.chats ?? 0, usage: totals?.usage,
                                 scope: "T3 hosting view · recorded main-chat turns, including archived chats · overlaps provider archives",
                                 recordedAt: "Read from disk now · active turns may not have reported consumption yet")
        } catch {
            return UsageOverview(app: .t3, sessions: 0, scope: "T3 usage unavailable: " + error.localizedDescription, recordedAt: "Unavailable")
        }
    }

    /// With IDs, return a cumulative sum for each loaded chat. Without IDs,
    /// return one archive aggregate, excluding separate subagent chats.
    static func read(db: ReadOnlyDatabase, threadIDs: [String]?) throws -> [String: Totals] {
        let required: [(String, Set<String>)] = [
            (threadTable, ["thread_id", "deleted_at", "payload_json"]),
            (providerTable, ["provider_thread_id", "thread_id", "owner_node_id"]),
            (turnTable, ["provider_turn_id", "provider_thread_id", "thread_id", "payload_json"])
        ]
        for (table, columns) in required {
            guard try db.columns(table).isSuperset(of: columns) else { throw DatabaseError.failure("T3 consumption counters are not available in this projection schema.") }
        }
        if threadIDs?.isEmpty == true { return [:] }
        let filter: String
        if let threadIDs { filter = "AND a.thread_id IN (\(threadIDs.map(sqlLiteral).joined(separator: ",")))" }
        else { filter = "AND CASE WHEN json_valid(a.payload_json) THEN json_extract(a.payload_json,'$.lineage.relationshipToParent') IS NOT 'subagent' ELSE 0 END" }
        func counter(_ field: String) -> String {
            "CASE WHEN json_type(counters,'$.\(field)')='integer' AND json_extract(counters,'$.\(field)')>=0 THEN json_extract(counters,'$.\(field)') END"
        }
        let input = counter("inputTokens"), output = counter("outputTokens")
        let sql = """
        WITH source AS (
            SELECT a.thread_id,t.provider_turn_id,
                   CASE WHEN json_valid(t.payload_json) THEN
                        CASE WHEN json_type(t.payload_json,'$.turnTokenUsage')='object' THEN json_extract(t.payload_json,'$.turnTokenUsage') END
                   END AS usage
            FROM \(threadTable) a
            LEFT JOIN \(providerTable) p ON p.thread_id=a.thread_id AND p.owner_node_id IS NULL
            LEFT JOIN \(turnTable) t ON t.provider_thread_id=p.provider_thread_id AND t.thread_id=a.thread_id
            WHERE a.deleted_at IS NULL
                  AND CASE WHEN json_valid(a.payload_json) THEN json_extract(a.payload_json,'$.deletedAt') IS NULL ELSE 0 END
                  \(filter)
        ), normalized AS (
            SELECT *, CASE WHEN json_extract(usage,'$.usageScope')='main_agent'
                           AND json_extract(usage,'$.usageStatus') IN ('complete','partial') THEN usage END AS counters
            FROM source
        )
        SELECT \(threadIDs == nil ? "'archive'" : "thread_id") AS key,
               COUNT(DISTINCT thread_id) AS chats,COUNT(provider_turn_id) AS turns,
               COUNT(DISTINCT CASE WHEN \(input) IS NOT NULL OR \(output) IS NOT NULL THEN thread_id END) AS covered_chats,
               SUM(CASE WHEN \(input) IS NOT NULL AND \(output) IS NOT NULL AND json_extract(counters,'$.usageStatus')='complete' THEN 1 ELSE 0 END) AS complete_turns,
               SUM(CASE WHEN json_extract(counters,'$.hasSubagents')=1 THEN 1 ELSE 0 END) AS worker_turns,
               SUM(\(input)) AS input,SUM(\(output)) AS output,
               SUM(\(counter("cachedInputTokens"))) AS cache_read,
               SUM(\(counter("cacheCreationTokens"))) AS cache_write,
               SUM(\(counter("reasoningTokens"))) AS reasoning
        FROM normalized \(threadIDs == nil ? "" : "GROUP BY thread_id")
        """
        var result: [String: Totals] = [:]
        for row in try db.rows(sql) {
            let chats = Int(row["chats"] ?? "0") ?? 0, covered = Int(row["covered_chats"] ?? "0") ?? 0
            let turns = Int(row["turns"] ?? "0") ?? 0, complete = Int(row["complete_turns"] ?? "0") ?? 0
            let workers = Int(row["worker_turns"] ?? "0") ?? 0
            let input = TokenUsage.number(row["input"]), output = TokenUsage.number(row["output"])
            let read = TokenUsage.number(row["cache_read"]), write = TokenUsage.number(row["cache_write"]), reasoning = TokenUsage.number(row["reasoning"])
            let total = TokenUsage.sum([input, output])
            let partial = covered < chats || complete < turns || workers > 0 || total == nil
            let usage: TokenUsage?
            if [input, output, read, write, reasoning].contains(where: { $0 != nil }) {
                usage = TokenUsage(input: input, output: output, cacheRead: read, cacheWrite: write, reasoning: reasoning,
                                   total: total,
                                   coverage: "T3-recorded main-agent consumption · \(complete.formatted()) of \(turns.formatted()) turns complete · \(covered.formatted()) of \(chats.formatted()) chats have counters",
                                   note: "T3 normalizes input to include cache reads and writes; output includes reasoning. These are recorded turn sums, not context occupancy. Active turns, imported histories and worker usage may be missing. Separate subagent-chat totals are excluded from the overall hosting view. This view overlaps native provider archive totals; do not add them together.", totalIsPartial: partial)
            } else { usage = nil }
            result[row["key"] ?? "archive"] = Totals(usage: usage, chats: chats)
        }
        return result
    }
}
