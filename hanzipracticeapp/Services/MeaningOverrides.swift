//
//  MeaningOverrides.swift
//  hanzipracticeapp
//
//  Tiny curated table that lets us hand-pick the *teaching-relevant*
//  meaning for a hanzi when the chinese-lexicon `short` definition
//  picks an etymologically interesting but classroom-rare sense. The
//  inspiration for this file was 周: lexicon gives "to circle, to
//  make a circuit", but in HSK 1-3 classes the character only ever
//  means "week". Without this override the dictionary detail page and
//  every quiz answer surface "to circle", which doesn't match what
//  the learner has actually been taught.
//
//  Scope: keep this small. We're not trying to redefine the language
//  — only patching the handful of characters where the lexicon's
//  scoring chose poorly. Add an entry whenever a real lesson or
//  example sentence demonstrates a sense that's missing from the
//  current `short` value. Keep entries to ≤ 30 chars so quiz chips
//  still fit cleanly.
//
//  Order of precedence in `CharacterStore.character(for:)`:
//    1. SeedCharacters curated overlay (hand-written rich entries)
//    2. **This override table**
//    3. chinese-lexicon short definition
//    4. MMA dictionary definition (fallback)
//

import Foundation

enum MeaningOverrides {

    /// Canonical (Simplified) char → preferred meaning string.
    /// Multi-sense glosses are comma-separated like the rest of the
    /// app — `.quizFriendly` will keep them whole on the chip.
    static let table: [String: String] = [
        // Time / cycle words that the lexicon labelled by their
        // etymological "circular motion" sense, but learners only
        // ever encounter as time units.
        "周": "week, cycle",
        // Particle-heavy chars where the lexicon picked a verb sense.
        // Learners hit these as grammar markers first, so the gloss
        // needs to acknowledge that.
        "着": "(verb suffix), -ing; to wear",
        "把": "(disposal marker); to hold, to grasp",
        "被": "(passive marker); quilt; to suffer",
        // Direction / verbs whose lexicon short missed a common
        // modern usage.
        "行": "to be OK; to walk, to travel",
        "对": "correct, right; toward",
        "过": "to pass, to cross; (after verb: experience marker)",
        "为": "for; to act as",
        "然": "so, in this way; -ly suffix",
        // 到 is mostly used as a result complement ("到了 — arrived")
        // not the literal "to go" verb chinese-lexicon picked.
        "到": "to arrive; until, up to",
        // 就 is overwhelmingly the "then / right away" adverb in
        // beginner material, not the lexicon's "only".
        "就": "then, right away; only",
    ]

    /// Lookup the curated meaning for a canonical char id. Returns nil
    /// when no override exists so the caller can fall back through
    /// the normal lexicon → MMA chain.
    static func meaning(for canonical: String) -> String? {
        table[canonical]
    }
}
