//
//  PinyinNumbers.swift
//  hanzipracticeapp
//
//  CC-CEDICT cross-references and many other Chinese-dictionary sources
//  spell pinyin with trailing tone digits (`Xiang1 dong1 Qu1`). For
//  display we want proper tone marks (`Xiāng dōng Qū`). This file does
//  the conversion in two flavours:
//
//   • `markedSyllable(_:)` — convert a single bare syllable
//     ("xiang1" → "xiāng").
//   • `convertBracketedTones(in:)` — walk a longer string, find every
//     `[...]` block, treat its contents as space-separated numbered
//     syllables, and rewrite them with tone marks. Anything outside
//     the brackets passes through unchanged.
//

import Foundation

enum PinyinNumbers {

    /// Convert a single bare syllable with a trailing tone digit (or no
    /// digit, in which case it's returned as-is) to the tone-marked form.
    /// Handles `u:` / `U:` → `ü` / `Ü`, capitalised initials (`Xi3` →
    /// `Xǐ`), and the iu/ui priority rule.
    static func markedSyllable(_ raw: String) -> String {
        guard let last = raw.unicodeScalars.last,
              let tone = digitValue(of: last),
              (1...5).contains(tone) else {
            // No trailing digit, or unrecognised digit — return as-is
            // (after the u:/ü swap so it still renders cleanly).
            return raw.replacingOccurrences(of: "u:", with: "ü")
                      .replacingOccurrences(of: "U:", with: "Ü")
        }
        var base = String(raw.dropLast())
            .replacingOccurrences(of: "u:", with: "ü")
            .replacingOccurrences(of: "U:", with: "Ü")
        // Tone 5 is neutral — no mark, just strip the digit.
        guard tone <= 4 else { return base }

        // Find the vowel that takes the mark: a > e > o, otherwise the
        // *last* of i / u / ü. This matches the standard pinyin rule
        // (in "iu" the mark goes on u; in "ui" the mark goes on i).
        let lower = base.lowercased()
        let priority: [Character] = ["a", "e", "o"]
        var targetIndex: String.Index? = nil
        for p in priority {
            if let idx = lower.firstIndex(of: p) {
                targetIndex = base.index(base.startIndex,
                                          offsetBy: lower.distance(from: lower.startIndex, to: idx))
                break
            }
        }
        if targetIndex == nil {
            for idx in lower.indices.reversed() where "iuü".contains(lower[idx]) {
                targetIndex = base.index(base.startIndex,
                                          offsetBy: lower.distance(from: lower.startIndex, to: idx))
                break
            }
        }
        guard let target = targetIndex else { return base }

        let original = base[target]
        let lowered = Character(original.lowercased())
        guard let marked = mark(for: lowered, tone: tone) else { return base }
        let finalChar: Character = original.isUppercase
            ? Character(String(marked).uppercased())
            : marked
        base.replaceSubrange(target...target, with: [finalChar])
        return base
    }

    /// Walk `text`, find every `[...]` block, treat its contents as a
    /// space-separated sequence of numbered syllables, and rewrite them
    /// with proper tone marks. Anything outside the brackets is left
    /// untouched. Used to clean up CC-CEDICT glosses for display:
    ///   "see 湘东区[Xiang1 dong1 Qu1]" → "see 湘东区[Xiāng dōng Qū]"
    static func convertBracketedTones(in text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "[",
               let close = text[i...].firstIndex(of: "]") {
                let inner = text[text.index(after: i)..<close]
                let converted = inner.split(separator: " ", omittingEmptySubsequences: false)
                    .map { markedSyllable(String($0)) }
                    .joined(separator: " ")
                out += "["
                out += converted
                out += "]"
                i = text.index(after: close)
            } else {
                out.append(text[i])
                i = text.index(after: i)
            }
        }
        return out
    }

    // MARK: - Private helpers

    private static func digitValue(of scalar: Unicode.Scalar) -> Int? {
        let v = Int(scalar.value)
        return (v >= 0x30 && v <= 0x39) ? v - 0x30 : nil
    }

    private static func mark(for vowel: Character, tone: Int) -> Character? {
        guard (1...4).contains(tone) else { return nil }
        switch vowel {
        case "a": return ["ā", "á", "ǎ", "à"][tone - 1]
        case "e": return ["ē", "é", "ě", "è"][tone - 1]
        case "i": return ["ī", "í", "ǐ", "ì"][tone - 1]
        case "o": return ["ō", "ó", "ǒ", "ò"][tone - 1]
        case "u": return ["ū", "ú", "ǔ", "ù"][tone - 1]
        case "ü": return ["ǖ", "ǘ", "ǚ", "ǜ"][tone - 1]
        default:  return nil
        }
    }
}
