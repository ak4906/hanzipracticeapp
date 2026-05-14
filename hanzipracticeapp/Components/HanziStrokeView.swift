//
//  HanziStrokeView.swift
//  hanzipracticeapp
//
//  Renders a hanzi using the real Make-Me-a-Hanzi stroke outlines. Each
//  stroke is a filled SVG path inside a 1024×1024 canonical box, scaled to
//  the view's bounds. Three modes:
//
//   • staticAll               — all strokes filled at once (proper printed look)
//   • progressive(completed:) — only the first N strokes filled
//   • animate                 — animates the strokes being painted in order,
//                                in-progress stroke drawn as a fat stroked
//                                median.
//

import SwiftUI

struct HanziStrokeView: View {
    enum Mode {
        case staticAll
        case progressive(completed: Int)
        case animate
    }

    let character: HanziCharacter
    var mode: Mode = .staticAll
    var strokeColor: Color = .primary
    /// Optional per-stroke color overrides. When non-nil, each stroke is
    /// drawn in `strokeColors[index]` (falling back to `strokeColor` if the
    /// array is short). Used to highlight which strokes belong to which
    /// component on a phono-semantic compound (e.g. 朗 → 月 / 良).
    var strokeColors: [Color]? = nil
    var ghostColor: Color = Color.primary.opacity(0.08)
    var showGrid: Bool = true
    var medianLineFraction: CGFloat = 0.075     // for the in-progress animation stroke
    var animationDuration: Double = 0.7
    var loops: Bool = true

    @State private var animatedStrokes: Int = 0
    @State private var animationProgress: Double = 0
    @State private var animationTask: Task<Void, Never>? = nil
    @State private var graphics: MMAGraphics? = nil

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                if showGrid { gridBackground(side: side) }
                ghostOutline(side: side)
                paintedStrokes(side: side)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: character.char) {
            // Keyed on `.char` (not `.id`) so the strokes re-fetch when the
            // active writing system switches between Simplified/Traditional.
            self.graphics = MMAStore.shared.graphics(for: character.char)
            if case .animate = mode { restartAnimation() }
        }
        .onDisappear { animationTask?.cancel() }
    }

    // MARK: - Subviews

    private func gridBackground(side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: side, y: side))
                p.move(to: CGPoint(x: side, y: 0)); p.addLine(to: CGPoint(x: 0, y: side))
                p.move(to: CGPoint(x: side / 2, y: 0)); p.addLine(to: CGPoint(x: side / 2, y: side))
                p.move(to: CGPoint(x: 0, y: side / 2)); p.addLine(to: CGPoint(x: side, y: side / 2))
            }
            .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .frame(width: side, height: side)
    }

    private func ghostOutline(side: CGFloat) -> some View {
        Group {
            if let graphics {
                graphics.scaledFilledPath(side: side)
                    .fill(ghostColor)
            }
        }
    }

    private func paintedStrokes(side: CGFloat) -> some View {
        Group {
            if let graphics {
                switch mode {
                case .staticAll:
                    strokeStack(graphics: graphics, side: side, count: graphics.strokes.count)

                case .progressive(let completed):
                    strokeStack(graphics: graphics, side: side,
                                count: min(completed, graphics.strokes.count))

                case .animate:
                    strokeStack(graphics: graphics, side: side, count: animatedStrokes)
                    if animatedStrokes < graphics.strokes.count {
                        // Draw the in-progress stroke as a fat median line
                        // tracing along the stroke's median path.
                        let medians = graphics.medians
                        let median = medians[animatedStrokes]
                        let scaled = median.map {
                            CGPoint(x: $0.x * side / 1024.0, y: $0.y * side / 1024.0)
                        }
                        let partial = partialPoints(scaled, progress: animationProgress)
                        Path { path in
                            guard let first = partial.first else { return }
                            path.move(to: first)
                            for p in partial.dropFirst() { path.addLine(to: p) }
                        }
                        .stroke(color(at: animatedStrokes),
                                style: StrokeStyle(lineWidth: side * medianLineFraction,
                                                   lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
    }

    /// Paints the first `count` strokes, each with its own colour from
    /// `strokeColors` (falling back to `strokeColor` when no override is
    /// supplied). When no overrides exist we collapse into a single combined
    /// `Path.fill` for speed — that's the hot path for the common case.
    private func strokeStack(graphics: MMAGraphics, side: CGFloat, count: Int) -> some View {
        let n = max(0, min(count, graphics.strokes.count))
        return Group {
            if strokeColors == nil {
                graphics.scaledFilledPath(side: side, count: n)
                    .fill(strokeColor)
            } else {
                ForEach(0..<n, id: \.self) { i in
                    graphics.scaledFilledPath(side: side, from: i, to: i + 1)
                        .fill(color(at: i))
                }
            }
        }
    }

    private func color(at index: Int) -> Color {
        if let colors = strokeColors, index >= 0, index < colors.count {
            return colors[index]
        }
        return strokeColor
    }

    // MARK: - Animation helpers

    private func partialPoints(_ points: [CGPoint], progress: Double) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        let totalLength = Geometry.polylineLength(points)
        guard totalLength > 0 else { return points }
        let target = totalLength * progress
        var travelled = 0.0
        var result: [CGPoint] = [points[0]]
        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]
            let d = hypot(curr.x - prev.x, curr.y - prev.y)
            if travelled + d >= target {
                let t = (target - travelled) / d
                result.append(CGPoint(x: prev.x + t * (curr.x - prev.x),
                                      y: prev.y + t * (curr.y - prev.y)))
                break
            } else {
                travelled += d
                result.append(curr)
            }
        }
        return result
    }

    private func restartAnimation() {
        guard let graphics else { return }
        animationTask?.cancel()
        animatedStrokes = 0
        animationProgress = 0

        animationTask = Task { @MainActor in
            for index in 0..<graphics.strokes.count {
                if Task.isCancelled { return }
                let frameRate: Double = 60
                let frames = Int(animationDuration * frameRate)
                for f in 0...frames {
                    if Task.isCancelled { return }
                    animationProgress = Double(f) / Double(frames)
                    try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / frameRate))
                }
                animatedStrokes = index + 1
                animationProgress = 0
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled, loops { restartAnimation() }
        }
    }
}

// MARK: - Drawing helpers

extension MMAGraphics {
    /// Combined `Path` of the first `count` strokes, scaled into a `side×side`
    /// canvas. If `count` is nil, returns all strokes.
    func scaledFilledPath(side: CGFloat, count: Int? = nil) -> Path {
        let n = count ?? strokes.count
        var combined = Path()
        let scale = side / 1024.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        for i in 0..<min(n, strokes.count) {
            combined.addPath(strokes[i].applying(transform))
        }
        return combined
    }
}
