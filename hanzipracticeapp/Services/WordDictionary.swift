//
//  WordDictionary.swift
//  hanzipracticeapp
//
//  Multi-character Chinese-English dictionary backed by CC-CEDICT (the
//  community-maintained list published by MDBG, CC-BY-SA 4.0). Single-character
//  data still comes from the existing MMA store; this fills in *words* like
//  容易 / 冰激凌 / 你好 that MMA doesn't cover as units.
//
//  The bundled file is `cedict.tsv` — pre-filtered to entries whose simplified
//  form has 2+ Chinese characters, with numeric tones converted to tone marks
//  at build time so we don't pay that cost on every launch.
//
//  Format per line: `<simplified>\t<traditional>\t<pinyin>\t<gloss>`
//

import Foundation

/// One row in CC-CEDICT (multi-character only — single-char hanzi go through
/// `CharacterStore` / MMA so we don't duplicate metadata).
struct WordEntry: Hashable, Identifiable, Sendable {
    let simplified: String     // canonical key
    let traditional: String
    let pinyin: String         // tone-marked, space-separated syllables
    let gloss: String          // English definitions joined by "; "

    var id: String { simplified }

    /// Pinyin with no tone marks, lower-cased — used for fuzzy search like
    /// "rongyi" matching "róng yì".
    var pinyinToneless: String { pinyin.toneStripped }

    /// First definition only, useful for compact list rows.
    var firstGloss: String {
        if let idx = gloss.firstIndex(of: ";") {
            return String(gloss[..<idx])
        }
        return gloss
    }
}

@MainActor
final class WordDictionary {

    static let shared = WordDictionary()

    /// Lookup table keyed by simplified form (the canonical key — same
    /// convention as the rest of the user-data storage).
    private(set) var bySimplified: [String: WordEntry] = [:]

    /// All entries in insertion order. Used by search.
    private(set) var all: [WordEntry] = []

    /// True once `loadIfNeeded()` has finished — UI can decide whether to
    /// surface word-search results yet.
    private(set) var isLoaded: Bool = false

    private init() {}

    /// Parse the bundled `cedict.tsv` on a background queue. ~110k entries,
    /// roughly 200-400ms on a modern simulator. Idempotent — subsequent calls
    /// are no-ops.
    func loadIfNeeded() async {
        if isLoaded { return }
        let parsed = await Task.detached(priority: .userInitiated) { () -> [WordEntry] in
            guard let url = Bundle.main.url(forResource: "cedict", withExtension: "tsv"),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                print("WordDictionary: cedict.tsv missing")
                return []
            }
            var out: [WordEntry] = []
            out.reserveCapacity(120_000)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let entry = WordDictionary.parse(line: Substring(line)) else { continue }
                out.append(entry)
            }
            return out
        }.value

        self.all = parsed
        // CC-CEDICT can list the same simplified form under multiple readings
        // ("一并" appears with both yībìng readings). Keep the first occurrence
        // — uniqueKeysWithValues traps on duplicates, which was crashing the
        // whole load and leaving the splash screen stuck on "Loading…".
        self.bySimplified = Dictionary(parsed.map { ($0.simplified, $0) },
                                       uniquingKeysWith: { first, _ in first })
        self.isLoaded = true
        print("WordDictionary: loaded \(parsed.count) word entries, \(bySimplified.count) unique simplified keys")
    }

    /// O(1) exact-match lookup.
    func entry(for simplified: String) -> WordEntry? {
        bySimplified[simplified]
    }

    /// Whether the simplified string is a known multi-character word. Used
    /// by the paste-import tokenizer to decide where to break.
    func contains(_ simplified: String) -> Bool {
        bySimplified[simplified] != nil
    }

    /// Greedy longest-match tokenisation. Given a run of Chinese text like
    /// "我们喜欢吃冰激凌" (no spaces), returns ["我们", "喜欢", "吃", "冰激凌"]
    /// when those entries are in the dictionary. Single-character fallback
    /// emits the bare hanzi when nothing longer matches.
    ///
    /// `maxWordLength` caps the longest substring we'll try — most Chinese
    /// words are 1–4 characters, so 6 is a generous ceiling.
    func tokenize(_ text: String, maxWordLength: Int = 6) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var i = 0
        while i < chars.count {
            var matched = false
            let upper = min(chars.count - i, maxWordLength)
            // Try longest first.
            for length in stride(from: upper, through: 2, by: -1) {
                let candidate = String(chars[i..<i+length])
                if bySimplified[candidate] != nil {
                    out.append(candidate)
                    i += length
                    matched = true
                    break
                }
            }
            if !matched {
                // No multi-char match — emit the single character as-is.
                out.append(String(chars[i]))
                i += 1
            }
        }
        return out
    }

    /// Linear-scan search. Slow for autocomplete-on-every-keystroke at 110k
    /// entries (~30-50 ms), so callers should debounce. Matches simplified,
    /// pinyin (tone-marked or toneless), or English gloss — case-insensitive.
    func search(_ query: String, limit: Int = 50) -> [WordEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let qToneless = q.toneStripped
        var out: [WordEntry] = []
        out.reserveCapacity(limit)
        for entry in all {
            if entry.simplified.contains(query)
                || entry.traditional.contains(query)
                || entry.pinyinToneless.contains(qToneless)
                || entry.gloss.lowercased().contains(q) {
                out.append(entry)
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// Parse one TSV line. Returns nil for malformed rows so a single bad
    /// entry can't poison the whole dictionary. Pure function — explicitly
    /// nonisolated so the background parser can call it.
    nonisolated private static func parse(line: Substring) -> WordEntry? {
        let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        return WordEntry(simplified: String(parts[0]),
                         traditional: String(parts[1]),
                         pinyin: String(parts[2]),
                         gloss: String(parts[3]))
    }
}
