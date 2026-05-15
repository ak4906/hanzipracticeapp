//
//  UserDataController.swift
//  hanzipracticeapp
//
//  Thin convenience layer on top of SwiftData for the kinds of writes the UI
//  performs repeatedly: noting a lookup, scheduling a new card, recording a
//  practice, fetching due cards.
//

import Foundation
import SwiftData

@MainActor
struct UserDataController {
    let context: ModelContext

    /// All user-owned SwiftData rows are keyed by the *canonical* (Simplified)
    /// form so progress and lists survive a writing-system toggle.
    private func canonical(_ id: String) -> String {
        VariantClassifier.shared.canonical(id)
    }

    // MARK: - Recent lookups

    func noteLookup(_ characterID: String) {
        let key = canonical(characterID)
        let descriptor = FetchDescriptor<RecentLookup>(
            predicate: #Predicate { $0.characterID == key }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.lastViewed = .now
        } else {
            context.insert(RecentLookup(characterID: key))
        }
        try? context.save()
    }

    func recentLookups(limit: Int = 12) -> [RecentLookup] {
        var descriptor = FetchDescriptor<RecentLookup>(
            sortBy: [SortDescriptor(\.lastViewed, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func clearRecentLookups() {
        guard let all = try? context.fetch(FetchDescriptor<RecentLookup>()) else { return }
        for r in all { context.delete(r) }
        try? context.save()
    }

    // MARK: - SRS cards

    func card(for characterID: String) -> SRSCard? {
        let key = canonical(characterID)
        let descriptor = FetchDescriptor<SRSCard>(
            predicate: #Predicate { $0.characterID == key }
        )
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    func ensureCard(for characterID: String) -> SRSCard {
        let key = canonical(characterID)
        if let existing = card(for: key) { return existing }
        let new = SRSCard(characterID: key)
        context.insert(new)
        try? context.save()
        return new
    }

    /// Cards due now or earlier.
    func dueCards(at date: Date = .now) -> [SRSCard] {
        let descriptor = FetchDescriptor<SRSCard>(
            predicate: #Predicate { $0.dueDate <= date },
            sortBy: [SortDescriptor(\.dueDate)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func allCards() -> [SRSCard] {
        (try? context.fetch(FetchDescriptor<SRSCard>())) ?? []
    }

    // MARK: - Quiz cards (reading / translation)

    func quizCard(for entry: String, mode: QuizMode) -> SRSQuizCard? {
        let key = SRSQuizCard.compositeKey(entry: canonicaliseWord(entry), mode: mode)
        let descriptor = FetchDescriptor<SRSQuizCard>(
            predicate: #Predicate { $0.key == key }
        )
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    func ensureQuizCard(for entry: String, mode: QuizMode) -> SRSQuizCard {
        let canon = canonicaliseWord(entry)
        if let existing = quizCard(for: canon, mode: mode) { return existing }
        let new = SRSQuizCard(entryKey: canon, quizMode: mode)
        context.insert(new)
        try? context.save()
        return new
    }

    /// Quiz cards due now or earlier in a given mode.
    func dueQuizCards(mode: QuizMode, at date: Date = .now) -> [SRSQuizCard] {
        let raw = mode.rawValue
        let descriptor = FetchDescriptor<SRSQuizCard>(
            predicate: #Predicate { $0.dueDate <= date && $0.quizModeRaw == raw },
            sortBy: [SortDescriptor(\.dueDate)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Lists

    func allLists() -> [VocabularyList] {
        (try? context.fetch(FetchDescriptor<VocabularyList>())) ?? []
    }

    private func nextVocabularyListSortRank() -> Int {
        let ranks = allLists().map(\.sortRank)
        return (ranks.max() ?? -1) + 1
    }

    @discardableResult
    func createList(name: String,
                    detail: String = "",
                    symbol: String = "book.closed.fill",
                    colorHex: Int = 0x266358,
                    initial: [String] = []) -> VocabularyList {
        // `initial` may be a mix of single-char and multi-char entries —
        // canonicalise each character individually so 學/学 collapse.
        let canonicalInitial = initial.map { canonicaliseWord($0) }
        let list = VocabularyList(name: name, detail: detail,
                                  symbol: symbol, colorHex: colorHex,
                                  sortRank: nextVocabularyListSortRank(),
                                  characterIDs: [],
                                  entries: canonicalInitial)
        context.insert(list)
        // Auto-add an SRS card for each constituent character so writing
        // practice can grade them. Word-level cards are added in Phase B.
        for entry in canonicalInitial {
            for ch in entry { _ = ensureCard(for: String(ch)) }
        }
        context.processPendingChanges()
        do {
            try context.save()
        } catch {
            print("HanziPractice: SwiftData failed to save new vocabulary list — \(error)")
        }
        return list
    }

    /// Canonicalise each character inside a multi-character word. So
    /// "学習" → "学习" (traditional → simplified), preserving boundaries.
    private func canonicaliseWord(_ word: String) -> String {
        if word.count == 1 { return canonical(word) }
        return String(word.map { c -> Character in
            let mapped = canonical(String(c))
            return mapped.first ?? c
        })
    }

    /// Add a single entry (character OR multi-character word) to the list.
    /// Replaces the older single-char `add(_:to:)` — that one's still here
    /// as a thin shim for callers that haven't migrated yet.
    func addEntry(_ entry: String, to list: VocabularyList) {
        let key = canonicaliseWord(entry)
        var entries = list.effectiveEntries
        guard !entries.contains(key) else { return }
        entries.append(key)
        list.entries = entries
        // Drop the legacy field once we've migrated this list onto entries
        // so the two stay in sync.
        list.characterIDs = []
        for ch in key { _ = ensureCard(for: String(ch)) }
        try? context.save()
    }

    /// Backwards-compat shim: single character add. New call sites should
    /// use `addEntry`. Kept so existing code (Dictionary → Add to list) works.
    func add(_ characterID: String, to list: VocabularyList) {
        addEntry(characterID, to: list)
    }

    /// Bulk-add words/chars; saves once at the end.
    func addManyEntries(_ entries: [String], to list: VocabularyList) {
        var current = list.effectiveEntries
        var changed = false
        for raw in entries {
            let key = canonicaliseWord(raw)
            if !current.contains(key) {
                current.append(key)
                for ch in key { _ = ensureCard(for: String(ch)) }
                changed = true
            }
        }
        if changed {
            list.entries = current
            list.characterIDs = []
            try? context.save()
        }
    }

    /// Backwards-compat shim.
    func addMany(_ characterIDs: [String], to list: VocabularyList) {
        addManyEntries(characterIDs, to: list)
    }

    func remove(_ entry: String, from list: VocabularyList) {
        let key = canonicaliseWord(entry)
        // Migrate legacy lists to `entries` storage on first edit so future
        // reads don't have to keep falling back through both fields.
        var current = list.effectiveEntries
        current.removeAll { $0 == key || $0 == entry }
        list.entries = current
        list.characterIDs = []
        try? context.save()
    }

    func deleteList(_ list: VocabularyList) {
        context.delete(list)
        try? context.save()
    }

    // MARK: - Practice records

    func recordPractice(characterID: String,
                        accuracy: Double,
                        retries: Int,
                        duration: Double,
                        kind: String = "writing") {
        let record = PracticeRecord(characterID: canonical(characterID),
                                    accuracy: accuracy,
                                    retries: retries,
                                    duration: duration,
                                    kind: kind)
        context.insert(record)
        try? context.save()
    }

    func recentPractice(limit: Int = 200) -> [PracticeRecord] {
        var descriptor = FetchDescriptor<PracticeRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Settings

    func settings() -> UserSettings {
        if let existing = try? context.fetch(FetchDescriptor<UserSettings>()).first {
            return existing
        }
        let s = UserSettings()
        context.insert(s)
        context.processPendingChanges()
        do {
            try context.save()
        } catch {
            print("HanziPractice: failed to save initial UserSettings — \(error)")
        }
        return s
    }
}
