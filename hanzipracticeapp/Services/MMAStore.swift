//
//  MMAStore.swift
//  hanzipracticeapp
//
//  Loads the bundled Make-Me-a-Hanzi data set:
//
//   • mma-dictionary.txt — small (~2.5MB); fully decoded at launch so search
//                          over pinyin / definition works without touching disk.
//   • mma-graphics.txt   — large (~30MB); indexed at launch (byte offsets per
//                          character), then random-accessed lazily for the
//                          stroke / median data on demand.
//
//  Coordinate notes:
//    Strokes are SVG paths in a 1024×1024 viewbox with the MMA transform
//    `translate(0, 900) scale(1, -1)`. `SVGPath.makePath` already flips them
//    into y-down coordinates that match every other renderer in the app.
//
//    Medians come from MMA in y-UP form (matching the raw SVG numbers). We
//    flip them to y-down at load time so they are directly comparable with
//    user touches in the writing canvas.
//

import Foundation
import SwiftUI

struct MMAGraphics: Sendable {
    let strokes: [Path]
    let medians: [[CGPoint]]
    /// Indices into `strokes` that MMA tags as belonging to the character's
    /// radical. Empty when MMA can't identify a clean radical breakdown.
    let radStrokes: [Int]
}

struct MMADictionaryEntry: Sendable {
    let character: String
    let definition: String?
    let pinyin: [String]
    let radical: String?
    let decomposition: String?
    let etymologyType: String?       // "pictographic", "ideographic", "pictophonetic", "indicative", …
    let etymologyHint: String?       // free-form prose hint
    let phoneticComponent: String?   // present when type == "pictophonetic"
    let semanticComponent: String?   // present when type == "pictophonetic"
}

/// Explicitly `nonisolated` so `loadIfNeeded()` can run on a background task
/// regardless of the project-wide default isolation. After loading,
/// `dictionary` and `graphicsIndex` are immutable so all reads are
/// thread-safe; cache mutations are guarded by `cacheLock`.
nonisolated final class MMAStore: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = MMAStore()

    // MARK: - Public surface

    private(set) var allCharacters: [String] = []
    private(set) var dictionary: [String: MMADictionaryEntry] = [:]

    private var graphicsCache: [String: MMAGraphics] = [:]
    private var graphicsOrder: [String] = []
    private let graphicsCacheLimit = 200
    private let cacheLock = NSLock()

    func hasGraphics(_ character: String) -> Bool {
        graphicsIndex[character] != nil
    }

    func strokeCount(for character: String) -> Int {
        graphics(for: character)?.strokes.count ?? 0
    }

    func graphics(for character: String) -> MMAGraphics? {
        cacheLock.lock()
        if let cached = graphicsCache[character] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let location = graphicsIndex[character],
              let mmap = graphicsBuffer else { return nil }
        let line = mmap.subdata(in: location.offset..<(location.offset + location.length))
        guard let parsed = parseGraphicsLine(line) else { return nil }

        cacheLock.lock()
        graphicsCache[character] = parsed
        graphicsOrder.append(character)
        if graphicsOrder.count > graphicsCacheLimit {
            let evict = graphicsOrder.removeFirst()
            graphicsCache.removeValue(forKey: evict)
        }
        cacheLock.unlock()
        return parsed
    }

    // MARK: - Internal state

    private var graphicsIndex: [String: (offset: Int, length: Int)] = [:]
    private var graphicsBuffer: Data? = nil
    private(set) var isLoaded: Bool = false

    // MARK: - Loading

    private init() {}

    /// Synchronously prepare both indexes. Designed to be called from a
    /// background task — both passes use pointer-level scans rather than
    /// Swift's bounds-checked buffer subscripts.
    func loadIfNeeded() {
        guard !isLoaded else { return }
        let t0 = Date()
        loadDictionary()
        let t1 = Date()
        indexGraphics()
        let t2 = Date()
        var chars: Set<String> = []
        chars.reserveCapacity(dictionary.count + graphicsIndex.count)
        for k in dictionary.keys { chars.insert(k) }
        for k in graphicsIndex.keys { chars.insert(k) }
        self.allCharacters = Array(chars)
        self.isLoaded = true
        print("MMA loaded — dictionary \(Int(t1.timeIntervalSince(t0)*1000))ms, graphics \(Int(t2.timeIntervalSince(t1)*1000))ms")
    }

    // MARK: - Dictionary parse (eager, ~9.5K lines)

    private func loadDictionary() {
        guard let url = Bundle.main.url(forResource: "mma-dictionary", withExtension: "txt"),
              let data = try? Data(contentsOf: url) else {
            print("MMA: dictionary file missing")
            return
        }
        var entries: [String: MMADictionaryEntry] = [:]
        entries.reserveCapacity(10_000)

        let count = data.count
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var lineStart = 0
            for i in 0..<count {
                if base[i] == 0x0A {                                  // newline
                    let len = i - lineStart
                    if len > 0 {
                        // Use bytesNoCopy: JSONSerialization is sync and
                        // returns objects with their own backing storage,
                        // so the no-copy buffer is safe for this call.
                        let slice = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base.advanced(by: lineStart)),
                                         count: len,
                                         deallocator: .none)
                        if let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any],
                           let character = obj["character"] as? String {
                            let etymology = obj["etymology"] as? [String: Any]
                            let entry = MMADictionaryEntry(
                                character: character,
                                definition: obj["definition"] as? String,
                                pinyin: (obj["pinyin"] as? [String]) ?? [],
                                radical: obj["radical"] as? String,
                                decomposition: obj["decomposition"] as? String,
                                etymologyType: etymology?["type"] as? String,
                                etymologyHint: etymology?["hint"] as? String,
                                phoneticComponent: etymology?["phonetic"] as? String,
                                semanticComponent: etymology?["semantic"] as? String
                            )
                            entries[character] = entry
                        }
                    }
                    lineStart = i + 1
                }
            }
        }
        self.dictionary = entries
    }

    // MARK: - Graphics offset index (lazy parse later)

    private func indexGraphics() {
        guard let url = Bundle.main.url(forResource: "mma-graphics", withExtension: "txt"),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            print("MMA: graphics file missing")
            return
        }
        self.graphicsBuffer = data

        var index: [String: (offset: Int, length: Int)] = [:]
        index.reserveCapacity(10_000)

        let count = data.count
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var lineStart = 0
            for i in 0..<count {
                if base[i] == 0x0A {
                    let len = i - lineStart
                    if len > 0, let charValue = extractCharacter(bytes: base, start: lineStart, end: i) {
                        index[charValue] = (offset: lineStart, length: len)
                    }
                    lineStart = i + 1
                }
            }
            if lineStart < count,
               let charValue = extractCharacter(bytes: base, start: lineStart, end: count) {
                index[charValue] = (offset: lineStart, length: count - lineStart)
            }
        }
        self.graphicsIndex = index
    }

    /// MMA lines always start with `{"character":"X"` — the character payload
    /// begins at byte offset 14.
    private func extractCharacter(bytes: UnsafePointer<UInt8>, start: Int, end: Int) -> String? {
        let prefixLen = 14
        guard end - start > prefixLen + 1 else { return nil }
        let quote: UInt8 = 0x22
        var i = start + prefixLen
        let maxLen = 8
        while i < end {
            if bytes[i] == quote { break }
            i += 1
            if i - (start + prefixLen) > maxLen { return nil }
        }
        let len = i - (start + prefixLen)
        guard len > 0, len <= maxLen else { return nil }
        // Copy out so the resulting String doesn't reference the closure-only
        // pointer once `withUnsafeBytes` returns.
        let buf = UnsafeBufferPointer(start: bytes.advanced(by: start + prefixLen),
                                      count: len)
        return String(decoding: buf, as: UTF8.self)
    }

    // MARK: - Per-character graphics parse (lazy)

    private struct GraphicsRecord: Decodable {
        let character: String
        let strokes: [String]
        let medians: [[[Double]]]
    }

    private func parseGraphicsLine(_ line: Data) -> MMAGraphics? {
        // JSONSerialization is much faster than JSONDecoder here. Each
        // character has only a few strokes / medians so per-element manual
        // casting is fine.
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let strokeStrings = obj["strokes"] as? [String],
              let medianArrays = obj["medians"] as? [[[Any]]]
        else { return nil }

        let strokes = strokeStrings.map { SVGPath.makePath($0) }
        let medians: [[CGPoint]] = medianArrays.map { stroke -> [CGPoint] in
            stroke.compactMap { pair -> CGPoint? in
                guard pair.count >= 2,
                      let x = (pair[0] as? Double) ?? (pair[0] as? Int).map(Double.init),
                      let y = (pair[1] as? Double) ?? (pair[1] as? Int).map(Double.init)
                else { return nil }
                return CGPoint(x: x, y: 900 - y)       // flip y to y-down
            }
        }
        // `radStrokes` is an optional `[Int]` in the MMA dataset; absent
        // when the radical isn't a clean subset of the strokes.
        let radStrokes: [Int]
        if let rs = obj["radStrokes"] as? [Int] {
            radStrokes = rs
        } else if let rs = obj["radStrokes"] as? [NSNumber] {
            radStrokes = rs.map(\.intValue)
        } else {
            radStrokes = []
        }
        return MMAGraphics(strokes: strokes, medians: medians, radStrokes: radStrokes)
    }
}
