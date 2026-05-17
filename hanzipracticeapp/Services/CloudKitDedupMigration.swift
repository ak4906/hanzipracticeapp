//
//  CloudKitDedupMigration.swift
//  hanzipracticeapp
//
//  Once SwiftData syncs through CloudKit, multiple devices can create
//  rows that "should" be unique by content (e.g. two SRSCards with the
//  same `characterID`) before any one device sees the others. CloudKit
//  doesn't enforce uniqueness — that's exactly why we removed every
//  `@Attribute(.unique)` — so we reconcile after the fact: at launch,
//  scan each natural-key model for duplicates, pick a winner, merge
//  the rest into it, and delete the losers.
//
//  Runs on every launch because it's cheap (handful of in-memory
//  groups) and idempotent. Logs a summary so collisions are visible
//  during development.
//

import Foundation
import SwiftData

@MainActor
enum CloudKitDedupMigration {

    /// Walk every dedup-eligible model and merge duplicates. Safe to
    /// call repeatedly; a no-op when nothing is duplicated.
    static func run(in context: ModelContext) {
        var totalMerges = 0
        totalMerges += mergeSRSCards(in: context)
        totalMerges += mergeSRSQuizCards(in: context)
        totalMerges += mergeCustomWords(in: context)
        totalMerges += mergeRecentLookups(in: context)
        totalMerges += mergeUserSettings(in: context)
        totalMerges += mergeUserProfiles(in: context)
        if totalMerges > 0 {
            do {
                try context.save()
                print("CloudKitDedupMigration: merged \(totalMerges) duplicate row(s)")
            } catch {
                print("CloudKitDedupMigration: save failed — \(error)")
            }
        }
    }

    // MARK: - SRSCard (writing) — merge by characterID, keep most-progressed

    private static func mergeSRSCards(in context: ModelContext) -> Int {
        let cards = (try? context.fetch(FetchDescriptor<SRSCard>())) ?? []
        let groups = Dictionary(grouping: cards, by: \.characterID)
        var merges = 0
        for (_, dupes) in groups where dupes.count > 1 {
            // Winner: the card with the most progress (highest review
            // count, then highest mastery). Carries forward the union
            // of state — newest review, most repetitions, etc.
            let sorted = dupes.sorted { a, b in
                if a.reviewCount != b.reviewCount { return a.reviewCount > b.reviewCount }
                if a.mastery != b.mastery { return a.mastery > b.mastery }
                return a.dateAdded < b.dateAdded
            }
            let winner = sorted[0]
            for loser in sorted.dropFirst() {
                mergeSRSState(from: loser, into: winner)
                context.delete(loser)
                merges += 1
            }
        }
        return merges
    }

    // MARK: - SRSQuizCard — merge by `key`, same rule as writing cards.

    private static func mergeSRSQuizCards(in context: ModelContext) -> Int {
        let cards = (try? context.fetch(FetchDescriptor<SRSQuizCard>())) ?? []
        let groups = Dictionary(grouping: cards, by: \.key)
        var merges = 0
        for (_, dupes) in groups where dupes.count > 1 {
            let sorted = dupes.sorted { a, b in
                if a.reviewCount != b.reviewCount { return a.reviewCount > b.reviewCount }
                if a.mastery != b.mastery { return a.mastery > b.mastery }
                return a.dateAdded < b.dateAdded
            }
            let winner = sorted[0]
            for loser in sorted.dropFirst() {
                mergeSRSQuizState(from: loser, into: winner)
                context.delete(loser)
                merges += 1
            }
        }
        return merges
    }

    // MARK: - CustomWordEntry — merge by `word`, keep newest definition.

    private static func mergeCustomWords(in context: ModelContext) -> Int {
        let words = (try? context.fetch(FetchDescriptor<CustomWordEntry>())) ?? []
        let groups = Dictionary(grouping: words, by: \.word)
        var merges = 0
        for (_, dupes) in groups where dupes.count > 1 {
            // User-edited content: keep whichever was edited most
            // recently (largest dateAdded since that's the only
            // touched-recently field on this model).
            let sorted = dupes.sorted { $0.dateAdded > $1.dateAdded }
            for loser in sorted.dropFirst() {
                context.delete(loser)
                merges += 1
            }
        }
        return merges
    }

    // MARK: - RecentLookup — merge by `characterID`, keep newest.

    private static func mergeRecentLookups(in context: ModelContext) -> Int {
        let lookups = (try? context.fetch(FetchDescriptor<RecentLookup>())) ?? []
        let groups = Dictionary(grouping: lookups, by: \.characterID)
        var merges = 0
        for (_, dupes) in groups where dupes.count > 1 {
            let sorted = dupes.sorted { $0.lastViewed > $1.lastViewed }
            let winner = sorted[0]
            for loser in sorted.dropFirst() {
                // Take the later timestamp into the winner so the
                // "recently viewed" order reflects the union.
                if loser.lastViewed > winner.lastViewed {
                    winner.lastViewed = loser.lastViewed
                }
                context.delete(loser)
                merges += 1
            }
        }
        return merges
    }

    // MARK: - UserSettings — singleton row, keep the oldest.

    private static func mergeUserSettings(in context: ModelContext) -> Int {
        let settings = (try? context.fetch(FetchDescriptor<UserSettings>())) ?? []
        guard settings.count > 1 else { return 0 }
        // Settings has no `dateCreated` — fall back to keeping the
        // first row (SwiftData fetch order is stable per persistent
        // store) so the choice is deterministic across launches.
        let winner = settings[0]
        // Take the highest enabled-or-non-default value across all
        // copies so a sync from a more-customised device doesn't lose
        // those tweaks.
        for loser in settings.dropFirst() {
            mergeSettings(from: loser, into: winner)
            context.delete(loser)
        }
        return settings.count - 1
    }

    // MARK: - UserProfile — singleton row, keep the oldest.

    private static func mergeUserProfiles(in context: ModelContext) -> Int {
        let profiles = (try? context.fetch(FetchDescriptor<UserProfile>(
            sortBy: [SortDescriptor(\.dateCreated, order: .forward)]
        ))) ?? []
        guard profiles.count > 1 else { return 0 }
        let winner = profiles[0]
        // The newer rows are likelier to carry the user's latest
        // chosen avatar / name, so promote those over the older
        // defaults.
        for loser in profiles.dropFirst() {
            if loser.displayName != "Hanzi Learner" {
                winner.displayName = loser.displayName
            }
            if loser.avatarSymbol != "学" {
                winner.avatarSymbol = loser.avatarSymbol
            }
            if loser.avatarColorHex != 0x266358 {
                winner.avatarColorHex = loser.avatarColorHex
            }
            context.delete(loser)
        }
        return profiles.count - 1
    }

    // MARK: - Merge helpers

    private static func mergeSRSState(from loser: SRSCard, into winner: SRSCard) {
        winner.reviewCount = max(winner.reviewCount, loser.reviewCount)
        winner.lapseCount = max(winner.lapseCount, loser.lapseCount)
        winner.repetitions = max(winner.repetitions, loser.repetitions)
        winner.mastery = max(winner.mastery, loser.mastery)
        winner.interval = max(winner.interval, loser.interval)
        winner.ease = max(winner.ease, loser.ease)
        // Move the next due date forward (longer interval ⇒ more
        // mastered) but never backward.
        if loser.dueDate > winner.dueDate { winner.dueDate = loser.dueDate }
        // Keep the *earliest* dateAdded — that's when the user
        // actually first met the character.
        if loser.dateAdded < winner.dateAdded { winner.dateAdded = loser.dateAdded }
        // Latest review timestamp wins.
        if let li = loser.lastReviewed,
           winner.lastReviewed == nil || li > (winner.lastReviewed ?? .distantPast) {
            winner.lastReviewed = li
        }
    }

    private static func mergeSRSQuizState(from loser: SRSQuizCard, into winner: SRSQuizCard) {
        winner.reviewCount = max(winner.reviewCount, loser.reviewCount)
        winner.lapseCount = max(winner.lapseCount, loser.lapseCount)
        winner.repetitions = max(winner.repetitions, loser.repetitions)
        winner.mastery = max(winner.mastery, loser.mastery)
        winner.interval = max(winner.interval, loser.interval)
        winner.ease = max(winner.ease, loser.ease)
        if loser.dueDate > winner.dueDate { winner.dueDate = loser.dueDate }
        if loser.dateAdded < winner.dateAdded { winner.dateAdded = loser.dateAdded }
        if let li = loser.lastReviewed,
           winner.lastReviewed == nil || li > (winner.lastReviewed ?? .distantPast) {
            winner.lastReviewed = li
        }
    }

    /// For each UserSettings property, prefer the *non-default* value
    /// so settings tweaked on one device persist after the merge.
    private static func mergeSettings(from loser: UserSettings, into winner: UserSettings) {
        if loser.dailyNewLimit != 10 { winner.dailyNewLimit = loser.dailyNewLimit }
        if !loser.soundsEnabled { winner.soundsEnabled = false }
        if loser.preferTraditional { winner.preferTraditional = true }
        if loser.practiceHSKCeiling > 1 { winner.practiceHSKCeiling = loser.practiceHSKCeiling }
        if let v = loser.dailyReviewLimit { winner.dailyReviewLimit = v }
        if let v = loser.practiceChunkSize { winner.practiceChunkSize = v }
        if let v = loser.writingDirectionRaw { winner.writingDirectionRaw = v }
        if let v = loser.practiceCanvasFitRaw { winner.practiceCanvasFitRaw = v }
        if let v = loser.practiceCanvasMaxSize { winner.practiceCanvasMaxSize = v }
        if let v = loser.interPassQuizEnabled { winner.interPassQuizEnabled = v }
    }
}
