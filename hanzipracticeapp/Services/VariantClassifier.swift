//
//  VariantClassifier.swift
//  hanzipracticeapp
//
//  Maps Chinese characters between Simplified (简体) and Traditional (繁體)
//  forms and decides which set a character belongs to, using the bundled
//  OpenCC dictionaries.
//
//  We treat **the simplified form** as the canonical key for all user data
//  (SRS cards, vocab lists, recents). When the user is in Traditional mode
//  we *translate the display* — we never duplicate progress across variants.
//

import Foundation

enum ChineseVariant: String, Sendable, Codable, CaseIterable {
    case simplified
    case traditional

    var displayName: String {
        switch self {
        case .simplified: "Simplified (简体)"
        case .traditional: "Traditional (繁體)"
        }
    }

    var shortName: String {
        switch self {
        case .simplified: "简"
        case .traditional: "繁"
        }
    }
}

nonisolated final class VariantClassifier: @unchecked Sendable {

    static let shared = VariantClassifier()

    /// Map from a simplified character → its preferred traditional form.
    private(set) var simpToTrad: [String: String] = [:]
    /// Map from a traditional character → its preferred simplified form.
    private(set) var tradToSimp: [String: String] = [:]

    /// Set of *keys* in opencc-st.txt (i.e. characters that have a different
    /// traditional form).
    private(set) var simplifiedKeys: Set<String> = []
    /// Set of *keys* in opencc-ts.txt (i.e. characters that have a different
    /// simplified form).
    private(set) var traditionalKeys: Set<String> = []

    private(set) var isLoaded: Bool = false

    private init() {}

    func loadIfNeeded() {
        guard !isLoaded else { return }
        (simpToTrad, simplifiedKeys) = loadMapping(named: "opencc-st")
        (tradToSimp, traditionalKeys) = loadMapping(named: "opencc-ts")
        isLoaded = true
    }

    // MARK: - Classification ("would this character appear in the active set?")

    /// Should the given character appear when the user has selected `variant`?
    /// Used to filter *discoverable* content (search results, trending,
    /// browse-by-HSK), NOT to filter user-owned lists.
    func includes(_ character: String, in variant: ChineseVariant) -> Bool {
        let isSimpOnly = simplifiedKeys.contains(character) && !traditionalKeys.contains(character)
        let isTradOnly = traditionalKeys.contains(character) && !simplifiedKeys.contains(character)
        switch variant {
        case .simplified:  return !isTradOnly
        case .traditional: return !isSimpOnly
        }
    }

    // MARK: - Translation ("show me the variant the user picked")

    /// Canonical form (Simplified) — used as the stable storage key for
    /// SwiftData rows so that progress survives variant toggles.
    func canonical(_ char: String) -> String {
        tradToSimp[char] ?? char
    }

    /// What the user should *see* for `char` when the app is in `variant`.
    /// Accepts either a simplified or a traditional input.
    func displayed(_ char: String, in variant: ChineseVariant) -> String {
        let simp = tradToSimp[char] ?? char
        switch variant {
        case .simplified:
            return simp
        case .traditional:
            return simpToTrad[simp] ?? char
        }
    }

    // MARK: - File loading

    private func loadMapping(named name: String) -> (map: [String: String], keys: Set<String>) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            print("VariantClassifier: \(name) missing")
            return ([:], [])
        }
        var map: [String: String] = [:]
        var keys: Set<String> = []
        map.reserveCapacity(4500)
        keys.reserveCapacity(4500)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first == "#" { continue }
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let key = String(line[line.startIndex..<tab])
            // The right side is one or more space-separated targets; pick the first.
            let rhs = line[line.index(after: tab)...]
            let firstTarget = rhs.split(separator: " ").first.map(String.init) ?? key
            map[key] = firstTarget
            keys.insert(key)
        }
        return (map, keys)
    }
}
