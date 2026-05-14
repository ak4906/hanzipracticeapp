//
//  ContentView.swift
//  hanzipracticeapp
//

import SwiftUI
import SwiftData

enum RootTab: Hashable {
    case home, dictionary, practice, stats, profile
}

struct ContentView: View {
    @State private var selectedTab: RootTab = .home
    @State private var dictionaryJumpToLists: Bool = false

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
