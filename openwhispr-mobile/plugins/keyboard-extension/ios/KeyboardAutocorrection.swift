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
    return (5...20).contains(word.count)
      && lower.allSatisfy { alphabet.contains($0) }
      && word.unicodeScalars.count == word.count
      && (word == lower || word == String(lower.prefix(1)).uppercased() + lower.dropFirst())
  }

  static func replacement(for word: String, suggestions: [String]) -> String? {
    guard isWord(word) else { return nil }
    let source = Array(word)
    let candidates = Set(suggestions).filter { candidate in
      guard isWord(candidate), candidate.count == word.count,
            candidate.first == word.first, candidate.last == word.last else { return false }
      let target = Array(candidate)
      let changed = source.indices.filter { source[$0] != target[$0] }
      guard changed.count == 2, changed[1] == changed[0] + 1 else { return false }
      return source[changed[0]] == target[changed[1]] && source[changed[1]] == target[changed[0]]
    }
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
