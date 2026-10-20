import Charts
import SwiftUI

/// Explainable insights computed from the trip's own facts (server summary). No generated advice.
enum TripInsights {
    struct Insight: Identifiable, Equatable { let id: String; let text: String }

    static func make(summary: TripSummary, trip: Trip, now: Date = .now) -> [Insight] {
        var insights: [Insight] = []
        let currency = summary.baseCurrency
        func money(_ minor: Int64) -> String { Money(minorUnits: minor, currency: currency).formatted() }
        guard summary.expenseCount > 0 else { return [] }

        if let top = summary.byCategory.first, summary.totalSpentMinor > 0 {
            let share = Int((Double(top.totalMinor) / Double(summary.totalSpentMinor) * 100).rounded())
            insights.append(.init(id: "top-category", text: String(localized: "\(top.category.title) is the biggest category: \(money(top.totalMinor)), \(share)% of all spending.")))
        }
        if !summary.byDay.isEmpty {
            let average = summary.totalSpentMinor / Int64(summary.byDay.count)
            insights.append(.init(id: "daily", text: String(localized: "Average of \(money(average)) per day with spending, over \(summary.byDay.count) day(s).")))
            if let peak = summary.byDay.max(by: { $0.totalMinor < $1.totalMinor }), summary.byDay.count > 1 {
                insights.append(.init(id: "peak", text: String(localized: "Highest day: \(peak.day.formatted(date: .abbreviated, time: .omitted)) at \(money(peak.totalMinor)).")))
            }
        }
        if let budget = summary.budgetMinor, budget > 0 {
            let remaining = budget - summary.totalSpentMinor
            if remaining < 0 {
                insights.append(.init(id: "budget", text: String(localized: "Over budget by \(money(-remaining)).")))
            } else if let end = trip.endDate, end > now {
                let days = max(1, Calendar.current.dateComponents([.day], from: now, to: end).day ?? 1)
                insights.append(.init(id: "budget", text: String(localized: "\(money(remaining)) left in the budget — about \(money(remaining / Int64(days))) per remaining day.")))
            } else {
                insights.append(.init(id: "budget", text: String(localized: "Finished \(money(remaining)) under budget.")))
            }
        }
        if let biggestPayer = summary.byParticipant.max(by: { $0.paidMinor < $1.paidMinor }), biggestPayer.paidMinor > 0 {
            insights.append(.init(id: "payer", text: String(localized: "\(trip.name(of: biggestPayer.participantId)) has paid the most: \(money(biggestPayer.paidMinor)).")))
        }
        return insights
    }
}

@MainActor
struct InsightsView: View {
    @Environment(TripStore.self) private var store
    let tripID: TripID

    var body: some View {
        if let cached = store.cachedTrip(tripID), let summary = cached.summary {
            let trip = cached.trip
            List {
                Section {
                    ForEach(TripInsights.make(summary: summary, trip: trip)) { insight in
                        Label(insight.text, systemImage: "lightbulb").font(.subheadline)
                    }
                } header: { Text("Highlights") } footer: {
                    Text("Based on \(summary.expenseCount) expenses in \(summary.baseCurrency.rawValue), as of the last sync.")
                }
                Section("By category") {
                    Chart(summary.byCategory, id: \.category) { row in
                        BarMark(x: .value("Amount", Double(row.totalMinor) / Double(summary.baseCurrency.minorUnitScale)),
                                y: .value("Category", row.category.title))
                            .foregroundStyle(Color.brand)
                            .accessibilityValue(Money(minorUnits: row.totalMinor, currency: summary.baseCurrency).formatted())
                    }
                    .frame(height: CGFloat(max(summary.byCategory.count, 1)) * 34 + 20)
                    ForEach(summary.byCategory, id: \.category) { row in
                        LabeledContent(row.category.title) { Text(Money(minorUnits: row.totalMinor, currency: summary.baseCurrency).formatted()).monospacedDigit() }
                    }
                }
                if summary.byDay.count > 1 {
                    Section("By day") {
                        Chart(summary.byDay, id: \.day) { row in
                            BarMark(x: .value("Day", row.day, unit: .day), y: .value("Amount", Double(row.totalMinor) / Double(summary.baseCurrency.minorUnitScale)))
                                .foregroundStyle(Color.brand)
                        }
                        .frame(height: 180)
                    }
                }
                Section("By person") {
                    ForEach(summary.byParticipant, id: \.participantId) { row in
                        LabeledContent(trip.name(of: row.participantId)) {
                            VStack(alignment: .trailing) {
                                Text("consumed \(Money(minorUnits: row.consumedMinor, currency: summary.baseCurrency).formatted())").monospacedDigit()
                                Text("paid \(Money(minorUnits: row.paidMinor, currency: summary.baseCurrency).formatted())").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .screenBackground()
            .navigationTitle("Insights")
        } else {
            ContentUnavailableView("No insights yet", systemImage: "chart.pie", description: Text("Insights appear after expenses sync."))
        }
    }
}
