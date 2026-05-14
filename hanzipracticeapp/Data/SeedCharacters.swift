//
//  SeedCharacters.swift
//  hanzipracticeapp
//
//  Curated metadata (HSK level, mnemonics, examples, tags) for a small set
//  of "featured" characters. This is overlaid onto the comprehensive MMA
//  dataset by `CharacterStore`. Stroke graphics come from MMA, not here.
//

import Foundation

/// Curated overlay record — only the fields the bundled JSON / dataset doesn't
/// already provide.
struct CuratedCharacter: Sendable {
    let char: String
    let pinyin: String?           // override MMA pinyin if set (tone marks etc.)
    let meaning: String?          // friendlier gloss than MMA's definition
    let hskLevel: Int
    let radical: RelatedCharacter?
    let variant: RelatedCharacter?
    let structure: String?
    let examples: [UsageExample]
    let mnemonic: String?
    let tags: [String]
}


nonisolated enum SeedCharacters {

    nonisolated static let curated: [CuratedCharacter] = [

        // MARK: HSK 1 — single strokes & numerals

        CuratedCharacter(
            char: "一", pinyin: "yī", meaning: "one",
            hskLevel: 1,
            radical: RelatedCharacter(char: "一", label: "One"),
            variant: nil, structure: "Single",
            examples: [
                UsageExample(hanzi: "一个", pinyin: "yī gè",
                             meaning: "one (of something)",
                             sentenceHanzi: "我有一个想法。",
                             sentencePinyin: "Wǒ yǒu yī gè xiǎngfǎ.",
                             sentenceMeaning: "I have an idea.")
            ],
            mnemonic: "A single horizontal line — the simplest character and the number one.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "二", pinyin: "èr", meaning: "two",
            hskLevel: 1,
            radical: RelatedCharacter(char: "二", label: "Two"),
            variant: nil, structure: "Top-Bottom",
            examples: [
                UsageExample(hanzi: "二月", pinyin: "èr yuè", meaning: "February",
                             sentenceHanzi: nil, sentencePinyin: nil, sentenceMeaning: nil)
            ],
            mnemonic: "Two horizontal strokes — top shorter, bottom longer.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "三", pinyin: "sān", meaning: "three",
            hskLevel: 1,
            radical: RelatedCharacter(char: "一", label: "One"),
            variant: nil, structure: "Stacked",
            examples: [
                UsageExample(hanzi: "三个", pinyin: "sān gè", meaning: "three (things)",
                             sentenceHanzi: nil, sentencePinyin: nil, sentenceMeaning: nil)
            ],
            mnemonic: "Three lines stacked — short, shorter, longest.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "人", pinyin: "rén", meaning: "person, people",
            hskLevel: 1,
            radical: RelatedCharacter(char: "人", label: "Person"),
            variant: nil, structure: "Left-Right",
            examples: [
                UsageExample(hanzi: "中国人", pinyin: "Zhōngguó rén",
                             meaning: "Chinese (person)",
                             sentenceHanzi: "他是好人。", sentencePinyin: "Tā shì hǎo rén.",
                             sentenceMeaning: "He is a good person.")
            ],
            mnemonic: "Two legs walking — a stick figure of a person.",
            tags: ["common", "radical"]
        ),

        CuratedCharacter(
            char: "大", pinyin: "dà", meaning: "big, large",
            hskLevel: 1,
            radical: RelatedCharacter(char: "大", label: "Big"),
            variant: nil, structure: "Overlapped",
            examples: [
                UsageExample(hanzi: "大学", pinyin: "dàxué", meaning: "university",
                             sentenceHanzi: "她在大学学习。", sentencePinyin: "Tā zài dàxué xuéxí.",
                             sentenceMeaning: "She studies at university.")
            ],
            mnemonic: "A person 人 stretching their arms wide → big.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "小", pinyin: "xiǎo", meaning: "small, little",
            hskLevel: 1,
            radical: RelatedCharacter(char: "小", label: "Small"),
            variant: nil, structure: "Centered",
            examples: [
                UsageExample(hanzi: "小心", pinyin: "xiǎoxīn", meaning: "be careful",
                             sentenceHanzi: "请小心走路。", sentencePinyin: "Qǐng xiǎoxīn zǒulù.",
                             sentenceMeaning: "Please walk carefully.")
            ],
            mnemonic: "A central pillar with two tiny droplets — something small.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "山", pinyin: "shān", meaning: "mountain",
            hskLevel: 2,
            radical: RelatedCharacter(char: "山", label: "Mountain"),
            variant: nil, structure: "Composite",
            examples: [
                UsageExample(hanzi: "山水", pinyin: "shānshuǐ",
                             meaning: "landscape (lit. mountains-water)",
                             sentenceHanzi: nil, sentencePinyin: nil, sentenceMeaning: nil)
            ],
            mnemonic: "Three peaks of a mountain range.",
            tags: ["common", "radical"]
        ),

        CuratedCharacter(
            char: "口", pinyin: "kǒu", meaning: "mouth, opening",
            hskLevel: 1,
            radical: RelatedCharacter(char: "口", label: "Mouth"),
            variant: nil, structure: "Enclosure",
            examples: [
                UsageExample(hanzi: "出口", pinyin: "chūkǒu", meaning: "exit",
                             sentenceHanzi: nil, sentencePinyin: nil, sentenceMeaning: nil)
            ],
            mnemonic: "A square — the open shape of a mouth.",
            tags: ["common", "radical"]
        ),

        CuratedCharacter(
            char: "中", pinyin: "zhōng", meaning: "middle, center, China",
            hskLevel: 1,
            radical: RelatedCharacter(char: "丨", label: "Vertical"),
            variant: nil, structure: "Pierced",
            examples: [
                UsageExample(hanzi: "中国", pinyin: "Zhōngguó", meaning: "China",
                             sentenceHanzi: "我来自中国。", sentencePinyin: "Wǒ láizì Zhōngguó.",
                             sentenceMeaning: "I'm from China.")
            ],
            mnemonic: "An arrow piercing the center of a box — the middle.",
            tags: ["common", "trending"]
        ),

        CuratedCharacter(
            char: "上", pinyin: "shàng", meaning: "up, above, on",
            hskLevel: 1,
            radical: RelatedCharacter(char: "一", label: "One"),
            variant: nil, structure: "Stacked",
            examples: [
                UsageExample(hanzi: "上海", pinyin: "Shànghǎi", meaning: "Shanghai",
                             sentenceHanzi: nil, sentencePinyin: nil, sentenceMeaning: nil)
            ],
            mnemonic: "A mark sitting above a baseline — up.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "下", pinyin: "xià", meaning: "down, below, under",
            hskLevel: 1,
            radical: RelatedCharacter(char: "一", label: "One"),
            variant: nil, structure: "Stacked",
            examples: [
                UsageExample(hanzi: "下午", pinyin: "xiàwǔ", meaning: "afternoon",
                             sentenceHanzi: nil, sentencePinyin: nil, sentenceMeaning: nil)
            ],
            mnemonic: "A mark hanging below a ceiling — down.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "不", pinyin: "bù", meaning: "no, not",
            hskLevel: 1,
            radical: RelatedCharacter(char: "一", label: "One"),
            variant: nil, structure: "Composite",
            examples: [
                UsageExample(hanzi: "不是", pinyin: "bú shì", meaning: "is not",
                             sentenceHanzi: "他不是学生。", sentencePinyin: "Tā bú shì xuésheng.",
                             sentenceMeaning: "He is not a student.")
            ],
            mnemonic: "A roof with legs running away — refusing, not.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "我", pinyin: "wǒ", meaning: "I, me, myself",
            hskLevel: 1,
            radical: RelatedCharacter(char: "戈", label: "Spear"),
            variant: nil, structure: "Left-Right",
            examples: [
                UsageExample(hanzi: "我们", pinyin: "wǒmen", meaning: "we, us",
                             sentenceHanzi: "我喜欢学中文。", sentencePinyin: "Wǒ xǐhuan xué Zhōngwén.",
                             sentenceMeaning: "I like to study Chinese.")
            ],
            mnemonic: "Hand holding a spear — I, the warrior of my own life.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "你", pinyin: "nǐ", meaning: "you",
            hskLevel: 1,
            radical: RelatedCharacter(char: "亻", label: "Person"),
            variant: nil, structure: "Left-Right",
            examples: [
                UsageExample(hanzi: "你好", pinyin: "nǐ hǎo", meaning: "hello",
                             sentenceHanzi: "你叫什么名字?", sentencePinyin: "Nǐ jiào shénme míngzi?",
                             sentenceMeaning: "What's your name?")
            ],
            mnemonic: "A person 亻 plus the second-person particle 尔 → you.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "好", pinyin: "hǎo", meaning: "good, well",
            hskLevel: 1,
            radical: RelatedCharacter(char: "女", label: "Woman"),
            variant: nil, structure: "Left-Right",
            examples: [
                UsageExample(hanzi: "你好", pinyin: "nǐ hǎo", meaning: "hello",
                             sentenceHanzi: "今天天气很好。", sentencePinyin: "Jīntiān tiānqì hěn hǎo.",
                             sentenceMeaning: "The weather is nice today.")
            ],
            mnemonic: "A woman 女 with her child 子 → good.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "水", pinyin: "shuǐ", meaning: "water",
            hskLevel: 1,
            radical: RelatedCharacter(char: "水", label: "Water"),
            variant: RelatedCharacter(char: "氵", label: "Water (radical)"),
            structure: "Composite",
            examples: [
                UsageExample(hanzi: "喝水", pinyin: "hē shuǐ", meaning: "drink water",
                             sentenceHanzi: "请多喝水。", sentencePinyin: "Qǐng duō hē shuǐ.",
                             sentenceMeaning: "Please drink more water.")
            ],
            mnemonic: "A central river with droplets splashing on either side.",
            tags: ["common", "radical"]
        ),

        CuratedCharacter(
            char: "火", pinyin: "huǒ", meaning: "fire",
            hskLevel: 2,
            radical: RelatedCharacter(char: "火", label: "Fire"),
            variant: RelatedCharacter(char: "灬", label: "Fire (radical)"),
            structure: "Composite",
            examples: [
                UsageExample(hanzi: "火车", pinyin: "huǒchē", meaning: "train",
                             sentenceHanzi: nil, sentencePinyin: nil, sentenceMeaning: nil)
            ],
            mnemonic: "A flame with sparks flying out to either side.",
            tags: ["common", "radical"]
        ),

        CuratedCharacter(
            char: "木", pinyin: "mù", meaning: "tree, wood",
            hskLevel: 2,
            radical: RelatedCharacter(char: "木", label: "Tree"),
            variant: nil, structure: "Composite",
            examples: [
                UsageExample(hanzi: "树木", pinyin: "shùmù", meaning: "trees",
                             sentenceHanzi: nil, sentencePinyin: nil, sentenceMeaning: nil)
            ],
            mnemonic: "A trunk, two roots and the ground line — a tree.",
            tags: ["common", "radical"]
        ),

        CuratedCharacter(
            char: "日", pinyin: "rì", meaning: "sun, day",
            hskLevel: 1,
            radical: RelatedCharacter(char: "日", label: "Sun"),
            variant: nil, structure: "Enclosure",
            examples: [
                UsageExample(hanzi: "今日", pinyin: "jīnrì", meaning: "today",
                             sentenceHanzi: nil, sentencePinyin: nil, sentenceMeaning: nil)
            ],
            mnemonic: "A box with a horizon line — the rising sun.",
            tags: ["common", "radical"]
        ),

        CuratedCharacter(
            char: "月", pinyin: "yuè", meaning: "moon, month",
            hskLevel: 1,
            radical: RelatedCharacter(char: "月", label: "Moon"),
            variant: nil, structure: "Enclosure",
            examples: [
                UsageExample(hanzi: "月亮", pinyin: "yuèliang", meaning: "the moon",
                             sentenceHanzi: nil, sentencePinyin: nil, sentenceMeaning: nil)
            ],
            mnemonic: "A crescent moon with two cloud streaks across it.",
            tags: ["common", "radical"]
        ),

        CuratedCharacter(
            char: "天", pinyin: "tiān", meaning: "sky, day, heaven",
            hskLevel: 1,
            radical: RelatedCharacter(char: "大", label: "Big"),
            variant: nil, structure: "Composite",
            examples: [
                UsageExample(hanzi: "今天", pinyin: "jīntiān", meaning: "today",
                             sentenceHanzi: "今天是好日子。", sentencePinyin: "Jīntiān shì hǎo rìzi.",
                             sentenceMeaning: "Today is a good day.")
            ],
            mnemonic: "What is above a person 大 — the sky.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "心", pinyin: "xīn", meaning: "heart, mind",
            hskLevel: 2,
            radical: RelatedCharacter(char: "心", label: "Heart"),
            variant: RelatedCharacter(char: "忄", label: "Heart (radical)"),
            structure: "Composite",
            examples: [
                UsageExample(hanzi: "开心", pinyin: "kāixīn", meaning: "happy",
                             sentenceHanzi: "她很开心。", sentencePinyin: "Tā hěn kāixīn.",
                             sentenceMeaning: "She's very happy.")
            ],
            mnemonic: "Three chambers and an aorta — a stylised heart.",
            tags: ["common", "radical"]
        ),

        CuratedCharacter(
            char: "是", pinyin: "shì", meaning: "to be; yes",
            hskLevel: 1,
            radical: RelatedCharacter(char: "日", label: "Sun"),
            variant: nil, structure: "Top-Bottom",
            examples: [
                UsageExample(hanzi: "是的", pinyin: "shì de", meaning: "yes / it is so",
                             sentenceHanzi: "这是我的书。", sentencePinyin: "Zhè shì wǒ de shū.",
                             sentenceMeaning: "This is my book.")
            ],
            mnemonic: "Sun 日 above a balanced base — what is, is.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "学", pinyin: "xué", meaning: "to study, learn",
            hskLevel: 1,
            radical: RelatedCharacter(char: "子", label: "Child"),
            variant: nil, structure: "Top-Bottom",
            examples: [
                UsageExample(hanzi: "学生", pinyin: "xuéshēng", meaning: "student",
                             sentenceHanzi: "我学中文。", sentencePinyin: "Wǒ xué Zhōngwén.",
                             sentenceMeaning: "I'm studying Chinese.")
            ],
            mnemonic: "A child 子 under a roof receiving knowledge — to study.",
            tags: ["common", "trending"]
        ),

        CuratedCharacter(
            char: "爱", pinyin: "ài", meaning: "love, affection",
            hskLevel: 1,
            radical: RelatedCharacter(char: "心", label: "Heart"),
            variant: nil, structure: "Top-Bottom",
            examples: [
                UsageExample(hanzi: "我爱你", pinyin: "wǒ ài nǐ", meaning: "I love you",
                             sentenceHanzi: "我爱中国菜。", sentencePinyin: "Wǒ ài Zhōngguó cài.",
                             sentenceMeaning: "I love Chinese food.")
            ],
            mnemonic: "A hand 爫 over a friend 友, holding their heart 心 close — love.",
            tags: ["common", "trending"]
        ),

        CuratedCharacter(
            char: "和", pinyin: "hé", meaning: "harmony, peace; and",
            hskLevel: 1,
            radical: RelatedCharacter(char: "口", label: "Mouth"),
            variant: nil, structure: "Left-Right",
            examples: [
                UsageExample(hanzi: "和平", pinyin: "hépíng", meaning: "peace",
                             sentenceHanzi: "我和你都是朋友。", sentencePinyin: "Wǒ hé nǐ dōu shì péngyǒu.",
                             sentenceMeaning: "You and I are both friends.")
            ],
            mnemonic: "Grain 禾 by a mouth 口 — eating together brings harmony.",
            tags: ["common", "trending"]
        ),

        CuratedCharacter(
            char: "明", pinyin: "míng", meaning: "bright, clear",
            hskLevel: 1,
            radical: RelatedCharacter(char: "日", label: "Sun"),
            variant: nil, structure: "Left-Right",
            examples: [
                UsageExample(hanzi: "明天", pinyin: "míngtiān", meaning: "tomorrow",
                             sentenceHanzi: "明天见!", sentencePinyin: "Míngtiān jiàn!",
                             sentenceMeaning: "See you tomorrow!")
            ],
            mnemonic: "The sun 日 and the moon 月 together — bright and clear.",
            tags: ["common", "trending"]
        ),

        CuratedCharacter(
            char: "永", pinyin: "yǒng", meaning: "eternal, forever, always",
            hskLevel: 3,
            radical: RelatedCharacter(char: "丶", label: "Dot"),
            variant: RelatedCharacter(char: "水", label: "Water"),
            structure: "Composite",
            examples: [
                UsageExample(hanzi: "永远", pinyin: "yǒngyuǎn", meaning: "forever, always",
                             sentenceHanzi: "我会永远爱你。", sentencePinyin: "Wǒ huì yǒngyuǎn ài nǐ.",
                             sentenceMeaning: "I will love you forever.")
            ],
            mnemonic: "The classic stroke-order character — every basic brush technique appears in 永.",
            tags: ["common", "trending"]
        ),

        CuratedCharacter(
            char: "德", pinyin: "dé", meaning: "virtue, morality",
            hskLevel: 5,
            radical: RelatedCharacter(char: "彳", label: "Step"),
            variant: nil, structure: "Left-Right",
            examples: [
                UsageExample(hanzi: "道德", pinyin: "dàodé", meaning: "morality",
                             sentenceHanzi: nil, sentencePinyin: nil, sentenceMeaning: nil)
            ],
            mnemonic: "Stepping forward 彳 with a straight heart 心 — virtue.",
            tags: ["trending"]
        ),

        CuratedCharacter(
            char: "书", pinyin: "shū", meaning: "book, to write",
            hskLevel: 1,
            radical: RelatedCharacter(char: "丨", label: "Vertical"),
            variant: nil, structure: "Composite",
            examples: [
                UsageExample(hanzi: "书店", pinyin: "shūdiàn", meaning: "bookstore",
                             sentenceHanzi: nil, sentencePinyin: nil, sentenceMeaning: nil)
            ],
            mnemonic: "A brush over a writing tablet — to write, a book.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "家", pinyin: "jiā", meaning: "home, family",
            hskLevel: 1,
            radical: RelatedCharacter(char: "宀", label: "Roof"),
            variant: nil, structure: "Top-Bottom",
            examples: [
                UsageExample(hanzi: "家人", pinyin: "jiārén", meaning: "family members",
                             sentenceHanzi: "我爱我的家。", sentencePinyin: "Wǒ ài wǒ de jiā.",
                             sentenceMeaning: "I love my home.")
            ],
            mnemonic: "A pig 豕 under a roof 宀 — the traditional home.",
            tags: ["common"]
        ),

        CuratedCharacter(
            char: "汉", pinyin: "hàn", meaning: "Chinese; the Han people",
            hskLevel: 3,
            radical: RelatedCharacter(char: "氵", label: "Water"),
            variant: nil, structure: "Left-Right",
            examples: [
                UsageExample(hanzi: "汉字", pinyin: "Hànzì", meaning: "Chinese characters",
                             sentenceHanzi: "我在练习汉字。", sentencePinyin: "Wǒ zài liànxí Hànzì.",
                             sentenceMeaning: "I'm practicing Chinese characters.")
            ],
            mnemonic: "Water 氵beside the crossing X — the Han people lived by the river.",
            tags: ["common"]
        )
    ]
}
