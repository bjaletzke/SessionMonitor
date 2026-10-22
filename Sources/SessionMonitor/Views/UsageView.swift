import SwiftUI

struct TokenUsageView: View {
    let usage: TokenUsage
    let app: AgentApp
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage").font(.headline)
            TokenBreakdownBar(usage: usage, app: app)
            Text(usage.coverage).font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                if let total = usage.total { counter(usage.totalIsPartial == true ? "Recorded token subtotal" : "Total tokens", total) }
                else if let total = usage.displayCount { counter("Input + output", total) }
                else { GridRow { Text("Total tokens"); Text("Not recorded").foregroundStyle(.secondary) } }
                if let input = usage.input { counter("Input", input) }
                if let output = usage.output { counter("Output", output) }
                if let read = usage.cacheRead { counter("Cache read", read) }
                if let write = usage.cacheWrite { counter("Cache write", write) }
                if let reasoning = usage.reasoning { counter("Reasoning", reasoning) }
                if let cost = usage.actualCostUSD, cost.isFinite {
                    GridRow { Text("Recorded actual cost"); Text(cost, format: .currency(code: "USD")).monospacedDigit() }
                }
                if let cost = usage.estimatedCostUSD, cost.isFinite {
                    GridRow { Text("Estimated cost"); Text(cost, format: .currency(code: "USD")).monospacedDigit() }
                }
                if !usage.costStatus.isEmpty {
                    GridRow { Text("Cost status"); Text(usage.costStatus.capitalized) }
                }
            }.font(.callout)
            if usage.actualCostUSD == nil && usage.estimatedCostUSD == nil { Text("Cost not recorded").font(.caption).foregroundStyle(.secondary) }
            Text(usage.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func counter(_ label: String, _ value: Int64) -> some View {
        GridRow { Text(label); Text(value.formatted()).monospacedDigit().textSelection(.enabled) }
    }
}

struct UsageView: View {
    @Bindable var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    private var quotas: [QuotaSnapshot] {
        Dictionary(grouping: store.snapshot.sessions.compactMap(\.quota), by: \.limitID)
            .values.compactMap { $0.max { $0.recordedAt < $1.recordedAt } }.sorted { $0.limitID < $1.limitID }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Overall usage").font(.title2.weight(.semibold))
                    Text("Local records · provider totals have different coverage").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    UsageByAppChart(overviews: store.snapshot.usage)
                    RecentUsageChart(sessions: store.snapshot.sessions)
                    Text("Archive totals include records outside the table's date range and load limit. Refreshes from local files at most once a minute. They do not measure remaining account credit or current charges.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(store.snapshot.usage) { overview in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Label(overview.app.rawValue, systemImage: overview.app.symbol).font(.headline)
                                    Spacer()
                                    if overview.usage != nil { Text("\(overview.sessions.formatted()) records").font(.callout).foregroundStyle(.secondary) }
                                }
                                Text(overview.scope).font(.callout)
                                Text(overview.recordedAt).font(.callout.weight(.medium)).foregroundStyle(overview.app == .claude ? Color.orange : Color.secondary)
                                if let usage = overview.usage { TokenUsageView(usage: usage, app: overview.app) }
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !quotas.isEmpty {
                        Text("Codex allowance snapshots").font(.headline)
                        Text("Last recorded in local session logs. These are account/limit snapshots, not per-session allowances, and may have changed since recording.").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(quotas.enumerated()), id: \.offset) { _, quota in
                            GroupBox(quota.limitID) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Recorded \(quota.recordedAt.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
                                    ForEach(Array(quota.windows.enumerated()), id: \.offset) { _, window in
                                        if window.resetsAt > Date(), quota.recordedAt <= Date().addingTimeInterval(60) {
                                            HStack {
                                                Text(window.label)
                                                Spacer()
                                                Text("\(window.usedPercent.formatted(.number.precision(.fractionLength(0...1))))% used")
                                            }
                                            ProgressView(value: window.usedPercent, total: 100)
                                            Text("Resets \(window.resetsAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                        } else {
                                            Text("Recorded window has expired or has an invalid timestamp; current allowance is unknown.").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }.padding(8)
                            }
                        }
                    }
                    Text("Harness usage appears in session details when your harness reports counters. No account API calls or model requests are made.").font(.caption).foregroundStyle(.secondary)
                }.padding(22)
            }
        }.frame(width: 680, height: 690)
    }
}

struct SessionUsagePopover: View {
    let session: Session
    @Bindable var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Session usage").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            Text(session.displayModel).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let usage = session.usage { TokenUsageView(usage: usage, app: session.app) }
                    else { Text("No usage counters recorded for this session.").foregroundStyle(.secondary) }
                    if let turn = session.record?.lastTurnUsage {
                        DisclosureGroup("Last recorded turn") { TokenUsageView(usage: turn, app: session.app).padding(.top, 8) }
                    }
                    if let source = session.record?.costSource { Text("Cost source: " + source).font(.caption).foregroundStyle(.secondary) }
                    if [.codex, .claude].contains(session.app), !session.savedBookmark {
                        Button(store.hasExpandedDetails(session) ? "Reload deeper counters" : "Load deeper counters") { Task { await store.loadDetails(session) } }
                            .disabled(store.loadingDetailsID != nil)
                        Text("Reads up to 8 MiB on demand; larger files remain partial. Account allowances are separate from session usage.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 450)
            Divider()
            Button("Overall usage & account snapshots…") { dismiss(); store.showingUsage = true }
            Text("Session counters are recorded totals, not remaining account credit.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 380).textSelection(.enabled)
    }
}
