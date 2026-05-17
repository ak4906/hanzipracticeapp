//
//  HanziCharacter.swift
//  hanzipracticeapp
//
//  Lightweight metadata for a Chinese character. Heavy stroke graphics
//  (SVG paths + medians) are sourced lazily from `MMAStore` so this struct
//  stays cheap to hold for the entire ~9,500-character dictionary.
//

import Foundation
import CoreGraphics

/// One example usage (compound / sentence) attached to a character.
struct UsageExample: Codable, Hashable, Sendable {
    let hanzi: String
    let pinyin: String
    let meaning: String
    let sentenceHanzi: String?
    let sentencePinyin: String?
    let sentenceMeaning: String?
}

/// A reference to another character — used for radicals / variants.
struct RelatedCharacter: Codable, Hashable, Sendable {
    let char: String
    let label: String
}

struct HanziCharacter: Hashable, Identifiable, Sendable {
    /// Stable storage key — always the **simplified** form. Used for SRS
    /// cards, vocab lists, recents so progress survives variant toggles.
    let canonicalID: String

    /// The character to render in the UI in the currently active writing
    /// system. May equal `canonicalID` (Simplified mode or no traditional
    /// counterpart) or be the Traditional form (`學`, `愛`, …).
    let char: String

    var id: String { canonicalID }

    let pinyin: String           // tone-marked, primary reading
    let pinyinToneless: String   // search-friendly
    /// All recognised readings for display ("dé / děi / de"). Falls
    /// back to `pinyin` when only one reading is known. Sourced from
    /// the chinese-lexicon bundle which catalogues every standard
    /// pronunciation per character.
    let pinyinAllReadings: String
    let meaning: String
    let hskLevel: Int            // 0 == outside HSK / unknown
    let strokeCount: Int

    let radical: RelatedCharacter?
    let variant: RelatedCharacter?
    let structure: String?

    let examples: [UsageExample]
    let mnemonic: String?
    let tags: [String]

    /// Component breakdown + type classification (phono-semantic etc.).
    /// Provided by MMA for almost every character; curated overrides may
    /// refine it for featured entries.
    let etymology: Etymology?
}
