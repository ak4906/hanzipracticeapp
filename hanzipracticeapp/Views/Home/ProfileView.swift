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
    @Query private var profiles: [UserProfile]

    @State private var editingProfile: Bool = false

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
            .sheet(isPresented: $editingProfile) {
                if let profile = profiles.first {
                    ProfileEditorSheet(profile: profile)
                        .presentationDetents([.medium, .large])
                }
            }
        }
        .onAppear {
            _ = UserDataController(context: modelContext).settings()
            // Materialise the profile row eagerly so the header
            // doesn't flash a placeholder on first launch.
            _ = UserDataController(context: modelContext).userProfile()
        }
    }

    private var profileHeader: some View {
        let profile = profiles.first
        let displayName = profile?.displayName ?? "Hanzi Learner"
        let symbol = profile?.avatarSymbol ?? "学"
        let color = profile.map { Color(hex: UInt32($0.avatarColorHex)) } ?? Theme.accent
        return Button {
            editingProfile = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(color.opacity(0.18)).frame(width: 64, height: 64)
                    Text(symbol)
                        .font(Theme.hanzi(28, weight: .semibold))
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("\(cards.filter { $0.state == .mastered }.count) mastered • \(streak)-day streak")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "pencil.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
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
            Stepper("Daily new cards: \(settings.dailyNewLimit)",
                    value: $settings.dailyNewLimit,
                    in: 0...20, step: 1)
            Stepper("Chunk size: \(settings.effectivePracticeChunkSize)",
                    value: chunkSizeBinding,
                    in: 1...10, step: 1)
        } header: {
            Text("Session sizing")
        } footer: {
            Text("Today's Review size = how many due cards appear in one session. Daily new cards = how many never-seen HSK characters get introduced per session, on top of due cards (set to 0 to only review what you've started). Chunk size groups characters during the 3-pass drill so you don't see 100 traces before the first memory test.")
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
            // Stepper rather than a fixed-tag picker because the live
            // in-session pinch / resize-handle can land on any value
            // between 120 and 1000pt — a discrete picker would warn
            // "selection X is invalid" whenever the live value doesn't
            // match one of its preset tags.
            Stepper("Max canvas size: \(canvasMaxSizeBinding.wrappedValue)pt",
                    value: canvasMaxSizeBinding,
                    in: 120...1000,
                    step: 20)
        } header: {
            Text("Multi-character layout")
        } footer: {
            Text("Direction sets how the characters of a multi-character word (容易, 冰激凌) are laid out during writing practice. Canvas size chooses between fitting all canvases on one screen or scrolling between them. Max canvas size caps how big a single canvas can grow — useful on iPad where the canvas otherwise stretches across the whole screen.")
        }

        Section {
            Toggle("Quiz between passes", isOn: interPassQuizBinding)
        } header: {
            Text("Recall prompts")
        } footer: {
            Text("Between each pass of the 3-pass writing drill, ask a quick multiple-choice question about what you just wrote (meaning, pinyin). Wrong answer = redo the pass. Off for quick blast-through sessions; on when you want to commit characters to deep memory.")
        }

        Section("Other") {
            Toggle("Sounds & pronunciation", isOn: $settings.soundsEnabled)
        }
    }

    private var interPassQuizBinding: Binding<Bool> {
        Binding(
            get: { settings.interPassQuizEnabled ?? false },
            set: { settings.interPassQuizEnabled = $0 }
        )
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

    private var canvasMaxSizeBinding: Binding<Int> {
        Binding(
            get: { settings.practiceCanvasMaxSize ?? 360 },
            set: { settings.practiceCanvasMaxSize = $0 }
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
        if let custom = try? context.fetch(FetchDescriptor<CustomWordEntry>()) {
            for c in custom { context.delete(c) }
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

// MARK: - Profile editor

/// Sheet for editing the user's display name + avatar glyph. The
/// avatar is a single character or emoji — keeps the underlying
/// `UserProfile` row small and CloudKit-syncable. Full picture upload
/// can come in a follow-up once we have a path for shrinking / caching
/// images through CloudKit.
struct ProfileEditorSheet: View {
    @Bindable var profile: UserProfile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var workingName: String = ""
    @State private var workingSymbol: String = ""
    @State private var workingColorHex: Int = 0x266358

    /// Curated palette — themed greens / blues / warm accents that
    /// look good on the avatar circle. Hex packed so they line up
    /// with the `UserProfile.avatarColorHex` storage.
    private let colorPalette: [Int] = [
        0x266358, 0x3F8C7A, 0x6789C2, 0xC9A13C,
        0xC9605D, 0x8D6CD0, 0x4A5060, 0x9C3F60,
    ]

    /// Quick-pick glyphs. Common stand-ins until we have image
    /// picker / CloudKit asset support.
    private let glyphPalette: [String] = [
        "学", "汉", "字", "书", "笔", "心", "好", "永",
        "🐯", "🐉", "🌸", "🍵", "📚", "✏️", "⭐️", "🔥",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(Color(hex: UInt32(workingColorHex)).opacity(0.2))
                                .frame(width: 96, height: 96)
                            Text(workingSymbol.isEmpty ? "?" : workingSymbol)
                                .font(Theme.hanzi(48, weight: .semibold))
                                .foregroundStyle(Color(hex: UInt32(workingColorHex)))
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Display name") {
                    TextField("Your name", text: $workingName)
                        .textInputAutocapitalization(.words)
                }

                Section("Avatar glyph") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 56),
                                                  spacing: 8)],
                              spacing: 8) {
                        ForEach(glyphPalette, id: \.self) { glyph in
                            Button {
                                workingSymbol = glyph
                            } label: {
                                Text(glyph)
                                    .font(Theme.hanzi(22))
                                    .frame(width: 44, height: 44)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(workingSymbol == glyph
                                                  ? Color(hex: UInt32(workingColorHex)).opacity(0.2)
                                                  : Color.secondary.opacity(0.08))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(workingSymbol == glyph
                                                    ? Color(hex: UInt32(workingColorHex))
                                                    : Color.clear,
                                                    lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    HStack {
                        Text("Or type your own")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("符", text: $workingSymbol)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                    }
                }

                Section("Colour") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 36, maximum: 44),
                                                  spacing: 10)],
                              spacing: 10) {
                        ForEach(colorPalette, id: \.self) { hex in
                            Button { workingColorHex = hex } label: {
                                Circle()
                                    .fill(Color(hex: UInt32(hex)))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle().stroke(
                                            workingColorHex == hex
                                                ? Color.primary
                                                : Color.clear,
                                            lineWidth: 2.5
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmed = workingName.trimmingCharacters(in: .whitespacesAndNewlines)
                        profile.displayName = trimmed.isEmpty ? "Hanzi Learner" : trimmed
                        // Clamp to a single grapheme so multi-emoji
                        // strings (and accidental long input) don't
                        // blow out the avatar circle.
                        let glyph = workingSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let first = glyph.first {
                            profile.avatarSymbol = String(first)
                        }
                        profile.avatarColorHex = workingColorHex
                        try? modelContext.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            workingName = profile.displayName
            workingSymbol = profile.avatarSymbol
            workingColorHex = profile.avatarColorHex
        }
    }
}
