//
//  StrokeJudge.swift
//  hanzipracticeapp
//
//  Compares a user-drawn stroke (a series of touch points in canvas space)
//  against the expected stroke median for a hanzi. Returns a per-stroke
//  result and an aggregate score for the whole character.
//

import CoreGraphics
import Foundation

struct StrokeResult: Identifiable, Hashable {
    let id = UUID()
    let strokeIndex: Int
    let accuracy: Double      // 0…1
    let positionError: Double // 0…1, normalised to canvas size
    let directionError: Double // 0…1, 0 = perfect, 1 = opposite direction
    let lengthRatio: Double   // user / expected (1 == matching length)

    var passed: Bool { accuracy >= 0.55 }

    var grade: String {
        switch accuracy {
        case 0.9...: "Excellent"
        case 0.75..<0.9: "Great"
        case 0.55..<0.75: "Good"
        case 0.35..<0.55: "Off"
        default: "Try again"
        }
    }
}

enum StrokeJudge {

    /// Sample count used for both the user's stroke and the expected median.
    private static let sampleCount = 32

    /// Compare the user's drawn polyline against an expected stroke median
    /// (both in the same coordinate space — i.e. canvas-local CGPoints
    /// scaled to the same rect).
    ///
    /// `canvasSize` is the length of the side of the square drawing canvas;
    /// it's used to normalise the position error so the score is independent
    /// of the on-screen size of the canvas.
    static func judge(userStroke raw: [CGPoint],
                      against expected: [CGPoint],
                      canvasSize: CGFloat,
                      strokeIndex: Int) -> StrokeResult {

        guard raw.count >= 2, expected.count >= 2, canvasSize > 0 else {
            return StrokeResult(strokeIndex: strokeIndex,
                                accuracy: 0,
                                positionError: 1,
                                directionError: 1,
                                lengthRatio: 0)
        }

        let user = Geometry.resample(raw, count: sampleCount)
        let model = Geometry.resample(expected, count: sampleCount)

        // 1) Position error — average distance between samples, normalised
        //    by the canvas diagonal so the worst case is ≈ √2.
        let meanDist = Geometry.meanDistance(user, model)
        let normMean = meanDist / Double(canvasSize)
        let positionScore = max(0.0, 1.0 - normMean * 4.5)  // 22% off-center → 0

        // 2) Direction error — dot product of net direction vectors.
        let du = Geometry.direction(user)
        let dm = Geometry.direction(model)
        let dot = du.dx * dm.dx + du.dy * dm.dy
        let directionScore = max(0.0, (dot + 1) / 2)       // map -1…1 → 0…1
        let directionError = 1 - directionScore

        // 3) Length match — user shouldn't drift too short or too long.
        let userLen = Geometry.polylineLength(user)
        let modelLen = Geometry.polylineLength(model)
        let lengthRatio = modelLen == 0 ? 0 : userLen / modelLen
        let lengthScore: Double = {
            let diff = abs(1 - lengthRatio)
            return max(0, 1 - diff)        // 100% off → 0
        }()

        // Weighted blend.
        let accuracy = 0.6 * positionScore + 0.25 * directionScore + 0.15 * lengthScore

        return StrokeResult(strokeIndex: strokeIndex,
                            accuracy: max(0, min(1, accuracy)),
                            positionError: max(0, min(1, normMean)),
                            directionError: max(0, min(1, directionError)),
                            lengthRatio: lengthRatio)
    }

    /// Maximum allowable mean position error for a stroke to "pass" — a
    /// short-circuit used by the writing canvas to accept a stroke without
    /// the user having to tap a button.
    static func passes(_ result: StrokeResult) -> Bool {
        result.accuracy >= 0.55
    }
}
