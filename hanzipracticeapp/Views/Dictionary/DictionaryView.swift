//
//  DictionaryView.swift
//  hanzipracticeapp
//
//  Search hanzi by character, pinyin, or English meaning. Surfaces recently
//  viewed entries and a trending grid when the search field is empty.
//

import SwiftUI
import SwiftData

/// Routes for the Dictionary tab’s single `NavigationStack` — keeps programmatic
/// pushes (vocabulary lists) on the same typed path as character detail so SwiftData’s
/// model environment and `@Query` updates stay wired correctly.
private enum DictionaryNav: Hashable {
    case vocabularyLists
    case character(HanziCharacter)
}

struct DictionaryView: View {
    @Environment(CharacterStore.self) private var store
    @Environment(\.modelContext) private var modelContext

    /// When Home taps “See all”, this flips true so we push Manage Lists once.
    @Binding var jumpToLists: Bool

    @Query(sort: \RecentLookup.lastViewed, order: .reverse) private var recents: [RecentLookup]

    @State private var query: String = ""
    @State private var mode: CharacterStore.SearchMode = .auto
    @State private var path: [DictionaryNav] = []

    init(jumpToLists: Binding<Bool> = .constant(false)) {
        _jumpToLists = jumpToLists
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    searchBar
                    modePicker
                    if query.isEmpty {
                        if !recents.isEmpty { recentlyViewed }
                        trendingGrid
                        writePracticeCTA
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Dictionary")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        path.append(.vocabularyLists)
                    } label: {
                        Image(systemName: "books.vertical")
                    }
                    .accessibilityLabel("Vocabulary lists")
                    NavigationLink {
                        BrowseAllView()
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .accessibilityLabel("Browse")
                }
            }
            .navigationDestination(for: DictionaryNav.self) { nav in
                switch nav {
                case .vocabularyLists:
                    VocabularyListsView()
                case .character(let c):
                    CharacterDetailView(character: c)
                }
            }
            .onChange(of: jumpToLists) { _, _ in
                consumeJumpToListsIfNeeded()
            }
            .onAppear {
                consumeJumpToListsIfNeeded()
            }
        }
    }

    /// Home’s “See all” / jump flag may be set while this tab appears; handle
    /// it once whether we get `onAppear` or `onChange` first.
    private func consumeJumpToListsIfNeeded() {
        guard jumpToLists else { return }
        jumpToLists = false
        path.append(.vocabularyLists)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Hanzi, pinyin, English…", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.card)
        )
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Character").tag(CharacterStore.SearchMode.hanzi)
            Text("Pinyin").tag(CharacterStore.SearchMode.pinyin)
            Text("English").tag(CharacterStore.SearchMode.english)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Empty state sections

    private var recentlyViewed: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recently Viewed")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Button("Clear All") {
                    UserDataController(context: modelContext).clearRecentLookups()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(recents.prefix(20), id: \.characterID) { recent in
                        if let c = store.character(for: recent.characterID) {
                            Button {
                                path.append(.character(c))
                            } label: {
                                RecentHanziChip(character: c)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var trendingGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trending Characters")
                .font(.system(size: 17, weight: .bold))
            Text("Popular among HSK learners")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(store.trending) { c in
                    Button { path.append(.character(c)) } label: {
                        HanziGridTile(character: c)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var writePracticeCTA: some View {
        NavigationLink {
            PracticeView(showDueSession: true)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Write Practice")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Review your SRS deck today")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: "applepencil.and.scribble")
                    .font(.system(size: 22, weight: .semibold))
                    .padding(10)
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.18))
                    )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.accent)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search results

    private var searchResults: some View {
        let results = store.search(query, mode: mode)
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(results) { c in
                Button { path.append(.character(c)) } label: {
                    HanziListRow(character: c)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Theme.card)
                        )
                }
                .buttonStyle(.plain)
            }
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

// MARK: - Browse all

struct BrowseAllView: View {
    @Environment(CharacterStore.self) private var store
    @Query private var cards: [SRSCard]
    /// `nil` means "show every level" — most users will pick one to focus.
    @State private var selectedHSK: Int? = 1
    @State private var sortOrder: BrowseSortOrder = .strokeCount
    @State private var filter: BrowseFilter = .all

    var body: some View {
        let cardByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.characterID, $0) })
        let processed = processedLevels(cardByID: cardByID)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hskPicker(levels: processed)
                if processed.allSatisfy({ $0.characters.isEmpty }) {
                    emptyState
                } else {
                    ForEach(processed, id: \.level) { group in
                        if selectedHSK == nil || selectedHSK == group.level {
                            levelSection(group)
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Browse")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
        }
    }

    /// Toolbar menu: sort order + progress filter.
    private var filterMenu: some View {
        Menu {
            Section("Sort") {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(BrowseSortOrder.allCases) { order in
                        Label(order.displayName, systemImage: order.systemImage)
                            .tag(order)
                    }
                }
            }
            Section("Show") {
                Picker("Show", selection: $filter) {
                    ForEach(BrowseFilter.allCases) { f in
                        Label(f.displayName, systemImage: f.systemImage)
                            .tag(f)
                    }
                }
            }
        } label: {
            Image(systemName: filter == .all
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No characters match this filter")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Try \"All\" or pick a different HSK level.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// Apply the active filter + sort on top of `store.byHSK`. Cheap: a few
    /// thousand dictionary lookups per recompute, all O(1).
    private func processedLevels(cardByID: [String: SRSCard])
        -> [(level: Int, characters: [HanziCharacter])]
    {
        store.byHSK.map { lvl in
            let kept = lvl.characters.filter { c in
                filter.includes(cardByID[c.canonicalID])
            }
            let sorted: [HanziCharacter] = {
                switch sortOrder {
                case .strokeCount:
                    return kept.sorted {
                        ($0.strokeCount, $0.canonicalID)
                            < ($1.strokeCount, $1.canonicalID)
                    }
                case .alphabetical:
                    return kept.sorted {
                        ($0.pinyinToneless, $0.canonicalID)
                            < ($1.pinyinToneless, $1.canonicalID)
                    }
                }
            }()
            return (level: lvl.level, characters: sorted)
        }
    }

    private func levelSection(_ group: (level: Int, characters: [HanziCharacter]))
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HSK Level \(group.level)")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Text("\(group.characters.count) characters")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if group.characters.isEmpty {
                Text("No \(filter.displayName.lowercased()) characters at this level.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 10)],
                          spacing: 10) {
                    ForEach(group.characters) { c in
                        NavigationLink(value: c) {
                            VStack(spacing: 4) {
                                Text(c.char)
                                    .font(Theme.hanzi(40))
                                    .foregroundStyle(Theme.accent)
                                Text(c.pinyin.isEmpty ? c.pinyinToneless : c.pinyin)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(width: 78, height: 90)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Theme.surface)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func hskPicker(levels: [(level: Int, characters: [HanziCharacter])])
        -> some View
    {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(title: "All", value: nil)
                ForEach(levels.map(\.level), id: \.self) { level in
                    pill(title: "HSK \(level)", value: level)
                }
            }
        }
    }

    private func pill(title: String, value: Int?) -> some View {
        let active = selectedHSK == value
        return Button { selectedHSK = value } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(active ? .white : .primary)
                .background(
                    Capsule().fill(active ? Theme.accent : Theme.card)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Browse filter / sort

enum BrowseSortOrder: String, CaseIterable, Identifiable, Hashable {
    case strokeCount
    case alphabetical

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .strokeCount:  "Stroke count"
        case .alphabetical: "Pinyin"
        }
    }
    var systemImage: String {
        switch self {
        case .strokeCount:  "scribble"
        case .alphabetical: "textformat.abc"
        }
    }
}

/// Per-character progress filter for the Browse grid.
enum BrowseFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case notStarted
    case inProgress
    case mastered
    case hideMastered

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all:          "All characters"
        case .notStarted:   "Not started"
        case .inProgress:   "In progress"
        case .mastered:     "Mastered"
        case .hideMastered: "Hide mastered"
        }
    }
    var systemImage: String {
        switch self {
        case .all:          "square.grid.3x3"
        case .notStarted:   "circle.dashed"
        case .inProgress:   "circle.lefthalf.filled"
        case .mastered:     "checkmark.seal.fill"
        case .hideMastered: "eye.slash"
        }
    }

    /// Whether a character with the given SRS card should be shown.
    func includes(_ card: SRSCard?) -> Bool {
        switch self {
        case .all:
            return true
        case .notStarted:
            return card == nil || card?.state == .new
        case .inProgress:
            return card != nil
                && card?.state != .new
                && card?.state != .mastered
        case .mastered:
            return card?.state == .mastered
        case .hideMastered:
            return card?.state != .mastered
        }
    }
}
