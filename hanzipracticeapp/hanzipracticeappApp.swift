//
//  hanzipracticeappApp.swift
//  hanzipracticeapp
//

import SwiftUI
import SwiftData

@main
struct hanzipracticeappApp: App {
    @State private var characterStore = CharacterStore()

    var body: some Scene {
        WindowGroup {
            RootBootstrap(store: characterStore) {
                ContentView()
                    .environment(characterStore)
            }
        }
        .modelContainer(for: [
            SRSCard.self,
            VocabularyList.self,
            PracticeRecord.self,
            RecentLookup.self,
            UserSettings.self
        ])
    }
}

/// Shows a small splash while the bundled MMA dictionary + stroke index are
/// being loaded (typically a few hundred milliseconds).
private struct RootBootstrap<Content: View>: View {
    @Bindable var store: CharacterStore
    @Query private var settings: [UserSettings]
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if store.isLoaded {
                content()
            } else {
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    VStack(spacing: 16) {
                        Text("汉")
                            .font(.system(size: 80, weight: .regular, design: .serif))
                            .foregroundStyle(Theme.accent)
                        ProgressView()
                        Text("Loading character data…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            let preferTraditional = settings.first?.preferTraditional ?? false
            await store.bootstrap(initialVariant: preferTraditional ? .traditional : .simplified)
        }
    }
}
