//
//  SentenceCorpus.swift
//  hanzipracticeapp
//
//  Bundled Mandarin↔English example-sentence corpus from Tatoeba
//  (CC-BY 2.0 FR · https://tatoeba.org). Used to surface real-usage
//  examples on character and word detail pages.
//
//  Bundled file: `sentences.tsv` — `<chinese>\t<english>\n`, sorted by
//  shortest Chinese first. ~64k pairs, ~4.2 MB. Filtered upstream to
//  cmn sentences 2-40 hanzi long with at least one English translation;
//  duplicates collapsed to the shortest English option.
//
//  Lookup strategy is a per-character inverted index built lazily on
//  first load: for every character, a list of indices into `pairs` that
//  contain it. Word lookups intersect the indices of each constituent
//  character. The index is built off the main actor so app launch isn't
//  blocked.
//

import Foundation

struct SentencePair: Hashable, Identifiable, Sendable {
    let id: Int            // position in the loaded array
    let chinese: String
    let english: String
}

@MainActor
final class SentenceCorpus {

    static let shared = SentenceCorpus()

    private(set) var pairs: [SentencePair] = []
    /// char → indices in `pairs` containing that character. Lazily
    /// extended on first lookup of each char (the upfront cost would
    /// be 30-60 MB; lazy keeps it pay-as-you-go).
    private var charIndex: [Character: [Int]] = [:]
    private(set) var isLoaded: Bool = false

    private init() {}

    func loadIfNeeded() async {
        if isLoaded { return }
        let parsed = await Task.detached(priority: .userInitiated) { () -> [SentencePair] in
            guard let url = Bundle.main.url(forResource: "sentences", withExtension: "tsv"),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                print("SentenceCorpus: sentences.tsv missing")
                return []
            }
            var out: [SentencePair] = []
            out.reserveCapacity(80_000)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: "\t", maxSplits: 1,
                                       omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                out.append(SentencePair(id: out.count,
                                        chinese: String(parts[0]),
                                        english: String(parts[1])))
            }
            return out
        }.value
        self.pairs = parsed
        self.isLoaded = true
        print("SentenceCorpus: loaded \(parsed.count) sentence pairs")
    }

    /// All sentences containing the given single character, ordered
    /// shortest first (which matches the upstream sort). The bucket is
    /// built on first access for each character — lazy keeps startup
    /// cheap.
    private func sentences(containingChar char: Character, limit: Int) -> [SentencePair] {
        if charIndex[char] == nil {
            var bucket: [Int] = []
            for (i, p) in pairs.enumerated() where p.chinese.contains(char) {
                bucket.append(i)
            }
            charIndex[char] = bucket
        }
        let indices = charIndex[char] ?? []
        return Array(indices.prefix(limit).compactMap { pairs.indices.contains($0) ? pairs[$0] : nil })
    }

    /// All sentences containing the given hanzi string. Single-char
    /// queries use the cached per-char inverted index directly;
    /// multi-char queries intersect via the rarest character's bucket so
    /// we don't scan all 64k pairs on every lookup.
    func sentences(containing query: String, limit: Int = 8) -> [SentencePair] {
        guard !query.isEmpty else { return [] }
        if query.count == 1, let ch = query.first {
            return sentences(containingChar: ch, limit: limit)
        }
        // Multi-char: get the smallest per-char bucket and scan it.
        let chars = Array(query)
        let buckets = chars.map { sentences(containingChar: $0, limit: Int.max) }
            .sorted { $0.count < $1.count }
        guard let smallest = buckets.first else { return [] }
        var out: [SentencePair] = []
        for pair in smallest where pair.chinese.contains(query) {
            out.append(pair)
            if out.count >= limit { break }
        }
        return out
    }
}
