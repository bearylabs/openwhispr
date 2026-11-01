import Foundation

/// No UIKit here: the host's freshly read context, never the word buffer, authorizes edits.
struct KeyboardCorrectionContext: Equatable {
  let document: UUID
  let before: String?
  let after: String?
  let selection: String?
  let allowed: Bool

  // UIKit may report nil after the cursor at end-of-document. Missing LEFT context
  // still prevents replacement; nil and empty right/selection reports are equivalent.
  var isSafe: Bool { allowed && before != nil && (selection ?? "").isEmpty }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.document == rhs.document && lhs.before == rhs.before
      && (lhs.after ?? "") == (rhs.after ?? "")
      && (lhs.selection ?? "") == (rhs.selection ?? "") && lhs.allowed == rhs.allowed
  }

  static func reported(document: UUID, before: String?, after: String?, selection: String?,
                       allowed: Bool, hasText: Bool) -> Self {
    // Only a genuinely empty field can seed tracking without left context. Never infer
    // that our previous insert landed from a buffer, or normalize an opaque nonempty field.
    let readableBefore = before ?? (!hasText && (after ?? "").isEmpty ? "" : nil)
    return Self(document: document, before: readableBefore, after: after,
                selection: selection, allowed: allowed)
  }

  func inserting(_ text: String) -> Self {
    Self(document: document, before: before.map { $0 + text }, after: after,
         selection: selection, allowed: allowed)
  }
}

/// A language the keyboard can correct. `code` is what the app's Settings write to the App
/// Group (`src/lib/keyboardAutocorrection.ts` lists the same codes); `dictionaries` are
/// UITextChecker identifiers in order of preference, then any `<code>_`/`<code>-` variant;
/// `letters` are the lowercase letters a correctable word of this language may use.
struct KeyboardCorrectionLanguage: Equatable {
  let code: String
  let dictionaries: [String]
  let letters: Set<Character>
  /// The language's common two-letter words (and interjections): a two-letter word is swapped
  /// only into one of these, and never when it is one itself (`na`, `eh` stay).
  var twoLetterWords: Set<String> = []
  /// Further two-letter words that are never swapped but aren't swapped into either (`hä`
  /// stays, and `äh` never becomes it).
  var keptTwoLetterWords: Set<String> = []

  private static let latin = Set("abcdefghijklmnopqrstuvwxyz")
  static let german = Self(code: "de", dictionaries: ["de_DE", "de-DE", "de"],
                           letters: latin.union("äöüß"),
                           twoLetterWords: ["ab", "ah", "am", "an", "da", "du", "eh", "er", "es", "ha",
                                            "im", "in", "ja", "je", "na", "ne", "nö", "ob", "oh", "ok",
                                            "so", "um", "wo", "zu", "äh"],
                           keptTwoLetterWords: ["hä", "ma", "ey", "yo", "ui", "en", "ho", "km", "zb", "dh",
                                                "ca", "jo", "mo", "di", "sa", "st", "nr", "hm", "mh",
                                                "eu", "ex", "co", "do", "dr", "kb", "et", "ag", "mg",
                                                "ms", "dl", "hr", "eg", "ph", "pr", "ip", "lb", "dj",
                                                "hp", "bw", "ps", "gb"])
  static let english = Self(code: "en", dictionaries: ["en_US", "en-US", "en_GB", "en-GB", "en"],
                            letters: latin,
                            twoLetterWords: ["ah", "am", "an", "as", "at", "be", "by", "do", "eh", "go",
                                             "ha", "he", "hi", "if", "in", "is", "it", "me", "my", "no",
                                             "of", "oh", "ok", "on", "or", "so", "to", "uh", "um", "up",
                                             "us", "we"],
                            keptTwoLetterWords: ["ad", "em", "ew", "ho", "ma", "ow", "pa", "ta", "ya",
                                                 "ye", "yo", "ox", "mu", "re", "hm", "mh", "st", "co",
                                                 "ex", "eu", "id", "uk", "mg", "ms", "dl", "hr", "eg",
                                                 "mr", "ph", "pr", "ip", "lb", "dj", "hp", "bw", "ps",
                                                 "gb", "md", "mt", "nl", "kt", "ft"])
  /// Adding a language: an entry here, its code in the app's list, and tests.
  static let all = [german, english]
  static let defaultSelection = [german, english]
  /// Each language is another lookup at every space; matches the app's cap.
  static let maxSelected = 3

  /// Parses the App Group value ("de,en"). Unknown codes are ignored, duplicates dropped and
  /// the list capped; nothing usable (missing key, no Full Access) means the default.
  static func selection(from raw: String?) -> [KeyboardCorrectionLanguage] {
    var picked: [KeyboardCorrectionLanguage] = []
    for part in (raw ?? "").split(separator: ",") {
      let code = part.trimmingCharacters(in: .whitespaces).lowercased()
      if let language = all.first(where: { $0.code == code }), !picked.contains(language),
         picked.count < maxSelected {
        picked.append(language)
      }
    }
    return picked.isEmpty ? defaultSelection : picked
  }

  static func letters(of languages: [KeyboardCorrectionLanguage]) -> Set<Character> {
    languages.reduce(into: Set<Character>()) { $0.formUnion($1.letters) }
  }
}

protocol KeyboardCorrectionProvider {
  func suggestions(for word: String) -> [String]
  /// `before` is the field's text before the word (for the sentence's language); never logged.
  func suggestions(for word: String, before: String) -> [String]
  /// The letters of the languages it corrects; words with any other letter are left alone.
  var letters: Set<Character> { get }
  /// How common a proposal is (0 = most common), or nil when unknown.
  func frequencyRank(of candidate: String) -> Int?
}

extension KeyboardCorrectionProvider {
  func suggestions(for word: String, before: String) -> [String] { suggestions(for: word) }
  var letters: Set<Character> { KeyboardCorrectionRules.defaultLetters }
  func frequencyRank(of candidate: String) -> Int? { nil }
}

enum KeyboardCorrectionRules {
  static let defaultLetters = KeyboardCorrectionLanguage.letters(
    of: KeyboardCorrectionLanguage.defaultSelection)

  // Deliberately narrow: the selected languages' letters, no identifiers, mixed case, combining
  // marks, punctuation, emoji, digits, or capitalization changes. Character indexing, not UTF-16.
  static func isWord(_ word: String,
                     letters: Set<Character> = KeyboardCorrectionRules.defaultLetters) -> Bool {
    let lower = word.lowercased()
    return (3...20).contains(word.count)
      && lower.allSatisfy { letters.contains($0) }
      && word.unicodeScalars.count == word.count
      && (word == lower || word == String(lower.prefix(1)).uppercased() + lower.dropFirst())
  }

  /// A two-letter word whose only correction is swapping its letters (`mi` → `im`, `os` →
  /// `so`, `Si` → `Is`): two different letters of the selected languages, lowercase or with a
  /// capital first letter.
  static func isSwappable(_ word: String,
                          letters: Set<Character> = KeyboardCorrectionRules.defaultLetters) -> Bool {
    let characters = Array(word.lowercased())
    return characters.count == 2 && word.unicodeScalars.count == 2 && characters[0] != characters[1]
      && characters.allSatisfy { letters.contains($0) }
      && (word == word.lowercased() || word == capitalized(word.lowercased()))
  }

  /// The two letters swapped, the capital staying first (`Mi` → `Im`).
  static func swapped(_ word: String) -> String {
    let swap = String(word.lowercased().reversed())
    return word == word.lowercased() ? swap : capitalized(swap)
  }

  /// The swap of a two-letter word (`os` → `so`), or nil: the swap must be a common two-letter
  /// word of a language the sentence may be in (`sentence`), and the typed word none of any
  /// selected language. A dictionary knowing the typed word doesn't stop it (English knows
  /// `os`); the lists keep the words people really type (`na`, `eh`, `oh`).
  static func twoLetterSwap(of word: String, sentence: [KeyboardCorrectionLanguage],
                            selected: [KeyboardCorrectionLanguage]) -> String? {
    let typed = word.lowercased(), swap = swapped(typed)
    guard selected.allSatisfy({ !$0.twoLetterWords.contains(typed) && !$0.keptTwoLetterWords.contains(typed) }),
          sentence.contains(where: { $0.twoLetterWords.contains(swap) }) else { return nil }
    return swapped(word)
  }

  /// The word with one letter on a neighbouring key (`ia` → `is`, `ja`, …), the capital kept.
  static func twoLetterSlips(of word: String) -> [String] {
    let characters = Array(word)
    let titleCase = word != word.lowercased()
    var result: [String] = []
    for index in characters.indices {
      for neighbor in (keyNeighbors[Character(characters[index].lowercased())] ?? []).sorted() {
        var variant = characters
        variant[index] = index == 0 && titleCase ? Character(neighbor.uppercased()) : neighbor
        result.append(String(variant))
      }
    }
    return result
  }

  /// A two-letter word with one neighbouring-key slip (`ia` → `is` in an English sentence,
  /// `zi` → `zu`), or nil: exactly one of its slips must be a common two-letter word of the
  /// sentence's language (of any selected one when the sentence has none; `ia` at a sentence
  /// start, `is` or `ja`, stays), and the typed word none of any selected language. The provider
  /// also requires that no selected dictionary knows the typed word.
  static func twoLetterSlip(of word: String, sentence: [KeyboardCorrectionLanguage],
                            selected: [KeyboardCorrectionLanguage]) -> String? {
    let typed = word.lowercased()
    guard selected.allSatisfy({ !$0.twoLetterWords.contains(typed) && !$0.keptTwoLetterWords.contains(typed) })
    else { return nil }
    let targets = Set(twoLetterSlips(of: word).filter { slip in
      sentence.contains { $0.twoLetterWords.contains(slip.lowercased()) }
    })
    return targets.count == 1 ? targets.first : nil
  }

  /// Keeps `candidates` that aren't words German accepts only as a possible compound
  /// (`isCompoundLike`, e.g. `Ichhabe` for the typo `Ichhaeb`); for each one that is, its
  /// common two-word splits (`splits`) take its place (`Ich habe`).
  static func repairingCompounds(_ candidates: [String], isCompoundLike: (String) -> Bool,
                                 splits: (String) -> [String]) -> [String] {
    var result: [String] = []
    for candidate in candidates {
      let replacements = isCompoundLike(candidate) ? splits(candidate) : [candidate]
      for replacement in replacements where !result.contains(replacement) { result.append(replacement) }
    }
    return result
  }

  /// German accepts almost any capitalised word as a possible compound noun, so `Ichhabe` and
  /// `Moeglichkwitne` at the start of a sentence pass its misspelling check. Such a word is
  /// treated as a typo only when German is selected and accepts it, no other selected language
  /// does, it isn't a common word (no rank), and every dictionary flags it in lowercase (so
  /// `Erleben`, `Einmal` and `Haus` stay). Each check is one lookup, made only while
  /// `shouldStop` allows it.
  static func acceptedOnlyAsCompound(
    _ word: String, shouldStop: () -> Bool = { false },
    germanKnows: (String) -> Bool, othersKnow: (String) -> Bool, isRanked: (String) -> Bool,
    lowercaseFlaggedEverywhere: (String) -> Bool
  ) -> Bool {
    let lower = word.lowercased()
    guard word != lower, word == capitalized(lower) else { return false }
    guard !shouldStop(), germanKnows(word), !shouldStop(), !othersKnow(word), !shouldStop(),
          !isRanked(word), !shouldStop(), lowercaseFlaggedEverywhere(lower) else { return false }
    return !shouldStop()
  }

  /// The only first words a compound-like word is split into: German subject pronouns
  /// (`Ichhabe` → `Ich habe`), so a real compound such as `Morgenrot` is never cut in two.
  static let compoundSplitSubjects: Set<String> = ["ich", "du", "er", "es", "wir", "ihr", "sie", "man"]

  /// Whether a compound-like word may become `candidate`: two words with a pronoun first
  /// (`Ich habe`), or a word that begins like one of the typed word's respellings up to and
  /// including an ä/ö/ü/ß it spelled as ae/oe/ue/ss (`Moeglichkwitne` → `möglichk…` →
  /// `Möglichkeiten`), so typing that letter without its umlaut is the evidence of a typo.
  /// An unrelated pair is no evidence (`Feuerwache` never becomes `Feuerwächter`).
  static func isCompoundCorrection(_ candidate: String, of word: String,
                                   letters: Set<Character> = KeyboardCorrectionRules.defaultLetters) -> Bool {
    if let (left, _) = splitParts(of: candidate, letters: letters) {
      return compoundSplitSubjects.contains(left.lowercased())
    }
    let special: Set<Character> = ["ä", "ö", "ü", "ß"]
    let typed = Set(word.lowercased())
    let target = Array(candidate.lowercased())
    return transcriptions(of: word).contains { respelling in
      // The candidate and the respelling agree up to and including a letter the respelling
      // introduced.
      for (index, letter) in Array(respelling.word.lowercased()).enumerated() {
        guard index < target.count, target[index] == letter else { return false }
        if special.contains(letter) && !typed.contains(letter) { return true }
      }
      return false
    }
  }

  // The keyboard's own letter rows (KeyboardViewController.letterRows), centred as drawn:
  // the middle row half a key in, the bottom row a whole key in (shift sits beside it).
  private static let keyRows: [(keys: String, offset: Double)] = [
    ("qwertyuiop", 0), ("asdfghjkl", 0.5), ("zxcvbnm", 1.5),
  ]

  private static let keyCentres: [Character: (row: Int, x: Double)] = {
    var centres: [Character: (row: Int, x: Double)] = [:]
    for (row, line) in keyRows.enumerated() {
      for (index, key) in line.keys.enumerated() { centres[key] = (row, Double(index) + line.offset) }
    }
    return centres
  }()

  /// Keys that touch on the drawn layout: either side in a row, and the keys of the next row
  /// that overlap it (two from the top rows, the one straight below/above for the bottom row).
  static let keyNeighbors: [Character: Set<Character>] = {
    var neighbors: [Character: Set<Character>] = [:]
    for (key, a) in keyCentres {
      neighbors[key] = Set(keyCentres.compactMap { other, b in
        guard other != key else { return nil }
        let dx = abs(a.x - b.x)
        if a.row == b.row { return dx == 1 ? other : nil }
        return abs(a.row - b.row) == 1 && dx < 1 ? other : nil
      })
    }
    return neighbors
  }()

  static func areNeighborKeys(_ a: Character, _ b: Character) -> Bool {
    let lowerA = Character(a.lowercased()), lowerB = Character(b.lowercased())
    return keyNeighbors[lowerA]?.contains(lowerB) == true
  }

  /// How many letters the neighbouring-key search replaces: one in three-letter words, two in
  /// four-letter words, three from five letters on.
  static func maxNeighborSlips(forLength length: Int) -> Int {
    length >= 5 ? 3 : length == 4 ? 2 : length == 3 ? 1 : 0
  }

  // Edit weights, tuned with the frequency weight below on the 50,000 most common German and
  // English words and random typos (70% sideways). A slip sideways in a row is the commonest
  // typo; a slip to the row above or below less likely; a letter for its umlaut (a↔ä, o↔ö, u↔ü, s↔ß) counts like a
  // slip; any other wrong key costs two edits. A swap of adjacent letters costs one, a missing
  // or extra letter one and a half (otherwise dropping a letter of a common short word wins
  // too often).
  static let rowSlipCost = 1.0
  static let insertDeleteCost = 1.5
  static let diagonalSlipCost = 1.5
  static let otherLetterCost = 2.0
  private static let umlauts: Set<String> = ["aä", "äa", "oö", "öo", "uü", "üu", "sß", "ßs"]

  static func substitutionCost(_ a: Character, _ b: Character) -> Double {
    let lowerA = Character(a.lowercased()), lowerB = Character(b.lowercased())
    if lowerA == lowerB { return 0 }
    if umlauts.contains(String([lowerA, lowerB])) { return rowSlipCost }
    guard keyNeighbors[lowerA]?.contains(lowerB) == true,
          let centreA = keyCentres[lowerA], let centreB = keyCentres[lowerB] else { return otherLetterCost }
    return centreA.row == centreB.row ? rowSlipCost : diagonalSlipCost
  }

  /// The most edit weight a word may need: one slip (diagonal included) in three letters; two
  /// slips in four letters (not two diagonal ones); three in five or six letters (at most two
  /// diagonal); four from seven letters on. A wrong far-away letter counts as two slips.
  static func maxEditCost(forLength length: Int) -> Double {
    switch length {
    case ..<3: return 0
    case 3: return 1.5
    case 4: return 2.5
    case 5, 6: return 4.0
    default: return 5.0
    }
  }

  /// Weighted edit distance (optimal string alignment: substitutions by key distance,
  /// insertions, deletions, swaps of adjacent letters, and ae/oe/ue/ss typed for ä/ö/ü/ß), or
  /// nil when the words are equal or further apart than `maxEditCost` allows for the typed word.
  /// The respelling step lets German typed without umlauts carry typos as well
  /// (`moeglichkwitne` → `Möglichkeiten`: ö, a slip and a swap).
  static func editCost(from word: String, to candidate: String) -> Double? {
    let source = Array(word), target = Array(candidate)
    let limit = maxEditCost(forLength: source.count)
    // Each letter the candidate is shorter by costs at least a respelling, each it is longer by
    // an insertion.
    let lengthCost = source.count > target.count ? umlautTranscriptionCost : insertDeleteCost
    guard source != target,
          Double(abs(source.count - target.count)) * lengthCost <= limit + 1e-9 else { return nil }
    var table = Array(repeating: Array(repeating: 0.0, count: target.count + 1), count: source.count + 1)
    for i in 0...source.count { table[i][0] = Double(i) * insertDeleteCost }
    for j in 0...target.count { table[0][j] = Double(j) * insertDeleteCost }
    for i in stride(from: 1, through: source.count, by: 1) {
      for j in stride(from: 1, through: target.count, by: 1) {
        var best = min(table[i - 1][j] + insertDeleteCost, table[i][j - 1] + insertDeleteCost,
                       table[i - 1][j - 1] + substitutionCost(source[i - 1], target[j - 1]))
        if i > 1, j > 1, source[i - 1] == target[j - 2], source[i - 2] == target[j - 1] {
          best = min(best, table[i - 2][j - 2] + 1)
        }
        if i > 1, let respelling = transcriptionCost(source[i - 2], source[i - 1], for: target[j - 1]) {
          best = min(best, table[i - 2][j - 1] + respelling)
        }
        table[i][j] = best
      }
    }
    let cost = table[source.count][target.count]
    return cost <= limit + 1e-9 ? cost : nil
  }

  /// 0.3 edits per doubling of a word's frequency rank: a common word wins over a rarer one
  /// that is slightly closer (`hsbd` → `habe` rather than `hand` or `habs`). Tuned with the
  /// edit weights above on mixed typos (slips, swaps, missing and extra letters). An unknown rank
  /// counts as fairly rare, so between unranked words the edit cost decides.
  static let frequencyWeight = 0.3
  static let unrankedFrequencyRank = 20_000

  static func score(cost: Double, rank: Int?) -> Double {
    cost + frequencyWeight * log2(Double(min(rank ?? unrankedFrequencyRank, unrankedFrequencyRank)) + 1)
  }

  // German spelled without its special letters: ae/oe/ue for ä/ö/ü (Ae/Oe/Ue at the start of
  // a capitalised word) and ss for ß. Each pair is a choice, so `Gruesse` yields `Grüsse`,
  // `Grueße` and `Grüße`. ß costs a little more than an umlaut, since ss is often right.
  static let umlautTranscriptionCost = 0.3
  static let eszettTranscriptionCost = 0.5
  private static let transcriptionPairs: [(pair: String, letter: Character, cost: Double)] = [
    ("ae", "ä", umlautTranscriptionCost), ("oe", "ö", umlautTranscriptionCost),
    ("ue", "ü", umlautTranscriptionCost), ("ss", "ß", eszettTranscriptionCost),
  ]
  /// More pairs than this in one word are left alone (2^6 spellings at most).
  static let maxTranscriptionPairs = 6

  /// The cost of typing `first` and `second` for `letter` (`o`, `e` for `ö`; `s`, `s` for
  /// `ß`), case-insensitively, or nil when they don't spell it.
  private static func transcriptionCost(_ first: Character, _ second: Character,
                                        for letter: Character) -> Double? {
    let pair = (String(first) + String(second)).lowercased()
    let lower = Character(letter.lowercased())
    return transcriptionPairs.first { $0.pair == pair && $0.letter == lower }?.cost
  }

  /// A word typed without the space between two words (`ichhabe` → `ich habe`) costs like a
  /// wrong key beside the right one.
  static let splitCost = 1.0

  /// The two words of a candidate with one space (`ich habe`), each of two letters or more and
  /// only the selected languages' letters; nil for anything else.
  static func splitParts(of candidate: String,
                         letters: Set<Character> = KeyboardCorrectionRules.defaultLetters) -> (String, String)? {
    let parts = candidate.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, parts.allSatisfy({ part in
      let lower = part.lowercased()
      return part.count >= 2 && lower.allSatisfy { letters.contains($0) }
        && part.unicodeScalars.count == part.count
        && (part == lower || part == capitalized(lower))
    }) else { return nil }
    return (parts[0], parts[1])
  }

  /// Both words of a split must be at most this far down the completions of their first two
  /// letters (`frequencyRank`), i.e. common words; a rarer one is never split off.
  static let maxSplitRank = 100

  /// Every way to cut `word` into two words of two letters or more (`ichhabe` → `ich habe`)
  /// that `isCommonSplit` accepts, as candidates with a space. A search cut short by
  /// `shouldStop` gives nothing, since the cut it didn't reach could be the better one.
  static func splitCandidates(for word: String, shouldStop: () -> Bool = { false },
                              isCommonSplit: (_ left: String, _ right: String) -> Bool) -> [String] {
    let characters = Array(word)
    guard characters.count >= 4 else { return [] }
    var found: [String] = []
    for cut in 2...(characters.count - 2) {
      if shouldStop() { return [] }
      let left = String(characters[..<cut]), right = String(characters[cut...])
      if isCommonSplit(left, right) { found.append(left + " " + right) }
    }
    return shouldStop() ? [] : found
  }

  /// Whether `left` and `right` are two words for one typed without its space: both known as
  /// typed in the same dictionary and ranked there within `maxSplitRank`. Checks the deadline
  /// before each lookup and answers false once it has passed.
  static func isCommonSplit<Language>(
    _ left: String, _ right: String, in dictionaries: [Language],
    shouldStop: () -> Bool = { false },
    isKnown: (_ word: String, _ dictionary: Language) -> Bool,
    rank: (_ word: String, _ dictionary: Language) -> Int?
  ) -> Bool {
    for dictionary in dictionaries {
      if shouldStop() { return false }
      guard isKnown(left, dictionary), !shouldStop(), isKnown(right, dictionary), !shouldStop(),
            (rank(left, dictionary).map { $0 <= maxSplitRank } ?? false), !shouldStop(),
            (rank(right, dictionary).map { $0 <= maxSplitRank } ?? false) else { continue }
      return !shouldStop()
    }
    return false
  }

  /// Long words whose end went wrong are found among the completions of their start
  /// (`möglichk` → `Möglichkeiten`). The prefixes to try, longest first, for the word as typed
  /// and, before it, its German respellings (most pairs replaced first; `maxCompletionForms`
  /// forms in all): from one letter short down to half the word, five letters
  /// at least. Nothing for words under `minCompletionLength` letters.
  static let minCompletionLength = 7
  static let maxCompletionForms = 4
  /// At most this many of a prefix's completions are scored, in Apple's order (likeliest first).
  static let maxCompletions = 40
  /// Shorter prefixes are tried after this many that completed to nothing close enough.
  static let maxCompletingPrefixes = 3

  /// Words completing the start of a long word (`completionPrefixes`) that are close enough to
  /// it (`editCost`) to be scored: per spelling, the longest prefix that completes to one wins.
  /// `complete` returns a prefix's completions. A title-case word keeps its capital. A search
  /// cut short by `shouldStop` gives nothing.
  static func completionCandidates(for word: String, respell: Bool,
                                   shouldStop: () -> Bool = { false },
                                   complete: (_ prefix: String) -> [String]) -> [String] {
    let titleCase = word != word.lowercased()
    var found: [String] = []
    for prefixes in completionPrefixes(of: word, respell: respell) {
      var completing = 0
      for prefix in prefixes {
        if shouldStop() { return [] }
        let completions = complete(prefix)
        if shouldStop() { return [] }
        guard !completions.isEmpty else { continue }
        var matched = false
        for completion in completions.prefix(maxCompletions) {
          if shouldStop() { return [] }
          let candidate = titleCase ? capitalized(completion) : completion
          guard editCost(from: word, to: candidate) != nil else { continue }
          matched = true
          if !found.contains(candidate) { found.append(candidate) }
        }
        completing += 1
        if matched || completing >= maxCompletingPrefixes { break }
      }
    }
    return shouldStop() ? [] : found
  }

  static func completionPrefixes(of word: String, respell: Bool) -> [[String]] {
    guard word.count >= minCompletionLength else { return [] }
    let respellings = respell
      ? transcriptions(of: word).sorted { $0.pairs > $1.pairs }.map { $0.word } : []
    return (respellings.prefix(maxCompletionForms - 1) + [word]).map { form in
      let characters = Array(form)
      let shortest = max(5, (characters.count + 1) / 2)
      guard characters.count - 1 >= shortest else { return [] }
      return stride(from: characters.count - 1, through: shortest, by: -1).map {
        String(characters[..<$0])
      }
    }
  }

  /// The language of the words before the cursor: the code of the only language that knows
  /// some of the last eight words (two letters or more) that the others don't, or nil when
  /// none or several do (`ich habe` → de, `I have` → en, `so` → nil, `ich have` → nil).
  static func sentenceLanguage(before: String, codes: [String],
                               knows: (_ word: String, _ code: String) -> Bool) -> String? {
    let words = before.split { !$0.isLetter }.suffix(8).map(String.init).filter { $0.count >= 2 }
    var only = Set<String>()
    for word in words {
      let knownBy = codes.filter { knows(word, $0) || knows(word.lowercased(), $0) }
      if knownBy.count == 1 { only.insert(knownBy[0]) }
    }
    return only.count == 1 ? only.first : nil
  }

  static func capitalized(_ word: String) -> String {
    word.prefix(1).uppercased() + word.dropFirst()
  }

  /// Every respelling of `word` with at least one pair replaced, its cost and how many pairs
  /// it replaced.
  static func transcriptions(of word: String) -> [(word: String, cost: Double, pairs: Int)] {
    let characters = Array(word)
    var sites: [(index: Int, letter: Character, cost: Double)] = []
    var index = 0
    while index < characters.count - 1 {
      let pair = String(characters[index...index + 1])
      let lower = pair.lowercased()
      // Only a lowercase pair, or Ae/Oe/Ue opening a capitalised word (never ss there).
      if let match = transcriptionPairs.first(where: { $0.pair == lower }),
         pair == lower || (index == 0 && pair == lower.prefix(1).uppercased() + lower.dropFirst()
                           && match.letter != "ß") {
        let letter = pair == lower ? match.letter : Character(match.letter.uppercased())
        sites.append((index, letter, match.cost))
        index += 2
      } else {
        index += 1
      }
    }
    guard !sites.isEmpty, sites.count <= maxTranscriptionPairs else { return [] }
    var result: [(word: String, cost: Double, pairs: Int)] = []
    for mask in 1..<(1 << sites.count) {
      var output: [Character] = []
      var cost = 0.0
      var pairs = 0
      var position = 0
      for (bit, site) in sites.enumerated() where mask & (1 << bit) != 0 {
        output += characters[position..<site.index]
        output.append(site.letter)
        cost += site.cost
        pairs += 1
        position = site.index + 2
      }
      output += characters[position...]
      result.append((String(output), cost, pairs))
    }
    return result
  }

  /// The eligible candidate with the lowest score (edit cost plus frequency); a tie goes to the
  /// earliest in `suggestions`. A candidate that is the word's own spelling with ä/ö/ü/ß
  /// (`schoen` → `schön`, `Strasse` → `Straße`) wins over every other: typing an unknown word
  /// whose umlaut spelling is a word almost always means that word. Among those, the one
  /// replacing the most pairs wins (`gruesse` → `grüße`, not the Swiss `grüsse`). More corrections, at the
  /// risk of picking the wrong word of two; backspace right after undoes it.
  static func replacement(for word: String, suggestions: [String],
                          letters: Set<Character> = KeyboardCorrectionRules.defaultLetters,
                          rank: (String) -> Int? = { _ in nil }) -> String? {
    // A two-letter word only ever becomes its swap (`mi` → `im`) or a one-key slip (`ia` → `is`).
    if isSwappable(word, letters: letters) {
      let allowed = [swapped(word)] + twoLetterSlips(of: word)
      return suggestions.first { allowed.contains($0) }
    }
    guard isWord(word, letters: letters) else { return nil }
    // A lowercase respelling may also come capitalised: German nouns (`strasse` → `Straße`).
    let respellings = Dictionary(transcriptions(of: word).flatMap { respelling in
      [(respelling.word, (respelling.cost, respelling.pairs)),
       (capitalized(respelling.word), (respelling.cost, respelling.pairs))]
    }, uniquingKeysWith: { $0.0 <= $1.0 ? $0 : $1 })
    var best: (word: String, score: Double, pairs: Int)?
    var seen = Set<String>()
    for candidate in suggestions where seen.insert(candidate).inserted {
      if candidate.contains(" ") {
        // Two words for one typed without its space: both must be common words (ranked within
        // `maxSplitRank`), so a rare word is never cut off, and the second stays lowercase, so
        // a German noun is never split off an unknown compound (`dashaus` stays, even when
        // UITextChecker proposes `das Haus`). The rarer word's rank counts, and the missing
        // space counts towards the edit budget.
        guard let (left, right) = splitParts(of: candidate, letters: letters),
              right == right.lowercased(),
              word == word.lowercased() || left != left.lowercased(),
              let leftRank = rank(left), let rightRank = rank(right),
              max(leftRank, rightRank) <= maxSplitRank,
              let joinedCost = left + right == word
                ? 0 : editCost(from: word, to: left + right),
              joinedCost + splitCost <= maxEditCost(forLength: word.count) + 1e-9 else { continue }
        let candidateScore = score(cost: joinedCost + splitCost, rank: max(leftRank, rightRank))
        if best == nil || (best!.pairs == 0 && candidateScore < best!.score - 1e-9) {
          best = (candidate, candidateScore, 0)
        }
        continue
      }
      let respelled = respellings[candidate]
      // A capitalised word keeps its capital; a lowercase one may gain one (a German noun:
      // the provider only offers capitalised proposals for lowercase words that are nouns).
      guard isWord(candidate, letters: letters),
            word == word.lowercased() || candidate != candidate.lowercased() else { continue }
      guard let cost = respelled?.0 ?? editCost(from: word, to: candidate) else { continue }
      let candidateScore = score(cost: cost, rank: rank(candidate))
      let pairs = respelled?.1 ?? 0
      if best == nil || pairs > best!.pairs
          || (pairs == best!.pairs && candidateScore < best!.score - 1e-9) {
        best = (candidate, candidateScore, pairs)
      }
    }
    return best?.word
  }

  /// Known words made by replacing up to `maxSlips` letters of `word` with neighbouring keys,
  /// one level of slips after the other, since a common word with more slips can still win
  /// (`fubktiojiert` → `funktioniert` without UITextChecker proposing it). A level whose
  /// variants would push the total past `budget` lookups is skipped with all after it, and a
  /// level cut short by `shouldStop` is dropped whole: an unfinished level could miss a closer
  /// word than the one it found.
  /// Known words one swap of adjacent letters, one missing letter (from `letters`) or one
  /// extra letter away. UITextChecker usually proposes these but not always (`kalppt` →
  /// `klappt`). The first letter keeps its case, so a title-case word is never edited there.
  static func singleEditCandidates(for word: String, letters: Set<Character>,
                                   shouldStop: () -> Bool = { false },
                                   isKnown: (String) -> Bool) -> [String] {
    let characters = Array(word)
    guard characters.count >= 3 else { return [] }
    let titleCase = word != word.lowercased()
    let start = titleCase ? 1 : 0
    var variants: [[Character]] = []
    for index in start..<(characters.count - 1) where characters[index] != characters[index + 1] {
      var swapped = characters
      swapped.swapAt(index, index + 1)
      variants.append(swapped)
    }
    if characters.count >= 4 {
      for index in start..<characters.count {
        var shorter = characters
        shorter.remove(at: index)
        variants.append(shorter)
      }
    }
    let alphabet = letters.sorted()
    for index in max(start, 1)...characters.count {
      for letter in alphabet {
        var longer = characters
        longer.insert(letter, at: index)
        variants.append(longer)
      }
    }
    var found: [String] = []
    var seen = Set<String>()
    for variant in variants {
      if shouldStop() { return [] }
      let text = String(variant)
      if seen.insert(text).inserted, text != word, isKnown(text) { found.append(text) }
    }
    return found
  }

  static func neighborSlipCandidates(for word: String, maxSlips: Int, budget: Int = 1_500,
                                     shouldStop: () -> Bool = { false },
                                     isKnown: (String) -> Bool) -> [String] {
    let characters = Array(word)
    let limit = min(maxSlips, maxNeighborSlips(forLength: characters.count))
    guard limit > 0 else { return [] }
    let titleCase = word != word.lowercased()
    // Lowercase neighbours per position; the first one is capitalised again for title case.
    let options: [[Character]] = characters.enumerated().map { index, character in
      let lower = Character(character.lowercased())
      return (keyNeighbors[lower] ?? []).sorted().map { neighbor in
        index == 0 && titleCase ? Character(neighbor.uppercased()) : neighbor
      }
    }
    var used = 0
    var result: [String] = []
    for slips in 1...limit {
      var positions = Array(0..<slips)
      var variants = 0
      var combinationsPossible = true
      // Count first, so an oversized level is skipped before any lookup.
      while combinationsPossible {
        variants += positions.reduce(1) { $0 * options[$1].count }
        combinationsPossible = nextCombination(&positions, upTo: characters.count)
      }
      guard used + variants <= budget else { break }
      used += variants
      var found: [String] = []
      positions = Array(0..<slips)
      combinationsPossible = true
      while combinationsPossible {
        var picks = Array(repeating: 0, count: slips)
        var morePicks = positions.allSatisfy { !options[$0].isEmpty }
        while morePicks {
          if shouldStop() { return result }
          var variant = characters
          for (slot, position) in positions.enumerated() { variant[position] = options[position][picks[slot]] }
          let text = String(variant)
          if isKnown(text) { found.append(text) }
          // Next neighbour choice, like an odometer.
          morePicks = false
          for slot in picks.indices.reversed() {
            picks[slot] += 1
            if picks[slot] < options[positions[slot]].count { morePicks = true; break }
            picks[slot] = 0
          }
        }
        combinationsPossible = nextCombination(&positions, upTo: characters.count)
      }
      result += found
    }
    return result
  }

  /// Advances `positions` to the next ascending combination below `count`; false at the end.
  private static func nextCombination(_ positions: inout [Int], upTo count: Int) -> Bool {
    var slot = positions.count - 1
    while slot >= 0 && positions[slot] == count - positions.count + slot { slot -= 1 }
    guard slot >= 0 else { return false }
    positions[slot] += 1
    for next in (slot + 1)..<positions.count { positions[next] = positions[next - 1] + 1 }
    return true
  }
}

struct KeyboardAutocorrection {
  /// Keys that end a word and correct it, like space: the delimiter is typed after the
  /// replacement (`nciht?` → `nicht?`).
  static let delimiters: Set<String> = [" ", "?", "!", ".", ","]
  /// Marks that pull a space typed before them back onto the word (`nicht ?` → `nicht?`).
  static let spaceHuggingMarks: Set<String> = ["?", "!", ".", ","]

  /// Whether typing `mark` should first delete the space before the cursor: one space right
  /// after a letter or digit. Not after other punctuation or several spaces (`Hallo  .`,
  /// `- .`), and never with a selection or unknown left context.
  static func removesSpace(before mark: String, in context: KeyboardCorrectionContext) -> Bool {
    guard spaceHuggingMarks.contains(mark), context.isSafe, let before = context.before,
          before.last == " " else { return false }
    let word = before.dropLast()
    guard let last = word.last else { return false }
    return last.isLetter || last.isNumber
  }

  struct Edit {
    let original: String
    let replacement: String
    let context: KeyboardCorrectionContext
    /// The key that triggered the correction, typed after the replacement.
    var delimiter = " "
  }
  private var expected: KeyboardCorrectionContext?
  private var word = ""
  private var undo: Edit?
  /// When the correction was made (system uptime, seconds), for the undo window.
  private var undoTime: TimeInterval = 0
  private(set) var awaitingHostReport = false
  /// How long backspace undoes a correction; after that it is an ordinary backspace.
  static let undoWindow: TimeInterval = 3
  var hasTrackedWord: Bool { expected != nil && !word.isEmpty }

  mutating func invalidate() {
    expected = nil
    word = ""
    undo = nil
    awaitingHostReport = false
  }

  mutating func hostWillChange() {
    // Do not discard a possible acknowledgement of our own insert. No edit is allowed
    // until the corresponding did-change report matches the complete expected context.
    awaitingHostReport = true
  }

  mutating func hostDidChange(_ context: KeyboardCorrectionContext) {
    guard context.isSafe, expected == context else { invalidate(); return }
    awaitingHostReport = false
  }

  mutating func reconcile(_ context: KeyboardCorrectionContext) {
    guard !awaitingHostReport, context.isSafe, expected == context else { invalidate(); return }
  }

  /// Called before a manual character insert, not for shortcuts, dictation or agent output.
  mutating func manualInsertion(_ text: String, in context: KeyboardCorrectionContext) {
    reconcile(context)
    undo = nil
    guard context.isSafe, text.count == 1, text.first?.isLetter == true else {
      invalidate()
      return
    }
    if word.isEmpty {
      // Never adopt an existing word or something after punctuation (URLs/code/mentions),
      // including the `?`/`!` of a correction (`nicht?abc`).
      guard context.before?.isEmpty == true || context.before?.last?.isWhitespace == true else {
        invalidate()
        return
      }
    }
    word += text
    guard word.count <= 20 else { invalidate(); return }
    expected = context.inserting(text)
  }

  mutating func correction(in context: KeyboardCorrectionContext,
                           provider: KeyboardCorrectionProvider,
                           delimiter: String = " ") -> Edit? {
    reconcile(context)
    let letters = provider.letters
    guard Self.delimiters.contains(delimiter), expected != nil,
          KeyboardCorrectionRules.isWord(word, letters: letters)
            || KeyboardCorrectionRules.isSwappable(word, letters: letters),
          (context.after ?? "").isEmpty || context.after?.first?.isWhitespace == true,
          let replacement = KeyboardCorrectionRules.replacement(
            for: word,
            suggestions: provider.suggestions(
              for: word, before: String((context.before ?? "").dropLast(word.count))),
            letters: letters,
            rank: { provider.frequencyRank(of: $0) }) else { return nil }
    return Edit(original: word, replacement: replacement, context: context, delimiter: delimiter)
  }

  mutating func didCorrect(_ edit: Edit, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    invalidate()
    guard let before = edit.context.before else { return }
    let prefix = String(before.dropLast(edit.original.count))
    expected = KeyboardCorrectionContext(
      document: edit.context.document, before: prefix + edit.replacement + edit.delimiter,
      after: edit.context.after, selection: edit.context.selection, allowed: edit.context.allowed)
    undo = edit
    undoTime = now
  }

  /// Consumed even on failure. After undo, the restored word is deliberately not tracked.
  /// Only within `undoWindow` seconds of the correction; later backspace deletes normally.
  mutating func takeUndo(in context: KeyboardCorrectionContext,
                         at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Edit? {
    reconcile(context)
    let edit = now - undoTime <= Self.undoWindow ? undo : nil
    invalidate()
    return edit
  }
}
