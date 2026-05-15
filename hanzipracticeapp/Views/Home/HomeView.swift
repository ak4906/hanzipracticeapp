//
//  HomeView.swift
//  hanzipracticeapp
//
//  Landing screen — greeting, today's review, weekly pulse, suggested
//  characters, and a "character of the day" highlight.
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(CharacterStore.self) private var store
    @Environment(\.modelContext) private var modelContext

    @Query private var cards: [SRSCard]
    @Query(sort: \PracticeRecord.date, order: .reverse) private var records: [PracticeRecord]
    @Query private var listsRaw: [VocabularyList]
    @Query private var settingsList: [UserSettings]

    private var lists: [VocabularyList] { listsRaw.sortedForDisplay() }

    @Binding var selectedTab: RootTab
    @Binding var dictionaryJumpToLists: Bool

    @State private var session: PracticeSession? = nil
    @State private var quizSession: QuizSession? = nil
    @Query private var quizCards: [SRSQuizCard]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    greetingHeader
                    todayCard
                    metricsRow
                    characterOfDay
                    quickLists
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Hanzi")
            .navigationBarTitleDisplayMode(.large)
            .fullScreenCover(item: $session) { s in
                WritingSessionView(session: s) { session = nil }
            }
            .fullScreenCover(item: $quizSession) { q in
                QuizView(session: q) { quizSession = nil }
            }
            .onAppear {
                _ = UserDataController(context: modelContext).settings()
            }
        }
    }

    // MARK: - Sections

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("Ready to write a few?")
                .font(.system(size: 22, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Late-night practice"
        }
    }

    private var todayCard: some View {
        let due = cards.filter {
            $0.dueDate <= .now && characterMatchesPracticeCeiling($0.characterID)
        }.count
        let learning = cards.filter { $0.state == .learning }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(Date.now.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 22) {
                stat(label: "Due", value: "\(due)")
                stat(label: "Learning", value: "\(learning)")
                stat(label: "Streak", value: "\(currentStreak)d")
            }
            // Primary action — full-width writing CTA. Below it, two
            // smaller chips kick off reading / translation review on the
            // same due-card pool (mode-specific SRS state).
            Button { startDueSession() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "applepencil.and.scribble")
                    Text("Start writing")
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color.white))
            }
            HStack(spacing: 10) {
                Button { startQuizSession(mode: .reading) } label: {
                    todayPill(systemImage: QuizMode.reading.systemImage,
                              title: "Reading")
                }
                Button { startQuizSession(mode: .translation) } label: {
                    todayPill(systemImage: QuizMode.translation.systemImage,
                              title: "Translation")
                }
                Button { selectedTab = .dictionary } label: {
                    todayPill(systemImage: "books.vertical",
                              title: "Browse")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.accent)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.08), .clear],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        )
    }

    private func todayPill(systemImage: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1.2))
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .tracking(0.6)
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 12) {
            metricTile(icon: "checkmark.seal.fill",
                       value: "\(cards.filter { $0.state == .mastered }.count)",
                       label: "Mastered",
                       color: Theme.accent)
            metricTile(icon: "scope",
                       value: "\(Int(averageAccuracy * 100))%",
                       label: "Last-week accuracy",
                       color: Color(hex: 0x6789C2))
            metricTile(icon: "books.vertical.fill",
                       value: "\(lists.count)",
                       label: "Lists",
                       color: Color(hex: 0xC9A13C))
        }
    }

    private func metricTile(icon: String, value: String, label: String,
                            color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Circle().fill(color))
            Text(value).font(.system(size: 20, weight: .bold))
            Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card)
        )
    }

    private var averageAccuracy: Double {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        let recent = records.filter { $0.date >= cutoff }
        guard !recent.isEmpty else { return 0 }
        return recent.map(\.accuracy).reduce(0, +) / Double(recent.count)
    }

    private var characterOfDay: some View {
        let pick = pickOfTheDay
        return Group {
            if let c = pick {
                NavigationLink {
                    CharacterDetailView(character: c)
                } label: {
                    HStack(spacing: 14) {
                        Text(c.char)
                            .font(Theme.hanzi(64))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 96, height: 96)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Theme.accentSoft)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CHARACTER OF THE DAY")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                                .tracking(1.2)
                            Text(c.pinyin)
                                .font(.system(size: 18, weight: .semibold, design: .serif))
                                .foregroundStyle(Theme.accent)
                            Text(c.meaning)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(2)
                            Text(characterOfDayMeta(c))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.card)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var practiceHSKCeiling: Int {
        let raw = settingsList.first?.practiceHSKCeiling ?? 1
        return max(1, min(HSKLevels.maxLevel, raw))
    }

    private func characterMatchesPracticeCeiling(_ canonicalID: String) -> Bool {
        guard let c = store.character(for: canonicalID) else { return false }
        if c.hskLevel >= 1 { return c.hskLevel <= practiceHSKCeiling }
        return practiceHSKCeiling >= HSKLevels.maxLevel
    }

    private func characterOfDayMeta(_ c: HanziCharacter) -> String {
        let strokes = "\(c.strokeCount) strokes"
        if c.hskLevel > 0 {
            return "\(strokes) • \(HSKLevels.displayLabel(for: c.hskLevel))"
        }
        return "\(strokes) • Outside HSK lists"
    }

    /// Deterministic per-day pick — always from official HSK levels ≤ user's
    /// practice ceiling so beginners don't see obscure dictionary-only hanzi.
    private var pickOfTheDay: HanziCharacter? {
        let ids = store.officialHSKCanonicalIDs(upThrough: practiceHSKCeiling)
        guard !ids.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: .now) ?? 1
        return store.character(for: ids[day % ids.count])
    }

    private var quickLists: some View {
        Group {
            if !lists.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Your Lists")
                            .font(.system(size: 17, weight: .bold))
                        Spacer()
                        Button {
                            selectedTab = .dictionary
                            dictionaryJumpToLists = true
                        } label: {
                            Text("See all")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(lists.prefix(6)) { list in
                                // Always navigate to detail — jumping
                                // straight into practice on first tap was
                                // disorienting because the user hadn't
                                // seen what was in the list yet.
                                NavigationLink {
                                    ListDetailView(list: list)
                                } label: {
                                    listChip(list)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func listChip(_ list: VocabularyList) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: list.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(
                    Circle().fill(Color(hex: UInt32(list.colorHex)))
                )
            Text(list.name)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
            Text(list.entryCountSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 160, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card)
        )
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

    private func startDueSession() {
        let controller = UserDataController(context: modelContext)
        let settings = settingsList.first
        let limit = settings?.effectiveDailyReviewLimit ?? 10
        let newCap = settings?.dailyNewLimit ?? 0
        let fallbackSize = max(3, min(limit, 8))
        // Real due cards (already-graded cards whose dueDate has passed)
        // come first, then we top up with brand-new HSK cards within the
        // daily-new cap so beginners with empty decks get a session that
        // doesn't just lean on the random fallback below.
        let dueFiltered = controller.dueCards()
            .filter { characterMatchesPracticeCeiling($0.characterID) }
        let dueIds = Array(dueFiltered.prefix(limit)).map(\.characterID)
        // Per-day cap: subtract cards already introduced today from the
        // user's `dailyNewLimit` so launching multiple sessions on the
        // same day doesn't keep introducing fresh chars past the budget.
        let startOfToday = Calendar.current.startOfDay(for: .now)
        let introducedToday = cards.filter { $0.dateAdded >= startOfToday }.count
        let perDayRemaining = max(0, newCap - introducedToday)
        let remainingSlots = max(0, limit - dueIds.count)
        let newQuota = min(perDayRemaining, remainingSlots)
        let knownSet = Set(cards.map(\.characterID))
        let newIds: [String] = newQuota > 0
            ? Array(store.officialHSKCanonicalIDs(upThrough: practiceHSKCeiling)
                    .filter { !knownSet.contains($0) }
                    .shuffled()
                    .prefix(newQuota))
            : []
        let ids = dueIds + newIds
        let valid = store.characters(for: ids).map(\.id)
        if valid.isEmpty {
            let gentle = Array(store.officialHSKCanonicalIDs(upThrough: practiceHSKCeiling).shuffled().prefix(fallbackSize))
            let fallbackPool = gentle.isEmpty
                ? Array(store.allCharacterIDs.shuffled().prefix(fallbackSize))
                : gentle
            session = PracticeSession(characterIDs: fallbackPool, title: "Today's Review")
        } else {
            session = PracticeSession(characterIDs: valid, title: "Today's Review")
        }
    }

    /// Today's Review for a quiz mode. Pulls due quiz cards for the given
    /// mode; if there aren't enough, tops up from the user's vocab lists
    /// so the user can still get a meaningful session early on.
    private func startQuizSession(mode: QuizMode) {
        let controller = UserDataController(context: modelContext)
        let settings = settingsList.first
        let limit = settings?.effectiveDailyReviewLimit ?? 10
        let due = controller.dueQuizCards(mode: mode)
        var entries: [String] = Array(due.prefix(limit)).map(\.entryKey)
        if entries.count < limit {
            // Top up from the user's lists (entries they care about) that
            // don't yet have a quiz card for this mode.
            let seen = Set(entries)
            let listPool = lists.flatMap(\.effectiveEntries)
            let topUp = listPool
                .filter { !seen.contains($0) }
                .prefix(limit - entries.count)
            entries.append(contentsOf: topUp)
        }
        guard !entries.isEmpty else { return }
        quizSession = QuizSession(entries: entries,
                                  title: "Today's Review",
                                  mode: mode)
    }
}
