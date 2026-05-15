//
//  ActivityHeatmap.swift
//  hanzipracticeapp
//
//  GitHub-style contribution graph that shows recent practice intensity.
//

import SwiftUI

struct ActivityHeatmap: View {
    /// Map of day-start → intensity score (0…1).
    let intensityByDay: [Date: Double]
    let weeks: Int

    var body: some View {
        let columns = (0..<weeks).reversed().map { weekOffset -> [HeatmapCell] in
            (0..<7).map { weekday -> HeatmapCell in
                let cal = Calendar.current
                let today = cal.startOfDay(for: .now)
                let weekStart = cal.date(byAdding: .day,
                                         value: -weekOffset * 7 - (6 - weekday),
                                         to: today) ?? today
                let day = cal.startOfDay(for: weekStart)
                let intensity = intensityByDay[day] ?? 0
                return HeatmapCell(date: day, intensity: intensity)
            }
        }

        let monthLabels = columns.enumerated().compactMap { idx, col -> (Int, String)? in
            guard let mid = col.dropFirst(3).first else { return nil }
            let comp = Calendar.current.component(.day, from: mid.date)
            if comp <= 7 {
                let f = DateFormatter()
                f.dateFormat = "MMM"
                return (idx, f.string(from: mid.date))
            }
            return nil
        }

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(0..<columns.count, id: \.self) { i in
                    VStack(spacing: 4) {
                        ForEach(columns[i]) { cell in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color(for: cell.intensity))
                                .frame(width: 16, height: 16)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<columns.count, id: \.self) { i in
                    // Each cell is 16pt wide, but a 3-letter month label
                    // ("Feb", "Mar", …) doesn't fit and was wrapping into a
                    // vertical stack of single letters. Let the text overflow
                    // its frame (months are ~4–5 cells apart, so the spill
                    // never collides with the next label) and force a single
                    // line.
                    Text(monthLabels.first(where: { $0.0 == i })?.1 ?? "")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 16, alignment: .leading)
                }
            }
        }
    }

    private func color(for intensity: Double) -> Color {
        if intensity <= 0 { return Theme.accentSoft.opacity(0.45) }
        let clamped = min(max(intensity, 0), 1)
        return Theme.accent.opacity(0.25 + clamped * 0.75)
    }

    private struct HeatmapCell: Identifiable {
        let date: Date
        let intensity: Double
        var id: Date { date }
    }
}
