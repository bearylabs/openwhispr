import UIKit
import os

/// Public, on-device API only. No learned words or text leave the keyboard.
///
/// Checks the languages picked in the app's Settings together (German and English by
/// default), since the keyboard has no language switch: a word any of their dictionaries
/// knows is left alone (an English word in German text, or the reverse), unless the
/// sentence's language or a German umlaut respelling says otherwise, and each proposal must be
/// a known word in the dictionary that offered it. `KeyboardCorrectionRules` then scores the
/// proposals by key distance and frequency; the provider returns the one it picks.
final class TextCheckerCorrectionProvider: KeyboardCorrectionProvider {
  /// The selection this provider was built for; the controller rebuilds it when that changes.
  let languages: [KeyboardCorrectionLanguage]
  /// Only languages with an installed dictionary; their letters bound what can be corrected.
  let letters: Set<Character>
  private let dictionaries: [String]
  /// The language code of each entry in `dictionaries`.
  private let resolvedCodes: [String]
  /// The German dictionary, when German is selected and installed (for ae/oe/ue/ss).
  private let germanDictionary: String?
  /// Every language the keyboard knows whose dictionary is installed, selected or not, by code:
  /// the English contractions need a sentence shown to be English against all of them.
  private let detectionDictionaries: [(code: String, dictionary: String)]
  private let checker = UITextChecker()
  private var completionCache: [String: [String]] = [:]
  /// Corpus ranks by language code (`KeyboardFrequencyList`), for scoring only; empty uses
  /// UITextChecker's completions alone.
  private let frequencyLists: [String: KeyboardFrequencyList]
  /// Word pairs by language code (`KeyboardContextModel`): the word before chooses between the
  /// candidates for a word being corrected. Empty, or a weight of 0, changes nothing.
  private let contextModels: [String: KeyboardContextModel]
  private let contextWeight: Double
  private let contextCap: Double
  /// Edits per bit of a pair's association, and the most bits a pair counts for: tuned on typos
  /// in Wikipedia sentences (AUTOCORRECTION.md, Context).
  static let defaultContextWeight = 0.15
  static let defaultContextCap = 8.0
  /// How long a space press may spend on its own lookups, from the moment it asks for
  /// suggestions; each search stops at it and drops what it didn't finish.
  static let slipSearchNanoseconds: UInt64 = 100_000_000
  private var deadline: UInt64 = 0
  private var timedOut = false

  /// Starts the press's time budget.
  private func startDeadline() {
    deadline = DispatchTime.now().uptimeNanoseconds + Self.slipSearchNanoseconds
    timedOut = false
  }

  /// Whether the press's time budget is used up; stays true once it is.
  private func stop() -> Bool {
    if !timedOut && DispatchTime.now().uptimeNanoseconds >= deadline { timedOut = true }
    return timedOut
  }
  private let log = Logger(subsystem: "com.gizmolabs.openwhispr.keyboard", category: "Autocorrection")

  init(languages: [KeyboardCorrectionLanguage], frequencyLists: [String: KeyboardFrequencyList] = [:],
       contextModels: [String: KeyboardContextModel] = [:],
       contextWeight: Double = TextCheckerCorrectionProvider.defaultContextWeight,
       contextCap: Double = TextCheckerCorrectionProvider.defaultContextCap) {
    self.languages = languages
    self.frequencyLists = frequencyLists
    self.contextModels = contextModels
    self.contextWeight = contextWeight
    self.contextCap = contextCap
    let available = UITextChecker.availableLanguages
    let resolved = languages.compactMap { language in
      Self.dictionary(for: language, from: available).map { (language, $0) }
    }
    dictionaries = resolved.map { $0.1 }
    resolvedCodes = resolved.map { $0.0.code }
    germanDictionary = resolved.first { $0.0.code == KeyboardCorrectionLanguage.german.code }?.1
    detectionDictionaries = KeyboardCorrectionLanguage.all.compactMap { language in
      Self.dictionary(for: language, from: available).map { (language.code, $0) }
    }
    letters = KeyboardCorrectionLanguage.letters(of: resolved.map { $0.0 })
  }

  private static func dictionary(for language: KeyboardCorrectionLanguage,
                                 from available: [String]) -> String? {
    language.dictionaries.first { available.contains($0) }
      ?? available.sorted().first {
        $0.hasPrefix(language.code + "_") || $0.hasPrefix(language.code + "-")
      }
  }

  /// Called thousands of times per space press, so each lookup frees its autoreleased
  /// temporaries at once instead of holding them until the press ends.
  private func misspelledRange(of word: String, in dictionary: String) -> NSRange {
    autoreleasepool {
      let range = NSRange(word.startIndex..<word.endIndex, in: word)
      return checker.rangeOfMisspelledWord(
        in: word, range: range, startingAt: 0, wrap: false, language: dictionary)
    }
  }

  private func isKnown(_ word: String, in dictionary: String) -> Bool {
    misspelledRange(of: word, in: dictionary).location == NSNotFound
  }

  /// How common a word is, for scoring: per selected language its rank in that language's
  /// frequency list (`KeyboardFrequencyList`, among the list's words with the same first two
  /// letters), else its position among UITextChecker's completions of its first two letters
  /// (`completionRank`); the lowest. Without lists it is `completionRank`.
  func frequencyRank(of candidate: String) -> Int? {
    guard !frequencyLists.isEmpty else { return completionRank(of: candidate) }
    return zip(resolvedCodes, dictionaries).compactMap { code, dictionary in
      frequencyLists[code]?.rank(of: candidate) ?? rank(of: candidate, in: dictionary)
    }.min()
  }

  /// A word's position among UITextChecker's completions of its first two letters, which Apple
  /// orders by likelihood (lower is more common); nil when no selected dictionary completes to
  /// it. The rules that ask whether a word is common at all (two words for one, respellings of
  /// accepted words) use this, never the frequency lists. Completions are cached per dictionary
  /// and prefix, a few dozen at most, since the keyboard extension runs under a tight memory limit.
  private func completionRank(of candidate: String) -> Int? {
    dictionaries.compactMap { rank(of: candidate, in: $0) }.min()
  }

  /// The candidate's position among one dictionary's completions of its first two letters.
  private func rank(of candidate: String, in dictionary: String) -> Int? {
    autoreleasepool {
      let prefix = String(candidate.prefix(2)).lowercased()
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
      return completions.firstIndex(of: candidate.lowercased())
    }
  }

  /// Respellings of a word a dictionary accepts as typed, that German knows, when the typed
  /// spelling isn't a common word in any selected dictionary (no frequency rank): `moechte` or a
  /// learned `fuer` become `möchte` and `für`, while `sued`, `phoenix`, `Masse` and `Busse`
  /// stay. A respelling with ß also needs German not to know the ss spelling, or the ß one to
  /// be common.
  private func knownWordRespellings(of word: String) -> [String] {
    guard let germanDictionary, completionRank(of: word) == nil else { return [] }
    let germanKnowsWord = isKnown(word, in: germanDictionary)
    let found = KeyboardCorrectionRules.transcriptions(of: word).compactMap { respelling -> String? in
      guard !stop(), let spelling = germanSpelling(of: respelling.word, in: germanDictionary) else { return nil }
      guard spelling.contains("ß") else { return spelling }
      return !germanKnowsWord || completionRank(of: spelling) != nil ? spelling : nil
    }
    return stop() ? [] : found
  }

  /// The respelling as German knows it: as typed, or capitalised for a noun typed in lowercase.
  private func germanSpelling(of respelling: String, in dictionary: String) -> String? {
    if isKnown(respelling, in: dictionary) { return respelling }
    let noun = KeyboardCorrectionRules.capitalized(respelling)
    return noun != respelling && isKnown(noun, in: dictionary) ? noun : nil
  }

  func suggestions(for word: String) -> [String] { suggestions(for: word, before: "") }

  /// In a sentence in one selected language, a word only another language knows counts as a
  /// typo when it isn't common there (`woe` in German text → `wie`, while `cool` stays), so
  /// that language's dictionary alone checks it.
  func suggestions(for word: String, before: String) -> [String] {
    startDeadline()
    return suggestionsWithinDeadline(for: word, before: before)
  }

  /// The app's dictionary first (`KeyboardUserDictionary.decide`): an entry's spelling, a word
  /// it protects, or a misspelled word becoming one of its words, ahead of anything iOS proposes.
  /// The scan shares the press's time budget with the ordinary search that follows.
  func replacement(for word: String, before: String, dictionary: KeyboardUserDictionary) -> String? {
    let ordinary = { () -> String? in
      // After the whole dictionary decision, ahead of every ordinary candidate.
      if KeyboardCorrectionRules.englishContraction(of: word) != nil {
        if let contraction = self.englishContraction(for: word, before: before) { return contraction }
        // Out of time while reading the sentence, or `i`, which nothing else corrects: no
        // further lookups.
        guard !self.stop(), KeyboardCorrectionRules.isWord(word, letters: self.letters)
          || KeyboardCorrectionRules.isSwappable(word, letters: self.letters) else { return nil }
      }
      return KeyboardCorrectionRules.replacement(
        for: word, suggestions: self.suggestionsWithinDeadline(for: word, before: before),
        letters: self.letters, rank: { self.frequencyRank(of: $0) },
        splitRank: { self.completionRank(of: $0) })
    }
    startDeadline()
    guard !dictionary.isEmpty else { return ordinary() }
    var ordinaryPick: String?
    let pick = dictionary.decide(
      for: word, letters: letters,
      // Unknown to every selected dictionary, or German accepts it only as a possible compound
      // (`Hrudke` at a sentence start).
      misspelled: {
        guard !dictionaries.isEmpty else { return false }
        let range = NSRange(word.startIndex..<word.endIndex, in: word)
        return dictionaries.allSatisfy { misspelledRange(of: word, in: $0) == range }
          || acceptedOnlyAsCompound(word, in: dictionaries)
      },
      shouldStop: { self.stop() },
      ordinary: {
        ordinaryPick = ordinary()
        return ordinaryPick
      })
    // Flags only, never the word or the dictionary's words.
    log.info("Autocorrection user dictionary: entries=\(dictionary.protected.count, privacy: .public) userWord=\(pick != nil && pick != ordinaryPick, privacy: .public)")
    return pick
  }

  /// `I`, `I’m`, `don’t` and the rest of `KeyboardCorrectionRules.englishContractions`, only when
  /// English is selected and installed and the words before the cursor are in English
  /// (`KeyboardCorrectionRules.sentenceLanguage`), checked against every language the keyboard
  /// knows with an installed dictionary, selected or not, so that with English alone selected
  /// `ich bin` or `so` still isn't English. With no words before, mixed, shared or German ones,
  /// or no other dictionary to tell English from, `im` and `dont` are corrected (or not) as
  /// before. Within the press's time budget.
  private func englishContraction(for word: String, before: String) -> String? {
    let english = KeyboardCorrectionLanguage.english.code
    guard let fixed = KeyboardCorrectionRules.englishContraction(of: word), !before.isEmpty,
          resolvedCodes.contains(english), detectionDictionaries.count > 1 else { return nil }
    let codes = detectionDictionaries.map { $0.code }
    let byCode = Dictionary(uniqueKeysWithValues: detectionDictionaries.map { ($0.code, $0.dictionary) })
    let code = KeyboardCorrectionRules.sentenceLanguage(
      before: before, codes: codes,
      knows: { word, code in !self.stop() && (byCode[code].map { self.isKnown(word, in: $0) } ?? false) })
    guard !stop(), code == english else { return nil }
    // Flags only, never the word.
    log.info("Autocorrection English contraction")
    return fixed
  }

  /// `suggestions(for:before:)` within a time budget already started.
  private func suggestionsWithinDeadline(for word: String, before: String) -> [String] {
    if KeyboardCorrectionRules.isSwappable(word, letters: letters) {
      return swapSuggestions(for: word, before: before)
    }
    guard languages.count > 1, !before.isEmpty else {
      return suggestions(for: word, using: dictionaries, before: before)
    }
    let byCode = Dictionary(uniqueKeysWithValues: zip(resolvedCodes, dictionaries))
    guard let code = KeyboardCorrectionRules.sentenceLanguage(
      before: before, codes: resolvedCodes,
      knows: { word, code in byCode[code].map { self.isKnown(word, in: $0) } ?? false }),
      let sentenceDictionary = byCode[code], !isKnown(word, in: sentenceDictionary) else {
      return suggestions(for: word, using: dictionaries, before: before)
    }
    let others = dictionaries.filter { $0 != sentenceDictionary }
    let commonElsewhere = others.contains { dictionary in
      isKnown(word, in: dictionary) && (rank(of: word, in: dictionary).map { $0 < Self.commonRank } ?? false)
    }
    // Flags only: the sentence's language code, never its words.
    log.info("Autocorrection sentence language: \(code, privacy: .public) commonElsewhere=\(commonElsewhere, privacy: .public)")
    return suggestions(for: word, using: commonElsewhere ? dictionaries : [sentenceDictionary], before: before)
  }

  /// A word among the first this many completions of its first two letters counts as common
  /// in that language and isn't corrected by another language's sentence.
  static let commonRank = 25

  /// Two swapped letters (`mi` → `im`, `os` → `so`), by the languages' common two-letter
  /// words (`KeyboardCorrectionRules.twoLetterSwap`): into one of the sentence's language (of
  /// any selected one when the sentence has none), and the swap a known word there. Nothing
  /// else is ever proposed for a two-letter word.
  private func swapSuggestions(for word: String, before: String) -> [String] {
    let installed = languages.filter { resolvedCodes.contains($0.code) }
    guard !installed.isEmpty else { return [] }
    let byCode = Dictionary(uniqueKeysWithValues: zip(resolvedCodes, dictionaries))
    let code = installed.count > 1 && !before.isEmpty
      ? KeyboardCorrectionRules.sentenceLanguage(
          before: before, codes: resolvedCodes,
          knows: { word, code in !self.stop() && (byCode[code].map { self.isKnown(word, in: $0) } ?? false) })
      : nil
    guard !stop() else { return [] }
    let sentence = code.map { code in installed.filter { $0.code == code } } ?? installed
    let knownInSentence: (String) -> Bool = { candidate in
      sentence.contains { language in
        !self.stop() && byCode[language.code].map { self.isKnown(candidate.lowercased(), in: $0) } == true
      }
    }
    if let swap = KeyboardCorrectionRules.twoLetterSwap(of: word, sentence: sentence, selected: installed),
       knownInSentence(swap), !stop() {
      log.info("Autocorrection swap: sentenceLanguage=\(code != nil, privacy: .public)")
      return [swap]
    }
    // A slip only for a word no selected dictionary knows (`km`, `ca` stay).
    guard !stop(), let slip = KeyboardCorrectionRules.twoLetterSlip(of: word, sentence: sentence, selected: installed),
          // As typed and in lowercase: a dictionary may know only `Mr` or `Do`.
          Set([word, word.lowercased()]).allSatisfy({ form in
            dictionaries.allSatisfy { !stop() && !isKnown(form, in: $0) } }),
          knownInSentence(slip), !stop() else {
      log.info("Autocorrection two-letter skipped: sentenceLanguage=\(code != nil, privacy: .public)")
      return []
    }
    log.info("Autocorrection two-letter slip: sentenceLanguage=\(code != nil, privacy: .public)")
    return [slip]
  }

  private func suggestions(for word: String, using dictionaries: [String], before: String) -> [String] {
    guard !dictionaries.isEmpty else {
      log.info("Autocorrection skipped: no dictionary for the selected languages")
      return []
    }
    guard KeyboardCorrectionRules.isWord(word, letters: letters) else { return [] }
    let range = NSRange(word.startIndex..<word.endIndex, in: word)
    // The complete word must be flagged by every dictionary, not just part of it by one.
    let flagged = dictionaries.allSatisfy { misspelledRange(of: word, in: $0) == range }
    // German accepts almost any capitalised word as a possible compound noun, so `Ichhabe` and
    // `Moeglichkwitne` at the start of a sentence pass. Such a word is still corrected, but only
    // into two common words, a German respelling or a common completion of its start.
    let compound = !flagged && acceptedOnlyAsCompound(word, in: dictionaries)
    // A press out of time corrects nothing rather than taking a path the checks it skipped
    // would have ruled out.
    guard !stop() else {
      log.info("Autocorrection skipped: out of time")
      return []
    }
    if compound { log.info("Autocorrection compound-like capitalised word") }
    guard flagged || compound else {
      // Except German typed without umlauts that a dictionary (English, or one with Swiss or
      // learned spellings) accepts as it is: `moechte`, `strasse`.
      let respelled = knownWordRespellings(of: word)
      guard !stop() else { return [] }
      let pick = respelled.isEmpty ? word : KeyboardCorrectionRules.replacement(
        for: word, suggestions: respelled, letters: letters, rank: { self.frequencyRank(of: $0) },
        splitRank: { self.completionRank(of: $0) }) ?? word
      // A correctly typed lowercase German noun is capitalised (`haus` → `Haus`).
      let final = nounCased(pick)
      // Flags only: which dictionaries accept the word, never the word itself.
      log.info("Autocorrection skipped: whole word not flagged as misspelled in every dictionary (germanKnows=\(self.germanDictionary.map { self.isKnown(word, in: $0) } ?? false, privacy: .public) respellings=\(respelled.count, privacy: .public) capitalised=\(final != final.lowercased() && word == word.lowercased(), privacy: .public) corrects=\(final != word, privacy: .public))")
      return final != word ? [final] : []
    }
    var suggestions: [String] = []
    // Proposals with a space (`ich habe`), with the dictionary that made them; checked like
    // generated splits once the deadline below runs.
    var spacedGuesses: [(candidate: String, dictionary: String)] = []
    for dictionary in dictionaries where !compound {
      autoreleasepool {
        for candidate in checker.guesses(forWordRange: range, in: word, language: dictionary) ?? []
        where !suggestions.contains(candidate) && isKnown(candidate, in: dictionary) {
          if candidate.contains(" ") {
            spacedGuesses.append((candidate, dictionary))
          } else {
            suggestions.append(candidate)
          }
        }
      }
    }
    // UITextChecker doesn't always propose swaps or missing/extra letters (`kalppt` →
    // `klappt`), and rarely words several neighbouring-key slips away (`njxbt` → `nicht`), so
    // try those variants against the dictionaries too: single edits first, then every level of
    // slips, since a common word with more slips can beat a rare one with fewer. The space
    // press waits for this, so it stops at a deadline; a level cut short is dropped.
    // A lowercase variant also counts when German knows it capitalised (a noun: `hsus` → `haus`
    // → `Haus`); `caseFixed` then gives it its capital.
    let known: (String) -> Bool = { variant in
      dictionaries.contains { self.isKnown(variant, in: $0) }
        || self.germanDictionary.map { self.isKnown(KeyboardCorrectionRules.capitalized(variant), in: $0) } == true
    }
    let caseFixed: (String) -> String = { variant in
      guard let german = self.germanDictionary,
            !dictionaries.contains(where: { self.isKnown(variant, in: $0) }) else { return variant }
      let noun = KeyboardCorrectionRules.capitalized(variant)
      return self.isKnown(noun, in: german) ? noun : variant
    }
    // German spelled with ae/oe/ue/ss (`schoen`, `Strasse`); only when ä/ö/ü/ß can be typed
    // in the selected languages, and before anything slower.
    var respellings = germanDictionary.map { german in
      KeyboardCorrectionRules.transcriptions(of: word).compactMap {
        stop() ? nil : germanSpelling(of: $0.word, in: german)
      }
    } ?? []
    if stop() { respellings = [] }
    // Long words whose end went wrong, from the completions of their start (`moeglichkwitne` →
    // `möglichk` → `Möglichkeiten`), and two words typed without their space (`ichhabe` →
    // `ich habe`). Both take few lookups, so they run before the slip search can use up the time.
    let isOver: () -> Bool = { self.stop() }
    let completed = completionCandidates(for: word, using: dictionaries, shouldStop: isOver)
    let isCommonSplit: (String, String, [String]) -> Bool = { left, right, dictionaries in
      KeyboardCorrectionRules.isCommonSplit(
        left, right, in: dictionaries, shouldStop: isOver,
        isKnown: { self.isKnown($0, in: $1) }, rank: { self.rank(of: $0, in: $1) })
    }
    // Apple's proposals with a space follow the rule for generated splits, in the dictionary
    // that proposed them; all are dropped when the deadline passes while checking them.
    var spaced = spacedGuesses.filter { guess in
      guard let (left, right) = KeyboardCorrectionRules.splitParts(of: guess.candidate, letters: letters) else {
        return false
      }
      return isCommonSplit(left, right, [guess.dictionary])
    }.map { $0.candidate }
    if isOver() { spaced = [] }
    let generatedSplits = isOver() ? [] : KeyboardCorrectionRules.splitCandidates(for: word, shouldStop: isOver) {
      isCommonSplit($0, $1, dictionaries)
    }
    let splits = spaced + generatedSplits.filter { !spaced.contains($0) }
    let edits = compound || isOver() ? [] : KeyboardCorrectionRules.singleEditCandidates(
      for: word, letters: letters, shouldStop: isOver, isKnown: known)
    let slips = compound || isOver() ? [] : KeyboardCorrectionRules.neighborSlipCandidates(
      for: word, maxSlips: KeyboardCorrectionRules.maxNeighborSlips(forLength: word.count),
      shouldStop: isOver, isKnown: known)
    var generated = 0
    // The typed word itself, when German only knows it capitalised (`haus` → `Haus`).
    let ownCapital = germanDictionary.map { german -> [String] in
      let noun = KeyboardCorrectionRules.capitalized(word)
      return noun != word && isKnown(noun, in: german) ? [noun] : []
    } ?? []
    // A compound-like word only becomes two words with a pronoun first, or a common (ranked)
    // respelling or completion using the umlauts it spelled as pairs (`isCompoundCorrection`);
    // never a respelling German knows only as a possible compound itself (`Möglichkwitne`).
    var compoundCandidates: [String] = []
    if compound {
      for candidate in respellings + completed + splits
      where KeyboardCorrectionRules.isCompoundCorrection(candidate, of: word, letters: letters) {
        if isOver() { compoundCandidates = []; break }
        let accepted = candidate.contains(" ") || dictionaries.contains {
          !isOver() && rank(of: candidate, in: $0) != nil
        }
        if isOver() { compoundCandidates = []; break }
        if accepted { compoundCandidates.append(candidate) }
      }
    }
    // A candidate German accepts only as a possible compound is no word (`Ichhabe`, from a swap
    // in `Ichhaeb`, or `ichhabe` read as a noun); its common splits replace it (`Ich habe`),
    // after the search, within the same time.
    let isCompoundLike: (String) -> Bool = { candidate in
      !isOver() && self.acceptedOnlyAsCompound(candidate, in: dictionaries)
    }
    let repairSplits: (String) -> [String] = { candidate in
      isOver() ? [] : KeyboardCorrectionRules.splitCandidates(for: candidate, shouldStop: isOver) {
        isCommonSplit($0, $1, dictionaries)
      }
    }
    // A lowercase variant whose noun capital is only a possible compound (`ichhabe` for
    // `Ichhabe`) is split as typed, not as the noun.
    var lowercaseCompounds = Set<String>()
    let variants = compound ? [] : (edits + slips).map { variant -> String in
      let fixed = caseFixed(variant)
      guard fixed != variant, isCompoundLike(fixed) else { return fixed }
      lowercaseCompounds.insert(variant)
      return variant
    }
    var repaired = compound ? [] : KeyboardCorrectionRules.repairingCompounds(
      respellings + completed + variants,
      isCompoundLike: { lowercaseCompounds.contains($0) || isCompoundLike($0) },
      splits: repairSplits)
    // Apple's own proposals and the word's own capital are dropped when they are only that.
    var ownNoun = compound ? [] : ownCapital.filter { !isCompoundLike($0) }
    if !compound { suggestions = suggestions.filter { !isCompoundLike($0) } }
    // Out of time, a capitalised candidate may not have been checked: only lowercase ones stay
    // (the compound check only ever rejects capitalised words), so a cut-short slip search
    // still corrects `fubktiojiert`.
    if isOver() {
      let checked: (String) -> Bool = { $0 == $0.lowercased() }
      repaired = repaired.filter(checked)
      ownNoun = []
      suggestions = suggestions.filter(checked)
    }
    let candidates = compound ? compoundCandidates : ownNoun + splits + repaired
    for candidate in candidates
    where !suggestions.contains(candidate) {
      suggestions.append(candidate)
      generated += 1
    }
    // For a lowercase word, a capitalised proposal (Apple's, or a respelled noun) doesn't count
    // when a selected dictionary also lists the word in lowercase (a sentence-start form, or
    // `Essen` for `essen`).
    if word == word.lowercased() {
      suggestions = suggestions.filter { $0 == $0.lowercased() || !listsLowercase($0.lowercased()) }
    }
    let contextBonus = self.contextBonus(before: before)
    let pick = KeyboardCorrectionRules.replacement(
      for: word, suggestions: suggestions, letters: letters, rank: { frequencyRank(of: $0) },
      splitRank: { self.completionRank(of: $0) }, contextBonus: contextBonus)
    // The correction takes the noun's capital when it is one (`strasse` → `Straße`).
    let final = pick.map(nounCased)
    // Only control-flow metadata, never the original, proposals or surrounding text.
    log.info("Autocorrection proposals: dictionaries=\(dictionaries.count, privacy: .public) compound=\(compound, privacy: .public) dictionaryCount=\(suggestions.count, privacy: .public) completions=\(completed.count, privacy: .public) splits=\(splits.count, privacy: .public) neighborSlips=\(generated, privacy: .public) slipSearchTimedOut=\(self.timedOut, privacy: .public) capitalised=\(final.map { $0 != $0.lowercased() } == true && word == word.lowercased(), privacy: .public) corrects=\(final != nil, privacy: .public)")
    return final.map { [$0] } ?? []
  }

  /// The word before's bonus for each candidate (`KeyboardContextModel`, weighted and capped), or
  /// nil: no models or weight, no usable context (`KeyboardCorrectionRules.wordContext`), or no
  /// language to read it in. One selected language reads it in that language, unless a word
  /// before only another installed language knows (`hasForeignWords`); several, in the
  /// sentence's language (`sentenceLanguage`), and a sentence start then gets no context, since
  /// the sentence before may be in another language. Out of time while finding the language, none: every candidate is scored alike.
  private func contextBonus(before: String) -> ((String) -> Double)? {
    guard !contextModels.isEmpty, contextWeight > 0, !stop(),
          let context = KeyboardCorrectionRules.wordContext(before: before) else { return nil }
    let code: String?
    if resolvedCodes.count == 1 {
      // Not in a sentence another installed language shows to be its own, or mixed (`ich vat`
      // with English alone); shared words (`so`) and a field's start keep it.
      let byCode = Dictionary(uniqueKeysWithValues: detectionDictionaries.map { ($0.code, $0.dictionary) })
      let foreign = KeyboardCorrectionRules.hasForeignWords(
        before: before, language: resolvedCodes[0], codes: detectionDictionaries.map { $0.code },
        shouldStop: { self.stop() },
        knows: { word, code in !self.stop() && (byCode[code].map { self.isKnown(word, in: $0) } ?? false) })
      code = foreign ? nil : resolvedCodes[0]
    } else if context == .sentenceStart {
      // Nothing yet says which language a new sentence is in; the one before may be another.
      return nil
    } else {
      let byCode = Dictionary(uniqueKeysWithValues: zip(resolvedCodes, dictionaries))
      code = KeyboardCorrectionRules.sentenceLanguage(
        before: before, codes: resolvedCodes,
        knows: { word, code in !self.stop() && (byCode[code].map { self.isKnown(word, in: $0) } ?? false) })
    }
    guard !stop(), let code, let model = contextModels[code] else { return nil }
    let weight = contextWeight, cap = contextCap
    // Flags only: the language code, never a word.
    log.info("Autocorrection context: language=\(code, privacy: .public)")
    return { candidate in weight * min(model.bonus(for: candidate, after: context), cap) }
  }

  /// Words completing the start of a long word in any of `dictionaries`
  /// (`KeyboardCorrectionRules.completionCandidates`), German ones from its respellings too.
  private func completionCandidates(for word: String, using dictionaries: [String],
                                    shouldStop: () -> Bool) -> [String] {
    var found: [String] = []
    for dictionary in dictionaries {
      let candidates = KeyboardCorrectionRules.completionCandidates(
        for: word, respell: dictionary == germanDictionary, shouldStop: shouldStop) { prefix in
        autoreleasepool {
          let range = NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
          return checker.completions(forPartialWordRange: range, in: prefix, language: dictionary) ?? []
        }
      }
      if shouldStop() { return [] }
      found += candidates.filter { !found.contains($0) }
    }
    return found
  }

  /// A capitalised word that a dictionary accepts only as a possible compound: not a common
  /// word (no frequency rank), and every dictionary flags it in lowercase.
  private func acceptedOnlyAsCompound(_ word: String, in dictionaries: [String]) -> Bool {
    guard let germanDictionary, dictionaries.contains(germanDictionary) else { return false }
    return KeyboardCorrectionRules.acceptedOnlyAsCompound(
      word, shouldStop: { self.stop() },
      germanKnows: { self.isKnown($0, in: germanDictionary) },
      othersKnow: { word in
        dictionaries.contains { $0 != germanDictionary && !self.stop() && self.isKnown(word, in: $0) } },
      isRanked: { word in dictionaries.contains { !self.stop() && self.rank(of: word, in: $0) != nil } },
      lowercaseFlaggedEverywhere: { lower in
        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        return dictionaries.allSatisfy { !self.stop() && self.misspelledRange(of: lower, in: $0) == range }
      })
  }

  /// Whether any selected dictionary's completions list `word` exactly in lowercase.
  private func listsLowercase(_ word: String) -> Bool {
    let range = NSRange(word.startIndex..<word.endIndex, in: word)
    return dictionaries.contains { dictionary in
      autoreleasepool {
        (checker.completions(forPartialWordRange: range, in: word, language: dictionary) ?? []).contains(word)
      }
    }
  }

  /// A lowercase word written the way German writes it: capitalised when it is a German noun,
  /// i.e. the German dictionary's completions list it only capitalised and no selected
  /// dictionary lists it in lowercase (so `essen`/`Essen`, `morgen` and English `hand` stay).
  /// Only German is capitalised; anything else, or a word typed capitalised, is returned as is.
  func nounCased(_ word: String) -> String {
    guard let germanDictionary, word == word.lowercased(), !word.contains(" ") else { return word }
    let noun = KeyboardCorrectionRules.capitalized(word)
    guard noun != word else { return word }
    let range = NSRange(word.startIndex..<word.endIndex, in: word)
    var germanNoun = false
    for dictionary in dictionaries {
      let listsWord = autoreleasepool { () -> Bool in
        let completions = checker.completions(forPartialWordRange: range, in: word, language: dictionary) ?? []
        if dictionary == germanDictionary && completions.contains(noun) { germanNoun = true }
        return completions.contains(word)
      }
      if listsWord { return word }
    }
    return germanNoun ? noun : word
  }
}
