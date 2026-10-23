import SwiftUI
import Charts

extension TokenSegment.Kind {
    var color: Color {
        switch self {
        case .input: .blue
        case .output: .green
        case .cacheRead: .teal
        case .cacheWrite: .orange
        case .reasoning: .purple
        case .recordedTotal: .gray
        }
    }
}

private extension AgentApp {
    var usageColor: Color {
        switch self {
        case .codex: .blue
        case .claude: .orange
        case .hermes: .purple
        case .t3: .indigo
        case .harness: .teal
        }
    }
}

struct TokenBreakdownBar: View {
    let usage: TokenUsage
    let app: AgentApp
    private var segments: [TokenSegment] { usage.chartSegments(for: app) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !segments.isEmpty {
                Chart(segments) { segment in
                    BarMark(x: .value("Tokens", segment.value), y: .value("Usage", "Tokens"))
                        .foregroundStyle(by: .value("Kind", segment.kind.rawValue))
                        .accessibilityLabel(segment.kind.label(for: app))
                        .accessibilityValue("\(segment.value.formatted()) tokens")
                }
                .chartForegroundStyleScale(domain: segments.map { $0.kind.rawValue }, range: segments.map { $0.kind.color })
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 22)
                .help(segments.map { "\($0.kind.label(for: app)): \($0.value.formatted()) tokens" }.joined(separator: "\n"))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(segments) { segment in
                        HStack(spacing: 5) {
                            Circle().fill(segment.kind.color).frame(width: 7, height: 7)
                            Text(segment.kind.label(for: app))
                            Text(segment.value, format: .number.notation(.compactName)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .help("\(segment.kind.label(for: app)): \(segment.value.formatted()) tokens")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(segment.kind.label(for: app)): \(segment.value.formatted()) tokens")
                    }
                }
                if segments.first?.kind == .recordedTotal {
                    Text("Breakdown not recorded").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No positive token counters recorded").font(.caption).foregroundStyle(.secondary)
            }
            if usage.totalIsPartial == true {
                Text("Partial · recorded counters only").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct UsageByAppChart: View {
    let overviews: [UsageOverview]
    private var kinds: [TokenSegment.Kind] {
        TokenSegment.Kind.allCases.filter { kind in
            overviews.contains { $0.usage?.chartSegments(for: $0.app).contains { $0.kind == kind } == true }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By app").font(.headline)
            if kinds.isEmpty {
                Text("No overall token counters recorded.").font(.callout).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(overviews) { overview in
                        let segments = overview.usage?.chartSegments(for: overview.app) ?? []
                        ForEach(segments) { segment in
                            BarMark(x: .value("Tokens", segment.value), y: .value("App", overview.app.rawValue))
                                .foregroundStyle(by: .value("Kind", segment.kind.rawValue))
                                .accessibilityLabel("\(overview.app.rawValue), \(segment.kind.label(for: overview.app))")
                                .accessibilityValue("\(segment.value.formatted()) tokens")
                                .annotation(position: .trailing, alignment: .leading) {
                                    if segment.id == segments.last?.id {
                                        let count = segments.reduce(0.0) { $0 + Double($1.value) }
                                        Text(count, format: .number.notation(.compactName)).font(.caption).monospacedDigit()
                                            .help(segments.map { "\($0.kind.label(for: overview.app)): \($0.value.formatted()) tokens" }.joined(separator: "\n"))
                                    }
                                }
                        }
                    }
                }
                .chartForegroundStyleScale(domain: kinds.map(\.rawValue), range: kinds.map(\.color))
                .chartYScale(domain: overviews.map { $0.app.rawValue })
                .chartXScale(range: .plotDimension(endPadding: 60), type: .symmetricLog)
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let count = value.as(Double.self) { Text(count, format: .number.notation(.compactName)) }
                        }
                    }
                }
                .frame(height: CGFloat(max(overviews.count, 1) * 42 + 70))
                Text("Logarithmic token axis keeps smaller apps visible; segment widths are not proportional. Recorded total means no breakdown is available. Codex input excludes cache reads; output excludes reasoning. Hermes bars include separately recorded cache and reasoning counters. Coverage differs by app; see the records below.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if overviews.contains(where: { $0.app == .t3 }) {
                    Text("T3 is a hosting view and overlaps the provider archive totals. Do not add these bars. T3 bars exclude cache reads and writes from input, and reasoning from output.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct RecentUsageChart: View {
    let sessions: [Session]

    var body: some View {
        let buckets = DailyTokenUsage.buckets(sessions: sessions)
        let apps = AgentApp.allCases.filter { app in buckets.contains { $0.app == app && $0.value > 0 } }
        let start = buckets.first?.day ?? Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? Date()
        VStack(alignment: .leading, spacing: 10) {
            Text("Last 7 days (loaded sessions)").font(.headline)
            Chart(buckets.filter { apps.contains($0.app) }) { bucket in
                BarMark(x: .value("Day", bucket.day, unit: .day), y: .value("Tokens", bucket.value))
                    .foregroundStyle(by: .value("App", bucket.app.rawValue))
                    .accessibilityLabel("\(bucket.day.formatted(date: .abbreviated, time: .omitted)), \(bucket.app.rawValue)")
                    .accessibilityValue("\(bucket.value.formatted()) tokens")
            }
            .chartForegroundStyleScale(domain: apps.map(\.rawValue), range: apps.map(\.usageColor))
            .chartXScale(domain: start...end)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) {
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let count = value.as(Double.self) { Text(count, format: .number.notation(.compactName)) }
                    }
                }
            }
            .frame(height: 190)
            if apps.isEmpty { Text("No recorded token usage in the last seven days of loaded sessions.").font(.caption).foregroundStyle(.secondary) }
            Text("Approximate: each session's cumulative total is counted on its last-activity day; only sessions in the current load window are included.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if sessions.contains(where: { $0.app == .t3 && $0.usage != nil }) {
                Text("T3 uses recorded main-agent turns; active turns and imported history may be missing. Exact matched native records are omitted when T3 usage is available. Unmatched sources may overlap.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
