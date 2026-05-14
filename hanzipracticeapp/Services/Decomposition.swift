//
//  Decomposition.swift
//  hanzipracticeapp
//
//  Tiny helper for parsing MMA's IDS (Ideographic Description Sequence)
//  strings into the *leaf component* characters that make up a hanzi.
//
//  The IDS operators live in U+2FF0…U+2FFF. Everything else that lands in
//  the CJK Unified Ideographs or CJK Compatibility Ideographs blocks (plus
//  the radical supplement block) is a real component.
//

import Foundation

nonisolated enum Decomposition {

    /// Returns the *unique, ordered* list of leaf component characters
    /// inside `ids`, with the host character itself filtered out.
    nonisolated static func components(in ids: String?, excluding host: String? = nil) -> [String] {
        guard let ids else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for scalar in ids.unicodeScalars {
            if isOperator(scalar) { continue }
            if !isComponent(scalar) { continue }
            let s = String(scalar)
            if let host, s == host { continue }
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }

    /// IDS structural operators (⿰, ⿱, ⿲, ⿳, ⿴, ⿵, ⿶, ⿷, ⿸, ⿹, ⿺, ⿻, …).
    nonisolated private static func isOperator(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x2FF0 && scalar.value <= 0x2FFF
    }

    /// Anything we'd consider a "real" hanzi component.
    nonisolated private static func isComponent(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // CJK Unified Ideographs.
        if v >= 0x4E00 && v <= 0x9FFF { return true }
        // CJK Unified Ideographs Extension A.
        if v >= 0x3400 && v <= 0x4DBF { return true }
        // Kangxi Radicals.
        if v >= 0x2F00 && v <= 0x2FDF { return true }
        // CJK Radicals Supplement.
        if v >= 0x2E80 && v <= 0x2EFF { return true }
        return false
    }
}
