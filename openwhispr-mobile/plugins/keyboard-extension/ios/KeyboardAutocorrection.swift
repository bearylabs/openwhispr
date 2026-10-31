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

  private static let latin = Set("abcdefghijklmnopqrstuvwxyz")
  static let german = Self(code: "de", dictionaries: ["de_DE", "de-DE", "de"],
                           letters: latin.union("äöüß"))
  static let english = Self(code: "en", dictionaries: ["en_US", "en-US", "en_GB", "en-GB", "en"],
                            letters: latin)
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
  /// The letters of the languages it corrects; words with any other letter are left alone.
  var letters: Set<Character> { get }
}

extension KeyboardCorrectionProvider {
  var letters: Set<Character> { KeyboardCorrectionRules.defaultLetters }
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

  // The keyboard's own letter rows (KeyboardViewController.letterRows), centred as drawn:
  // the middle row half a key in, the bottom row a whole key in (shift sits beside it).
  private static let keyRows: [(keys: String, offset: Double)] = [
    ("qwertyuiop", 0), ("asdfghjkl", 0.5), ("zxcvbnm", 1.5),
  ]

  /// Keys that touch on the drawn layout: either side in a row, and the keys of the next row
  /// that overlap it (two from the top rows, the one straight below/above for the bottom row).
  static let keyNeighbors: [Character: Set<Character>] = {
    var centres: [Character: (row: Int, x: Double)] = [:]
    for (row, line) in keyRows.enumerated() {
      for (index, key) in line.keys.enumerated() { centres[key] = (row, Double(index) + line.offset) }
    }
    var neighbors: [Character: Set<Character>] = [:]
    for (key, a) in centres {
      neighbors[key] = Set(centres.compactMap { other, b in
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

  /// How many letters may be neighbouring-key slips: none in three-letter words (`teh` stays
  /// `the`, never `ten`), two in four-letter words, three from five letters on.
  static func maxNeighborSlips(forLength length: Int) -> Int {
    length >= 5 ? 3 : length == 4 ? 2 : 0
  }

  /// The edits from `word` to `candidate`, or nil when it is too far: 1 for a swap of two
  /// adjacent letters, one wrong letter (four letters and up), or one missing or extra letter;
  /// otherwise the number of wrong letters when every one is a neighbouring key.
  static func editCost(from word: String, to candidate: String) -> Int? {
    let source = Array(word), target = Array(candidate)
    if source.count == target.count {
      let changed = source.indices.filter { source[$0] != target[$0] }
      guard !changed.isEmpty else { return nil }
      // Adjacent swaps may include the first or last letter, even in short words.
      if changed.count == 2, changed[1] == changed[0] + 1,
         source[changed[0]] == target[changed[1]], source[changed[1]] == target[changed[0]] {
        return 1
      }
      // Still avoid ordinary substitutions in very short words.
      if source.count >= 4 && changed.count == 1 { return 1 }
      guard changed.count <= maxNeighborSlips(forLength: source.count),
            changed.allSatisfy({ areNeighborKeys(source[$0], target[$0]) }) else { return nil }
      return changed.count
    }
    guard min(source.count, target.count) >= 4,
          abs(source.count - target.count) == 1 else { return nil }
    let longer = source.count > target.count ? source : target
    let shorter = source.count > target.count ? target : source
    // One extra/missing Character, not a UTF-16 code unit. Check only the first
    // mismatch; skipping any other position cannot make the two sequences equal.
    let mismatch = shorter.indices.first { longer[$0] != shorter[$0] } ?? shorter.count
    var withoutExtra = longer
    withoutExtra.remove(at: mismatch)
    return withoutExtra == shorter ? 1 : nil
  }

  static func replacement(for word: String, suggestions: [String],
                          letters: Set<Character> = KeyboardCorrectionRules.defaultLetters) -> String? {
    guard isWord(word, letters: letters) else { return nil }
    var best: (cost: Int, words: Set<String>)?
    for candidate in Set(suggestions) {
      guard isWord(candidate, letters: letters),
            (word == word.lowercased()) == (candidate == candidate.lowercased()),
            let cost = editCost(from: word, to: candidate) else { continue }
      if best == nil || cost < best!.cost {
        best = (cost, [candidate])
      } else if cost == best!.cost {
        best!.words.insert(candidate)
      }
    }
    // The fewest edits win; a tie stays untouched, irrespective of provider ranking.
    guard let best, best.words.count == 1 else { return nil }
    return best.words.first
  }

  /// Words made by replacing letters of `word` with neighbouring keys, fewest slips first:
  /// stops at the first number of slips that finds a known word, so `fubktiojiert` reaches
  /// `funktioniert` without UITextChecker having to propose it. `maxSlips` stops early when a
  /// cheaper proposal is already known. A level whose variants don't fit in `budget` lookups is
  /// dropped whole, since a partial search could miss the rival that makes it ambiguous.
  static func neighborSlipCandidates(for word: String, maxSlips: Int, budget: Int = 2_500,
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
    for slips in 1...limit {
      var positions = Array(0..<slips)
      var variants = 0
      var combinationsPossible = true
      // Count first, so an oversized level is skipped before any lookup.
      while combinationsPossible {
        variants += positions.reduce(1) { $0 * options[$1].count }
        combinationsPossible = nextCombination(&positions, upTo: characters.count)
      }
      guard used + variants <= budget else { return [] }
      used += variants
      var found: [String] = []
      positions = Array(0..<slips)
      combinationsPossible = true
      while combinationsPossible {
        var picks = Array(repeating: 0, count: slips)
        var morePicks = positions.allSatisfy { !options[$0].isEmpty }
        while morePicks {
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
      if !found.isEmpty { return found }
    }
    return []
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
  struct Edit {
    let original: String
    let replacement: String
    let context: KeyboardCorrectionContext
  }
  private var expected: KeyboardCorrectionContext?
  private var word = ""
  private var undo: Edit?
  private(set) var awaitingHostReport = false
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
    if expected == nil {
      // Never adopt an existing word or something after punctuation (URLs/code/mentions).
      guard context.before?.isEmpty == true || context.before?.last?.isWhitespace == true else {
        return
      }
      word = ""
    }
    word += text
    guard word.count <= 20 else { invalidate(); return }
    expected = context.inserting(text)
  }

  mutating func correction(in context: KeyboardCorrectionContext,
                           provider: KeyboardCorrectionProvider) -> Edit? {
    reconcile(context)
    let letters = provider.letters
    guard expected != nil, KeyboardCorrectionRules.isWord(word, letters: letters),
          (context.after ?? "").isEmpty || context.after?.first?.isWhitespace == true,
          let replacement = KeyboardCorrectionRules.replacement(
            for: word, suggestions: provider.suggestions(for: word), letters: letters) else { return nil }
    return Edit(original: word, replacement: replacement, context: context)
  }

  mutating func didCorrect(_ edit: Edit) {
    invalidate()
    guard let before = edit.context.before else { return }
    let prefix = String(before.dropLast(edit.original.count))
    expected = KeyboardCorrectionContext(
      document: edit.context.document, before: prefix + edit.replacement + " ",
      after: edit.context.after, selection: edit.context.selection, allowed: edit.context.allowed)
    undo = edit
  }

  /// Consumed even on failure. After undo, the restored word is deliberately not tracked.
  mutating func takeUndo(in context: KeyboardCorrectionContext) -> Edit? {
    reconcile(context)
    let edit = undo
    invalidate()
    return edit
  }
}
