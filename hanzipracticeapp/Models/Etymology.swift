//
//  Etymology.swift
//  hanzipracticeapp
//
//  Per-character etymology: classification, component breakdown with
//  semantic/phonetic role tagging, and the original Make-Me-a-Hanzi hint.
//

import Foundation

enum HanziType: String, Sendable, Hashable, Codable {
    case phonosemantic     // 形声字 — semantic + phonetic
    case pictogram         // 象形字 — stylised drawing
    case compoundIdeogram  // 会意字 — two pictographs combine into a new meaning
    case simpleIdeogram    // 指事字 — abstract symbol for a concept
    case loan              // 假借字 — borrowed for its sound
    case derivative        // 转注字 — derivative cognate
    case unknown

    /// Short English label suitable for badges.
    var displayName: String {
        switch self {
        case .phonosemantic:    "Phono-semantic"
        case .pictogram:        "Pictogram"
        case .compoundIdeogram: "Compound ideogram"
        case .simpleIdeogram:   "Simple ideogram"
        case .loan:             "Loan character"
        case .derivative:       "Derivative cognate"
        case .unknown:          "Composite"
        }
    }

    /// Chinese name (e.g. 形声字) for the badge subtitle.
    var chineseName: String {
        switch self {
        case .phonosemantic:    "形声字"
        case .pictogram:        "象形字"
        case .compoundIdeogram: "会意字"
        case .simpleIdeogram:   "指事字"
        case .loan:             "假借字"
        case .derivative:       "转注字"
        case .unknown:          ""
        }
    }

    /// SF Symbol that hints at the type.
    var systemImage: String {
        switch self {
        case .phonosemantic:    "waveform.path"
        case .pictogram:        "scribble"
        case .compoundIdeogram: "rectangle.connected.to.line.below"
        case .simpleIdeogram:   "circle.dotted"
        case .loan:             "arrow.left.and.right"
        case .derivative:       "arrow.triangle.branch"
        case .unknown:          "puzzlepiece.extension"
        }
    }

    /// Map a raw MMA "type" string to one of our cases.
    static func fromMMA(_ raw: String?) -> HanziType {
        switch raw {
        case "pictophonetic":  return .phonosemantic
        case "pictographic":   return .pictogram
        case "ideographic":    return .compoundIdeogram
        case "indicative":     return .simpleIdeogram
        case "loan":           return .loan
        case "derivative":     return .derivative
        default:               return .unknown
        }
    }
}

/// One component inside a character with its role.
struct EtymologyComponent: Hashable, Sendable {
    enum Role: String, Sendable, Hashable {
        case semantic     // contributes the meaning
        case phonetic     // contributes the sound
        case both         // contributes both
        case component    // generic part (compound ideograms, ideograms)
    }

    let char: String
    let role: Role

    /// Short descriptor shown on the badge above the component tile.
    var roleLabel: String {
        switch role {
        case .semantic:  "Meaning"
        case .phonetic:  "Sound"
        case .both:      "Both"
        case .component: "Part"
        }
    }
}

struct Etymology: Hashable, Sendable {
    let type: HanziType
    /// Components in display order with role tagging.
    let components: [EtymologyComponent]
    /// Free-form prose hint from MMA, e.g.
    /// "A building 冖 where children 子 study; ⺍ provides the pronunciation".
    let hint: String?
}
