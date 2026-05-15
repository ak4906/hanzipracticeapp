//
//  ProfileView.swift
//  hanzipracticeapp
//
//  Light settings/profile screen — daily-new limit, sound toggle,
//  preferred variant, and quick links to lists and stats.
//

import SwiftUI
import SwiftData

struct ProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(CharacterStore.self) private var store
    @Query private var settingsList: [UserSettings]
    @Query private var cards: [SRSCard]
    @Query private var records: [PracticeRecord]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    profileHeader
                }

                if let settings = settingsList.first {
                    SettingsSections(settings: settings, store: store)
                } else {
                    Section {
                        Text("Loading settings…").foregroundStyle(.secondary)
                    }
                }

                Section("Your library") {
                    NavigationLink {
                        VocabularyListsView()
                    } label: {
                        Label("My vocabulary lists", systemImage: "books.vertical")
                    }
                    NavigationLink {
                        DangerZoneView()
                    } label: {
                        Label("Reset learning data", systemImage: "arrow.counterclockwise")
                    }
                }

                Section("About") {
                    LabeledContent("Total cards", value: "\(cards.count)")
                    LabeledContent("Practice sessions", value: "\(records.count)")
                    LabeledContent("Version", value: "1.0")
                }
            }
            .navigationTitle("Profile")
        }
        .onAppear {
            _ = UserDataController(context: modelContext).settings()
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 64, height: 64)
                Text("学")
                    .font(Theme.hanzi(28, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Hanzi Learner")
                    .font(.system(size: 18, weight: .bold))
                Text("\(cards.filter { $0.state == .mastered }.count) mastered • \(streak)-day streak")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    private var streak: Int {
        let cal = Calendar.current
        let days = Set(records.map { cal.startOfDay(for: $0.date) })
        var s = 0
        var cursor = cal.startOfDay(for: .now)
        while days.contains(cursor) {
            s += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return s
    }

}

/// Settings sections that own a `@Bindable` reference to the UserSettings row.
/// Using `@Bindable` (rather than custom `Binding(get:set:)`) keeps Picker /
/// Toggle / Stepper writes flowing through SwiftData's observation, which the
/// custom bindings disrupted in iOS 26 (selections wouldn't take).
private struct SettingsSections: View {
    @Bindable var settings: UserSettings
    let store: CharacterStore
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Section {
            Picker(selection: variantBinding) {
                ForEach(ChineseVariant.allCases, id: \.self) { v in
                    Text(v.displayName).tag(v)
                }
            } label: {
                Text("Writing system")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Writing system")
        } footer: {
            Text("All characters across the dictionary, sessions, and lists will be shown in your selected writing system. No mixing.")
        }

        Section {
            Picker("New picks through", selection: $settings.practiceHSKCeiling) {
                ForEach(1...HSKLevels.maxLevel, id: \.self) { n in
                    Text(hskCeilingLabel(n)).tag(n)
                }
            }
        } header: {
            Text("Practice level")
        } footer: {
            Text("Character of the Day, fallback sessions, Random, and New character queues draw only from official HSK lists through this level. Today's Review shows due cards at or below your level (extra-list hanzi appear once you're set through HSK 7-9). Raise this when you're ready for harder characters.")
        }

        Section {
            Stepper("Today's Review size: \(settings.effectiveDailyReviewLimit)",
                    value: dailyReviewLimitBinding,
                    in: 3...50, step: 1)
            Stepper("Chunk size: \(settings.effectivePracticeChunkSize)",
                    value: chunkSizeBinding,
                    in: 1...10, step: 1)
        } header: {
            Text("Session sizing")
        } footer: {
            Text("Today's Review size sets how many due cards appear in one session. Chunk size groups characters during the 3-pass drill so you don't see 100 traces before the first memory test — small chunks (2–3) let you actually remember each character.")
        }

        Section {
            Picker("Writing direction", selection: writingDirectionBinding) {
                ForEach(WritingDirection.allCases) { d in
                    Text(d.displayName).tag(d)
                }
            }
            Picker("Canvas size", selection: canvasFitBinding) {
                ForEach(PracticeCanvasFit.allCases) { f in
                    Text(f.displayName).tag(f)
                }
            }
        } header: {
            Text("Multi-character layout")
        } footer: {
            Text("Direction sets how the characters of a multi-character word (容易, 冰激凌) are laid out during writing practice. Canvas size lets you choose between fitting all the canvases on one screen, or keeping each one full size and scrolling / swiping to the next.")
        }

        Section("Other") {
            Toggle("Sounds & pronunciation", isOn: $settings.soundsEnabled)
        }
    }

    private var dailyReviewLimitBinding: Binding<Int> {
        Binding(
            get: { settings.effectiveDailyReviewLimit },
            set: { settings.dailyReviewLimit = $0 }
        )
    }

    private var chunkSizeBinding: Binding<Int> {
        Binding(
            get: { settings.effectivePracticeChunkSize },
            set: { settings.practiceChunkSize = $0 }
        )
    }

    private var writingDirectionBinding: Binding<WritingDirection> {
        Binding(
            get: { settings.effectiveWritingDirection },
            set: { settings.writingDirectionRaw = $0.rawValue }
        )
    }

    private var canvasFitBinding: Binding<PracticeCanvasFit> {
        Binding(
            get: { settings.effectivePracticeCanvasFit },
            set: { settings.practiceCanvasFitRaw = $0.rawValue }
        )
    }

    /// Bridges the boolean stored property to a ChineseVariant for the picker
    /// while keeping the store's active variant in sync.
    private var variantBinding: Binding<ChineseVariant> {
        Binding(
            get: { settings.preferTraditional ? .traditional : .simplified },
            set: { newValue in
                settings.preferTraditional = (newValue == .traditional)
                try? modelContext.save()
                store.setVariant(newValue)
            }
        )
    }

    private func hskCeilingLabel(_ n: Int) -> String {
        if n == 1 { return "HSK 1 only" }
        if n >= 7 { return "HSK 1 – 7-9 (all)" }
        return "HSK 1–\(n)"
    }
}

// MARK: - Reset

struct DangerZoneView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var confirming: Bool = false

    var body: some View {
        Form {
            Section {
                Text("Resetting your learning data will erase all SRS progress, practice records, and vocabulary lists. Dictionary content will remain.")
                    .font(.system(size: 14))
            }
            Section {
                Button(role: .destructive) {
                    confirming = true
                } label: {
                    Label("Reset everything", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Reset")
        .alert("Reset all data?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetEverything()
                dismiss()
            }
        }
    }

    private func resetEverything() {
        let context = modelContext
        for type in [SRSCard.self] as [any PersistentModel.Type] { _ = type }
        if let cards = try? context.fetch(FetchDescriptor<SRSCard>()) {
            for c in cards { context.delete(c) }
        }
        if let quizCards = try? context.fetch(FetchDescriptor<SRSQuizCard>()) {
            for c in quizCards { context.delete(c) }
        }
        if let recs = try? context.fetch(FetchDescriptor<PracticeRecord>()) {
            for r in recs { context.delete(r) }
        }
        if let lists = try? context.fetch(FetchDescriptor<VocabularyList>()) {
            for l in lists { context.delete(l) }
        }
        if let recents = try? context.fetch(FetchDescriptor<RecentLookup>()) {
            for r in recents { context.delete(r) }
        }
        try? context.save()
    }
}
