// Linux stand-in for the part of UIKit TextCheckerCorrectionProvider uses, so the production
// provider compiles and runs off Apple platforms with a word list in place of Apple's
// dictionaries (`UITextChecker.lexicons`). Test-only: never part of the keyboard.
@_exported import Foundation

/// One language's words, most common first, as UITextChecker would know them.
public final class StandInLexicon {
  public let language: String
  /// Every stored form (`Haus`, `nicht`).
  public let forms: Set<String>
  /// Forms by their lowercase first two letters, most common first (completions).
  private let byPrefix: [String: [String]]

  public init(language: String, wordsByFrequency: [String]) {
    self.language = language
    var forms = Set<String>()
    var byPrefix: [String: [String]] = [:]
    for word in wordsByFrequency where forms.insert(word).inserted {
      byPrefix[String(word.lowercased().prefix(2)), default: []].append(word)
    }
    self.forms = forms
    self.byPrefix = byPrefix
  }

  /// As typed, or a known word capitalised (a sentence start). Lowercase nouns aren't known.
  public func knows(_ word: String) -> Bool {
    if forms.contains(word) { return true }
    let lower = word.lowercased()
    return word == lower.prefix(1).uppercased() + lower.dropFirst() && forms.contains(lower)
  }

  /// Known forms starting with `prefix` (case-insensitively), most common first, the prefix itself
  /// included when it is a word (as UITextChecker lists it; noun capitalisation relies on that).
  public func completions(of prefix: String) -> [String] {
    let lower = prefix.lowercased()
    guard lower.count >= 2 else { return [] }
    return (byPrefix[String(lower.prefix(2))] ?? []).filter { $0.lowercased().hasPrefix(lower) }
  }
}

open class UITextChecker {
  /// The stand-in dictionaries by language identifier; set by the harness.
  nonisolated(unsafe) public static var lexicons: [String: StandInLexicon] = [:]
  /// Lookups made (misspelling checks and completions).
  nonisolated(unsafe) public static var lookups = 0
  /// How long each lookup takes, to test the provider's time budget; 0 by default.
  nonisolated(unsafe) public static var lookupDelay: TimeInterval = 0

  public class var availableLanguages: [String] { lexicons.keys.sorted() }

  public init() {}

  open func rangeOfMisspelledWord(in string: String, range: NSRange, startingAt startingOffset: Int,
                                  wrap wrapFlag: Bool, language: String) -> NSRange {
    Self.lookups += 1
    if Self.lookupDelay > 0 { Thread.sleep(forTimeInterval: Self.lookupDelay) }
    guard let lexicon = Self.lexicons[language], let swiftRange = Range(range, in: string) else {
      return NSRange(location: NSNotFound, length: 0)
    }
    let word = String(string[swiftRange])
    let known = word.split(separator: " ").allSatisfy { lexicon.knows(String($0)) }
    return known ? NSRange(location: NSNotFound, length: 0) : range
  }

  open func guesses(forWordRange range: NSRange, in string: String, language: String) -> [String]? {
    // No proposals of its own: the provider's generated candidates decide.
    []
  }

  open func completions(forPartialWordRange range: NSRange, in string: String,
                        language: String) -> [String]? {
    Self.lookups += 1
    if Self.lookupDelay > 0 { Thread.sleep(forTimeInterval: Self.lookupDelay) }
    guard let lexicon = Self.lexicons[language], let swiftRange = Range(range, in: string) else { return [] }
    return lexicon.completions(of: String(string[swiftRange]))
  }
}

/// Objective-C's autorelease pools don't exist here; the body just runs.
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
  try body()
}
