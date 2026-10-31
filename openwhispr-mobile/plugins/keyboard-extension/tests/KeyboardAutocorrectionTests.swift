import Foundation

private struct StubProvider: KeyboardCorrectionProvider {
  var words = ["nicht"]
  func suggestions(for word: String) -> [String] { words }
}

/// A provider for a chosen selection, as the controller builds from the app's setting.
private struct SelectionProvider: KeyboardCorrectionProvider {
  var words: [String]
  var letters: Set<Character>
  func suggestions(for word: String) -> [String] { words }
}

@main
private enum KeyboardAutocorrectionTests {
  static var count = 0
  static func check(_ label: String, _ value: Bool) {
    count += 1
    precondition(value, label)
  }

  static func context(_ before: String? = "", after: String? = "", selection: String? = nil,
                      allowed: Bool = true, document: UUID) -> KeyboardCorrectionContext {
    KeyboardCorrectionContext(document: document, before: before, after: after,
                              selection: selection, allowed: allowed)
  }

  static func typed(_ word: String, prefix: String = "", after: String = "",
                    document: UUID) -> (KeyboardAutocorrection, KeyboardCorrectionContext) {
    var state = KeyboardAutocorrection()
    var current = context(prefix, after: after, document: document)
    for letter in word {
      state.manualInsertion(String(letter), in: current)
      current = current.inserting(String(letter))
      state.reconcile(current)
    }
    return (state, current)
  }

  static func main() {
    let provider = StubProvider()
    let document = UUID()
    check("unique inner swap", KeyboardCorrectionRules.replacement(
      for: "nciht", suggestions: ["nicht", "nichts"]) == "nicht")
    check("duplicates do not introduce ambiguity", KeyboardCorrectionRules.replacement(
      for: "nciht", suggestions: ["nicht", "nicht"]) == "nicht")
    check("first guess is not evidence", KeyboardCorrectionRules.replacement(
      for: "nciht", suggestions: ["Nacht"]) == nil)
    check("ambiguous swaps", KeyboardCorrectionRules.replacement(
      for: "abcde", suggestions: ["acbde", "abdce"]) == nil)
    check("umlaut swap", KeyboardCorrectionRules.replacement(
      for: "Mädcehn", suggestions: ["Mädchen"]) == "Mädchen")
    check("eszett swap", KeyboardCorrectionRules.replacement(
      for: "grßoer", suggestions: ["großer"]) == "großer")
    check("no case changes", KeyboardCorrectionRules.replacement(
      for: "Nciht", suggestions: ["nicht"]) == nil)
    check("short end swap", KeyboardCorrectionRules.replacement(
      for: "udn", suggestions: ["und"]) == "und")
    check("first letter swap", KeyboardCorrectionRules.replacement(
      for: "incht", suggestions: ["nicht"]) == "nicht")
    check("last letter swap", KeyboardCorrectionRules.replacement(
      for: "nicth", suggestions: ["nicht"]) == "nicht")
    check("one wrong letter", KeyboardCorrectionRules.replacement(
      for: "nucht", suggestions: ["nicht"]) == "nicht")
    check("one missing letter", KeyboardCorrectionRules.replacement(
      for: "nich", suggestions: ["nicht"]) == "nicht")
    check("one extra letter", KeyboardCorrectionRules.replacement(
      for: "Halllo", suggestions: ["Hallo"]) == "Hallo")
    check("umlaut substitution", KeyboardCorrectionRules.replacement(
      for: "Mödchen", suggestions: ["Mädchen"]) == "Mädchen")
    check("ambiguous edit kinds", KeyboardCorrectionRules.replacement(
      for: "nich", suggestions: ["nicht", "noch"]) == nil)
    check("ranking does not resolve ambiguity", KeyboardCorrectionRules.replacement(
      for: "nich", suggestions: ["noch", "nicht"]) == nil)
    check("two edits excluded", KeyboardCorrectionRules.replacement(
      for: "ncih", suggestions: ["nicht"]) == nil)
    check("short substitution excluded", KeyboardCorrectionRules.replacement(
      for: "unt", suggestions: ["und"]) == nil)
    check("unchanged word excluded", KeyboardCorrectionRules.replacement(
      for: "nicht", suggestions: ["nicht"]) == nil)
    // English goes through the same rules as German.
    check("english short swap", KeyboardCorrectionRules.replacement(
      for: "teh", suggestions: ["the", "ten", "tech"]) == "the")
    check("english inner swap", KeyboardCorrectionRules.replacement(
      for: "recieve", suggestions: ["receive", "recite"]) == "receive")
    check("english missing letter", KeyboardCorrectionRules.replacement(
      for: "becuse", suggestions: ["because"]) == "because")
    check("english title case kept", KeyboardCorrectionRules.replacement(
      for: "Thsi", suggestions: ["This", "this"]) == "This")
    check("german and english proposals together stay unique", KeyboardCorrectionRules.replacement(
      for: "nciht", suggestions: ["nicht", "night", "niche"]) == "nicht")
    check("one proposal per language is ambiguous", KeyboardCorrectionRules.replacement(
      for: "Bnad", suggestions: ["Band", "Brad"]) == nil)
    check("english contraction excluded", !KeyboardCorrectionRules.isWord("don't"))

    // The app's language selection ("de,en" in the App Group).
    let german = KeyboardCorrectionLanguage.german, english = KeyboardCorrectionLanguage.english
    check("missing selection is German and English",
          KeyboardCorrectionLanguage.selection(from: nil) == [german, english])
    check("empty selection is the default", KeyboardCorrectionLanguage.selection(from: "") == [german, english])
    check("unknown-only selection is the default",
          KeyboardCorrectionLanguage.selection(from: "xx, zz") == [german, english])
    check("single language", KeyboardCorrectionLanguage.selection(from: "en") == [english])
    check("order kept, spacing and case tolerated, duplicates and unknown dropped",
          KeyboardCorrectionLanguage.selection(from: " EN ,xx,de,en") == [english, german])
    check("selection capped", KeyboardCorrectionLanguage.selection(
      from: Array(repeating: "de,en", count: 5).joined(separator: ",")).count
      <= KeyboardCorrectionLanguage.maxSelected)
    check("every language has a unique code",
          Set(KeyboardCorrectionLanguage.all.map(\.code)).count == KeyboardCorrectionLanguage.all.count)
    let englishLetters = KeyboardCorrectionLanguage.letters(of: [english])
    let germanLetters = KeyboardCorrectionLanguage.letters(of: [german])
    check("english-only leaves umlaut words alone", KeyboardCorrectionRules.replacement(
      for: "Mädcehn", suggestions: ["Mädchen"], letters: englishLetters) == nil)
    check("english-only rejects an umlaut proposal", KeyboardCorrectionRules.replacement(
      for: "nciht", suggestions: ["nicht", "nücht"], letters: englishLetters) == "nicht")
    check("german-only keeps umlauts", KeyboardCorrectionRules.replacement(
      for: "Mädcehn", suggestions: ["Mädchen"], letters: germanLetters) == "Mädchen")
    check("german-only still corrects plain words", KeyboardCorrectionRules.replacement(
      for: "udn", suggestions: ["und"], letters: germanLetters) == "und")
    check("no dictionary means no letters", !KeyboardCorrectionRules.isWord("nciht", letters: []))
    for word in ["ab", "a", "hello_world", "abc123", "https://nciht", "a@b.de",
                 "fooBar", "ALLCAPS", "👩🏽‍💻nciht", "Ma\u{308}dcehn", "a-bcd", "abc'd", "abc\u{200B}de"] {
      check("excluded token: \(word)", !KeyboardCorrectionRules.isWord(word))
    }
    check("long words bounded", !KeyboardCorrectionRules.isWord(String(repeating: "a", count: 21)))

    var (state, current) = typed("nciht", prefix: "🙂 ", document: document)
    let edit = state.correction(in: current, provider: provider)
    check("manual word with emoji prefix", edit?.replacement == "nicht")
    state.didCorrect(edit!)
    let corrected = context("🙂 nicht ", document: document)
    state.reconcile(corrected)
    let undo = state.takeUndo(in: corrected)
    check("undo original", undo?.original == "nciht")
    check("undo one shot", state.takeUndo(in: corrected) == nil)
    check("space after undo does not recorrect", state.correction(
      in: context("🙂 nciht", document: document), provider: provider) == nil)

    // Length-changing edits must preserve the surrounding emoji and restore the full
    // original, not delete a replacement-sized suffix from the original context.
    for (original, replacement) in [("nich", "nicht"), ("Halllo", "Hallo")] {
      (state, current) = typed(original, prefix: "🙂 ", document: document)
      let variableEdit = state.correction(in: current, provider: StubProvider(words: [replacement]))!
      check("length-changing candidate", variableEdit.replacement == replacement)
      state.didCorrect(variableEdit)
      let restored = state.takeUndo(in: context("🙂 " + replacement + " ", document: document))
      check("length-changing undo", restored?.original == original)
      check("length-changing undo suppresses recorrection", state.correction(
        in: current, provider: StubProvider(words: [replacement])) == nil)
    }

    // Real UIKit proxies use nil at document boundaries, unlike the initial mocks.
    var empty = KeyboardCorrectionContext.reported(
      document: document, before: nil, after: nil, selection: nil, allowed: true, hasText: false)
    check("known empty field seeds left context", empty.before == "" && empty.isSafe)
    state = KeyboardAutocorrection()
    for letter in "nciht" {
      state.manualInsertion(String(letter), in: empty)
      empty = empty.inserting(String(letter))
      state.hostWillChange()
      state.hostDidChange(empty)
    }
    // Hosts may switch between nil and empty-string boundary reports after insertion.
    let emptyStringBoundary = context("nciht", after: "", selection: "", document: document)
    state.hostWillChange()
    state.hostDidChange(emptyStringBoundary)
    let boundaryEdit = state.correction(in: empty, provider: provider)
    check("nil right context at end permits verified correction", boundaryEdit?.replacement == "nicht")
    state.didCorrect(boundaryEdit!)
    state.hostWillChange()
    let boundaryCorrected = context("nicht ", after: nil, document: document)
    state.hostDidChange(boundaryCorrected)
    check("nil right context undo", state.takeUndo(in: boundaryCorrected)?.original == "nciht")
    let hidden = KeyboardCorrectionContext.reported(
      document: document, before: nil, after: nil, selection: nil, allowed: true, hasText: true)
    check("nonempty opaque field is still unsafe", !hidden.isSafe && hidden.before == nil)
    let rightText = KeyboardCorrectionContext.reported(
      document: document, before: nil, after: "existing", selection: nil, allowed: true, hasText: false)
    check("right text contradicts empty field", !rightText.isSafe)
    check("only empty boundary reports are equivalent",
      context("nciht", after: nil, document: document) == context("nciht", document: document))
    check("nonempty right context is never ignored",
      context("nciht", after: "x", document: document) != context("nciht", document: document))
    check("missing left context is never equal to empty",
      context(nil, document: document) != context("", document: document))

    (state, current) = typed("nciht", document: document)
    state.hostWillChange()
    state.hostDidChange(current)
    check("matching own acknowledgement retains word", state.correction(in: current, provider: provider) != nil)
    (state, current) = typed("nciht", document: document)
    state.hostWillChange()
    check("pending report blocks correction despite matching stale read", state.correction(in: current, provider: provider) == nil)
    state.hostDidChange(current)
    check("blocked pending attempt cannot revive", state.correction(in: current, provider: provider) == nil)
    (state, current) = typed("nciht", document: document)
    state.hostWillChange()
    state.hostDidChange(context("nc", after: "iht", document: document))
    check("actual cursor move invalidates", state.correction(in: current, provider: provider) == nil)
    (state, current) = typed("nciht", document: document)
    state.hostWillChange()
    state.hostDidChange(context("nci", document: document))
    check("delayed own acknowledgement invalidates", state.correction(in: current, provider: provider) == nil)

    let unsafe = [
      context(nil, document: document),
      context("nciht", selection: "chosen", document: document),
      context("nciht", allowed: false, document: document),
      context("nciht", document: UUID()), context("nci", document: document),
      context("prefix nciht", document: document), context("nciht", after: "x", document: document),
    ]
    for other in unsafe {
      (state, current) = typed("nciht", document: document)
      check("unsafe/stale context cannot correct", state.correction(in: other, provider: provider) == nil)
      check("invalidated context cannot be revived", state.correction(in: current, provider: provider) == nil)
    }
    for other in unsafe + [context("nicht", document: document)] {
      (state, current) = typed("nciht", document: document)
      let pendingEdit = state.correction(in: current, provider: provider)!
      state.didCorrect(pendingEdit)
      check("unsafe undo does nothing", state.takeUndo(in: other) == nil)
    }
    (state, current) = typed("nciht", document: document)
    state.invalidate()
    check("lifecycle/cursor invalidation", state.correction(in: current, provider: provider) == nil)
    (state, current) = typed("nciht", prefix: "existing", document: document)
    check("do not adopt existing word", state.correction(in: current, provider: provider) == nil)
    (state, current) = typed("nciht", prefix: "@", document: document)
    check("do not adopt technical suffix", state.correction(in: current, provider: provider) == nil)
    (state, current) = typed("nciht", document: document)
    state.reconcile(context("nci", document: document))
    check("late report abandons tracking", state.correction(in: current, provider: provider) == nil)
    (state, current) = typed("nciht", document: document)
    let pendingEdit = state.correction(in: current, provider: provider)!
    state.didCorrect(pendingEdit)
    state.manualInsertion("a", in: context("nicht ", document: document))
    check("typing consumes undo", state.takeUndo(in: context("nicht a", document: document)) == nil)

    // The provider's letters (its selected languages) bound what the state machine corrects.
    var englishOnly = typed("Mädcehn", document: document)
    check("english-only selection leaves umlaut word", englishOnly.0.correction(
      in: englishOnly.1, provider: SelectionProvider(
        words: ["Mädchen"], letters: KeyboardCorrectionLanguage.letters(of: [english]))) == nil)
    var germanOnly = typed("Mädcehn", document: document)
    let germanEdit = germanOnly.0.correction(
      in: germanOnly.1, provider: SelectionProvider(
        words: ["Mädchen"], letters: KeyboardCorrectionLanguage.letters(of: [german])))
    check("german selection corrects umlaut word", germanEdit?.replacement == "Mädchen")
    print("Keyboard autocorrection: \(count) checks passed")
  }
}
