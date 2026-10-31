import UIKit
import os

/// Public, on-device API only. No learned words or text leave the keyboard.
///
/// Checks the languages picked in the app's Settings together (German and English by
/// default), since the keyboard has no language switch: a word any of their dictionaries
/// knows is never corrected (an English word in German text, or the reverse), and each
/// proposal must be a known word in the dictionary that offered it.
/// `KeyboardCorrectionRules` then still needs exactly one eligible proposal across all of them.
final class TextCheckerCorrectionProvider: KeyboardCorrectionProvider {
  /// The selection this provider was built for; the controller rebuilds it when that changes.
  let languages: [KeyboardCorrectionLanguage]
  /// Only languages with an installed dictionary; their letters bound what can be corrected.
  let letters: Set<Character>
  private let dictionaries: [String]
  private let checker = UITextChecker()
  /// How long a space press may spend looking up neighbouring-key variants.
  static let slipSearchNanoseconds: UInt64 = 80_000_000
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
    // UITextChecker rarely proposes words several neighbouring-key slips away (`njxbt` →
    // `nicht`), so try those variants against the dictionaries too, unless a one-edit proposal
    // already exists (nothing with more slips could beat it).
    let cheapest = suggestions.compactMap { KeyboardCorrectionRules.editCost(from: word, to: $0) }.min()
    var generated = 0
    var timedOut = false
    if cheapest != 1 {
      let maxSlips = cheapest ?? KeyboardCorrectionRules.maxNeighborSlips(forLength: word.count)
      // The space press waits for this; past the deadline the search is abandoned whole
      // (an unfinished search could miss the rival that makes a word ambiguous).
      let deadline = DispatchTime.now().uptimeNanoseconds + Self.slipSearchNanoseconds
      let found = KeyboardCorrectionRules.neighborSlipCandidates(
        for: word, maxSlips: maxSlips,
        isKnown: { variant in
          guard !timedOut, DispatchTime.now().uptimeNanoseconds < deadline else {
            timedOut = true
            return false
          }
          return dictionaries.contains { isKnown(variant, in: $0) }
        })
      if !timedOut {
        for candidate in found where !suggestions.contains(candidate) {
          suggestions.append(candidate)
          generated += 1
        }
      }
    }
    let eligible = KeyboardCorrectionRules.replacement(
      for: word, suggestions: suggestions, letters: letters) != nil
    // Only control-flow metadata, never the original, proposals or surrounding text.
    log.info("Autocorrection proposals: dictionaries=\(self.dictionaries.count, privacy: .public) dictionaryCount=\(suggestions.count, privacy: .public) neighborSlips=\(generated, privacy: .public) slipSearchTimedOut=\(timedOut, privacy: .public) uniqueEligible=\(eligible, privacy: .public)")
    return suggestions
  }
}
