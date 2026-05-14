//
//  HanziTile.swift
//  hanzipracticeapp
//
//  Reusable tiles shown in the dictionary grid, the recently-viewed strip
//  and inside vocabulary lists.
//

import SwiftUI

/// Compact pill-shaped chip used in the "Recently viewed" strip.
struct RecentHanziChip: View {
    let character: HanziCharacter

    var body: some View {
        VStack(spacing: 4) {
            Text(character.char)
                .font(Theme.hanzi(36, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(height: 44)
            Text(character.pinyinToneless.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            Text(character.meaning.firstPart)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(width: 96)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
    }
}

/// Big card tile used for the "Trending" grid.
struct HanziGridTile: View {
    let character: HanziCharacter
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Image(systemName: "applepencil.and.scribble")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(7)
                    .foregroundStyle(Theme.accent)
                    .background(
                        Circle().fill(Theme.card)
                    )
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Text(character.char)
                    .font(Theme.hanzi(compact ? 72 : 96, weight: .regular))
                    .foregroundStyle(Theme.accent)
                Spacer()
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                Text(character.pinyin)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                if character.hskLevel > 0 {
                    Text("HSK \(character.hskLevel)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Theme.card)
                        )
                }
            }
            Text(character.meaning.firstPart)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(height: compact ? 140 : 200)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.accentSoft.opacity(0.6))
        )
    }
}

/// Row used inside a search-results list or vocabulary editor.
struct HanziListRow: View {
    let character: HanziCharacter
    var accessory: AnyView? = nil

    var body: some View {
        HStack(spacing: 14) {
            Text(character.char)
                .font(Theme.hanzi(36, weight: .regular))
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.surface)
                )
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(character.pinyin)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    if character.hskLevel > 0 {
                        Text("HSK \(character.hskLevel)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    if character.strokeCount > 0 {
                        Text("\(character.strokeCount) strokes")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(character.meaning)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let accessory { accessory }
        }
        .padding(.vertical, 6)
    }
}

extension String {
    /// Take the first segment before a comma, useful when a meaning lists
    /// several glosses ("eternal, forever, always" → "eternal").
    var firstPart: String {
        if let idx = firstIndex(of: ",") {
            return String(self[..<idx])
        }
        return self
    }

    /// Alias used inside etymology blurbs.
    var firstGloss: String { firstPart }
}
