//
//  SingleCharDefinitions.swift
//  hanzipracticeapp
//
//  Learner-friendly single-character glosses extracted from
//  `chinese-lexicon` (the npm package by Peter Olson, ISC-licensed —
//  same source as the etymology bundle). MMA's per-character glosses
//  skew Classical / literary ("essential, necessary" for 要), which
//  doesn't match how the character is taught in modern HSK / CEFR
//  classes ("to want, to ask for, will"). This bundle gives us the
//  teaching-relevant form for ~10.8k single chars.
//
//  Bundled file: `definitions.tsv`, ~760 KB. Format per row:
//    <char>\t<pinyin-readings>\t<short-definition>\t<full-definition>
//
//  Where:
//    • <pinyin-readings> is tone-marked, semicolon-separated for chars
//      with multiple readings (e.g. "yào; yāo").
//    • <short-definition> ≤ 30 chars — designed to fit on a quiz chip
//      and answer "what does X mean?" the way a teacher would.
//    • <full-definition> ≤ 240 chars — every reading's definitions
//      joined; used when we want the long-form gloss on a detail page.
//

import Foundation

struct LexiconDefinition: Hashable, Sendable {
    let char: String
    /// Tone-marked, semicolon-separated readings ("yào; yāo").
    let pinyinReadings: String
    /// Compact gloss for quiz chips / list rows ("to want, to ask for").
    let short: String
    /// Long-form gloss for detail pages.
    let full: String
}

@MainActor
final class SingleCharDefinitions {

    static let shared = SingleCharDefinitions()

    private(set) var byChar: [String: LexiconDefinition] = [:]
    private(set) var isLoaded: Bool = false

    private init() {}

    /// Parse the bundled `definitions.tsv` on a background queue.
    /// ~10.8k entries — sub-100 ms on a modern simulator. Idempotent.
    func loadIfNeeded() async {
        if isLoaded { return }
        let parsed = await Task.detached(priority: .userInitiated) { () -> [String: LexiconDefinition] in
            guard let url = Bundle.main.url(forResource: "definitions", withExtension: "tsv"),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                print("SingleCharDefinitions: definitions.tsv missing")
                return [:]
            }
            var out: [String: LexiconDefinition] = [:]
            out.reserveCapacity(12_000)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let entry = SingleCharDefinitions.parse(line: Substring(line)) else { continue }
                if !out.keys.contains(entry.char) {
                    out[entry.char] = entry
                }
            }
            return out
        }.value

        self.byChar = parsed
        self.isLoaded = true
        print("SingleCharDefinitions: loaded \(parsed.count) entries")
    }

    /// O(1) lookup. Returns nil for chars not in the bundle (rare —
    /// covers all HSK plus most CJK Ext-A / B).
    func entry(for char: String) -> LexiconDefinition? {
        byChar[char]
    }

    /// Convenience accessor for the short form, used as the preferred
    /// single-char meaning when synthesising `HanziCharacter`.
    func shortDefinition(for char: String) -> String? {
        byChar[char]?.short
    }

    // MARK: - Parsing

    nonisolated private static func parse(line: Substring) -> LexiconDefinition? {
        let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let char = String(parts[0])
        guard !char.isEmpty else { return nil }
        return LexiconDefinition(char: char,
                                 pinyinReadings: String(parts[1]),
                                 short: String(parts[2]),
                                 full: String(parts[3]))
    }
}
