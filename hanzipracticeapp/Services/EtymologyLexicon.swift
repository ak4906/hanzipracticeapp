//
//  EtymologyLexicon.swift
//  hanzipracticeapp
//
//  Per-character etymology prose extracted from `chinese-lexicon` (the npm
//  package by Peter Olson that powers dong-chinese.com). ISC-licensed code;
//  the wiki prose itself is CC BY-SA 4.0, so anywhere we surface a note in
//  the UI we credit "Dong Chinese · chinese-lexicon · CC BY-SA 4.0".
//
//  Bundled file: `etymology.tsv` — `<simplified>\t<notes>\t<components-json>`,
//  ~5k entries, ~1.3 MB. Parsed off the main actor on first load.
//
//  This data is complementary to the MMA-derived `Etymology` we already
//  attach to `HanziCharacter` — MMA gives us a structured component
//  breakdown with role tags; this gives us the natural-language
//  explanation (e.g. "Phonosemantic compound. 氵 represents the meaning
//  and 相 represents the sound.") that's hard to synthesise from
//  structure alone.
//

import Foundation

/// One row from the chinese-lexicon dump.
struct LexiconEtymology: Hashable, Sendable {
    let char: String
    /// Free-form prose explanation. May be empty for a handful of atomic
    /// components where the source only listed structural info.
    let notes: String
    /// Optional structured component list — same idea as MMA's
    /// `EtymologyComponent`, but sourced from chinese-lexicon. Used as a
    /// fallback when MMA didn't decompose the character.
    let components: [LexiconComponent]
}

struct LexiconComponent: Hashable, Sendable {
    /// "meaning", "sound", "iconic", "simplified", "unknown", etc. —
    /// kept verbatim so callers can decide how to render. Empty when the
    /// source row didn't tag a role.
    let type: String
    let char: String
    let pinyin: String      // tone-marked, may include multiple readings
    let definition: String  // English gloss, may include multiple meanings
    /// Optional sub-note attached to the component (e.g. "龰 is a
    /// component form of 止.").
    let notes: String
}

@MainActor
final class EtymologyLexicon {

    static let shared = EtymologyLexicon()

    private(set) var byChar: [String: LexiconEtymology] = [:]
    private(set) var isLoaded: Bool = false

    private init() {}

    /// Parse the bundled `etymology.tsv` on a background queue.
    /// ~5k entries, well under 100 ms on a modern simulator. Idempotent.
    func loadIfNeeded() async {
        if isLoaded { return }
        let parsed = await Task.detached(priority: .userInitiated) { () -> [String: LexiconEtymology] in
            guard let url = Bundle.main.url(forResource: "etymology", withExtension: "tsv"),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                print("EtymologyLexicon: etymology.tsv missing")
                return [:]
            }
            var out: [String: LexiconEtymology] = [:]
            out.reserveCapacity(6_000)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let entry = EtymologyLexicon.parse(line: Substring(line)) else { continue }
                // Source has one row per char; keep the first if a dup
                // ever sneaks in. Use `.keys.contains` so the dedup check
                // doesn't pull in main-actor-isolated Equatable inference
                // on the value type under Swift 6 strict concurrency.
                if !out.keys.contains(entry.char) {
                    out[entry.char] = entry
                }
            }
            return out
        }.value

        self.byChar = parsed
        self.isLoaded = true
        print("EtymologyLexicon: loaded \(parsed.count) entries")
    }

    /// O(1) lookup. Returns nil for characters chinese-lexicon doesn't
    /// cover (the bundle skews toward common hanzi).
    func entry(for char: String) -> LexiconEtymology? {
        byChar[char]
    }

    /// Convenience: just the prose note, trimmed. Returns nil when the
    /// entry exists but the notes string is empty.
    func notes(for char: String) -> String? {
        guard let n = byChar[char]?.notes else { return nil }
        let trimmed = n.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Random sample of etymology notes for quiz distractors. Optionally
    /// filtered by whether the entry has structured components — useful
    /// when we want pictogram-style distractors (no components) vs
    /// compound-ideogram-style (≥2 components). Excludes the listed
    /// chars and any entry with an empty notes field.
    func randomNotes(count: Int,
                     requireComponents: Bool? = nil,
                     excluding: Set<String> = []) -> [String] {
        guard count > 0, !byChar.isEmpty else { return [] }
        var candidates: [String] = []
        for (char, entry) in byChar {
            guard !excluding.contains(char) else { continue }
            let trimmedNotes = entry.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedNotes.isEmpty else { continue }
            if let req = requireComponents {
                if req && entry.components.isEmpty { continue }
                if !req && !entry.components.isEmpty { continue }
            }
            candidates.append(trimmedNotes)
        }
        candidates.shuffle()
        return Array(candidates.prefix(count))
    }

    /// Same as `randomNotes` but returns the full lexicon entry so the
    /// caller can run additional annotation on the components (e.g.
    /// the phono-semantic quiz that needs to append "氵 (water) — sound
    /// component" reference lines to each option uniformly).
    func randomEntries(count: Int,
                       requireComponents: Bool? = nil,
                       excluding: Set<String> = []) -> [LexiconEtymology] {
        guard count > 0, !byChar.isEmpty else { return [] }
        var candidates: [LexiconEtymology] = []
        for (char, entry) in byChar {
            guard !excluding.contains(char) else { continue }
            let trimmedNotes = entry.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedNotes.isEmpty else { continue }
            if let req = requireComponents {
                if req && entry.components.isEmpty { continue }
                if !req && !entry.components.isEmpty { continue }
            }
            candidates.append(entry)
        }
        candidates.shuffle()
        return Array(candidates.prefix(count))
    }

    // MARK: - Parsing

    /// Parse one TSV row. Returns nil for malformed lines so a bad row
    /// can't poison the whole load. Pure function — explicitly
    /// nonisolated so the background parser can call it.
    nonisolated private static func parse(line: Substring) -> LexiconEtymology? {
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let char = String(parts[0])
        guard !char.isEmpty else { return nil }
        let notes = String(parts[1])
        let componentsJSON = String(parts[2])
        let components = parseComponents(componentsJSON)
        return LexiconEtymology(char: char, notes: notes, components: components)
    }

    nonisolated private static func parseComponents(_ json: String) -> [LexiconComponent] {
        // Cheap fast-path: most entries are "[]".
        if json == "[]" || json.isEmpty { return [] }
        guard let data = json.data(using: .utf8) else { return [] }
        guard let decoded = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = decoded as? [[String: Any]] else { return [] }
        var out: [LexiconComponent] = []
        out.reserveCapacity(array.count)
        for raw in array {
            let char = (raw["char"] as? String) ?? ""
            guard !char.isEmpty else { continue }
            let type = (raw["type"] as? String) ?? ""
            let pinyin = (raw["pinyin"] as? String) ?? ""
            let definition = (raw["definition"] as? String) ?? ""
            let notes = (raw["notes"] as? String) ?? ""
            out.append(LexiconComponent(type: type,
                                        char: char,
                                        pinyin: pinyin,
                                        definition: definition,
                                        notes: notes))
        }
        return out
    }
}
