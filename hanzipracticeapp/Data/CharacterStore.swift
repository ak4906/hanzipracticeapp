//
//  CharacterStore.swift
//  hanzipracticeapp
//
//  Wraps the bundled MMA data set plus an in-code "curated overlay" of rich
//  metadata (HSK, mnemonics, example sentences) for featured characters.
//
//  Performance notes:
//    • The 9,500-entry search index is built on a *background* task during
//      `bootstrap()` so the main actor only sees the result.
//    • `HanziCharacter` records are synthesised on demand and cached. We
//      never eagerly materialise the full Cartesian set.
//

import Foundation
import Observation

/// Compact, Sendable per-character row used by search and iteration.
struct SearchEntry: Sendable {
    /// Canonical (Simplified) form — also the SwiftData key.
    let canonicalID: String
    /// Form keyed in MMA — varies by entry; we index *all* MMA entries so
    /// both 学 and 學 each have their own row.
    let char: String
    /// All readings, lowercased, tone-marks stripped (joined by space).
    let pinyinToneless: String
    /// All readings, lowercased, tone-marks intact (joined by space).
    let pinyinLower: String
    /// Lowercased definition / gloss.
    let meaningLower: String
}

@Observable
@MainActor
final class CharacterStore {

    // MARK: - Stored state

    private(set) var isLoaded: Bool = false

    /// One row per hanzi we know about (full set across both variants).
    private(set) var searchIndex: [SearchEntry] = []

    /// IDs surviving the current Simplified/Traditional filter — O(1) lookups.
    private(set) var filteredIDs: Set<String> = []

    /// Active writing system. Mutate via `setVariant(_:)`.
    private(set) var variant: ChineseVariant = .simplified

    /// Curated overlay keyed by hanzi.
    @ObservationIgnored private var curatedMap: [String: CuratedCharacter] = [:]

    /// Synthesised `HanziCharacter` cache. Built lazily by `character(for:)`.
    @ObservationIgnored private var synthCache: [String: HanziCharacter] = [:]

    /// component-char  →  list of canonical hanzi that include it.
    /// Used to answer "what other characters share 月?" with O(1) lookup.
    @ObservationIgnored private var componentIndex: [String: [String]] = [:]

    /// Memoised `byHSK` payload for the currently-active variant.
    /// Invalidated whenever the variant changes.
    @ObservationIgnored private var byHSKCache: [(level: Int, characters: [HanziCharacter])]? = nil

    init() {}

    // MARK: - Variant

    func setVariant(_ new: ChineseVariant) {
        guard new != variant else { return }
        variant = new
        synthCache.removeAll(keepingCapacity: true)
        byHSKCache = nil
        rebuildFilteredIDs()
    }

    private func rebuildFilteredIDs() {
        let classifier = VariantClassifier.shared
        var set: Set<String> = []
        set.reserveCapacity(searchIndex.count)
        for entry in searchIndex {
            if classifier.includes(entry.char, in: variant) {
                set.insert(entry.char)
            }
        }
        filteredIDs = set
    }

    /// Canonical (Simplified) storage key for `char`. Use this when reading
    /// or writing SRS cards / vocab lists / recents so progress survives a
    /// variant toggle.
    nonisolated func canonical(_ char: String) -> String {
        VariantClassifier.shared.canonical(char)
    }

    /// The display form of `char` in the active writing system.
    func displayed(_ char: String) -> String {
        VariantClassifier.shared.displayed(char, in: variant)
    }

    /// Word-level variant mapping. Each character in `word` is run through
    /// the per-character OpenCC map, so a canonical-Simplified entry like
    /// "学习" renders as "學習" in Traditional mode without us needing a
    /// separate word-level mapping table. Used everywhere a vocab-list
    /// entry's raw key is rendered (list rows, practice header, quiz card).
    func displayedWord(_ word: String) -> String {
        if word.count == 1 { return displayed(word) }
        let classifier = VariantClassifier.shared
        let v = variant
        return String(word.map { ch -> Character in
            let mapped = classifier.displayed(String(ch), in: v)
            return mapped.first ?? ch
        })
    }

    /// Variant transformation for free-form Mandarin text — e.g. the
    /// example sentences pulled from Tatoeba, which mix Simplified and
    /// Traditional source content. Runs every CJK character through the
    /// OpenCC mapping and passes punctuation / Latin / digits through
    /// unchanged. Without this, a user in Simplified mode would see
    /// 「來」 in a sentence even though their settings ask for 来.
    func displayedSentence(_ sentence: String) -> String {
        let classifier = VariantClassifier.shared
        let v = variant
        return String(sentence.map { ch -> Character in
            let mapped = classifier.displayed(String(ch), in: v)
            return mapped.first ?? ch
        })
    }

    /// Pinyin transliteration of a Chinese sentence. Goal: produce
    /// reading aids that match what a native speaker would actually
    /// say + how a textbook would print it, not a brittle
    /// char-by-char fallback that emits raw hanzi when MMA hasn't
    /// catalogued an obscure character.
    ///
    /// Strategy:
    ///   1. Greedy-tokenise into words (CC-CEDICT entries) so 妈妈 is
    ///      one token, not two. We then use the word's CEDICT pinyin
    ///      directly — that preserves capitalisation for proper nouns
    ///      (北京 → "Běijīng", 周 → surname "Zhōu" when the entry
    ///      flags it) and neutral tones (妈 in 妈妈 reads "ma" not
    ///      "mā"). Adjacent syllables inside the same word are
    ///      space-collapsed so the textbook form "māma" reads as one
    ///      word, not "mā ma".
    ///   2. Per-character fallback: MMA primary → chinese-lexicon
    ///      single-char short reading → `?` placeholder. We never
    ///      emit the raw hanzi; the prior fallback was leaking 肏 /
    ///      屄 / other rare chars into the pinyin line.
    ///   3. 一 / 不 sandhi post-pass on per-character segments so 不是
    ///      reads "búshì" even when it's tokenised as two singletons.
    func pinyinReading(for sentence: String) -> String {
        // Step 1 — segment into runs of hanzi and non-hanzi glyphs.
        // Each hanzi run is tokenised against the word dictionary;
        // non-hanzi glyphs pass through verbatim.
        var pieces: [String] = []
        var buffer: [Character] = []
        let flushBuffer: ([Character]) -> [String] = { buf in
            guard !buf.isEmpty else { return [] }
            return self.tokenisedPinyin(forHanziRun: String(buf))
        }
        for ch in sentence {
            if Self.isHanzi(String(ch)) {
                buffer.append(ch)
            } else {
                pieces.append(contentsOf: flushBuffer(buffer))
                buffer.removeAll(keepingCapacity: true)
                pieces.append(String(ch))
            }
        }
        pieces.append(contentsOf: flushBuffer(buffer))
        return pieces.joined()
    }

    /// Build the pinyin string for a run of contiguous hanzi. Each
    /// returned element is either a word-level pinyin token (already
    /// space-collapsed) or a single-char fallback, with a leading
    /// space prepended on every element after the first so the caller
    /// can just `.joined()` them.
    private func tokenisedPinyin(forHanziRun run: String) -> [String] {
        // WordDictionary's tokenizer does longest-match greedy
        // segmentation; we then look up each word in the dictionary
        // to get its pinyin (which is already capitalised + neutral-
        // toned correctly per CEDICT). Single-char tokens get the
        // existing per-character logic + tone sandhi.
        let words = WordDictionary.shared.tokenize(run)
        // Build per-syllable tokens for the sandhi pass — we want 一
        // / 不 sandhi to fire across word boundaries too (e.g. "一年"
        // when it's one token from the lexicon AND "一" alone before
        // a 4th-tone char in another segment).
        var sandhiTokens: [(char: String, pinyin: String)] = []
        var tokenSpans: [(wordIdx: Int, sandhiStart: Int, sandhiEnd: Int)] = []
        for (wi, word) in words.enumerated() {
            let start = sandhiTokens.count
            // Word-level entry: pull its CEDICT pinyin and split into
            // syllables for sandhi alignment.
            if word.count > 1, let entry = WordDictionary.shared.entry(for: word) {
                let syllables = entry.pinyin.split(separator: " ").map(String.init)
                let chars = Array(word).map(String.init)
                // Best-effort align: when the syllable count matches
                // the char count (almost always true for CEDICT
                // entries), pair them up. Otherwise fall back to
                // single-char lookups for this word so sandhi
                // alignment stays stable.
                if syllables.count == chars.count {
                    for (i, ch) in chars.enumerated() {
                        sandhiTokens.append((ch, syllables[i]))
                    }
                } else {
                    for ch in chars {
                        sandhiTokens.append((ch, perCharPinyin(ch) ?? "?"))
                    }
                }
            } else {
                let ch = word
                sandhiTokens.append((ch, perCharPinyin(ch) ?? "?"))
            }
            tokenSpans.append((wi, start, sandhiTokens.count))
        }
        // Apply 一 / 不 sandhi across the full sentence span.
        ToneSandhi.apply(to: &sandhiTokens)
        // Re-emit per word: collapse word-internal syllables to no
        // spaces ("māma"), and add a single leading space between
        // separate words so the joined output reads "nǐ māma ne".
        var out: [String] = []
        for (wi, start, end) in tokenSpans {
            guard end > start else { continue }
            let chunk = sandhiTokens[start..<end].map(\.pinyin).joined()
            let prefix = (wi == 0) ? "" : " "
            out.append(prefix + chunk)
        }
        return out
    }

    /// Per-character pinyin lookup with a full fallback chain:
    /// MMA-primary → chinese-lexicon's first reading → nil. Used by
    /// the sentence tokeniser; the nil case is replaced with `?` so
    /// we never leak the raw hanzi into the pinyin line.
    private func perCharPinyin(_ char: String) -> String? {
        if let c = character(for: char), !c.pinyin.isEmpty {
            return c.pinyin
        }
        // The single-char definitions bundle covers a much wider set
        // than MMA (10.8k vs ~9k). Take the first reading from its
        // `pinyinReadings` field — it's already tone-marked.
        if let def = SingleCharDefinitions.shared.entry(for: char) {
            let first = def.pinyinReadings
                .split(separator: ";", maxSplits: 1)
                .first.map { $0.trimmingCharacters(in: .whitespaces) }
            if let f = first, !f.isEmpty { return f }
        }
        return nil
    }

    // MARK: - Loading

    /// Loads MMA data + builds the search index on a background task.
    func bootstrap(initialVariant: ChineseVariant = .simplified) async {
        guard !isLoaded else { return }

        let t0 = Date()
        let result = await Task.detached(priority: .userInitiated) {
            MMAStore.shared.loadIfNeeded()
            VariantClassifier.shared.loadIfNeeded()
            HSKLevels.shared.loadIfNeeded()
            return Self.buildIndex()
        }.value

        self.searchIndex = result.index
        self.curatedMap = result.curated
        self.componentIndex = result.componentIndex
        self.variant = initialVariant
        rebuildFilteredIDs()
        self.isLoaded = true
        print("CharacterStore bootstrap \(Int(Date().timeIntervalSince(t0) * 1000))ms — \(result.index.count) entries (\(filteredIDs.count) in \(initialVariant.rawValue))")
    }

    /// Heavy build phase — runs off main actor.
    nonisolated static func buildIndex()
        -> (index: [SearchEntry],
            curated: [String: CuratedCharacter],
            componentIndex: [String: [String]])
    {
        let classifier = VariantClassifier.shared
        let curated = Dictionary(uniqueKeysWithValues:
            SeedCharacters.curated.map { ($0.char, $0) })

        var entries: [SearchEntry] = []
        entries.reserveCapacity(MMAStore.shared.dictionary.count)

        // While we're iterating, also map each component → the canonical
        // hanzi that contain it, so the detail view can answer
        // "what else uses 月?" in O(1).
        var componentSets: [String: [String]] = [:]

        for (char, dictEntry) in MMAStore.shared.dictionary {
            guard Self.isHanzi(char) else { continue }
            let canonical = classifier.canonical(char)
            // Pull all readings (MMA can have multiple) plus any curated one
            // so tone-sensitive search ("shī") and plain search ("shi") both
            // work without losing matches.
            var readings: [String] = []
            if let p = curated[canonical]?.pinyin, !p.isEmpty { readings.append(p) }
            readings.append(contentsOf: dictEntry.pinyin)
            let joined = readings.joined(separator: " ").lowercased()
            let meaning = curated[canonical]?.meaning ?? dictEntry.definition ?? ""
            entries.append(SearchEntry(
                canonicalID: canonical,
                char: char,
                pinyinToneless: joined.toneStripped,
                pinyinLower: joined,
                meaningLower: meaning.lowercased()
            ))

            for component in Decomposition.components(in: dictEntry.decomposition,
                                                     excluding: char) {
                componentSets[component, default: []].append(canonical)
            }
        }
        // De-dup each component bucket (different MMA char keys can map to
        // the same canonical) while preserving order.
        for (k, v) in componentSets {
            var seen = Set<String>(); var ordered: [String] = []
            for c in v where seen.insert(c).inserted { ordered.append(c) }
            componentSets[k] = ordered
        }
        return (entries, curated, componentSets)
    }

    nonisolated static func isHanzi(_ s: String) -> Bool {
        guard let scalar = s.unicodeScalars.first else { return false }
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF)
    }

    // MARK: - Synthesis

    /// Build (and cache) a fully-populated `HanziCharacter`. The input can
    /// be either a simplified or traditional form — we always store and
    /// return the canonical (Simplified) form as `canonicalID`, and we
    /// translate `char` to the active variant for display.
    func character(for input: String) -> HanziCharacter? {
        let classifier = VariantClassifier.shared
        let canonical = classifier.canonical(input)
        let displayed = classifier.displayed(canonical, in: variant)

        if let cached = synthCache[canonical] { return cached }

        // Curated metadata (HSK, mnemonic, examples) is keyed by canonical.
        let curated = curatedMap[canonical]
        // MMA stroke / pinyin lookups happen under the *displayed* form so
        // the strokes match what's on screen. Fall back to canonical if
        // the displayed form isn't in MMA (rare).
        let mma = MMAStore.shared.dictionary[displayed]
            ?? MMAStore.shared.dictionary[canonical]
        guard curated != nil || mma != nil else { return nil }

        let pinyinTone = curated?.pinyin ?? mma?.pinyin.first ?? ""
        // Meaning resolution order:
        //   1. SeedCharacters curated overlay (rich hand-written rows)
        //   2. MeaningOverrides table — small curated patch for chars
        //      where chinese-lexicon picked an etymologically correct
        //      but classroom-rare sense (周 → "to circle" should be
        //      "week, cycle"; 着 → "to touch" should mention the verb
        //      suffix usage students actually meet first).
        //   3. chinese-lexicon `short` — learner-friendly default for
        //      ~10k chars (better than MMA's Classical glosses).
        //   4. MMA `definition` — final fallback for rare hanzi.
        let lexiconEntry = SingleCharDefinitions.shared.entry(for: canonical)
            ?? SingleCharDefinitions.shared.entry(for: displayed)
        let meaning = curated?.meaning
            ?? MeaningOverrides.meaning(for: canonical)
            ?? MeaningOverrides.meaning(for: displayed)
            ?? lexiconEntry?.short
            ?? mma?.definition
            ?? ""
        // Multi-reading display string. The lexicon stores readings
        // semicolon-separated ("dé; děi; de"); we surface them with a
        // slash divider in the UI so chars like 得 / 行 / 着 show every
        // valid pronunciation in the detail header instead of just
        // their primary one.
        let pinyinAllReadings: String = {
            guard let readings = lexiconEntry?.pinyinReadings, !readings.isEmpty else {
                return pinyinTone
            }
            let parts = readings.split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            return parts.isEmpty ? pinyinTone : parts.joined(separator: " / ")
        }()

        let radical: RelatedCharacter? = curated?.radical
            ?? mma?.radical.map { RelatedCharacter(char: $0, label: "Radical") }

        let strokeCount = MMAStore.shared.strokeCount(for: displayed)

        let etymology = makeEtymology(canonical: canonical, mma: mma)
        // Prefer the curated HSK level when present, otherwise fall back to
        // the official-list lookup. Try both forms in case the user is in
        // Traditional mode and the HSK file is keyed by Simplified.
        let hskLevel: Int = {
            if let c = curated, c.hskLevel > 0 { return c.hskLevel }
            let table = HSKLevels.shared
            let viaCanonical = table.level(for: canonical)
            if viaCanonical > 0 { return viaCanonical }
            return table.level(for: displayed)
        }()

        let synthesised = HanziCharacter(
            canonicalID: canonical,
            char: displayed,
            pinyin: pinyinTone,
            pinyinToneless: pinyinTone.toneStripped,
            pinyinAllReadings: pinyinAllReadings,
            meaning: meaning,
            hskLevel: hskLevel,
            strokeCount: strokeCount,
            radical: radical,
            variant: curated?.variant,
            structure: curated?.structure,
            examples: curated?.examples ?? [],
            mnemonic: curated?.mnemonic,
            tags: curated?.tags ?? [],
            etymology: etymology
        )
        synthCache[canonical] = synthesised
        return synthesised
    }

    /// Build an `Etymology` from MMA's `etymology` payload + the IDS
    /// decomposition. Returns nil when MMA tells us nothing useful.
    private func makeEtymology(canonical: String,
                               mma: MMADictionaryEntry?) -> Etymology? {
        guard let mma else { return nil }
        let type = HanziType.fromMMA(mma.etymologyType)
        let phonetic = mma.phoneticComponent
        let semantic = mma.semanticComponent
        // Skip any component reference that points back at the host
        // character itself — both the canonical (simplified) key and the
        // MMA-resolved (possibly traditional) form. Otherwise primitive
        // chars like 用 / 月 / 心 self-reference because MMA either lists
        // them as their own semantic component or the IDS contains them.
        let isSelf: (String) -> Bool = { c in
            c == mma.character || c == canonical
        }
        let parts = Decomposition.components(in: mma.decomposition,
                                             excluding: mma.character)
            .filter { !isSelf($0) }

        var components: [EtymologyComponent] = []
        var consumed = Set<String>()

        // For phono-semantic compounds the semantic + phonetic come first.
        if type == .phonosemantic {
            if let s = semantic, !isSelf(s) {
                components.append(.init(char: s, role: .semantic))
                consumed.insert(s)
            }
            if let p = phonetic, !isSelf(p) {
                components.append(.init(char: p,
                                        role: phonetic == semantic ? .both : .phonetic))
                consumed.insert(p)
            }
        }

        // Then any remaining IDS leaves as generic parts.
        for c in parts where !consumed.contains(c) {
            components.append(.init(char: c, role: .component))
        }

        // No info at all → bail out.
        if components.isEmpty && mma.etymologyHint == nil { return nil }
        return Etymology(type: type,
                         components: components,
                         hint: mma.etymologyHint)
    }

    // MARK: - Component co-occurrence

    /// Other canonical hanzi that contain `component`, ordered so that
    /// (1) characters in `prioritise` come first (e.g. the user's SRS deck)
    /// then (2) the rest in their natural insertion order. The host
    /// character itself is filtered out.
    func charactersSharing(component: String,
                           excluding host: String? = nil,
                           prioritise: Set<String> = [],
                           limit: Int = 12) -> [HanziCharacter] {
        let bucket = componentIndex[component] ?? []
        let filtered = bucket.filter { $0 != host }
        let pinned = filtered.filter { prioritise.contains($0) }
        let rest   = filtered.filter { !prioritise.contains($0) }
        return Array((pinned + rest).prefix(limit))
            .compactMap { character(for: $0) }
    }

    func characters(for ids: [String]) -> [HanziCharacter] {
        ids.compactMap { character(for: $0) }
    }

    // MARK: - Search

    enum SearchMode { case auto, hanzi, pinyin, english }

    func search(_ query: String, mode: SearchMode = .auto, limit: Int = 60) -> [HanziCharacter] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }

        let effective: SearchMode = {
            if mode != .auto { return mode }
            if q.unicodeScalars.contains(where: { ($0.value >= 0x4E00 && $0.value <= 0x9FFF) ||
                                                  ($0.value >= 0x3400 && $0.value <= 0x4DBF) }) {
                return .hanzi
            }
            return .pinyin
        }()

        // Detect tone marks: if the user typed "shī" they want that exact
        // tone; if they typed "shi" they want any tone.
        let queryHasTone = q.contains { hasToneMark($0) }

        var hits: [(String, Int)] = []
        hits.reserveCapacity(min(searchIndex.count, limit * 4))

        let activeIDs = filteredIDs
        for entry in searchIndex {
            if !activeIDs.contains(entry.char) { continue }
            let score: Int?
            switch effective {
            case .hanzi:
                if entry.char == q { score = 100 }
                else if entry.char.contains(q) { score = 80 }
                else { score = nil }
            case .pinyin:
                // Compare against either the toned or the toneless field so
                // "shī" only matches first-tone shi readings, while "shi"
                // matches all four tones. Pinyin mode is strictly pinyin —
                // typing "beautiful" while in Pinyin mode should return
                // nothing (no fallback to English meaning), otherwise the
                // mode picker is useless.
                let haystack = queryHasTone ? entry.pinyinLower : entry.pinyinToneless
                if pinyinExactWordMatch(haystack: haystack, needle: q) { score = 95 }
                else if pinyinPrefixWordMatch(haystack: haystack, needle: q) { score = 70 }
                else if haystack.contains(q) { score = 50 }
                else { score = nil }
            case .english:
                // Quick reject first — only run the relatively expensive
                // tokenising rank pass when the entry could *possibly*
                // match. 99% of the 10k entries fail this check on a
                // typical query.
                guard entry.meaningLower.contains(q) else { score = nil; break }
                score = englishMatchScore(meaning: entry.meaningLower,
                                          query: q)
            case .auto:
                score = nil
            }
            if let s = score {
                hits.append((entry.canonicalID, s))
                if hits.count > limit * 4 { break }
            }
        }

        // Sort, dedupe by canonical id (so 学/學 don't both surface), then
        // synthesise.
        var seen = Set<String>()
        let sorted = hits.sorted { $0.1 > $1.1 }
        var result: [HanziCharacter] = []
        for (id, _) in sorted {
            if seen.insert(id).inserted, let c = character(for: id) {
                result.append(c)
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// True when the haystack contains `needle` as a whole space-delimited
    /// token. Pinyin fields are joined by spaces so this matches the
    /// individual readings rather than substrings inside other readings.
    private func pinyinExactWordMatch(haystack: String, needle: String) -> Bool {
        for token in haystack.split(separator: " ") where token == needle[...] {
            return true
        }
        return false
    }

    private func pinyinPrefixWordMatch(haystack: String, needle: String) -> Bool {
        for token in haystack.split(separator: " ")
            where token.hasPrefix(needle) { return true }
        return false
    }

    /// Score an English search hit. Higher is more relevant.
    /// The meaning text is split into individual definitions by `,;()/` so
    /// "to eat, to consume" produces two pieces, each scored separately
    /// against the query. A definition that *equals* the query (or is the
    /// query prefixed by "to ") gets the top score; a whole-word match
    /// within a short definition outranks a substring match in a long one;
    /// pure-substring matches (e.g. "eat" inside "great") get the lowest
    /// score so they don't crowd out direct matches.
    private func englishMatchScore(meaning: String, query: String) -> Int? {
        let definitions = meaning
            .split(whereSeparator: { ",;()/[]".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var best: Int = 0
        for def in definitions {
            if def == query || def == "to \(query)" {
                return 1000   // perfect: this character's definition *is* the query
            }
            // Tokenise the definition into words; whole-word match is what
            // distinguishes the canonical character from coincidental hits.
            let words = def.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { String($0) }
            if words.contains(query) {
                // Shorter definitions score higher — "eat" alone is more
                // canonical than "eat (a small bite of something)".
                let score = 600 - min(300, def.count * 4)
                if score > best { best = score }
            } else if def.hasPrefix(query + " ") {
                if 400 > best { best = 400 }
            } else if def.contains(query) {
                if 100 > best { best = 100 }
            }
        }
        if best == 0 {
            return meaning.contains(query) ? 20 : nil
        }
        return best
    }

    // MARK: - Curated convenience views

    var trending: [HanziCharacter] {
        // Seed characters are keyed by their Simplified canonical id; we
        // ask `character(for:)` to render them in the active variant so the
        // Traditional user sees 學/愛 instead of an empty grid.
        //
        // Pool composition (broadest first, so rotation has somewhere to
        // go — the previous version pulled only `trending`-tagged seeds
        // and there were just 7 of them, so the daily shuffle produced
        // the same 7 forever):
        //   1. Curated chars tagged `trending` (top priority, always appear
        //      more often via duplication-in-pool).
        //   2. Curated chars tagged `common` — anything teachable we've
        //      hand-written examples for.
        //   3. HSK 1 + HSK 2 characters from the bundled HSK index, so
        //      learners always see beginner-friendly hanzi even when the
        //      curated pool is exhausted.
        // Deduped by canonical id, then shuffled by day-of-year so the
        // user gets a fresh-feeling daily set deterministically.
        var pool: [HanziCharacter] = []
        var seen = Set<String>()
        // Curated, prioritised by tag.
        let curatedTrending = SeedCharacters.curated
            .filter { $0.tags.contains("trending") }
        let curatedCommon = SeedCharacters.curated
            .filter { $0.tags.contains("common") && !$0.tags.contains("trending") }
        for seed in curatedTrending + curatedCommon {
            guard let c = character(for: seed.char),
                  seen.insert(c.canonicalID).inserted else { continue }
            pool.append(c)
        }
        // HSK 1-2 fill so even users who've seen every curated tile keep
        // discovering new ones across rotations.
        let table = HSKLevels.shared
        for level in 1...2 {
            for id in table.byLevel[level] ?? [] {
                guard let c = character(for: id),
                      seen.insert(c.canonicalID).inserted else { continue }
                pool.append(c)
            }
        }
        guard pool.count > 12 else { return pool }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: .now) ?? 1
        var generator = SeededGenerator(seed: UInt64(day))
        let shuffled = pool.shuffled(using: &generator)
        return Array(shuffled.prefix(12))
    }

    /// Every HSK level (1–6) with all of the characters at that level,
    /// translated for the active variant and deduped by canonical id.
    /// Memoised per active variant — cheap enough on cold cache (~5–10 ms)
    /// to defer building until first access.
    var byHSK: [(level: Int, characters: [HanziCharacter])] {
        if let cached = byHSKCache { return cached }
        let activeIDs = filteredIDs
        let classifier = VariantClassifier.shared
        let table = HSKLevels.shared
        var groups: [Int: [HanziCharacter]] = [:]
        var seenIDs: [Int: Set<String>] = [:]
        for level in 1...HSKLevels.maxLevel {
            let ids = table.byLevel[level] ?? []
            for id in ids {
                // Some HSK chars only exist in MMA in their traditional
                // form (and vice versa). Filter to the active set so we
                // don't emit unsupported entries.
                let canonical = classifier.canonical(id)
                let displayed = classifier.displayed(canonical, in: variant)
                guard activeIDs.contains(displayed) || activeIDs.contains(canonical) else { continue }
                guard let c = character(for: canonical) else { continue }
                if seenIDs[level, default: []].insert(c.canonicalID).inserted {
                    groups[level, default: []].append(c)
                }
            }
        }
        let result = groups.keys.sorted().map { lvl in
            (lvl, groups[lvl]!.sorted { $0.strokeCount < $1.strokeCount })
        }
        byHSKCache = result
        return result
    }

    /// Pool of canonical (Simplified) ids used to seed random / new sessions.
    /// Filtered to the active writing system so suggestions match the user's
    /// chosen variant, deduped so 学 and 學 don't both appear.
    var allCharacterIDs: [String] {
        let activeIDs = filteredIDs
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(searchIndex.count)
        for entry in searchIndex where activeIDs.contains(entry.char) {
            if seen.insert(entry.canonicalID).inserted {
                out.append(entry.canonicalID)
            }
        }
        return out
    }

    /// Canonical IDs from the bundled official **HSK 2012** character lists,
    /// levels `1…maxLevel` inclusive. Used so beginners aren't thrown rare
    /// dictionary-only hanzi during Character of the Day or fallback sessions.
    func officialHSKCanonicalIDs(upThrough maxLevel: Int) -> [String] {
        let cap = max(1, min(6, maxLevel))
        let classifier = VariantClassifier.shared
        let activeIDs = filteredIDs
        let table = HSKLevels.shared
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(2800)
        for level in 1...cap {
            for id in table.byLevel[level] ?? [] {
                let canonical = classifier.canonical(id)
                guard seen.insert(canonical).inserted else { continue }
                let displayed = classifier.displayed(canonical, in: variant)
                guard activeIDs.contains(displayed) || activeIDs.contains(canonical) else { continue }
                guard character(for: canonical) != nil else { continue }
                out.append(canonical)
            }
        }
        return out
    }
}

// MARK: - Tone-mark detection

private nonisolated let pinyinToneMarks: Set<Character> = [
    "ā","á","ǎ","à",
    "ē","é","ě","è",
    "ī","í","ǐ","ì",
    "ō","ó","ǒ","ò",
    "ū","ú","ǔ","ù",
    "ǖ","ǘ","ǚ","ǜ","ü",
    "ñ"
]

private nonisolated func hasToneMark(_ ch: Character) -> Bool {
    pinyinToneMarks.contains(ch)
}

// MARK: - Tone-stripped pinyin

extension String {
    nonisolated var toneStripped: String {
        // Cheap fast path — most strings don't contain any tone marks.
        var hasTone = false
        for ch in self where toneMap[ch] != nil { hasTone = true; break }
        if !hasTone { return self.lowercased() }
        var out = String()
        out.reserveCapacity(count)
        for ch in self { out.append(toneMap[ch] ?? ch) }
        return out.lowercased()
    }
}

nonisolated private let toneMap: [Character: Character] = [
    "ā": "a", "á": "a", "ǎ": "a", "à": "a",
    "ē": "e", "é": "e", "ě": "e", "è": "e",
    "ī": "i", "í": "i", "ǐ": "i", "ì": "i",
    "ō": "o", "ó": "o", "ǒ": "o", "ò": "o",
    "ū": "u", "ú": "u", "ǔ": "u", "ù": "u",
    "ǖ": "u", "ǘ": "u", "ǚ": "u", "ǜ": "u", "ü": "u",
    "ñ": "n"
]

/// Tiny deterministic PRNG so daily picks (trending, character of the day)
/// stay stable across multiple opens within the same day. SplitMix64 — small,
/// no dependencies, well-distributed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Fold 0 → a non-zero value to keep the generator from getting stuck.
        self.state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
