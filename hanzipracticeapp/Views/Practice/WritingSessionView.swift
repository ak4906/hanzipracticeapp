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
    @Query private var settingsList: [UserSettings]

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

    /// User's preferred chunk size, clamped to 1...characters.count so
    /// `.threePass` interleaves passes across small batches instead of
    /// running all of pass 1 before any of pass 2.
    private var chunkSize: Int {
        let raw = settingsList.first?.effectivePracticeChunkSize ?? 3
        guard !characters.isEmpty else { return raw }
        return max(1, min(raw, characters.count))
    }

    /// Pre-built (charIndex, pass) order for the whole session — generated
    /// once per (characters, mode, chunkSize) triple. For adaptive mode
    /// this is just a flat single-pass walk.
    private var sequence: [(charIndex: Int, pass: Int)] {
        buildSequence(passCount: practiceMode.passCount,
                      chunkSize: chunkSize,
                      count: characters.count)
    }

    /// Pure builder so `onChange(of: practiceMode)` can also compute the
    /// sequence under the *previous* mode and find the character we were on.
    private func buildSequence(passCount: Int, chunkSize: Int, count: Int)
        -> [(charIndex: Int, pass: Int)]
    {
        guard count > 0 else { return [] }
        let cs = max(1, min(chunkSize, count))
        var out: [(Int, Int)] = []
        out.reserveCapacity(count * passCount)
        var start = 0
        while start < count {
            let end = min(start + cs, count)
            for pass in 0..<passCount {
                for i in start..<end { out.append((i, pass)) }
            }
            start = end
        }
        return out
    }

    /// Total steps until the session is "finished".
    private var totalSteps: Int { sequence.count }

    /// Which character we're on within the current chunk/pass.
    private var currentCharIndex: Int {
        guard !sequence.isEmpty, sequence.indices.contains(min(index, sequence.count - 1)) else { return 0 }
        return sequence[min(index, sequence.count - 1)].charIndex
    }

    /// Which pass we're on (0..passCount-1). 0 for adaptive mode.
    private var currentPass: Int {
        guard !sequence.isEmpty, sequence.indices.contains(min(index, sequence.count - 1)) else { return 0 }
        return sequence[min(index, sequence.count - 1)].pass
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
                                quickActionsRow(for: c)
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
                        // Graded cards have already been persisted by
                        // applyGrade — exiting never loses progress, so no
                        // confirmation needed. Ungraded cards retain their
                        // due-date and come back next session naturally.
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 22))
                    }
                    .accessibilityLabel("Close session")
                }
                ToolbarItem(placement: .principal) {
                    Text(session.title)
                        .font(.system(size: 15, weight: .semibold))
                }
                if !characters.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 14) {
                            // Always visible (not just after a card is graded)
                            // so the user knows mid-session escape is one tap
                            // away — the prior "appears only after grading"
                            // behaviour confused users into thinking they
                            // were locked in.
                            if phase != .finished {
                                Button {
                                    phase = .finished
                                } label: {
                                    Text("Finish")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            settingsMenu
                        }
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
            .onChange(of: practiceMode) { oldValue, _ in
                guard !characters.isEmpty else { return }
                // Find the character we were on under the OLD mode/chunking
                // and jump to that character's pass-0 entry in the new
                // sequence. Without this the index could end up out-of-bounds
                // (e.g. switching from `.threePass` to `.adaptive` shrinks
                // the sequence by 3×) or land on the wrong character.
                let oldSequence = buildSequence(passCount: oldValue.passCount,
                                                chunkSize: chunkSize,
                                                count: characters.count)
                let priorChar = oldSequence.indices.contains(index)
                    ? oldSequence[index].charIndex
                    : 0
                if let newIdx = sequence.firstIndex(where: { $0.charIndex == priorChar && $0.pass == 0 }) {
                    if index != newIdx { index = newIdx }
                    else if let c = current {
                        canvas?.hintMode = defaultHintMode(for: c)
                    }
                } else {
                    index = 0
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

    /// Two small chip buttons for "I already know this" (mark mastered, skip
    /// all remaining passes) and "Skip for now" (move on without touching SRS
    /// state so the card stays due).
    private func quickActionsRow(for c: HanziCharacter) -> some View {
        HStack(spacing: 8) {
            Button {
                markKnown(c)
            } label: {
                quickActionChip(systemImage: "checkmark.circle",
                                title: "I know this",
                                tint: Theme.accent)
            }
            Button {
                skipCharacter()
            } label: {
                quickActionChip(systemImage: "forward.end",
                                title: "Skip for now",
                                tint: .secondary)
            }
        }
    }

    private func quickActionChip(systemImage: String,
                                  title: String,
                                  tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().stroke(tint.opacity(0.4), lineWidth: 1)
        )
    }

    /// User claims to already know the character — grade it as `.easy`
    /// without writing, then jump past any remaining passes for it. No
    /// practice record is created since there's no real attempt.
    private func markKnown(_ c: HanziCharacter) {
        let controller = UserDataController(context: modelContext)
        let card = controller.ensureCard(for: c.id)
        SRSEngine.apply(grade: .easy, to: card)
        try? modelContext.save()
        sessionResults[c.id] = 1.0
        skipToNextCharacter()
    }

    /// Move past the current character entirely without touching its SRS
    /// state — it stays due, so it'll re-appear in a future session.
    private func skipCharacter() {
        skipToNextCharacter()
    }

    /// Advance `index` to the first step whose charIndex differs from the
    /// current one (i.e. the next character in the chunk/session). If there
    /// are no more characters, mark the session finished.
    private func skipToNextCharacter() {
        guard !sequence.isEmpty else { phase = .finished; return }
        let currentChar = currentCharIndex
        var newIndex = index + 1
        while newIndex < totalSteps && sequence[newIndex].charIndex == currentChar {
            newIndex += 1
        }
        if newIndex >= totalSteps {
            phase = .finished
        } else {
            index = newIndex
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
        let practised = sessionResults.count
        let total = characters.count
        let remaining = max(0, total - practised)
        let avg: Double = sessionResults.isEmpty ? 0
            : sessionResults.values.reduce(0, +) / Double(sessionResults.count)
        let duration = Int(Date.now.timeIntervalSince(sessionStarted))
        let finishedEarly = practised < total
        return VStack(spacing: 18) {
            Image(systemName: finishedEarly
                  ? "pause.circle.fill" : "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text(finishedEarly ? "Stopped early" : "Session complete!")
                .font(.system(size: 24, weight: .bold))
            VStack(spacing: 6) {
                Text("\(practised) of \(total) character\(total == 1 ? "" : "s") practised")
                if !sessionResults.isEmpty {
                    Text("Average accuracy \(Int(avg * 100))%")
                }
                Text("Time: \(duration / 60)m \(duration % 60)s")
                if finishedEarly && remaining > 0 {
                    Text("\(remaining) still due — they'll come back next session.")
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 4)
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
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
    /// Optional sheet for the character info page — tap the header to open.
    /// (Common urge: after writing, peek at the dictionary entry to confirm
    /// what it means / check stroke order, without leaving the session.)
    @State private var showingDetail: Bool = false

    var body: some View {
        // The system drag indicator is enabled at the .sheet call site, so
        // we don't draw our own — that produced two stacked indicators.
        VStack(spacing: 16) {
            Button {
                showingDetail = true
            } label: {
                HStack(spacing: 8) {
                    Text(character.char)
                        .font(Theme.hanzi(36))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading) {
                        HStack(spacing: 4) {
                            Text(character.pinyin)
                                .font(.system(size: 16, weight: .semibold))
                            Image(systemName: "info.circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accent.opacity(0.6))
                        }
                        Text(character.meaning)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 18)

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
        .sheet(isPresented: $showingDetail) {
            NavigationStack {
                CharacterDetailView(character: character)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingDetail = false }
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var strokeBreakdown: some View {
        let results = model.perStrokeResults
        return VStack(alignment: .leading, spacing: 8) {
            Text("STROKE ACCURACY")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            if results.isEmpty {
                Text("No strokes recorded.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(results.enumerated()), id: \.offset) { idx, r in
                        strokeColumn(strokeNumber: idx + 1, result: r)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func strokeColumn(strokeNumber: Int, result: StrokeResult) -> some View {
        let passed = result.passed
        return VStack(spacing: 4) {
            Text("Stroke \(strokeNumber)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(passed ? color(for: result.accuracy) : Theme.warning)
            Text("\(Int(result.accuracy * 100))%")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
