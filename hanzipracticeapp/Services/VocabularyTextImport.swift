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
