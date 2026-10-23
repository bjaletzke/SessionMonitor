import XCTest
import SQLite3
@testable import SessionMonitor

final class UsageAndReviewTests: XCTestCase {
    let date = "2026-10-08T12:00:00Z"
    func testCodexChartSegmentsSubtractSubsetsWithoutDoubleCounting() {
        let usage = TokenUsage.codex([
            "input_tokens": 100, "cached_input_tokens": 80,
            "output_tokens": 20, "reasoning_output_tokens": 5, "total_tokens": 120
        ])
        let segments = usage.chartSegments(for: .codex)
        XCTAssertEqual(segments, [
            TokenSegment(kind: .input, value: 20), TokenSegment(kind: .cacheRead, value: 80),
            TokenSegment(kind: .output, value: 15), TokenSegment(kind: .reasoning, value: 5)
        ])
        XCTAssertEqual(segments.reduce(0) { $0 + $1.value }, usage.total)
    }

    func testClaudeChartSegmentsKeepSeparateCacheCounters() {
        let usage = TokenUsage(input: 10, output: 8, cacheRead: 100, cacheWrite: 20, total: 138)
        let segments = usage.chartSegments(for: .claude)
        XCTAssertEqual(segments, [
            TokenSegment(kind: .input, value: 10), TokenSegment(kind: .output, value: 8),
            TokenSegment(kind: .cacheRead, value: 100), TokenSegment(kind: .cacheWrite, value: 20)
        ])
        XCTAssertEqual(segments.reduce(0) { $0 + $1.value }, usage.total)
    }

    func testT3NormalizedSegmentsSubtractBothCacheKindsAndReasoning() {
        let usage = TokenUsage(input: 130, output: 8, cacheRead: 100, cacheWrite: 20, reasoning: 3, total: 138)
        let segments = usage.chartSegments(for: .t3)
        XCTAssertEqual(segments, [TokenSegment(kind: .input, value: 10), TokenSegment(kind: .cacheRead, value: 100),
                                  TokenSegment(kind: .cacheWrite, value: 20), TokenSegment(kind: .output, value: 5), TokenSegment(kind: .reasoning, value: 3)])
        XCTAssertEqual(segments.reduce(0) { $0 + $1.value }, 138)
    }

    func testChartSegmentsClampSubtractionsAndSkipMissingOrZeroCounters() {
        let codex = TokenUsage(input: 5, output: 2, cacheRead: 10, cacheWrite: 50, reasoning: 4)
        XCTAssertEqual(codex.chartSegments(for: .codex), [
            TokenSegment(kind: .cacheRead, value: 10), TokenSegment(kind: .reasoning, value: 4)
        ])
        XCTAssertEqual(TokenUsage(input: 0, cacheWrite: 0).chartSegments(for: .claude), [])
        XCTAssertEqual(TokenUsage(cacheRead: 8).chartSegments(for: .codex), [TokenSegment(kind: .cacheRead, value: 8)])
        XCTAssertEqual(TokenUsage(input: -1, output: 0).chartSegments(for: .hermes), [])
    }

    func testHermesChartSegmentsIncludeSeparateReasoningAndCache() {
        let usage = TokenUsage(input: 10, output: 5, cacheRead: 20, cacheWrite: 3, reasoning: 2)
        XCTAssertEqual(usage.chartSegments(for: .hermes), [
            TokenSegment(kind: .input, value: 10), TokenSegment(kind: .output, value: 5),
            TokenSegment(kind: .cacheRead, value: 20), TokenSegment(kind: .cacheWrite, value: 3),
            TokenSegment(kind: .reasoning, value: 2)
        ])
    }

    func testChartSegmentsUseUnclassifiedTotalOnlyWhenBreakdownIsUnavailable() {
        XCTAssertEqual(TokenUsage(total: 120).chartSegments(for: .codex), [TokenSegment(kind: .recordedTotal, value: 120)])
        XCTAssertEqual(TokenUsage(input: 100, total: 120).chartSegments(for: .codex), [TokenSegment(kind: .input, value: 100)])
        XCTAssertTrue(TokenUsage(total: 0).chartSegments(for: .codex).isEmpty)
    }

    func testRecentUsageUsesCalendarDaysDisplayCountAndExcludesSubagents() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // This week spans the spring DST transition: calendar days are not all 24 hours.
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)))
        func session(_ id: String, _ app: AgentApp, _ day: Date, _ usage: TokenUsage?, subagent: Bool = false) -> Session {
            Session(id: id, sessionID: id, app: app, title: "Synthetic session", updatedAt: day, usage: usage, isSubagent: subagent)
        }
        let sessions = [
            session("first", .codex, start, TokenUsage(total: 100)),
            session("second", .codex, start.addingTimeInterval(60), TokenUsage(total: 20)),
            session("claude", .claude, now, TokenUsage(input: 5, output: 3, total: 30)),
            session("hermes", .hermes, now, TokenUsage(input: 7, output: 2, cacheRead: 50)),
            session("child", .codex, now, TokenUsage(total: 9_999), subagent: true),
            session("old", .codex, start.addingTimeInterval(-1), TokenUsage(total: 9_999)),
            session("future", .codex, now.addingTimeInterval(60), TokenUsage(total: 9_999)),
            session("missing", .codex, now, nil)
        ]
        let buckets = DailyTokenUsage.buckets(sessions: sessions, now: now, calendar: calendar)
        XCTAssertEqual(Set(buckets.map(\.day)).count, 7)
        XCTAssertEqual(buckets.count, 7 * AgentApp.allCases.count)
        XCTAssertEqual(buckets.first { $0.day == start && $0.app == .codex }?.value, 120)
        XCTAssertEqual(buckets.filter { $0.app == .claude }.reduce(0) { $0 + $1.value }, 30)
        XCTAssertEqual(buckets.filter { $0.app == .hermes }.reduce(0) { $0 + $1.value }, 9)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.value }, 159)
    }

    func testCodexCumulativeCountersDoNotDoubleCountCacheAndReasoning() {
        let result = TranscriptReader.reduce(objects: [
            event("token_count", ["info": ["total_token_usage": ["input_tokens": 100, "cached_input_tokens": 80, "output_tokens": 20, "reasoning_output_tokens": 5, "total_tokens": 120]]]),
            event("token_count", ["info": ["total_token_usage": ["input_tokens": 200, "cached_input_tokens": 180, "output_tokens": 40, "total_tokens": 240]]])
        ], app: .codex)
        XCTAssertEqual(result.usage?.total, 240)
        XCTAssertEqual(result.usage?.input, 200)
        XCTAssertEqual(result.usage?.cacheRead, 180)
    }
    func testClaudeStreamingDuplicatesCountOnceWithLatestOutput() {
        func assistant(_ output: Int) -> [String: Any] {
            ["type": "assistant", "message": ["id": "msg1", "usage": ["input_tokens": 10, "output_tokens": output, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 20]]]
        }
        let result = TranscriptReader.reduce(objects: [assistant(2), assistant(8)], app: .claude)
        XCTAssertEqual(result.usage?.input, 10)
        XCTAssertEqual(result.usage?.output, 8)
        XCTAssertEqual(result.usage?.total, 138)
        XCTAssertTrue(result.usage?.coverage.contains("partial") == true)
    }
    func testCodexStructuredQuestionClearsAfterMatchingResult() {
        let request: [String: Any] = ["type": "response_item", "timestamp": date, "payload": ["type": "function_call", "name": "request_user_input", "call_id": "q1", "arguments": "{\"questions\":[{\"question\":\"Which workspace?\"}]}" ]]
        var result = TranscriptReader.reduce(objects: [event("task_started"), request], app: .codex)
        XCTAssertEqual(result.state, .waitingForAnswer)
        XCTAssertEqual(result.question, "Which workspace?")
        // A question can remain unanswered longer than the activity-estimate timeout.
        XCTAssertEqual(TranscriptReader.age(result, now: Date(timeIntervalSince1970: 2_000_000_000)).state, .waitingForAnswer)
        let output: [String: Any] = ["type": "response_item", "timestamp": date, "payload": ["type": "function_call_output", "call_id": "q1"]]
        result = TranscriptReader.reduce(objects: [request, output], app: .codex)
        XCTAssertEqual(result.state, .running)
        XCTAssertEqual(result.question, "")
    }
    func testClaudeQuestionResolutionAndOrdinaryQuestionText() {
        let request: [String: Any] = ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "q1", "name": "AskUserQuestion", "input": ["questions": [["question": "Proceed?"]]]]]]]
        let output: [String: Any] = ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "q1"]]]]
        XCTAssertEqual(TranscriptReader.reduce(objects: [request], app: .claude).state, .waitingForAnswer)
        XCTAssertEqual(TranscriptReader.reduce(objects: [request, output], app: .claude).state, .unknown)
        let prose: [String: Any] = ["type": "assistant", "timestamp": date, "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "Would you like more?"]]]]
        XCTAssertEqual(TranscriptReader.reduce(objects: [prose], app: .claude).state, .responseReady)
    }
    func testReviewAcknowledgementAppliesToOneCompletionOnly() {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        var session = Session(id: "one", sessionID: "one", app: .codex, title: "Test", state: .responseReady, updatedAt: time, completedAt: time)
        let reviews = ReviewAcknowledgements(dates: ["one": time.timeIntervalSince1970])
        XCTAssertEqual(reviews.apply(to: session).state, .idle)
        session.completedAt = time.addingTimeInterval(1)
        XCTAssertEqual(reviews.apply(to: session).state, .responseReady)
        session.state = .running
        XCTAssertEqual(reviews.apply(to: session).state, .running)
    }
    func testSessionLinksUseDesktopIdentityAndRejectInjectedIDs() {
        var session = Session(id: "one", sessionID: "01a11b61-4db3-7960-9df3-d3cf8594e2a0", app: .codex, title: "Test", updatedAt: Date())
        XCTAssertEqual(DesktopActions.sessionURL(session)?.absoluteString, "codex://threads/01a11b61-4db3-7960-9df3-d3cf8594e2a0")
        session.sessionID = "id?command=bad"
        XCTAssertNil(DesktopActions.sessionURL(session))
        session.app = .claude; session.desktopSessionID = "local_abc-123"
        XCTAssertEqual(DesktopActions.sessionURL(session)?.absoluteString, "claude://code/continue?session=local_abc-123")
        session.desktopSessionID = "local_abc&session=last"
        XCTAssertNil(DesktopActions.sessionURL(session))
        session.app = .hermes
        XCTAssertNil(DesktopActions.sessionURL(session)) // A deep link could target the wrong active profile.
    }
    func testHermesResumeCommandPreservesProfileAndQuotesWorkspace() {
        let session = Session(id: "one", sessionID: "id'1", app: .hermes, title: "Test", workspace: "/tmp/it's a folder", updatedAt: Date(), sourcePath: "/tmp/hermes/profiles/research/state.db")
        let command = DesktopActions.resumeCommand(session) ?? ""
        XCTAssertTrue(command.contains("HERMES_HOME='/tmp/hermes/profiles/research'"))
        XCTAssertTrue(command.contains("cd '/tmp/it'\\''s a folder'"))
        XCTAssertTrue(command.hasSuffix("hermes --resume 'id'\\''1'"))
    }
    func testQuotaRetainsRecordedTimeAndRejectsInvalidPercent() {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        var object: [String: Any] = ["primary": ["used_percent": 8.0, "window_minutes": 10080, "resets_at": 1800001000]]
        XCTAssertEqual(QuotaSnapshot.parse(object, recordedAt: time)?.recordedAt, time)
        XCTAssertEqual(QuotaSnapshot.parse(object, recordedAt: time)?.windows.first?.usedPercent, 8)
        object["primary"] = ["used_percent": 108.0, "window_minutes": 10080, "resets_at": 1800001000]
        XCTAssertNil(QuotaSnapshot.parse(object, recordedAt: time))
    }
    func testClaudeOverallCacheRetainsDateAndDoesNotInventActualCost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let object: [String: Any] = ["lastComputedDate": "2026-08-19", "totalSessions": 3, "modelUsage": ["model": ["inputTokens": 10, "outputTokens": 5, "cacheReadInputTokens": 20, "costUSD": 0]]]
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("stats-cache.json"))
        let result = UsageReader.claude(home: root.path)
        XCTAssertEqual(result.sessions, 3)
        XCTAssertEqual(result.usage?.total, 35)
        XCTAssertTrue(result.recordedAt.contains("2026-08-19"))
        XCTAssertNil(result.usage?.actualCostUSD)
    }
    func testCompletedHarnessResponsePersistsAsHistoryWithoutHeartbeat() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let object: [String: Any] = ["session_id": "run", "state": "response_ready", "observed_at": now.timeIntervalSince1970, "completed_at": now.timeIntervalSince1970]
        let result = HarnessAdapter.parse(object, path: "fixture", now: now.addingTimeInterval(3600))
        XCTAssertEqual(result?.state, .responseReady)
        XCTAssertEqual(result?.confidence, .historical)
        XCTAssertEqual(result?.completedAt, now)
    }
    private func event(_ type: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "event_msg", "timestamp": date, "payload": extra.merging(["type": type]) { _, new in new }]
    }
}
