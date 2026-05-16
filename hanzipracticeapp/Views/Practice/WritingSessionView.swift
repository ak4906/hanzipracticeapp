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

/// One practice unit — either a single hanzi or a multi-character word.
/// The writing session shows all `characters` side-by-side, the user writes
/// them in order, and the whole entry gets a single SRS grade keyed by
/// `word`.
struct PracticeEntry: Hashable {
    /// Canonical (simplified) key — "我" for a single char, "容易" for a word.
    let word: String
    /// Resolved hanzi data in display order.
    let characters: [HanziCharacter]

    var isWord: Bool { characters.count > 1 }
}

struct WritingSessionView: View {
    let session: PracticeSession
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(CharacterStore.self) private var store
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Query private var settingsList: [UserSettings]

    /// Compact vertical (landscape on phone) — we lay out the session
    /// horizontally so the canvas can claim the full screen height,
    /// instead of getting squeezed below the header/controls.
    private var isCompactVertical: Bool {
        verticalSizeClass == .compact
    }

    /// Hard cap on a single canvas's side length. Defaults to the user's
    /// Profile setting; the in-session pinch gesture below temporarily
    /// overrides it (and writes back to the setting on gesture end so the
    /// new size sticks for next session).
    private var canvasMaxSideOrInfinity: CGFloat {
        if liveCanvasSize > 0 { return liveCanvasSize }
        if let raw = settingsList.first?.practiceCanvasMaxSize, raw > 0 {
            return CGFloat(raw)
        }
        return .infinity
    }

    /// The cap with the in-flight pinch scale folded in. Used as the
    /// `maxWidth`/`maxHeight` on the canvas frame so the user sees the
    /// size change live as they pinch. Clamped to a sensible writable
    /// minimum so the canvas can't disappear.
    private var liveCappedSide: CGFloat {
        let base = canvasMaxSideOrInfinity
        let baseValue = base.isFinite ? base : 360
        let scaled = baseValue * pinchScale
        return max(120, min(scaled, 1000))
    }

    /// Two-finger pinch on the canvas adjusts the live cap. The base
    /// value comes from the current `liveCanvasSize` (or Profile setting),
    /// the gesture's magnification multiplies it, and on gesture-end we
    /// commit the result back to both `liveCanvasSize` and the user's
    /// Profile setting so the new size sticks for the next session.
    /// `simultaneousGesture` modifier at the call site keeps this from
    /// fighting with the canvas's drawing drag gesture.
    private var canvasPinchGesture: some Gesture {
        MagnifyGesture()
            .updating($pinchScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                let base = canvasMaxSideOrInfinity
                let baseValue = base.isFinite ? base : 360
                let newSize = max(120, min(baseValue * value.magnification, 1000))
                liveCanvasSize = newSize
                settingsList.first?.practiceCanvasMaxSize = Int(newSize)
            }
    }

    /// Visible bottom-right resize handle — a small diagonal-arrow chip
    /// the user can drag to grow / shrink the canvas. Pinch is also
    /// supported, but the handle gives users a discoverable affordance
    /// (otherwise pinch is invisible to anyone who doesn't try it).
    private var canvasResizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(
                Circle().fill(Theme.accent.opacity(0.85))
            )
            .padding(8)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let base = canvasMaxSideOrInfinity
                        let baseValue = base.isFinite ? base : 360
                        // Diagonal drag towards bottom-right grows; the
                        // average of the two axes is what we apply.
                        let delta = (value.translation.width + value.translation.height) / 2
                        let newSize = max(120, min(baseValue + delta, 1000))
                        liveCanvasSize = newSize
                    }
                    .onEnded { _ in
                        // Commit the new size back to the user's settings.
                        if liveCanvasSize > 0 {
                            settingsList.first?.practiceCanvasMaxSize = Int(liveCanvasSize)
                        }
                    }
            )
            .accessibilityLabel("Resize canvas")
    }

    @State private var index: Int = 0
    /// One canvas per character in the *current* entry. Rebuilt every time
    /// `index` (or therefore `currentEntry`) changes.
    @State private var canvases: [WritingCanvasModel] = []
    /// Which character within the current entry the user is currently
    /// writing. For single-char entries this is always 0.
    @State private var activeCharIndex: Int = 0
    @State private var phase: Phase = .writing
    @State private var sessionStarted: Date = .now
    /// Keyed by entry word ("容易") → averaged accuracy across all chars of
    /// the most recent attempt. Used by the progress header and the
    /// finished-view summary.
    @State private var sessionResults: [String: Double] = [:]
    /// Whether the user has manually overridden the auto-graduation logic
    /// for the current session. When true we respect their pick on every
    /// new entry; when false we pick based on SRS mastery.
    @State private var hintModeOverride: WritingHintMode? = nil
    /// Set when the user taps the pinyin / meaning row mid-session — pops
    /// open the character detail page without aborting the session.
    @State private var peekCharacter: HanziCharacter? = nil
    /// Set when the user taps the header of a multi-character entry —
    /// opens the word detail sheet (with components + definition) rather
    /// than jumping straight to one character's page.
    @State private var peekWord: WordEntry? = nil
    /// How the session sequences entries and which hint level is used on
    /// each pass. `.threePass` runs every entry three times in a row
    /// (arrow → trace → memory); `.adaptive` does a single pass with the
    /// hint level chosen by SRS mastery.
    @State private var practiceMode: SessionPracticeMode = .threePass
    /// Entry indices the user has bailed out on (via "I know this" or
    /// "Skip for now"). Their remaining passes are skipped — without this,
    /// chunked 3-pass mode would loop the same entry back two more times
    /// because the passes for one entry aren't contiguous in `sequence`.
    @State private var skippedEntries: Set<Int> = []
    /// Current playback order. Computed once from `practiceEntries` + the
    /// mode's pass count + the chunk size, but **mutable** so an "Again"
    /// grade can re-queue the failed entry at the end of the session
    /// (Anki-style relearning queue: you keep seeing it within the
    /// session until you get to Hard or better).
    @State private var sequence: [(entryIndex: Int, pass: Int)] = []
    /// Canvas indices within the *current* entry that the user has marked
    /// as "I already know this character". Their canvases are dimmed,
    /// skipped during auto-advance, and treated as 100% accuracy in the
    /// word-level grade. Persists across all passes of the same entry —
    /// re-marking on every pass of a 3-pass drill would be annoying.
    /// Cleared when the entry index changes.
    @State private var knownCanvases: Set<Int> = []
    /// Tracks which entry `knownCanvases` belongs to, so we know when to
    /// clear it (same-entry pass changes don't reset; new entry does).
    @State private var knownCanvasesEntryIdx: Int = -1
    /// Live canvas size override driven by the in-session pinch gesture.
    /// 0 means "use the user's saved Profile setting"; any positive value
    /// caps the canvas side at that many points. Persisted back to
    /// settings when the gesture ends so the change sticks across sessions.
    @State private var liveCanvasSize: CGFloat = 0
    @GestureState private var pinchScale: CGFloat = 1.0

    enum Phase: Hashable {
        case writing       // user is drawing
        case grading       // showing summary + SRS buttons
        case interPassQuiz // multiple-choice prompt between passes
        case finished      // whole session done
    }

    /// One multiple-choice prompt shown between passes when the user has
    /// enabled the inter-pass quiz. Hashable so the @State binding works.
    struct InterPassQuiz: Hashable {
        enum Kind: String, Hashable {
            case meaning   // "What does X mean?"
            case pinyin    // "How is X pronounced?"
            case component // "Which is a component of X?"
        }
        let entryIndex: Int
        let fromPass: Int          // pass that just completed
        let toPass: Int            // pass that's about to begin
        let kind: Kind
        let prompt: String
        let correct: String
        let options: [String]
    }
    /// Question queue for the current inter-pass quiz event — multiple
    /// questions about the same entry (meaning, pinyin, optionally
    /// components) shown back-to-back. The user must get *all* right to
    /// advance to the next pass; any wrong answer triggers a pass redo.
    @State private var currentQuizQueue: [InterPassQuiz] = []
    @State private var quizQueueIndex: Int = 0
    @State private var quizSelection: String? = nil
    @State private var quizAnyWrong: Bool = false   // sticky for the queue
    /// Entry indices we've already quizzed this session — prevents the
    /// inter-pass quiz from firing twice on the same word.
    @State private var quizzedEntryIndices: Set<Int> = []

    /// Currently visible question, if any.
    private var currentQuiz: InterPassQuiz? {
        guard currentQuizQueue.indices.contains(quizQueueIndex) else { return nil }
        return currentQuizQueue[quizQueueIndex]
    }

    /// Resolved practice queue. Each entry is one SRS unit — a single hanzi
    /// or a multi-character word — with its constituent chars looked up in
    /// `store`. Deduped by canonical word key.
    private var practiceEntries: [PracticeEntry] {
        var seen = Set<String>()
        var out: [PracticeEntry] = []
        for word in session.entries {
            guard seen.insert(word).inserted else { continue }
            let chars = word.compactMap { store.character(for: String($0)) }
            // Skip entries where any constituent character is missing from
            // MMA — rare but possible with very obscure hanzi.
            guard chars.count == word.count else { continue }
            out.append(PracticeEntry(word: word, characters: chars))
        }
        return out
    }

    /// User's preferred chunk size, clamped to 1...entries.count so
    /// `.threePass` interleaves passes across small batches instead of
    /// running all of pass 1 before any of pass 2.
    private var chunkSize: Int {
        let raw = settingsList.first?.effectivePracticeChunkSize ?? 3
        let n = practiceEntries.count
        guard n > 0 else { return raw }
        return max(1, min(raw, n))
    }

    /// Pure builder so `onChange(of: practiceMode)` can also compute the
    /// sequence under the *previous* mode and find the entry we were on.
    private func buildSequence(passCount: Int, chunkSize: Int, count: Int)
        -> [(entryIndex: Int, pass: Int)]
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

    /// Which entry we're on within the current chunk/pass.
    private var currentEntryIndex: Int {
        guard !sequence.isEmpty, sequence.indices.contains(min(index, sequence.count - 1)) else { return 0 }
        return sequence[min(index, sequence.count - 1)].entryIndex
    }

    /// Which pass we're on (0..passCount-1). 0 for adaptive mode.
    private var currentPass: Int {
        guard !sequence.isEmpty, sequence.indices.contains(min(index, sequence.count - 1)) else { return 0 }
        return sequence[min(index, sequence.count - 1)].pass
    }

    private var currentEntry: PracticeEntry? {
        practiceEntries.indices.contains(currentEntryIndex) ? practiceEntries[currentEntryIndex] : nil
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
                if practiceEntries.isEmpty {
                    emptyQueueView
                } else {
                    VStack(spacing: 16) {
                        progressHeader
                        if phase == .finished {
                            finishedView
                        } else if phase == .interPassQuiz, let quiz = currentQuiz {
                            interPassQuizView(quiz)
                                .padding(.horizontal, 16)
                        } else if let entry = currentEntry {
                            if isCompactVertical {
                                // Landscape: header + controls in a narrow
                                // left column, canvas claims the rest of
                                // the screen so it actually gets bigger
                                // when the user rotates, not smaller.
                                HStack(alignment: .top, spacing: 14) {
                                    VStack(spacing: 12) {
                                        cardHeader(for: entry)
                                        quickActionsRow(for: entry)
                                        memoryAidCard(for: entry)
                                        Spacer()
                                        controls(for: entry)
                                    }
                                    .frame(width: 240)
                                    canvasRow(for: entry)
                                }
                                .padding(.horizontal, 16)
                            } else {
                                VStack(spacing: 14) {
                                    cardHeader(for: entry)
                                    quickActionsRow(for: entry)
                                    memoryAidCard(for: entry)
                                    canvasRow(for: entry)
                                    controls(for: entry)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                            }
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
                if !practiceEntries.isEmpty {
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
                guard !practiceEntries.isEmpty else { return }
                if sequence.isEmpty {
                    sequence = buildSequence(passCount: practiceMode.passCount,
                                             chunkSize: chunkSize,
                                             count: practiceEntries.count)
                }
                if canvases.isEmpty {
                    rebuildCanvasesForCurrentEntry()
                }
            }
            .onChange(of: index) { _, _ in
                guard !practiceEntries.isEmpty else { return }
                rebuildCanvasesForCurrentEntry()
                phase = .writing
            }
            .onChange(of: practiceMode) { oldValue, _ in
                guard !practiceEntries.isEmpty else { return }
                // Rebuild under the new mode/chunking; locate the entry we
                // were on so the user doesn't get teleported to char 0.
                let priorEntry = sequence.indices.contains(index)
                    ? sequence[index].entryIndex
                    : 0
                let _ = oldValue   // silence unused-arg warning
                sequence = buildSequence(passCount: practiceMode.passCount,
                                         chunkSize: chunkSize,
                                         count: practiceEntries.count)
                if let newIdx = sequence.firstIndex(where: { $0.entryIndex == priorEntry && $0.pass == 0 }) {
                    if index != newIdx {
                        index = newIdx
                    } else {
                        rebuildCanvasesForCurrentEntry()
                    }
                } else {
                    index = 0
                }
            }
            .sheet(isPresented: gradingBinding) {
                if let entry = currentEntry, !canvases.isEmpty {
                    GradingSheet(canvases: canvases,
                                 entry: entry,
                                 onGrade: { grade in
                                     applyGrade(grade, for: entry)
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
            .sheet(item: $peekWord) { w in
                WordDetailSheet(word: w)
                    .presentationDetents([.medium, .large])
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
            Text("There are no entries in this session. Close and add items from the Dictionary or list detail first.")
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
                    Text("\(min(currentEntryIndex + 1, practiceEntries.count)) / \(practiceEntries.count)")
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

    /// Header shown above the writing canvases. For single-char entries
    /// tapping opens that character's detail page; for multi-char entries
    /// it opens the *word* detail sheet (component characters, pinyin,
    /// definition, and an "add to list" picker if the user wants), so
    /// they get the whole-word context rather than being forced to pick
    /// just one character to look up.
    @ViewBuilder
    private func cardHeader(for entry: PracticeEntry) -> some View {
        Button {
            if entry.characters.count > 1 {
                peekWord = wordLookup(entry.word)
                    ?? WordEntry(simplified: entry.word,
                                 traditional: entry.word,
                                 pinyin: entryPinyin(entry),
                                 gloss: entryMeaning(entry))
            } else {
                peekCharacter = entry.characters.first
            }
        } label: {
            cardHeaderContent(for: entry)
        }
        .buttonStyle(.plain)
    }

    /// The visual content of the header — extracted so the Menu/Button
    /// wrappers above don't have to duplicate it.
    @ViewBuilder
    private func cardHeaderContent(for entry: PracticeEntry) -> some View {
        let pinyin = entryPinyin(entry)
        let meaning = entryMeaning(entry)
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(pinyin)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.accent)
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent.opacity(0.6))
            }
            Text(meaning)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let active = canvases.indices.contains(activeCharIndex)
                ? canvases[activeCharIndex] : nil {
                HStack(spacing: 8) {
                    if entry.isWord {
                        Text("Char \(activeCharIndex + 1) of \(entry.characters.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    if active.totalStrokes > 0 {
                        Text("Stroke \(min(active.completedStrokes + 1, active.totalStrokes)) of \(active.totalStrokes)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    hintModePill(active.hintMode)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// Word lookup that consults user-supplied custom entries first, then
    /// CC-CEDICT. So if the user defined 加菲猫 with a custom meaning,
    /// that shows here instead of (or in absence of) any dictionary hit.
    private func wordLookup(_ word: String) -> WordEntry? {
        UserDataController(context: modelContext).lookupWord(word)
    }

    /// Pinyin for the whole entry. Multi-char looks up the unified word
    /// store (custom → CC-CEDICT); single-char uses the MMA per-character
    /// pinyin (which already has tone marks).
    private func entryPinyin(_ entry: PracticeEntry) -> String {
        if entry.isWord, let w = wordLookup(entry.word) {
            return w.pinyin
        }
        return entry.characters.first?.pinyin ?? ""
    }

    /// English meaning for the entry — unified word lookup for multi-char,
    /// MMA definition for single chars.
    private func entryMeaning(_ entry: PracticeEntry) -> String {
        if entry.isWord, let w = wordLookup(entry.word) {
            return w.gloss
        }
        return entry.characters.first?.meaning ?? ""
    }

    /// Inline component-breakdown card. Shown during the *visual-aid*
    /// passes (dots + trace) so the user is building meaning-level
    /// associations while they have a template to look at. Deliberately
    /// hidden during the memory pass — that pass is the user's chance to
    /// recall completely unaided, and showing the breakdown then would
    /// turn it into a spoiler. Also hidden when there's no useful
    /// decomposition.
    ///
    /// Shows three layers when available:
    ///   1. The MMA etymology *hint* (free-form prose like "Depicts a
    ///      person resting under a tree") if the character has one.
    ///   2. Each component with its role badge (Meaning / Sound / Both /
    ///      Part) plus pinyin + first-gloss meaning.
    ///   3. A type pill (Pictographic / Phono-semantic / etc.) so the
    ///      user can pattern-match.
    @ViewBuilder
    private func memoryAidCard(for entry: PracticeEntry) -> some View {
        let activeChar = entry.characters.indices.contains(activeCharIndex)
            ? entry.characters[activeCharIndex] : nil
        let activeMode = canvases.indices.contains(activeCharIndex)
            ? canvases[activeCharIndex].hintMode : nil
        // Transliteration words (加菲猫 = Garfield, 咖啡 = coffee, 纽约 =
        // New York) get a simpler "Transliteration of X" card — the
        // per-character etymology isn't meaningful because the chars
        // were chosen for sound, not meaning.
        if memoryAidShouldShow, activeMode != .memory, entry.isWord,
           let label = transliterationLabel(for: entry) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TRANSLITERATION")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.accentSoft.opacity(0.55))
            )
        } else if memoryAidShouldShow, activeMode != .memory, let c = activeChar {
            let etymology = c.etymology
            let parts = componentBreakdown(for: c)
            // Only render the card if there's *something* to say.
            if etymology?.hint != nil
                || (parts != nil && !(parts!.isEmpty))
                || c.mnemonic != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("BUILD ASSOCIATIONS")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let ety = etymology {
                            Text(ety.type.displayName.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.accent))
                        }
                    }
                    if let hint = etymology?.hint, !hint.isEmpty {
                        Text(hint)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let mnemonic = c.mnemonic, !mnemonic.isEmpty {
                        Text(mnemonic)
                            .font(.system(size: 12, weight: .medium))
                            .italic()
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let parts, !parts.isEmpty {
                        if memoryAidCompact {
                            // Full-size mode: collapse the grid into a
                            // one-line "口 (mouth) · 乞 (beg)" summary so
                            // the canvas below still fits on screen.
                            Text(parts.map { compactPart($0) }.joined(separator: "  ·  "))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                                    VStack(spacing: 3) {
                                        Text(part.char)
                                            .font(Theme.hanzi(22))
                                            .foregroundStyle(Theme.accent)
                                        if !part.roleLabel.isEmpty {
                                            Text(part.roleLabel.uppercased())
                                                .font(.system(size: 8, weight: .bold))
                                                .tracking(0.5)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(part.roleColor))
                                        }
                                        if !part.pinyin.isEmpty {
                                            Text(part.pinyin)
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(Theme.accent)
                                        }
                                        if !part.meaning.isEmpty {
                                            Text(part.meaning)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                                .minimumScaleFactor(0.6)
                                                .multilineTextAlignment(.center)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .top)
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accentSoft.opacity(0.55))
                )
            }
        }
    }

    /// Compact one-line representation of a component for the Full-size
    /// memory-aid layout: "口 (mouth)" / "乞 (beg, qǐ)".
    private func compactPart(_ part: ComponentBreakdownItem) -> String {
        var bits: [String] = []
        if !part.meaning.isEmpty { bits.append(part.meaning) }
        if !part.pinyin.isEmpty  { bits.append(part.pinyin) }
        let suffix = bits.isEmpty ? "" : " (\(bits.joined(separator: ", ")))"
        return "\(part.char)\(suffix)"
    }

    /// Detect "transliteration / loanword" multi-character words —
    /// 加菲猫 (Garfield), 咖啡 (coffee), 纽约 (New York) etc. Returns
    /// a short user-facing label when matched, nil otherwise.
    ///
    /// Heuristics (all checked against the CC-CEDICT gloss):
    ///   1. gloss contains "(loanword)" — explicit tag
    ///   2. first definition starts with a capital letter — proper
    ///      noun translation
    ///   3. gloss starts with "abbr." pointing at another phonetic
    ///      transliteration
    private func transliterationLabel(for entry: PracticeEntry) -> String? {
        guard let w = wordLookup(entry.word) else {
            return nil
        }
        let lower = w.gloss.lowercased()
        // Some characters are pure phono-loaner glyphs (you'll basically
        // only ever see them in transliterations): 咖, 啡, 啦, 玛, 菲,
        // 纽, 顿 etc. Skip the heuristic for words made entirely of
        // common chars — they're more likely real compounds.
        let phonoLoanChars: Set<Character> = [
            "咖", "啡", "啦", "玛", "菲", "纽", "顿", "莎", "斯", "尔",
            "巴", "佛", "罗", "伦", "瑞", "丹", "兰", "贝", "桑", "塔",
            "拉", "维", "勒", "克", "莱", "蒂", "卡", "诺", "默", "亨",
            "杰", "麦", "萨", "霍", "弗"
        ]
        let containsPhonoChar = entry.word.contains(where: { phonoLoanChars.contains($0) })
        if lower.contains("(loanword)") || lower.contains("loanword)") {
            return "Loanword / transliteration of '\(w.firstGloss)'"
        }
        let firstDef = (w.gloss.split(whereSeparator: { ";/".contains($0) })
                              .first?.trimmingCharacters(in: .whitespaces)) ?? w.gloss
        if let firstChar = firstDef.unicodeScalars.first,
           firstChar.properties.isUppercase {
            // Proper noun — likely a place / person / brand transliteration.
            // Only flag if we've got at least one phono-loan char OR the
            // word is short (most transliterations are 2-3 chars).
            if containsPhonoChar || entry.word.count <= 4 {
                return "Transliteration of '\(firstDef)'"
            }
        }
        return nil
    }

    /// Resolve the per-component breakdown for `c`. Uses the already-parsed
    /// etymology when available (preserves the semantic / phonetic role
    /// info from MMA) so we can show role badges like "Meaning" / "Sound".
    /// Returns nil if the character has no useful etymology data.
    private func componentBreakdown(for c: HanziCharacter)
        -> [ComponentBreakdownItem]?
    {
        guard let etymology = c.etymology else { return nil }
        // Defensive: drop any component that points back at the host
        // character itself (compare both canonical and displayed forms).
        // The makeEtymology pipeline already filters, but a stale MMA
        // entry or variant pair can still slip through.
        let filtered = etymology.components.filter {
            $0.char != c.char && $0.char != c.canonicalID
        }
        guard !filtered.isEmpty else { return nil }
        return filtered.map { comp in
            let resolved = store.character(for: comp.char)
            return ComponentBreakdownItem(
                char: store.displayed(comp.char),
                pinyin: resolved?.pinyin ?? "",
                meaning: resolved?.meaning.firstPart ?? "",
                roleLabel: comp.roleLabel,
                roleColor: ComponentBreakdownItem.color(for: comp.role)
            )
        }
    }

    /// Display tuple for the memory-aid card. Mirrors EtymologyComponent
    /// fields with the role flattened into a label + colour so the row
    /// renderer doesn't need to know about the Role enum.
    private struct ComponentBreakdownItem {
        let char: String
        let pinyin: String
        let meaning: String
        let roleLabel: String
        let roleColor: Color

        static func color(for role: EtymologyComponent.Role) -> Color {
            switch role {
            case .semantic:  return Theme.accent
            case .phonetic:  return Color(hex: 0x6789C2)
            case .both:      return Color(hex: 0xC9A13C)
            case .component: return Color.secondary
            }
        }
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

    /// Toolbar menu lets the user choose the session-level practice mode,
    /// the multi-character layout (direction + canvas fit), and — in
    /// adaptive mode only — pin the hint level for the current entry.
    /// Layout choices mirror the Profile settings; changing them here
    /// writes through to the same UserSettings row, so the preference
    /// sticks across sessions.
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
            // Always available so the user doesn't have to back out of a
            // single-character session just to set a preference that'll
            // apply to the next multi-char one. (The pickers are no-ops
            // for the current single-char session but persist for later.)
            Section("Layout (multi-character)") {
                Picker("Direction", selection: writingDirectionBinding) {
                    ForEach(WritingDirection.allCases) { d in
                        Text(d.displayName).tag(d)
                    }
                }
                Picker("Canvas size", selection: canvasFitBinding) {
                    ForEach(PracticeCanvasFit.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
            }
            if practiceMode == .adaptive {
                Section("Hint level (this entry)") {
                    Picker("Hint level", selection: hintModeBinding) {
                        ForEach(WritingHintMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.systemImage)
                                .tag(Optional(mode))
                        }
                        Label("Auto", systemImage: "wand.and.stars")
                            .tag(Optional<WritingHintMode>.none)
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(Theme.accent)
        }
    }

    /// Live binding to the user's writing-direction preference. Writes go
    /// straight to the active `UserSettings` row so the change persists.
    private var writingDirectionBinding: Binding<WritingDirection> {
        Binding(
            get: { settingsList.first?.effectiveWritingDirection ?? .horizontal },
            set: { settingsList.first?.writingDirectionRaw = $0.rawValue }
        )
    }

    private var canvasFitBinding: Binding<PracticeCanvasFit> {
        Binding(
            get: { settingsList.first?.effectivePracticeCanvasFit ?? .fit },
            set: { settingsList.first?.practiceCanvasFitRaw = $0.rawValue }
        )
    }

    /// Two-way binding so the hint-level picker reflects whatever's actually
    /// driving the canvas right now — explicit override or auto-derived.
    private var hintModeBinding: Binding<WritingHintMode?> {
        Binding(
            get: { hintModeOverride },
            set: { newValue in
                hintModeOverride = newValue
                if let entry = currentEntry {
                    let mode = newValue ?? defaultHintMode(forKey: entry.word)
                    for i in canvases.indices { canvases[i].hintMode = mode }
                }
            }
        )
    }

    /// Picks the hint level for the current entry. Three-pass mode is
    /// authoritative — each pass has a fixed level. Adaptive mode falls back
    /// to the *entry's* SRS mastery (so a known word stays easy even if its
    /// constituent characters were studied separately).
    private func defaultHintMode(forKey key: String) -> WritingHintMode {
        if let pinned = hintModeOverride { return pinned }
        if practiceMode == .threePass {
            switch currentPass {
            case 0:  return .traceWithArrow
            case 1:  return .trace
            default: return .memory
            }
        }
        let card = UserDataController(context: modelContext).card(for: key)
        let mastery = card?.mastery ?? 0
        return mastery >= 0.6 ? .memory : .trace
    }

    /// Lay out the canvases for the current entry per the user's settings:
    ///   * `horizontal + fit` → an HStack that shrinks to fit (was the
    ///     Phase B default).
    ///   * `horizontal + full` → a paged horizontal ScrollView with one
    ///     full-size canvas per page; scroll/swipe between them.
    ///   * `vertical + fit`   → a VStack of canvases, each shrunk
    ///     vertically to fit alongside the rest.
    ///   * `vertical + full`  → a vertical ScrollView; scroll down to
    ///     reach the next char.
    @ViewBuilder
    private func canvasRow(for entry: PracticeEntry) -> some View {
        if canvases.isEmpty {
            Color.clear.aspectRatio(1, contentMode: .fit)
        } else if canvases.count == 1 {
            // Fast path for the (very common) single-character entry.
            // Resize controls only meaningful in Full-size mode (in Fit
            // mode the canvas already fills the available space).
            singleCanvas(canvases[0], index: 0)
                .frame(maxWidth: liveCappedSide,
                       maxHeight: liveCappedSide)
                .frame(maxWidth: .infinity)
                .modifier(ResizableCanvasModifier(enabled: resizeAffordanceEnabled,
                                                  handle: canvasResizeHandle,
                                                  gesture: canvasPinchGesture))
        } else {
            // Multi-char layout — same direction/fit switch as before.
            // Resize handle only in Full-size scroll mode (Fit mode
            // already fills the screen; resizing it makes no sense).
            multiCanvasLayout
                .modifier(ResizableCanvasModifier(enabled: resizeAffordanceEnabled,
                                                  handle: canvasResizeHandle,
                                                  gesture: canvasPinchGesture))
        }
    }

    /// Resize affordance (pinch + bottom-right handle) is only useful in
    /// Full-size mode — in Fit mode the canvas auto-fills the screen so
    /// shrinking the cap doesn't change anything visible. Hidden in Fit
    /// mode keeps the screen clean.
    private var resizeAffordanceEnabled: Bool {
        (settingsList.first?.effectivePracticeCanvasFit ?? .fit) == .full
    }

    /// The actual multi-character canvas group. Switches between HStack/
    /// VStack and fit/scroll based on the user's settings.
    @ViewBuilder
    private var multiCanvasLayout: some View {
        let direction = settingsList.first?.effectiveWritingDirection ?? .horizontal
        let fit = settingsList.first?.effectivePracticeCanvasFit ?? .fit
        switch (direction, fit) {
        case (.horizontal, .fit):
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(canvases.enumerated()), id: \.offset) { idx, model in
                    singleCanvas(model, index: idx)
                }
            }
            .padding(.horizontal, 8)
        case (.horizontal, .full):
            fullSizeScroll(axis: .horizontal)
        case (.vertical, .fit):
            VStack(spacing: 8) {
                ForEach(Array(canvases.enumerated()), id: \.offset) { idx, model in
                    singleCanvas(model, index: idx)
                }
            }
            .padding(.horizontal, 8)
        case (.vertical, .full):
            fullSizeScroll(axis: .vertical)
        }
    }

    /// Build-associations card is always rendered; it's the layout
    /// inside the card that adapts. In Full-size mode we collapse the
    /// card to just its header + hint (one line) so the canvas below
    /// stays reachable. In Fit mode it shows the full component grid.
    private var memoryAidShouldShow: Bool { true }

    /// True when we should render the compact (Full-size-friendly)
    /// version of the build-associations card.
    private var memoryAidCompact: Bool {
        (settingsList.first?.effectivePracticeCanvasFit ?? .fit) == .full
    }

    /// Hard cap applied to each canvas in the *multi-character* full-size
    /// layouts so the in-session pinch / drag-handle actually changes the
    /// canvas size (the single-canvas fast path applies the cap directly).
    /// In Fit mode this is just `.infinity` so canvases shrink to fit.
    private var multiCanvasSideCap: CGFloat {
        let fit = settingsList.first?.effectivePracticeCanvasFit ?? .fit
        return fit == .full ? liveCappedSide : .infinity
    }

    /// Scroll-paged layout used in "Full size" mode. Each canvas is laid
    /// out at its natural square size and the user scrolls/swipes between
    /// them. The active canvas is auto-scrolled into view as it changes so
    /// the user doesn't have to chase it.
    @ViewBuilder
    private func fullSizeScroll(axis: Axis) -> some View {
        let cap = multiCanvasSideCap
        ScrollViewReader { proxy in
            ScrollView(axis == .horizontal ? .horizontal : .vertical,
                       showsIndicators: false) {
                if axis == .horizontal {
                    LazyHStack(spacing: 16) {
                        ForEach(Array(canvases.enumerated()), id: \.offset) { idx, model in
                            singleCanvas(model, index: idx)
                                .frame(maxWidth: cap, maxHeight: cap)
                                .containerRelativeFrame(.horizontal)
                                .id(idx)
                        }
                    }
                    .scrollTargetLayout()
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(Array(canvases.enumerated()), id: \.offset) { idx, model in
                            singleCanvas(model, index: idx)
                                .frame(maxWidth: cap, maxHeight: cap)
                                .containerRelativeFrame(.horizontal)
                                .id(idx)
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            .scrollTargetBehavior(.viewAligned)
            .onChange(of: activeCharIndex) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// One canvas in the row, with the tap-to-activate behaviour, the
    /// long-press "I know this character" menu, and the stroke-completion
    /// callback that drives the per-entry advance state machine.
    @ViewBuilder
    private func singleCanvas(_ model: WritingCanvasModel, index idx: Int) -> some View {
        let isActive = idx == activeCharIndex
        let isKnown = knownCanvases.contains(idx)
        WritingCanvas(model: model) { _ in
            // Stroke accepted. If this canvas has now completed all its
            // strokes, advance within (or past) the entry. Delay slightly
            // so the user sees the accepted-stroke flash.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                handleStrokeAccepted(forCanvasAt: idx)
            }
        }
        .opacity(isKnown ? 0.35 : (isActive ? 1 : 0.55))
        .allowsHitTesting(isActive && !isKnown)
        .overlay(alignment: .topLeading) {
            if canvases.count > 1 {
                HStack(spacing: 4) {
                    Text("\(idx + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(isActive ? Theme.accent : Color.secondary))
                    if isKnown {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap an inactive canvas to re-focus it (unless it's marked
            // as known — that one just stays out of the way).
            if idx != activeCharIndex && !isKnown {
                activeCharIndex = idx
            }
        }
        .contextMenu {
            // Long-press menu — only meaningful for multi-char entries,
            // so we hide it for single-char sessions.
            if canvases.count > 1 {
                if isKnown {
                    Button {
                        knownCanvases.remove(idx)
                    } label: {
                        Label("Don't skip this character", systemImage: "arrow.uturn.backward")
                    }
                } else if let entry = currentEntry,
                          entry.characters.indices.contains(idx) {
                    Button {
                        markCharacterKnown(at: idx)
                    } label: {
                        Label("I know \(entry.characters[idx].char)",
                              systemImage: "checkmark.circle")
                    }
                    Button {
                        if idx != activeCharIndex { activeCharIndex = idx }
                    } label: {
                        Label("Focus on this character", systemImage: "scope")
                    }
                }
            }
        }
    }

    /// Called by the WritingCanvas after each accepted stroke. Decides
    /// whether to stay (more strokes to go for this char), advance the
    /// active char index (this char done, move to the next char in word),
    /// or transition to grading / advance the sequence (word done).
    private func handleStrokeAccepted(forCanvasAt idx: Int) {
        guard idx == activeCharIndex,
              canvases.indices.contains(idx) else { return }
        let model = canvases[idx]
        let charDone = model.totalStrokes > 0
            && model.completedStrokes >= model.totalStrokes
        guard charDone else { return }    // more strokes to go on this char
        advanceWithinEntry()
    }

    /// Move `activeCharIndex` to the next non-known canvas in the current
    /// entry; if there isn't one, either trigger grading (final pass) or
    /// advance the outer sequence to the next entry / pass.
    private func advanceWithinEntry() {
        var next = activeCharIndex + 1
        while next < canvases.count && knownCanvases.contains(next) {
            next += 1
        }
        if next < canvases.count {
            activeCharIndex = next
        } else if isGradingStep {
            phase = .grading
        } else {
            advance()
        }
    }

    /// User long-pressed a canvas and chose "I know this character". Apply
    /// `.easy` to that character's own SRS card, mark its canvas dim+done,
    /// and skip past it during auto-advance. The word's overall grade
    /// happens later as usual; in that grade, this canvas counts as 100%
    /// accuracy and the WORD's grade isn't propagated to *this* character
    /// (the easy grade we just applied is more informed).
    private func markCharacterKnown(at idx: Int) {
        guard let entry = currentEntry,
              entry.characters.indices.contains(idx) else { return }
        let char = entry.characters[idx]
        let controller = UserDataController(context: modelContext)
        let card = controller.ensureCard(for: char.id)
        SRSEngine.apply(grade: .easy, to: card)
        try? modelContext.save()
        knownCanvases.insert(idx)
        if idx == activeCharIndex {
            advanceWithinEntry()
        }
    }

    private func controls(for entry: PracticeEntry) -> some View {
        HStack(spacing: 10) {
            Button {
                if canvases.indices.contains(activeCharIndex) {
                    canvases[activeCharIndex].playDemonstration()
                }
            } label: {
                controlLabel(systemImage: "eye", title: "Show stroke")
            }
            Button {
                resetActiveCanvas(for: entry)
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
                // "Grade" (not "Finish") — the toolbar has its own "Finish"
                // for ending the whole session.
                controlLabel(systemImage: isGradingStep ? "checkmark.seal" : "arrow.right",
                             title: isGradingStep ? "Grade" : "Next pass")
            }
            .disabled(noStrokeYet)
        }
    }

    /// True when none of the entry's canvases have any strokes drawn yet —
    /// the "Grade" / "Next pass" button stays disabled until the user has
    /// at least started writing.
    private var noStrokeYet: Bool {
        canvases.allSatisfy { $0.completedStrokes == 0 }
    }

    private func resetActiveCanvas(for entry: PracticeEntry) {
        guard let key = currentEntry?.word,
              canvases.indices.contains(activeCharIndex),
              entry.characters.indices.contains(activeCharIndex) else { return }
        canvases[activeCharIndex] = WritingCanvasModel(
            character: entry.characters[activeCharIndex],
            hintMode: defaultHintMode(forKey: key)
        )
    }

    /// Two small chip buttons for "I already know this" (mark mastered, skip
    /// all remaining passes for this *entry*) and "Skip for now" (move on
    /// without touching SRS state so the entry stays due).
    private func quickActionsRow(for entry: PracticeEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                markKnown(entry)
            } label: {
                quickActionChip(systemImage: "checkmark.circle",
                                title: "I know this",
                                tint: Theme.accent)
            }
            Button {
                skipEntry()
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

    /// User claims to already know the entry — grade it as `.easy` without
    /// writing, then drop it from the remainder of the session. No practice
    /// record is created since there's no real attempt.
    private func markKnown(_ entry: PracticeEntry) {
        let controller = UserDataController(context: modelContext)
        let card = controller.ensureCard(for: entry.word)
        SRSEngine.apply(grade: .easy, to: card)
        try? modelContext.save()
        sessionResults[entry.word] = 1.0
        dropCurrentEntry()
    }

    /// Move past the current entry entirely without touching its SRS state —
    /// it stays due, so it'll re-appear in a future session.
    private func skipEntry() {
        dropCurrentEntry()
    }

    /// Mark the current entry as "skipped" and jump to the next visible
    /// step. All remaining passes for this entry will be silently stepped
    /// over by `advanceToNextVisible()`.
    private func dropCurrentEntry() {
        guard !sequence.isEmpty else { phase = .finished; return }
        skippedEntries.insert(currentEntryIndex)
        advanceToNextVisible()
    }

    /// Build fresh `WritingCanvasModel`s for the current entry's characters
    /// using the appropriate hint mode for this pass. Called whenever the
    /// active entry changes or the user resets / changes mode.
    private func rebuildCanvasesForCurrentEntry() {
        guard let entry = currentEntry else {
            canvases = []
            return
        }
        let mode = defaultHintMode(forKey: entry.word)
        canvases = entry.characters.map { char in
            WritingCanvasModel(character: char, hintMode: mode)
        }
        // Persist known-canvas marks across the 3-pass drill — re-marking
        // "I know 冰" every pass would be annoying. Only reset when the
        // entry index actually changes.
        if knownCanvasesEntryIdx != currentEntryIndex {
            knownCanvases = []
            knownCanvasesEntryIdx = currentEntryIndex
        }
        // Skip to the first canvas that isn't marked known.
        var first = 0
        while first < canvases.count && knownCanvases.contains(first) {
            first += 1
        }
        activeCharIndex = min(first, max(0, canvases.count - 1))
    }

    /// Step `index` forward until it lands on a sequence step whose entry
    /// hasn't been skipped. Used by every advance path so a dropped entry
    /// can't sneak back in on a later pass.
    private func advanceToNextVisible() {
        guard !sequence.isEmpty else { phase = .finished; return }
        var newIndex = index + 1
        while newIndex < sequence.count {
            if !skippedEntries.contains(sequence[newIndex].entryIndex) {
                break
            }
            newIndex += 1
        }
        if newIndex >= sequence.count {
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
        let total = practiceEntries.count
        let remaining = max(0, total - practised)
        let avg: Double = sessionResults.isEmpty ? 0
            : sessionResults.values.reduce(0, +) / Double(sessionResults.count)
        let duration = Int(Date.now.timeIntervalSince(sessionStarted))
        let finishedEarly = practised < total
        let unit = practiceEntries.contains(where: { $0.isWord }) ? "entries" : "characters"
        return VStack(spacing: 18) {
            Image(systemName: finishedEarly
                  ? "pause.circle.fill" : "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text(finishedEarly ? "Stopped early" : "Session complete!")
                .font(.system(size: 24, weight: .bold))
            VStack(spacing: 6) {
                Text("\(practised) of \(total) \(unit) practised")
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

    /// Grade the current entry as a *single SRS unit* keyed by its word.
    /// Accuracy / retries are averaged across all canvases so a slip on any
    /// constituent character still penalises the word.
    ///
    /// For multi-character words we *also* propagate the grade to each
    /// constituent character's SRS card — if you can write 容易, the system
    /// trusts you can write 容 and 易 individually. We deliberately don't
    /// do this for reading/translation modes (Phase C): knowing a word's
    /// pronunciation or meaning doesn't always imply the char in isolation.
    ///
    /// "Again" re-queues the entry at the end of the in-session sequence
    /// (Anki-style relearning queue) so the user keeps seeing the slipped
    /// character until they grade it Hard or better.
    private func applyGrade(_ grade: SRSGrade, for entry: PracticeEntry) {
        let controller = UserDataController(context: modelContext)
        let card = controller.ensureCard(for: entry.word)
        SRSEngine.apply(grade: grade, to: card)

        if entry.isWord {
            // Propagate the word grade only to chars the user *actually
            // wrote* this session. Characters they marked as already
            // known got an `.easy` grade applied directly at the
            // long-press; we don't want to clobber that with a possibly
            // lower word-level grade just because they slipped on the
            // other chars.
            for (idx, char) in entry.characters.enumerated()
                where char.id != entry.word && !knownCanvases.contains(idx) {
                let charCard = controller.ensureCard(for: char.id)
                SRSEngine.apply(grade: grade, to: charCard)
            }
        }

        // Per-canvas accuracy. Skipped (known) canvases count as 100% so
        // they don't drag the word average down.
        let canvasAccuracies: [Double] = canvases.enumerated().map { idx, canvas in
            knownCanvases.contains(idx) ? 1.0 : canvas.averageAccuracy
        }
        let count = max(1, canvasAccuracies.count)
        let avgAccuracy = canvasAccuracies.reduce(0, +) / Double(count)
        let totalRetries = canvases.enumerated()
            .filter { !knownCanvases.contains($0.offset) }
            .map { $0.element.totalRetries }
            .reduce(0, +)
        let totalDuration = canvases.enumerated()
            .filter { !knownCanvases.contains($0.offset) }
            .map { $0.element.elapsedSeconds }
            .reduce(0, +)
        controller.recordPractice(characterID: entry.word,
                                  accuracy: avgAccuracy,
                                  retries: totalRetries,
                                  duration: totalDuration,
                                  kind: "writing")

        sessionResults[entry.word] = avgAccuracy

        if grade == .again {
            // Re-queue this entry at the end of the session so it comes
            // back after the rest. Mark with the final pass (so it's a
            // grading step when the user reaches it again, not a warmup).
            let entryIdx = currentEntryIndex
            sequence.append((entryIndex: entryIdx,
                             pass: practiceMode.passCount - 1))
        }

        advance()
    }

    /// Move forward by one step, honouring `skippedEntries` so a dropped
    /// entry can't reappear on its next pass. If the user has enabled the
    /// inter-pass quiz AND we're transitioning into pass 1 of an entry we
    /// haven't quizzed yet, intercept with a multiple-choice question set.
    private func advance() {
        guard totalSteps > 0 else {
            phase = .finished
            return
        }
        let quiz = generateInterPassQuizIfNeeded()
        if !quiz.isEmpty {
            currentQuizQueue = quiz
            quizQueueIndex = 0
            quizSelection = nil
            quizAnyWrong = false
            phase = .interPassQuiz
            return
        }
        advanceToNextVisible()
    }

    /// Decide whether to inject a quiz set between the current pass and
    /// the next. Fires once per entry, right before that entry's *trace*
    /// pass (pass 1) starts. Returns the full queue of questions for the
    /// entry — meaning, pinyin, and (when the etymology is available) a
    /// component question — all of which the user must answer correctly
    /// to advance.
    private func generateInterPassQuizIfNeeded() -> [InterPassQuiz] {
        let enabled = settingsList.first?.interPassQuizEnabled ?? false
        guard enabled,
              practiceMode == .threePass,
              !sequence.isEmpty,
              index + 1 < sequence.count else { return [] }
        let next = sequence[index + 1]
        guard next.pass == 1,
              !quizzedEntryIndices.contains(next.entryIndex),
              practiceEntries.indices.contains(next.entryIndex)
        else { return [] }
        let entry = practiceEntries[next.entryIndex]
        let here = sequence[index]    // for parity in makeQuiz signature
        // Build the question queue: meaning + pinyin always, plus a
        // component question for single-char entries with etymology
        // data. Anything missing source data is just skipped.
        let correctMeaning = entryMeaning(entry).firstPart
        let correctPinyin = entryPinyin(entry)
        var queue: [InterPassQuiz] = []
        if !correctMeaning.isEmpty {
            queue.append(makeQuiz(.meaning, entry: entry,
                                  here: here, next: next,
                                  correct: correctMeaning))
        }
        if !correctPinyin.isEmpty {
            queue.append(makeQuiz(.pinyin, entry: entry,
                                  here: here, next: next,
                                  correct: correctPinyin))
        }
        if let componentQuiz = makeComponentQuizIfPossible(entry: entry,
                                                            here: here,
                                                            next: next) {
            queue.append(componentQuiz)
        }
        return queue
    }

    private func makeQuiz(_ kind: InterPassQuiz.Kind,
                          entry: PracticeEntry,
                          here: (entryIndex: Int, pass: Int),
                          next: (entryIndex: Int, pass: Int),
                          correct: String) -> InterPassQuiz {
        let prompt: String = {
            let word = entry.word
            switch kind {
            case .meaning:   return "What does \(word) mean?"
            case .pinyin:    return "How is \(word) pronounced?"
            case .component: return "Which is a component of \(word)?"
            }
        }()
        let options = quizDistractors(for: kind, correct: correct,
                                      excludingEntry: entry)
        return InterPassQuiz(entryIndex: here.entryIndex,
                             fromPass: here.pass,
                             toPass: next.pass,
                             kind: kind,
                             prompt: prompt,
                             correct: correct,
                             options: options)
    }

    /// Component question — only emitted when the active character has
    /// useful etymology data. Multi-char words get this for their first
    /// character (the user is still building radical familiarity even
    /// when learning whole words).
    private func makeComponentQuizIfPossible(entry: PracticeEntry,
                                              here: (entryIndex: Int, pass: Int),
                                              next: (entryIndex: Int, pass: Int))
        -> InterPassQuiz?
    {
        // For multi-char, pick the first char with an etymology.
        let candidates = entry.characters
        guard let host = candidates.first(where: { c in
            (c.etymology?.components.contains { $0.char != c.char && $0.char != c.canonicalID })
                ?? false
        }) else { return nil }
        let components = host.etymology?.components.filter {
            $0.char != host.char && $0.char != host.canonicalID
        } ?? []
        guard let correct = components.randomElement()?.char else { return nil }
        let prompt = "Which is a component of \(host.char)?"
        let options = componentDistractors(correct: correct,
                                            host: host,
                                            session: practiceEntries)
        return InterPassQuiz(entryIndex: here.entryIndex,
                             fromPass: here.pass,
                             toPass: next.pass,
                             kind: .component,
                             prompt: prompt,
                             correct: correct,
                             options: options)
    }

    /// Distractors for the component question — pull from a small set of
    /// common radicals that aren't components of the host character.
    private func componentDistractors(correct: String,
                                       host: HanziCharacter,
                                       session: [PracticeEntry]) -> [String] {
        let hostComponents = Set((host.etymology?.components.map(\.char)) ?? [])
        // Curated common-radical pool — frequently-occurring radicals
        // across HSK 1-3 so the distractors look plausible.
        let pool = ["口", "心", "月", "日", "木", "火", "水", "人",
                    "女", "子", "大", "小", "土", "金", "言", "马",
                    "门", "山", "石", "目", "手", "刀", "力", "云"]
        let distractors = pool.filter { !hostComponents.contains($0) && $0 != correct }
            .shuffled()
            .prefix(3)
        var options = Array(distractors) + [correct]
        while options.count < 4 {
            options.append("—")
        }
        return options.shuffled()
    }

    /// Three random distractors plus the correct answer, shuffled. Pulls
    /// from the rest of the session's entries first (contextually closest);
    /// falls back to padding when the session is too small.
    private func quizDistractors(for kind: InterPassQuiz.Kind,
                                  correct: String,
                                  excludingEntry entry: PracticeEntry) -> [String] {
        // .component has its own dedicated distractor pool — handle
        // separately below. This routine is for meaning / pinyin.
        var pool: [String] = []
        for other in practiceEntries where other.word != entry.word {
            let value: String = {
                switch kind {
                case .meaning:   return entryMeaning(other).firstPart
                case .pinyin:    return entryPinyin(other)
                case .component: return ""  // never used for components
                }
            }()
            if !value.isEmpty && value != correct {
                pool.append(value)
            }
        }
        // Dedupe while preserving order, then shuffle and take 3.
        var seen = Set<String>([correct])
        let distractors = pool.filter { seen.insert($0).inserted }
            .shuffled()
            .prefix(3)
        var options = Array(distractors) + [correct]
        // Pad if the session was tiny.
        while options.count < 4 {
            options.append("—")
        }
        return options.shuffled()
    }

    /// View shown when `phase == .interPassQuiz`. Multiple-choice
    /// question with reveal-and-continue logic. Within the queue, each
    /// question is answered one at a time; wrong answers are remembered
    /// but the user still proceeds through the rest, so they see the
    /// reveal for each. After the last question they either advance
    /// (all correct) or redo the pass (any wrong).
    @ViewBuilder
    private func interPassQuizView(_ quiz: InterPassQuiz) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text("QUICK CHECK")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                if currentQuizQueue.count > 1 {
                    Text("\(quizQueueIndex + 1) / \(currentQuizQueue.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(quiz.prompt)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            ForEach(quiz.options, id: \.self) { option in
                quizOptionButton(quiz: quiz, option: option)
            }
            if quizSelection != nil {
                let isLast = quizQueueIndex >= currentQuizQueue.count - 1
                let wasCorrect = quizSelection == quiz.correct
                VStack(spacing: 8) {
                    if !wasCorrect {
                        Text("Correct: \(quiz.correct)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Button {
                        if isLast {
                            commitQuizSet()
                        } else {
                            advanceWithinQuizQueue()
                        }
                    } label: {
                        Text(isLast
                             ? (quizAnyWrong ? "Redo this pass" : "Continue")
                             : "Next question")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(isLast && quizAnyWrong ? Theme.warning : Theme.accent)
                            )
                    }
                }
                .padding(.top, 8)
            }
            Spacer()
        }
        .padding(.top, 12)
    }

    /// Advance to the next question in the current quiz queue.
    private func advanceWithinQuizQueue() {
        if quizSelection != currentQuiz?.correct {
            quizAnyWrong = true
        }
        quizQueueIndex += 1
        quizSelection = nil
    }

    /// All questions in the queue have been answered. Either advance the
    /// pass (all correct) or restart the pass (any wrong).
    private func commitQuizSet() {
        if quizSelection != currentQuiz?.correct {
            quizAnyWrong = true
        }
        let anyWrong = quizAnyWrong
        if let q = currentQuizQueue.first {
            quizzedEntryIndices.insert(q.entryIndex)
        }
        currentQuizQueue = []
        quizQueueIndex = 0
        quizSelection = nil
        quizAnyWrong = false
        if anyWrong {
            rebuildCanvasesForCurrentEntry()
            phase = .writing
        } else {
            advanceToNextVisible()
        }
    }

    private func quizOptionButton(quiz: InterPassQuiz, option: String) -> some View {
        let answered = quizSelection != nil
        let isCorrect = option == quiz.correct
        let isChosen = option == quizSelection
        let bg: Color = {
            guard answered else { return Theme.card }
            if isCorrect { return Theme.accent.opacity(0.85) }
            if isChosen  { return Theme.warning.opacity(0.85) }
            return Theme.card
        }()
        let fg: Color = (answered && (isCorrect || isChosen))
            ? .white : .primary
        return Button {
            guard quizSelection == nil else { return }
            quizSelection = option
        } label: {
            HStack {
                Text(option)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(fg)
                    .multilineTextAlignment(.leading)
                Spacer()
                if answered, isCorrect {
                    Image(systemName: "checkmark").foregroundStyle(.white)
                } else if answered, isChosen {
                    Image(systemName: "xmark").foregroundStyle(.white)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(bg)
            )
        }
        .buttonStyle(.plain)
        .disabled(answered)
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
    /// One canvas per character in the entry being graded.
    let canvases: [WritingCanvasModel]
    /// The whole entry — used to display the word, pinyin, meaning, and to
    /// fetch the entry's SRS card for the "Again / Hard / Good / Easy"
    /// preview-interval labels.
    let entry: PracticeEntry
    let onGrade: (SRSGrade) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(CharacterStore.self) private var store
    @State private var card: SRSCard?
    /// Character to peek at — set when the header is tapped for a
    /// single-character entry.
    @State private var peekChar: HanziCharacter? = nil
    /// Word to peek at — set when the header is tapped for a
    /// multi-character entry. Opens the word detail sheet.
    @State private var peekWord: WordEntry? = nil

    /// Averaged accuracy across every char's canvas. Used by the SRS card
    /// preview-interval display and as the "this attempt" headline number.
    private var averageAccuracy: Double {
        guard !canvases.isEmpty else { return 0 }
        return canvases.map(\.averageAccuracy).reduce(0, +) / Double(canvases.count)
    }

    private var pinyin: String {
        if entry.isWord,
           let w = UserDataController(context: modelContext).lookupWord(entry.word) {
            return w.pinyin
        }
        return entry.characters.first?.pinyin ?? ""
    }

    private var meaning: String {
        if entry.isWord,
           let w = UserDataController(context: modelContext).lookupWord(entry.word) {
            return w.gloss
        }
        return entry.characters.first?.meaning ?? ""
    }

    var body: some View {
        // The system drag indicator is enabled at the .sheet call site, so
        // we don't draw our own — that produced two stacked indicators.
        VStack(spacing: 16) {
            headerContent
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
            card = UserDataController(context: modelContext).ensureCard(for: entry.word)
        }
        .sheet(item: $peekChar) { c in
            NavigationStack {
                CharacterDetailView(character: c)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { peekChar = nil }
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $peekWord) { w in
            WordDetailSheet(word: w)
                .presentationDetents([.medium, .large])
        }
    }

    /// Header content. Single-char entries open the character detail
    /// directly; multi-char entries open the word detail sheet so the
    /// user gets pinyin, definition, and a list of the component chars
    /// (each tappable to its own detail page).
    @ViewBuilder
    private var headerContent: some View {
        Button {
            if entry.characters.count > 1 {
                peekWord = UserDataController(context: modelContext).lookupWord(entry.word)
                    ?? WordEntry(simplified: entry.word,
                                 traditional: entry.word,
                                 pinyin: pinyin,
                                 gloss: meaning)
            } else {
                peekChar = entry.characters.first
            }
        } label: {
            headerRow
        }
        .buttonStyle(.plain)
    }

    /// The visible row content inside the header — extracted so the Menu /
    /// Button wrappers above can both render it.
    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(store.displayedWord(entry.word))
                .font(Theme.hanzi(36))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(pinyin)
                        .font(.system(size: 16, weight: .semibold))
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent.opacity(0.6))
                }
                Text(meaning)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("\(Int(averageAccuracy * 100))%")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("accuracy")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// All stroke results across every canvas in the entry. For multi-char
    /// words we group by character so the user can see at a glance which
    /// hanzi a slipped stroke belongs to.
    private var strokeBreakdown: some View {
        let totalStrokes = canvases.reduce(0) { $0 + $1.perStrokeResults.count }
        return VStack(alignment: .leading, spacing: 12) {
            Text("STROKE ACCURACY")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            if totalStrokes == 0 {
                Text("No strokes recorded.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(canvases.enumerated()), id: \.offset) { idx, canvas in
                    if entry.isWord {
                        Text(entry.characters[idx].char)
                            .font(Theme.hanzi(16))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, idx == 0 ? 0 : 4)
                    }
                    let results = canvas.perStrokeResults
                    if results.isEmpty {
                        Text("Not yet written.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56),
                                                     spacing: 6,
                                                     alignment: .top)],
                                  alignment: .leading,
                                  spacing: 10) {
                            ForEach(Array(results.enumerated()), id: \.offset) { strokeIdx, r in
                                strokeColumn(strokeNumber: strokeIdx + 1, result: r)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func strokeColumn(strokeNumber: Int, result: StrokeResult) -> some View {
        // A stroke counts as a "mistake" (red X) if the user had to redo
        // it, even if the final accepted attempt was accurate — first-try
        // correctness is what we want to flag.
        let clean = result.cleanPass
        return VStack(spacing: 4) {
            Text("Stroke \(strokeNumber)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Image(systemName: clean ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(clean ? color(for: result.accuracy) : Theme.warning)
            if result.retries > 0 {
                Text("\(result.retries)× retry")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("\(Int(result.accuracy * 100))%")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
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

/// View modifier that optionally adds the pinch gesture + bottom-right
/// resize handle to a canvas. `enabled` lets us hide the affordance in
/// Fit mode where resizing has no visible effect.
private struct ResizableCanvasModifier<Handle: View, G: Gesture>: ViewModifier {
    let enabled: Bool
    let handle: Handle
    let gesture: G

    func body(content: Content) -> some View {
        if enabled {
            content
                .simultaneousGesture(gesture)
                .overlay(alignment: .bottomTrailing) { handle }
        } else {
            content
        }
    }
}
