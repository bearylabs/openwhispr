import UIKit
import os

/// Public, on-device API only. No learned words or text leave the keyboard.
final class GermanTextCheckerProvider: KeyboardCorrectionProvider {
  private let checker = UITextChecker()
  private let log = Logger(subsystem: "com.gizmolabs.openwhispr.keyboard", category: "Autocorrection")
  private let language: String? = {
    let languages = UITextChecker.availableLanguages
    return ["de_DE", "de-DE", "de"].first { languages.contains($0) }
      ?? languages.sorted().first { $0.hasPrefix("de_") || $0.hasPrefix("de-") }
  }()

  func suggestions(for word: String) -> [String] {
    guard let language else {
      log.info("Autocorrection skipped: German dictionary unavailable")
      return []
    }
    guard KeyboardCorrectionRules.isWord(word) else { return [] }
    let range = NSRange(word.startIndex..<word.endIndex, in: word)
    let misspelled = checker.rangeOfMisspelledWord(
      in: word, range: range, startingAt: 0, wrap: false, language: language)
    guard misspelled == range else {
      log.info("Autocorrection skipped: whole word not flagged as misspelled")
      return []
    }
    let suggestions = (checker.guesses(forWordRange: range, in: word, language: language) ?? [])
      .filter { candidate in
        let candidateRange = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return checker.rangeOfMisspelledWord(
          in: candidate, range: candidateRange, startingAt: 0, wrap: false,
          language: language).location == NSNotFound
      }
    let eligible = KeyboardCorrectionRules.replacement(for: word, suggestions: suggestions) != nil
    // Only control-flow metadata, never the original, proposals or surrounding text.
    log.info("Autocorrection proposals: dictionaryCount=\(suggestions.count, privacy: .public) uniqueEligible=\(eligible, privacy: .public)")
    return suggestions
  }
}
