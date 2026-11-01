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
    check("two-letter words get nothing but their swap", KeyboardCorrectionRules.replacement(
      for: "qm", suggestions: ["am", "im"]) == nil)
    check("swapped", KeyboardCorrectionRules.swapped("os") == "so" && KeyboardCorrectionRules.swapped("Mi") == "Im")
    check("swappable", KeyboardCorrectionRules.isSwappable("mi") && KeyboardCorrectionRules.isSwappable("Os"))
    check("a double letter isn't swappable", !KeyboardCorrectionRules.isSwappable("aa"))
    check("all caps isn't swappable", !KeyboardCorrectionRules.isSwappable("OS"))
    check("one or three letters aren't swappable",
          !KeyboardCorrectionRules.isSwappable("a") && !KeyboardCorrectionRules.isSwappable("abc"))
    check("digits aren't swappable", !KeyboardCorrectionRules.isSwappable("a1"))
    check("umlauts only with German", KeyboardCorrectionRules.isSwappable("üb")
      && !KeyboardCorrectionRules.isSwappable("üb", letters: KeyboardCorrectionLanguage.letters(of: [.english])))
    var (swapState, swapContext) = typed("mi", prefix: "ich bin ", document: document)
    check("a two-letter word is tracked and swapped", swapState.correction(
      in: swapContext, provider: StubProvider(words: ["im"]))?.replacement == "im")

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

    // ? and ! correct like space and stay after the replacement.
    for delimiter in ["?", "!", ".", ","] {
      var (marked, markedContext) = typed("nciht", document: document)
      let markedEdit = marked.correction(in: markedContext, provider: provider, delimiter: delimiter)
      check("\(delimiter) corrects", markedEdit?.replacement == "nicht" && markedEdit?.delimiter == delimiter)
      marked.didCorrect(markedEdit!)
      let markedCorrected = context("nicht" + delimiter, document: document)
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
    if failed > 0 {
      print("Keyboard autocorrection: \(failed) of \(count) checks failed")
      exit(1)
    }
    print("Keyboard autocorrection: \(count) checks passed")
  }
}
