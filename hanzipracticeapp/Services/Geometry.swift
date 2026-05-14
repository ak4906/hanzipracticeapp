//
//  Geometry.swift
//  hanzipracticeapp
//
//  Small helpers shared by the stroke-judging pipeline and the renderer.
//

import CoreGraphics
import Foundation

enum Geometry {

    /// Total length of a polyline.
    static func polylineLength(_ points: [CGPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            total += hypot(points[i].x - points[i-1].x, points[i].y - points[i-1].y)
        }
        return total
    }

    /// Resample a polyline to exactly `count` evenly-spaced points along its
    /// arc length. Useful for comparing two strokes of arbitrary length.
    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count >= 2, count >= 2 else {
            return Array(repeating: points.first ?? .zero, count: count)
        }

        let totalLength = polylineLength(points)
        guard totalLength > 0 else {
            return Array(repeating: points[0], count: count)
        }

        // Cumulative arc length at each input point.
        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(points.count)
        for i in 1..<points.count {
            let d = hypot(points[i].x - points[i-1].x, points[i].y - points[i-1].y)
            cumulative.append(cumulative.last! + d)
        }

        let step = totalLength / Double(count - 1)
        var result: [CGPoint] = []
        result.reserveCapacity(count)
        result.append(points[0])

        var seg = 1
        for k in 1..<(count - 1) {
            let target = Double(k) * step
            while seg < points.count - 1 && cumulative[seg] < target {
                seg += 1
            }
            let a = cumulative[seg - 1]
            let b = cumulative[seg]
            let t = b == a ? 0 : (target - a) / (b - a)
            let p1 = points[seg - 1]
            let p2 = points[seg]
            result.append(CGPoint(
                x: p1.x + t * (p2.x - p1.x),
                y: p1.y + t * (p2.y - p1.y)
            ))
        }
        result.append(points.last!)
        return result
    }

    /// Mean L2 distance between two same-length polylines.
    static func meanDistance(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum = 0.0
        for i in 0..<a.count {
            sum += hypot(a[i].x - b[i].x, a[i].y - b[i].y)
        }
        return sum / Double(a.count)
    }

    /// Hausdorff-like maximum distance — punishes a single rogue point.
    static func maxDistance(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var m = 0.0
        for i in 0..<a.count {
            m = max(m, hypot(a[i].x - b[i].x, a[i].y - b[i].y))
        }
        return m
    }

    /// Bounding box of a polyline.
    static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Direction from first to last point of a polyline (unit vector).
    static func direction(_ points: [CGPoint]) -> CGVector {
        guard let first = points.first, let last = points.last,
              first != last else { return .zero }
        let dx = last.x - first.x
        let dy = last.y - first.y
        let len = hypot(dx, dy)
        return CGVector(dx: dx / len, dy: dy / len)
    }
}
