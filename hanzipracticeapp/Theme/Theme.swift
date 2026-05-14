//
//  Theme.swift
//  hanzipracticeapp
//

import SwiftUI

enum Theme {
    static let accent = Color(red: 38/255, green: 99/255, blue: 88/255)        // deep teal-green
    static let accentSoft = Color(red: 219/255, green: 233/255, blue: 226/255) // pale celadon
    static let accentMid = Color(red: 121/255, green: 167/255, blue: 144/255)
    static let warning = Color(red: 217/255, green: 109/255, blue: 67/255)
    static let surface = Color(.secondarySystemBackground)
    static let card = Color(.tertiarySystemBackground)
    static let hairline = Color.primary.opacity(0.08)

    static let hanziFont = "PingFang SC"

    static func hanzi(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static let cardCorner: CGFloat = 18
}

extension View {
    func cardStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .fill(Theme.surface)
            )
    }

    func softCardStyle() -> some View {
        self
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .fill(Theme.accentSoft.opacity(0.55))
            )
    }
}

extension Color {
    /// Hex helper for ad-hoc colors used in mnemonic highlighting etc.
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
