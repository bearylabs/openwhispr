import Foundation

/// No UIKit here: the host's freshly read context, never the word buffer, authorizes edits.
struct KeyboardCorrectionContext: Equatable {
  let document: UUID
  let before: String?
  let after: String?
  let selection: String?
  let allowed: Bool

  var isSafe: Bool { allowed && before != nil && after != nil && (selection ?? "").isEmpty }

  func inserting(_ text: String) -> Self {
    Self(document: document, before: before.map { $0 + text }, after: after,
         selection: selection, allowed: allowed)
  }
}

protocol KeyboardCorrectionProvider {
  func suggestions(for word: String) -> [String]
}

enum KeyboardCorrectionRules {
  // Deliberately narrow: German letters, no identifiers, mixed case, combining marks,
  // punctuation, emoji, digits, or capitalization changes. Character indexing, not UTF-16.
  static func isWord(_ word: String) -> Bool {
    let lower = word.lowercased()
    let alphabet = Set("abcdefghijklmnopqrstuvwxyzäöüß")
    return (3...20).contains(word.count)
      && lower.allSatisfy { alphabet.contains($0) }
      && word.unicodeScalars.count == word.count
      && (word == lower || word == String(lower.prefix(1)).uppercased() + lower.dropFirst())
  }

  static func replacement(for word: String, suggestions: [String]) -> String? {
    guard isWord(word) else { return nil }
    let source = Array(word)
    let candidates = Set(suggestions).filter { candidate in
      guard isWord(candidate),
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

  mutating func invalidate() {
    expected = nil
    word = ""
    undo = nil
  }

  mutating func reconcile(_ context: KeyboardCorrectionContext) {
    guard context.isSafe, expected == context else { invalidate(); return }
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
    guard expected != nil, KeyboardCorrectionRules.isWord(word),
          context.after?.isEmpty == true || context.after?.first?.isWhitespace == true,
          let replacement = KeyboardCorrectionRules.replacement(
            for: word, suggestions: provider.suggestions(for: word)) else { return nil }
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
