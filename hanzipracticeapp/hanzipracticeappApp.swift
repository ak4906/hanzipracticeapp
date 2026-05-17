//
//  hanzipracticeappApp.swift
//  hanzipracticeapp
//

import SwiftUI
import SwiftData

@main
struct hanzipracticeappApp: App {
    @State private var characterStore = CharacterStore()
    /// Eagerly-constructed model container so we can drive it through
    /// CloudKit (the `.modelContainer(for:)` view modifier still works
    /// but doesn't expose the `ModelConfiguration` we need for the
    /// `cloudKitDatabase` option).
    let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SRSCard.self,
            SRSQuizCard.self,
            VocabularyList.self,
            CustomWordEntry.self,
            PracticeRecord.self,
            RecentLookup.self,
            UserSettings.self,
            UserProfile.self
        ])
        // Private CloudKit database — everything in the user's own
        // iCloud account, never shared. The container id matches the
        // one declared in `hanzipracticeapp.entitlements` and the
        // CloudKit dashboard.
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private("iCloud.cometzfly.hanzipracticeapp")
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Falling back to a local-only store keeps the app usable
            // when iCloud is signed out / disabled. The next launch
            // with iCloud enabled will pick the synced store back up.
            print("HanziPractice: CloudKit ModelContainer failed (\(error)) — falling back to local")
            let localConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
            // If even the fallback init throws something is badly
            // wrong with the schema — let it crash loudly.
            // swiftlint:disable:next force_try
            return try! ModelContainer(for: schema, configurations: [localConfig])
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootBootstrap(store: characterStore) {
                ContentView()
                    .environment(characterStore)
            }
        }
        .modelContainer(sharedModelContainer)
    }
}

/// Shows a small splash while the bundled MMA dictionary + stroke index are
/// being loaded (typically a few hundred milliseconds).
private struct RootBootstrap<Content: View>: View {
    @Bindable var store: CharacterStore
    @Environment(\.modelContext) private var modelContext
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
            // Reconcile any CloudKit-synced duplicates before we read
            // settings — otherwise a freshly-merged second device could
            // see two UserSettings rows (one from each device) and the
            // initial `.first` query would pick a non-deterministic one.
            CloudKitDedupMigration.run(in: modelContext)
            // Guarantee a UserSettings row exists before any feature view
            // queries it — otherwise Profile gets stuck on "Loading settings…"
            // because @Query's first read sees an empty array and the eventual
            // insert doesn't always re-trigger a body recompute.
            let userSettings = UserDataController(context: modelContext).settings()
            async let charBoot: Void = store.bootstrap(initialVariant: userSettings.preferTraditional ? .traditional : .simplified)
            async let wordBoot: Void = WordDictionary.shared.loadIfNeeded()
            async let sentenceBoot: Void = SentenceCorpus.shared.loadIfNeeded()
            async let etymologyBoot: Void = EtymologyLexicon.shared.loadIfNeeded()
            async let defsBoot: Void = SingleCharDefinitions.shared.loadIfNeeded()
            _ = await (charBoot, wordBoot, sentenceBoot, etymologyBoot, defsBoot)
        }
    }
}
