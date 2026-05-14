//
//  StatsView.swift
//  hanzipracticeapp
//
//  Top-level stats / progress tab. Mirrors the layout in the inspiration
//  screenshot: mastered counter, due-soon banner, deck distribution donut,
//  practice-activity heatmap, and weekly stroke accuracy.
//

import SwiftUI
import SwiftData
import Charts

struct StatsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(CharacterStore.self) private var store

    @Query private var cards: [SRSCard]
    @Query(sort: \PracticeRecord.date, order: .reverse) private var records: [PracticeRecord]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    summaryCards
                    deckDistribution
                    hskProgress
                    practiceActivity
                    strokeAccuracyChart
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Learning Progress")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Summary cards

    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard(label: "Mastered",
                        big: "\(mastered.count)",
                        unit: "chars",
                        accent: Theme.accent,
                        background: Theme.accentSoft)
            summaryCard(label: nextReviewLabel,
                        big: nextReviewValue,
                        unit: nextReviewUnit,
                        accent: Theme.warning,
                        background: Color(hex: 0xFAE7D9))
        }
    }

    private func summaryCard(label: String, big: String, unit: String,
                             accent: Color, background: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(1.2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(big)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(accent)
                Text(unit)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(background)
        )
    }

    private var mastered: [SRSCard] { cards.filter { $0.state == .mastered } }

    private var nextReviewLabel: String { "Next review" }
    private var nextReviewValue: String {
        let upcoming = cards
            .map(\.dueDate)
            .filter { $0 > .now }
            .sorted()
            .first
        guard let next = upcoming else { return "—" }
        let interval = next.timeIntervalSince(.now)
        if interval < 3600 {
            return "\(max(1, Int(interval / 60))):\(String(format: "%02d", Int(interval) % 60))"
        }
        if interval < 86_400 {
            let h = Int(interval / 3600)
            let m = (Int(interval) % 3600) / 60
            return "\(String(format: "%02d", h)):\(String(format: "%02d", m))"
        }
        return "\(Int(interval / 86_400))d"
    }
    private var nextReviewUnit: String {
        guard let next = cards.map(\.dueDate).filter({ $0 > .now }).sorted().first else { return "" }
        let interval = next.timeIntervalSince(.now)
        if interval < 3600 { return "MIN" }
        if interval < 86_400 { return "HRS" }
        return "DAYS"
    }

    // MARK: - Deck distribution

    private var deckDistribution: some View {
        let counts = SRSCard.DeckState.allCases.map { state in
            (state: state, count: cards.filter { $0.state == state }.count)
        }
        let total = counts.map(\.count).reduce(0, +)

        return VStack(alignment: .leading, spacing: 12) {
            Text("DECK DISTRIBUTION")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary).tracking(1.2)
            HStack(spacing: 16) {
                ZStack {
                    Chart {
                        ForEach(counts, id: \.state.rawValue) { row in
                            SectorMark(
                                angle: .value("Count", max(row.count, 0)),
                                innerRadius: .ratio(0.65),
                                angularInset: 2
                            )
                            .foregroundStyle(color(for: row.state))
                        }
                        if total == 0 {
                            SectorMark(angle: .value("Empty", 1),
                                       innerRadius: .ratio(0.65))
                                .foregroundStyle(Theme.accentSoft)
                        }
                    }
                    .frame(width: 130, height: 130)
                    VStack {
                        Text("\(total)")
                            .font(.system(size: 22, weight: .bold))
                        Text("TOTAL")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .tracking(1)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(counts, id: \.state.rawValue) { row in
                        HStack {
                            Circle().fill(color(for: row.state))
                                .frame(width: 10, height: 10)
                            Text(row.state.displayName)
                                .font(.system(size: 14))
                            Spacer()
                            Text("\(row.count)")
                                .font(.system(size: 14, weight: .bold))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.card)
        )
    }

    private func color(for state: SRSCard.DeckState) -> Color {
        switch state {
        case .mastered: Theme.accent
        case .review:   Color(hex: 0x6789C2)
        case .learning: Color(hex: 0xC9A13C)
        case .new:      Theme.accentSoft.opacity(0.7)
        }
    }

    // MARK: - HSK progress

    private var hskProgress: some View {
        // O(1) state lookup per character.
        let cardByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.characterID, $0) })
        return VStack(alignment: .leading, spacing: 10) {
            Text("HSK PROGRESS")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary).tracking(1.2)
            ForEach(1...6, id: \.self) { level in
                hskProgressRow(level: level, cardByID: cardByID)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.card)
        )
    }

    private func hskProgressRow(level: Int, cardByID: [String: SRSCard]) -> some View {
        let chars = HSKLevels.shared.byLevel[level] ?? []
        let total = chars.count
        var started = 0
        var mastered = 0
        for c in chars {
            // SRSCard.characterID is always the canonical (simplified) id,
            // which matches the keys in HSKLevels.byLevel — see UserDataController.
            if let card = cardByID[c] {
                if card.state == .mastered { mastered += 1 }
                if card.state != .new { started += 1 }
            }
        }
        let startedFrac = total > 0 ? Double(started) / Double(total) : 0
        let masteredFrac = total > 0 ? Double(mastered) / Double(total) : 0

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("HSK \(level)")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text("\(started) / \(total)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                if mastered > 0 {
                    Text("·")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("\(mastered) mastered")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.surface)
                    Capsule()
                        .fill(Theme.accent.opacity(0.45))
                        .frame(width: max(0, w * startedFrac))
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(0, w * masteredFrac))
                }
            }
            .frame(height: 10)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Activity heatmap

    private var practiceActivity: some View {
        let streak = currentStreak
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PRACTICE ACTIVITY")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary).tracking(1.2)
                Spacer()
                HStack(spacing: 4) {
                    Text("\(streak) Day Streak")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "flame.fill")
                        .foregroundStyle(Theme.warning)
                }
            }
            ActivityHeatmap(intensityByDay: intensityByDay, weeks: 16)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.card)
        )
    }

    private var intensityByDay: [Date: Double] {
        let cal = Calendar.current
        var buckets: [Date: Double] = [:]
        for r in records {
            let day = cal.startOfDay(for: r.date)
            buckets[day, default: 0] += 1
        }
        let maxV = max(1.0, buckets.values.max() ?? 1)
        return buckets.mapValues { min(1.0, $0 / maxV) }
    }

    private var currentStreak: Int {
        let cal = Calendar.current
        let days = Set(records.map { cal.startOfDay(for: $0.date) })
        var streak = 0
        var cursor = cal.startOfDay(for: .now)
        while days.contains(cursor) {
            streak += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return streak
    }

    // MARK: - Stroke accuracy chart

    private var strokeAccuracyChart: some View {
        let weeklyAccuracies = weeklyAccuracySeries
        return VStack(alignment: .leading, spacing: 10) {
            Text("STROKE ACCURACY")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary).tracking(1.2)
            Chart {
                ForEach(weeklyAccuracies, id: \.weekday) { row in
                    BarMark(
                        x: .value("Day", row.weekday),
                        y: .value("Mistakes", row.mistakes)
                    )
                    .foregroundStyle(Theme.warning.opacity(0.75))
                    .position(by: .value("Series", "Mistakes"))
                    BarMark(
                        x: .value("Day", row.weekday),
                        y: .value("Correct", row.correct)
                    )
                    .foregroundStyle(Theme.accent)
                    .position(by: .value("Series", "Correct"))
                }
            }
            .frame(height: 160)
            HStack(spacing: 14) {
                legend(color: Theme.accent, label: "Correct")
                legend(color: Theme.warning, label: "Mistakes")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.card)
        )
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.system(size: 12, weight: .semibold))
        }
    }

    /// Last 7 days of correct vs mistaken strokes, keyed by weekday.
    private var weeklyAccuracySeries: [(weekday: String, correct: Double, mistakes: Double)] {
        let cal = Calendar.current
        let now = cal.startOfDay(for: .now)
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var byDay: [Int: (Double, Double)] = [:]
        for day in 0..<7 {
            let target = cal.date(byAdding: .day, value: -day, to: now) ?? now
            let key = cal.component(.weekday, from: target)
            byDay[key] = (0, 0)
        }
        for r in records {
            guard r.date >= (cal.date(byAdding: .day, value: -7, to: now) ?? now) else { continue }
            let key = cal.component(.weekday, from: r.date)
            let pair = byDay[key] ?? (0, 0)
            byDay[key] = (pair.0 + r.accuracy, pair.1 + max(0, 1 - r.accuracy))
        }
        let ordered = (1...7).map { i -> (String, Double, Double) in
            let pair = byDay[i] ?? (0, 0)
            return (weekdays[i - 1], pair.0, pair.1)
        }
        return ordered.map { (weekday: $0.0, correct: $0.1, mistakes: $0.2) }
    }
}
