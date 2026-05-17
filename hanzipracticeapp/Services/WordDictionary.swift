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
    /// Pre-lowercased gloss for fast substring matching during search —
    /// avoids re-lowering 110k entries on every keystroke.
    let glossLower: String
    /// Pre-stripped pinyin for fuzzy matching ("rongyi" → "róng yì").
    let pinyinToneless: String

    var id: String { simplified }

    /// Memberwise init with everything explicit — used by the bundled-file
    /// parser where we want to precompute the derived fields once.
    /// Explicitly nonisolated so the background TSV parser (which runs
    /// off the main actor) can construct entries.
    nonisolated init(simplified: String,
                     traditional: String,
                     pinyin: String,
                     gloss: String,
                     glossLower: String,
                     pinyinToneless: String) {
        self.simplified = simplified
        self.traditional = traditional
        self.pinyin = pinyin
        self.gloss = gloss
        self.glossLower = glossLower
        self.pinyinToneless = pinyinToneless
    }

    /// Convenience init for code paths that synthesise a `WordEntry` on
    /// the fly (e.g. opening the word detail sheet for a vocab-list entry
    /// CC-CEDICT doesn't know about). Derives the lowered / toneless
    /// fields automatically.
    nonisolated init(simplified: String,
                     traditional: String,
                     pinyin: String,
                     gloss: String) {
        self.init(simplified: simplified,
                  traditional: traditional,
                  pinyin: pinyin,
                  gloss: gloss,
                  glossLower: gloss.lowercased(),
                  pinyinToneless: pinyin.toneStripped)
    }

    /// Gloss with CC-CEDICT-style numbered pinyin (`Xiang1 dong1 Qu1`)
    /// converted to tone-marked form (`Xiāng dōng Qū`) for display.
    /// The raw `gloss` field is kept intact so search ranking can still
    /// match on the original text.
    var displayGloss: String {
        PinyinNumbers.convertBracketedTones(in: gloss)
    }

    /// First definition only, useful for compact list rows. Tone-marked
    /// for the same reason as `displayGloss`.
    var firstGloss: String {
        let display = displayGloss
        if let idx = display.firstIndex(of: ";") {
            return String(display[..<idx])
        }
        return display
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
    ///
    /// Results are *ranked* — an exact-gloss / exact-pinyin / exact-hanzi
    /// match outranks a coincidental substring match. Earlier the function
    /// just returned the first N raw hits in load order, which buried the
    /// obvious answer for queries like "eat" under hundreds of long
    /// idiom glosses that happened to contain the substring.
    /// Which kinds of matches `search` is allowed to score, mirroring
    /// `CharacterStore.SearchMode`. In `.pinyin` we won't return English
    /// gloss matches; in `.english` we won't return hanzi/pinyin matches;
    /// `.auto` and `.hanzi` consider everything.
    enum Scope { case auto, hanzi, pinyin, english }

    func search(_ query: String, scope: Scope = .auto, limit: Int = 50) -> [WordEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let qToneless = q.toneStripped
        let raw = query.trimmingCharacters(in: .whitespaces)
        var hits: [(WordEntry, Int)] = []
        for entry in all {
            // Cheap reject — only call the expensive ranking on entries
            // that have *some* substring match anywhere. Drops 99%+ of
            // the 110k entries in the inner loop for typical queries.
            let hanziHit = entry.simplified.contains(raw)
                || entry.traditional.contains(raw)
            let pinyinHit = entry.pinyinToneless.contains(qToneless)
            let glossHit = entry.glossLower.contains(q)
            // Filter the reject pass by scope so a Pinyin-mode search for
            // "beautiful" can't sneak through via a gloss hit.
            let candidate: Bool = {
                switch scope {
                case .auto, .hanzi: return hanziHit || pinyinHit || glossHit
                case .pinyin:       return pinyinHit
                case .english:      return glossHit
                }
            }()
            guard candidate else { continue }
            let score = matchScore(entry: entry,
                                   query: q,
                                   queryToneless: qToneless,
                                   rawQuery: raw,
                                   scope: scope)
            if score > 0 {
                hits.append((entry, score))
            }
        }
        return hits.sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Per-entry relevance score. Higher = more relevant. Tuned so direct
    /// hits on the *whole* simplified / pinyin reading / English gloss
    /// outrank substring-only matches, and shorter glosses outrank long
    /// ones (a definition that just says "easy" beats one that says
    /// "easy, simple, light, painless, comfortable, smooth, etc.").
    private func matchScore(entry: WordEntry,
                            query q: String,
                            queryToneless qt: String,
                            rawQuery raw: String,
                            scope: Scope) -> Int {
        var best = 0
        let considerHanzi = scope == .auto || scope == .hanzi
        let considerPinyin = scope == .auto || scope == .pinyin
        let considerEnglish = scope == .auto || scope == .english
        // Hanzi / traditional matches.
        if considerHanzi {
            if entry.simplified == raw || entry.traditional == raw { return 1500 }
            if entry.simplified.hasPrefix(raw) || entry.traditional.hasPrefix(raw) {
                best = max(best, 900)
            } else if entry.simplified.contains(raw) || entry.traditional.contains(raw) {
                best = max(best, 250)
            }
        }
        // Pinyin tokens.
        if considerPinyin {
            let pinyinHay = qt == q ? entry.pinyinToneless : entry.pinyin
            let pyTokens = pinyinHay.split(separator: " ").map { String($0) }
            if pyTokens == qt.split(separator: " ").map({ String($0) }) {
                best = max(best, 1000)
            } else if pyTokens.contains(qt) {
                best = max(best, 700)
            } else if pyTokens.contains(where: { $0.hasPrefix(qt) }) {
                best = max(best, 350)
            } else if entry.pinyinToneless.contains(qt) {
                best = max(best, 150)
            }
        }
        // English gloss — pick the strongest of the slash/semicolon-split
        // definitions, with a shorter-definition bonus so the canonical
        // entry beats one where the same word is buried in a long list.
        if considerEnglish {
            let defs = entry.glossLower
                .split(whereSeparator: { ",;()/[]".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for def in defs {
                if def == q || def == "to \(q)" {
                    best = max(best, 1100)
                    continue
                }
                let words = def.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map { String($0) }
                if words.contains(q) {
                    best = max(best, 700 - min(300, def.count * 3))
                } else if def.hasPrefix(q + " ") {
                    best = max(best, 400)
                } else if def.contains(q) {
                    best = max(best, 80)
                }
            }
        }
        return best
    }

    /// Parse one TSV line. Returns nil for malformed rows so a single bad
    /// entry can't poison the whole dictionary. Pure function — explicitly
    /// nonisolated so the background parser can call it.
    nonisolated private static func parse(line: Substring) -> WordEntry? {
        let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let gloss = String(parts[3])
        let pinyin = String(parts[2])
        return WordEntry(simplified: String(parts[0]),
                         traditional: String(parts[1]),
                         pinyin: pinyin,
                         gloss: gloss,
                         glossLower: gloss.lowercased(),
                         pinyinToneless: pinyin.toneStripped)
    }
}
