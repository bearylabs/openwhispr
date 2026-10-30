import Foundation

private struct StubProvider: KeyboardCorrectionProvider {
  var words = ["nicht"]
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

    let unsafe = [
      context(nil, document: document), context("nciht", after: nil, document: document),
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
    print("Keyboard autocorrection: \(count) checks passed")
  }
}
