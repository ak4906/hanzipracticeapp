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
    @Query private var settingsList: [UserSettings]

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

    enum Phase: Hashable {
        case writing       // user is drawing
        case grading       // showing summary + SRS buttons
        case finished      // whole session done
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

    /// Pre-built (entryIndex, pass) order for the whole session — generated
    /// from `(entries, mode, chunkSize)`. For adaptive mode this is just a
    /// flat single-pass walk.
    private var sequence: [(entryIndex: Int, pass: Int)] {
        buildSequence(passCount: practiceMode.passCount,
                      chunkSize: chunkSize,
                      count: practiceEntries.count)
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
                        } else if let entry = currentEntry {
                            VStack(spacing: 14) {
                                cardHeader(for: entry)
                                quickActionsRow(for: entry)
                                canvasRow(for: entry)
                                controls(for: entry)
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
                // Find the entry we were on under the OLD mode/chunking and
                // jump to that entry's pass-0 position in the new sequence.
                // Without this the index could land out-of-bounds (e.g.
                // switching `.threePass` → `.adaptive` shrinks the sequence
                // by 3×) or on the wrong entry.
                let oldSequence = buildSequence(passCount: oldValue.passCount,
                                                chunkSize: chunkSize,
                                                count: practiceEntries.count)
                let priorEntry = oldSequence.indices.contains(index)
                    ? oldSequence[index].entryIndex
                    : 0
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

    /// Header shown above the writing canvases — pinyin, meaning, and the
    /// "Stroke N of M" indicator for the currently-active char (with its
    /// hint-mode pill). Tapping the row peeks at the character/word detail.
    private func cardHeader(for entry: PracticeEntry) -> some View {
        let activeChar = entry.characters.indices.contains(activeCharIndex)
            ? entry.characters[activeCharIndex] : nil
        let pinyin = entryPinyin(entry)
        let meaning = entryMeaning(entry)
        return Button {
            // For multi-char entries we peek the currently-active char so
            // the user can quickly check stroke order for that specific
            // hanzi. (A word-level detail view could come later.)
            peekCharacter = activeChar
        } label: {
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
        .buttonStyle(.plain)
    }

    /// Pinyin for the whole entry. Multi-char looks up CC-CEDICT; single-char
    /// uses the MMA per-character pinyin (which already has tone marks).
    private func entryPinyin(_ entry: PracticeEntry) -> String {
        if entry.isWord, let w = WordDictionary.shared.entry(for: entry.word) {
            return w.pinyin
        }
        return entry.characters.first?.pinyin ?? ""
    }

    /// English meaning for the entry — CC-CEDICT gloss for words, MMA
    /// definition for single chars.
    private func entryMeaning(_ entry: PracticeEntry) -> String {
        if entry.isWord, let w = WordDictionary.shared.entry(for: entry.word) {
            return w.gloss
        }
        return entry.characters.first?.meaning ?? ""
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

    /// Side-by-side row of canvases for the current entry. The active canvas
    /// is full-opacity and accepts input; completed / pending canvases are
    /// dimmed. When the user finishes the active canvas's last stroke we
    /// advance `activeCharIndex` automatically.
    @ViewBuilder
    private func canvasRow(for entry: PracticeEntry) -> some View {
        if canvases.isEmpty {
            Color.clear.aspectRatio(1, contentMode: .fit)
        } else if canvases.count == 1 {
            // Fast path for the (very common) single-character entry — no
            // HStack overhead, full canvas size.
            singleCanvas(canvases[0], index: 0)
        } else {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(canvases.enumerated()), id: \.offset) { idx, model in
                    singleCanvas(model, index: idx)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    /// One canvas in the row, with the tap-to-activate behaviour and the
    /// stroke-completion callback that drives the per-entry advance state
    /// machine.
    @ViewBuilder
    private func singleCanvas(_ model: WritingCanvasModel, index idx: Int) -> some View {
        let isActive = idx == activeCharIndex
        WritingCanvas(model: model) { _ in
            // Stroke accepted. If this canvas has now completed all its
            // strokes, advance within (or past) the entry. Delay slightly
            // so the user sees the accepted-stroke flash.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                handleStrokeAccepted(forCanvasAt: idx)
            }
        }
        .opacity(isActive ? 1 : 0.55)
        .allowsHitTesting(isActive)
        .overlay(alignment: .topLeading) {
            if canvases.count > 1 {
                Text("\(idx + 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(isActive ? Theme.accent : Color.secondary))
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap an inactive canvas to re-focus it (e.g. user wants to
            // redo or skip ahead). Only allowed for chars that have ALREADY
            // been finished or are still pending — current behaviour
            // matches user expectations of standard segmented writing.
            if idx != activeCharIndex {
                activeCharIndex = idx
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
        if activeCharIndex + 1 < canvases.count {
            activeCharIndex += 1
        } else if isGradingStep {
            phase = .grading
        } else {
            advance()
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
        activeCharIndex = 0
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
    private func applyGrade(_ grade: SRSGrade, for entry: PracticeEntry) {
        let controller = UserDataController(context: modelContext)
        let card = controller.ensureCard(for: entry.word)
        SRSEngine.apply(grade: grade, to: card)

        let count = max(1, canvases.count)
        let avgAccuracy = canvases.map(\.averageAccuracy).reduce(0, +) / Double(count)
        let totalRetries = canvases.map(\.totalRetries).reduce(0, +)
        let totalDuration = canvases.map(\.elapsedSeconds).reduce(0, +)
        controller.recordPractice(characterID: entry.word,
                                  accuracy: avgAccuracy,
                                  retries: totalRetries,
                                  duration: totalDuration,
                                  kind: "writing")

        sessionResults[entry.word] = avgAccuracy
        advance()
    }

    /// Move forward by one step, honouring `skippedEntries` so a dropped
    /// entry can't reappear on its next pass.
    private func advance() {
        guard totalSteps > 0 else {
            phase = .finished
            return
        }
        advanceToNextVisible()
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
    /// Optional sheet for the entry's detail page — tap the header to open.
    /// For multi-char entries we open the *first* character; a true
    /// word-detail screen is a future enhancement.
    @State private var showingDetail: Bool = false

    /// Averaged accuracy across every char's canvas. Used by the SRS card
    /// preview-interval display and as the "this attempt" headline number.
    private var averageAccuracy: Double {
        guard !canvases.isEmpty else { return 0 }
        return canvases.map(\.averageAccuracy).reduce(0, +) / Double(canvases.count)
    }

    private var pinyin: String {
        if entry.isWord, let w = WordDictionary.shared.entry(for: entry.word) {
            return w.pinyin
        }
        return entry.characters.first?.pinyin ?? ""
    }

    private var meaning: String {
        if entry.isWord, let w = WordDictionary.shared.entry(for: entry.word) {
            return w.gloss
        }
        return entry.characters.first?.meaning ?? ""
    }

    var body: some View {
        // The system drag indicator is enabled at the .sheet call site, so
        // we don't draw our own — that produced two stacked indicators.
        VStack(spacing: 16) {
            Button {
                showingDetail = true
            } label: {
                HStack(spacing: 8) {
                    Text(entry.word)
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
            card = UserDataController(context: modelContext).ensureCard(for: entry.word)
        }
        .sheet(isPresented: $showingDetail) {
            NavigationStack {
                if let first = entry.characters.first {
                    CharacterDetailView(character: first)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showingDetail = false }
                                    .font(.system(size: 15, weight: .semibold))
                            }
                        }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
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
