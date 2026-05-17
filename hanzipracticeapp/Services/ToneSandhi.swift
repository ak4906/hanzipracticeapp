//
//  ToneSandhi.swift
//  hanzipracticeapp
//
//  Mandarin tone-sandhi adjustments that change the *written* tone mark
//  in pinyin transliterations. The big two are 一 and 不 — both have
//  fixed default tones (yī / bù) that shift based on the tone of the
//  following syllable. Without this pass our example-sentence pinyin
//  reads as the textbook citation form, which doesn't match what a
//  native speaker would say:
//
//    一定  →  rendered "yī dìng", spoken "yí dìng"
//    不是  →  rendered "bù shì",  spoken "bú shì"
//
//  Rules implemented (matching the standard taught in HSK / CEFR
//  Mandarin courses):
//
//    一  default = yī
//      • before tone-4 syllable  → yí   (一定 yídìng, 一样 yíyàng)
//      • before tone-1/2/3       → yì   (一天 yìtiān, 一年 yìnián, 一起 yìqǐ)
//      • after 第 (ordinal)      → yī   (第一 dìyī)
//      • at end of phrase / before non-hanzi → yī
//
//    不  default = bù
//      • before tone-4 syllable  → bú   (不要 búyào, 不是 búshì)
//      • elsewhere               → bù
//
//  Limitations: we don't apply third-tone sandhi (你好 stays "nǐhǎo" in
//  text, even though spoken as "níhǎo"); textbook pinyin keeps the
//  original marks for 3-tone clusters, so this matches what learners
//  see in their materials. We also can't reliably distinguish 一月 as
//  "January" (yīyuè) from 一月 as "one month" (yíyuè) without semantic
//  context, so the default 4-tone-before rule wins for now.
//

import Foundation

enum ToneSandhi {

    /// In-place sandhi pass over a (char, pinyin) token stream. The
    /// pinyin strings are mutated when a rule fires; everything else is
    /// untouched. Callers typically build the stream from a single
    /// sentence and then join.
    static func apply(to tokens: inout [(char: String, pinyin: String)]) {
        guard !tokens.isEmpty else { return }
        for i in tokens.indices {
            let ch = tokens[i].char
            // Skip non-hanzi tokens (Latin / punctuation) — they pass
            // through pinyinReading unchanged and don't trigger sandhi
            // on the next syllable either.
            guard ch == "一" || ch == "不" else { continue }
            let nextTone: Int? = nextHanziTone(in: tokens, after: i)
            let prevChar: String? = i > 0 ? tokens[i - 1].char : nil
            switch ch {
            case "一":
                tokens[i].pinyin = yiReading(nextTone: nextTone, prevChar: prevChar)
            case "不":
                tokens[i].pinyin = buReading(nextTone: nextTone)
            default:
                break
            }
        }
    }

    /// The tone of the next *hanzi* token (skipping non-CJK glyphs like
    /// commas, which sandhi reaches across at phrase boundaries — "不,
    /// 是" is rare but should still trigger "bú").
    private static func nextHanziTone(
        in tokens: [(char: String, pinyin: String)], after i: Int
    ) -> Int? {
        var j = i + 1
        while j < tokens.count {
            let next = tokens[j]
            // Pass over non-hanzi glyphs whose pinyin matches the raw
            // char (our convention in pinyinReading for non-CJK).
            if isHanzi(next.char), let t = tone(of: next.pinyin) { return t }
            // Non-hanzi token: treat as a phrase-ender. Per the standard
            // teaching, 一 / 不 at end-of-phrase keep their default tone.
            if !isHanzi(next.char) { return nil }
            j += 1
        }
        return nil
    }

    private static func yiReading(nextTone: Int?, prevChar: String?) -> String {
        // Ordinal override — 一 keeps its citation tone after 第.
        if prevChar == "第" { return "yī" }
        guard let t = nextTone else { return "yī" }
        switch t {
        case 4:           return "yí"
        case 1, 2, 3:     return "yì"
        default:          return "yī" // neutral or unknown → default
        }
    }

    private static func buReading(nextTone: Int?) -> String {
        nextTone == 4 ? "bú" : "bù"
    }

    /// Map a tone-marked syllable to its tone number. Walks the string
    /// looking for the first marked vowel. Returns nil for unmarked
    /// (neutral-tone) syllables or anything we can't classify.
    static func tone(of pinyin: String) -> Int? {
        for scalar in pinyin.unicodeScalars {
            switch scalar {
            case "\u{0101}", "\u{0113}", "\u{012B}", "\u{014D}", "\u{016B}", "\u{01D6}",  // ā ē ī ō ū ǖ
                 "\u{0100}", "\u{0112}", "\u{012A}", "\u{014C}", "\u{016A}", "\u{01D5}":  // Ā Ē Ī Ō Ū Ǖ
                return 1
            case "\u{00E1}", "\u{00E9}", "\u{00ED}", "\u{00F3}", "\u{00FA}", "\u{01D8}",  // á é í ó ú ǘ
                 "\u{00C1}", "\u{00C9}", "\u{00CD}", "\u{00D3}", "\u{00DA}", "\u{01D7}":  // Á É Í Ó Ú Ǘ
                return 2
            case "\u{01CE}", "\u{011B}", "\u{01D0}", "\u{01D2}", "\u{01D4}", "\u{01DA}",  // ǎ ě ǐ ǒ ǔ ǚ
                 "\u{01CD}", "\u{011A}", "\u{01CF}", "\u{01D1}", "\u{01D3}", "\u{01D9}":  // Ǎ Ě Ǐ Ǒ Ǔ Ǚ
                return 3
            case "\u{00E0}", "\u{00E8}", "\u{00EC}", "\u{00F2}", "\u{00F9}", "\u{01DC}",  // à è ì ò ù ǜ
                 "\u{00C0}", "\u{00C8}", "\u{00CC}", "\u{00D2}", "\u{00D9}", "\u{01DB}":  // À È Ì Ò Ù Ǜ
                return 4
            default:
                continue
            }
        }
        return nil
    }

    private static func isHanzi(_ s: String) -> Bool {
        guard let scalar = s.unicodeScalars.first else { return false }
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF)
    }
}
