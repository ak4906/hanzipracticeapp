//
//  VocabularyListsView.swift
//  hanzipracticeapp
//
//  Manage user-created vocabulary lists.
//

import SwiftUI
import SwiftData

struct VocabularyListsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(CharacterStore.self) private var store

    /// Unsorted fetch — composite `@Query(sort:)` has proven flaky with schema churn; sort in memory instead.
    @Query private var listsRaw: [VocabularyList]

    private var lists: [VocabularyList] { listsRaw.sortedForDisplay() }

    @State private var showingNew: Bool = false
    @State private var showingPasteImport: Bool = false
    @State private var editMode: EditMode = .inactive

    var body: some View {
        Group {
            if lists.isEmpty {
                ScrollView {
                    emptyState
                        .padding(16)
                }
            } else {
                List {
                    ForEach(lists) { list in
                        NavigationLink {
                            ListDetailView(list: list)
                        } label: {
                            listTile(list)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .onDelete(perform: deleteLists)
                    .onMove(perform: moveLists)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Vocabulary Lists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if !lists.isEmpty {
                        EditButton()
                    }
                    Button { showingPasteImport = true } label: {
                        Image(systemName: "doc.text.viewfinder")
                    }
                    .accessibilityLabel("Import from text")
                    Button { showingNew = true } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("New list")
                }
            }
        }
        .sheet(isPresented: $showingNew) {
            NewListSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingPasteImport) {
            BulkListImportSheet(lockedList: nil)
                .presentationDetents([.large])
        }
    }

    private func deleteLists(at offsets: IndexSet) {
        let controller = UserDataController(context: modelContext)
        for i in offsets {
            guard lists.indices.contains(i) else { continue }
            controller.deleteList(lists[i])
        }
    }

    private func moveLists(from source: IndexSet, to destination: Int) {
        var ordered = lists
        ordered.move(fromOffsets: source, toOffset: destination)
        for (rank, list) in ordered.enumerated() {
            list.sortRank = rank
        }
        try? modelContext.save()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
                .padding(.top, 30)
            Text("Build your own deck")
                .font(.system(size: 18, weight: .bold))
            Text("Tap + to start a new list, or import many characters at once from pasted text. Add characters from the Dictionary too, then practice here.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button { showingNew = true } label: {
                Text("Create my first list")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.accent))
            }
            .padding(.top, 6)
        }
        .padding(.vertical, 24)
    }

    private func listTile(_ list: VocabularyList) -> some View {
        let entries = list.effectiveEntries
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                Image(systemName: list.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(hex: UInt32(list.colorHex)))
                    )
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(list.name)
                        .font(.system(size: 16, weight: .bold))
                    Spacer()
                    Text("\(entries.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if !list.detail.isEmpty {
                    Text(list.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    ForEach(entries.prefix(6), id: \.self) { entry in
                        Text(store.displayedWord(entry))
                            .font(Theme.hanzi(20))
                            .foregroundStyle(Theme.accent)
                    }
                    if entries.count > 6 {
                        Text("+\(entries.count - 6)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.card)
        )
    }
}

// MARK: - List detail

struct ListDetailView: View {
    @Bindable var list: VocabularyList
    @Environment(\.modelContext) private var modelContext
    @Environment(CharacterStore.self) private var store

    @State private var session: PracticeSession? = nil
    @State private var quizSession: QuizSession? = nil
    @State private var showingAdd: Bool = false
    @State private var showingPasteImport: Bool = false
    /// Per-session toggle: when on, entries are shuffled before each
    /// practice run instead of going in list order.
    @State private var shuffleOnPractice: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                practiceControls
                if !list.effectiveEntries.isEmpty { entryList }
                else {
                    Text("No entries yet — tap “Add” or paste in text.")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingPasteImport = true } label: {
                    Image(systemName: "doc.text.viewfinder")
                }
                .accessibilityLabel("Paste characters")
                Button { showingAdd = true } label: {
                    Label("Add characters", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddCharactersSheet(list: list)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showingPasteImport) {
            BulkListImportSheet(lockedList: list)
                .presentationDetents([.large])
        }
        .fullScreenCover(item: $session) { s in
            WritingSessionView(session: s) { session = nil }
        }
        .fullScreenCover(item: $quizSession) { q in
            QuizView(session: q) { quizSession = nil }
        }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            Image(systemName: list.symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(hex: UInt32(list.colorHex)))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(list.entryCountSummary)
                    .font(.system(size: 15, weight: .semibold))
                Text("Created \(list.dateCreated.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.card)
        )
    }

    private var practiceControls: some View {
        let disabled = list.effectiveEntries.isEmpty
        return VStack(spacing: 10) {
            Toggle(isOn: $shuffleOnPractice) {
                Label("Shuffle order", systemImage: "shuffle")
                    .font(.system(size: 14, weight: .semibold))
            }
            .tint(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.card)
            )
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)

            // Primary "practice writing" button — full width, accent color,
            // since writing is the deepest form of practice and the most
            // common starting point.
            Button {
                session = PracticeSession(entries: orderedEntries(),
                                          title: list.name)
            } label: {
                HStack {
                    Image(systemName: "applepencil.and.scribble")
                    Text("Practice writing")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.accent)
                )
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)

            // Secondary quiz buttons — smaller, side by side. Reading +
            // translation are independent skills, tracked on a separate
            // SRS deck per mode (`SRSQuizCard`).
            HStack(spacing: 10) {
                quizButton(mode: .reading)
                quizButton(mode: .translation)
            }
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)
        }
    }

    private func quizButton(mode: QuizMode) -> some View {
        Button {
            quizSession = QuizSession(entries: orderedEntries(),
                                      title: list.name,
                                      mode: mode)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.systemImage)
                Text(mode.displayName)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accentSoft.opacity(0.6))
            )
        }
        .buttonStyle(.plain)
    }

    /// Apply the per-session shuffle toggle to the list's effective entries.
    /// Used by both writing and quiz starts so the order policy is shared.
    private func orderedEntries() -> [String] {
        shuffleOnPractice
            ? list.effectiveEntries.shuffled()
            : list.effectiveEntries
    }

    /// One row per word entry. Multi-character entries (容易) get a
    /// word-shaped row backed by CC-CEDICT; single-character entries fall
    /// back to the existing per-hanzi row backed by MMA.
    private var entryList: some View {
        VStack(spacing: 8) {
            ForEach(list.effectiveEntries, id: \.self) { entry in
                if entry.count > 1 {
                    wordRow(entry)
                } else if let c = store.character(for: entry) {
                    NavigationLink {
                        CharacterDetailView(character: c)
                    } label: {
                        HanziListRow(character: c,
                                     accessory: AnyView(removeButton(for: entry)))
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Theme.card)
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    // Entry references a hanzi we don't have in the dictionary
                    // (rare but possible). Still let the user remove it.
                    HStack {
                        Text(store.displayedWord(entry))
                            .font(Theme.hanzi(28))
                            .foregroundStyle(Theme.accent)
                        Spacer()
                        removeButton(for: entry)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.card)
                    )
                }
            }
        }
    }

    /// Display row for a multi-character word (容易). Pulls pinyin + gloss
    /// from CC-CEDICT; tapping opens a word-detail sheet (Phase B+).
    private func wordRow(_ word: String) -> some View {
        let entry = WordDictionary.shared.entry(for: word)
        return HStack(spacing: 14) {
            Text(store.displayedWord(word))
                .font(Theme.hanzi(28, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if let entry {
                    Text(entry.pinyin)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(entry.firstGloss)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                } else {
                    Text("Word")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Custom entry — no dictionary match.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            removeButton(for: word)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card)
        )
    }

    private func removeButton(for entry: String) -> some View {
        Button {
            UserDataController(context: modelContext).remove(entry, from: list)
        } label: {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red.opacity(0.85))
                .font(.system(size: 18))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - New list sheet

struct NewListSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var detail: String = ""
    @State private var symbol: String = "bookmark.fill"
    @State private var colorHex: UInt32 = 0x266358

    private let symbols = ["bookmark.fill", "book.closed.fill", "graduationcap.fill",
                           "star.fill", "flame.fill", "leaf.fill", "heart.fill",
                           "sparkles", "books.vertical.fill"]
    private let colors: [UInt32] = [0x266358, 0xCE5757, 0xC9A13C, 0x6789C2,
                                    0x8C5BAF, 0x4F8A6B, 0xD08770]

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. HSK 1, Travel Words", text: $name)
                    TextField("Optional description", text: $detail, axis: .vertical)
                        .lineLimit(2, reservesSpace: false)
                }
                Section("Icon") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(symbols, id: \.self) { s in
                                Button { symbol = s } label: {
                                    Image(systemName: s)
                                        .frame(width: 40, height: 40)
                                        .background(Circle().fill(Theme.accentSoft))
                                        .overlay(
                                            Circle().stroke(symbol == s ? Theme.accent : .clear,
                                                            lineWidth: 2)
                                        )
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }
                Section("Colour") {
                    HStack(spacing: 10) {
                        ForEach(colors, id: \.self) { hex in
                            Button { colorHex = hex } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle().stroke(colorHex == hex ? Color.primary : .clear,
                                                        lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("New List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { performCreate() }
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    /// Inserts the new VocabularyList and dismisses. We force a save *before*
    /// `dismiss()` so the parent's `@Query` re-fetch sees the new row instead
    /// of racing the sheet tear-down.
    private func performCreate() {
        let controller = UserDataController(context: modelContext)
        _ = controller.createList(name: trimmedName,
                                   detail: detail,
                                   symbol: symbol,
                                   colorHex: Int(colorHex))
        dismiss()
    }
}

// MARK: - Add characters

struct AddCharactersSheet: View {
    @Bindable var list: VocabularyList
    @Environment(\.modelContext) private var modelContext
    @Environment(CharacterStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var showingPasteImport: Bool = false

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        Text("Search for a character, word, pinyin, or English meaning.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Section("Trending") {
                        ForEach(store.trending) { c in
                            characterRow(c)
                        }
                    }
                } else {
                    let words = WordDictionary.shared.search(query, limit: 20)
                    if !words.isEmpty {
                        Section("Words") {
                            ForEach(words) { w in
                                wordRow(w)
                            }
                        }
                    }
                    let chars = store.search(query)
                    if !chars.isEmpty {
                        Section("Characters") {
                            ForEach(chars) { c in
                                characterRow(c)
                            }
                        }
                    }
                    if words.isEmpty && chars.isEmpty {
                        Text("No matches.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search hanzi, pinyin, English")
            .navigationTitle("Add to \(list.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        showingPasteImport = true
                    } label: {
                        Label("Paste text import", systemImage: "doc.text.viewfinder")
                    }
                }
            }
            .sheet(isPresented: $showingPasteImport) {
                BulkListImportSheet(lockedList: list)
                    .presentationDetents([.large])
            }
        }
    }

    private func characterRow(_ c: HanziCharacter) -> some View {
        HStack {
            Text(c.char)
                .font(Theme.hanzi(28))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(Theme.surface)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(c.pinyin).font(.system(size: 14, weight: .semibold))
                Text(c.meaning).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if list.effectiveEntries.contains(c.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            } else {
                Button {
                    UserDataController(context: modelContext)
                        .addEntry(c.id, to: list)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Word-level row (multi-char) drawn from CC-CEDICT.
    private func wordRow(_ w: WordEntry) -> some View {
        HStack(spacing: 12) {
            Text(store.displayedWord(w.simplified))
                .font(Theme.hanzi(24))
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(w.pinyin).font(.system(size: 14, weight: .semibold))
                Text(w.firstGloss)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if list.effectiveEntries.contains(w.simplified) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            } else {
                Button {
                    UserDataController(context: modelContext)
                        .addEntry(w.simplified, to: list)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Paste / bulk text import

struct BulkListImportSheet: View {
    /// When set, characters are appended only to this list (detail-screen flow).
    var lockedList: VocabularyList?

    @Environment(\.modelContext) private var modelContext
    @Environment(CharacterStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @Query private var listsRaw: [VocabularyList]

    private var lists: [VocabularyList] { listsRaw.sortedForDisplay() }

    @State private var pastedText: String = ""
    @State private var createNewList: Bool = true
    @State private var newListName: String = ""
    @State private var selectedListID: UUID?

    /// Already canonicalised + deduped — see `wordsInOrder`'s doc-comment
    /// for why dedupe lives there now (so 收養 (收养) annotations don't
    /// produce three entries).
    private var orderedWords: [String] {
        VocabularyTextImport.wordsInOrder(from: pastedText,
                                          using: WordDictionary.shared)
    }

    /// Tokens we have either a dictionary entry (multi-char) or an MMA
    /// character record (single-char) for.
    private var recognizedEntries: [String] {
        orderedWords.filter { token in
            if token.count > 1 {
                return WordDictionary.shared.contains(token)
            }
            return store.character(for: token) != nil
        }
    }

    private var skippedUnknown: [String] {
        orderedWords.filter { token in
            if token.count > 1 { return !WordDictionary.shared.contains(token) }
            return store.character(for: token) == nil
        }
    }

    /// When importing into a fixed list: how many recognised tokens would be new rows.
    private var newEntriesForLockedList: Int {
        guard let list = lockedList else { return recognizedEntries.count }
        let existing = Set(list.effectiveEntries)
        return recognizedEntries.filter { !existing.contains($0) }.count
    }

    /// Multi-char word count (for the preview label).
    private var multiWordCount: Int {
        recognizedEntries.filter { $0.count > 1 }.count
    }

    private var navTitle: String {
        if let list = lockedList {
            return "Import into \(list.name)"
        }
        return "Import from text"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $pastedText)
                        .frame(minHeight: 140)
                        .font(.system(size: 17))
                } header: {
                    Text("Paste words or sentences")
                } footer: {
                    Text("Each word becomes one entry. Multi-character words like 容易 or 冰激凌 are detected automatically using the CC-CEDICT dictionary; unknown characters fall through as single hanzi. Punctuation, spaces, and English text are ignored.")
                }

                if lockedList == nil {
                    Section("Add to") {
                        Picker("Destination", selection: $createNewList) {
                            Text("New list").tag(true)
                            Text("Existing list").tag(false)
                        }
                        .pickerStyle(.segmented)

                        if createNewList {
                            TextField("List name", text: $newListName)
                                .textInputAutocapitalization(.words)
                        } else {
                            if lists.isEmpty {
                                Text("Create a list first, or switch to “New list”.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("List", selection: Binding(
                                    get: { selectedListID ?? lists.first!.id },
                                    set: { selectedListID = $0 }
                                )) {
                                    ForEach(lists) { list in
                                        Text(list.name).tag(list.id)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Preview") {
                    LabeledContent("Entries detected") {
                        Text("\(orderedWords.count)")
                    }
                    LabeledContent("Recognised") {
                        Text("\(recognizedEntries.count)")
                            .foregroundStyle(recognizedEntries.isEmpty ? .secondary : Theme.accent)
                            .fontWeight(.semibold)
                    }
                    if multiWordCount > 0 {
                        LabeledContent("Multi-char words") {
                            Text("\(multiWordCount)")
                                .foregroundStyle(Theme.accent)
                                .fontWeight(.semibold)
                        }
                    }
                    if !skippedUnknown.isEmpty {
                        LabeledContent("Not in app") {
                            Text(skippedUnknown.map { store.displayed($0) }.joined(separator: " "))
                                .font(Theme.hanzi(17))
                                .lineLimit(3)
                        }
                    }
                    if lockedList != nil {
                        LabeledContent("New to this list") {
                            Text("\(newEntriesForLockedList)")
                        }
                    }
                }

                Section {
                    Button {
                        performImport()
                    } label: {
                        Text(importButtonTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!canImport)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if selectedListID == nil { selectedListID = lists.first?.id }
            }
        }
    }

    private var importButtonTitle: String {
        if lockedList != nil {
            return newEntriesForLockedList > 0
                ? "Add \(newEntriesForLockedList) " + (newEntriesForLockedList == 1 ? "entry" : "entries")
                : "Nothing new to add"
        }
        if createNewList {
            return recognizedEntries.isEmpty ? "Nothing to import"
                : "Create list with \(recognizedEntries.count) " + (recognizedEntries.count == 1 ? "entry" : "entries")
        }
        return recognizedEntries.isEmpty ? "Nothing to import"
            : "Add \(recognizedEntries.count) to list"
    }

    private var canImport: Bool {
        guard !recognizedEntries.isEmpty else { return false }
        if lockedList != nil { return newEntriesForLockedList > 0 }
        if createNewList { return true }
        guard !lists.isEmpty else { return false }
        let id = selectedListID ?? lists.first?.id
        return id != nil
    }

    private func performImport() {
        let controller = UserDataController(context: modelContext)
        let ids = recognizedEntries
        guard !ids.isEmpty else { return }

        if let list = lockedList {
            controller.addManyEntries(ids, to: list)
            dismiss()
            return
        }

        if createNewList {
            let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty
                ? "Imported \(Date().formatted(date: .abbreviated, time: .omitted))"
                : trimmed
            _ = controller.createList(name: name, initial: ids)
        } else if let lid = selectedListID ?? lists.first?.id,
                  let target = lists.first(where: { $0.id == lid }) {
            controller.addManyEntries(ids, to: target)
        }

        dismiss()
    }
}
