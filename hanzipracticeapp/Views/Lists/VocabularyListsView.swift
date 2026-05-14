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
        let chars = store.characters(for: list.characterIDs)
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
                    Text("\(list.characterIDs.count)")
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
                    ForEach(chars.prefix(6)) { c in
                        Text(c.char)
                            .font(Theme.hanzi(20))
                            .foregroundStyle(Theme.accent)
                    }
                    if chars.count > 6 {
                        Text("+\(chars.count - 6)")
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
    @State private var showingAdd: Bool = false
    @State private var showingPasteImport: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                practiceButton
                if !list.characterIDs.isEmpty { characterList }
                else {
                    Text("No characters yet — tap “Add characters”.")
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
                Text("\(list.characterIDs.count) characters")
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

    private var practiceButton: some View {
        Button {
            session = PracticeSession(characterIDs: list.characterIDs,
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
        .disabled(list.characterIDs.isEmpty)
        .opacity(list.characterIDs.isEmpty ? 0.5 : 1)
    }

    private var characterList: some View {
        VStack(spacing: 8) {
            ForEach(store.characters(for: list.characterIDs)) { c in
                NavigationLink {
                    CharacterDetailView(character: c)
                } label: {
                    HanziListRow(character: c,
                                 accessory: AnyView(
                                    Button {
                                        UserDataController(context: modelContext)
                                            .remove(c.id, from: list)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red.opacity(0.85))
                                            .font(.system(size: 18))
                                    }
                                    .buttonStyle(.plain)
                                 ))
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.card)
                    )
                }
                .buttonStyle(.plain)
            }
        }
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
                // Showing all 9,500 characters would be wasteful — guide the
                // user to search instead when the query is empty.
                let results: [HanziCharacter] = query.isEmpty
                    ? store.trending
                    : store.search(query)
                if query.isEmpty {
                    Text("Search for a character, pinyin, or English word above.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                ForEach(results) { c in
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
                        if list.characterIDs.contains(c.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.accent)
                        } else {
                            Button {
                                UserDataController(context: modelContext)
                                    .add(c.id, to: list)
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

    private var orderedHanzi: [String] {
        VocabularyTextImport.hanziInOrder(from: pastedText)
    }

    private var uniqueCanonical: [String] {
        VocabularyTextImport.uniqueCanonicalSequence(orderedHanzi) { store.canonical($0) }
    }

    /// Canonical ids that exist in the bundled dictionary / MMA index.
    private var recognizedIDs: [String] {
        uniqueCanonical.filter { store.character(for: $0) != nil }
    }

    private var skippedUnknown: [String] {
        uniqueCanonical.filter { store.character(for: $0) == nil }
    }

    /// When importing into a fixed list: how many recognized chars are new rows.
    private var newEntriesForLockedList: Int {
        guard let list = lockedList else { return recognizedIDs.count }
        return recognizedIDs.filter { !list.characterIDs.contains($0) }.count
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
                    Text("Commas, Chinese commas (，)、spaces, and English text are ignored — each Hanzi becomes one flashcard entry. Duplicates collapse to a single character.")
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
                    LabeledContent("Hanzi found") {
                        Text("\(orderedHanzi.count)")
                    }
                    LabeledContent("Unique (after dedupe)") {
                        Text("\(uniqueCanonical.count)")
                    }
                    LabeledContent("In dictionary") {
                        Text("\(recognizedIDs.count)")
                            .foregroundStyle(recognizedIDs.isEmpty ? .secondary : Theme.accent)
                            .fontWeight(.semibold)
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
                ? "Add \(newEntriesForLockedList) character\(newEntriesForLockedList == 1 ? "" : "s")"
                : "Nothing new to add"
        }
        if createNewList {
            return recognizedIDs.isEmpty ? "Nothing to import"
                : "Create list with \(recognizedIDs.count) character\(recognizedIDs.count == 1 ? "" : "s")"
        }
        return recognizedIDs.isEmpty ? "Nothing to import"
            : "Add \(recognizedIDs.count) to list"
    }

    private var canImport: Bool {
        guard !recognizedIDs.isEmpty else { return false }
        if lockedList != nil { return newEntriesForLockedList > 0 }
        if createNewList { return true }
        guard !lists.isEmpty else { return false }
        let id = selectedListID ?? lists.first?.id
        return id != nil
    }

    private func performImport() {
        let controller = UserDataController(context: modelContext)
        let ids = recognizedIDs
        guard !ids.isEmpty else { return }

        if let list = lockedList {
            controller.addMany(ids, to: list)
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
            controller.addMany(ids, to: target)
        }

        dismiss()
    }
}
