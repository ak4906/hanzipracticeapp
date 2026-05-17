//
//  RadicalNotes.swift
//  hanzipracticeapp
//
//  Curated learning-context notes for the most common Chinese radicals
//  and component forms. The component-quiz options use these to surface
//  *why* a radical is there ("classifies water-related things"), which
//  is the bit that turns a multiple-choice answer into something the
//  user actually internalises.
//
//  The chinese-lexicon definitions cover the literal meaning ("water",
//  "fire") but don't say much about the *function* a radical performs
//  inside a compound character. That function-level hint is what the
//  user asked for when they pointed out that 氵 isn't just "water" —
//  it's the marker that classifies a character as something water-
//  related (river, lake, ocean, washing, drinking…). This table is
//  scoped to the radicals a learner is likeliest to hit in HSK 1-4.
//
//  Per-radical fields:
//    • pinyin  — the standalone reading when the radical is also a
//      free character (人 rén); empty when the radical only appears
//      bound (e.g. 灬, 宀).
//    • meaning — the literal gloss in 1-3 words.
//    • role    — short "why is this here when it appears in a
//      compound" note. Designed for the quiz secondary line.
//

import Foundation

enum RadicalNotes {

    struct Entry: Hashable, Sendable {
        let pinyin: String     // empty for bound-only forms
        let meaning: String
        let role: String
    }

    static let table: [String: Entry] = [
        // Person / human ─────────────────────────────────────────────
        "人": Entry(pinyin: "rén", meaning: "person",
                   role: "classifies people and roles"),
        "亻": Entry(pinyin: "rén", meaning: "person",
                   role: "left-side form of 人; classifies people"),

        // Water ───────────────────────────────────────────────────────
        "水": Entry(pinyin: "shuǐ", meaning: "water",
                   role: "classifies water and liquids"),
        "氵": Entry(pinyin: "shuǐ", meaning: "water",
                   role: "left-side form of 水; classifies water-related things (rivers, washing, drinking)"),

        // Fire ────────────────────────────────────────────────────────
        "火": Entry(pinyin: "huǒ", meaning: "fire",
                   role: "classifies fire and heat"),
        "灬": Entry(pinyin: "huǒ", meaning: "fire",
                   role: "bottom form of 火; classifies fire/heat (cooking, boiling)"),

        // Heart / mind ────────────────────────────────────────────────
        "心": Entry(pinyin: "xīn", meaning: "heart, mind",
                   role: "classifies feelings, thoughts, mental states"),
        "忄": Entry(pinyin: "xīn", meaning: "heart, mind",
                   role: "left-side form of 心; classifies feelings and thoughts"),

        // Hand ────────────────────────────────────────────────────────
        "手": Entry(pinyin: "shǒu", meaning: "hand",
                   role: "classifies hand-related actions"),
        "扌": Entry(pinyin: "shǒu", meaning: "hand",
                   role: "left-side form of 手; classifies actions done with the hands (push, pull, hit)"),

        // Mouth / speech ─────────────────────────────────────────────
        "口": Entry(pinyin: "kǒu", meaning: "mouth",
                   role: "classifies mouth actions (eating, speaking, shouting)"),
        "言": Entry(pinyin: "yán", meaning: "speech",
                   role: "classifies speaking, language, words"),
        "讠": Entry(pinyin: "yán", meaning: "speech",
                   role: "left-side form of 言; classifies speech and language"),

        // Walking / movement ─────────────────────────────────────────
        "辶": Entry(pinyin: "chuò", meaning: "walk",
                   role: "wraps actions of movement, travel, going"),
        "走": Entry(pinyin: "zǒu", meaning: "walk, go",
                   role: "classifies walking/running actions"),
        "彳": Entry(pinyin: "chì", meaning: "step",
                   role: "left-side form; classifies stepping and walking"),

        // Plant / wood ────────────────────────────────────────────────
        "木": Entry(pinyin: "mù", meaning: "tree, wood",
                   role: "classifies trees, wood, and wooden tools"),
        "艹": Entry(pinyin: "cǎo", meaning: "grass, plant",
                   role: "top form of 草; classifies plants, herbs, flowers"),
        "禾": Entry(pinyin: "hé", meaning: "grain",
                   role: "classifies grains and crops"),
        "竹": Entry(pinyin: "zhú", meaning: "bamboo",
                   role: "classifies bamboo and bamboo objects"),

        // Sun / moon / weather ───────────────────────────────────────
        "日": Entry(pinyin: "rì", meaning: "sun, day",
                   role: "classifies time, sun, brightness"),
        "月": Entry(pinyin: "yuè", meaning: "moon, month",
                   role: "classifies moon/months OR (when from 肉) flesh/body parts"),
        "雨": Entry(pinyin: "yǔ", meaning: "rain",
                   role: "classifies weather and precipitation"),

        // Earth / minerals ───────────────────────────────────────────
        "土": Entry(pinyin: "tǔ", meaning: "earth, soil",
                   role: "classifies soil, ground, places"),
        "石": Entry(pinyin: "shí", meaning: "stone",
                   role: "classifies stone, rocks, hardness"),
        "金": Entry(pinyin: "jīn", meaning: "gold, metal",
                   role: "classifies metals"),
        "钅": Entry(pinyin: "jīn", meaning: "metal",
                   role: "left-side form of 金; classifies metal objects"),

        // Body / parts ───────────────────────────────────────────────
        "目": Entry(pinyin: "mù", meaning: "eye",
                   role: "classifies eyes, seeing, vision"),
        "耳": Entry(pinyin: "ěr", meaning: "ear",
                   role: "classifies ears and hearing"),
        "足": Entry(pinyin: "zú", meaning: "foot",
                   role: "classifies feet and leg actions"),
        "牛": Entry(pinyin: "niú", meaning: "ox, cow",
                   role: "classifies cattle and oxen"),
        "马": Entry(pinyin: "mǎ", meaning: "horse",
                   role: "classifies horses and horse-related"),
        "鸟": Entry(pinyin: "niǎo", meaning: "bird",
                   role: "classifies birds"),
        "鱼": Entry(pinyin: "yú", meaning: "fish",
                   role: "classifies fish and aquatic creatures"),

        // Buildings / containers ─────────────────────────────────────
        "宀": Entry(pinyin: "mián", meaning: "roof",
                   role: "tops a character; classifies buildings, homes, shelter"),
        "广": Entry(pinyin: "guǎng", meaning: "shelter",
                   role: "left-top form; classifies buildings and shelters"),
        "门": Entry(pinyin: "mén", meaning: "door, gate",
                   role: "frames a character; classifies doors and gates"),
        "囗": Entry(pinyin: "wéi", meaning: "enclosure",
                   role: "wraps a character; classifies enclosures and surrounding"),
        "户": Entry(pinyin: "hù", meaning: "door",
                   role: "classifies doors and households"),

        // Tools / cloth / food ───────────────────────────────────────
        "巾": Entry(pinyin: "jīn", meaning: "cloth",
                   role: "classifies cloth, fabric, towels"),
        "衤": Entry(pinyin: "yī", meaning: "clothing",
                   role: "left-side form of 衣; classifies clothing"),
        "刀": Entry(pinyin: "dāo", meaning: "knife",
                   role: "classifies knives and cutting"),
        "刂": Entry(pinyin: "dāo", meaning: "knife",
                   role: "right-side form of 刀; classifies cutting actions"),
        "力": Entry(pinyin: "lì", meaning: "strength",
                   role: "classifies strength, effort, force"),
        "食": Entry(pinyin: "shí", meaning: "eat, food",
                   role: "classifies eating and food"),
        "饣": Entry(pinyin: "shí", meaning: "eat, food",
                   role: "left-side form of 食; classifies eating and food"),

        // Numbers / abstract ─────────────────────────────────────────
        "女": Entry(pinyin: "nǚ", meaning: "woman",
                   role: "classifies female roles and family relations"),
        "子": Entry(pinyin: "zǐ", meaning: "child",
                   role: "classifies children and small things"),
        "大": Entry(pinyin: "dà", meaning: "big",
                   role: "depicts a person with arms out; means 'big'"),
        "小": Entry(pinyin: "xiǎo", meaning: "small",
                   role: "classifies smallness"),
        "山": Entry(pinyin: "shān", meaning: "mountain",
                   role: "classifies mountains and terrain"),
        "云": Entry(pinyin: "yún", meaning: "cloud",
                   role: "classifies clouds and weather"),
        "工": Entry(pinyin: "gōng", meaning: "work, craft",
                   role: "classifies work and craft"),
    ]

    /// O(1) lookup. Returns nil for radicals not in our curated set
    /// (the option will then fall back to whatever pinyin/meaning the
    /// lexicon has — still useful, just without the role hint).
    static func entry(for radical: String) -> Entry? {
        table[radical]
    }
}
