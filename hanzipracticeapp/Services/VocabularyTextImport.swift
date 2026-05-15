//
//  VocabularyTextImport.swift
//  hanzipracticeapp
//
//  Pulls individual Hanzi from pasted prose / comma-separated vocabulary so
//  users can build lists from textbook snippets or flashcard exports.
//

import Foundation

nonisolated enum VocabularyTextImport {

    /// Each CJK unified / extension ideograph in document order (commas,
    /// spaces, Latin text, etc. are skipped).
    static func hanziInOrder(from text: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(min(text.count, 512))
        for ch in text where containsHanziScalar(ch) {
            out.append(String(ch))
        }
        return out
    }

    /// Dedupes by canonical id while preserving first-seen order.
    static func uniqueCanonicalSequence(_ chars: [String],
                                        canonical: (String) -> String) -> [String] {
        var seen = Set<String>()
        seen.reserveCapacity(chars.count)
        var out: [String] = []
        for ch in chars {
            let c = canonical(ch)
            if seen.insert(c).inserted {
                out.append(c)
            }
        }
        return out
    }

    /// Pull contiguous Chinese-character runs from pasted text. Latin
    /// characters, digits, punctuation, and whitespace all act as word
    /// breaks — useful before handing to `WordDictionary.tokenize` so we
    /// don't try to merge across "我们;喜欢吃" into one bogus token.
    static func hanziRuns(from text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for ch in text {
            if containsHanziScalar(ch) {
                current.append(ch)
            } else if !current.isEmpty {
                runs.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Word-level tokens preserved in document order, already canonicalised
    /// to Simplified and deduped. Multi-character words recognised by
    /// CC-CEDICT (容易, 冰激凌, …) come through as single entries; characters
    /// that don't form a known word fall through as individual hanzi.
    ///
    /// Canonicalisation happens *before* tokenisation so paste text with
    /// traditional/simplified annotations like `收養 (收养)` doesn't end up
    /// producing three entries (收 + 养 + 收养): the 收養 run gets mapped
    /// to 收养, then tokenises identically to the (收养) run, and the
    /// dedupe step collapses them.
    ///
    /// Caller must pass `WordDictionary.shared` explicitly — using a default
    /// parameter here would evaluate `.shared` in a nonisolated context,
    /// which is a Swift 6 error since `WordDictionary` is main-actor-bound.
    @MainActor
    static func wordsInOrder(from text: String,
                             using dictionary: WordDictionary) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for run in hanziRuns(from: text) {
            let canonical = canonicaliseToSimplified(run)
            for token in dictionary.tokenize(canonical) {
                if seen.insert(token).inserted {
                    out.append(token)
                }
            }
        }
        return out
    }

    /// Per-character map from any variant to its canonical (Simplified)
    /// form using the bundled OpenCC dictionaries via `VariantClassifier`.
    /// `nonisolated final class VariantClassifier` is `@unchecked Sendable`,
    /// so it's fine to call from this MainActor-only context.
    @MainActor
    private static func canonicaliseToSimplified(_ s: String) -> String {
        String(s.map { ch -> Character in
            let mapped = VariantClassifier.shared.canonical(String(ch))
            return mapped.first ?? ch
        })
    }

    /// Legacy entry point. Pre-dedupe variant of `wordsInOrder` no longer
    /// exists, so callers that used to chain `uniqueCanonicalWords` on top
    /// of an un-canonicalised list now get an already-deduped result from
    /// `wordsInOrder` directly. Retained as a no-op pass-through so any
    /// stragglers compile.
    static func uniqueCanonicalWords(_ words: [String],
                                     canonical: (String) -> String) -> [String] {
        words
    }

    private static func containsHanziScalar(_ ch: Character) -> Bool {
        for s in ch.unicodeScalars {
            let v = s.value
            switch v {
            case 0x3400...0x4DBF: return true   // Ext A
            case 0x4E00...0x9FFF: return true   // BMP
            case 0x20000...0x2A6DF: return true // Ext B
            case 0x2A700...0x2B73F: return true // Ext C
            case 0x2B740...0x2B81F: return true // Ext D
            case 0x2B820...0x2CEAF: return true // Ext E
            case 0x30000...0x3134F: return true // Ext G / H slice
            default: break
            }
        }
        return false
    }
}
