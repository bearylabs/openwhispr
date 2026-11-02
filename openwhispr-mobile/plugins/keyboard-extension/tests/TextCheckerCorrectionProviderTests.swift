import Foundation
import UIKit

/// The production `TextCheckerCorrectionProvider` with small stand-in dictionaries
/// (`tests/linux/UIKit.swift`), so its decisions can be checked without Apple's: the English
/// contractions only in English sentences, the app's dictionary first, and frequency lists that
/// change the scoring but none of the rules. Linux only (`scripts/test-keyboard-autocorrection.sh`).
@main
enum TextCheckerCorrectionProviderTests {
  static var count = 0
  static var failed = 0
  static func check(_ label: String, _ value: Bool) {
    count += 1
    if !value { print("FAIL: \(label)"); failed += 1 }
  }

  static let english = [
    "the", "think", "this", "is", "so", "and", "have", "you", "cat", "bad", "bag", "ban", "bar",
    "bat", "it", "in", "I", "a", "fine", "today", "tea", "its", "cant", "bin",
  ]
  static let german = ["ich", "bin", "so", "das", "ist", "im", "Haus", "heute", "nicht", "und", "es"]

  static func words(_ json: [String]) -> KeyboardUserDictionary {
    let data = try! JSONSerialization.data(withJSONObject: ["v": 1, "personal": json, "shared": []] as [String: Any])
    return KeyboardUserDictionary(json: String(decoding: data, as: UTF8.self))
  }

  static func list(_ language: String, _ entries: [(String, UInt16)]) -> KeyboardFrequencyList {
    let sorted = entries.map { (Array($0.0.utf8), $0.1) }.sorted { $0.0.lexicographicallyPrecedes($1.0) }
    var bytes = Array("OWFR".utf8)
    func u16(_ value: UInt16) { bytes += [UInt8(value & 0xff), UInt8(value >> 8)] }
    func u32(_ value: UInt32) { bytes += (0..<4).map { UInt8((value >> (8 * $0)) & 0xff) } }
    u16(1); u16(1); bytes += Array(language.utf8); u16(0); u32(UInt32(sorted.count))
    var offset: UInt32 = 0
    for entry in sorted { u32(offset); offset += UInt32(entry.0.count) }
    u32(offset)
    for entry in sorted { u16(entry.1) }
    for entry in sorted { bytes += entry.0 }
    return KeyboardFrequencyList(data: Data(bytes))!
  }

  /// A word-pair file as `scripts/build-keyboard-context-lists.mjs` writes it; `.` is the sentence start.
  static func contextModelData(_ pairs: [(String, String, UInt8)], language: String = "de",
                               magic: String = "OWCX", version: UInt16 = 1, reserved: UInt16 = 0) -> Data {
    let words = Array(Set(pairs.flatMap { [$0.0, $0.1] })).map { Array($0.utf8) }
      .sorted { $0.lexicographicallyPrecedes($1) }
    func id(_ word: String) -> UInt32 { UInt32(words.firstIndex(of: Array(word.utf8))!) }
    let entries = pairs.map { (id($0.0) << 16 | id($0.1), $0.2) }.sorted { $0.0 < $1.0 }
    var bytes = Array(magic.utf8)
    func u16(_ value: UInt16) { bytes += [UInt8(value & 0xff), UInt8(value >> 8)] }
    func u32(_ value: UInt32) { bytes += (0..<4).map { UInt8((value >> (8 * $0)) & 0xff) } }
    u16(version); u16(1); bytes += Array(language.utf8); u16(reserved)
    u32(UInt32(words.count)); u32(UInt32(entries.count)); u32(0)
    var offset: UInt32 = 0
    for word in words { u32(offset); offset += UInt32(word.count) }
    u32(offset)
    for word in words { bytes += word }
    while bytes.count % 4 != 0 { bytes.append(0) }
    for entry in entries { u32(entry.0) }
    for entry in entries { bytes.append(entry.1) }
    return Data(bytes)
  }

  static func main() {
    UITextChecker.lexicons = [
      "en_US": StandInLexicon(language: "en_US", wordsByFrequency: english),
      "de_DE": StandInLexicon(language: "de_DE", wordsByFrequency: german),
    ]
    let both = TextCheckerCorrectionProvider(languages: [.german, .english])
    func fix(_ word: String, _ before: String, _ provider: TextCheckerCorrectionProvider = both,
             dictionary: KeyboardUserDictionary = .empty) -> String? {
      provider.replacement(for: word, before: before, dictionary: dictionary)
    }

    // English contractions: only when the words before are English.
    check("im in an English sentence", fix("im", "I think ") == "I\u{2019}m")
    check("i in an English sentence", fix("i", "you and ") == "I")
    check("dont in an English sentence", fix("dont", "I think you ") == "don\u{2019}t")
    check("Dont keeps its capital", fix("Dont", "So you have it. ") == "Don\u{2019}t")
    check("no words before: im stays", fix("im", "") == nil && fix("i", "") == nil)
    check("a German sentence keeps im", fix("im", "ich bin ") == nil && fix("i", "das ist ") == nil)
    check("words of both languages decide nothing", fix("im", "so ") == nil)
    check("a mixed sentence decides nothing", fix("im", "ich think ") == nil)
    check("English not selected: im stays",
          fix("im", "I think ", TextCheckerCorrectionProvider(languages: [.german])) == nil)
    let englishOnly = TextCheckerCorrectionProvider(languages: [.english])
    check("English alone: im after English words", fix("im", "I think ", englishOnly) == "I\u{2019}m")
    check("English alone: no words before, im stays", fix("im", "", englishOnly) == nil)
    // English alone is still told apart from German, which isn't selected: shared and German
    // words before don't make the sentence English.
    check("English alone: German words before, im stays", fix("im", "ich bin ", englishOnly) == nil)
    check("English alone: shared words before, im stays", fix("im", "so ", englishOnly) == nil
      && fix("i", "so ", englishOnly) == nil)
    check("English alone: a word only English knows decides", fix("im", "so you ", englishOnly) == "I\u{2019}m")
    check("words that are words stay (its, cant)", fix("its", "I think ") == nil && fix("cant", "I think ") == nil)

    // Without another installed dictionary nothing tells English apart: the list stays off.
    let lexicons = UITextChecker.lexicons
    UITextChecker.lexicons = ["en_US": lexicons["en_US"]!]
    check("no other dictionary installed: im stays",
          fix("im", "I think ", TextCheckerCorrectionProvider(languages: [.english])) == nil
            && fix("im", "I think ", TextCheckerCorrectionProvider(languages: [.german, .english])) == nil)
    UITextChecker.lexicons = lexicons

    // Out of time while reading the sentence, nothing more is looked up: each lookup takes 60 ms,
    // so the second ends the press's 100 ms.
    UITextChecker.lookupDelay = 0.06
    for typed in ["i", "im", "dont"] {
      let slow = TextCheckerCorrectionProvider(languages: [.german, .english])
      UITextChecker.lookups = 0
      let result = fix(typed, "This is ", slow)
      check("out of time, \(typed) stays and stops looking up", result == nil && UITextChecker.lookups <= 2)
    }
    UITextChecker.lookupDelay = 0

    // The app's dictionary first.
    check("a dictionary word is no contraction", fix("im", "I think ", dictionary: words(["IM"])) == "IM"
      && fix("im", "I think ", dictionary: words(["im"])) == nil)
    check("an unrelated dictionary leaves the contraction",
          fix("im", "I think ", dictionary: words(["Hrudek"])) == "I\u{2019}m")
    check("the dictionary's spelling of i", fix("i", "ich bin ", dictionary: words(["I"])) == "I")

    // Ordinary correction is unchanged where no contraction applies.
    check("ordinary correction still runs", fix("nciht", "ich bin ") == "nicht"
      && fix("teh", "I think ") == "the")

    // Frequency lists change the scoring: `vat` is a slip from `bat` and `cat` alike. UITextChecker
    // ranks `bat` 4th of its `ba` words and `cat` 1st of `ca`; the list says the opposite.
    check("without a list the completions rank", fix("vat", "I think ", englishOnly) == "cat")
    let ranked = TextCheckerCorrectionProvider(
      languages: [.english], frequencyLists: ["en": list("en", [("bat", 0), ("cat", 40)])])
    check("a list ranks for scoring", fix("vat", "I think ", ranked) == "bat")
    check("a word missing from the list keeps its completion rank", TextCheckerCorrectionProvider(
      languages: [.english], frequencyLists: ["en": list("en", [("bat", 0)])]).frequencyRank(of: "cat") == 0)
    check("the lowest rank across languages", TextCheckerCorrectionProvider(
      languages: [.german, .english],
      frequencyLists: ["en": list("en", [("so", 9)]), "de": list("de", [("so", 2)])]).frequencyRank(of: "so") == 2)
    check("no list, no change", both.frequencyRank(of: "bat") == 4)

    // ... but not the split rule: two words for one need both common among UITextChecker's
    // completions, whatever the list says.
    UITextChecker.lexicons["de_DE"] = StandInLexicon(language: "de_DE", wordsByFrequency: german + ["habe"])
    let germanOnly = TextCheckerCorrectionProvider(languages: [.german])
    check("a common split", fix("ichhabe", "", germanOnly) == "ich habe")
    // 120 words before `habe` among the `ha` completions.
    let manyHa = (0..<120).map { "ha" + String(UnicodeScalar(UInt8(97 + $0 % 26))) + String(repeating: "q", count: $0 / 26 + 1) }
    UITextChecker.lexicons["de_DE"] = StandInLexicon(language: "de_DE", wordsByFrequency: german + manyHa + ["habe"])
    let rareHabe = TextCheckerCorrectionProvider(languages: [.german])
    check("a rare second word is never split off", fix("ichhabe", "", rareHabe) == nil)
    let listed = TextCheckerCorrectionProvider(
      languages: [.german], frequencyLists: ["de": list("de", [("habe", 0), ("ich", 0)])])
    check("a list doesn't make a split common", fix("ichhabe", "", listed) == nil)

    // Word-pair context: it chooses between the candidates for a word being corrected.
    UITextChecker.lexicons = [
      "de_DE": StandInLexicon(language: "de_DE", wordsByFrequency:
        ["das", "ist", "ich", "hand", "habe", "wie", "woe", "wo", "nicht", "und", "Hrudek", "bin", "so"]),
      "en_US": StandInLexicon(language: "en_US", wordsByFrequency: ["the", "this", "is", "woe", "I", "you", "think", "so"]),
    ]
    let pairs = KeyboardContextModel(data: contextModelData(
      [("ich", "habe", 93), ("ist", "wie", 60), (".", "ich", 30), ("so", "habe", 93)]))!
    let germanOnlyPlain = TextCheckerCorrectionProvider(languages: [.german])
    let germanOnlyContext = TextCheckerCorrectionProvider(languages: [.german], contextModels: ["de": pairs])
    check("without context: ich hsbd → hand", fix("hsbd", "ich ", germanOnlyPlain) == "hand")
    check("with context: ich hsbd → habe", fix("hsbd", "ich ", germanOnlyContext) == "habe")
    check("with context, other words before: hsbd → hand", fix("hsbd", "das ", germanOnlyContext) == "hand")
    check("with context, no usable word before: hsbd → hand", fix("hsbd", "x.com ", germanOnlyContext) == "hand")
    check("weight 0 is no context", fix("hsbd", "ich ", TextCheckerCorrectionProvider(
      languages: [.german], contextModels: ["de": pairs], contextWeight: 0)) == "hand")
    check("with context: das ist wo + e slip → wie", fix("wue", "das ist ", germanOnlyContext) == "wie")
    // Context never changes a word the dictionaries know (`woe`), nor the app's dictionary.
    check("a real word stays whatever the context", fix("woe", "das ist ", germanOnlyContext) == nil)
    check("a dictionary word stays whatever the context",
          fix("hsbd", "ich ", germanOnlyContext, dictionary: words(["hsbd"])) == nil)
    check("a dictionary target wins over a context pick",
          fix("Hrudk", "ich ", germanOnlyContext, dictionary: words(["Hrudek"])) == "Hrudek")
    // Two languages: context only in the sentence's language, none when it is unknown.
    let bothContext = TextCheckerCorrectionProvider(languages: [.german, .english], contextModels: ["de": pairs])
    check("German sentence: German pairs apply", fix("hsbd", "das ist ich ", bothContext) == "habe")
    check("one language selected: its pairs apply after a shared word", fix("hsbd", "so ", germanOnlyContext) == "habe")
    check("unknown sentence language: no context", fix("hsbd", "so ", bothContext)
      == fix("hsbd", "so ", TextCheckerCorrectionProvider(languages: [.german, .english])))
    // A sentence start: its language is unknown with two selected (the sentence before may be
    // another), so no context; with one selected, that language's.
    let starts = KeyboardContextModel(data: contextModelData([(".", "habe", 200)]))!
    let twoWithStarts = TextCheckerCorrectionProvider(languages: [.german, .english], contextModels: ["de": starts])
    let twoPlain = TextCheckerCorrectionProvider(languages: [.german, .english])
    for before in ["ich habe nicht.\n", "ich habe nicht. ", ""] {
      check("two languages, sentence start after \(before.debugDescription): no context",
            fix("hsbd", before, twoWithStarts) == fix("hsbd", before, twoPlain))
    }
    check("one language, sentence start: its context", fix("hsbd", "", TextCheckerCorrectionProvider(
      languages: [.german], contextModels: ["de": starts])) == "habe")
    // One language selected: not after words only another installed language knows.
    let englishPairs = KeyboardContextModel(data: contextModelData([("ich", "bat", 200), ("this", "bat", 200),
                                                                    ("so", "bat", 200)]))!
    UITextChecker.lexicons["en_US"] = StandInLexicon(language: "en_US", wordsByFrequency:
      ["the", "this", "is", "cat", "bad", "bag", "ban", "bar", "bat", "so", "I", "think"])
    let englishContext = TextCheckerCorrectionProvider(languages: [.english], contextModels: ["en": englishPairs])
    let englishPlain = TextCheckerCorrectionProvider(languages: [.english])
    check("one language: a German word before is no context",
          fix("vat", "ich ", englishContext) == fix("vat", "ich ", englishPlain))
    check("one language: a mixed sentence is no context",
          fix("vat", "this ich ", englishContext) == fix("vat", "this ich ", englishPlain))
    check("one language: its own words before give context", fix("vat", "I think this ", englishContext) == "bat"
      && fix("vat", "I think this ", englishPlain) != "bat")
    check("one language: a shared word before gives context", fix("vat", "so ", englishContext) == "bat")
    // On the device German knows many English words (`think`, `still`, `warm`): they say
    // nothing, and `I` says English.
    UITextChecker.lexicons = [
      "de_DE": StandInLexicon(language: "de_DE", wordsByFrequency:
        ["ich", "bin", "so", "im", "das", "die", "Gefühl", "still", "warm", "modern", "Wald", "Phase", "think", "you"]),
      "en_US": StandInLexicon(language: "en_US", wordsByFrequency:
        ["the", "think", "you", "so", "I", "die", "is", "still", "warm", "modern", "phase"]),
    ]
    for languages in [[KeyboardCorrectionLanguage.german, .english], [.english]] {
      let deviceLike = TextCheckerCorrectionProvider(languages: languages)
      let name = languages.count == 2 ? "both" : "English alone"
      check("device-like (\(name)): I think im → I’m", fix("im", "I think ", deviceLike) == "I\u{2019}m")
      check("device-like (\(name)): I think you dont → don’t", fix("dont", "I think you ", deviceLike) == "don\u{2019}t")
      for before in ["ich bin ", "so ", "das Gefühl ", "still ", "warm ", "modern ", "Phase I ", "x-I-x ",
                     "https://I.zzzzzz ", "ich think ", "I think ich "] {
        check("device-like (\(name)): im stays after \(before.debugDescription)", fix("im", before, deviceLike) == nil)
      }
    }
    if failed > 0 {
      print("Keyboard autocorrection provider: \(failed) of \(count) checks failed")
      exit(1)
    }
    print("Keyboard autocorrection provider: \(count) checks passed")
  }
}
