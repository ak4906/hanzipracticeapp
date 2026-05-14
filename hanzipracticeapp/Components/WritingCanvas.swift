//
//  WritingCanvas.swift
//  hanzipracticeapp
//
//  Interactive writing surface. Real Make-Me-a-Hanzi stroke outlines are
//  drawn for completed/hint strokes, the user's drag is rendered live, and
//  each finished stroke is judged against the MMA median for that index.
//

import SwiftUI

/// How much of the character is visible to the user while they're writing.
///   • `.traceWithArrow` — template + **green start dot** and **red end dot**
///                          on the median of the next stroke (reliable hints;
///                          no directional arrow — MMA medians often mislead).
///   • `.trace`          — template silhouette + faint next-stroke outline.
///   • `.memory`         — blank grid; the user has to write from memory.
///                          "Show stroke" still works as a one-off rescue.
enum WritingHintMode: String, Sendable, CaseIterable, Identifiable {
    case traceWithArrow
    case trace
    case memory

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .traceWithArrow: "Trace + markers"
        case .trace:          "Trace"
        case .memory:         "Memory"
        }
    }

    var shortName: String {
        switch self {
        case .traceWithArrow: "Dots"
        case .trace:          "Trace"
        case .memory:         "Memory"
        }
    }

    var systemImage: String {
        switch self {
        case .traceWithArrow: "circle.lefthalf.filled.righthalf.striped.horizontal"
        case .trace:          "scribble.variable"
        case .memory:         "brain.head.profile"
        }
    }

    /// Whether the pale full-character ghost + next-stroke outline are drawn.
    var showsTemplate: Bool {
        switch self {
        case .traceWithArrow, .trace: true
        case .memory:                 false
        }
    }

    /// Green/red median endpoints for the next stroke (pass 1 of the drill).
    var showsStrokeEndpoints: Bool { self == .traceWithArrow }
}

@Observable
@MainActor
final class WritingCanvasModel {
    let character: HanziCharacter
    var graphics: MMAGraphics?

    /// Current hint level — flipped from the parent view.
    var hintMode: WritingHintMode

    private(set) var completedStrokes: Int = 0
    private(set) var attempts: Int = 0
    private(set) var retriesOnCurrent: Int = 0
    private(set) var totalRetries: Int = 0
    private(set) var perStrokeResults: [StrokeResult] = []
    /// Normalised canvas coords (0…1) for each **accepted** stroke — used to
    /// redraw the user's own ink instead of swapping in MMA fills.
    private(set) var completedUserStrokes: [[CGPoint]] = []
    private(set) var lastResult: StrokeResult? = nil
    private(set) var feedback: Feedback? = nil
    private(set) var startTime: Date = .now

    // Demonstration state — drives the "Show stroke" preview animation.
    private(set) var isDemonstrating: Bool = false
    private(set) var demoProgress: Double = 0
    @ObservationIgnored private var demoTask: Task<Void, Never>? = nil

    enum Feedback: Equatable {
        case accepted(StrokeResult)
        case retry(StrokeResult)
    }

    init(character: HanziCharacter, hintMode: WritingHintMode = .trace) {
        self.character = character
        self.hintMode = hintMode
        self.graphics = MMAStore.shared.graphics(for: character.char)
    }

    var isComplete: Bool {
        guard let g = graphics else { return false }
        return completedStrokes >= g.strokes.count
    }

    var averageAccuracy: Double {
        guard !perStrokeResults.isEmpty else { return 0 }
        return perStrokeResults.map(\.accuracy).reduce(0, +) / Double(perStrokeResults.count)
    }

    var totalStrokes: Int { graphics?.strokes.count ?? 0 }

    @discardableResult
    func submit(stroke unitPoints: [CGPoint], canvasSide: CGFloat) -> StrokeResult {
        attempts += 1
        guard let graphics, completedStrokes < graphics.medians.count else {
            let dud = StrokeResult(strokeIndex: completedStrokes,
                                   accuracy: 0, positionError: 1,
                                   directionError: 1, lengthRatio: 0)
            lastResult = dud
            return dud
        }
        let medianRaw = graphics.medians[completedStrokes]
        // medianRaw is in 1024-space y-down; scale to canvas-space, then judge.
        let modelScaled = medianRaw.map {
            CGPoint(x: $0.x * canvasSide / 1024.0, y: $0.y * canvasSide / 1024.0)
        }
        let userScaled = unitPoints.map {
            CGPoint(x: $0.x * canvasSide, y: $0.y * canvasSide)
        }

        let result = StrokeJudge.judge(userStroke: userScaled,
                                       against: modelScaled,
                                       canvasSize: canvasSide,
                                       strokeIndex: completedStrokes)
        lastResult = result

        if result.passed {
            perStrokeResults.append(result)
            completedUserStrokes.append(unitPoints)
            completedStrokes += 1
            retriesOnCurrent = 0
            feedback = .accepted(result)
        } else {
            retriesOnCurrent += 1
            totalRetries += 1
            feedback = .retry(result)
        }
        return result
    }

    /// Animates the next expected stroke along its median path so the user
    /// can see the correct direction / order without auto-completing it —
    /// they still have to actually draw it themselves.
    func playDemonstration(duration: Double = 1.0) {
        guard let graphics, completedStrokes < graphics.medians.count else { return }
        demoTask?.cancel()
        demoProgress = 0
        isDemonstrating = true
        demoTask = Task { @MainActor in
            let frameRate: Double = 60
            let frames = max(2, Int(duration * frameRate))
            for f in 0...frames {
                if Task.isCancelled { break }
                demoProgress = Double(f) / Double(frames)
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / frameRate))
            }
            // Linger for a beat at the end before fading out.
            try? await Task.sleep(nanoseconds: 200_000_000)
            isDemonstrating = false
            demoProgress = 0
        }
    }

    /// Force-accept the current stroke (used as a hidden escape hatch if
    /// the parser misses a stroke entirely; not bound to a UI control).
    func skipCurrentStroke() {
        guard let graphics, completedStrokes < graphics.strokes.count else { return }
        let placeholder = StrokeResult(strokeIndex: completedStrokes,
                                       accuracy: 0.4,
                                       positionError: 0.5,
                                       directionError: 0.5,
                                       lengthRatio: 1)
        perStrokeResults.append(placeholder)
        completedUserStrokes.append([])
        completedStrokes += 1
        retriesOnCurrent = 0
        feedback = .accepted(placeholder)
    }

    func reset() {
        demoTask?.cancel()
        isDemonstrating = false
        demoProgress = 0
        completedStrokes = 0
        attempts = 0
        retriesOnCurrent = 0
        totalRetries = 0
        perStrokeResults.removeAll()
        completedUserStrokes.removeAll()
        lastResult = nil
        feedback = nil
        startTime = .now
    }

    var elapsedSeconds: Double { Date.now.timeIntervalSince(startTime) }
}

struct WritingCanvas: View {
    @Bindable var model: WritingCanvasModel
    var onCompletion: ((WritingCanvasModel) -> Void)? = nil

    @State private var currentStroke: [CGPoint] = []
    @State private var flashColor: Color? = nil
    @State private var ghostStrokeIndex: Int? = nil
    @State private var ghostOpacity: Double = 0

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                background(side: side)
                fullCharacterGhost(side: side)
                userCompletedInk(side: side)
                hintNextStroke(side: side)
                strokeEndpointMarkers(side: side)
                demonstrationOverlay(side: side)
                currentDrawing(side: side)
                ghostFeedback(side: side)
                flashOverlay(side: side)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = CGPoint(x: value.location.x / side,
                                        y: value.location.y / side)
                        if p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 {
                            currentStroke.append(p)
                        }
                    }
                    .onEnded { _ in
                        guard currentStroke.count > 2, !model.isComplete else {
                            currentStroke.removeAll()
                            return
                        }
                        let result = model.submit(stroke: currentStroke, canvasSide: side)
                        currentStroke.removeAll()
                        flashFeedback(for: result)
                        if model.isComplete { onCompletion?(model) }
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Subviews

    private func background(side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.card)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: side, y: side))
                p.move(to: CGPoint(x: side, y: 0)); p.addLine(to: CGPoint(x: 0, y: side))
                p.move(to: CGPoint(x: side/2, y: 0)); p.addLine(to: CGPoint(x: side/2, y: side))
                p.move(to: CGPoint(x: 0, y: side/2)); p.addLine(to: CGPoint(x: side, y: side/2))
            }
            .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        }
    }

    /// Pale silhouette of the whole character so the user can see where to
    /// write. Suppressed entirely in memory mode (user writes from memory).
    private func fullCharacterGhost(side: CGFloat) -> some View {
        Group {
            if model.hintMode.showsTemplate, let g = model.graphics {
                g.scaledFilledPath(side: side)
                    .fill(Color.primary.opacity(0.05))
            }
        }
    }

    private func hintNextStroke(side: CGFloat) -> some View {
        Group {
            if model.hintMode.showsTemplate,
               let g = model.graphics,
               model.completedStrokes < g.strokes.count {
                // Faded outline of the expected next stroke.
                g.scaledFilledPath(side: side,
                                   from: model.completedStrokes,
                                   to: model.completedStrokes + 1)
                    .fill(Theme.accent.opacity(model.retriesOnCurrent >= 2 ? 0.45 : 0.20))

                // Median direction guide — only when the user has missed
                // at least once, and only when pass-1 endpoint dots aren't shown
                // (those already encode start vs end).
                let median = g.medians[model.completedStrokes]
                let scaled = median.map {
                    CGPoint(x: $0.x * side / 1024.0, y: $0.y * side / 1024.0)
                }
                if model.retriesOnCurrent >= 1, !model.hintMode.showsStrokeEndpoints {
                    Path { p in
                        guard let f = scaled.first else { return }
                        p.move(to: f)
                        for pt in scaled.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(Theme.accent.opacity(0.55),
                            style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                }
                // No standalone start dot in `.trace` — after the dots pass we
                // only hint via the faint stroke silhouette (and the dashed
                // median after a miss), so the entry point isn't given away.
            } else if model.hintMode == .memory,
                      let g = model.graphics,
                      model.completedStrokes < g.strokes.count,
                      model.retriesOnCurrent >= 3 {
                // Last-ditch rescue: after 3 consecutive misses in memory
                // mode, briefly reveal the next stroke's outline so the
                // user can recover and continue the session.
                g.scaledFilledPath(side: side,
                                   from: model.completedStrokes,
                                   to: model.completedStrokes + 1)
                    .fill(Theme.warning.opacity(0.35))
            }
        }
    }

    /// Green dot at the stroke's median **start**, red at the **end** — gives
    /// order without a misleading tangent direction from sparse MMA medians.
    private func strokeEndpointMarkers(side: CGFloat) -> some View {
        Group {
            if model.hintMode.showsStrokeEndpoints,
               let g = model.graphics,
               model.completedStrokes < g.medians.count {
                let median = g.medians[model.completedStrokes]
                let scaled = median.map {
                    CGPoint(x: $0.x * side / 1024.0, y: $0.y * side / 1024.0)
                }
                if let start = scaled.first {
                    let dot = side * 0.052
                    Circle()
                        .fill(Color.green)
                        .frame(width: dot, height: dot)
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                        .position(start)
                }
                if let end = scaled.last, scaled.count > 1 {
                    let dot = side * 0.052
                    Circle()
                        .fill(Color.red)
                        .frame(width: dot, height: dot)
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                        .position(end)
                }
            }
        }
    }

    /// The learner's accepted strokes only — lets them compare their line
    /// quality against the pale template underneath instead of MMA "perfect" fills.
    private func userCompletedInk(side: CGFloat) -> some View {
        let w = side * WritingCanvas.inkLineWidthFactor
        return ForEach(Array(model.completedUserStrokes.enumerated()), id: \.offset) { _, pts in
            Group {
                if pts.count > 1 {
                    Path { path in
                        let first = pts[0]
                        path.move(to: CGPoint(x: first.x * side, y: first.y * side))
                        for p in pts.dropFirst() {
                            path.addLine(to: CGPoint(x: p.x * side, y: p.y * side))
                        }
                    }
                    .stroke(Color.primary.opacity(0.88),
                            style: StrokeStyle(lineWidth: w,
                                               lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private static let inkLineWidthFactor: CGFloat = 0.052

    /// Animated brush-tip travelling along the next expected stroke's
    /// median when the user taps "Show stroke". The full silhouette of the
    /// stroke is also faded in for context, then the active section is
    /// painted on top to convey direction.
    private func demonstrationOverlay(side: CGFloat) -> some View {
        Group {
            if model.isDemonstrating,
               let g = model.graphics,
               model.completedStrokes < g.medians.count {

                // Soft silhouette of the whole stroke (where it'll end up).
                g.scaledFilledPath(side: side,
                                   from: model.completedStrokes,
                                   to: model.completedStrokes + 1)
                    .fill(Theme.accent.opacity(0.18))

                // Trimmed median path painted up to the current progress, so
                // the user can see direction & order rather than a static fill.
                let median = g.medians[model.completedStrokes]
                let scaled = median.map {
                    CGPoint(x: $0.x * side / 1024.0, y: $0.y * side / 1024.0)
                }
                let medianPath = Path { p in
                    guard let first = scaled.first else { return }
                    p.move(to: first)
                    for pt in scaled.dropFirst() { p.addLine(to: pt) }
                }
                medianPath
                    .trimmedPath(from: 0, to: model.demoProgress)
                    .stroke(Theme.accent,
                            style: StrokeStyle(lineWidth: side * 0.054,
                                               lineCap: .round, lineJoin: .round))

                // Leading dot following the brush tip.
                if let tip = pointAlong(scaled, progress: model.demoProgress) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: side * 0.06, height: side * 0.06)
                        .position(tip)
                }
            }
        }
    }

    private func pointAlong(_ points: [CGPoint], progress: Double) -> CGPoint? {
        guard points.count >= 2 else { return points.first }
        let totalLength = Geometry.polylineLength(points)
        guard totalLength > 0 else { return points.first }
        let target = totalLength * progress
        var travelled = 0.0
        for i in 1..<points.count {
            let prev = points[i - 1], curr = points[i]
            let d = hypot(curr.x - prev.x, curr.y - prev.y)
            if travelled + d >= target {
                let t = (target - travelled) / d
                return CGPoint(x: prev.x + t * (curr.x - prev.x),
                               y: prev.y + t * (curr.y - prev.y))
            }
            travelled += d
        }
        return points.last
    }

    private func currentDrawing(side: CGFloat) -> some View {
        Path { path in
            guard let first = currentStroke.first else { return }
            path.move(to: CGPoint(x: first.x * side, y: first.y * side))
            for point in currentStroke.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * side, y: point.y * side))
            }
        }
        .stroke(Theme.accent,
                style: StrokeStyle(lineWidth: side * WritingCanvas.inkLineWidthFactor,
                                   lineCap: .round, lineJoin: .round))
    }

    private func ghostFeedback(side: CGFloat) -> some View {
        Group {
            if let idx = ghostStrokeIndex, let g = model.graphics, idx < g.strokes.count {
                g.scaledFilledPath(side: side, from: idx, to: idx + 1)
                    .fill(Theme.warning.opacity(ghostOpacity * 0.6))
            }
        }
    }

    private func flashOverlay(side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(flashColor ?? .clear)
            .opacity(flashColor == nil ? 0 : 0.18)
            .allowsHitTesting(false)
    }

    private func flashFeedback(for result: StrokeResult) {
        let success = result.passed
        flashColor = success ? Theme.accent : Theme.warning
        if !success {
            ghostStrokeIndex = result.strokeIndex
            withAnimation(.easeOut(duration: 0.15)) { ghostOpacity = 1 }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.easeOut(duration: 0.35)) { flashColor = nil }
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeOut(duration: 0.6)) { ghostOpacity = 0 }
            try? await Task.sleep(nanoseconds: 600_000_000)
            ghostStrokeIndex = nil
        }
    }
}

// MARK: - Subset helper

extension MMAGraphics {
    /// Combined `Path` of `strokes[from..<to]`, scaled to `side`.
    func scaledFilledPath(side: CGFloat, from: Int, to: Int) -> Path {
        let scale = side / 1024.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        var combined = Path()
        for i in max(0, from)..<min(to, strokes.count) {
            combined.addPath(strokes[i].applying(transform))
        }
        return combined
    }
}
