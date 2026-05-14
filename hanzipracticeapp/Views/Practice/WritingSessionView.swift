//
//  WritingSessionView.swift
//  hanzipracticeapp
//
//  Full-screen interactive practice session — runs through a queue of
//  characters, displays the writing canvas, and applies SRS grading after
//  each one.
//

import SwiftUI
import SwiftData

struct WritingSessionView: View {
    let session: PracticeSession
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(CharacterStore.self) private var store

    @State private var index: Int = 0
    @State private var canvas: WritingCanvasModel? = nil
    @State private var phase: Phase = .writing
    @State private var sessionStarted: Date = .now
    @State private var sessionResults: [String: Double] = [:]   // characterID → avg accuracy
    /// Whether the user has manually overridden the auto-graduation logic
    /// for the current session. When true we respect their pick on every
    /// new character; when false we pick based on SRS mastery.
    @State private var hintModeOverride: WritingHintMode? = nil
    /// Set when the user taps the pinyin / meaning row mid-session — pops
    /// open the character detail page without aborting the session.
    @State private var peekCharacter: HanziCharacter? = nil
    /// How the session sequences characters and which hint level is used
    /// on each pass. `.threePass` runs every character three times in a row
    /// (arrow → trace → memory); `.adaptive` does a single pass with the
    /// hint level chosen by SRS mastery.
    @State private var practiceMode: SessionPracticeMode = .threePass

    enum Phase: Hashable {
        case writing       // user is drawing
        case grading       // showing summary + SRS buttons
        case finished      // whole session done
    }

    private var characters: [HanziCharacter] {
        // De-duplicate by canonical id so a list that contains both 学 and
        // 學 only practices once when the user is in either mode.
        var seen = Set<String>()
        var out: [HanziCharacter] = []
        for id in session.characterIDs {
            if let c = store.character(for: id), seen.insert(c.canonicalID).inserted {
                out.append(c)
            }
        }
        return out
    }

    /// Total steps until the session is "finished" — characters × passes.
    private var totalSteps: Int {
        guard !characters.isEmpty else { return 0 }
        return characters.count * practiceMode.passCount
    }

    /// Which character we're on within the current pass (0..N-1).
    private var currentCharIndex: Int {
        guard !characters.isEmpty else { return 0 }
        return index % characters.count
    }

    /// Which pass we're on (0..passCount-1). 0 for adaptive mode.
    private var currentPass: Int {
        guard !characters.isEmpty else { return 0 }
        return min(index / characters.count, practiceMode.passCount - 1)
    }

    private var current: HanziCharacter? {
        characters.indices.contains(currentCharIndex) ? characters[currentCharIndex] : nil
    }

    /// Whether the SRS grading sheet should appear after the current step.
    /// In `.threePass` we only grade after the final (memory) pass; the two
    /// warm-up passes auto-advance.
    private var isGradingStep: Bool {
        practiceMode == .adaptive || currentPass == practiceMode.passCount - 1
    }

    var body: some View {
        NavigationStack {
            Group {
                if characters.isEmpty {
                    emptyQueueView
                } else {
                    VStack(spacing: 16) {
                        progressHeader
                        if phase == .finished {
                            finishedView
                        } else if let c = current {
                            VStack(spacing: 14) {
                                cardHeader(for: c)
                                Group {
                                    if let canvas {
                                        WritingCanvas(model: canvas) { _ in
                                            Task { @MainActor in
                                                try? await Task.sleep(nanoseconds: 600_000_000)
                                                if isGradingStep {
                                                    phase = .grading
                                                } else {
                                                    advance()
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                    } else {
                                        Color.clear.aspectRatio(1, contentMode: .fit)
                                    }
                                }
                                controls(for: c)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 22))
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(session.title)
                        .font(.system(size: 15, weight: .semibold))
                }
                if !characters.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        settingsMenu
                    }
                }
            }
            .onAppear {
                guard !characters.isEmpty else { return }
                if canvas == nil, let c = current {
                    canvas = WritingCanvasModel(character: c,
                                                hintMode: defaultHintMode(for: c))
                }
            }
            .onChange(of: index) { _, _ in
                guard !characters.isEmpty else { return }
                if let c = current {
                    canvas = WritingCanvasModel(character: c,
                                                hintMode: defaultHintMode(for: c))
                }
                phase = .writing
            }
            .onChange(of: practiceMode) { _, _ in
                guard !characters.isEmpty else { return }
                // Stay on the current character but restart from pass 0 of
                // the new mode so the user isn't dropped into an unexpected
                // hint level after switching settings mid-session.
                let charIdx = currentCharIndex
                if index != charIdx {
                    index = charIdx     // triggers onChange(of: index) → rebuilds canvas
                } else if let c = current {
                    canvas?.hintMode = defaultHintMode(for: c)
                }
            }
            .sheet(isPresented: gradingBinding) {
                if let model = canvas, let c = current {
                    GradingSheet(model: model,
                                 character: c,
                                 onGrade: { grade in
                                     applyGrade(grade, character: c, model: model)
                                 })
                    .presentationDetents([.fraction(0.55), .large])
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
                }
            }
            .sheet(item: $peekCharacter) { c in
                NavigationStack {
                    CharacterDetailView(character: c)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { peekCharacter = nil }
                                    .font(.system(size: 15, weight: .semibold))
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var emptyQueueView: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 32)
            Image(systemName: "square.and.pencil")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent.opacity(0.85))
            Text("Nothing to practice")
                .font(.system(size: 20, weight: .bold))
            Text("There are no characters in this session. Close and add items from the Dictionary or list detail first.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button {
                onClose()
            } label: {
                Text("Close")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.accent)
                    )
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)
            Spacer()
        }
        .padding(.top, 8)
    }

    private var gradingBinding: Binding<Bool> {
        Binding(
            get: { phase == .grading },
            set: { newValue in
                // Only revert to .writing if we're dismissing *from* grading.
                // Otherwise we'd clobber transitions to .finished after the
                // user grades the last character.
                if !newValue, phase == .grading { phase = .writing }
            }
        )
    }

    private var progressHeader: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(min(currentCharIndex + 1, characters.count)) / \(characters.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if practiceMode == .threePass {
                        Text("Pass \(currentPass + 1) of \(practiceMode.passCount) · \(passCaption)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Spacer()
                if !sessionResults.isEmpty {
                    Text(averageString)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            ProgressView(value: Double(min(index, totalSteps)),
                         total: Double(totalSteps))
                .tint(Theme.accent)
        }
        .padding(.horizontal, 16)
    }

    /// Short caption matching the current pass — keeps the UI reminding the
    /// user why this round looks different from the last.
    private var passCaption: String {
        guard practiceMode == .threePass else { return "" }
        switch currentPass {
        case 0:  return "start/end dots + template"
        case 1:  return "template only"
        default: return "from memory"
        }
    }

    private var averageString: String {
        guard !sessionResults.isEmpty else { return "" }
        let avg = sessionResults.values.reduce(0, +) / Double(sessionResults.count)
        return "Avg \(Int(avg * 100))%"
    }

    private func cardHeader(for c: HanziCharacter) -> some View {
        Button {
            peekCharacter = c
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(c.pinyin)
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .foregroundStyle(Theme.accent)
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent.opacity(0.6))
                }
                Text(c.meaning)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let canvas {
                    HStack(spacing: 8) {
                        if canvas.totalStrokes > 0 {
                            Text("Stroke \(min(canvas.completedStrokes + 1, canvas.totalStrokes)) of \(canvas.totalStrokes)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        hintModePill(canvas.hintMode)
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hintModePill(_ mode: WritingHintMode) -> some View {
        let color: Color = mode == .memory ? Theme.warning : Theme.accent
        return HStack(spacing: 4) {
            Image(systemName: mode.systemImage)
            Text(mode.shortName.uppercased())
                .tracking(0.6)
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    /// Toolbar menu lets the user choose the session-level practice mode and
    /// (optionally) pin the hint level for the current character.
    private var settingsMenu: some View {
        Menu {
            Section("Practice method") {
                Picker("Practice method", selection: $practiceMode) {
                    ForEach(SessionPracticeMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
            }
            Section("Hint level (this character)") {
                Picker("Hint level", selection: hintModeBinding) {
                    ForEach(WritingHintMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage)
                            .tag(Optional(mode))
                    }
                    Label("Auto", systemImage: "wand.and.stars")
                        .tag(Optional<WritingHintMode>.none)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(Theme.accent)
        }
    }

    /// Two-way binding so the hint-level picker reflects whatever's actually
    /// driving the canvas right now — explicit override or auto-derived.
    private var hintModeBinding: Binding<WritingHintMode?> {
        Binding(
            get: { hintModeOverride },
            set: { newValue in
                hintModeOverride = newValue
                if let c = current {
                    canvas?.hintMode = newValue ?? defaultHintMode(for: c)
                }
            }
        )
    }

    /// Picks the hint level for the current character. Three-pass mode is
    /// authoritative — each pass has a fixed level. Adaptive mode falls back
    /// to SRS mastery, with a manual override still taking precedence.
    private func defaultHintMode(for c: HanziCharacter) -> WritingHintMode {
        if let pinned = hintModeOverride { return pinned }
        if practiceMode == .threePass {
            switch currentPass {
            case 0:  return .traceWithArrow
            case 1:  return .trace
            default: return .memory
            }
        }
        let card = UserDataController(context: modelContext).card(for: c.id)
        let mastery = card?.mastery ?? 0
        return mastery >= 0.6 ? .memory : .trace
    }

    private func controls(for c: HanziCharacter) -> some View {
        HStack(spacing: 10) {
            Button {
                canvas?.playDemonstration()
            } label: {
                controlLabel(systemImage: "eye", title: "Show stroke")
            }
            Button {
                canvas = WritingCanvasModel(character: c,
                                            hintMode: defaultHintMode(for: c))
            } label: {
                controlLabel(systemImage: "arrow.counterclockwise", title: "Reset")
            }
            Button {
                if isGradingStep {
                    phase = .grading
                } else {
                    advance()
                }
            } label: {
                controlLabel(systemImage: isGradingStep ? "checkmark.seal" : "arrow.right",
                             title: isGradingStep ? "Finish" : "Next pass")
            }
            .disabled(canvas?.completedStrokes == 0)
        }
    }

    private func controlLabel(systemImage: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title).font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Theme.accent)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accentSoft.opacity(0.6))
        )
    }

    // MARK: - Finishing

    private var finishedView: some View {
        let total = characters.count
        let avg: Double = sessionResults.isEmpty ? 0
            : sessionResults.values.reduce(0, +) / Double(sessionResults.count)
        let duration = Int(Date.now.timeIntervalSince(sessionStarted))
        return VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("Session complete!")
                .font(.system(size: 24, weight: .bold))
            VStack(spacing: 6) {
                Text("\(total) character\(total == 1 ? "" : "s")")
                Text("Average accuracy \(Int(avg * 100))%")
                Text("Time: \(duration / 60)m \(duration % 60)s")
            }
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            Button {
                onClose()
            } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.accent)
                    )
            }
            .padding(.horizontal, 30)
            .padding(.top, 8)
        }
        .padding()
    }

    private func applyGrade(_ grade: SRSGrade, character: HanziCharacter, model: WritingCanvasModel) {
        let controller = UserDataController(context: modelContext)
        let card = controller.ensureCard(for: character.id)
        SRSEngine.apply(grade: grade, to: card)
        controller.recordPractice(characterID: character.id,
                                  accuracy: model.averageAccuracy,
                                  retries: model.totalRetries,
                                  duration: model.elapsedSeconds,
                                  kind: "writing")

        sessionResults[character.id] = model.averageAccuracy
        advance()
    }

    /// Move forward by one step (next character within this pass, or the
    /// first character of the next pass when we wrap around).
    private func advance() {
        guard totalSteps > 0 else {
            phase = .finished
            return
        }
        if index + 1 >= totalSteps {
            phase = .finished
        } else {
            index += 1
        }
    }
}

// MARK: - Practice mode

/// How a session structures its repetitions and hint levels.
enum SessionPracticeMode: String, CaseIterable, Identifiable, Sendable {
    /// Each character is practised three times in a row — first with a bold
    /// median start/end dots + template, then template only, then from memory.
    /// Grading happens only after the memory pass.
    case threePass

    /// Single pass through the queue, with the hint level chosen for each
    /// character based on SRS mastery (the pre-existing behaviour).
    case adaptive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .threePass: "3-pass drill"
        case .adaptive:  "Adaptive (1×)"
        }
    }

    var systemImage: String {
        switch self {
        case .threePass: "rectangle.stack.fill"
        case .adaptive:  "wand.and.stars"
        }
    }

    var passCount: Int {
        switch self {
        case .threePass: 3
        case .adaptive:  1
        }
    }
}

// MARK: - Grading sheet

struct GradingSheet: View {
    let model: WritingCanvasModel
    let character: HanziCharacter
    let onGrade: (SRSGrade) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var card: SRSCard?

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color.secondary.opacity(0.3))
                .frame(width: 40, height: 4)
                .padding(.top, 4)
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(character.char)
                        .font(Theme.hanzi(36))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading) {
                        Text(character.pinyin)
                            .font(.system(size: 16, weight: .semibold))
                        Text(character.meaning)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("\(Int(model.averageAccuracy * 100))%")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Theme.accent)
                        Text("accuracy")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)

            strokeBreakdown
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 8) {
                Text("How well did you remember it?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                gradeButtons
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .onAppear {
            card = UserDataController(context: modelContext).ensureCard(for: character.id)
        }
    }

    private var strokeBreakdown: some View {
        let results = model.perStrokeResults
        return HStack(spacing: 6) {
            ForEach(Array(results.enumerated()), id: \.offset) { idx, r in
                VStack(spacing: 4) {
                    Text("\(idx + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(color(for: r.accuracy))
                        .frame(width: 14, height: 14)
                    Text("\(Int(r.accuracy * 100))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            if results.isEmpty {
                Text("No strokes recorded.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func color(for accuracy: Double) -> Color {
        switch accuracy {
        case 0.85...: return Theme.accent
        case 0.6..<0.85: return Color(hex: 0xC9A13C)
        default: return Theme.warning
        }
    }

    private var gradeButtons: some View {
        HStack(spacing: 8) {
            ForEach(SRSGrade.allCases) { grade in
                Button {
                    onGrade(grade)
                } label: {
                    VStack(spacing: 4) {
                        Text(grade.label)
                            .font(.system(size: 14, weight: .bold))
                        if let card {
                            Text(grade.previewInterval(for: card))
                                .font(.system(size: 11))
                                .opacity(0.85)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(color(for: grade))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func color(for grade: SRSGrade) -> Color {
        switch grade {
        case .again: Color(hex: 0xCE5757)
        case .hard:  Color(hex: 0xC9A13C)
        case .good:  Theme.accent
        case .easy:  Color(hex: 0x6789C2)
        }
    }
}
