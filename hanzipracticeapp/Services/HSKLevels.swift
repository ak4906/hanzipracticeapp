//
//  HSKLevels.swift
//  hanzipracticeapp
//
//  Per-character minimum HSK level (1-6) derived from the official 2012
//  HSK word lists. A character takes the lowest level at which it first
//  appears (in any word), so 爱 → 1, 情 → 4, etc.
//

import Foundation

nonisolated final class HSKLevels: @unchecked Sendable {

    static let shared = HSKLevels()

    private(set) var levels: [String: Int] = [:]
    private(set) var byLevel: [Int: [String]] = [:]
    private(set) var isLoaded = false

    private init() {}

    func loadIfNeeded() {
        guard !isLoaded else { return }
        guard let url = Bundle.main.url(forResource: "hsk-characters", withExtension: "txt"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            print("HSKLevels: hsk-characters.txt missing")
            isLoaded = true
            return
        }
        var levelMap: [String: Int] = [:]
        var grouped: [Int: [String]] = [:]
        levelMap.reserveCapacity(3000)

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first == "#" { continue }
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let char = String(line[line.startIndex..<tab])
            let rhs = line[line.index(after: tab)...]
            guard let lvl = Int(rhs) else { continue }
            levelMap[char] = lvl
            grouped[lvl, default: []].append(char)
        }
        self.levels = levelMap
        self.byLevel = grouped
        self.isLoaded = true
    }

    func level(for char: String) -> Int {
        levels[char] ?? 0
    }
}
