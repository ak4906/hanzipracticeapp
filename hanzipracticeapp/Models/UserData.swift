//
//  UserData.swift
//  hanzipracticeapp
//
//  SwiftData models that track everything the user creates: vocabulary lists,
//  spaced-repetition state, practice history, and recently-viewed characters.
//
//  CloudKit notes:
//    • All `@Attribute(.unique)` annotations have been removed — CloudKit
//      can't enforce uniqueness, so we de-dup at the controller layer
//      (fetch-then-insert) and run a one-time merge pass at launch.
//    • Every stored property has an inline default value so CloudKit can
//      treat them as nullable / defaultable in the generated CKRecord
//      schema. Constructors still accept the previous parameter lists
//      so existing call sites are unchanged.
//

import Foundation
import SwiftData

// MARK: - SRS

@Model
final class SRSCard {
    /// The character id (the hanzi itself). De-duped at controller layer
    /// via `UserDataController.ensureCard(for:)` rather than a SwiftData
    /// uniqueness constraint, because CloudKit doesn't support them.
    var characterID: String = ""

    /// Days until next review.
    var interval: Double = 0
    /// SM-2 ease factor.
    var ease: Double = 2.5
    /// Successful repetitions in a row.
    var repetitions: Int = 0

    var dueDate: Date = Date.now
    var lastReviewed: Date?
    var dateAdded: Date = Date.now

    /// 0…1 estimate of how well the user remembers this character; updated
    /// every review using an exponentially-weighted moving average.
    var mastery: Double = 0

    /// Total review count (any grade).
    var reviewCount: Int = 0
    /// Number of "again" grades (mistakes).
    var lapseCount: Int = 0

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

// MARK: - Quiz modes (reading / translation)

/// Self-graded recall quiz over a single entry — show 容易, ask the user
/// to recall its pinyin (reading) or English meaning (translation), reveal,
/// then grade Again/Hard/Good/Easy. The SRS state lives in a separate
/// model from writing because the skills are independent: you can read
/// 容易 fluently while still struggling to write it, and vice versa.
@Model
final class SRSQuizCard {
    /// Composite key — `"<entry>:<mode>"`. Used as the natural-key for
    /// dedup at the controller layer; CloudKit doesn't enforce
    /// uniqueness so the merge pass at launch reconciles any
    /// duplicates that arrive from another device.
    var key: String = ""
    /// The entry this card belongs to. Single char ("我") or word ("容易"),
    /// always in the canonical (Simplified) form.
    var entryKey: String = ""
    /// Which quiz mode this card tracks. Stored as a string so unknown
    /// values from a future build round-trip cleanly.
    var quizModeRaw: String = QuizMode.reading.rawValue

    /// Days until next review.
    var interval: Double = 0
    /// SM-2 ease factor.
    var ease: Double = 2.5
    /// Successful repetitions in a row.
    var repetitions: Int = 0

    var dueDate: Date = Date.now
    var lastReviewed: Date?
    var dateAdded: Date = Date.now

    var mastery: Double = 0
    var reviewCount: Int = 0
    var lapseCount: Int = 0

    init(entryKey: String,
         quizMode: QuizMode,
         interval: Double = 0,
         ease: Double = 2.5,
         repetitions: Int = 0,
         dueDate: Date = .now,
         mastery: Double = 0,
         reviewCount: Int = 0,
         lapseCount: Int = 0) {
        self.entryKey = entryKey
        self.quizModeRaw = quizMode.rawValue
        self.key = SRSQuizCard.compositeKey(entry: entryKey, mode: quizMode)
        self.interval = interval
        self.ease = ease
        self.repetitions = repetitions
        self.dueDate = dueDate
        self.dateAdded = .now
        self.mastery = mastery
        self.reviewCount = reviewCount
        self.lapseCount = lapseCount
    }

    /// Convenience constructor for the storage key used as the unique
    /// SwiftData attribute. Public so fetches can build it without
    /// duplicating the format string.
    static func compositeKey(entry: String, mode: QuizMode) -> String {
        "\(entry):\(mode.rawValue)"
    }

    var quizMode: QuizMode {
        QuizMode(rawValue: quizModeRaw) ?? .reading
    }

    /// Bucket for the Stats screen — same definition as `SRSCard.state`
    /// so reading / translation decks compare apples-to-apples with the
    /// writing deck.
    var state: SRSCard.DeckState {
        if reviewCount == 0 { return .new }
        if mastery >= 0.9 && interval >= 21 { return .mastered }
        if repetitions < 2 || interval < 1 { return .learning }
        return .review
    }
}

/// Which side of an entry's metadata the quiz asks the user to recall.
enum QuizMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Show the hanzi; recall the pinyin.
    case reading
    /// Show the hanzi; recall the English meaning.
    case translation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reading:     "Reading"
        case .translation: "Translation"
        }
    }

    var systemImage: String {
        switch self {
        case .reading:     "speaker.wave.2"
        case .translation: "globe"
        }
    }

    /// Word shown on the "tap to reveal" prompt.
    var promptWord: String {
        switch self {
        case .reading:     "pinyin"
        case .translation: "meaning"
        }
    }
}

// MARK: - User-supplied custom words

/// A multi-character vocab entry the user defined themselves — they
/// picked the hanzi combination and wrote their own pinyin + meaning.
/// Used when CC-CEDICT doesn't have the word they want to study (rare
/// compound nicknames, slang, brand transliterations, etc.).
@Model
final class CustomWordEntry {
    /// Canonical (Simplified) word string. De-duped at the controller
    /// layer (CloudKit doesn't enforce uniqueness).
    var word: String = ""
    /// User-supplied pinyin (tone marks expected; not validated).
    var customPinyin: String = ""
    /// User-supplied English meaning.
    var customMeaning: String = ""
    /// Optional traditional rendering — falls back to per-char conversion
    /// when nil.
    var customTraditional: String?
    var dateAdded: Date = Date.now

    init(word: String,
         customPinyin: String,
         customMeaning: String,
         customTraditional: String? = nil) {
        self.word = word
        self.customPinyin = customPinyin
        self.customMeaning = customMeaning
        self.customTraditional = customTraditional
        self.dateAdded = .now
    }
}

// MARK: - Vocabulary lists

@Model
final class VocabularyList {
    /// Stable identifier — UUIDs are collision-resistant enough that we
    /// don't need a SwiftData uniqueness constraint, and removing it is
    /// what CloudKit needs anyway.
    var id: UUID = UUID()
    var name: String = ""
    var detail: String = ""
    /// SF Symbol name shown on the list tile.
    var symbol: String = "book.closed.fill"
    /// Hex colour code (`0xRRGGBB`) for the list tile accent.
    var colorHex: Int = 0x266358
    var dateCreated: Date = Date.now
    /// Manual sort order on the Manage lists screen (lower = higher on screen).
    var sortRank: Int = 0
    /// Legacy single-character ids stored as an ordered array. Kept so old
    /// lists keep working — every read goes through `effectiveEntries` which
    /// falls back to this when `entries` is nil. New writes go to `entries`.
    var characterIDs: [String] = []
    /// Each entry is a *word* (one or more hanzi) — the simplified form,
    /// e.g. "容易" or "你好". Optional so existing rows lightweight-migrate.
    var entries: [String]?

    init(name: String,
         detail: String = "",
         symbol: String = "book.closed.fill",
         colorHex: Int = 0x266358,
         sortRank: Int = 0,
         characterIDs: [String] = [],
         entries: [String]? = nil) {
        self.id = UUID()
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.colorHex = colorHex
        self.dateCreated = .now
        self.sortRank = sortRank
        self.characterIDs = characterIDs
        self.entries = entries
    }

    /// What the UI should iterate over. New lists store words here; existing
    /// pre-word-support lists fall back to `characterIDs` so nothing breaks.
    var effectiveEntries: [String] {
        if let entries, !entries.isEmpty { return entries }
        return characterIDs
    }

    /// Flatten every entry to its constituent hanzi — used by writing
    /// practice until word-as-unit grading lands (Phase B).
    var flattenedCharacters: [String] {
        effectiveEntries.flatMap { entry in
            entry.map { String($0) }
        }
    }

    /// Display string for the entry count — pluralised and aware of whether
    /// the list holds multi-char words ("entries") or only single hanzi.
    var entryCountSummary: String {
        let n = effectiveEntries.count
        let hasMulti = effectiveEntries.contains { $0.count > 1 }
        if hasMulti {
            return "\(n) " + (n == 1 ? "entry" : "entries")
        }
        return "\(n) " + (n == 1 ? "character" : "characters")
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
    /// UUID identifier — collision-resistant enough that no SwiftData
    /// uniqueness constraint is needed.
    var id: UUID = UUID()
    var characterID: String = ""
    var date: Date = Date.now
    /// 0…1 overall accuracy of the attempt.
    var accuracy: Double = 0
    /// Number of strokes the user re-tried before passing.
    var retries: Int = 0
    /// Seconds spent on this attempt.
    var duration: Double = 0
    /// "writing", "review", "lookup", …
    var kind: String = "writing"

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
    /// De-duped at controller layer by `characterID`.
    var characterID: String = ""
    var lastViewed: Date = Date.now

    init(characterID: String) {
        self.characterID = characterID
        self.lastViewed = .now
    }
}

// MARK: - Settings

@Model
final class UserSettings {
    /// Daily review cap.
    var dailyNewLimit: Int = 10
    /// Whether to play stroke order audio cues.
    var soundsEnabled: Bool = true
    /// Selected writing system. When true, the dictionary, sessions, and
    /// trending lists only show Traditional (繁體) characters; otherwise the
    /// app shows only Simplified (简体) — no mixing.
    var preferTraditional: Bool = false

    /// Characters picked for **discovery** flows — Character of the Day,
    /// random/quick sessions when nothing is due, and "introduce new" pools —
    /// are limited to official HSK lists up through this level (1…6).
    /// Raise as you advance; SRS cards you already own are unaffected.
    ///
    /// Was originally property-default-less because lightweight migration
    /// trouble; CloudKit needs a default though, and current SwiftData
    /// versions handle this case cleanly. `effectivePracticeHSKCeiling`
    /// provides a non-zero floor if a sync-arriving row ever comes in
    /// uninitialised.
    var practiceHSKCeiling: Int = 1

    /// How many due cards to surface in a single "Today's Review" session.
    /// Optional so existing rows can lightweight-migrate (nil = use default).
    var dailyReviewLimit: Int?

    /// How many characters to interleave per chunk during multi-pass writing
    /// drills. Smaller chunks (2–3) keep the "memory" pass close enough to
    /// the "trace" pass that the learner still remembers the strokes.
    /// Optional for the same migration reason as above.
    var practiceChunkSize: Int?

    /// Writing direction for multi-character entries — `"horizontal"`
    /// (left-to-right, like reading prose) or `"vertical"` (top-to-bottom,
    /// like traditional calligraphy). Stored as a string so old rows
    /// lightweight-migrate cleanly. Optional → nil means use the default.
    var writingDirectionRaw: String?

    /// Canvas size mode: `"fit"` (all canvases shrink to fit on screen,
    /// best for 2-3 char words) or `"full"` (each canvas full-size,
    /// scroll/swipe between them — better for long words).
    var practiceCanvasFitRaw: String?

    /// Hard cap on the single-canvas square size in points. Optional so
    /// existing rows lightweight-migrate; nil = no cap (matches Phase B
    /// behaviour). Mostly useful on iPad where the canvas otherwise
    /// stretches across the whole screen — at 800pt of width, writing
    /// becomes uncomfortably arm-wide.
    var practiceCanvasMaxSize: Int?

    /// When true, the writing session inserts a multiple-choice quiz
    /// question between each pass — "what does X mean?", "how is X
    /// pronounced?" — to force the user to consciously associate
    /// strokes with meaning before going to memory. Optional so existing
    /// rows migrate cleanly; treated as false (off) by default.
    var interPassQuizEnabled: Bool?

    init(dailyNewLimit: Int = 10,
         soundsEnabled: Bool = true,
         preferTraditional: Bool = false,
         practiceHSKCeiling: Int = 1,
         dailyReviewLimit: Int? = nil,
         practiceChunkSize: Int? = nil,
         writingDirectionRaw: String? = nil,
         practiceCanvasFitRaw: String? = nil,
         practiceCanvasMaxSize: Int? = nil,
         interPassQuizEnabled: Bool? = nil) {
        self.dailyNewLimit = dailyNewLimit
        self.soundsEnabled = soundsEnabled
        self.preferTraditional = preferTraditional
        self.practiceHSKCeiling = practiceHSKCeiling
        self.dailyReviewLimit = dailyReviewLimit
        self.practiceChunkSize = practiceChunkSize
        self.writingDirectionRaw = writingDirectionRaw
        self.practiceCanvasFitRaw = practiceCanvasFitRaw
        self.practiceCanvasMaxSize = practiceCanvasMaxSize
        self.interPassQuizEnabled = interPassQuizEnabled
    }

    /// Effective values with sensible fallbacks — use these from views.
    var effectiveDailyReviewLimit: Int { dailyReviewLimit ?? 10 }
    var effectivePracticeChunkSize: Int { practiceChunkSize ?? 3 }
    var effectivePracticeHSKCeiling: Int {
        // Floor at 1 in case a freshly-synced CloudKit row arrives
        // with the default sentinel (0). Existing local rows store the
        // real value already.
        max(1, practiceHSKCeiling)
    }
    var effectiveWritingDirection: WritingDirection {
        WritingDirection(rawValue: writingDirectionRaw ?? "") ?? .horizontal
    }
    var effectivePracticeCanvasFit: PracticeCanvasFit {
        PracticeCanvasFit(rawValue: practiceCanvasFitRaw ?? "") ?? .fit
    }
}

// MARK: - User profile

/// Personal identity for the Profile tab — display name + chosen
/// avatar glyph. Kept deliberately small and CloudKit-friendly (all
/// stored properties have defaults, no `.unique`) so this model can be
/// the first to ride the upcoming `.cloudKit` SwiftData configuration
/// without a schema migration.
///
/// The avatar is currently a single Chinese character or emoji rather
/// than an image — keeps storage tiny, syncs instantly, and matches
/// the visual register of the rest of the app. A full
/// `Data`-backed picture can come later once we have a path for
/// shrinking + caching it through CloudKit.
@Model
final class UserProfile {
    /// Friendly display name, shown at the top of the Profile tab and
    /// reusable elsewhere (e.g. session greetings).
    var displayName: String = "Hanzi Learner"

    /// Single glyph or emoji rendered inside the avatar circle.
    /// Defaults to 学 ("study") — same character the older hard-coded
    /// header used, so existing installs look unchanged after the
    /// first sync.
    var avatarSymbol: String = "学"

    /// Background tint for the avatar circle. Stored as a packed
    /// 0xRRGGBB int so SwiftData / CloudKit don't need a custom
    /// `Color` codec.
    var avatarColorHex: Int = 0x266358

    /// When the profile row was created. Useful for "member since"
    /// chrome and for tie-breaking duplicate rows that could appear
    /// briefly during the first CloudKit merge.
    var dateCreated: Date = Date.now

    init(displayName: String = "Hanzi Learner",
         avatarSymbol: String = "学",
         avatarColorHex: Int = 0x266358) {
        self.displayName = displayName
        self.avatarSymbol = avatarSymbol
        self.avatarColorHex = avatarColorHex
        self.dateCreated = .now
    }
}

/// Reading-order axis for multi-character writing practice.
enum WritingDirection: String, CaseIterable, Identifiable, Sendable {
    case horizontal
    case vertical

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .horizontal: "Left → right"
        case .vertical:   "Top → bottom"
        }
    }
}

/// How big each canvas should be in a multi-character entry.
enum PracticeCanvasFit: String, CaseIterable, Identifiable, Sendable {
    /// Shrink canvases so they all fit on screen at once.
    case fit
    /// Keep canvases at their natural size; scroll / swipe between them.
    case full

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .fit:  "Fit all on screen"
        case .full: "Full size (scroll)"
        }
    }
}
