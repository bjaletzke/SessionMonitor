import Foundation

enum HarnessAdapter {
    static func scan(directory: String, limit: Int, now: Date) throws -> [Session] {
        guard LocalFiles.exists(directory) else { return [] }
        let files = LocalFiles.children(directory).filter { $0.pathExtension == "json" }.sorted { LocalFiles.modification($0) > LocalFiles.modification($1) }
        return files.prefix(limit).compactMap { file in
            guard let object = LocalFiles.object(file) else { return nil }
            return parse(object, path: file.path, now: now)
        }
    }
    static func parse(_ object: [String: Any], path: String, now: Date) -> Session? {
        guard let id = object["session_id"] as? String, !id.isEmpty,
              let stateValue = object["state"] as? String, let state = SessionState(rawValue: stateValue),
              let observed = LocalFiles.date(object["observed_at"]) else { return nil }
        let namespace = object["namespace"] as? String ?? "default"
        var session = Session(id: "harness:\(namespace):\(id)", sessionID: id, app: .harness,
                              title: LocalFiles.boundedTitle(object["title"] as? String, fallback: id),
                              model: object["model"] as? String ?? "", provider: object["provider"] as? String ?? "",
                              workspace: object["cwd"] as? String ?? "", origin: namespace,
                              state: state, confidence: .reported,
                              evidence: "State reported by your harness at \(observed.formatted()).", updatedAt: observed, sourcePath: path,
                              completedAt: LocalFiles.date(object["completed_at"]), question: object["question"] as? String ?? "")
        if let usage = object["usage"] as? [String: Any] {
            session.usage = TokenUsage(input: TokenUsage.number(usage["input_tokens"]), output: TokenUsage.number(usage["output_tokens"]),
                                       cacheRead: TokenUsage.number(usage["cache_read_tokens"]), cacheWrite: TokenUsage.number(usage["cache_write_tokens"]),
                                       total: TokenUsage.number(usage["total_tokens"]), actualCostUSD: usage["actual_cost_usd"] as? Double,
                                       coverage: "Harness-reported counters", note: "Semantics are defined by your harness.")
        }
        if let message = object["last_message"] as? [String: Any] {
            session.lastMessage = MessageText.preview(message["text"] as? String, role: message["role"] as? String ?? "assistant",
                                                      at: LocalFiles.date(message["recorded_at"]), coverage: "Last message reported by your harness")
        } else if let text = object["last_message"] as? String {
            session.lastMessage = MessageText.preview(text, role: "assistant", at: nil, coverage: "Last message reported by your harness · timestamp unavailable")
        }
        let ttl = min(3600, max(10, (object["ttl_seconds"] as? NSNumber)?.doubleValue ?? 180))
        if now.timeIntervalSince(observed) < -60 || (![SessionState.ended, .error, .responseReady].contains(state) && now.timeIntervalSince(observed) > ttl) {
            session.state = .unknown; session.confidence = .unavailable
            session.evidence = "The harness report is stale or has a future timestamp. Send a heartbeat to verify current state."
        }
        if session.state == .responseReady, now.timeIntervalSince(observed) > ttl {
            session.confidence = .historical
            session.evidence = "The harness recorded a completed response. No recent heartbeat verifies whether the session is still open."
        }
        return session
    }
}
