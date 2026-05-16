//
//  CharacterDetailView.swift
//  hanzipracticeapp
//
//  The big screen the user lands on after picking a hanzi anywhere in the
//  app. Hosts: stroke-order animation, structure, contextual usage, mnemonic,
//  and the "add to practice list" call to action.
//

import SwiftUI
import SwiftData
import AVFoundation

struct CharacterDetailView: View {
    let character: HanziCharacter

    @Environment(\.modelContext) private var modelContext
    @Environment(CharacterStore.self) private var store
    @Query private var knownCards: [SRSCard]
    @Query private var userLists: [VocabularyList]

    @State private var animateStrokes: Bool = false
    @State private var animationKey: Int = 0
    @State private var showAddToList: Bool = false
    /// Graphics loaded just so we can compute a component colour map for
    /// the hero panel — `HanziStrokeView` does its own independent load.
    @State private var graphics: MMAGraphics? = nil
    /// Single-entry practice / quiz sessions launched from the "Practice
    /// this character" row. Lets a user drill one character without
    /// having to set up a vocab list first.
    @State private var practiceSession: PracticeSession? = nil
    @State private var quizSession: QuizSession? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                pinyinHeader
                characterPanel
                if let legend = strokeBreakdown?.legend, !legend.isEmpty {
                    componentLegend(legend)
                }
                meaningRow
                strokeControls
                practiceThisRow
                if let etymology = character.etymology {
                    etymologySection(etymology)
                } else if character.radical != nil || character.variant != nil {
                    legacyStructureSection
                }
                usedInCharactersSection
                commonWordsSection
                contextualUsage
                addToListButton
                if let m = character.mnemonic { mnemonicCard(text: m) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Character Detail")
        .navigationBarTitleDisplayMode(.inline)
        // Note: no `.navigationDestination(for: HanziCharacter.self)` here.
        // CharacterDetailView is pushed from several places — Dictionary uses
        // a typed `path: [DictionaryNav]`, which won't accept a bare
        // HanziCharacter value. The related-character links below use the
        // destination-view form (`NavigationLink { CharacterDetailView(...) }`)
        // so they work regardless of how this view was reached.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareString) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showAddToList) {
            AddToListSheet(character: character)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $practiceSession) { s in
            WritingSessionView(session: s) { practiceSession = nil }
        }
        .fullScreenCover(item: $quizSession) { q in
            QuizView(session: q) { quizSession = nil }
        }
        .task(id: character.char) {
            // Loaded off the main thread by MMAStore.graphics's cache. Used
            // for the per-stroke colour map; HanziStrokeView still loads its
            // own copy independently for animation.
            self.graphics = MMAStore.shared.graphics(for: character.char)
        }
        .onAppear {
            UserDataController(context: modelContext).noteLookup(character.id)
        }
    }

    // MARK: - Subviews

    private var pinyinHeader: some View {
        Text(character.pinyin)
            .font(.system(size: 30, weight: .semibold, design: .serif))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
    }

    private var characterPanel: some View {
        VStack {
            HanziStrokeView(character: character,
                            mode: animateStrokes ? .animate : .staticAll,
                            strokeColor: .primary,
                            strokeColors: strokeBreakdown?.colors,
                            ghostColor: Color.primary.opacity(0.05),
                            showGrid: true,
                            loops: animateStrokes)
                .id(animationKey)
        }
        .frame(maxWidth: 320)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.card)
        )
    }

    /// Tappable colour-coded legend for the component breakdown shown
    /// directly under the hero character panel.
    private func componentLegend(_ legend: [LegendChip]) -> some View {
        HStack(spacing: 8) {
            ForEach(legend) { chip in
                let label = HStack(spacing: 6) {
                    Circle()
                        .fill(chip.color)
                        .frame(width: 10, height: 10)
                    Text(chip.char)
                        .font(Theme.hanzi(15, weight: .regular))
                        .foregroundStyle(.primary)
                    Text(chip.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.4)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Theme.surface)
                )

                if let related = chip.related {
                    NavigationLink {
                        CharacterDetailView(character: related)
                    } label: { label }
                        .buttonStyle(.plain)
                } else {
                    label
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Stroke breakdown

    /// Identifies which strokes belong to which etymology component so the
    /// hero panel can paint them in distinct colours. Only attempts a split
    /// for two-component compounds where MMA gives us a clean `radStrokes`
    /// slice.
    private var strokeBreakdown: StrokeBreakdown? {
        guard let ety = character.etymology,
              ety.components.count >= 2,
              let g = graphics,
              !g.radStrokes.isEmpty,
              g.radStrokes.count < g.strokes.count
        else { return nil }

        let radIdx = Set(g.radStrokes)

        // Try to align radStrokes with one of the etymology components. We
        // prefer the component the user already considers the "radical" (by
        // explicit char equality), then fall back to whichever component is
        // tagged as semantic / both — that's the conventional carrier of
        // radical strokes in phono-semantic compounds.
        let radicalChar = character.radical?.char
        let semanticComp =
            ety.components.first(where: { $0.char == radicalChar })
            ?? ety.components.first(where: { $0.role == .semantic || $0.role == .both })
            ?? ety.components.first
        let phoneticComp =
            ety.components.first(where: { $0.char != semanticComp?.char })
            ?? ety.components.last

        // Pull theme-friendly colours: green for "meaning", blue for "sound".
        let semColor = Theme.accent
        let phoColor = Color(hex: 0x6789C2)

        var colors: [Color] = []
        colors.reserveCapacity(g.strokes.count)
        for i in 0..<g.strokes.count {
            colors.append(radIdx.contains(i) ? semColor : phoColor)
        }

        var chips: [LegendChip] = []
        if let s = semanticComp {
            chips.append(LegendChip(char: s.char,
                                    label: labelFor(role: s.role, fallback: "Meaning"),
                                    color: semColor,
                                    related: store.character(for: s.char)))
        }
        if let p = phoneticComp, p.char != semanticComp?.char {
            chips.append(LegendChip(char: p.char,
                                    label: labelFor(role: p.role, fallback: "Sound"),
                                    color: phoColor,
                                    related: store.character(for: p.char)))
        }
        return StrokeBreakdown(colors: colors, legend: chips)
    }

    private func labelFor(role: EtymologyComponent.Role, fallback: String) -> String {
        switch role {
        case .semantic:  return "Meaning"
        case .phonetic:  return "Sound"
        case .both:      return "Sound + Meaning"
        case .component: return fallback
        }
    }

    private struct StrokeBreakdown {
        let colors: [Color]
        let legend: [LegendChip]
    }

    private struct LegendChip: Identifiable {
        let char: String
        let label: String
        let color: Color
        let related: HanziCharacter?

        var id: String { char + label }
    }

    private var meaningRow: some View {
        let strokeCount = character.strokeCount > 0
            ? character.strokeCount
            : MMAStore.shared.strokeCount(for: character.char)
        return VStack(spacing: 6) {
            Text(character.meaning)
                .font(.system(size: 18, weight: .bold))
                .multilineTextAlignment(.center)
            HStack(spacing: 6) {
                if character.hskLevel > 0 {
                    Text(HSKLevels.displayLabel(for: character.hskLevel))
                    Text("•")
                }
                if strokeCount > 0 {
                    Text("\(strokeCount) Strokes")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .padding(.top, -4)
    }

    private var strokeControls: some View {
        HStack(spacing: 12) {
            Button {
                // The animation loops automatically, so "Replay" never
                // really applied — what the user wants once it's running
                // is to *stop* the loop, not restart it. Toggle here.
                if animateStrokes {
                    animateStrokes = false
                } else {
                    animateStrokes = true
                    animationKey += 1
                }
            } label: {
                HStack {
                    Image(systemName: animateStrokes ? "stop.fill" : "play.fill")
                    Text(animateStrokes ? "Stop animation" : "Stroke Order")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule().fill(Theme.accentSoft)
                )
            }
            Button {
                Speech.shared.say(character.pinyin, locale: "zh-CN", text: character.char)
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(14)
                    .background(
                        Circle().fill(Theme.accentSoft)
                    )
            }
        }
    }

    // MARK: - Practice this character (single-entry sessions)

    /// "Practice this" row — three buttons that kick off a one-entry
    /// session for the current character in writing / reading /
    /// translation mode. Lets the user drill a single hanzi without
    /// having to set up a vocab list. Grades feed into the same SRS
    /// cards as bigger sessions would, so Stats reflects the work.
    private var practiceThisRow: some View {
        HStack(spacing: 8) {
            practiceThisButton(title: "Write",
                               systemImage: "applepencil.and.scribble",
                               isPrimary: true) {
                practiceSession = PracticeSession(entries: [character.canonicalID],
                                                  title: character.char)
            }
            practiceThisButton(title: "Reading",
                               systemImage: QuizMode.reading.systemImage,
                               isPrimary: false) {
                quizSession = QuizSession(entries: [character.canonicalID],
                                          title: character.char,
                                          mode: .reading)
            }
            practiceThisButton(title: "Translate",
                               systemImage: QuizMode.translation.systemImage,
                               isPrimary: false) {
                quizSession = QuizSession(entries: [character.canonicalID],
                                          title: character.char,
                                          mode: .translation)
            }
        }
    }

    private func practiceThisButton(title: String,
                                    systemImage: String,
                                    isPrimary: Bool,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isPrimary ? .white : Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isPrimary ? Theme.accent : Theme.accentSoft.opacity(0.6))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Etymology

    /// Set of canonical ids the user has at least started learning — drives
    /// the "Also in characters you know" prioritisation of the shared lists.
    private var knownIDs: Set<String> {
        Set(knownCards.map(\.characterID))
    }

    /// Characters that *contain* this character as a component (e.g. for
    /// 易: 踢 / 赐 / 锡 / 阳…). Mirrors the existing within-component view
    /// but in the *reverse* direction. Hidden when there's nothing to show
    /// (e.g. for chars that aren't components of anything).
    @ViewBuilder
    private var usedInCharactersSection: some View {
        let known = knownIDs
        let chars = store.charactersSharing(component: character.canonicalID,
                                            excluding: character.canonicalID,
                                            prioritise: known,
                                            limit: 24)
        if !chars.isEmpty {
            let knownCount = chars.filter { known.contains($0.canonicalID) }.count
            VStack(alignment: .leading, spacing: 8) {
                Text(usedInLabel(knownCount: knownCount))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chars) { c in
                            NavigationLink {
                                CharacterDetailView(character: c)
                            } label: {
                                VStack(spacing: 1) {
                                    Text(c.char)
                                        .font(Theme.hanzi(22))
                                        .foregroundStyle(Theme.accent)
                                    Text(c.pinyin.isEmpty ? c.pinyinToneless : c.pinyin)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                                .frame(width: 44, height: 50)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(known.contains(c.canonicalID)
                                              ? Theme.accentSoft
                                              : Theme.surface)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.card)
            )
        }
    }

    private func usedInLabel(knownCount: Int) -> String {
        if knownCount > 0 {
            return "Used in characters you know · \(character.char)"
        }
        return "Characters using \(character.char)"
    }

    /// Multi-character words containing this character — split into two
    /// groups: words from the user's own vocab lists (more relevant for
    /// what they're actually studying) and the wider CC-CEDICT pool.
    /// Hidden when both groups are empty.
    @ViewBuilder
    private var commonWordsSection: some View {
        // Words from the user's vocab lists that contain this character.
        // These bubble up first — they're what the user has explicitly
        // chosen to study, so they're the most contextually useful.
        let userWords = userVocabWordsContainingCharacter
        // CC-CEDICT pool, deduped against the user's set so we don't
        // show 容易 twice when it's already in a list.
        let cedictWords = WordDictionary.shared.search(character.canonicalID, limit: 200)
            .filter { $0.simplified.contains(character.canonicalID)
                      && !userWords.contains($0.simplified) }
            .sorted { $0.simplified.count < $1.simplified.count }
            .prefix(12)
        if !userWords.isEmpty || !cedictWords.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !userWords.isEmpty {
                    Text("From your vocab lists".uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                    ForEach(userWords, id: \.self) { word in
                        if let entry = WordDictionary.shared.entry(for: word) {
                            wordExampleRow(entry)
                        } else {
                            customWordRow(word)
                        }
                    }
                }
                if !cedictWords.isEmpty {
                    Text("Common words with \(character.char)".uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                        .padding(.top, userWords.isEmpty ? 0 : 6)
                    ForEach(Array(cedictWords), id: \.simplified) { word in
                        wordExampleRow(word)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.card)
            )
        }
    }

    /// Multi-char words across the user's vocab lists that contain this
    /// character. Deduped, preserving first-list-first order.
    private var userVocabWordsContainingCharacter: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for list in userLists {
            for entry in list.effectiveEntries
                where entry.count > 1 && entry.contains(character.canonicalID) {
                if seen.insert(entry).inserted {
                    out.append(entry)
                }
            }
        }
        return out
    }

    /// Row used when a user-list entry isn't in CC-CEDICT — just the
    /// word, with a "from your list" hint.
    private func customWordRow(_ word: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(store.displayedWord(word))
                .font(Theme.hanzi(22))
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 56, alignment: .leading)
            Text("Custom — no dictionary entry")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func wordExampleRow(_ word: WordEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(store.displayedWord(word.simplified))
                .font(Theme.hanzi(22))
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(word.pinyin)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(word.firstGloss)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func etymologySection(_ ety: Etymology) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("STRUCTURE")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
                Spacer()
                typeBadge(ety.type)
            }
            if let hint = ety.hint, !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .padding(.bottom, 4)
            }
            ForEach(ety.components, id: \.char) { component in
                componentCard(component)
            }
            if let radical = character.radical,
               !ety.components.contains(where: { $0.char == radical.char }) {
                // Older curated entries surface a radical that the IDS
                // decomposition didn't catch — surface it as a part too.
                componentCard(.init(char: radical.char, role: .semantic))
            }
        }
    }

    private func typeBadge(_ type: HanziType) -> some View {
        HStack(spacing: 4) {
            Image(systemName: type.systemImage)
            Text(type.displayName)
            if !type.chineseName.isEmpty {
                Text("· \(type.chineseName)")
                    .opacity(0.75)
            }
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Theme.accentSoft)
        )
    }

    @ViewBuilder
    private func componentCard(_ component: EtymologyComponent) -> some View {
        let related = store.character(for: component.char)
        let known = knownIDs
        let shared = store.charactersSharing(component: component.char,
                                             excluding: character.canonicalID,
                                             prioritise: known,
                                             limit: 8)
        VStack(alignment: .leading, spacing: 10) {
            componentHeader(component: component, related: related)
            if !shared.isEmpty {
                Divider()
                sharedRow(label: knownsLabel(component, knownCount: shared.filter { known.contains($0.canonicalID) }.count),
                          chars: shared,
                          highlight: known)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card)
        )
    }

    /// Top row of a component card. Wraps the whole row in a navigation
    /// link to the component's own detail page when MMA has data for it,
    /// so tapping 月 inside 朗's card opens 月.
    @ViewBuilder
    private func componentHeader(component: EtymologyComponent,
                                 related: HanziCharacter?) -> some View {
        let rowContent = HStack(alignment: .top, spacing: 14) {
            Text(component.char)
                .font(Theme.hanzi(32, weight: .regular))
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.surface)
                )
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    roleBadge(component.role)
                    if let r = related, !r.pinyin.isEmpty {
                        Text(r.pinyin)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                if let r = related, !r.meaning.isEmpty {
                    Text(r.meaning)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                if component.role == .phonetic, let r = related {
                    Text("Sounds like \(r.pinyin); literally \"\(r.meaning.firstGloss)\".")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if component.role == .semantic, let r = related {
                    Text("Means \"\(r.meaning.firstGloss)\"; usually read \(r.pinyin).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if related != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())

        if let related {
            NavigationLink {
                CharacterDetailView(character: related)
            } label: { rowContent }
                .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private func knownsLabel(_ component: EtymologyComponent, knownCount: Int) -> String {
        if knownCount > 0 {
            return "Also in characters you know · \(component.char)"
        }
        return "Other characters with \(component.char)"
    }

    private func roleBadge(_ role: EtymologyComponent.Role) -> some View {
        let (color, label): (Color, String) = {
            switch role {
            case .semantic:  return (Theme.accent, "Meaning")
            case .phonetic:  return (Color(hex: 0x6789C2), "Sound")
            case .both:      return (Color(hex: 0xC9A13C), "Sound + Meaning")
            case .component: return (.secondary, "Part")
            }
        }()
        return Text(label.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
    }

    private func sharedRow(label: String,
                           chars: [HanziCharacter],
                           highlight: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chars) { c in
                        NavigationLink {
                            CharacterDetailView(character: c)
                        } label: {
                            VStack(spacing: 1) {
                                Text(c.char)
                                    .font(Theme.hanzi(22))
                                    .foregroundStyle(Theme.accent)
                                Text(c.pinyin.isEmpty ? c.pinyinToneless : c.pinyin)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(width: 44, height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(highlight.contains(c.canonicalID)
                                          ? Theme.accentSoft
                                          : Theme.surface)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Legacy structure (when no etymology info exists)

    private var legacyStructureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STRUCTURE")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(1.5)
            HStack(spacing: 10) {
                if let radical = character.radical {
                    structureCard(symbol: radical.char,
                                  label: "Radical",
                                  detail: radical.label)
                }
                if let variant = character.variant {
                    structureCard(symbol: variant.char,
                                  label: "Variant",
                                  detail: variant.label)
                }
            }
        }
    }

    private func structureCard(symbol: String, label: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Text(symbol)
                .font(Theme.hanzi(28, weight: .regular))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.surface)
                )
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.system(size: 15, weight: .semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card)
        )
    }

    private var contextualUsage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTEXTUAL USAGE")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(1.5)
            ForEach(character.examples, id: \.hanzi) { ex in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(ex.hanzi) (\(ex.pinyin))")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Button {
                            UIPasteboard.general.string = ex.hanzi
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let sentence = ex.sentenceHanzi {
                        Divider()
                        Text(sentence).font(Theme.hanzi(18))
                        if let p = ex.sentencePinyin {
                            Text(p).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        if let m = ex.sentenceMeaning {
                            Text("\"" + m + "\"").font(.system(size: 13, design: .serif))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(ex.meaning).font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.card)
                )
            }
        }
    }

    private var addToListButton: some View {
        Button {
            showAddToList = true
        } label: {
            HStack {
                Image(systemName: "bookmark.fill")
                Text("Add to Practice List")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accent)
            )
        }
        .buttonStyle(.plain)
    }

    private func mnemonicCard(text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(Theme.accent)
                Text("MNEMONIC")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .tracking(1.5)
            }
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.accentSoft.opacity(0.6))
        )
    }

    private var shareString: String {
        "\(character.char) (\(character.pinyin)) — \(character.meaning)"
    }
}

// MARK: - Add-to-list sheet

struct AddToListSheet: View {
    let character: HanziCharacter
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var lists: [VocabularyList]

    @State private var newListName: String = ""
    @State private var creating: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if lists.isEmpty {
                        Text("You don't have any lists yet — create one below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lists) { list in
                        Button {
                            UserDataController(context: modelContext)
                                .add(character.id, to: list)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: list.symbol)
                                    .foregroundStyle(Color(hex: UInt32(list.colorHex)))
                                VStack(alignment: .leading) {
                                    Text(list.name).font(.system(size: 15, weight: .semibold))
                                    Text(list.entryCountSummary)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if list.effectiveEntries.contains(character.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                } else {
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(list.effectiveEntries.contains(character.id))
                    }
                }

                Section("Create new list") {
                    TextField("List name", text: $newListName)
                    Button {
                        let trimmed = newListName.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        creating = true
                        let controller = UserDataController(context: modelContext)
                        _ = controller.createList(name: trimmed,
                                                   detail: "Custom list",
                                                   symbol: "bookmark.fill",
                                                   colorHex: 0x266358,
                                                   initial: [character.id])
                        dismiss()
                    } label: {
                        Label("Create and add", systemImage: "plus.circle.fill")
                    }
                    .disabled(newListName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Add to Practice List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Speech helper

@MainActor
final class Speech {
    static let shared = Speech()
    private let synth = AVSpeechSynthesizer()

    func say(_ pinyin: String, locale: String, text: String) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let utt = AVSpeechUtterance(string: text)
        utt.voice = AVSpeechSynthesisVoice(language: locale)
        utt.rate = 0.42
        synth.speak(utt)
    }
}
