//
//  QuizView.swift
//  hanzipracticeapp
//
//  Self-graded recall quiz over a list of entries — used for both the
//  reading mode (show hanzi, recall pinyin) and the translation mode
//  (show hanzi, recall English meaning). One pass per entry; the user
//  taps to reveal the answer and self-grades Again / Hard / Good / Easy.
//
//  The SRS state is stored on `SRSQuizCard`, keyed by (entry, mode), so
//  reading and translation progress live independently of writing
//  practice — knowing how to recognise 容易 doesn't imply you can write
//  it, and vice versa.
//

import SwiftUI
import SwiftData

struct QuizSession: Identifiable, Hashable {
    let id = UUID()
    let entries: [String]
    let title: String
    let mode: QuizMode
}

struct QuizView: View {
    let session: QuizSession
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(CharacterStore.self) private var store

    @State private var index: Int = 0
    @State private var revealed: Bool = false
    @State private var phase: Phase = .quizzing
    @State private var sessionStarted: Date = .now
    /// Entry word → grade chosen on this attempt. Used by the finished
    /// view to summarise how the session went.
    @State private var sessionResults: [String: SRSGrade] = [:]
    /// Entry indices the user has dropped (via "Skip for now").
    @State private var skippedEntries: Set<Int> = []
    /// Sheet for tapping a constituent character to see its detail page.
    @State private var peekChar: HanziCharacter? = nil
    /// Sheet for tapping a multi-char entry's prompt — opens word detail.
    @State private var peekWord: WordEntry? = nil

    enum Phase: Hashable {
        case quizzing
        case finished
    }

    // MARK: - Derived

    private var entries: [String] {
        // Dedupe by canonical key, preserving order.
        var seen = Set<String>()
        return session.entries.filter { seen.insert($0).inserted }
    }

    private var currentEntry: String? {
        entries.indices.contains(min(index, entries.count - 1)) ? entries[min(index, entries.count - 1)] : nil
    }

    /// Resolved hanzi for the current entry (in display order).
    private var currentCharacters: [HanziCharacter] {
        guard let entry = currentEntry else { return [] }
        return entry.compactMap { store.character(for: String($0)) }
    }

    private var totalCount: Int { entries.count }

    private var pinyin: String {
        guard let entry = currentEntry else { return "" }
        if entry.count > 1 {
            if let w = WordDictionary.shared.entry(for: entry) { return w.pinyin }
            // Fallback for multi-char entries CC-CEDICT doesn't know — give
            // the user *something* (per-char pinyins joined) rather than
            // misleadingly showing only the first char's pronunciation.
            return currentCharacters.map(\.pinyin).joined(separator: " ")
        }
        return currentCharacters.first?.pinyin ?? ""
    }

    private var meaning: String {
        guard let entry = currentEntry else { return "" }
        if entry.count > 1 {
            if let w = WordDictionary.shared.entry(for: entry) { return w.gloss }
            // Unknown word — best we can do is list the constituent chars'
            // individual glosses so the quiz isn't useless.
            return currentCharacters.map(\.meaning).joined(separator: " · ")
        }
        return currentCharacters.first?.meaning ?? ""
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyQueueView
                } else if phase == .finished {
                    finishedView
                } else {
                    quizContent
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
                    .accessibilityLabel("Close session")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(session.title)
                            .font(.system(size: 15, weight: .semibold))
                        Text(session.mode.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if !entries.isEmpty, phase != .finished {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            phase = .finished
                        } label: {
                            Text("Finish")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
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
    }

    private var emptyQueueView: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 32)
            Image(systemName: "questionmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent.opacity(0.85))
            Text("Nothing to quiz")
                .font(.system(size: 20, weight: .bold))
            Text("There are no entries in this session. Close and add items first.")
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

    private var quizContent: some View {
        VStack(spacing: 18) {
            progressHeader
            entryCard
            if revealed {
                revealedCard
                gradeButtons
            } else {
                revealButton
                quickActionsRow
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var progressHeader: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(min(index + 1, totalCount)) / \(totalCount)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Label(session.mode.displayName, systemImage: session.mode.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accentSoft))
            }
            ProgressView(value: Double(min(index, totalCount)),
                         total: Double(totalCount))
                .tint(Theme.accent)
        }
    }

    /// Big card showing the hanzi (the *prompt* — what the user is being
    /// asked to recall about). For multi-char entries this becomes a Menu
    /// so the user can peek individual characters.
    @ViewBuilder
    private var entryCard: some View {
        let entry = currentEntry ?? ""
        let card = VStack(spacing: 8) {
            Text(store.displayedWord(entry))
                .font(Theme.hanzi(80))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Text("Recall the \(session.mode.promptWord)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.card)
        )

        if currentCharacters.count > 1 {
            Button {
                let entry = currentEntry ?? ""
                peekWord = WordDictionary.shared.entry(for: entry)
                    ?? WordEntry(simplified: entry,
                                 traditional: entry,
                                 pinyin: pinyin,
                                 gloss: meaning)
            } label: {
                card
            }
            .buttonStyle(.plain)
        } else if let c = currentCharacters.first {
            Button {
                peekChar = c
            } label: {
                card
            }
            .buttonStyle(.plain)
        } else {
            card
        }
    }

    private var revealButton: some View {
        Button {
            withAnimation { revealed = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                Text("Reveal \(session.mode.promptWord)")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accent)
            )
        }
        .buttonStyle(.plain)
    }

    private var revealedCard: some View {
        // Show both pinyin AND meaning regardless of mode — the one the
        // user was asked to recall is emphasised, but the other is right
        // there too. Saves them a separate dictionary lookup when they
        // realise they knew the meaning but not the pronunciation (or
        // vice versa).
        VStack(alignment: .leading, spacing: 14) {
            revealedRow(label: "PINYIN",
                        value: pinyin,
                        valueFont: .system(size: 28, weight: .semibold, design: .serif),
                        emphasised: session.mode == .reading)
            Divider()
            revealedRow(label: "MEANING",
                        value: meaning,
                        valueFont: .system(size: 18, weight: .semibold),
                        emphasised: session.mode == .translation)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.accentSoft.opacity(0.5))
        )
    }

    private func revealedRow(label: String,
                              value: String,
                              valueFont: Font,
                              emphasised: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text(value)
                .font(valueFont)
                .foregroundStyle(emphasised ? Theme.accent : .primary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gradeButtons: some View {
        let card = currentEntry.map {
            UserDataController(context: modelContext).ensureQuizCard(for: $0, mode: session.mode)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("How well did you remember it?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(SRSGrade.allCases) { grade in
                    Button {
                        applyGrade(grade)
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
    }

    private var quickActionsRow: some View {
        HStack(spacing: 8) {
            Button {
                markKnown()
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

    private var finishedView: some View {
        let practised = sessionResults.count
        let total = totalCount
        let remaining = max(0, total - practised)
        let again = sessionResults.values.filter { $0 == .again }.count
        let mastered = sessionResults.values.filter { $0 == .easy || $0 == .good }.count
        let duration = Int(Date.now.timeIntervalSince(sessionStarted))
        return VStack(spacing: 18) {
            Image(systemName: practised < total ? "pause.circle.fill" : "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text(practised < total ? "Stopped early" : "Session complete!")
                .font(.system(size: 24, weight: .bold))
            VStack(spacing: 6) {
                Text("\(practised) of \(total) reviewed")
                Text("\(mastered) recalled · \(again) missed")
                Text("Time: \(duration / 60)m \(duration % 60)s")
                if remaining > 0 {
                    Text("\(remaining) still due — they'll come back.")
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

    // MARK: - SRS

    private func applyGrade(_ grade: SRSGrade) {
        guard let entry = currentEntry else { return }
        let controller = UserDataController(context: modelContext)
        let card = controller.ensureQuizCard(for: entry, mode: session.mode)
        SRSEngine.apply(grade: grade, to: card)
        try? modelContext.save()
        sessionResults[entry] = grade
        // Note: we deliberately do *not* propagate quiz grades to the
        // individual characters' quiz cards. Recognising 容易 doesn't
        // imply you can read 容 / 易 in isolation; same for translation.
        advance()
    }

    private func markKnown() {
        applyGrade(.easy)
    }

    private func skipEntry() {
        guard let _ = currentEntry else { return }
        skippedEntries.insert(index)
        advance()
    }

    private func advance() {
        revealed = false
        if index + 1 >= entries.count {
            phase = .finished
        } else {
            index += 1
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
