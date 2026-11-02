import Foundation

private struct StubProvider: KeyboardCorrectionProvider {
  var words = ["nicht"]
  func suggestions(for word: String) -> [String] { words }
}

/// Records the text before the word it is asked about.
private final class ContextRecorder: KeyboardCorrectionProvider {
  var before: String?
  func suggestions(for word: String) -> [String] { [] }
  func suggestions(for word: String, before: String) -> [String] {
    self.before = before
    return ["nicht"]
  }
}

/// A provider for a chosen selection, as the controller builds from the app's setting.
private struct SelectionProvider: KeyboardCorrectionProvider {
  var words: [String]
  var letters: Set<Character>
  func suggestions(for word: String) -> [String] { words }
}

@main
private enum KeyboardAutocorrectionTests {
  static var count = 0
  static var failed = 0
  static func check(_ label: String, _ value: Bool) {
    count += 1
    if !value { print("FAIL: \(label)"); failed += 1 }
  }

  static func context(_ before: String? = "", after: String? = "", selection: String? = nil,
                      allowed: Bool = true, document: UUID) -> KeyboardCorrectionContext {
    KeyboardCorrectionContext(document: document, before: before, after: after,
                              selection: selection, allowed: allowed)
  }

  static func typed(_ word: String, prefix: String = "", after: String = "",
                    document: UUID) -> (KeyboardAutocorrection, KeyboardCorrectionContext) {
    var state = KeyboardAutocorrection()
    var current = context(prefix, after: after, document: document)
    for letter in word {
      state.manualInsertion(String(letter), in: current)
      current = current.inserting(String(letter))
      state.reconcile(current)
    }
    return (state, current)
  }

  static func userDictionary(_ personal: [String], shared: [String] = []) -> KeyboardUserDictionary {
    let data = try! JSONSerialization.data(withJSONObject: ["v": 1, "personal": personal, "shared": shared] as [String: Any])
    return KeyboardUserDictionary(json: String(decoding: data, as: UTF8.self))
  }

  /// The app's dictionary (`KeyboardUserDictionary`): parsing, protection, the user's words as
  /// targets, and how they reach the state machine's edit.
  static func userDictionaryChecks(document: UUID) {
    check("no value is an empty dictionary", KeyboardUserDictionary(json: nil).isEmpty
      && KeyboardUserDictionary(json: "").isEmpty)
    check("malformed values are empty", KeyboardUserDictionary(json: "Hrudek").isEmpty
      && KeyboardUserDictionary(json: "[\"Hrudek\"]").isEmpty
      && KeyboardUserDictionary(json: "{\"v\":2,\"personal\":[\"Hrudek\"]}").isEmpty
      && KeyboardUserDictionary(json: "{\"personal\":[\"Hrudek\"]}").isEmpty)
    check("an oversized value is empty", KeyboardUserDictionary(
      json: "{\"v\":1,\"personal\":[\"" + String(repeating: "a", count: KeyboardUserDictionary.maxBytes)
        + "\"]}").isEmpty)

    let words = userDictionary(["Hrudek", "OpenWhispr", "kubectl", "New York", "Tim", "NASA", "iPhone", "KI",
                                "GPT-6", "me@example.com", "Lennart"],
                               shared: ["Kubernetes", "os", "HRUDEK"])
    check("protects in any case", words.protects("Hrudek") && words.protects("hrudek")
      && words.protects("openwhispr") && words.protects("Kubectl"))
    check("protects the words of a phrase", words.protects("york") && words.protects("New"))
    check("protects shared and short words", words.protects("kubernetes") && words.protects("os")
      && words.protects("tim"))
    check("technical strings protect nothing", !words.protects("gpt") && !words.protects("example")
      && !words.protects("me"))
    check("other words aren't protected", !words.protects("nicht"))
    let decomposed = userDictionary(["Sine\u{301}ad"])
    check("a decomposed entry protects the composed word", decomposed.protects("Sin\u{e9}ad")
      && decomposed.protects("sine\u{301}ad"))
    check("letters whose case expands are no word", !KeyboardUserDictionary.isLetterWord("İstanbul")
      && !KeyboardUserDictionary.isLetterWord("ßtraße") && KeyboardUserDictionary.isLetterWord("Straße")
      && KeyboardUserDictionary.isLetterWord("Sin\u{e9}ad") && !KeyboardUserDictionary.isLetterWord("Sine\u{301}ad"))
    // Distinct letter-only words: the index in base 26, a to z.
    let many = (0..<(KeyboardUserDictionary.maxEntries + 1)).map { index -> String in
      var rest = index
      var word = "w"
      repeat {
        word.append(Character(UnicodeScalar(UInt8(97 + rest % 26))))
        rest /= 26
      } while rest > 0
      return word
    }
    let capped = userDictionary(many)
    check("entries are capped", capped.protects(many[KeyboardUserDictionary.maxEntries - 1])
      && !capped.protects(many[KeyboardUserDictionary.maxEntries]))
    check("an overlong entry is skipped, the rest kept", {
      let dictionary = userDictionary([String(repeating: "a", count: KeyboardUserDictionary.maxEntryLength + 1), "Hrudek"])
      return dictionary.protects("Hrudek") && !dictionary.protects(String(repeating: "a", count: 65))
    }())

    // 1. The entry's spelling for a word typed like it but for its case.
    check("lowercase becomes the stored spelling", words.caseFix(for: "iphone") == "iPhone"
      && words.caseFix(for: "openwhispr") == "OpenWhispr" && words.caseFix(for: "hrudek") == "Hrudek")
    check("a sentence-start capital becomes the stored spelling", words.caseFix(for: "Iphone") == "iPhone")
    check("short and all-caps entries fix case too", words.caseFix(for: "ki") == "KI"
      && words.caseFix(for: "Ki") == "KI" && words.caseFix(for: "nasa") == "NASA")
    check("the personal spelling wins over a shared one", words.caseFix(for: "hrudek") == "Hrudek")
    check("a word already spelled so needs no fix", words.caseFix(for: "Hrudek") == nil
      && words.caseFix(for: "KI") == nil)
    check("an all-lowercase entry keeps what was typed", words.caseFix(for: "Kubectl") == nil
      && words.caseFix(for: "kubectl") == nil)
    check("phrase words get no case fix", words.caseFix(for: "york") == nil)
    check("accented and long entries fix case",
          userDictionary(["Sin\u{e9}ad"]).caseFix(for: "sin\u{e9}ad") == "Sin\u{e9}ad"
            && userDictionary(["Donaudampfschifffahrtsgesellschaft"])
              .caseFix(for: "donaudampfschifffahrtsgesellschaft") == "Donaudampfschifffahrtsgesellschaft")

    // 3. A typo becomes an entry.
    check("a swap becomes the user's word", words.target(for: "Hrudke")?.word == "Hrudek")
    check("the stored spelling is kept", words.target(for: "openwhsipr")?.word == "OpenWhispr"
      && words.target(for: "Openwhsipr")?.word == "OpenWhispr" && words.target(for: "iphnoe")?.word == "iPhone")
    check("title case capitalises a lowercase word", words.target(for: "Kubectk")?.word == "Kubectl"
      && words.target(for: "kubectk")?.word == "kubectl")
    check("a missing letter becomes the user's word", words.target(for: "Lenart")?.word == "Lennart")
    check("three-letter words count", words.target(for: "Tmi")?.word == "Tim"
      && userDictionary(["Hruk"]).target(for: "Hru")?.word == "Hruk")
    let pi = userDictionary(["Pi", "Hruk"])
    check("a two-letter word gets the entry's case", pi.caseFix(for: "pi") == "Pi" && pi.caseFix(for: "Pi") == nil
      && pi.protects("pi"))
    check("a two-letter slip or swap becomes a two-letter entry", pi.target(for: "Po")?.word == "Pi"
      && pi.target(for: "pu")?.word == "Pi" && userDictionary(["Qt"]).target(for: "tq")?.word == "Qt"
      && pi.target(for: "Pk")?.word == "Pi")
    check("common two-letter words never become an entry", pi.target(for: "ip") == nil
      && userDictionary(["Om"]).target(for: "am") == nil && userDictionary(["Ka"]).target(for: "km") == nil)
    check("two letters far apart are no target", pi.target(for: "Pa") == nil && pi.target(for: "xi") == nil)
    check("two letters never reach longer entries", pi.target(for: "Hr") == nil
      && userDictionary(["Tim", "Hruk"]).target(for: "Ik") == nil)
    check("a swapped acronym becomes the entry", userDictionary(["KI"]).target(for: "Ik")?.word == "KI")
    check("three letters never become a two-letter entry", pi.target(for: "Pix") == nil)
    check("all-caps and shared entries are targets", words.target(for: "Nass")?.word == "NASA"
      && words.target(for: "Kubernetse")?.word == "Kubernetes")
    check("phrase words are no target", words.target(for: "Yrok") == nil)
    check("far-away words are no target", words.target(for: "Hruxyz") == nil
      && words.target(for: "Hdurke") == nil && words.target(for: "Tmo") == nil)
    check("five letters on allow more", userDictionary(["Sin\u{e9}ad"]).target(for: "Sinead")?.word == "Sin\u{e9}ad"
      && userDictionary(["Hruk"]).target(for: "Hxuk") == nil)
    check("long words are targets", userDictionary(["Donaudampfschifffahrtsgesellschaft"])
      .target(for: "donaudampfschiffahrtsgesellschaft")?.word == "Donaudampfschifffahrtsgesellschaft")
    check("two equally close words of a list are no target",
          userDictionary(["Lennart", "Leonart"]).target(for: "Lenart") == nil
            && userDictionary([], shared: ["Lennart", "Leonart"]).target(for: "Lenart") == nil)
    check("a personal word wins over an equally close shared one",
          userDictionary(["Lennart"], shared: ["Leonart"]).target(for: "Lenart")?.word == "Lennart"
            && userDictionary(["Leonart"], shared: ["Lennart"]).target(for: "Lenart")?.word == "Leonart")
    check("a closer shared word wins over a personal one",
          userDictionary(["kubectls"], shared: ["kubectl"]).target(for: "kubectk")?.word == "kubectl")
    check("a scan out of time finds nothing", words.target(for: "Hrudke", shouldStop: { true }) == nil)
    var lookups = 0
    check("a scan cut short after a first match finds nothing", userDictionary(["Hrudek", "Hrudel"])
      .target(for: "Hrudke", shouldStop: { lookups += 1; return lookups > 1 }) == nil)
    check("a tie in one list loses to a closer word in the other",
          userDictionary(["Lenat", "Lenrt"]).target(for: "Lenart") == nil
            && userDictionary(["Lenat", "Lenrt"], shared: ["Lenarr"]).target(for: "Lenart")?.word == "Lenarr")
    let cyrillic = userDictionary(["Москва"])
    check("Cyrillic entries fix case and take typos", cyrillic.caseFix(for: "москва") == "Москва"
      && cyrillic.target(for: "Моксва")?.word == "Москва")
    let longest = String(repeating: "ab", count: KeyboardUserDictionary.maxEntryLength / 2)
    check("inputs up to the entry bound", KeyboardUserDictionary.isInput(longest)
      && !KeyboardUserDictionary.isInput(longest + "a") && !KeyboardUserDictionary.isInput("i"))

    let letters = KeyboardCorrectionRules.defaultLetters
    check("the user's word wins over the ordinary pick", words.decide(
      for: "Hrudke", letters: letters, misspelled: { true }, shouldStop: { false },
      ordinary: { "Hrude" }) == "Hrudek")
    check("the user's word wins over a German respelling", userDictionary(["Strasso"]).decide(
      for: "strasse", letters: letters, misspelled: { true }, shouldStop: { false },
      ordinary: { "Straße" }) == "Strasso")
    check("a known word never becomes the user's word", words.decide(
      for: "Tom", letters: letters, misspelled: { false }, shouldStop: { false }, ordinary: { nil }) == nil)
    check("a known word still gets the stored case", words.decide(
      for: "iphone", letters: letters, misspelled: { false }, shouldStop: { false }, ordinary: { nil }) == "iPhone")
    check("out of time, no user's word", words.decide(
      for: "Hrudke", letters: letters, misspelled: { true }, shouldStop: { true }, ordinary: { nil }) == nil)
    check("a known word isn't scanned", words.decide(
      for: "Hrudke", letters: letters, misspelled: { false }, shouldStop: { false },
      ordinary: { "Hrude" }) == "Hrude")
    check("a split loses to the user's word", userDictionary(["ichhabee"]).decide(
      for: "ichhabe", letters: letters, misspelled: { true }, shouldStop: { false },
      ordinary: { "ich habe" }) == "ichhabee")
    check("no target: the ordinary pick", words.decide(
      for: "nciht", letters: letters, misspelled: { true }, shouldStop: { false }, ordinary: { "nicht" }) == "nicht")

    // Through the state machine, as the keyboard applies it.
    var protected = typed("nciht", document: document)
    check("a protected word is never corrected", protected.0.correction(
      in: protected.1, provider: StubProvider(), dictionary: userDictionary(["nciht"])) == nil)
    var protectedSwap = typed("os", document: document)
    check("a protected two-letter word isn't swapped", protectedSwap.0.correction(
      in: protectedSwap.1, provider: StubProvider(words: ["so"]), dictionary: words) == nil)
    var caseOnly = typed("iphone", document: document)
    let caseEdit = caseOnly.0.correction(in: caseOnly.1, provider: StubProvider(words: []), dictionary: words)
    check("a word typed in lowercase gets the stored case", caseEdit?.replacement == "iPhone"
      && caseEdit?.original == "iphone")
    var acronym = typed("ki", document: document)
    check("a two-letter word gets the stored case", acronym.0.correction(
      in: acronym.1, provider: StubProvider(words: ["ik"]), dictionary: words)?.replacement == "KI")
    var piCase = typed("pi", document: document)
    check("pi gets the stored case", piCase.0.correction(
      in: piCase.1, provider: StubProvider(words: ["ip"]), dictionary: pi)?.replacement == "Pi")
    var piSlip = typed("po", document: document)
    check("a two-letter slip becomes the user's word", piSlip.0.correction(
      in: piSlip.1, provider: StubProvider(words: ["so"]), dictionary: pi)?.replacement == "Pi")
    var long = typed("donaudampfschifffahrtsgesellschaft", document: document)
    check("a word past twenty letters gets the stored case", long.0.correction(
      in: long.1, provider: StubProvider(words: []),
      dictionary: userDictionary(["Donaudampfschifffahrtsgesellschaft"]))?.replacement
      == "Donaudampfschifffahrtsgesellschaft")
    var longPlain = typed("donaudampfschifffahrtsgesellschaft", document: document)
    check("past twenty letters nothing else is corrected", longPlain.0.correction(
      in: longPlain.1, provider: StubProvider(words: ["x"]), dictionary: words) == nil)
    var russian = typed("москва", document: document)
    check("Cyrillic reaches the dictionary", russian.0.correction(
      in: russian.1, provider: StubProvider(words: []), dictionary: cyrillic)?.replacement == "Москва")
    var accented = typed("sin\u{e9}ad", document: document)
    check("letters of other languages reach the dictionary", accented.0.correction(
      in: accented.1, provider: StubProvider(words: []), dictionary: userDictionary(["Sin\u{e9}ad"]))?.replacement
      == "Sin\u{e9}ad")
    var brand = typed("openwhsipr", document: document)
    check("a typo becomes a mixed-case user's word", brand.0.correction(
      in: brand.1, provider: StubProvider(words: []), dictionary: words)?.replacement == "OpenWhispr")
    var name = typed("Hrudke", document: document)
    check("the user's word wins over the provider's", name.0.correction(
      in: name.1, provider: StubProvider(words: ["Hrude"]), dictionary: words)?.replacement == "Hrudek")
    var short = typed("Hru", document: document)
    check("a three-letter typo becomes the user's word", short.0.correction(
      in: short.1, provider: StubProvider(words: []), dictionary: userDictionary(["Hruk"]))?.replacement == "Hruk")
    var ordinary = typed("nciht", document: document)
    check("other words correct as before", ordinary.0.correction(
      in: ordinary.1, provider: StubProvider(), dictionary: words)?.replacement == "nicht")
    var noDictionary = typed("donaudampfschifffahrtsgesellschaft", document: document)
    check("without a dictionary long words stay out", noDictionary.0.correction(
      in: noDictionary.1, provider: StubProvider(words: ["x"])) == nil)
  }

  /// A frequency list file as `scripts/build-keyboard-frequency-lists.mjs` writes it.
  static func frequencyListData(_ entries: [(String, UInt16)], magic: String = "OWFR", version: UInt16 = 1,
                                kind: UInt16 = 1, language: [UInt8] = Array("de".utf8),
                                reserved: UInt16 = 0) -> Data {
    let sorted = entries.map { (Array($0.0.utf8), $0.1) }.sorted { $0.0.lexicographicallyPrecedes($1.0) }
    var bytes = Array(magic.utf8)
    func u16(_ value: UInt16) { bytes += [UInt8(value & 0xff), UInt8(value >> 8)] }
    func u32(_ value: UInt32) { bytes += (0..<4).map { UInt8((value >> (8 * $0)) & 0xff) } }
    u16(version); u16(kind); bytes += language; u16(reserved); u32(UInt32(sorted.count))
    var offset: UInt32 = 0
    for entry in sorted { u32(offset); offset += UInt32(entry.0.count) }
    u32(offset)
    for entry in sorted { u16(entry.1) }
    for entry in sorted { bytes += entry.0 }
    return Data(bytes)
  }

  /// The frequency lists (`KeyboardFrequencyList`), the split rule's own ranks, and the English
  /// contractions with their gates.
  static func frequencyAndContractionChecks(document: UUID) {
    let data = frequencyListData([("nicht", 0), ("nichts", 3), ("haus", 7), ("größe", 2), ("über", 1)])
    let list = KeyboardFrequencyList(data: data)
    check("a frequency list opens", list?.count == 5 && list?.language == "de")
    check("frequency list ranks", list?.rank(of: "nicht") == 0 && list?.rank(of: "nichts") == 3
      && list?.rank(of: "über") == 1)
    check("frequency list lookups ignore case and composition", list?.rank(of: "Haus") == 7
      && list?.rank(of: "GRÖSSE") == nil && list?.rank(of: "gro\u{308}ße") == 2 && list?.rank(of: "Über") == 1)
    check("frequency list misses", list?.rank(of: "nich") == nil && list?.rank(of: "nichtss") == nil
      && list?.rank(of: "") == nil && list?.rank(of: "a") == nil && list?.rank(of: "zzz") == nil)
    check("an empty frequency list ranks nothing", KeyboardFrequencyList(data: frequencyListData([]))?.rank(of: "a") == nil)
    check("a malformed frequency list is no list",
          KeyboardFrequencyList(data: frequencyListData([("a", 0)], magic: "OWFX")) == nil
            && KeyboardFrequencyList(data: frequencyListData([("a", 0)], version: 2)) == nil
            && KeyboardFrequencyList(data: frequencyListData([("a", 0)], kind: 2)) == nil
            && KeyboardFrequencyList(data: frequencyListData([("a", 0)], language: [0, 0])) == nil
            && KeyboardFrequencyList(data: frequencyListData([("a", 0)], language: Array("DE".utf8))) == nil
            && KeyboardFrequencyList(data: frequencyListData([("a", 0)], reserved: 1)) == nil
            && KeyboardFrequencyList(data: data.dropLast()) == nil
            && KeyboardFrequencyList(data: data + Data([0])) == nil
            && KeyboardFrequencyList(data: Data()) == nil
            && KeyboardFrequencyList(data: Data("OWFR".utf8)) == nil)
    var shuffled = [UInt8](data)
    // A first offset past the words' start, read at lookup, is refused there.
    shuffled[16 + 4 * 2] = 0xff
    check("out-of-bounds offsets don't read outside the file",
          KeyboardFrequencyList(data: Data(shuffled))?.rank(of: "nicht") == nil)
    check("a missing file is no list", KeyboardFrequencyList(
      contentsOf: URL(fileURLWithPath: "/nonexistent/KeyboardFrequency-de.bin")) == nil)

    // Scoring ranks and the split rule's ranks are separate: a split both of whose words are
    // common by `splitRank` is scored with `rank`, and one that isn't stays out whatever `rank` says.
    let splitRanks: [String: Int] = ["ich": 1, "habe": 4]
    check("the split rule uses its own ranks", KeyboardCorrectionRules.replacement(
      for: "ichhabe", suggestions: ["ich habe"], rank: { _ in 0 }, splitRank: { _ in 500 }) == nil)
    check("a split common by its own ranks is kept", KeyboardCorrectionRules.replacement(
      for: "ichhabe", suggestions: ["ich habe"], rank: { _ in nil }, splitRank: { splitRanks[$0] }) == "ich habe")
    // Scored with `rank`: `ich habe` (rank 0, cost 1) beats `ichhabe`'s slip `ichgabe` (cost 1,
    // unranked); with the split's own rank 600 it would have lost to a rank-0 slip.
    check("a split is scored with the scoring ranks", KeyboardCorrectionRules.replacement(
      for: "ichhabe", suggestions: ["ichgabe", "ich habe"], rank: { $0 == "ichgabe" ? 2 : 0 },
      splitRank: { _ in 60 }) == "ich habe")
    check("without splitRank the scoring ranks decide splits", KeyboardCorrectionRules.replacement(
      for: "ichhabe", suggestions: ["ich habe"], rank: { _ in 500 }) == nil)

    // English contractions: the table only, with case kept; real words stay out.
    let contractions = ["i": "I", "im": "I\u{2019}m", "Im": "I\u{2019}m", "dont": "don\u{2019}t",
                        "Dont": "Don\u{2019}t", "ive": "I\u{2019}ve", "youre": "you\u{2019}re",
                        "thats": "that\u{2019}s", "shouldnt": "shouldn\u{2019}t"]
    for (typed, expected) in contractions {
      check("contraction \(typed)", KeyboardCorrectionRules.englishContraction(of: typed) == expected)
    }
    for typed in ["I", "IM", "DONT", "dOnt", "id", "ill", "cant", "wont", "lets", "its", "were", "well",
                  "hell", "shell", "don", "a", "", "i\u{2019}m", "nicht"] {
      check("no contraction for \(typed)", KeyboardCorrectionRules.englishContraction(of: typed) == nil)
    }
    check("contractions are typed with the typographic apostrophe",
          KeyboardCorrectionRules.englishContractions.values.allSatisfy { !$0.contains("'") })

    // The state machine tracks `i` and `im` for the provider, and types the apostrophe the field
    // uses; undo restores the word as typed.
    struct ContractionProvider: KeyboardCorrectionProvider {
      func suggestions(for word: String) -> [String] { [] }
      func replacement(for word: String, before: String, dictionary: KeyboardUserDictionary) -> String? {
        dictionary.decide(for: word, letters: letters, misspelled: { true }, shouldStop: { false },
                          ordinary: { KeyboardCorrectionRules.englishContraction(of: word) })
      }
    }
    var single = typed("i", prefix: "so ", document: document)
    check("a one-letter contraction is offered to the provider", single.0.correction(
      in: single.1, provider: ContractionProvider())?.replacement == "I")
    var other = typed("a", prefix: "so ", document: document)
    check("other one-letter words are not", other.0.correction(
      in: other.1, provider: ContractionProvider()) == nil)
    var curly = typed("im", prefix: "so ", document: document)
    let curlyEdit = curly.0.correction(in: curly.1, provider: ContractionProvider())
    check("contraction with the typographic apostrophe", curlyEdit?.replacement == "I\u{2019}m")
    var straight = typed("dont", prefix: "so ", document: document)
    let straightEdit = straight.0.correction(in: straight.1, provider: ContractionProvider(),
                                             delimiter: ",", straightApostrophe: true)
    check("contraction with a straight apostrophe", straightEdit?.replacement == "don't"
      && straightEdit?.delimiter == ",")
    if let straightEdit {
      straight.0.didCorrect(straightEdit, at: 100)
      let after = context("so don't,", document: document)
      check("undo of a contraction restores the typed word",
            straight.0.takeUndo(in: after, at: 101)?.original == "dont")
    }
    var plain = typed("nciht", prefix: "so ", document: document)
    check("a straight apostrophe changes nothing else", plain.0.correction(
      in: plain.1, provider: StubProvider(), straightApostrophe: true)?.replacement == "nicht")

    // The app's dictionary goes first: its spelling, then its protection, then the contraction.
    let words = userDictionary(["im", "Hrudek"])
    check("a dictionary word is no contraction", words.decide(
      for: "im", letters: KeyboardCorrectionRules.defaultLetters, misspelled: { true }, shouldStop: { false },
      ordinary: { KeyboardCorrectionRules.englishContraction(of: "im") }) == nil)
    check("the dictionary's spelling of a one-letter word wins", userDictionary(["I"]).decide(
      for: "i", letters: KeyboardCorrectionRules.defaultLetters, misspelled: { true }, shouldStop: { false },
      ordinary: { "x" }) == "I")
    check("a dictionary without the word leaves the contraction", words.decide(
      for: "dont", letters: KeyboardCorrectionRules.defaultLetters, misspelled: { true }, shouldStop: { false },
      ordinary: { KeyboardCorrectionRules.englishContraction(of: "dont") }) == "don\u{2019}t"
      && words.decide(for: "i", letters: KeyboardCorrectionRules.defaultLetters, misspelled: { true },
                      shouldStop: { false }, ordinary: { KeyboardCorrectionRules.englishContraction(of: "i") }) == "I")
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

  /// The word-pair file (`KeyboardContextModel`), what counts as the word before
  /// (`wordContext`), and the context's place in the score.
  static func contextChecks() {
    let data = contextModelData([("ich", "habe", 93), (".", "ich", 30), ("ist", "wie", 1), ("für", "größe", 200)])
    let model = KeyboardContextModel(data: data)
    check("a context model opens", model?.pairCount == 4 && model?.wordCount == 7 && model?.language == "de")
    check("a pair's bonus in bits", model?.bonus(for: "habe", after: .word("ich")) == 93.0 / 16
      && model?.bonus(for: "ich", after: .sentenceStart) == 30.0 / 16)
    check("bonus lookups ignore the candidate's case and composition",
          model?.bonus(for: "Habe", after: .word("ich")) == 93.0 / 16
            && model?.bonus(for: "gro\u{308}ße", after: .word("für")) == 200.0 / 16)
    check("a missing pair or word is no bonus", model?.bonus(for: "hand", after: .word("ich")) == 0
      && model?.bonus(for: "habe", after: .word("du")) == 0 && model?.bonus(for: "habe", after: .sentenceStart) == 0
      && model?.bonus(for: "", after: .word("ich")) == 0)
    check("an empty context model gives nothing",
          KeyboardContextModel(data: contextModelData([]))?.bonus(for: "a", after: .sentenceStart) == 0)
    check("a malformed context model is no model",
          KeyboardContextModel(data: contextModelData([("a", "b", 1)], magic: "OWCY")) == nil
            && KeyboardContextModel(data: contextModelData([("a", "b", 1)], version: 2)) == nil
            && KeyboardContextModel(data: contextModelData([("a", "b", 1)], language: "D\u{0}")) == nil
            && KeyboardContextModel(data: contextModelData([("a", "b", 1)], reserved: 1)) == nil
            && KeyboardContextModel(data: data.dropLast()) == nil
            && KeyboardContextModel(data: data + Data([0])) == nil
            && KeyboardContextModel(data: Data("OWCX".utf8)) == nil
            && KeyboardContextModel(data: Data()) == nil)
    var hostile = [UInt8](data)
    hostile[24 + 4 * 3] = 0xff
    check("hostile word offsets don't read outside the file",
          KeyboardContextModel(data: Data(hostile)).map { _ in true } != nil)
    _ = KeyboardContextModel(data: Data(hostile))?.bonus(for: "habe", after: .word("ich"))
    check("a missing context file is no model",
          KeyboardContextModel(contentsOf: URL(fileURLWithPath: "/nonexistent/KeyboardContext-de.bin")) == nil)

    // The word before: the previous word of letters, or a sentence start; nothing else.
    let contexts: [(String, KeyboardWordContext?)] = [
      ("", .sentenceStart), ("das ist ", .word("ist")), ("Das IST  ", .word("ist")), ("Hallo. ", .sentenceStart),
      ("Wow! ", .sentenceStart), ("Echt?! ", .sentenceStart), ("Zeile\n", .sentenceStart), ("foo\n ", .sentenceStart),
      ("für Ärger ", .word("ärger")), ("x.com ", nil), ("z.B. ", nil), ("a. ", nil), ("3 ", nil), ("Seite 3. ", nil),
      ("don't ", nil), ("foo123 ", nil), ("E-Mail ", nil), ("„Hallo“ ", nil), ("Hallo, ", nil), ("(so ", nil),
      ("gro\u{308}ße ", .word("größe")),
    ]
    for (before, expected) in contexts {
      check("word context of \(before.debugDescription)", KeyboardCorrectionRules.wordContext(before: before) == expected)
    }

    // The bonus chooses between candidates and nothing else.
    let ranks: [String: Int] = ["hand": 0, "habe": 1]
    check("without context the closer, commoner word wins", KeyboardCorrectionRules.replacement(
      for: "hsbd", suggestions: ["hand", "habe"], rank: { ranks[$0] }) == "hand")
    check("context can choose another candidate", KeyboardCorrectionRules.replacement(
      for: "hsbd", suggestions: ["hand", "habe"], rank: { ranks[$0] },
      contextBonus: { $0 == "habe" ? 0.9 : 0 }) == "habe")
    check("a zero bonus changes nothing", KeyboardCorrectionRules.replacement(
      for: "hsbd", suggestions: ["hand", "habe"], rank: { ranks[$0] }, contextBonus: { _ in 0 }) == "hand")
    check("a negative bonus counts as none", KeyboardCorrectionRules.replacement(
      for: "hsbd", suggestions: ["hand", "habe"], rank: { ranks[$0] },
      contextBonus: { $0 == "hand" ? -5 : 0 }) == "hand")
    check("context never makes a word a candidate", KeyboardCorrectionRules.replacement(
      for: "hsbd", suggestions: ["hand"], rank: { ranks[$0] }, contextBonus: { _ in 9 }) == "hand"
      && KeyboardCorrectionRules.replacement(for: "hsbd", suggestions: [], contextBonus: { _ in 9 }) == nil
      && KeyboardCorrectionRules.replacement(for: "hsbd", suggestions: ["zebra"], contextBonus: { _ in 9 }) == nil)
    check("context doesn't outweigh an umlaut respelling", KeyboardCorrectionRules.replacement(
      for: "schoen", suggestions: ["schön", "schoen"], contextBonus: { $0 == "schoen" ? 50 : 0 }) == "schön")
    check("a split takes its first word's bonus", KeyboardCorrectionRules.replacement(
      for: "ichhabe", suggestions: ["ichgabe", "ich habe"], rank: { $0 == "ichgabe" ? 0 : 60 },
      contextBonus: { $0 == "ich" ? 2 : 0 }) == "ich habe"
      && KeyboardCorrectionRules.replacement(
        for: "ichhabe", suggestions: ["ichgabe", "ich habe"], rank: { $0 == "ichgabe" ? 0 : 60 },
        contextBonus: { $0 == "ich habe" || $0 == "habe" ? 2 : 0 }) == "ichgabe")
    // Foreign words: shared and unknown ones are no evidence; out of time it abstains, and no
    // lookup starts after the deadline, the lowercase one included.
    let lexicon: [String: Set<String>] = ["de": ["ich", "so"], "en": ["this", "so"]]
    func foreign(_ before: String, _ language: String) -> Bool {
      KeyboardCorrectionRules.hasForeignWords(before: before, language: language, codes: ["de", "en"],
                                              knows: { lexicon[$1]?.contains($0) == true })
    }
    check("foreign words", foreign("ich ", "en") && foreign("this ich ", "en") && !foreign("ich ", "de")
      && !foreign("so ", "en") && !foreign("zzzz ", "en") && !foreign("", "en") && foreign("Ich ", "en"))
    for stopAfter in 0...3 {
      var calls = 0
      let result = KeyboardCorrectionRules.hasForeignWords(
        before: "Zzzz ", language: "en", codes: ["de", "en"], shouldStop: { calls >= stopAfter },
        knows: { _, _ in calls += 1; return false })
      check("foreign-word scan stops at the deadline (\(stopAfter))", calls == min(stopAfter, 4)
        && result == (stopAfter < 4))
    }
    check("two-letter words ignore context", KeyboardCorrectionRules.replacement(
      for: "mi", suggestions: ["im"], contextBonus: { _ in 9 }) == "im")
  }

  static func main() {
    let provider = StubProvider()
    let document = UUID()
    check("unique inner swap", KeyboardCorrectionRules.replacement(
      for: "nciht", suggestions: ["nicht", "nichts"]) == "nicht")
    check("duplicates do not introduce ambiguity", KeyboardCorrectionRules.replacement(
      for: "nciht", suggestions: ["nicht", "nicht"]) == "nicht")
    check("the closest proposal wins over a farther noun", KeyboardCorrectionRules.replacement(
      for: "nciht", suggestions: ["Nacht", "nicht"]) == "nicht")
    check("tied swaps go to the first (most common) proposal", KeyboardCorrectionRules.replacement(
      for: "abcde", suggestions: ["acbde", "abdce"]) == "acbde")
    check("umlaut swap", KeyboardCorrectionRules.replacement(
      for: "Mädcehn", suggestions: ["Mädchen"]) == "Mädchen")
    check("eszett swap", KeyboardCorrectionRules.replacement(
      for: "grßoer", suggestions: ["großer"]) == "großer")
    check("no case changes", KeyboardCorrectionRules.replacement(
      for: "Nciht", suggestions: ["nicht"]) == nil)
    check("short end swap", KeyboardCorrectionRules.replacement(
      for: "udn", suggestions: ["und"]) == "und")
    check("first letter swap", KeyboardCorrectionRules.replacement(
      for: "incht", suggestions: ["nicht"]) == "nicht")
    check("last letter swap", KeyboardCorrectionRules.replacement(
      for: "nicth", suggestions: ["nicht"]) == "nicht")
    check("one wrong letter", KeyboardCorrectionRules.replacement(
      for: "nucht", suggestions: ["nicht"]) == "nicht")
    check("one missing letter", KeyboardCorrectionRules.replacement(
      for: "nich", suggestions: ["nicht"]) == "nicht")
    check("one extra letter", KeyboardCorrectionRules.replacement(
      for: "Halllo", suggestions: ["Hallo"]) == "Hallo")
    check("umlaut substitution", KeyboardCorrectionRules.replacement(
      for: "Mödchen", suggestions: ["Mädchen"]) == "Mädchen")
    check("without frequency a slip beats a missing letter", KeyboardCorrectionRules.replacement(
      for: "nich", suggestions: ["nicht", "noch"]) == "noch")
    check("a far commoner word beats the slip", KeyboardCorrectionRules.replacement(
      for: "nich", suggestions: ["noch", "nicht"], rank: { $0 == "nicht" ? 0 : 30 }) == "nicht")
    check("proposal order breaks the tie", KeyboardCorrectionRules.replacement(
      for: "nich", suggestions: ["noch", "nicht"]) == "noch")
    check("swap plus missing letter", KeyboardCorrectionRules.replacement(
      for: "ncih", suggestions: ["nicht"]) == "nicht")
    check("too many edits for a short word", KeyboardCorrectionRules.replacement(
      for: "ncxh", suggestions: ["nicht"]) == nil)
    check("short substitution excluded", KeyboardCorrectionRules.replacement(
      for: "unt", suggestions: ["und"]) == nil)
    check("unchanged word excluded", KeyboardCorrectionRules.replacement(
      for: "nicht", suggestions: ["nicht"]) == nil)
    // English goes through the same rules as German.
    check("english short swap", KeyboardCorrectionRules.replacement(
      for: "teh", suggestions: ["the", "ten", "tech"]) == "the")
    check("english inner swap", KeyboardCorrectionRules.replacement(
      for: "recieve", suggestions: ["receive", "recite"]) == "receive")
    check("english missing letter", KeyboardCorrectionRules.replacement(
      for: "becuse", suggestions: ["because"]) == "because")
    check("english title case kept", KeyboardCorrectionRules.replacement(
      for: "Thsi", suggestions: ["This", "this"]) == "This")
    check("german and english proposals together stay unique", KeyboardCorrectionRules.replacement(
      for: "nciht", suggestions: ["nicht", "night", "niche"]) == "nicht")
    check("a swap beats a far-away letter across languages", KeyboardCorrectionRules.replacement(
      for: "Bnad", suggestions: ["Brad", "Band"]) == "Band")
    check("english contraction excluded", !KeyboardCorrectionRules.isWord("don't"))

    // Neighbouring-key slips (QWERTY rows as the keyboard draws them).
    check("n and b are neighbours", KeyboardCorrectionRules.areNeighborKeys("n", "b"))
    check("n and j are neighbours", KeyboardCorrectionRules.areNeighborKeys("n", "j"))
    check("i and j are neighbours", KeyboardCorrectionRules.areNeighborKeys("i", "j"))
    check("h and b are neighbours", KeyboardCorrectionRules.areNeighborKeys("h", "b"))
    check("case does not matter", KeyboardCorrectionRules.areNeighborKeys("N", "b"))
    check("a and l are not neighbours", !KeyboardCorrectionRules.areNeighborKeys("a", "l"))
    check("neighbours are symmetric", KeyboardCorrectionRules.keyNeighbors.allSatisfy { key, others in
      others.allSatisfy { KeyboardCorrectionRules.keyNeighbors[$0]?.contains(key) == true } })
    check("two slips in a long word", KeyboardCorrectionRules.replacement(
      for: "fubktiojiert", suggestions: ["funktioniert"]) == "funktioniert")
    check("three slips in five letters", KeyboardCorrectionRules.replacement(
      for: "njxbt", suggestions: ["nicht"]) == "nicht")
    check("two slips in four letters", KeyboardCorrectionRules.replacement(
      for: "hsbd", suggestions: ["hand"]) == "hand")
    check("three slips in four letters excluded", KeyboardCorrectionRules.replacement(
      for: "jsbd", suggestions: ["hand"]) == nil)
    check("four slips excluded", KeyboardCorrectionRules.replacement(
      for: "njxbr", suggestions: ["nicht"]) == nil)
    check("a far-away wrong letter costs two edits", KeyboardCorrectionRules.replacement(
      for: "nacgt", suggestions: ["nicht"]) == "nicht")
    check("a sideways slip beats a far-away letter", KeyboardCorrectionRules.replacement(
      for: "hamd", suggestions: ["hard", "hand"]) == "hand")
    check("sideways slips beat diagonal ones", KeyboardCorrectionRules.replacement(
      for: "hsbd", suggestions: ["habe", "hebe", "hand"]) == "hand")
    check("umlaut slip", KeyboardCorrectionRules.replacement(
      for: "Madchen", suggestions: ["Mädchen"]) == "Mädchen")
    check("costs are weighted", KeyboardCorrectionRules.editCost(from: "hsbd", to: "hand") == 2
      && KeyboardCorrectionRules.editCost(from: "hsbd", to: "habe") == 2.5
      && KeyboardCorrectionRules.editCost(from: "unt", to: "und") == nil)
    check("fewer edits win", KeyboardCorrectionRules.replacement(
      for: "njcht", suggestions: ["bucht", "nicht"]) == "nicht")
    check("a tie at the fewest edits goes to the first", KeyboardCorrectionRules.replacement(
      for: "hsbd", suggestions: ["habs", "hand"]) == "habs")
    // Frequency: half an edit per doubling of the rank (0 = most common).
    let ranks = ["hand": 40, "habs": 9_000, "habe": 3, "hebe": 12_000, "nicht": 0, "nucht": 20_000]
    func rank(_ word: String) -> Int? { ranks[word] }
    check("a common word beats a rarer equally close one", KeyboardCorrectionRules.replacement(
      for: "hsbd", suggestions: ["habs", "hand"], rank: rank) == "hand")
    check("a much commoner word beats a slightly closer one", KeyboardCorrectionRules.replacement(
      for: "hsbd", suggestions: ["hand", "habe"], rank: rank) == "habe")
    check("unranked words fall back to the edit cost", KeyboardCorrectionRules.replacement(
      for: "hsbd", suggestions: ["habe", "hand"], rank: { _ in nil }) == "hand")
    check("an unranked word loses to a ranked common one", KeyboardCorrectionRules.replacement(
      for: "nixht", suggestions: ["nicjt", "nicht"], rank: { $0 == "nicht" ? 0 : nil }) == "nicht")
    check("scores grow with rank", KeyboardCorrectionRules.score(cost: 1, rank: 0)
      < KeyboardCorrectionRules.score(cost: 1, rank: 100)
      && KeyboardCorrectionRules.score(cost: 1, rank: nil) == KeyboardCorrectionRules.score(cost: 1, rank: 1_000_000))
    check("title case slip", KeyboardCorrectionRules.replacement(
      for: "Hsbd", suggestions: ["Hand"]) == "Hand")
    check("three-letter words still get no substitutions",
          KeyboardCorrectionRules.replacement(for: "teh", suggestions: ["the", "ten"]) == "the")

    let lexicon: Set<String> = ["nicht", "funktioniert", "Hand", "hand", "bucht"]
    var lookups = 0
    func known(_ word: String) -> Bool { lookups += 1; return lexicon.contains(word) }
    check("generator finds three slips", KeyboardCorrectionRules.neighborSlipCandidates(
      for: "njxbt", maxSlips: 3, isKnown: known) == ["nicht"])
    check("generator finds two slips in a long word", KeyboardCorrectionRules.neighborSlipCandidates(
      for: "fubktiojiert", maxSlips: 3, isKnown: known) == ["funktioniert"])
    check("generator keeps title case", KeyboardCorrectionRules.neighborSlipCandidates(
      for: "Hsbd", maxSlips: 2, isKnown: known) == ["Hand"])
    lookups = 0
    check("generator collects every level, fewest slips first", KeyboardCorrectionRules.neighborSlipCandidates(
      for: "njcht", maxSlips: 3, isKnown: known) == ["nicht", "bucht"])
    check("generator honours maxSlips", KeyboardCorrectionRules.neighborSlipCandidates(
      for: "njxbt", maxSlips: 2, isKnown: known).isEmpty)
    check("generator tries one slip in three-letter words", KeyboardCorrectionRules.neighborSlipCandidates(
      for: "ubd", maxSlips: 3, isKnown: { $0 == "und" }) == ["und"])
    check("generator skips two-letter words", KeyboardCorrectionRules.neighborSlipCandidates(
      for: "ub", maxSlips: 3, isKnown: { _ in true }).isEmpty)
    lookups = 0
    check("generator drops a level over budget", KeyboardCorrectionRules.neighborSlipCandidates(
      for: "fubktiojiert", maxSlips: 3, budget: 100, isKnown: known).isEmpty && lookups < 100)
    lookups = 0
    _ = KeyboardCorrectionRules.neighborSlipCandidates(
      for: "abcdefghijkl", maxSlips: 3, isKnown: known)
    check("generator stays within its budget", lookups <= 1_500)
    lookups = 0
    var stops = 0
    check("generator drops a level cut short", KeyboardCorrectionRules.neighborSlipCandidates(
      for: "njcht", maxSlips: 3, shouldStop: { stops += 1; return stops > 30 }, isKnown: known) == ["nicht"])
    check("generator leaves umlaut positions alone", KeyboardCorrectionRules.neighborSlipCandidates(
      for: "Mädcehn", maxSlips: 3, isKnown: { $0.contains("ä") == false }).isEmpty)

    // Single edits the slip search adds when UITextChecker proposes nothing.
    let editLexicon: Set<String> = ["the", "nicht", "klappt", "Hallo", "und", "hallo"]
    func editKnown(_ word: String) -> Bool { editLexicon.contains(word) }
    let latinLetters = KeyboardCorrectionLanguage.letters(of: [.german, .english])
    check("single edit: swap", KeyboardCorrectionRules.singleEditCandidates(
      for: "teh", letters: latinLetters, isKnown: editKnown) == ["the"])
    check("single edit: inner swap", KeyboardCorrectionRules.singleEditCandidates(
      for: "kalppt", letters: latinLetters, isKnown: editKnown) == ["klappt"])
    check("single edit: missing letter", KeyboardCorrectionRules.singleEditCandidates(
      for: "nich", letters: latinLetters, isKnown: editKnown) == ["nicht"])
    check("single edit: extra letter", KeyboardCorrectionRules.singleEditCandidates(
      for: "nichtt", letters: latinLetters, isKnown: editKnown) == ["nicht"])
    check("single edit: title case keeps its first letter", KeyboardCorrectionRules.singleEditCandidates(
      for: "Hlalo", letters: latinLetters, isKnown: editKnown) == ["Hallo"])
    check("single edit: never the word itself", KeyboardCorrectionRules.singleEditCandidates(
      for: "unnd", letters: latinLetters, isKnown: { $0 == "unnd" || $0 == "und" }) == ["und"])
    check("single edit: stop gives nothing", KeyboardCorrectionRules.singleEditCandidates(
      for: "kalppt", letters: latinLetters, shouldStop: { true }, isKnown: editKnown).isEmpty)

    // German spelled with ae/oe/ue/ss.
    func spellings(_ word: String) -> Set<String> { Set(KeyboardCorrectionRules.transcriptions(of: word).map { $0.word }) }
    check("umlaut respellings", spellings("schoen") == ["schön"])
    check("every combination", spellings("Gruesse") == ["Grüsse", "Grueße", "Grüße"])
    check("capital umlaut at the start", spellings("Aerger") == ["Ärger"])
    check("no capital ß", spellings("Ssomething").allSatisfy { !$0.hasPrefix("ß") && !$0.hasPrefix("SS") })
    check("no pair, no respelling", spellings("nicht").isEmpty)
    check("pairs do not overlap", spellings("sss") == ["ßs"])
    check("respelling costs", KeyboardCorrectionRules.transcriptions(of: "Gruesse")
      .first { $0.word == "Grüße" }?.cost == 0.8)
    check("too many pairs left alone", KeyboardCorrectionRules.transcriptions(
      of: "aeaeaeaeaeaeae").isEmpty)
    check("respelling beats a common nearby word", KeyboardCorrectionRules.replacement(
      for: "schoen", suggestions: ["schon", "schön"], rank: { $0 == "schon" ? 0 : 500 }) == "schön")
    check("capital respelling", KeyboardCorrectionRules.replacement(
      for: "Aerger", suggestions: ["Ärger"]) == "Ärger")
    check("ß respelling", KeyboardCorrectionRules.replacement(
      for: "Strasse", suggestions: ["Strasser", "Straße"]) == "Straße")
    check("umlaut and ß together", KeyboardCorrectionRules.replacement(
      for: "gruesse", suggestions: ["grüße"]) == "grüße")
    check("frequency picks between respellings", KeyboardCorrectionRules.replacement(
      for: "gruesse", suggestions: ["grüsse", "grüße"], rank: { $0 == "grüße" ? 0 : 900 }) == "grüße")
    check("the most replaced pairs win, even against frequency", KeyboardCorrectionRules.replacement(
      for: "gruesse", suggestions: ["grüsse", "grüße"], rank: { $0 == "grüsse" ? 0 : 900 }) == "grüße")
    check("pair counts", KeyboardCorrectionRules.transcriptions(of: "Gruesse")
      .first { $0.word == "Grüße" }?.pairs == 2)
    check("a lowercase respelling may be capitalised", KeyboardCorrectionRules.replacement(
      for: "strasse", suggestions: ["Straße"]) == "Straße")
    check("a lowercase word may gain a capital (the provider offers only nouns)",
          KeyboardCorrectionRules.replacement(for: "haus", suggestions: ["Haus"]) == "Haus")
    check("capitalising alone costs nothing", KeyboardCorrectionRules.editCost(from: "haus", to: "Haus") == 0)
    check("a capitalised word never loses its capital", KeyboardCorrectionRules.replacement(
      for: "Haus", suggestions: ["haus"]) == nil)
    // Respellings inside the edit distance, so they combine with typos.
    func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } == true }
    check("a respelling costs little in the edit distance",
          near(KeyboardCorrectionRules.editCost(from: "schoen", to: "schön"), 0.3))
    check("ss for ß in the edit distance",
          near(KeyboardCorrectionRules.editCost(from: "grosse", to: "große"), 0.5))
    check("a capital respelling in the edit distance",
          near(KeyboardCorrectionRules.editCost(from: "Oefen", to: "Öfen"), 0.3))
    check("respelling, slip and swap together", near(KeyboardCorrectionRules.editCost(
      from: "moeglichkwitne", to: "Möglichkeiten"), 2.3))
    check("a respelled long word with typos", KeyboardCorrectionRules.replacement(
      for: "moeglichkwitne", suggestions: ["Möglichkeit", "Möglichkeiten"]) == "Möglichkeiten")
    check("a respelling pair never stands for another letter",
          KeyboardCorrectionRules.editCost(from: "oe", to: "ä") == nil)
    check("a missing letter still costs an insertion",
          near(KeyboardCorrectionRules.editCost(from: "nich", to: "nicht"), 1.5))
    check("too short by too many letters", KeyboardCorrectionRules.editCost(
      from: "abcdefghijkl", to: "abcd") == nil)

    // Completions of a long word's start.
    let prefixes = KeyboardCorrectionRules.completionPrefixes(of: "moeglichkwitne", respell: true)
    check("respelled prefixes first", prefixes.first?.first == "möglichkwitn"
      && prefixes.first?.contains("möglichk") == true)
    check("the word as typed comes last", prefixes.last?.first == "moeglichkwitn")
    check("prefixes stop at half the word", prefixes.last?.last == "moeglic")
    check("no respelled prefixes without German", KeyboardCorrectionRules.completionPrefixes(
      of: "moeglichkwitne", respell: false).count == 1)
    check("short words get no completions",
          KeyboardCorrectionRules.completionPrefixes(of: "nciht", respell: true).isEmpty)
    check("at most four spellings", KeyboardCorrectionRules.completionPrefixes(
      of: "aeoeueaeoeue", respell: true).count == KeyboardCorrectionRules.maxCompletionForms)
    check("prefixes keep five letters", KeyboardCorrectionRules.completionPrefixes(
      of: "abcdefg", respell: false) == [["abcdef", "abcde"]])
    let germanCompletions = ["möglichk": ["Möglichkeit", "Möglichkeiten", "Möglichkeitsform"]]
    var asked: [String] = []
    let completed = KeyboardCorrectionRules.completionCandidates(
      for: "moeglichkwitne", respell: true) { prefix in
      asked.append(prefix)
      return germanCompletions[prefix] ?? []
    }
    check("completions close enough to the word", completed == ["Möglichkeit", "Möglichkeiten"])
    check("the longest completing prefix wins", !asked.contains("möglich"))
    check("the word as typed is tried too", asked.contains("moeglichkwitn"))
    check("completions keep a title-case capital", KeyboardCorrectionRules.completionCandidates(
      for: "Funktionirt", respell: false) { $0 == "funktioni" || $0 == "Funktioni" ? ["funktioniert"] : [] }
      == ["Funktioniert"])
    var completionLookups = 0
    check("completions cut short give nothing", KeyboardCorrectionRules.completionCandidates(
      for: "moeglichkwitne", respell: true, shouldStop: { completionLookups >= 3 }) { prefix in
      completionLookups += 1
      return germanCompletions[prefix] ?? []
    }.isEmpty && completionLookups == 3)
    // The deadline passes while the second completion is scored (the third check after the lookup).
    var checksSinceLookup = -1
    check("completions stop during scoring", KeyboardCorrectionRules.completionCandidates(
      for: "Funktionirt", respell: false, shouldStop: {
        if checksSinceLookup >= 0 { checksSinceLookup += 1 }
        return checksSinceLookup >= 3
      }) { prefix in
      guard prefix == "Funktioni" else { return [] }
      checksSinceLookup = 0
      return ["funktioniert", "funktionieren"]
    }.isEmpty)
    var farLookups = 0
    _ = KeyboardCorrectionRules.completionCandidates(for: "abcdefghijkl", respell: false) { _ in
      farLookups += 1
      return ["abcdefzzzzzzzzzzzz"]
    }
    check("far-away completions stop after a few prefixes",
          farLookups == KeyboardCorrectionRules.maxCompletingPrefixes)

    // Two-letter words: only their letters swapped.
    check("two-letter swap", KeyboardCorrectionRules.replacement(for: "mi", suggestions: ["im"]) == "im")
    check("two-letter swap keeps the capital first", KeyboardCorrectionRules.replacement(
      for: "Si", suggestions: ["Is"]) == "Is")
    check("two-letter words get nothing but their swap or a one-key slip", KeyboardCorrectionRules.replacement(
      for: "qm", suggestions: ["im", "am"]) == "am" && KeyboardCorrectionRules.replacement(
      for: "qm", suggestions: ["im"]) == nil)
    check("swapped", KeyboardCorrectionRules.swapped("os") == "so" && KeyboardCorrectionRules.swapped("Mi") == "Im")
    check("swappable", KeyboardCorrectionRules.isSwappable("mi") && KeyboardCorrectionRules.isSwappable("Os"))
    check("a double letter isn't swappable", !KeyboardCorrectionRules.isSwappable("aa"))
    check("all caps isn't swappable", !KeyboardCorrectionRules.isSwappable("OS"))
    check("one or three letters aren't swappable",
          !KeyboardCorrectionRules.isSwappable("a") && !KeyboardCorrectionRules.isSwappable("abc"))
    check("digits aren't swappable", !KeyboardCorrectionRules.isSwappable("a1"))
    check("umlauts only with German", KeyboardCorrectionRules.isSwappable("üb")
      && !KeyboardCorrectionRules.isSwappable("üb", letters: KeyboardCorrectionLanguage.letters(of: [.english])))
    let de = KeyboardCorrectionLanguage.german, en = KeyboardCorrectionLanguage.english
    func swap(_ word: String, sentence: [KeyboardCorrectionLanguage] = [.german, .english]) -> String? {
      KeyboardCorrectionRules.twoLetterSwap(of: word, sentence: sentence, selected: [de, en])
    }
    check("os becomes so, though English knows os", swap("os") == "so")
    check("a sentence-start swap keeps its capital", swap("Os") == "So" && swap("Mi") == "Im")
    check("si becomes is in English", swap("si", sentence: [en]) == "is")
    check("si stays in a German sentence", swap("si", sentence: [de]) == nil)
    check("a common two-letter word is never swapped",
          swap("na") == nil && swap("eh") == nil && swap("on") == nil && swap("no") == nil)
    check("no common swap, no correction", swap("qm") == nil && swap("xy") == nil)
    for kept in ["hä", "Hä", "ma", "ta", "ad", "ow", "ew", "em", "re"] {
      check("kept two-letter word: \(kept)", swap(kept) == nil && swap(kept, sentence: [de]) == nil
        && swap(kept, sentence: [en]) == nil
        && KeyboardCorrectionRules.twoLetterSwap(of: kept, sentence: [en], selected: [en]) == nil)
    }
    func slip(_ word: String, sentence: [KeyboardCorrectionLanguage] = [.german, .english]) -> String? {
      KeyboardCorrectionRules.twoLetterSlip(of: word, sentence: sentence, selected: [de, en])
    }
    check("ia is is in an English sentence", slip("ia", sentence: [en]) == "is")
    check("ia is ja in a German sentence", slip("ia", sentence: [de]) == "ja")
    check("ia at a sentence start is ambiguous", slip("ia") == nil)
    check("a slip keeps the capital", slip("Ia", sentence: [en]) == "Is" && slip("Zi", sentence: [de]) == "Zu")
    check("zi is zu", slip("zi", sentence: [de]) == "zu")
    check("qm is am", slip("qm") == "am")
    check("several common slips stay", slip("ot", sentence: [en]) == nil)
    check("no common slip stays", slip("qq") == nil && slip("xv") == nil)
    for kept in ["km", "ca", "zb", "dh", "di", "mo", "sa", "st", "nr", "hm", "na", "on", "mg", "ms",
                 "dl", "hr", "eg", "mr", "do", "dr", "kb", "et", "Do", "Mr", "Mg", "ie", "np", "ka",
                 "Ka", "Np"] {
      check("kept from slips: \(kept)", slip(kept) == nil && slip(kept, sentence: [de]) == nil
        && slip(kept, sentence: [en]) == nil
        && (["ie", "np", "Np"].contains(kept)
            || KeyboardCorrectionRules.twoLetterSlip(of: kept, sentence: [de], selected: [de]) == nil)
        && (["dh", "di", "mo", "ka", "Ka"].contains(kept)
            || KeyboardCorrectionRules.twoLetterSlip(of: kept, sentence: [en], selected: [en]) == nil))
    }
    check("German abbreviations are only German", KeyboardCorrectionRules.twoLetterSlip(
      of: "di", sentence: [en], selected: [en]) == "do")
    check("a two-letter word may become a one-key slip", KeyboardCorrectionRules.replacement(
      for: "ia", suggestions: ["is"]) == "is")
    check("a two-letter word never becomes a farther word", KeyboardCorrectionRules.replacement(
      for: "ia", suggestions: ["in"]) == nil)
    check("a kept word is never a target", KeyboardCorrectionLanguage.all.allSatisfy {
      $0.keptTwoLetterWords.isDisjoint(with: $0.twoLetterWords) })
    check("every two-letter word is lowercase and two letters",
          KeyboardCorrectionLanguage.all.allSatisfy { $0.twoLetterWords.allSatisfy {
            $0.count == 2 && $0 == $0.lowercased() } })
    var (swapState, swapContext) = typed("mi", prefix: "ich bin ", document: document)
    check("a two-letter word is tracked and swapped", swapState.correction(
      in: swapContext, provider: StubProvider(words: ["im"]))?.replacement == "im")

    // Capitalised words German accepts only as possible compounds.
    let germanAccepts: Set<String> = ["Ichhabe", "Moeglichkwitne", "Morgenrot", "Haus", "Annabel",
                                      "Michael", "Erleben"]
    let englishAccepts: Set<String> = ["Annabel", "Michael"]
    let rankedWords: Set<String> = ["Haus"]
    let lowercaseKnown: Set<String> = ["haus", "erleben"]
    func compoundLike(_ word: String, german: Bool = true, stopAfter: Int = .max) -> (Bool, Int) {
      var lookups = 0
      let result = KeyboardCorrectionRules.acceptedOnlyAsCompound(
        word, shouldStop: { lookups >= stopAfter },
        germanKnows: { lookups += 1; return german && germanAccepts.contains($0) },
        othersKnow: { lookups += 1; return englishAccepts.contains($0) },
        isRanked: { lookups += 1; return rankedWords.contains($0) },
        lowercaseFlaggedEverywhere: { lookups += 1; return !lowercaseKnown.contains($0) })
      return (result, lookups)
    }
    check("a capitalised typo German accepts as a compound", compoundLike("Ichhabe").0
      && compoundLike("Moeglichkwitne").0)
    check("a common noun isn't compound-like", !compoundLike("Haus").0)
    check("a word another language knows isn't compound-like",
          !compoundLike("Annabel").0 && !compoundLike("Michael").0)
    check("a word known in lowercase isn't compound-like", !compoundLike("Erleben").0)
    check("without German nothing is compound-like", !compoundLike("Ichhabe", german: false).0)
    check("a lowercase word isn't compound-like", !compoundLike("ichhabe").0)
    check("all caps isn't compound-like", !compoundLike("ICHHABE").0)
    check("the compound check stops at the deadline", compoundLike("Ichhabe", stopAfter: 1) == (false, 1))
    check("a compound found as the deadline passes gives nothing", !compoundLike("Ichhabe", stopAfter: 4).0)
    check("a compound-like word splits after a pronoun",
          KeyboardCorrectionRules.isCompoundCorrection("Ich habe", of: "Ichhabe"))
    check("a real compound is never split", !KeyboardCorrectionRules.isCompoundCorrection(
      "Morgen rot", of: "Morgenrot"))
    check("a compound-like word becomes a word with the umlaut it spelled out",
          KeyboardCorrectionRules.isCompoundCorrection("Möglichkeiten", of: "Moeglichkwitne"))
    check("no umlaut spelled out, no correction", !KeyboardCorrectionRules.isCompoundCorrection(
      "Morgenröte", of: "Morgenrot"))
    check("an umlaut that was typed is no evidence", !KeyboardCorrectionRules.isCompoundCorrection(
      "Übermut", of: "Übermute"))
    check("an unrelated pair is no evidence", !KeyboardCorrectionRules.isCompoundCorrection(
      "Feuerwächter", of: "Feuerwache"))
    check("the respelled umlaut must be where the pair was", !KeyboardCorrectionRules.isCompoundCorrection(
      "Moglichkeit", of: "Moeglichkwitne") && !KeyboardCorrectionRules.isCompoundCorrection(
      "Mäglichkeit", of: "Moeglichkwitne"))
    check("ss for ß is evidence too", KeyboardCorrectionRules.isCompoundCorrection(
      "Großartigkeit", of: "Grossartigkiet"))

    // Candidates German accepts only as possible compounds are replaced by their splits.
    let compoundWords: Set<String> = ["Ichhabe", "Haben"]
    check("a compound-like candidate is replaced by its split", KeyboardCorrectionRules.repairingCompounds(
      ["Ichhabe", "Ichhaben"], isCompoundLike: { $0 == "Ichhabe" },
      splits: { $0 == "Ichhabe" ? ["Ich habe"] : [] }) == ["Ich habe", "Ichhaben"])
    check("a compound-like candidate without a split is dropped", KeyboardCorrectionRules.repairingCompounds(
      ["Haben", "Hagen"], isCompoundLike: { compoundWords.contains($0) }, splits: { _ in [] }) == ["Hagen"])
    check("repaired splits stay unique", KeyboardCorrectionRules.repairingCompounds(
      ["Ichhabe", "Ich habe"], isCompoundLike: { $0 == "Ichhabe" }, splits: { _ in ["Ich habe"] })
      == ["Ich habe"])
    check("a swapped compound typo becomes its split", KeyboardCorrectionRules.replacement(
      for: "Ichhaeb", suggestions: ["Ich habe"], rank: { _ in 5 }) == "Ich habe")
    check("a lowercase swapped compound typo becomes its split", KeyboardCorrectionRules.replacement(
      for: "ichhaeb", suggestions: ["ich habe"], rank: { _ in 5 }) == "ich habe")

    // Two words typed without their space.
    var cuts: [String] = []
    check("every cut into words of two letters or more",
          KeyboardCorrectionRules.splitCandidates(for: "ichhabe") { cuts.append($0 + " " + $1); return true }
            == ["ic hhabe", "ich habe", "ichh abe", "ichha be"] && cuts.count == 4)
    check("only accepted cuts", KeyboardCorrectionRules.splitCandidates(for: "ichhabe") {
      $0 == "ich" && $1 == "habe" } == ["ich habe"])
    check("too short to cut", KeyboardCorrectionRules.splitCandidates(for: "abc") { _, _ in true }.isEmpty)
    // Split words: both known and ranked in one dictionary, with the deadline before each lookup.
    let splitWords = ["de": ["ich": 3, "habe": 8, "rar": 400], "en": ["ich": 900, "have": 4]]
    func commonSplit(_ left: String, _ right: String, _ dictionaries: [String] = ["de", "en"],
                     stopAfter: Int = .max, lookups: inout [String]) -> Bool {
      var log: [String] = []
      defer { lookups = log }
      return KeyboardCorrectionRules.isCommonSplit(
        left, right, in: dictionaries, shouldStop: { log.count >= stopAfter },
        isKnown: { word, dictionary in log.append("known \(word) \(dictionary)")
          return splitWords[dictionary]?[word] != nil },
        rank: { word, dictionary in log.append("rank \(word) \(dictionary)")
          return splitWords[dictionary]?[word] })
    }
    var splitLog: [String] = []
    check("a common split", commonSplit("ich", "habe", lookups: &splitLog) && splitLog.count == 4)
    check("both words in the same dictionary", !commonSplit("ich", "have", lookups: &splitLog))
    check("a rare word is no split", !commonSplit("ich", "rar", lookups: &splitLog))
    check("another dictionary may know the split", commonSplit("ich", "habe", ["en", "de"], lookups: &splitLog))
    check("a split check stops at the deadline",
          !commonSplit("ich", "habe", stopAfter: 1, lookups: &splitLog) && splitLog == ["known ich de"])
    check("no further dictionary after the deadline",
          !commonSplit("ich", "habe", ["en", "de"], stopAfter: 2, lookups: &splitLog)
            && splitLog == ["known ich en", "known habe en"])
    check("a split found as the deadline passes gives nothing",
          !commonSplit("ich", "habe", stopAfter: 4, lookups: &splitLog) && splitLog.count == 4)
    var splitLookups = 0
    check("a split search cut short gives nothing", KeyboardCorrectionRules.splitCandidates(
      for: "ichhabe", shouldStop: { splitLookups >= 2 }) { _, _ in splitLookups += 1; return true }
      .isEmpty && splitLookups == 2)
    check("split parts", KeyboardCorrectionRules.splitParts(of: "ich habe")! == ("ich", "habe"))
    check("one-letter words are never split off", KeyboardCorrectionRules.splitParts(of: "a cat") == nil)
    check("one space only", KeyboardCorrectionRules.splitParts(of: "ich habe das") == nil)
    check("a common split", KeyboardCorrectionRules.replacement(
      for: "ichhabe", suggestions: ["ich habe"], rank: { _ in 10 }) == "ich habe")
    check("a split needs both words common", KeyboardCorrectionRules.replacement(
      for: "ichhabe", suggestions: ["ich habe"], rank: { $0 == "ich" ? 1 : nil }) == nil)
    check("a split at the rank limit", KeyboardCorrectionRules.replacement(
      for: "ichhabe", suggestions: ["ich habe"],
      rank: { _ in KeyboardCorrectionRules.maxSplitRank }) == "ich habe")
    check("a rare word is never split off", KeyboardCorrectionRules.replacement(
      for: "ichhabe", suggestions: ["ich habe"],
      rank: { $0 == "ich" ? 1 : KeyboardCorrectionRules.maxSplitRank + 1 }) == nil)
    check("a noun is never split off a lowercase word", KeyboardCorrectionRules.replacement(
      for: "dashaus", suggestions: ["das Haus"], rank: { _ in 10 }) == nil)
    check("a title-case word never gets a capital second word", KeyboardCorrectionRules.replacement(
      for: "Ichhabe", suggestions: ["Ich Habe"], rank: { _ in 10 }) == nil)
    check("the missing space counts towards the edit budget", KeyboardCorrectionRules.replacement(
      for: "abcde", suggestions: ["xy cde"], rank: { _ in 1 }) == nil)
    check("a split with typos up to the edit budget", KeyboardCorrectionRules.replacement(
      for: "abcde", suggestions: ["sb cdt"], rank: { _ in 1 }) == "sb cdt")
    check("a split keeps a capital", KeyboardCorrectionRules.replacement(
      for: "Ichhabe", suggestions: ["ich habe", "Ich habe"], rank: { _ in 10 }) == "Ich habe")
    check("a split with a typo", KeyboardCorrectionRules.replacement(
      for: "ichhsbe", suggestions: ["ich habe"], rank: { _ in 10 }) == "ich habe")
    check("a close word beats a rare split", KeyboardCorrectionRules.replacement(
      for: "nciht", suggestions: ["nc iht", "nicht"], rank: { $0 == "nicht" ? 3 : 5_000 }) == "nicht")
    check("a respelling beats a split", KeyboardCorrectionRules.replacement(
      for: "schoen", suggestions: ["sch oen", "schön"], rank: { _ in 1 }) == "schön")
    check("english-only never respells", KeyboardCorrectionRules.replacement(
      for: "schoen", suggestions: ["schön"],
      letters: KeyboardCorrectionLanguage.letters(of: [.english])) == nil)

    // The sentence's language from the words before the cursor.
    let deWords: Set<String> = ["ich", "habe", "das", "so", "in", "wie"]
    let enWords: Set<String> = ["i", "have", "the", "so", "in", "woe", "cool"]
    func knows(_ word: String, _ code: String) -> Bool { (code == "de" ? deWords : enWords).contains(word) }
    func language(_ text: String) -> String? {
      KeyboardCorrectionRules.sentenceLanguage(before: text, codes: ["de", "en"], knows: knows)
    }
    check("german sentence", language("ich habe das ") == "de")
    check("english sentence", language("I have the ") == "en")
    check("shared words only", language("so in ") == nil)
    check("mixed sentence", language("ich have ") == nil)
    check("nothing before", language("") == nil)
    check("one-letter words ignored", language("a ") == nil)
    check("capitalised words count", language("Ich ") == "de")
    check("only the last eight words", language("the the the ich ich ich ich ich ich ich ich ") == "de")
    check("punctuation splits words", language("ich,habe.") == "de")

    let recorder = ContextRecorder()
    var (contextState, wordContext) = typed("nciht", prefix: "das ist ", document: document)
    let contextEdit = contextState.correction(in: wordContext, provider: recorder)
    check("the text before the word reaches the provider", recorder.before == "das ist "
      && contextEdit?.replacement == "nicht")

    // The app's language selection ("de,en" in the App Group).
    let german = KeyboardCorrectionLanguage.german, english = KeyboardCorrectionLanguage.english
    check("missing selection is German and English",
          KeyboardCorrectionLanguage.selection(from: nil) == [german, english])
    check("empty selection is the default", KeyboardCorrectionLanguage.selection(from: "") == [german, english])
    check("unknown-only selection is the default",
          KeyboardCorrectionLanguage.selection(from: "xx, zz") == [german, english])
    check("single language", KeyboardCorrectionLanguage.selection(from: "en") == [english])
    check("order kept, spacing and case tolerated, duplicates and unknown dropped",
          KeyboardCorrectionLanguage.selection(from: " EN ,xx,de,en") == [english, german])
    check("selection capped", KeyboardCorrectionLanguage.selection(
      from: Array(repeating: "de,en", count: 5).joined(separator: ",")).count
      <= KeyboardCorrectionLanguage.maxSelected)
    check("every language has a unique code",
          Set(KeyboardCorrectionLanguage.all.map(\.code)).count == KeyboardCorrectionLanguage.all.count)
    let englishLetters = KeyboardCorrectionLanguage.letters(of: [english])
    let germanLetters = KeyboardCorrectionLanguage.letters(of: [german])
    check("english-only leaves umlaut words alone", KeyboardCorrectionRules.replacement(
      for: "Mädcehn", suggestions: ["Mädchen"], letters: englishLetters) == nil)
    check("english-only rejects an umlaut proposal", KeyboardCorrectionRules.replacement(
      for: "nciht", suggestions: ["nicht", "nücht"], letters: englishLetters) == "nicht")
    check("german-only keeps umlauts", KeyboardCorrectionRules.replacement(
      for: "Mädcehn", suggestions: ["Mädchen"], letters: germanLetters) == "Mädchen")
    check("german-only still corrects plain words", KeyboardCorrectionRules.replacement(
      for: "udn", suggestions: ["und"], letters: germanLetters) == "und")
    check("no dictionary means no letters", !KeyboardCorrectionRules.isWord("nciht", letters: []))
    for word in ["ab", "a", "hello_world", "abc123", "https://nciht", "a@b.de",
                 "fooBar", "ALLCAPS", "👩🏽‍💻nciht", "Ma\u{308}dcehn", "a-bcd", "abc'd", "abc\u{200B}de"] {
      check("excluded token: \(word)", !KeyboardCorrectionRules.isWord(word))
    }
    check("long words bounded", !KeyboardCorrectionRules.isWord(String(repeating: "a", count: 21)))

    var (state, current) = typed("nciht", prefix: "🙂 ", document: document)
    let edit = state.correction(in: current, provider: provider)
    check("manual word with emoji prefix", edit?.replacement == "nicht")
    state.didCorrect(edit!)
    let corrected = context("🙂 nicht ", document: document)
    state.reconcile(corrected)
    let undo = state.takeUndo(in: corrected)
    check("undo original", undo?.original == "nciht")
    check("undo one shot", state.takeUndo(in: corrected) == nil)
    check("space after undo does not recorrect", state.correction(
      in: context("🙂 nciht", document: document), provider: provider) == nil)

    // Length-changing edits must preserve the surrounding emoji and restore the full
    // original, not delete a replacement-sized suffix from the original context.
    for (original, replacement) in [("nich", "nicht"), ("Halllo", "Hallo")] {
      (state, current) = typed(original, prefix: "🙂 ", document: document)
      let variableEdit = state.correction(in: current, provider: StubProvider(words: [replacement]))!
      check("length-changing candidate", variableEdit.replacement == replacement)
      state.didCorrect(variableEdit)
      check("length-changing undo query", state.undoCandidate(
        in: context("🙂 " + replacement + " ", document: document))?.original == original)
      let restored = state.takeUndo(in: context("🙂 " + replacement + " ", document: document))
      check("length-changing undo", restored?.original == original)
      check("length-changing undo suppresses recorrection", state.correction(
        in: current, provider: StubProvider(words: [replacement])) == nil)
    }

    // Real UIKit proxies use nil at document boundaries, unlike the initial mocks.
    var empty = KeyboardCorrectionContext.reported(
      document: document, before: nil, after: nil, selection: nil, allowed: true, hasText: false)
    check("known empty field seeds left context", empty.before == "" && empty.isSafe)
    state = KeyboardAutocorrection()
    for letter in "nciht" {
      state.manualInsertion(String(letter), in: empty)
      empty = empty.inserting(String(letter))
      state.hostWillChange()
      state.hostDidChange(empty)
    }
    // Hosts may switch between nil and empty-string boundary reports after insertion.
    let emptyStringBoundary = context("nciht", after: "", selection: "", document: document)
    state.hostWillChange()
    state.hostDidChange(emptyStringBoundary)
    let boundaryEdit = state.correction(in: empty, provider: provider)
    check("nil right context at end permits verified correction", boundaryEdit?.replacement == "nicht")
    state.didCorrect(boundaryEdit!)
    state.hostWillChange()
    let boundaryCorrected = context("nicht ", after: nil, document: document)
    state.hostDidChange(boundaryCorrected)
    check("nil right context undo", state.takeUndo(in: boundaryCorrected)?.original == "nciht")
    let hidden = KeyboardCorrectionContext.reported(
      document: document, before: nil, after: nil, selection: nil, allowed: true, hasText: true)
    check("nonempty opaque field is still unsafe", !hidden.isSafe && hidden.before == nil)
    let rightText = KeyboardCorrectionContext.reported(
      document: document, before: nil, after: "existing", selection: nil, allowed: true, hasText: false)
    check("right text contradicts empty field", !rightText.isSafe)
    check("only empty boundary reports are equivalent",
      context("nciht", after: nil, document: document) == context("nciht", document: document))
    check("nonempty right context is never ignored",
      context("nciht", after: "x", document: document) != context("nciht", document: document))
    check("missing left context is never equal to empty",
      context(nil, document: document) != context("", document: document))

    (state, current) = typed("nciht", document: document)
    state.hostWillChange()
    state.hostDidChange(current)
    check("matching own acknowledgement retains word", state.correction(in: current, provider: provider) != nil)
    (state, current) = typed("nciht", document: document)
    state.hostWillChange()
    check("pending report blocks correction despite matching stale read", state.correction(in: current, provider: provider) == nil)
    state.hostDidChange(current)
    check("blocked pending attempt cannot revive", state.correction(in: current, provider: provider) == nil)
    (state, current) = typed("nciht", document: document)
    state.hostWillChange()
    state.hostDidChange(context("nc", after: "iht", document: document))
    check("actual cursor move invalidates", state.correction(in: current, provider: provider) == nil)
    (state, current) = typed("nciht", document: document)
    state.hostWillChange()
    state.hostDidChange(context("nci", document: document))
    check("delayed own acknowledgement invalidates", state.correction(in: current, provider: provider) == nil)

    let unsafe = [
      context(nil, document: document),
      context("nciht", selection: "chosen", document: document),
      context("nciht", allowed: false, document: document),
      context("nciht", document: UUID()), context("nci", document: document),
      context("prefix nciht", document: document), context("nciht", after: "x", document: document),
    ]
    for other in unsafe {
      (state, current) = typed("nciht", document: document)
      check("unsafe/stale context cannot correct", state.correction(in: other, provider: provider) == nil)
      check("invalidated context cannot be revived", state.correction(in: current, provider: provider) == nil)
    }
    for other in unsafe + [context("nicht", document: document)] {
      (state, current) = typed("nciht", document: document)
      let pendingEdit = state.correction(in: current, provider: provider)!
      state.didCorrect(pendingEdit)
      check("unsafe undo does nothing", state.takeUndo(in: other) == nil)
    }
    (state, current) = typed("nciht", document: document)
    state.invalidate()
    check("lifecycle/cursor invalidation", state.correction(in: current, provider: provider) == nil)
    (state, current) = typed("nciht", prefix: "existing", document: document)
    check("do not adopt existing word", state.correction(in: current, provider: provider) == nil)
    (state, current) = typed("nciht", prefix: "@", document: document)
    check("do not adopt technical suffix", state.correction(in: current, provider: provider) == nil)
    (state, current) = typed("nciht", document: document)
    state.reconcile(context("nci", document: document))
    check("late report abandons tracking", state.correction(in: current, provider: provider) == nil)
    (state, current) = typed("nciht", document: document)
    let pendingEdit = state.correction(in: current, provider: provider)!
    state.didCorrect(pendingEdit)
    state.manualInsertion("a", in: context("nicht ", document: document))
    check("typing consumes undo", state.takeUndo(in: context("nicht a", document: document)) == nil)

    // Backspace undoes a correction only for a few seconds.
    var (timed, timedContext) = typed("nciht", document: document)
    let timedEdit = timed.correction(in: timedContext, provider: provider)!
    timed.didCorrect(timedEdit, at: 100)
    let timedCorrected = context("nicht ", document: document)
    check("undo within the window", timed.takeUndo(in: timedCorrected, at: 102.9)?.original == "nciht")
    (timed, timedContext) = typed("nciht", document: document)
    timed.didCorrect(timed.correction(in: timedContext, provider: provider)!, at: 100)
    check("no undo after the window", timed.takeUndo(in: timedCorrected, at: 103.1) == nil)
    check("the window is three seconds", KeyboardAutocorrection.undoWindow == 3)

    // Queries and consumption share eligibility, but queries never discard pending undo.
    timed.didCorrect(timedEdit, at: 100)
    check("undo deadline uses the original correction time", timed.undoDeadline == 103)
    for now in [100.0, 102.9, 103.0, 103.1] {
      let contexts = [timedCorrected,
        context("nicht ", after: nil, selection: "", document: document),
        context(nil, document: document), context("nicht ", selection: "x", document: document),
        context("nicht ", allowed: false, document: document),
        context("nicht ", document: UUID()), context("nicht", document: document),
        context("nicht ", after: "x", document: document)]
      for current in contexts {
        let eligible = current.isSafe && current == timedCorrected && now <= 103
        check("query checks context and inclusive window", (timed.undoCandidate(in: current, at: now) != nil) == eligible)
        var consumed = timed
        check("query agrees with takeUndo", (consumed.takeUndo(in: current, at: now) != nil) == eligible)
        check("takeUndo consumes even on failure", consumed.undoDeadline == nil
          && consumed.undoCandidate(in: timedCorrected, at: 101) == nil)
      }
    }
    check("successful and failed queries leave undo intact",
          timed.undoCandidate(in: timedCorrected, at: 101)?.original == "nciht" && timed.undoDeadline == 103)
    timed.hostWillChange()
    check("pending host report blocks query", timed.undoCandidate(in: timedCorrected, at: 101) == nil)
    var blocked = timed
    check("pending takeUndo consumes", blocked.takeUndo(in: timedCorrected, at: 101) == nil
      && blocked.undoDeadline == nil)
    timed.hostDidChange(timedCorrected)
    check("query did not discard a matching acknowledgement",
          timed.undoCandidate(in: timedCorrected, at: 102)?.original == "nciht" && timed.undoDeadline == 103)
    timed.hostDidChange(context("external ", document: document))
    check("host change invalidates query", timed.undoCandidate(in: timedCorrected, at: 102) == nil)
    timed.didCorrect(timedEdit, at: 100)
    timed.manualInsertion("a", in: timedCorrected)
    check("manual insertion clears query", timed.undoDeadline == nil
      && timed.undoCandidate(in: timedCorrected.inserting("a"), at: 101) == nil)
    timed.didCorrect(timedEdit, at: 100)
    timed.invalidate()
    check("invalidation clears query", timed.undoDeadline == nil
      && timed.undoCandidate(in: timedCorrected, at: 101) == nil)

    // ? and ! correct like space and stay after the replacement.
    for delimiter in ["?", "!", ".", ","] {
      var (marked, markedContext) = typed("nciht", document: document)
      let markedEdit = marked.correction(in: markedContext, provider: provider, delimiter: delimiter)
      check("\(delimiter) corrects", markedEdit?.replacement == "nicht" && markedEdit?.delimiter == delimiter)
      marked.didCorrect(markedEdit!)
      let markedCorrected = context("nicht" + delimiter, document: document)
      check("\(delimiter) undo query", marked.undoCandidate(in: markedCorrected)?.original == "nciht")
      check("\(delimiter) undo", marked.takeUndo(in: markedCorrected)?.original == "nciht")
      (marked, markedContext) = typed("nciht", document: document)
      marked.didCorrect(marked.correction(in: markedContext, provider: provider, delimiter: delimiter)!)
      marked.manualInsertion("a", in: markedCorrected)
      check("no word adopted after \(delimiter)", marked.correction(
        in: context("nicht" + delimiter + "a", document: document), provider: provider) == nil)
    }
    var (other, otherContext) = typed("nciht", document: document)
    check("other punctuation does not correct", other.correction(
      in: otherContext, provider: provider, delimiter: ";") == nil)

    // A space typed before ? ! . , goes; only a single one, right after a word.
    func removes(_ before: String?, _ mark: String = "?", selection: String? = nil) -> Bool {
      KeyboardAutocorrection.removesSpace(before: mark, in: KeyboardCorrectionContext(
        document: document, before: before, after: nil, selection: selection, allowed: true))
    }
    for mark in ["?", "!", ".", ","] {
      check("space before \(mark) goes", removes("nicht ", mark))
    }
    check("space after a digit goes", removes("Seite 5 ", ","))
    check("other marks keep the space", !removes("nicht ", ";") && !removes("nicht ", ":"))
    check("two spaces stay", !removes("nicht  "))
    check("space after punctuation stays", !removes("Liste - ") && !removes("nicht. "))
    check("no space, nothing to remove", !removes("nicht") && !removes(" ") && !removes(""))
    check("unknown left context keeps the space", !removes(nil))
    check("selection keeps the space", !removes("nicht ", selection: "x"))

    // The provider's letters (its selected languages) bound what the state machine corrects.
    var englishOnly = typed("Mädcehn", document: document)
    check("english-only selection leaves umlaut word", englishOnly.0.correction(
      in: englishOnly.1, provider: SelectionProvider(
        words: ["Mädchen"], letters: KeyboardCorrectionLanguage.letters(of: [english]))) == nil)
    var germanOnly = typed("Mädcehn", document: document)
    let germanEdit = germanOnly.0.correction(
      in: germanOnly.1, provider: SelectionProvider(
        words: ["Mädchen"], letters: KeyboardCorrectionLanguage.letters(of: [german])))
    check("german selection corrects umlaut word", germanEdit?.replacement == "Mädchen")
    userDictionaryChecks(document: document)
    frequencyAndContractionChecks(document: document)
    contextChecks()
    if failed > 0 {
      print("Keyboard autocorrection: \(failed) of \(count) checks failed")
      exit(1)
    }
    print("Keyboard autocorrection: \(count) checks passed")
  }
}
