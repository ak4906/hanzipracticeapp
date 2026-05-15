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
    func previewInterval<C: SRSCardBackend>(for card: C) -> String {
        let next = SRSEngine.previewInterval(for: card, grade: self)
        return SRSEngine.format(interval: next)
    }
}

/// Minimal protocol for the mutable SRS fields shared by every card model.
/// Both `SRSCard` (writing) and `SRSQuizCard` (reading / translation)
/// conform, letting `SRSEngine.apply` run the same SM-2 update without
/// duplicating the logic per type.
@MainActor
protocol SRSCardBackend: AnyObject {
    var interval: Double { get set }
    var ease: Double { get set }
    var repetitions: Int { get set }
    var dueDate: Date { get set }
    var lastReviewed: Date? { get set }
    var mastery: Double { get set }
    var reviewCount: Int { get set }
    var lapseCount: Int { get set }
}

extension SRSCard: SRSCardBackend {}
extension SRSQuizCard: SRSCardBackend {}

enum SRSEngine {

    /// Apply a grade to any SRS card, updating it in place.
    static func apply<C: SRSCardBackend>(grade: SRSGrade, to card: C, now: Date = .now) {
        // True before we bump reviewCount — this is the very first time the
        // user is grading this card. Used to override interval logic so the
        // first review uses friendly short intervals instead of the SM-2
        // defaults (which gave 1d for every grade except Again).
        let isFirstReview = card.reviewCount == 0
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
            // Short re-show delay so a slipped character comes back inside
            // the same session — 1 min on first slip, doubling up to a cap.
            let delaySeconds = SRSEngine.againDelaySeconds(for: card.lapseCount)
            card.dueDate = now.addingTimeInterval(delaySeconds)
        case .hard:
            card.repetitions += 1
            card.ease = max(1.3, card.ease - 0.15)
            if isFirstReview {
                // First-time Hard: come back in 10 minutes, not a whole day.
                card.interval = 0
                card.dueDate = now.addingTimeInterval(10 * 60)
            } else {
                card.interval = max(1, card.interval * 1.2)
                card.dueDate = now.addingTimeInterval(card.interval * 86_400)
            }
        case .good:
            card.repetitions += 1
            if isFirstReview {
                card.interval = 1                    // 1 day
            } else {
                card.interval = newInterval(for: card)
            }
            card.dueDate = now.addingTimeInterval(card.interval * 86_400)
        case .easy:
            card.repetitions += 1
            card.ease = card.ease + 0.15
            if isFirstReview {
                card.interval = 3                    // 3 days
            } else {
                card.interval = newInterval(for: card) * 1.3
            }
            card.dueDate = now.addingTimeInterval(card.interval * 86_400)
        }
    }

    /// Non-mutating preview of what `apply(grade:)` would do to any card.
    /// Returns the resulting interval expressed in days — including sub-day
    /// values for short re-show delays (Again's 1-min, Hard's 10-min, etc.).
    static func previewInterval<C: SRSCardBackend>(for card: C,
                                                    grade: SRSGrade) -> Double {
        let now = Date.now
        let copy = SimulatedCard(from: card)
        apply(grade: grade, to: copy, now: now)
        // Derive from the actual due-date diff so Again's 1-min delay isn't
        // misreported as the previous hardcoded 10-min fallback.
        return copy.dueDate.timeIntervalSince(now) / 86_400
    }

    private static func newInterval<C: SRSCardBackend>(for card: C) -> Double {
        switch card.repetitions {
        case 1: return 1
        case 2: return 3
        default: return card.interval * card.ease
        }
    }

    /// Re-show delay (seconds) after an "Again" grade. Doubles per lapse:
    /// 1 min, 2 min, 4 min, 8 min, 15 min cap. Keeps slipped characters
    /// inside the same short practice window for the first few tries.
    static func againDelaySeconds(for lapseCount: Int) -> TimeInterval {
        let lapses = max(1, lapseCount)
        let minutes = min(15.0, pow(2.0, Double(lapses - 1)))
        return minutes * 60
    }

    /// Throwaway class used for non-mutating previews — copies the SRS
    /// fields off a real `SRSCardBackend` so we can run `apply` against it
    /// without affecting the persisted card. Not a SwiftData model.
    @MainActor
    private final class SimulatedCard: SRSCardBackend {
        var interval: Double
        var ease: Double
        var repetitions: Int
        var dueDate: Date
        var lastReviewed: Date?
        var mastery: Double
        var reviewCount: Int
        var lapseCount: Int

        init<C: SRSCardBackend>(from source: C) {
            self.interval = source.interval
            self.ease = source.ease
            self.repetitions = source.repetitions
            self.dueDate = source.dueDate
            self.lastReviewed = source.lastReviewed
            self.mastery = source.mastery
            self.reviewCount = source.reviewCount
            self.lapseCount = source.lapseCount
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
