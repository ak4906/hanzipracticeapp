//
//  SRSEngine.swift
//  hanzipracticeapp
//
//  A small SM-2 inspired spaced-repetition scheduler.
//

import Foundation

enum SRSGrade: Int, CaseIterable, Identifiable {
    case again = 0   // forgot — restart
    case hard  = 3
    case good  = 4
    case easy  = 5

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .again: "Again"
        case .hard:  "Hard"
        case .good:  "Good"
        case .easy:  "Easy"
        }
    }

    /// Approximate human-friendly preview of the next interval, given a card.
    func previewInterval(for card: SRSCard) -> String {
        let next = SRSEngine.previewInterval(for: card, grade: self)
        return SRSEngine.format(interval: next)
    }
}

enum SRSEngine {

    /// Apply a grade to a card, updating it in place.
    static func apply(grade: SRSGrade, to card: SRSCard, now: Date = .now) {
        card.reviewCount += 1
        card.lastReviewed = now

        // Mastery: EWMA of the implicit 0…1 score derived from the grade.
        let score: Double
        switch grade {
        case .again: score = 0.0
        case .hard:  score = 0.55
        case .good:  score = 0.8
        case .easy:  score = 1.0
        }
        let alpha = 0.35
        card.mastery = (1 - alpha) * card.mastery + alpha * score

        switch grade {
        case .again:
            card.lapseCount += 1
            card.repetitions = 0
            card.interval = 0
            card.ease = max(1.3, card.ease - 0.2)
            card.dueDate = now.addingTimeInterval(10 * 60)             // 10 minutes
        case .hard:
            card.repetitions += 1
            card.ease = max(1.3, card.ease - 0.15)
            card.interval = max(1, card.interval * 1.2)
            if card.repetitions == 1 { card.interval = 1 }
            card.dueDate = now.addingTimeInterval(card.interval * 86_400)
        case .good:
            card.repetitions += 1
            card.interval = newInterval(for: card)
            card.dueDate = now.addingTimeInterval(card.interval * 86_400)
        case .easy:
            card.repetitions += 1
            card.ease = card.ease + 0.15
            card.interval = newInterval(for: card) * 1.3
            card.dueDate = now.addingTimeInterval(card.interval * 86_400)
        }
    }

    /// Non-mutating preview of what `apply(grade:)` would do to a card.
    static func previewInterval(for card: SRSCard, grade: SRSGrade) -> Double {
        let copy = SRSCard(characterID: card.characterID,
                           interval: card.interval,
                           ease: card.ease,
                           repetitions: card.repetitions,
                           dueDate: card.dueDate,
                           mastery: card.mastery,
                           reviewCount: card.reviewCount,
                           lapseCount: card.lapseCount)
        apply(grade: grade, to: copy)
        return copy.interval == 0 ? (10.0 / 1440.0) : copy.interval   // minutes → days
    }

    private static func newInterval(for card: SRSCard) -> Double {
        switch card.repetitions {
        case 1: return 1
        case 2: return 3
        default: return card.interval * card.ease
        }
    }

    static func format(interval days: Double) -> String {
        if days < 1.0 / 24 {
            let minutes = max(1, Int(days * 24 * 60))
            return "\(minutes) min"
        }
        if days < 1 {
            let hours = Int(days * 24)
            return "\(hours) hr"
        }
        if days < 30 {
            return "\(Int(days.rounded())) d"
        }
        if days < 365 {
            return String(format: "%.1f mo", days / 30.0)
        }
        return String(format: "%.1f yr", days / 365.0)
    }
}
