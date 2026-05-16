//
//  ContentView.swift
//  hanzipracticeapp
//

import SwiftUI
import SwiftData

enum RootTab: Hashable, CaseIterable {
    case home, dictionary, practice, stats, profile

    /// Adjacent tab in a given direction, or nil if we're at the edge.
    /// Used by the swipe-between-tabs gesture.
    func neighbour(direction: Int) -> RootTab? {
        let all = RootTab.allCases
        guard let i = all.firstIndex(of: self) else { return nil }
        let next = i + direction
        guard next >= 0 && next < all.count else { return nil }
        return all[next]
    }
}

struct ContentView: View {
    @State private var selectedTab: RootTab = .home
    @State private var dictionaryJumpToLists: Bool = false
    /// Tracks accumulated horizontal drag across a single gesture so we
    /// only commit a tab switch once per swipe (a tiny live delta would
    /// otherwise oscillate the tab).
    @GestureState private var swipeOffset: CGFloat = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: RootTab.home) {
                HomeView(selectedTab: $selectedTab,
                         dictionaryJumpToLists: $dictionaryJumpToLists)
            }
            Tab("Dictionary", systemImage: "character.book.closed.fill",
                value: RootTab.dictionary) {
                DictionaryView(jumpToLists: $dictionaryJumpToLists)
            }
            Tab("Practice", systemImage: "applepencil.and.scribble",
                value: RootTab.practice) {
                PracticeView()
            }
            Tab("Stats", systemImage: "chart.bar.fill", value: RootTab.stats) {
                StatsView()
            }
            Tab("Profile", systemImage: "person.crop.circle.fill",
                value: RootTab.profile) {
                ProfileView()
            }
        }
        .tint(Theme.accent)
        // Horizontal swipe across the tab content moves between adjacent
        // tabs (Home → Dictionary → Practice → …). Vertical drift is
        // ignored so this doesn't trip on a typical scroll. Threshold is
        // generous to avoid accidental switches while drawing on a
        // writing canvas — the writing canvas's own pan gesture wins for
        // smaller / more vertical drags.
        .gesture(
            DragGesture(minimumDistance: 80)
                .updating($swipeOffset) { value, state, _ in
                    if abs(value.translation.width) > abs(value.translation.height) * 1.5 {
                        state = value.translation.width
                    }
                }
                .onEnded { value in
                    guard abs(value.translation.width) > 80,
                          abs(value.translation.width) > abs(value.translation.height) * 1.5
                    else { return }
                    let direction = value.translation.width < 0 ? 1 : -1
                    if let next = selectedTab.neighbour(direction: direction) {
                        selectedTab = next
                    }
                }
        )
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            SRSCard.self, VocabularyList.self, PracticeRecord.self,
            RecentLookup.self, UserSettings.self
        ], inMemory: true)
        .environment(CharacterStore())
}
