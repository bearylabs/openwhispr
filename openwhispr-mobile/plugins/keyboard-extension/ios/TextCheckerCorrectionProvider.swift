import UIKit
import os

/// Public, on-device API only. No learned words or text leave the keyboard.
///
/// Checks the languages picked in the app's Settings together (German and English by
/// default), since the keyboard has no language switch: a word any of their dictionaries
/// knows is never corrected (an English word in German text, or the reverse), and each
/// proposal must be a known word in the dictionary that offered it.
/// `KeyboardCorrectionRules` then picks the closest proposal across all of them; a tie goes
/// to the most common word.
final class TextCheckerCorrectionProvider: KeyboardCorrectionProvider {
  /// The selection this provider was built for; the controller rebuilds it when that changes.
  let languages: [KeyboardCorrectionLanguage]
  /// Only languages with an installed dictionary; their letters bound what can be corrected.
  let letters: Set<Character>
  private let dictionaries: [String]
  private let checker = UITextChecker()
  private var completionCache: [String: [String]] = [:]
  /// How long a space press may spend looking up neighbouring-key variants.
  static let slipSearchNanoseconds: UInt64 = 100_000_000
  private let log = Logger(subsystem: "com.gizmolabs.openwhispr.keyboard", category: "Autocorrection")

  init(languages: [KeyboardCorrectionLanguage]) {
    self.languages = languages
    let available = UITextChecker.availableLanguages
    let resolved = languages.compactMap { language in
      Self.dictionary(for: language, from: available).map { (language, $0) }
    }
    dictionaries = resolved.map { $0.1 }
    letters = KeyboardCorrectionLanguage.letters(of: resolved.map { $0.0 })
  }

  private static func dictionary(for language: KeyboardCorrectionLanguage,
                                 from available: [String]) -> String? {
    language.dictionaries.first { available.contains($0) }
      ?? available.sorted().first {
        $0.hasPrefix(language.code + "_") || $0.hasPrefix(language.code + "-")
      }
  }

  private func misspelledRange(of word: String, in dictionary: String) -> NSRange {
    let range = NSRange(word.startIndex..<word.endIndex, in: word)
    return checker.rangeOfMisspelledWord(
      in: word, range: range, startingAt: 0, wrap: false, language: dictionary)
  }

  private func isKnown(_ word: String, in dictionary: String) -> Bool {
    misspelledRange(of: word, in: dictionary).location == NSNotFound
  }

  /// How common a word is: its position among UITextChecker's completions of its first two
  /// letters, which Apple orders by likelihood (lower is more common); nil when no selected
  /// dictionary completes to it. Completions are cached per dictionary and prefix, a few dozen
  /// at most, since the keyboard extension runs under a tight memory limit.
  func frequencyRank(of candidate: String) -> Int? {
    let prefix = String(candidate.prefix(2)).lowercased()
    var best: Int?
    for dictionary in dictionaries {
      let key = dictionary + "|" + prefix
      let completions: [String]
      if let cached = completionCache[key] {
        completions = cached
      } else {
        let range = NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
        completions = (checker.completions(forPartialWordRange: range, in: prefix, language: dictionary) ?? [])
          .map { $0.lowercased() }
        if completionCache.count >= 48 { completionCache.removeAll() }
        completionCache[key] = completions
      }
      if let index = completions.firstIndex(of: candidate.lowercased()) { best = min(best ?? index, index) }
    }
    return best
  }

  func suggestions(for word: String) -> [String] {
    guard !dictionaries.isEmpty else {
      log.info("Autocorrection skipped: no dictionary for the selected languages")
      return []
    }
    guard KeyboardCorrectionRules.isWord(word, letters: letters) else { return [] }
    let range = NSRange(word.startIndex..<word.endIndex, in: word)
    // The complete word must be flagged by every dictionary, not just part of it by one.
    guard dictionaries.allSatisfy({ misspelledRange(of: word, in: $0) == range }) else {
      log.info("Autocorrection skipped: whole word not flagged as misspelled in every dictionary")
      return []
    }
    var suggestions: [String] = []
    for dictionary in dictionaries {
      for candidate in checker.guesses(forWordRange: range, in: word, language: dictionary) ?? []
      where !suggestions.contains(candidate) && isKnown(candidate, in: dictionary) {
        suggestions.append(candidate)
      }
    }
    // UITextChecker doesn't always propose swaps or missing/extra letters (`kalppt` →
    // `klappt`), and rarely words several neighbouring-key slips away (`njxbt` → `nicht`), so
    // try those variants against the dictionaries too: single edits first, then every level of
    // slips, since a common word with more slips can beat a rare one with fewer. The space
    // press waits for this, so it stops at a deadline; a level cut short is dropped.
    var timedOut = false
    let deadline = DispatchTime.now().uptimeNanoseconds + Self.slipSearchNanoseconds
    let stop: () -> Bool = {
      if DispatchTime.now().uptimeNanoseconds >= deadline { timedOut = true }
      return timedOut
    }
    let known: (String) -> Bool = { variant in self.dictionaries.contains { self.isKnown(variant, in: $0) } }
    let edits = KeyboardCorrectionRules.singleEditCandidates(
      for: word, letters: letters, shouldStop: stop, isKnown: known)
    let slips = timedOut ? [] : KeyboardCorrectionRules.neighborSlipCandidates(
      for: word, maxSlips: KeyboardCorrectionRules.maxNeighborSlips(forLength: word.count),
      shouldStop: stop, isKnown: known)
    var generated = 0
    for candidate in edits + slips where !suggestions.contains(candidate) {
      suggestions.append(candidate)
      generated += 1
    }
    let pick = KeyboardCorrectionRules.replacement(
      for: word, suggestions: suggestions, letters: letters, rank: { frequencyRank(of: $0) })
    let eligible = pick != nil
    // Only control-flow metadata, never the original, proposals or surrounding text.
    log.info("Autocorrection proposals: dictionaries=\(self.dictionaries.count, privacy: .public) dictionaryCount=\(suggestions.count, privacy: .public) neighborSlips=\(generated, privacy: .public) slipSearchTimedOut=\(timedOut, privacy: .public) corrects=\(eligible, privacy: .public)")
    return suggestions
  }
}
