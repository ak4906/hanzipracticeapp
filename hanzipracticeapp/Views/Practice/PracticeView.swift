//
//  PracticeView.swift
//  hanzipracticeapp
//
//  Top-level practice tab. From here the user can:
//   • jump into "Today's SRS Review"
//   • practice a specific vocabulary list
//   • practice a single character (used by navigation pushes)
//

import SwiftUI
import SwiftData

struct PracticeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(CharacterStore.self) private var store

    /// If true, the view jumps straight into the due-card session on appear.
    var showDueSession: Bool = false

    @Query private var listsRaw: [VocabularyList]
    @Query private var allCards: [SRSCard]
    @Query private var settingsList: [UserSettings]

    private var lists: [VocabularyList] { listsRaw.sortedForDisplay() }

    @State private var session: PracticeSession? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerHero
                    quickActions
                    recommendedSection
                    listsSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Practice")
            .navigationBarTitleDisplayMode(.large)
            .fullScreenCover(item: $session) { s in
                WritingSessionView(session: s) {
                    session = nil
                }
            }
            .onAppear {
                _ = UserDataController(context: modelContext).settings()
                if showDueSession, session == nil { startDueSession() }
            }
        }
    }

    // MARK: - Sections

    private var headerHero: some View {
        let due = allCards.filter {
            $0.dueDate <= .now && characterMatchesPracticeCeiling($0.characterID)
        }.count
        return VStack(alignment: .leading, spacing: 8) {
            Text(due > 0 ? "Today's Review" : "All caught up!")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Text(due > 0
                 ? "\(due) character\(due == 1 ? "" : "s") due — keep your streak alive."
                 : "Nothing scheduled. Try a list or look up a new character.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.85))
            Button {
                startDueSession()
            } label: {
                HStack {
                    Image(systemName: "applepencil.and.scribble")
                    Text(due > 0 ? "Start Writing Session" : "Practice anyway")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    Capsule().fill(Color.white)
                )
            }
            .padding(.top, 6)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.accent)
        )
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            actionTile(symbol: "shuffle",
                       title: "Random",
                       subtitle: "Mixed bag",
                       color: 0xC9A13C) {
                startRandomSession()
            }
            actionTile(symbol: "star.fill",
                       title: "Weakest",
                       subtitle: "Low mastery",
                       color: 0xCE5757) {
                startWeakestSession()
            }
            actionTile(symbol: "sparkles",
                       title: "New",
                       subtitle: "Never seen",
                       color: 0x6789C2) {
                startNewSession()
            }
        }
    }

    private func actionTile(symbol: String, title: String, subtitle: String,
                            color: UInt32,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .padding(8)
                    .foregroundStyle(.white)
                    .background(Circle().fill(Color(hex: color)))
                Spacer(minLength: 6)
                Text(title).font(.system(size: 15, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.card)
            )
        }
        .buttonStyle(.plain)
    }

    private var recommendedSection: some View {
        let weakIDs = allCards
            .sorted { $0.mastery < $1.mastery }
            .prefix(6)
            .map(\.characterID)
        let weakChars = store.characters(for: Array(weakIDs))
        return Group {
            if !weakChars.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Strengthen these")
                        .font(.system(size: 17, weight: .bold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(weakChars) { c in
                                Button {
                                    session = PracticeSession(characterIDs: [c.id],
                                                              title: c.char)
                                } label: {
                                    weakTile(c)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func weakTile(_ c: HanziCharacter) -> some View {
        VStack(spacing: 4) {
            Text(c.char)
                .font(Theme.hanzi(46))
                .foregroundStyle(Theme.accent)
            Text(c.pinyin)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .frame(width: 88)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card)
        )
    }

    private var listsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your Lists")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                NavigationLink {
                    VocabularyListsView()
                } label: {
                    Text("Manage")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            if lists.isEmpty {
                Text("Add characters to a list from the Dictionary to practice them here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.card)
                    )
            } else {
                ForEach(lists) { list in
                    Group {
                        if list.characterIDs.isEmpty {
                            NavigationLink {
                                ListDetailView(list: list)
                            } label: {
                                listRow(list)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                session = PracticeSession(characterIDs: list.characterIDs,
                                                          title: list.name)
                            } label: {
                                listRow(list)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func listRow(_ list: VocabularyList) -> some View {
        HStack(spacing: 12) {
            Image(systemName: list.symbol)
                .font(.system(size: 16, weight: .semibold))
                .padding(10)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(hex: UInt32(list.colorHex)))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name).font(.system(size: 15, weight: .semibold))
                Text("\(list.characterIDs.count) characters")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card)
        )
    }

    // MARK: - Session starters

    private var practiceHSKCeiling: Int {
        let raw = settingsList.first?.practiceHSKCeiling ?? 1
        return max(1, min(6, raw))
    }

    private func characterMatchesPracticeCeiling(_ canonicalID: String) -> Bool {
        guard let c = store.character(for: canonicalID) else { return false }
        if c.hskLevel >= 1 { return c.hskLevel <= practiceHSKCeiling }
        return practiceHSKCeiling >= 6
    }

    private func startDueSession() {
        let controller = UserDataController(context: modelContext)
        let dueFiltered = controller.dueCards()
            .filter { characterMatchesPracticeCeiling($0.characterID) }
        let ids = Array(dueFiltered.prefix(20)).map(\.characterID)
        let valid = store.characters(for: ids).map(\.id)
        if valid.isEmpty {
            let gentle = Array(store.officialHSKCanonicalIDs(upThrough: practiceHSKCeiling).shuffled().prefix(8))
            let fallbackPool = gentle.isEmpty
                ? Array(store.allCharacterIDs.shuffled().prefix(8))
                : gentle
            session = PracticeSession(characterIDs: fallbackPool, title: "Today's Review")
        } else {
            session = PracticeSession(characterIDs: valid, title: "Today's Review")
        }
    }

    private func startRandomSession() {
        let pool = store.officialHSKCanonicalIDs(upThrough: practiceHSKCeiling)
        let pick = Array(pool.shuffled().prefix(8))
        let fallbackPool = pick.isEmpty ? Array(store.allCharacterIDs.shuffled().prefix(8)) : pick
        session = PracticeSession(characterIDs: fallbackPool, title: "Random session")
    }

    private func startWeakestSession() {
        let weak = allCards
            .sorted { $0.mastery < $1.mastery }
            .prefix(8)
            .map(\.characterID)
        let chars = store.characters(for: Array(weak)).map(\.id)
        let gentle = Array(store.officialHSKCanonicalIDs(upThrough: practiceHSKCeiling).shuffled().prefix(8))
        let fallbackPool = gentle.isEmpty ? Array(store.allCharacterIDs.shuffled().prefix(8)) : gentle
        session = PracticeSession(characterIDs: chars.isEmpty ? fallbackPool : chars,
                                  title: "Weakest characters")
    }

    private func startNewSession() {
        let known = Set(allCards.map(\.characterID))
        let poolIDs = store.officialHSKCanonicalIDs(upThrough: practiceHSKCeiling)
        let unseen = poolIDs.filter { !known.contains($0) }
        let pick = Array(unseen.prefix(8))
        let fallbackPool = pick.isEmpty
            ? Array(store.officialHSKCanonicalIDs(upThrough: practiceHSKCeiling).shuffled().prefix(8))
            : pick
        let finalPool = fallbackPool.isEmpty ? Array(store.allCharacterIDs.prefix(8)) : fallbackPool
        session = PracticeSession(characterIDs: finalPool,
                                  title: "New characters")
    }
}

// MARK: - Session value

struct PracticeSession: Identifiable, Hashable {
    let id = UUID()
    let characterIDs: [String]
    let title: String
}
