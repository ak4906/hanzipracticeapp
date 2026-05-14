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
        let canonicalInitial = initial.map { canonical($0) }
        let list = VocabularyList(name: name, detail: detail,
                                  symbol: symbol, colorHex: colorHex,
                                  sortRank: nextVocabularyListSortRank(),
                                  characterIDs: canonicalInitial)
        context.insert(list)
        // Auto-add any character to the SRS deck.
        for id in canonicalInitial { _ = ensureCard(for: id) }
        context.processPendingChanges()
        do {
            try context.save()
        } catch {
            print("HanziPractice: SwiftData failed to save new vocabulary list — \(error)")
        }
        return list
    }

    func add(_ characterID: String, to list: VocabularyList) {
        let key = canonical(characterID)
        if !list.characterIDs.contains(key) {
            list.characterIDs.append(key)
            _ = ensureCard(for: key)
            try? context.save()
        }
    }

    /// Bulk-add canonical ids; saves once at the end.
    func addMany(_ characterIDs: [String], to list: VocabularyList) {
        var changed = false
        for raw in characterIDs {
            let key = canonical(raw)
            if !list.characterIDs.contains(key) {
                list.characterIDs.append(key)
                _ = ensureCard(for: key)
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    func remove(_ characterID: String, from list: VocabularyList) {
        let key = canonical(characterID)
        list.characterIDs.removeAll { $0 == key || $0 == characterID }
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
        try? context.save()
        return s
    }
}
