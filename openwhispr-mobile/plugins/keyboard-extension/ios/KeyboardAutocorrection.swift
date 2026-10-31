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

  static func replacement(for word: String, suggestions: [String],
                          letters: Set<Character> = KeyboardCorrectionRules.defaultLetters) -> String? {
    guard isWord(word, letters: letters) else { return nil }
    let source = Array(word)
    let candidates = Set(suggestions).filter { candidate in
      guard isWord(candidate, letters: letters),
            (word == word.lowercased()) == (candidate == candidate.lowercased()) else { return false }
      let target = Array(candidate)
      if source.count == target.count {
        let changed = source.indices.filter { source[$0] != target[$0] }
        // Adjacent swaps may now include the first or last letter, even in short words.
        if changed.count == 2, changed[1] == changed[0] + 1,
           source[changed[0]] == target[changed[1]], source[changed[1]] == target[changed[0]] {
          return true
        }
        // Still avoid ordinary substitutions in very short words.
        return source.count >= 4 && changed.count == 1
      }
      guard min(source.count, target.count) >= 4,
            abs(source.count - target.count) == 1 else { return false }
      let longer = source.count > target.count ? source : target
      let shorter = source.count > target.count ? target : source
      // One extra/missing Character, not a UTF-16 code unit. Check only the first
      // mismatch; skipping any other position cannot make the two sequences equal.
      let mismatch = shorter.indices.first { longer[$0] != shorter[$0] } ?? shorter.count
      var withoutExtra = longer
      withoutExtra.remove(at: mismatch)
      return withoutExtra == shorter
    }
    // Ambiguous nearby words remain untouched, irrespective of provider ranking.
    return candidates.count == 1 ? candidates.first : nil
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
