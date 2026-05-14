//
//  UserData.swift
//  hanzipracticeapp
//
//  SwiftData models that track everything the user creates: vocabulary lists,
//  spaced-repetition state, practice history, and recently-viewed characters.
//

import Foundation
import SwiftData

// MARK: - SRS

@Model
final class SRSCard {
    /// The character id (the hanzi itself).
    @Attribute(.unique) var characterID: String

    /// Days until next review.
    var interval: Double
    /// SM-2 ease factor.
    var ease: Double
    /// Successful repetitions in a row.
    var repetitions: Int

    var dueDate: Date
    var lastReviewed: Date?
    var dateAdded: Date

    /// 0…1 estimate of how well the user remembers this character; updated
    /// every review using an exponentially-weighted moving average.
    var mastery: Double

    /// Total review count (any grade).
    var reviewCount: Int
    /// Number of "again" grades (mistakes).
    var lapseCount: Int

    init(characterID: String,
         interval: Double = 0,
         ease: Double = 2.5,
         repetitions: Int = 0,
         dueDate: Date = .now,
         mastery: Double = 0,
         reviewCount: Int = 0,
         lapseCount: Int = 0) {
        self.characterID = characterID
        self.interval = interval
        self.ease = ease
        self.repetitions = repetitions
        self.dueDate = dueDate
        self.dateAdded = .now
        self.mastery = mastery
        self.reviewCount = reviewCount
        self.lapseCount = lapseCount
    }

    /// Bucket the card into one of the four deck states displayed on Stats.
    enum DeckState: String, CaseIterable {
        case new, learning, review, mastered

        var displayName: String {
            switch self {
            case .new: "New"
            case .learning: "Learning"
            case .review: "Review"
            case .mastered: "Mastered"
            }
        }
    }

    var state: DeckState {
        if reviewCount == 0 { return .new }
        if mastery >= 0.9 && interval >= 21 { return .mastered }
        if repetitions < 2 || interval < 1 { return .learning }
        return .review
    }
}

// MARK: - Vocabulary lists

@Model
final class VocabularyList {
    @Attribute(.unique) var id: UUID
    var name: String
    var detail: String
    /// SF Symbol name shown on the list tile.
    var symbol: String
    /// Hex colour code (`0xRRGGBB`) for the list tile accent.
    var colorHex: Int
    var dateCreated: Date
    /// Manual sort order on the Manage lists screen (lower = higher on screen).
    var sortRank: Int
    /// Character ids stored as an ordered array.
    var characterIDs: [String]

    init(name: String,
         detail: String = "",
         symbol: String = "book.closed.fill",
         colorHex: Int = 0x266358,
         sortRank: Int = 0,
         characterIDs: [String] = []) {
        self.id = UUID()
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.colorHex = colorHex
        self.dateCreated = .now
        self.sortRank = sortRank
        self.characterIDs = characterIDs
    }
}

extension Array where Element == VocabularyList {
    /// Matches manage/home ordering: manual rank first, then newest lists first as tie-breaker.
    func sortedForDisplay() -> [VocabularyList] {
        sorted {
            if $0.sortRank != $1.sortRank { return $0.sortRank < $1.sortRank }
            return $0.dateCreated > $1.dateCreated
        }
    }
}

// MARK: - Practice history

@Model
final class PracticeRecord {
    @Attribute(.unique) var id: UUID
    var characterID: String
    var date: Date
    /// 0…1 overall accuracy of the attempt.
    var accuracy: Double
    /// Number of strokes the user re-tried before passing.
    var retries: Int
    /// Seconds spent on this attempt.
    var duration: Double
    /// "writing", "review", "lookup", …
    var kind: String

    init(characterID: String,
         accuracy: Double,
         retries: Int = 0,
         duration: Double = 0,
         kind: String = "writing") {
        self.id = UUID()
        self.characterID = characterID
        self.date = .now
        self.accuracy = accuracy
        self.retries = retries
        self.duration = duration
        self.kind = kind
    }
}

// MARK: - Recently viewed

@Model
final class RecentLookup {
    @Attribute(.unique) var characterID: String
    var lastViewed: Date

    init(characterID: String) {
        self.characterID = characterID
        self.lastViewed = .now
    }
}

// MARK: - Settings

@Model
final class UserSettings {
    /// Daily review cap.
    var dailyNewLimit: Int
    /// Whether to play stroke order audio cues.
    var soundsEnabled: Bool
    /// Selected writing system. When true, the dictionary, sessions, and
    /// trending lists only show Traditional (繁體) characters; otherwise the
    /// app shows only Simplified (简体) — no mixing.
    var preferTraditional: Bool

    /// Characters picked for **discovery** flows — Character of the Day,
    /// random/quick sessions when nothing is due, and “introduce new” pools —
    /// are limited to official HSK lists up through this level (1…6).
    /// Raise as you advance; SRS cards you already own are unaffected.
    var practiceHSKCeiling: Int = 1

    init(dailyNewLimit: Int = 10,
         soundsEnabled: Bool = true,
         preferTraditional: Bool = false,
         practiceHSKCeiling: Int = 1) {
        self.dailyNewLimit = dailyNewLimit
        self.soundsEnabled = soundsEnabled
        self.preferTraditional = preferTraditional
        self.practiceHSKCeiling = practiceHSKCeiling
    }
}
