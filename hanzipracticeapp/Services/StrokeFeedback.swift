//
//  StrokeFeedback.swift
//  hanzipracticeapp
//
//  Per-stroke human-readable critique that goes one step beyond the raw
//  `StrokeResult` accuracy number. Looks at the user's drawn polyline
//  and the MMA median for the same stroke, and produces hints like
//  "make this stroke a little shorter", "shifted left", or — most
//  importantly — "don't forget the hook on this stroke" when the
//  template ends with a hook but the user drew a straight line.
//
//  Used by the grading sheet to surface coaching tips alongside the
//  per-stroke checkmarks. Pure geometry; no SwiftUI / SwiftData.
//

import CoreGraphics
import Foundation

/// Approximate classification of a stroke based on the geometry of
/// its median path. Maps to the names a learner would recognise from
/// a beginner stroke chart (横 / 竖 / 点 / 撇 / 捺 + the hook family).
enum StrokeShape: String, Hashable {
    case horizontal           // 横 héng
    case vertical             // 竖 shù
    case dot                  // 点 diǎn
    case fallingLeft          // 撇 piě (top-right → bottom-left)
    case fallingRight         // 捺 nà (top-left → bottom-right)
    case verticalHook         // 竖钩 shù gōu (亅)
    case horizontalHook       // 横钩 héng gōu (乛)
    case slantedHook          // 斜钩 xié gōu (㇂)
    case lyingHook            // 卧钩 wò gōu (㇃)
    case horizontalTurnVerticalHook // 横折钩 héng zhé gōu (𠃌)
    case turn                 // generic 折 — sharp angle, no hook
    case curve                // catch-all curved stroke
    case other

    /// Display name including the Chinese term so the feedback line
    /// has the proper stroke vocabulary the user is learning. Stays
    /// short enough to fit on a chip line.
    var displayName: String {
        switch self {
        case .horizontal:                  return "Horizontal (横)"
        case .vertical:                    return "Vertical (竖)"
        case .dot:                         return "Dot (点)"
        case .fallingLeft:                 return "Left-falling (撇)"
        case .fallingRight:                return "Right-falling (捺)"
        case .verticalHook:                return "Vertical hook (竖钩)"
        case .horizontalHook:              return "Horizontal hook (横钩)"
        case .slantedHook:                 return "Slanted hook (斜钩)"
        case .lyingHook:                   return "Lying hook (卧钩)"
        case .horizontalTurnVerticalHook:  return "Horizontal-turn hook (横折钩)"
        case .turn:                        return "Turn (折)"
        case .curve:                       return "Curve"
        case .other:                       return "Stroke"
        }
    }

    var isHook: Bool {
        switch self {
        case .verticalHook, .horizontalHook, .slantedHook,
             .lyingHook, .horizontalTurnVerticalHook:
            return true
        default:
            return false
        }
    }
}

/// A single coaching note for one stroke of a character. The grading
/// sheet renders these as bullet hints; absent issues mean the
/// stroke matched well enough that there's nothing to say.
struct StrokeFeedback: Identifiable, Hashable {
    enum Tip: Hashable {
        case shorter            // user stroke much longer than template
        case longer             // user stroke much shorter than template
        case shiftedLeft
        case shiftedRight
        case shiftedUp
        case shiftedDown
        case missingHook        // template ends with a hook, user's didn't
        case extraneousHook     // user added a hook the template didn't have
        case wrongDirection     // user drew the stroke backwards
    }

    let id = UUID()
    let strokeIndex: Int        // 0-based — display as +1
    let shape: StrokeShape
    /// Single most-impactful note for this stroke. The analyzer
    /// internally collects every candidate issue and then keeps just
    /// the highest-priority one — listing every detected nit at once
    /// (length + offset + hook) buries the actually important
    /// feedback in noise.
    let tip: Tip
}

enum StrokeFeedbackAnalyzer {

    /// Standard sample count — the same one StrokeJudge uses so both
    /// analyses agree on point counts after resampling.
    private static let sampleCount: Int = 32

    /// Build a feedback record for one stroke. Returns nil when the
    /// stroke is clean enough that we have nothing actionable to say
    /// (no severe length/offset gap, hook matches, drawn in the
    /// right direction) — better to stay silent than nag.
    ///
    /// When multiple issues are present we keep only the **one
    /// highest-priority** signal. Priority order (most-impactful
    /// first): wrongDirection → missingHook → extraneousHook →
    /// large length gap → large position offset → small length gap
    /// → small position offset. The chip then reads as a single
    /// pointed note instead of a checklist.
    static func analyze(strokeIndex: Int,
                        userPoints: [CGPoint],
                        median: [CGPoint]) -> StrokeFeedback? {
        guard userPoints.count >= 2, median.count >= 2 else { return nil }
        let user = Geometry.resample(userPoints, count: sampleCount)
        let model = Geometry.resample(median, count: sampleCount)
        let shape = classify(median: model)

        // 1) Direction (highest priority — a backwards stroke is a
        //    fundamental error that everything else is downstream of).
        let userDir = Geometry.direction(user)
        let modelDir = Geometry.direction(model)
        let dot = userDir.dx * modelDir.dx + userDir.dy * modelDir.dy
        let reversed = dot < -0.4
        if reversed {
            return StrokeFeedback(strokeIndex: strokeIndex,
                                  shape: shape, tip: .wrongDirection)
        }

        // 2) Hook check (next priority — missing a hook changes the
        //    stroke's identity).
        let templateHasHook = endsWithSharpTurn(model)
        let userHasHook = endsWithSharpTurn(user)
        if templateHasHook && !userHasHook {
            return StrokeFeedback(strokeIndex: strokeIndex,
                                  shape: shape, tip: .missingHook)
        }
        if !templateHasHook && userHasHook && shape != .dot {
            return StrokeFeedback(strokeIndex: strokeIndex,
                                  shape: shape, tip: .extraneousHook)
        }

        // 3) Length gap — only flag *significant* mismatch (>40%) so
        //    the chip doesn't fire on micro-variations.
        let userLen = Geometry.polylineLength(user)
        let modelLen = Geometry.polylineLength(model)
        let ratio = modelLen == 0 ? 1 : userLen / modelLen
        let lengthSeverity = abs(1 - ratio)

        // 4) Position offset (centroid distance, normalised to 0…1
        //    canvas coords). Anything <8% is too noisy to mention.
        let userCenter = centroid(user)
        let modelCenter = centroid(model)
        let dx = userCenter.x - modelCenter.x
        let dy = userCenter.y - modelCenter.y
        let offsetMag = sqrt(Double(dx * dx + dy * dy))

        // Pick the worst of length vs offset and emit only that.
        // Thresholds chosen so we stay silent on average strokes
        // and only call out the worst single problem.
        let lengthBig = lengthSeverity > 0.4
        let offsetBig: Bool = offsetMag > 0.10
        if !lengthBig && !offsetBig { return nil }

        let lengthScore = lengthSeverity       // 0…∞
        let offsetScore = offsetMag * 4        // scale to compare
        if lengthScore >= offsetScore {
            let tip: StrokeFeedback.Tip = ratio > 1 ? .shorter : .longer
            return StrokeFeedback(strokeIndex: strokeIndex,
                                  shape: shape, tip: tip)
        }
        let tip: StrokeFeedback.Tip = {
            if abs(dx) > abs(dy) {
                return dx < 0 ? .shiftedLeft : .shiftedRight
            } else {
                return dy < 0 ? .shiftedUp : .shiftedDown
            }
        }()
        return StrokeFeedback(strokeIndex: strokeIndex,
                              shape: shape, tip: tip)
    }

    /// Convert a tip into the prose hint the user sees, parameterised
    /// by the stroke's shape so we can say "don't forget the hook on
    /// this 竖钩" rather than just "missing hook".
    static func describe(_ tip: StrokeFeedback.Tip,
                         shape: StrokeShape) -> String {
        switch tip {
        case .shorter:
            return "Make this stroke a little shorter."
        case .longer:
            return "Make this stroke a little longer."
        case .shiftedLeft:
            return "Shifted left — nudge it right next time."
        case .shiftedRight:
            return "Shifted right — nudge it left next time."
        case .shiftedUp:
            return "Drawn too high — pull it down a bit."
        case .shiftedDown:
            return "Drawn too low — lift it up a bit."
        case .wrongDirection:
            return "Stroke was drawn in the wrong direction."
        case .missingHook:
            if shape.isHook {
                return "Don't forget the hook — this is a \(shape.displayName)."
            }
            return "Don't forget the hook at the end of this stroke."
        case .extraneousHook:
            return "No hook on this one — just a clean \(shape.displayName.lowercased())."
        }
    }

    // MARK: - Geometry helpers

    /// Detect a sharp directional change in the last ~25% of a
    /// resampled polyline — the geometric signature of a hook. We
    /// compare the average direction of segment [60%, 80%] with
    /// [80%, 100%]; if the angle between them exceeds ~55° AND the
    /// final segment is short (which a hook always is), it's a hook.
    private static func endsWithSharpTurn(_ points: [CGPoint]) -> Bool {
        guard points.count >= 8 else { return false }
        let n = points.count
        let aStart = Int(Double(n) * 0.60)
        let aEnd   = Int(Double(n) * 0.80)
        let bStart = aEnd
        let bEnd   = n - 1
        guard aEnd > aStart, bEnd > bStart else { return false }
        let dirA = directionVector(points, from: aStart, to: aEnd)
        let dirB = directionVector(points, from: bStart, to: bEnd)
        let len = magnitude(dirA) * magnitude(dirB)
        guard len > 1e-6 else { return false }
        let dot = (dirA.dx * dirB.dx + dirA.dy * dirB.dy) / len
        // dot < cos(55°) ≈ 0.57 ⇒ angle > 55° — counts as a sharp turn.
        guard dot < 0.57 else { return false }
        // Hook tail must be short relative to the body — guards
        // against false positives on smoothly-curving strokes.
        let bodyLen = polylineLength(points, from: 0, to: bStart)
        let tailLen = polylineLength(points, from: bStart, to: bEnd)
        guard bodyLen > 0 else { return false }
        return tailLen < bodyLen * 0.45
    }

    /// Lightweight stroke-shape classifier. Looks at the median's
    /// overall direction + sharp-turn signature. Not exhaustive — we
    /// only label things we're going to *say* in the feedback line.
    private static func classify(median model: [CGPoint]) -> StrokeShape {
        let n = model.count
        guard n >= 2 else { return .other }
        let start = model.first!
        let end = model.last!
        let dx = end.x - start.x
        let dy = end.y - start.y
        let bounds = Geometry.bounds(model)
        let extent = max(bounds.width, bounds.height)

        // Dot — basically stationary.
        if extent < 0.06 { return .dot }

        // Sharp turn / hook detection takes priority over straight
        // classification because a 竖钩 is "mostly vertical" but the
        // hook is what we want to surface.
        let hasHook = endsWithSharpTurn(model)
        if hasHook {
            // Decide which hook variant by looking at the dominant
            // direction of the body (before the hook).
            let bodyEnd = Int(Double(n) * 0.80)
            let body = Array(model[0..<bodyEnd])
            guard let bs = body.first, let be = body.last else { return .other }
            let bdx = be.x - bs.x, bdy = be.y - bs.y
            let bodyExtent = max(abs(bdx), abs(bdy))
            if bodyExtent < 0.04 { return .other }
            let horizontal = abs(bdx) > abs(bdy) * 1.5
            let vertical = abs(bdy) > abs(bdx) * 1.5
            // Look for an internal corner (横折钩 has TWO sharp turns —
            // body, then 90° drop, then hook). Detect by checking if
            // the body itself has its own sharp turn.
            if hasInternalSharpTurn(Array(model[0..<bodyEnd])) {
                return .horizontalTurnVerticalHook
            }
            if horizontal { return .horizontalHook }
            if vertical { return .verticalHook }
            // Slanted / lying. Lying hooks curve along the bottom;
            // their start.y ≈ end.y but the middle dips lower.
            let midY = model[n / 2].y
            if midY > max(start.y, end.y) + 0.05 {
                return .lyingHook
            }
            return .slantedHook
        }

        // No hook — classify by direction.
        let horizontal = abs(dx) > abs(dy) * 1.8
        let vertical = abs(dy) > abs(dx) * 1.8
        if horizontal { return .horizontal }
        if vertical { return .vertical }
        // Diagonal falling. In MMA coords y grows downward.
        if dx < 0 && dy > 0 { return .fallingLeft }
        if dx > 0 && dy > 0 { return .fallingRight }
        if hasInternalSharpTurn(model) { return .turn }
        return .curve
    }

    /// Detect a sharp turn somewhere in the middle of the stroke (not
    /// at the end). Used to identify 折 strokes that have a 90°
    /// corner but no hook tail.
    private static func hasInternalSharpTurn(_ points: [CGPoint]) -> Bool {
        guard points.count >= 6 else { return false }
        let n = points.count
        // Slide a 3-segment window across the middle 60% of the
        // stroke; if any window has an angle change > 70°, that's
        // an internal turn.
        let lo = Int(Double(n) * 0.20)
        let hi = Int(Double(n) * 0.80)
        guard hi > lo + 2 else { return false }
        for i in lo..<(hi - 1) {
            let a = directionVector(points, from: max(0, i - 1), to: i)
            let b = directionVector(points, from: i, to: min(n - 1, i + 1))
            let len = magnitude(a) * magnitude(b)
            guard len > 1e-6 else { continue }
            let dot = (a.dx * b.dx + a.dy * b.dy) / len
            // dot < cos(70°) ≈ 0.34
            if dot < 0.34 { return true }
        }
        return false
    }

    private static func directionVector(_ pts: [CGPoint], from i: Int, to j: Int)
        -> CGVector
    {
        guard pts.indices.contains(i), pts.indices.contains(j) else {
            return CGVector(dx: 0, dy: 0)
        }
        return CGVector(dx: pts[j].x - pts[i].x, dy: pts[j].y - pts[i].y)
    }

    private static func magnitude(_ v: CGVector) -> Double {
        Double(sqrt(v.dx * v.dx + v.dy * v.dy))
    }

    private static func centroid(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        let sumX = pts.reduce(0) { $0 + $1.x }
        let sumY = pts.reduce(0) { $0 + $1.y }
        let n = CGFloat(pts.count)
        return CGPoint(x: sumX / n, y: sumY / n)
    }

    private static func polylineLength(_ pts: [CGPoint], from i: Int, to j: Int)
        -> Double
    {
        guard pts.indices.contains(i), pts.indices.contains(j), j > i else {
            return 0
        }
        var len: Double = 0
        for k in i..<j {
            let dx = pts[k + 1].x - pts[k].x
            let dy = pts[k + 1].y - pts[k].y
            len += sqrt(Double(dx * dx + dy * dy))
        }
        return len
    }
}
