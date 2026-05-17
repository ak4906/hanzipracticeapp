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
    /// Canvas indices the user explicitly "Skipped" — also dimmed and
    /// auto-advanced past, but without applying any SRS grade (unlike
    /// knownCanvases). Useful when the user doesn't want to write a
    /// specific character right now but doesn't want to declare it as
    /// known either. Persists across passes within the same entry.
    @State private var skippedCanvases: Set<Int> = []
    /// Tracks which entry the skip / known sets belong to, so we know
    /// when to clear them (same-entry pass changes don't reset; new
    /// entry does).
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
        case interPassQuiz // inline multiple-choice prompt (after pass 0 / before pass 1)
        case finished      // whole session done
    }

    /// One multiple-choice prompt shown inline during a writing session
    /// when the user has enabled the inter-pass quiz. Hashable so the
    /// @State binding works.
    /// One multiple-choice option. `primary` is the label that
    /// identifies the option (matched against `correct` for grading).
    /// `pinyin` / `meaning` / `note` are optional secondary lines used
    /// by the rich component-quiz layout so each option can show, e.g.,
    /// "氵 — shuǐ — water — classifies water-related things". For
    /// meaning / pinyin / role / type questions the secondary fields
    /// are nil and only `primary` is rendered.
    struct QuizOption: Hashable {
        let primary: String
        let pinyin: String?
        let meaning: String?
        let note: String?

        static func simple(_ text: String) -> QuizOption {
            QuizOption(primary: text, pinyin: nil, meaning: nil, note: nil)
        }
    }

    struct InterPassQuiz: Hashable {
        enum Kind: String, Hashable {
            case meaning           // "What does X mean?"
            case pinyin            // "How is X pronounced?"
            case componentMeaning  // "Which is the meaning component of [pinyin]?"
            case componentSound    // "Which is the sound component of [pinyin]?"
            case componentStructure // "Which describes the components of [pinyin]?"
            case originStory       // "Which describes the origin of [pinyin]?"
        }
        /// Whether the quiz event fires *after* the entry's trace pass
        /// (right when association is freshest) or *before* the lighter
        /// visual-aid pass (recall before the next aid lands). Recorded
        /// so `commitQuizSet` can update the right "already-quizzed"
        /// bookkeeping set.
        enum Trigger: Hashable {
            case afterPass0
            case beforePass1
        }
        let entryIndex: Int
        let trigger: Trigger
        let kind: Kind
        let prompt: String
        /// The `primary` text of the option that's correct — quizzes
        /// grade by string-equality against this.
        let correct: String
        let options: [QuizOption]
    }

    /// Reversible snapshot of an `SRSCard`'s mutable state, used when
    /// the user performs an action that mutates SRS (like "I know this
    /// word") so we can roll back the grade if they tap undo.
    struct SRSCardSnapshot {
        let interval: Double
        let ease: Double
        let repetitions: Int
        let dueDate: Date
        let lastReviewed: Date?
        let mastery: Double
        let reviewCount: Int
        let lapseCount: Int

        init(card: SRSCard) {
            self.interval = card.interval
            self.ease = card.ease
            self.repetitions = card.repetitions
            self.dueDate = card.dueDate
            self.lastReviewed = card.lastReviewed
            self.mastery = card.mastery
            self.reviewCount = card.reviewCount
            self.lapseCount = card.lapseCount
        }

        func restore(to card: SRSCard) {
            card.interval = interval
            card.ease = ease
            card.repetitions = repetitions
            card.dueDate = dueDate
            card.lastReviewed = lastReviewed
            card.mastery = mastery
            card.reviewCount = reviewCount
            card.lapseCount = lapseCount
        }
    }

    /// Bookkeeping for the most-recent reversible action. Held in
    /// state so the undo chip can read the human-readable label and
    /// `performUndo()` can restore everything that changed.
    struct PendingUndoAction {
        enum Action {
            case canvasKnown(idx: Int)
            case canvasSkipped(idx: Int)
            case entryKnown(entryIndex: Int)
            case entrySkipped(entryIndex: Int)
        }
        let action: Action
        let label: String
        let entryIndex: Int
        let priorActiveCharIndex: Int?
        let priorSequenceIndex: Int?
        let cardID: String?
        let cardSnapshot: SRSCardSnapshot?
        let priorSessionResult: Double?
    }

    /// Question queue for the current inter-pass quiz event — multiple
    /// questions about the same entry (meaning, pinyin, optionally
    /// components) shown back-to-back. The user must get *all* right to
    /// advance to the next pass; any wrong answer triggers a pass redo.
    @State private var currentQuizQueue: [InterPassQuiz] = []
    @State private var quizQueueIndex: Int = 0
    @State private var quizSelection: String? = nil
    @State private var quizAnyWrong: Bool = false   // sticky for the queue
    /// Entries whose *after-pass-0* quiz has already fired this session.
    /// Prevents the post-trace quiz from re-firing on retries of the
    /// same pass (e.g. after the user fails the quiz and redraws).
    @State private var afterPass0Quizzed: Set<Int> = []
    /// Entries whose *before-pass-1* quiz has already fired. Tracked
    /// separately so we can deliver both halves of the inline quiz
    /// model (after trace + before visual-aid recall) per entry.
    @State private var beforePass1Quizzed: Set<Int> = []
    /// Entry whose quiz most recently fired. Used to suppress the
    /// before-pass-1 quiz when it would land immediately after the
    /// after-pass-0 quiz of the *same* entry (chunk size 1) — those
    /// would feel redundant to the user.
    @State private var lastQuizFiredEntryIndex: Int? = nil

    /// Reversible record of the most recent "I know" / "Skip" action.
    /// Powers the undo chip so an accidental tap doesn't lose the
    /// canvas or wrongly mark a card as easy. Cleared on the next
    /// action or when the user moves on to a different entry.
    @State private var pendingUndo: PendingUndoAction? = nil

    /// When true, the build-associations card collapses to just its
    /// header chip — frees vertical space for the writing canvas on
    /// small screens. The user can tap to toggle; reset to expanded
    /// whenever the active character changes (each new char is worth
    /// re-reading at least once).
    @State private var memoryAidCollapsed: Bool = false

    /// Words the user has completed (graded / marked-known / skipped)
    /// in this session, in completion order. Drives the back-arrow
    /// "review what I just wrote" navigation. Distinct from
    /// `sessionResults` so we get a stable ordering — that one's a
    /// dict and discards insertion order.
    @State private var entryHistory: [String] = []

    /// Index into `entryHistory` for review mode. nil means "live" —
    /// the user is on the current practice entry. Setting this jumps
    /// the main column into a read-only preview of the past entry so
    /// they can re-inspect it without losing the live state.
    @State private var reviewIndex: Int? = nil

    /// The actual `WritingCanvasModel`s as they stood when the user
    /// finished each entry (graded / marked-known / skipped). Keyed by
    /// entry word. Review mode renders these instead of building a
    /// fresh template so the user can see their own ink on top of the
    /// template and compare. Cleared when an entry is undone.
    @State private var historyCanvases: [String: [WritingCanvasModel]] = [:]

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
                            if let review = reviewedEntry {
                                // Back/forward arrows put us in review
                                // mode — collapse the writing UI to a
                                // read-only preview of the past entry
                                // so the user can re-inspect it (and
                                // tap the header for full detail).
                                VStack(spacing: 14) {
                                    historyBar
                                    reviewPanel(for: review)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                            } else if isCompactVertical {
                                // Landscape: header + controls in a narrow
                                // left column, canvas claims the rest of
                                // the screen so it actually gets bigger
                                // when the user rotates, not smaller.
                                HStack(alignment: .top, spacing: 14) {
                                    VStack(spacing: 12) {
                                        historyBar
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
                                    historyBar
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
            .onChange(of: index) { oldIndex, newIndex in
                guard !practiceEntries.isEmpty else { return }
                rebuildCanvasesForCurrentEntry()
                phase = .writing
                // Crossing to a different entry closes the undo
                // window — the previous action's context is gone, so
                // a stale "Undo" chip would only confuse the user.
                let prev = sequence.indices.contains(oldIndex) ? sequence[oldIndex].entryIndex : nil
                let next = sequence.indices.contains(newIndex) ? sequence[newIndex].entryIndex : nil
                if prev != next {
                    pendingUndo = nil
                    // Each new entry is worth at least one read of
                    // the build-associations card — auto-expand even
                    // if the user collapsed it on the previous one.
                    // Per-character (within the same entry) we
                    // *don't* reset: if the user has closed the card
                    // by the time we hit the memory pass or the
                    // grading sheet, the collapse should stick so
                    // the canvas keeps the freed vertical space.
                    memoryAidCollapsed = false
                }
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
                                 knownCanvases: knownCanvases,
                                 skippedCanvases: skippedCanvases,
                                 onGrade: { grade in
                                     applyGrade(grade, for: entry)
                                 })
                    // Three detents so the user can pull the sheet
                    // down to a thin handle (.fraction 0.12) when
                    // they want to see the canvas they just wrote
                    // for visual comparison, sit at the standard
                    // medium height for casual grading, or expand
                    // to .large for the coaching deep-dive.
                    .presentationDetents([.fraction(0.12),
                                          .fraction(0.55),
                                          .large])
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
        // Display the multi-reading form ("méi / mò") in the header
        // so the user sees every pronunciation the character can
        // take. The grading layer still uses `entryPinyin` which
        // returns the single primary reading.
        let pinyin = entryPinyinDisplay(entry)
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
    /// pinyin (which already has tone marks). Used by quizzes that
    /// grade against a single expected reading.
    private func entryPinyin(_ entry: PracticeEntry) -> String {
        if entry.isWord, let w = wordLookup(entry.word) {
            return w.pinyin
        }
        return entry.characters.first?.pinyin ?? ""
    }

    /// Pinyin for *display* in the practice header — surfaces every
    /// recognised reading for single-char entries (没 → "méi / mò",
    /// 得 → "dé / děi / de") so the user is reminded that the
    /// character has multiple pronunciations. Multi-char words still
    /// show their word-level CEDICT reading because there's exactly
    /// one canonical pronunciation per word.
    private func entryPinyinDisplay(_ entry: PracticeEntry) -> String {
        if entry.isWord, let w = wordLookup(entry.word) {
            return w.pinyin
        }
        if let first = entry.characters.first {
            // pinyinAllReadings is empty when the lexicon didn't
            // know about this char — fall back to the single primary
            // reading so the header isn't blank.
            return first.pinyinAllReadings.isEmpty
                ? first.pinyin
                : first.pinyinAllReadings
        }
        return ""
    }

    /// English meaning for the entry — unified word lookup for multi-char,
    /// MMA definition for single chars. Always tone-marked for display.
    private func entryMeaning(_ entry: PracticeEntry) -> String {
        if entry.isWord, let w = wordLookup(entry.word) {
            return w.displayGloss
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
        // Always show the per-character build-associations for whatever
        // char the user is currently writing — even when the *word* is
        // a transliteration / proper noun. The previous behaviour
        // replaced the breakdown with a "Transliteration of …" label,
        // which both over-flagged Chinese names (e.g. 御湘园) and made
        // the breakdown for legitimate chars like 菲 / 园 inaccessible.
        // A small loanword tag still shows at the top when CC-CEDICT
        // explicitly marks the word as a loanword.
        if memoryAidShouldShow, activeMode != .memory, let c = activeChar {
            let etymology = c.etymology
            let parts = componentBreakdown(for: c)
            let prose = bestEtymologyProse(for: c)
            // Only render the card if there's *something* to say.
            if prose != nil
                || (parts != nil && !(parts!.isEmpty))
                || c.mnemonic != nil {
                VStack(alignment: .leading, spacing: 8) {
                    // Header doubles as the tap target so the user can
                    // collapse the card once they've read it — the
                    // writing canvas below then claims the freed
                    // vertical space (matters most on smaller iPhones
                    // where the card otherwise leaves the canvas
                    // squished). Chevron points down when expanded,
                    // right when collapsed.
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            memoryAidCollapsed.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: memoryAidCollapsed
                                  ? "chevron.right" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
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
                            if memoryAidCollapsed {
                                Text("Tap to expand")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if !memoryAidCollapsed {
                    // Small loanword hint when CC-CEDICT explicitly tags
                    // the word as one — sits above the per-char breakdown
                    // so the user gets word-level context without losing
                    // access to character-level associations.
                    if entry.isWord, let note = transliterationLabel(for: entry) {
                        Text(note)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 2)
                    }
                    if let prose {
                        Text(prose.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if prose.fromDong {
                            Text("Etymology · Dong Chinese · CC BY-SA 4.0")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
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
                    } // memoryAidCollapsed == false
                }
                .padding(memoryAidCollapsed ? 8 : 12)
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

    /// Detect explicit loanword annotations from CC-CEDICT. Only fires
    /// when the gloss actually says "(loanword)" — the previous
    /// capital-letter heuristic over-flagged Chinese place / restaurant
    /// names like 御湘园 (Royal Hunanese Garden → "Happy Hot Hunan").
    /// Returned label is shown as a small inline note above the regular
    /// per-character breakdown, not in place of it.
    private func transliterationLabel(for entry: PracticeEntry) -> String? {
        guard let w = wordLookup(entry.word) else { return nil }
        let lower = w.gloss.lowercased()
        if lower.contains("(loanword)") || lower.contains("loanword)") {
            return "Loanword: '\(w.firstGloss)'"
        }
        return nil
    }

    /// Pick the best prose explanation for the build-associations card.
    /// Dong Chinese (chinese-lexicon) text is preferred when available —
    /// it's usually a fuller "why these parts" story than MMA's terse
    /// hint. Falls back to the MMA hint so chars not in the lexicon
    /// bundle still get a line. Returns nil when neither source has
    /// anything useful.
    private func bestEtymologyProse(for c: HanziCharacter)
        -> (text: String, fromDong: Bool)?
    {
        if let dong = EtymologyLexicon.shared.notes(for: c.canonicalID) {
            return (dong, true)
        }
        if let hint = c.etymology?.hint, !hint.isEmpty {
            return (hint, false)
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
            // Cross-entry / cross-pass jump: `activeCharIndex` might
            // not change (both passes start on canvas 0 if everything
            // is unmarked), so the .onChange above won't fire. Also
            // jump on entry / pass transitions so a pass-1 view of a
            // word where canvas 0 is already marked known opens with
            // the focus already on the next unwritten character.
            .onChange(of: currentEntryIndex) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo(activeCharIndex, anchor: .center)
                }
            }
            .onChange(of: currentPass) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo(activeCharIndex, anchor: .center)
                }
            }
            .onAppear {
                // ScrollViewReader proxies are ready by the time
                // .onAppear fires, but the layout pass for the
                // canvases is still pending — defer to the next
                // runloop so .scrollTo lands on the right item.
                DispatchQueue.main.async {
                    proxy.scrollTo(activeCharIndex, anchor: .center)
                }
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
        let isSkipped = skippedCanvases.contains(idx)
        let isInactive = isKnown || isSkipped
        WritingCanvas(model: model) { _ in
            // Stroke accepted. If this canvas has now completed all its
            // strokes, advance within (or past) the entry. Delay slightly
            // so the user sees the accepted-stroke flash.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                handleStrokeAccepted(forCanvasAt: idx)
            }
        }
        .opacity(isInactive ? 0.35 : (isActive ? 1 : 0.55))
        .allowsHitTesting(isActive && !isInactive)
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
                    } else if isSkipped {
                        Image(systemName: "forward.end.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap an inactive canvas to re-focus it (unless it's been
            // explicitly known/skipped — those stay out of the way).
            if idx != activeCharIndex && !isInactive {
                activeCharIndex = idx
            }
        }
        .contextMenu {
            // Long-press menu — only meaningful for multi-char entries,
            // so we hide it for single-char sessions.
            if canvases.count > 1, let entry = currentEntry,
               entry.characters.indices.contains(idx) {
                if isKnown {
                    Button {
                        knownCanvases.remove(idx)
                    } label: {
                        Label("Practise this character again",
                              systemImage: "arrow.uturn.backward")
                    }
                } else if isSkipped {
                    Button {
                        skippedCanvases.remove(idx)
                    } label: {
                        Label("Practise this character again",
                              systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        markCharacterKnown(at: idx)
                    } label: {
                        Label("I know \(entry.characters[idx].char)",
                              systemImage: "checkmark.circle")
                    }
                    Button {
                        skipCharacter(at: idx)
                    } label: {
                        Label("Skip \(entry.characters[idx].char)",
                              systemImage: "forward.end")
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
    ///
    /// On a *memory*-pass canvas we briefly flip the hint mode to
    /// `.trace` after the final stroke so the template silhouette
    /// appears under the user's ink — a visual diff for "how close
    /// was I really?". The pause is short enough not to feel
    /// blocking but long enough to register the comparison; the user
    /// can also tap any control to break out early.
    private func handleStrokeAccepted(forCanvasAt idx: Int) {
        guard idx == activeCharIndex,
              canvases.indices.contains(idx) else { return }
        let model = canvases[idx]
        let charDone = model.totalStrokes > 0
            && model.completedStrokes >= model.totalStrokes
        guard charDone else { return }    // more strokes to go on this char
        if model.hintMode == .memory {
            // Reveal: drop the memory veil so the template appears
            // behind the user's strokes. Hint flips back to .memory
            // when the canvas is rebuilt for the next entry/pass, so
            // we don't need to restore it manually.
            model.hintMode = .trace
            let token = idx
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                // User may have moved on (skipped, undone, hit
                // Next pass, etc.) while we slept — only auto-advance
                // when we're still on the same canvas and the model
                // is still complete.
                guard activeCharIndex == token,
                      canvases.indices.contains(token),
                      canvases[token].isComplete else { return }
                advanceWithinEntry()
            }
            return
        }
        advanceWithinEntry()
    }

    /// Move `activeCharIndex` to the next non-known canvas in the current
    /// entry; if there isn't one, either trigger grading (final pass) or
    /// advance the outer sequence to the next entry / pass.
    private func advanceWithinEntry() {
        var next = activeCharIndex + 1
        while next < canvases.count
            && (knownCanvases.contains(next) || skippedCanvases.contains(next)) {
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
    ///
    /// Snapshots the card + active-canvas state before mutating so an
    /// accidental tap can be reverted via the undo chip.
    private func markCharacterKnown(at idx: Int) {
        guard let entry = currentEntry,
              entry.characters.indices.contains(idx) else { return }
        let char = entry.characters[idx]
        let controller = UserDataController(context: modelContext)
        let card = controller.ensureCard(for: char.id)
        let snapshot = SRSCardSnapshot(card: card)
        let priorActive = activeCharIndex
        SRSEngine.apply(grade: .easy, to: card)
        try? modelContext.save()
        knownCanvases.insert(idx)
        if idx == activeCharIndex {
            advanceWithinEntry()
        }
        pendingUndo = PendingUndoAction(
            action: .canvasKnown(idx: idx),
            label: "Marked \(char.char) as known",
            entryIndex: currentEntryIndex,
            priorActiveCharIndex: priorActive,
            priorSequenceIndex: nil,
            cardID: char.id,
            cardSnapshot: snapshot,
            priorSessionResult: nil
        )
    }

    /// User long-pressed a canvas and chose "Skip this character". Unlike
    /// `markCharacterKnown` this *doesn't* touch SRS — the char just
    /// drops out of this entry's writing flow. The word still grades
    /// normally; the skipped canvas counts as 100% so it doesn't drag
    /// the average down, and the word-level grade still propagates to
    /// the constituent characters (skipped chars get the same grade as
    /// the rest of the word).
    private func skipCharacter(at idx: Int) {
        guard let entry = currentEntry,
              entry.characters.indices.contains(idx) else { return }
        let priorActive = activeCharIndex
        let char = entry.characters[idx]
        skippedCanvases.insert(idx)
        if idx == activeCharIndex {
            advanceWithinEntry()
        }
        pendingUndo = PendingUndoAction(
            action: .canvasSkipped(idx: idx),
            label: "Skipped \(char.char)",
            entryIndex: currentEntryIndex,
            priorActiveCharIndex: priorActive,
            priorSequenceIndex: nil,
            cardID: nil,
            cardSnapshot: nil,
            priorSessionResult: nil
        )
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

    /// Two chip buttons that operate on the whole *entry* (word) — the
    /// labels include "word" for multi-char entries to disambiguate from
    /// the per-character actions in the canvas long-press menu. For
    /// single-char entries we keep the short labels ("I know this" /
    /// "Skip") since there's no word vs char distinction. When the
    /// user has just taken a reversible action ("I know" / "Skip"),
    /// the row is replaced with an undo chip — they get one chance to
    /// roll back before doing anything else.
    @ViewBuilder
    private func quickActionsRow(for entry: PracticeEntry) -> some View {
        if let undo = pendingUndo {
            undoChip(undo)
        } else {
            let knowLabel  = entry.isWord ? "I know this word" : "I know this"
            let skipLabel  = entry.isWord ? "Skip word"        : "Skip"
            HStack(spacing: 8) {
                Button {
                    markKnown(entry)
                } label: {
                    quickActionChip(systemImage: "checkmark.circle",
                                    title: knowLabel,
                                    tint: Theme.accent)
                }
                Button {
                    skipEntry()
                } label: {
                    quickActionChip(systemImage: "forward.end",
                                    title: skipLabel,
                                    tint: .secondary)
                }
            }
        }
    }

    /// Compact back/forward navigator. Always rendered (with arrows
    /// greyed out when not actionable) so the affordance is
    /// discoverable from the very first entry of a session — the
    /// previous "only show when history exists" version meant the
    /// arrows literally didn't exist on first launch, and the user
    /// never learned the gesture. The right-arrow deliberately can't
    /// step *past* the live entry — that's what "Skip word" is for.
    @ViewBuilder
    private var historyBar: some View {
        HStack(spacing: 8) {
            Button { goBackInHistory() } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canGoBackInHistory
                                      ? Theme.accent
                                      : Color.secondary.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!canGoBackInHistory)
            .accessibilityLabel("Review previous entry")

            Spacer(minLength: 8)

            if let r = reviewIndex {
                Text("Reviewing \(r + 1) / \(historyEntries.count)")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.warning)
            } else if historyEntries.isEmpty {
                Text("← Past · Current · Skip →")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Current")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button { goForwardInHistory() } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canGoForwardInHistory
                                      ? Theme.accent
                                      : Color.secondary.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!canGoForwardInHistory)
            .accessibilityLabel("Return toward current entry")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(
            Capsule().fill(
                reviewIndex == nil ? Color.clear : Theme.warning.opacity(0.08)
            )
        )
        .overlay(
            Capsule().stroke(
                reviewIndex == nil
                    ? Color.secondary.opacity(0.15)
                    : Theme.warning.opacity(0.3),
                lineWidth: 1
            )
        )
    }

    /// Read-only review of a past entry. Reuses `cardHeader` so the
    /// tap-to-open-detail affordance the user already knows works
    /// identically here. When we snapshotted the user's canvases for
    /// this entry (during applyGrade / markKnown / skipEntry), we
    /// render them — strokes-on-template — in a non-interactive
    /// WritingCanvas so the user can see their own ink against the
    /// reference. Falls back to a big static hanzi when no snapshot
    /// exists (e.g. an entry that was never written this session).
    @ViewBuilder
    private func reviewPanel(for entry: PracticeEntry) -> some View {
        VStack(spacing: 14) {
            cardHeader(for: entry)
            if let savedCanvases = historyCanvases[entry.word], !savedCanvases.isEmpty {
                reviewCanvasRow(savedCanvases)
                Text("Read-only — your strokes shown over the template. Tap the header for full detail.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            } else {
                VStack(spacing: 10) {
                    Text(store.displayedWord(entry.word))
                        .font(Theme.hanzi(96))
                        .foregroundStyle(Theme.accent)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("No saved strokes — tap the header for the full detail page.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .padding(.horizontal, 20)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.surface)
                )
            }
        }
    }

    /// Lay out one or more snapshot canvases for review. Forces the
    /// hint mode to `.trace` so the template silhouette is visible
    /// underneath the user's ink (in memory mode the canvas hides
    /// the template by design — which is fine while practising but
    /// counter-productive in review).
    @ViewBuilder
    private func reviewCanvasRow(_ models: [WritingCanvasModel]) -> some View {
        let direction = (settingsList.first?.effectiveWritingDirection) ?? .horizontal
        let layout = direction == .horizontal
            ? AnyLayout(HStackLayout(spacing: 8))
            : AnyLayout(VStackLayout(spacing: 8))
        ScrollView(direction == .horizontal ? .horizontal : .vertical,
                   showsIndicators: false) {
            layout {
                ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                    // The snapshot model still carries whatever
                    // hintMode the entry was on when graded. Force
                    // `.trace` here so the template stays visible
                    // under the user's strokes in memory-mode
                    // snapshots — that's the comparison the user
                    // actually wants in review.
                    let _ = (model.hintMode = .trace)
                    WritingCanvas(model: model, isInteractive: false)
                        .frame(maxWidth: 280, maxHeight: 280)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    /// Inline "you just did X — tap to undo" chip. Stays visible until
    /// the user dismisses it OR moves to a different entry / pass (an
    /// `onChange` watcher clears `pendingUndo` in those cases so the
    /// chip doesn't linger out of context).
    private func undoChip(_ undo: PendingUndoAction) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.warning)
            Text(undo.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            Button {
                performUndo()
            } label: {
                Text("Undo")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.warning))
            }
            .buttonStyle(.plain)
            Button {
                pendingUndo = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss undo")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Theme.warning.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(Theme.warning.opacity(0.5), lineWidth: 1)
        )
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
    /// record is created since there's no real attempt. Snapshots the
    /// card + sequence state so an accidental tap can be undone.
    private func markKnown(_ entry: PracticeEntry) {
        let controller = UserDataController(context: modelContext)
        let card = controller.ensureCard(for: entry.word)
        let snapshot = SRSCardSnapshot(card: card)
        let priorIndex = index
        let priorEntryIdx = currentEntryIndex
        let priorResult = sessionResults[entry.word]
        SRSEngine.apply(grade: .easy, to: card)
        try? modelContext.save()
        sessionResults[entry.word] = 1.0
        rememberInHistory(entry.word)
        historyCanvases[entry.word] = canvases
        dropCurrentEntry()
        pendingUndo = PendingUndoAction(
            action: .entryKnown(entryIndex: priorEntryIdx),
            label: "Marked \(entry.word) as known",
            entryIndex: priorEntryIdx,
            priorActiveCharIndex: nil,
            priorSequenceIndex: priorIndex,
            cardID: entry.word,
            cardSnapshot: snapshot,
            priorSessionResult: priorResult
        )
    }

    /// Move past the current entry entirely without touching its SRS state —
    /// it stays due, so it'll re-appear in a future session.
    private func skipEntry() {
        guard let entry = currentEntry else { return }
        let priorIndex = index
        let priorEntryIdx = currentEntryIndex
        rememberInHistory(entry.word)
        historyCanvases[entry.word] = canvases
        dropCurrentEntry()
        pendingUndo = PendingUndoAction(
            action: .entrySkipped(entryIndex: priorEntryIdx),
            label: "Skipped \(entry.word)",
            entryIndex: priorEntryIdx,
            priorActiveCharIndex: nil,
            priorSequenceIndex: priorIndex,
            cardID: nil,
            cardSnapshot: nil,
            priorSessionResult: nil
        )
    }

    /// Reverse the most recent quick-action. Restores SRS state from
    /// the snapshot (for "I know" cases), removes the entry/canvas from
    /// the skip set, and rewinds the sequence index so the user can
    /// continue from where they were before the accidental tap.
    private func performUndo() {
        guard let undo = pendingUndo else { return }
        switch undo.action {
        case .canvasKnown(let idx):
            knownCanvases.remove(idx)
            if let snapshot = undo.cardSnapshot,
               let cardID = undo.cardID {
                let card = UserDataController(context: modelContext).ensureCard(for: cardID)
                snapshot.restore(to: card)
                try? modelContext.save()
            }
            if let prior = undo.priorActiveCharIndex,
               canvases.indices.contains(prior) {
                activeCharIndex = prior
            }
        case .canvasSkipped(let idx):
            skippedCanvases.remove(idx)
            if let prior = undo.priorActiveCharIndex,
               canvases.indices.contains(prior) {
                activeCharIndex = prior
            }
        case .entryKnown(let entryIdx):
            skippedEntries.remove(entryIdx)
            if let snapshot = undo.cardSnapshot,
               let cardID = undo.cardID {
                let card = UserDataController(context: modelContext).ensureCard(for: cardID)
                snapshot.restore(to: card)
                try? modelContext.save()
                forgetFromHistory(cardID)
            }
            if let prior = undo.priorSessionResult {
                sessionResults[undo.cardID ?? ""] = prior
            } else if let cardID = undo.cardID {
                sessionResults.removeValue(forKey: cardID)
            }
            if let prior = undo.priorSequenceIndex,
               sequence.indices.contains(prior) {
                index = prior
            }
            phase = .writing
        case .entrySkipped(let entryIdx):
            skippedEntries.remove(entryIdx)
            if let word = practiceEntries.indices.contains(entryIdx)
                ? practiceEntries[entryIdx].word : nil {
                forgetFromHistory(word)
            }
            if let prior = undo.priorSequenceIndex,
               sequence.indices.contains(prior) {
                index = prior
            }
            phase = .writing
        }
        pendingUndo = nil
    }

    // MARK: - Session history (back / forward arrows)

    /// Append a completed-entry word to the history queue (used by
    /// applyGrade / markKnown / skipEntry). Idempotent — repeating the
    /// same entry across passes keeps a single history slot rather
    /// than duplicating it, since the user expects "back" to walk
    /// distinct entries, not pass replays.
    private func rememberInHistory(_ word: String) {
        if !entryHistory.contains(word) {
            entryHistory.append(word)
        }
    }

    private func forgetFromHistory(_ word: String) {
        entryHistory.removeAll { $0 == word }
        historyCanvases.removeValue(forKey: word)
        // Clamp / clear the cursor if we just removed the entry
        // currently being reviewed.
        if let r = reviewIndex, r >= entryHistory.count {
            reviewIndex = entryHistory.isEmpty ? nil : entryHistory.count - 1
        }
    }

    /// `PracticeEntry` instances corresponding to the words in
    /// `entryHistory` (in original session order). Filters out any
    /// history entry that's no longer in `practiceEntries` so a stale
    /// review index can't crash.
    private var historyEntries: [PracticeEntry] {
        entryHistory.compactMap { word in
            practiceEntries.first(where: { $0.word == word })
        }
    }

    /// The entry currently being reviewed, if any.
    private var reviewedEntry: PracticeEntry? {
        guard let r = reviewIndex,
              historyEntries.indices.contains(r) else { return nil }
        return historyEntries[r]
    }

    private var canGoBackInHistory: Bool {
        let n = historyEntries.count
        guard n > 0 else { return false }
        if let r = reviewIndex { return r > 0 }
        return true
    }

    /// Right-arrow is enabled only inside review mode — moving forward
    /// from the live entry is what "Skip word" is for, per the user's
    /// design note.
    private var canGoForwardInHistory: Bool { reviewIndex != nil }

    private func goBackInHistory() {
        let n = historyEntries.count
        guard n > 0 else { return }
        if let r = reviewIndex {
            if r > 0 { reviewIndex = r - 1 }
        } else {
            reviewIndex = n - 1
        }
    }

    private func goForwardInHistory() {
        guard let r = reviewIndex else { return }
        if r + 1 < historyEntries.count {
            reviewIndex = r + 1
        } else {
            // Stepping past the most-recent history slot returns the
            // user to the live entry.
            reviewIndex = nil
        }
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
        // Persist known/skipped-canvas marks across the 3-pass drill —
        // re-marking "I know 冰" every pass would be annoying. Only
        // reset when the entry index actually changes.
        if knownCanvasesEntryIdx != currentEntryIndex {
            knownCanvases = []
            skippedCanvases = []
            knownCanvasesEntryIdx = currentEntryIndex
        }
        // Skip to the first canvas that's neither known nor skipped.
        var first = 0
        while first < canvases.count
            && (knownCanvases.contains(first) || skippedCanvases.contains(first)) {
            first += 1
        }
        activeCharIndex = min(first, max(0, canvases.count - 1))
    }

    /// Step `index` forward until it lands on a sequence step whose entry
    /// hasn't been skipped. Used by every advance path so a dropped entry
    /// can't sneak back in on a later pass.
    private func advanceToNextVisible() {
        // Crossing into a new sequence step closes the current
        // "transition window" used by the inline quiz redundancy
        // check — clear `lastQuizFiredEntryIndex` so a later quiz on
        // the same entry isn't accidentally suppressed.
        lastQuizFiredEntryIndex = nil
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
            // wrote* this session. Skip chars they marked as known
            // (already got .easy directly) or skipped (no engagement
            // signal — leave SRS unchanged).
            for (idx, char) in entry.characters.enumerated()
                where char.id != entry.word
                    && !knownCanvases.contains(idx)
                    && !skippedCanvases.contains(idx) {
                let charCard = controller.ensureCard(for: char.id)
                SRSEngine.apply(grade: grade, to: charCard)
            }
        }

        // Per-canvas accuracy. Known / skipped canvases count as 100% so
        // the user's deliberate non-engagement doesn't pretend to be a
        // miss when averaging the word's accuracy.
        let canvasAccuracies: [Double] = canvases.enumerated().map { idx, canvas in
            (knownCanvases.contains(idx) || skippedCanvases.contains(idx))
                ? 1.0 : canvas.averageAccuracy
        }
        let count = max(1, canvasAccuracies.count)
        let avgAccuracy = canvasAccuracies.reduce(0, +) / Double(count)
        let activelyWrittenIndices = canvases.indices.filter {
            !knownCanvases.contains($0) && !skippedCanvases.contains($0)
        }
        let totalRetries = activelyWrittenIndices
            .map { canvases[$0].totalRetries }
            .reduce(0, +)
        let totalDuration = activelyWrittenIndices
            .map { canvases[$0].elapsedSeconds }
            .reduce(0, +)
        controller.recordPractice(characterID: entry.word,
                                  accuracy: avgAccuracy,
                                  retries: totalRetries,
                                  duration: totalDuration,
                                  kind: "writing")

        sessionResults[entry.word] = avgAccuracy
        rememberInHistory(entry.word)
        historyCanvases[entry.word] = canvases

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
    /// entry can't reappear on its next pass. If the user has enabled
    /// the inter-pass quiz we may intercept here with a multiple-choice
    /// queue under one of two triggers:
    ///   • after the entry's trace pass (pass 0), to lock in the
    ///     just-built association while it's freshest;
    ///   • before the entry's visual-aid pass (pass 1), to force a
    ///     cold recall before the lighter aid lands.
    /// Triggers fire at most once per entry per session, and the
    /// before-pass-1 quiz is suppressed when it would immediately
    /// follow the after-pass-0 quiz on the same entry (chunk size 1).
    private func advance() {
        guard totalSteps > 0 else {
            phase = .finished
            return
        }
        if let quizQueue = nextInterPassQuiz(), !quizQueue.isEmpty {
            currentQuizQueue = quizQueue
            quizQueueIndex = 0
            quizSelection = nil
            quizAnyWrong = false
            phase = .interPassQuiz
            return
        }
        advanceToNextVisible()
    }

    /// Decide which inter-pass quiz (if any) should fire at the current
    /// transition. Evaluated in order:
    ///   1. After-pass-0 for the step we just completed.
    ///   2. Before-pass-1 for the step we're about to enter.
    /// Returns nil if neither trigger is eligible (quizzes disabled,
    /// non-threePass mode, already-fired, redundant follow-on).
    private func nextInterPassQuiz() -> [InterPassQuiz]? {
        let enabled = settingsList.first?.interPassQuizEnabled ?? false
        guard enabled,
              practiceMode == .threePass,
              !sequence.isEmpty else { return nil }
        // Trigger 1: after-pass-0 of the step we just completed.
        if sequence.indices.contains(index) {
            let here = sequence[index]
            if here.pass == 0,
               !afterPass0Quizzed.contains(here.entryIndex),
               practiceEntries.indices.contains(here.entryIndex) {
                let queue = buildQuizQueue(entryIndex: here.entryIndex,
                                            trigger: .afterPass0)
                if !queue.isEmpty { return queue }
            }
        }
        // Trigger 2: before-pass-1 of the next step. Skip when it would
        // land back-to-back after the after-pass-0 quiz on the same
        // entry — the two would feel redundant.
        if index + 1 < sequence.count {
            let next = sequence[index + 1]
            if next.pass == 1,
               !beforePass1Quizzed.contains(next.entryIndex),
               lastQuizFiredEntryIndex != next.entryIndex,
               practiceEntries.indices.contains(next.entryIndex) {
                let queue = buildQuizQueue(entryIndex: next.entryIndex,
                                            trigger: .beforePass1)
                if !queue.isEmpty { return queue }
            }
        }
        return nil
    }

    /// Build the question queue for one entry's inline quiz event.
    ///
    ///   • `afterPass0` — fires immediately after the user finishes
    ///     drawing the entry. Carries the full deep-dive: meaning +
    ///     pinyin + the component-comprehension questions. The user
    ///     just wrote the character and the goal is to lock in the
    ///     associations between meaning, pronunciation, and EACH
    ///     component (with its function) while they're still fresh.
    ///   • `beforePass1` — light cold-recall before the next visual
    ///     aid. Just meaning + pinyin so we re-test retention without
    ///     drowning the user in repeat component questions.
    ///
    /// Suppressed entirely when the parent event would be empty (no
    /// useful source data).
    private func buildQuizQueue(entryIndex: Int,
                                 trigger: InterPassQuiz.Trigger)
        -> [InterPassQuiz]
    {
        guard practiceEntries.indices.contains(entryIndex) else { return [] }
        let entry = practiceEntries[entryIndex]
        let correctMeaning = entryMeaning(entry).quizFriendly
        // For single-char entries the "correct" pinyin answer surfaces
        // every recognised reading ("méi / mò") so the user has to
        // pick the chip that covers *all* of them, not just the
        // primary. For multi-char words there's a single canonical
        // word reading, so we keep that.
        let correctPinyin = entryPinyinDisplay(entry)
        var queue: [InterPassQuiz] = []
        if !correctMeaning.isEmpty {
            queue.append(makeMeaningQuiz(entry: entry,
                                          entryIndex: entryIndex,
                                          trigger: trigger,
                                          correct: correctMeaning))
        }
        if !correctPinyin.isEmpty {
            queue.append(makePinyinQuiz(entry: entry,
                                         entryIndex: entryIndex,
                                         trigger: trigger,
                                         correct: correctPinyin))
        }
        if trigger == .afterPass0 {
            queue.append(contentsOf: makeComponentDeepDive(entry: entry,
                                                            entryIndex: entryIndex,
                                                            trigger: trigger))
        }
        return queue
    }

    private func makeMeaningQuiz(entry: PracticeEntry,
                                  entryIndex: Int,
                                  trigger: InterPassQuiz.Trigger,
                                  correct: String) -> InterPassQuiz {
        let options = textDistractors(for: .meaning, correct: correct,
                                      excludingEntry: entry)
        return InterPassQuiz(entryIndex: entryIndex,
                             trigger: trigger,
                             kind: .meaning,
                             prompt: "What does \(entry.word) mean?",
                             correct: correct,
                             options: options)
    }

    private func makePinyinQuiz(entry: PracticeEntry,
                                 entryIndex: Int,
                                 trigger: InterPassQuiz.Trigger,
                                 correct: String) -> InterPassQuiz {
        let options = textDistractors(for: .pinyin, correct: correct,
                                      excludingEntry: entry)
        return InterPassQuiz(entryIndex: entryIndex,
                             trigger: trigger,
                             kind: .pinyin,
                             prompt: "How is \(entry.word) pronounced?",
                             correct: correct,
                             options: options)
    }

    /// Build the full component-comprehension quiz set for the entry.
    /// Goal: by the end of the after-pass-0 quiz, the user has had to
    /// mentally reconstruct every component of every (etymology-rich)
    /// character in the word — and explain *why* each one is there —
    /// without ever seeing the host hanzi as a hint. This is what
    /// builds the by-heart recall needed for the memory pass.
    ///
    /// Question form chosen per host's character type:
    ///   • Phono-semantic: two questions — "which is the meaning
    ///     component?" and "which is the sound component?" Each
    ///     option chip lists the hanzi + pinyin + meaning + a curated
    ///     "role hint" (e.g. 氵 → "classifies water-related things").
    ///   • Compound ideogram: one descriptive question — the options
    ///     are full sentences ("Depicts an eye looking at a tree…")
    ///     so the user picks the right symbolic story.
    ///   • Pictogram / simple ideogram: one origin-story question —
    ///     similar descriptive format, drawn from chinese-lexicon
    ///     notes ("A single horizontal stroke representing the
    ///     number one.").
    ///
    /// Hosts are referred to by pinyin + first-gloss, NOT by the
    /// character itself, so its visible parts don't leak the answer.
    private func makeComponentDeepDive(entry: PracticeEntry,
                                        entryIndex: Int,
                                        trigger: InterPassQuiz.Trigger)
        -> [InterPassQuiz]
    {
        // Walk every char in the entry so multi-char words exercise
        // the whole word's component vocabulary.
        var out: [InterPassQuiz] = []
        for host in entry.characters {
            let questions = componentQuestions(for: host,
                                                entryIndex: entryIndex,
                                                trigger: trigger)
            out.append(contentsOf: questions)
        }
        return out
    }

    /// Question(s) appropriate for `host`'s etymology type.
    private func componentQuestions(for host: HanziCharacter,
                                     entryIndex: Int,
                                     trigger: InterPassQuiz.Trigger)
        -> [InterPassQuiz]
    {
        let handle = hostHandle(for: host)
        let etymology = host.etymology
        let components = (etymology?.components ?? []).filter {
            $0.char != host.char && $0.char != host.canonicalID
        }
        let lexiconEntry = EtymologyLexicon.shared.entry(for: host.canonicalID)
            ?? EtymologyLexicon.shared.entry(for: host.char)
        let lexiconNotes = lexiconEntry?.notes
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Phono-semantic path. We try MMA's role tagging first (richer
        // when present), then fall back to chinese-lexicon's component
        // type field ("meaning"/"sound"). The fallback is what fixes
        // chars where MMA never recorded which side was phonetic vs
        // semantic — without it those characters dropped into the
        // story-quiz format and the user couldn't see the per-role
        // pinyin/meaning split.
        if let (sem, phon) = phonoSemanticComponents(host: host,
                                                      mmaComponents: components,
                                                      lexicon: lexiconEntry) {
            var out: [InterPassQuiz] = []
            out.append(makeWhichComponentQuiz(host: host,
                                              handle: handle,
                                              correctComp: sem,
                                              kind: .componentMeaning,
                                              entryIndex: entryIndex,
                                              trigger: trigger))
            if phon.char != sem.char {
                out.append(makeWhichComponentQuiz(host: host,
                                                  handle: handle,
                                                  correctComp: phon,
                                                  kind: .componentSound,
                                                  entryIndex: entryIndex,
                                                  trigger: trigger))
            }
            return out
        }

        // Compound / simple ideogram with components: one descriptive
        // question. The "story" is the lexicon's prose note enriched
        // with a uniform component-key line so the user sees what each
        // referenced hanzi means / sounds like.
        if !components.isEmpty, let story = lexiconNotes, !story.isEmpty {
            return [makeStoryQuiz(host: host, handle: handle,
                                   story: story,
                                   storyComponents: lexiconEntry?.components ?? [],
                                   requireComponents: true,
                                   kind: .componentStructure,
                                   entryIndex: entryIndex, trigger: trigger)]
        }

        // Pictogram / simple ideogram with no decomposable components:
        // ask about the origin instead. Lexicon coverage isn't perfect
        // — skip silently when the host has no note.
        if components.isEmpty, let story = lexiconNotes, !story.isEmpty {
            return [makeStoryQuiz(host: host, handle: handle,
                                   story: story,
                                   storyComponents: lexiconEntry?.components ?? [],
                                   requireComponents: false,
                                   kind: .originStory,
                                   entryIndex: entryIndex, trigger: trigger)]
        }
        return []
    }

    /// Try to pull a (semantic, phonetic) pair from either MMA or the
    /// chinese-lexicon bundle. MMA wins when complete; the lexicon
    /// fallback fills in cases where MMA labelled the character type
    /// as phono-semantic but never tagged which child component was
    /// which (or didn't classify the type at all but the lexicon
    /// notes lead with "Phonosemantic compound.").
    private func phonoSemanticComponents(
        host: HanziCharacter,
        mmaComponents: [EtymologyComponent],
        lexicon: LexiconEtymology?
    ) -> (semantic: EtymologyComponent, phonetic: EtymologyComponent)? {
        // MMA path — preferred when both roles are present.
        if host.etymology?.type == .phonosemantic,
           let sem = mmaComponents.first(where: { $0.role == .semantic || $0.role == .both }),
           let phon = mmaComponents.first(where: { $0.role == .phonetic || $0.role == .both }) {
            return (sem, phon)
        }
        // Lexicon fallback — uses the explicit type tag from
        // chinese-lexicon. The lexicon also tags compound ideograms
        // with "meaning" types, so we additionally require either an
        // MMA type of .phonosemantic OR a prose intro that says so.
        guard let lex = lexicon else { return nil }
        let says = lex.notes.lowercased()
        let isPhono = host.etymology?.type == .phonosemantic
            || says.hasPrefix("phonosemantic compound")
            || says.hasPrefix("phono-semantic compound")
        guard isPhono else { return nil }
        let semChar = lex.components.first(where: { $0.type == "meaning"
                                                    && $0.char != host.char
                                                    && $0.char != host.canonicalID })
        let phonChar = lex.components.first(where: { $0.type == "sound"
                                                     && $0.char != host.char
                                                     && $0.char != host.canonicalID })
        guard let s = semChar, let p = phonChar else { return nil }
        return (EtymologyComponent(char: s.char, role: .semantic),
                EtymologyComponent(char: p.char, role: .phonetic))
    }

    /// "Which is the meaning/sound component" question with rich
    /// per-option layout — hanzi + pinyin + meaning + role hint, so
    /// the user has the data to reason about which fits.
    private func makeWhichComponentQuiz(host: HanziCharacter,
                                         handle: String,
                                         correctComp: EtymologyComponent,
                                         kind: InterPassQuiz.Kind,
                                         entryIndex: Int,
                                         trigger: InterPassQuiz.Trigger)
        -> InterPassQuiz
    {
        let prompt: String = {
            switch kind {
            case .componentMeaning:
                return "Which is the meaning component of \(handle)?"
            case .componentSound:
                return "Which is the sound component of \(handle)?"
            default:
                return "Which is a component of \(handle)?"
            }
        }()
        // Build 4 rich options: the correct component + 3 plausible
        // distractor radicals.
        let hostComponentChars = Set((host.etymology?.components.map(\.char)) ?? [])
        let pool = ["口", "心", "月", "日", "木", "火", "氵", "人",
                    "女", "子", "大", "小", "土", "金", "言", "马",
                    "门", "山", "石", "目", "手", "刀", "力", "雨",
                    "宀", "亻", "扌", "辶", "艹", "灬", "忄", "讠",
                    "钅", "饣"]
        let distractorChars = pool
            .filter { !hostComponentChars.contains($0) && $0 != correctComp.char }
            .shuffled()
            .prefix(3)
        var optionChars = Array(distractorChars) + [correctComp.char]
        optionChars.shuffle()
        let options = optionChars.map { ch in
            componentOption(for: ch)
        }
        return InterPassQuiz(entryIndex: entryIndex,
                             trigger: trigger,
                             kind: kind,
                             prompt: prompt,
                             correct: correctComp.char,
                             options: options)
    }

    /// Build one rich option chip for a component-which question.
    /// Pulls pinyin / meaning / role hint from `RadicalNotes` first,
    /// falling back to the chinese-lexicon single-char definitions
    /// (or whatever the store has) so non-curated radicals still get
    /// at least their pinyin + literal meaning. The role hint is the
    /// pedagogically interesting bit ("classifies water-related
    /// things") — it teaches the user *why* this radical shows up
    /// inside compound characters, which is the recall they need to
    /// write from memory on pass 3.
    private func componentOption(for char: String) -> QuizOption {
        // Curated radical notes win — they carry the function hint
        // ("classifies water-related things") that the user explicitly
        // asked for. Bare-component forms like 氵 / 灬 / 宀 won't have
        // useful lexicon entries (they're often radical-only chars
        // outside the bundled definition set), so RadicalNotes is the
        // primary source.
        if let entry = RadicalNotes.entry(for: char) {
            return QuizOption(primary: char,
                              pinyin: entry.pinyin.isEmpty ? nil : entry.pinyin,
                              meaning: entry.meaning.isEmpty ? nil : entry.meaning,
                              note: entry.role.isEmpty ? nil : entry.role)
        }
        // Fall back to whatever the lexicon / store knows.
        if let def = SingleCharDefinitions.shared.entry(for: char) {
            let pinyin = def.pinyinReadings.replacingOccurrences(of: "; ",
                                                                  with: " / ")
            return QuizOption(primary: char,
                              pinyin: pinyin.isEmpty ? nil : pinyin,
                              meaning: def.short.isEmpty ? nil : def.short,
                              note: nil)
        }
        if let stored = store.character(for: char) {
            return QuizOption(primary: char,
                              pinyin: stored.pinyin.isEmpty ? nil : stored.pinyin,
                              meaning: stored.meaning.isEmpty ? nil : stored.meaning,
                              note: nil)
        }
        return QuizOption(primary: char, pinyin: nil, meaning: nil, note: nil)
    }

    /// Descriptive ("which story matches") question used for compound
    /// ideograms and pictograms. The correct option is the lexicon's
    /// own prose note for the host; distractors are random notes from
    /// other chars (filtered by component-presence so the styles
    /// match — compound-ideogram chars get other compound stories,
    /// pictograms get other pictograph stories).
    private func makeStoryQuiz(host: HanziCharacter,
                                handle: String,
                                story: String,
                                storyComponents: [LexiconComponent],
                                requireComponents: Bool,
                                kind: InterPassQuiz.Kind,
                                entryIndex: Int,
                                trigger: InterPassQuiz.Trigger) -> InterPassQuiz
    {
        let prompt: String = (kind == .originStory)
            ? "Which best describes the origin of \(handle)?"
            : "Which best describes the components of \(handle)?"
        let exclude: Set<String> = [host.canonicalID, host.char]
        // `randomEntries` returns the full lexicon row so we can
        // append a uniform component-key line to every option. Without
        // that, the correct option's prose would be the only one
        // referencing pinyin / meaning of its parts — which would
        // give the answer away. With it, the user must actually read
        // the keys to identify which combination matches the host.
        let raw = EtymologyLexicon.shared.randomEntries(
            count: 8,
            requireComponents: requireComponents,
            excluding: exclude)
        // Enrich the correct story with its own component key.
        let correctPrimary = enrichedStory(notes: story,
                                            components: storyComponents)
        var seenPrimaries = Set<String>([correctPrimary])
        var distractorPrimaries: [String] = []
        for entry in raw where distractorPrimaries.count < 3 {
            let enriched = enrichedStory(notes: entry.notes,
                                          components: entry.components)
            if enriched.count > 220 { continue } // chip overflow guard
            if seenPrimaries.insert(enriched).inserted {
                distractorPrimaries.append(enriched)
            }
        }
        var primaries = distractorPrimaries + [correctPrimary]
        while primaries.count < 4 {
            primaries.append("Origin unclear.")
        }
        primaries.shuffle()
        let options = primaries.map { QuizOption.simple($0) }
        return InterPassQuiz(entryIndex: entryIndex,
                             trigger: trigger,
                             kind: kind,
                             prompt: prompt,
                             correct: correctPrimary,
                             options: options)
    }

    /// Append a uniform "Key:" line listing each component with its
    /// pinyin + first-gloss + role tag so a phono-semantic prompt
    /// reads "Phonosemantic compound. 氵 represents the meaning and 相
    /// represents the sound.\nKey: 氵 (shuǐ, water) — meaning · 相
    /// (xiàng, each other) — sound" instead of leaving the user to
    /// guess at what 氵 sounds like. Returns the raw notes unchanged
    /// when no usable components are available so distractors with
    /// thin metadata don't break parity.
    private func enrichedStory(notes: String,
                                components: [LexiconComponent]) -> String {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = components.compactMap { c -> String? in
            // Skip empty / placeholder rows like the "characterless
            // component" (◎) entries chinese-lexicon uses.
            guard !c.char.isEmpty, c.char != "◎" else { return nil }
            let pinyin = c.pinyin.trimmingCharacters(in: .whitespaces)
            let def = c.definition.trimmingCharacters(in: .whitespaces).firstPart
            var bits: [String] = []
            if !pinyin.isEmpty { bits.append(pinyin) }
            if !def.isEmpty { bits.append(def) }
            let suffix = bits.isEmpty ? "" : " (\(bits.joined(separator: ", ")))"
            let roleTag: String = {
                switch c.type {
                case "meaning":   return " — meaning"
                case "sound":     return " — sound"
                case "iconic":    return ""   // pictographic part, no extra tag
                case "simplified": return " — simplified form"
                default:          return ""
                }
            }()
            return "\(c.char)\(suffix)\(roleTag)"
        }
        if refs.isEmpty { return trimmedNotes }
        return "\(trimmedNotes)\nKey: \(refs.joined(separator: " · "))"
    }

    /// Pinyin + first-gloss handle used in component-quiz prompts so we
    /// can refer to the host character without showing the character
    /// itself (which would visually leak the answer).
    private func hostHandle(for c: HanziCharacter) -> String {
        let gloss = c.meaning.quizFriendly
        if c.pinyin.isEmpty { return "'\(gloss)'" }
        if gloss.isEmpty { return c.pinyin }
        return "\(c.pinyin) ('\(gloss)')"
    }

    /// Three random distractors plus the correct answer, shuffled — for
    /// meaning / pinyin questions. Pulls from the rest of the session's
    /// entries first (contextually closest), then falls back to a
    /// broader pool (other vocab in the same HSK band for single-char,
    /// or random words from CC-CEDICT for word entries) so a tiny
    /// session like a single-item vocab list still gets four real
    /// options instead of "—" placeholders. Component-family kinds
    /// have their own dedicated builders above.
    private func textDistractors(for kind: InterPassQuiz.Kind,
                                  correct: String,
                                  excludingEntry entry: PracticeEntry) -> [QuizOption]
    {
        var pool: [String] = []
        var seen = Set<String>([correct])
        // Tier 1 — other entries in the same session. Most contextually
        // relevant: same lesson, same difficulty band, same user
        // intent. Already deduped because `seen` includes `correct`.
        for other in practiceEntries where other.word != entry.word {
            let value = textValue(of: kind, for: other)
            if !value.isEmpty, seen.insert(value).inserted {
                pool.append(value)
            }
        }
        // Tier 2 — broader fallback when the session is too small. This
        // is what makes single-entry vocab lists work: pull random
        // chars / words and use their meanings / readings as decoys.
        if pool.count < 3 {
            let extra = fallbackDistractors(for: kind,
                                             excluding: entry,
                                             needed: 3 - pool.count,
                                             seen: seen)
            for value in extra where seen.insert(value).inserted {
                pool.append(value)
            }
        }
        let distractors = pool.shuffled().prefix(3)
        var primaries = Array(distractors) + [correct]
        // Final pad if even the fallback was empty (truly degenerate
        // case — e.g. CC-CEDICT not loaded yet on a first launch).
        while primaries.count < 4 {
            primaries.append("—")
        }
        return primaries.shuffled().map { QuizOption.simple($0) }
    }

    /// Extract the text value for a given quiz kind from a practice
    /// entry — used by both the in-session pool and the fallback
    /// builder so the same projection runs in both places.
    private func textValue(of kind: InterPassQuiz.Kind,
                            for entry: PracticeEntry) -> String {
        switch kind {
        case .meaning:        return entryMeaning(entry).quizFriendly
        case .pinyin:         return entryPinyinDisplay(entry)
        default:              return ""
        }
    }

    /// Broader distractor pool when the in-session set is too small.
    /// For single-character entries we draw from chars at the same HSK
    /// level (closer in difficulty + visual register). For multi-char
    /// words we sample CC-CEDICT entries of similar length so the
    /// distractor reading / gloss has the right "shape". Falls back
    /// to whatever the store has if neither bucket can fill the slot.
    private func fallbackDistractors(for kind: InterPassQuiz.Kind,
                                      excluding entry: PracticeEntry,
                                      needed: Int,
                                      seen: Set<String>) -> [String]
    {
        guard needed > 0 else { return [] }
        var out: [String] = []
        var alreadySeen = seen
        if entry.isWord {
            // Random CC-CEDICT entries with the same char-count as
            // the target word. Picks ~3× the needed amount because
            // many will collide with the source meaning / pinyin.
            let targetLen = entry.word.count
            let pool = WordDictionary.shared.all
                .filter { $0.simplified.count == targetLen
                          && $0.simplified != entry.word }
                .shuffled()
                .prefix(needed * 6)
            for w in pool {
                let value: String = {
                    switch kind {
                    case .meaning:  return w.firstGloss.quizFriendly
                    case .pinyin:   return w.pinyin
                    default:        return ""
                    }
                }()
                if !value.isEmpty, alreadySeen.insert(value).inserted {
                    out.append(value)
                    if out.count >= needed { break }
                }
            }
            if out.count >= needed { return out }
        }
        // Single-char fallback: same HSK level for relevance,
        // wider net by level if needed.
        let targetLevel = entry.characters.first?.hskLevel ?? 0
        let levelBands: [Int] = {
            if targetLevel > 0 {
                return Array(Set([targetLevel,
                                  max(1, targetLevel - 1),
                                  min(6, targetLevel + 1)])).sorted()
            }
            return [1, 2, 3]
        }()
        for level in levelBands {
            let bucket = store.byHSK.first(where: { $0.level == level })?.characters ?? []
            let shuffled = bucket.shuffled()
            for c in shuffled where c.canonicalID != entry.word {
                let value: String = {
                    switch kind {
                    case .meaning:  return c.meaning.quizFriendly
                    // Use the multi-reading form for pinyin distractors
                    // so the format matches the correct option (which
                    // is also multi-reading for single chars).
                    case .pinyin:   return c.pinyinAllReadings.isEmpty
                                          ? c.pinyin : c.pinyinAllReadings
                    default:        return ""
                    }
                }()
                if !value.isEmpty, alreadySeen.insert(value).inserted {
                    out.append(value)
                    if out.count >= needed { return out }
                }
            }
        }
        return out
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
            ForEach(quiz.options, id: \.primary) { option in
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

    /// All questions in the queue have been answered. Either redo the
    /// pass we just left (any wrong) or recurse into `advance()` so the
    /// second inline trigger gets a chance to fire (e.g. an after-pass-0
    /// quiz immediately followed by the before-pass-1 quiz of the next
    /// entry on chunk size > 1).
    private func commitQuizSet() {
        if quizSelection != currentQuiz?.correct {
            quizAnyWrong = true
        }
        let anyWrong = quizAnyWrong
        // Mark the appropriate bookkeeping set so this trigger doesn't
        // re-fire for the same entry on a retry.
        if let q = currentQuizQueue.first {
            switch q.trigger {
            case .afterPass0:  afterPass0Quizzed.insert(q.entryIndex)
            case .beforePass1: beforePass1Quizzed.insert(q.entryIndex)
            }
            lastQuizFiredEntryIndex = q.entryIndex
        }
        currentQuizQueue = []
        quizQueueIndex = 0
        quizSelection = nil
        quizAnyWrong = false
        if anyWrong {
            // User is being sent back to redraw the pass — the next
            // quiz fire shouldn't count as immediately back-to-back.
            lastQuizFiredEntryIndex = nil
            rebuildCanvasesForCurrentEntry()
            phase = .writing
        } else {
            // Don't jump straight to the next sequence step — re-enter
            // advance() so the *other* inline trigger (after-pass-0 vs
            // before-pass-1) still gets evaluated for the same
            // transition window.
            advance()
        }
    }

    private func quizOptionButton(quiz: InterPassQuiz, option: QuizOption) -> some View {
        let answered = quizSelection != nil
        let isCorrect = option.primary == quiz.correct
        let isChosen = option.primary == quizSelection
        let bg: Color = {
            guard answered else { return Theme.card }
            if isCorrect { return Theme.accent.opacity(0.85) }
            if isChosen  { return Theme.warning.opacity(0.85) }
            return Theme.card
        }()
        let fg: Color = (answered && (isCorrect || isChosen))
            ? .white : .primary
        let secondaryFg: Color = (answered && (isCorrect || isChosen))
            ? Color.white.opacity(0.85) : .secondary
        let hasRich = option.pinyin != nil || option.meaning != nil || option.note != nil
        return Button {
            guard quizSelection == nil else { return }
            quizSelection = option.primary
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    // Primary line — sized larger for component-style
                    // options so the hanzi pops; smaller when it's a
                    // descriptive sentence (so a long string can wrap
                    // cleanly without dominating the chip).
                    let primaryIsLong = option.primary.count > 24
                    Text(option.primary)
                        .font(.system(size: primaryIsLong ? 14 : 16,
                                      weight: .semibold))
                        .foregroundStyle(fg)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if hasRich {
                        // Pinyin + meaning on one line so the chip stays
                        // compact ("shuǐ — water"); empty parts collapse.
                        let headline = [option.pinyin, option.meaning]
                            .compactMap { $0 }
                            .filter { !$0.isEmpty }
                            .joined(separator: " — ")
                        if !headline.isEmpty {
                            Text(headline)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(secondaryFg)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let note = option.note, !note.isEmpty {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(secondaryFg)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 0)
                if answered, isCorrect {
                    Image(systemName: "checkmark").foregroundStyle(.white)
                } else if answered, isChosen {
                    Image(systemName: "xmark").foregroundStyle(.white)
                }
            }
            .padding(.vertical, hasRich ? 10 : 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    /// Canvases the user marked "I know this character" — surfaced in
    /// the stroke breakdown as "Skipped (already known)" so the
    /// summary reads honestly instead of pretending they were missed.
    var knownCanvases: Set<Int> = []
    /// Canvases the user explicitly skipped via the long-press menu.
    /// Same treatment as `knownCanvases` in the breakdown, with a
    /// slightly different label.
    var skippedCanvases: Set<Int> = []
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
            return w.displayGloss
        }
        return entry.characters.first?.meaning ?? ""
    }

    var body: some View {
        // The system drag indicator is enabled at the .sheet call site, so
        // we don't draw our own — that produced two stacked indicators.
        ScrollView {
            VStack(spacing: 16) {
                headerContent
                    .padding(.horizontal, 16)
                    .padding(.top, 18)

                strokeBreakdown
                    .padding(.horizontal, 16)

                coachingSection
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
                        // Distinguish deliberate skips (user knew it
                        // or chose to skip it) from "didn't get to" so
                        // the summary doesn't shame the user for
                        // characters they intentionally bypassed.
                        let label: String = {
                            if knownCanvases.contains(idx) {
                                return "Skipped — already known."
                            }
                            if skippedCanvases.contains(idx) {
                                return "Skipped by user."
                            }
                            return "Not yet written."
                        }()
                        Text(label)
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

    /// Per-character coaching hint — runs `StrokeFeedbackAnalyzer`
    /// against each canvas's saved strokes + the MMA medians and
    /// surfaces **the single worst stroke per character** instead of
    /// every flagged stroke. Tonally we want the section to feel like
    /// "the one thing to fix next time", not a checklist of every
    /// micro-deviation. Severity score for picking the worst:
    /// wrongDirection > missingHook > extraneousHook > length tip >
    /// offset tip.
    @ViewBuilder
    private var coachingSection: some View {
        let perCharacter: [(charIdx: Int, char: String, item: StrokeFeedback)] =
            canvases.enumerated().compactMap { idx, canvas in
                guard !canvas.completedUserStrokes.isEmpty,
                      let medians = canvas.graphics?.medians,
                      entry.characters.indices.contains(idx) else { return nil }
                let items: [StrokeFeedback] = canvas.completedUserStrokes
                    .enumerated()
                    .compactMap { strokeIdx, userPoints in
                        guard strokeIdx < medians.count else { return nil }
                        return StrokeFeedbackAnalyzer.analyze(
                            strokeIndex: strokeIdx,
                            userPoints: userPoints,
                            median: medians[strokeIdx])
                    }
                guard let worst = items.max(by: {
                    coachingSeverity($0.tip) < coachingSeverity($1.tip)
                }) else { return nil }
                return (idx, entry.characters[idx].char, worst)
            }
        if !perCharacter.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("ONE THING TO FIX")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                ForEach(perCharacter, id: \.charIdx) { group in
                    if entry.isWord {
                        Text(group.char)
                            .font(Theme.hanzi(16))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, group.charIdx == perCharacter.first?.charIdx ? 0 : 4)
                    }
                    coachingRow(group.item)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accentSoft.opacity(0.55))
            )
        }
    }

    /// Comparator used by `coachingSection.max(by:)` to pick the most
    /// impactful single feedback among a character's strokes. Higher
    /// number wins.
    private func coachingSeverity(_ tip: StrokeFeedback.Tip) -> Int {
        switch tip {
        case .wrongDirection:                       return 5
        case .missingHook:                          return 4
        case .extraneousHook:                       return 3
        case .shorter, .longer:                     return 2
        case .shiftedLeft, .shiftedRight,
             .shiftedUp, .shiftedDown:              return 1
        }
    }

    private func coachingRow(_ feedback: StrokeFeedback) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconForTip(feedback.tip))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Stroke \(feedback.strokeIndex + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(feedback.shape.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text(StrokeFeedbackAnalyzer.describe(feedback.tip, shape: feedback.shape))
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func iconForTip(_ tip: StrokeFeedback.Tip) -> String {
        switch tip {
        case .shorter:           return "arrow.left.and.right"
        case .longer:            return "arrow.left.and.right"
        case .shiftedLeft:       return "arrow.right"
        case .shiftedRight:      return "arrow.left"
        case .shiftedUp:         return "arrow.down"
        case .shiftedDown:       return "arrow.up"
        case .missingHook:       return "arrow.up.right"
        case .extraneousHook:    return "scissors"
        case .wrongDirection:    return "arrow.uturn.backward"
        }
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
