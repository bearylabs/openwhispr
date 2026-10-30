# German autocorrection prototype

## Enabled by default

Autocorrection runs automatically in eligible fields when manually tapping space.
There is no long-press menu, activation step or local opt-in preference. Any disabled
preference saved by the earlier prototype is ignored. The removed menu's string catalog
is no longer shipped. Full Access is not needed for correction; dictation still needs it.
The host field's `.autocorrectionType == .no` and all safety exclusions remain respected.

Context checks remain strict even with the expanded candidate rules below. If a host
reports stale/missing context, or the German dictionary offers no eligible replacement,
the prototype deliberately inserts an ordinary space. A lack of correction on a device
still needs host/dictionary investigation; changing the default alone does not prove a fix.

## Deliberately small scope

- Only the manually tapped space key can initiate a correction. No suggestion bar,
  automatic language detection, extra engine, learned dictionary, network, or text logging.
- `GermanTextCheckerProvider` uses public `UITextChecker` APIs. It checks the installed
  language identifiers, preferring `de_DE`, `de-DE`, then `de`, then another available
  German variant. With no German dictionary, it returns no suggestions.
- The complete original must be misspelled, and a replacement must pass the dictionary.
  Ranking first is not enough: `KeyboardCorrectionRules` requires exactly one distinct
  nearby candidate, preserving lowercase/title case and using 3–20 German alphabet letters.
  Adjacent swaps now include word edges (`udn` → `und`, `nicth` → `nicht`). For words
  with at least four letters on both sides, one wrong, missing or extra letter also
  qualifies (`nucht` → `nicht`, `nich` → `nicht`, `Halllo` → `Hallo`). More than one
  eligible proposal means no replacement, even when one is ranked first. Multiple edits,
  case changes and one-letter substitutions in three-letter words remain excluded.
  These broader rules may produce more false positives; immediately backspace to undo.
  Actual candidates depend on the OS dictionary; the prototype may deliberately do nothing.
- Digits, punctuation, underscores, mixed/all caps, URL/email-like tokens, emoji and
  decomposed combining sequences are excluded. Words following punctuation are not
  tracked. The MVP cannot semantically identify every all-letter name or technical term.
- Only default text fields are eligible. Secure fields, fields hiding their text,
  `.autocorrectionType == .no`, URL, email, ASCII-only, numeric and other specialized
  keyboard types are excluded. Selections are never automatically replaced.
- Existing text is never adopted into the manual word buffer. Dictation and assistant
  output go through the unchanged insertion behavior; `typeText` only invalidates
  correction state, it never corrects text.

## Replacement and undo safety

`KeyboardAutocorrection.swift` is Foundation-only; its provider protocol makes proposals
replaceable independently of the controller. It tracks expected host context after manual
inserts, not just the word. Before any replacement the controller freshly reads **both**
sides of the cursor, selection, field traits and document UUID, and requires an exact
match to the expected context. After querying the checker it reads all of them again,
immediately before deletion. Any missing, delayed, truncated or contradictory context
abandons the correction and inserts an ordinary space. Context is reconciled on text
reports and invalidated on selection callbacks, keyboard appearances/disappearances,
keyboard switches, other insertions and deleting. Conservative false negatives are intended.

Direct backspace after correction deletes the corrected word **and its space**, restoring
the original without a space. It needs the same document and exact freshly rechecked
corrected context; otherwise it is ordinary backspace. Undo is one-shot. The restored
word is not tracked, so pressing space again does not immediately re-correct it. Held
backspace retains normal repeating/word-chunk deletion, rather than triggering undo.

All word indexing/deletion uses Swift `Character`; the provider alone uses UTF-16
`NSRange(_:in:)` for Apple's API. Surrounding emoji do not affect delete counts. A word
with combining marks is left unchanged rather than assuming a host's deletion semantics.

Public proxy reads cannot form an atomic transaction with the host. This prototype
fails closed on observable changes; it cannot detect an unreported cursor move to an
identical context. No inferred cursor coordinates or private host APIs are used here.

## Build and automated tests (macOS)

Use Node 24 and Xcode 26.2+. From `openwhispr-mobile/`:

```bash
npm ci
bundle install
sh scripts/test-keyboard-autocorrection.sh
npm run test:keyboard-capitalization
python3 plugins/keyboard-extension/tests/run-keyboard-touch-tests.py
npm test -- --runInBand
```

Jest automatically runs the Foundation-only Swift tests if `swiftc` is available and
explicitly skips that test otherwise. The Swift tests cover conservative decisions,
ambiguity, excluded tokens, Unicode, context invalidation, delayed reports and undo.
The existing Catalyst controller regression suite now also covers default-on behavior
(including an obsolete disabled preference), removal of the space long-press menu, correction,
undo, recorrection suppression, double space, silent hosts, cursor changes, field guards,
transcript exclusion and held delete. Existing shift, smart quote and layout checks remain.
The plugin tests check source registration, copying and idempotent prebuild.

For a device build, configure your own bundle ID/scheme and signing team as described in
[CONTRIBUTING.md](../../CONTRIBUTING.md#physical-ios-devices-and-forks), then:

```bash
npm run prebuild:dev -- --clean
npm run ios -- --device
```

Select your team for the app, keyboard and activity extension targets in the generated
Xcode workspace if needed. Both new Swift sources are registered
in `withKeyboardExtension.js`; do not copy them manually into generated `ios/`.
A native rebuild is required; a JS-only update is insufficient.

## Initial validation performed in this Linux worktree

- Node **24.22.1**, `npm ci --ignore-scripts --no-audit --no-fund`; lockfiles unchanged.
- `npm test -- --runInBand`: **326 suites passed; 4,332 tests passed, 1 Swift test skipped**.
- `npm run typecheck`: passed.
- `npm run lint`: no errors, 177 existing warnings outside the changed files.
- `npm run format` and `git diff --check`: passed.
- Native rule/capitalization scripts: attempted, unavailable (`swiftc` not installed).
- Catalyst regression runner: attempted, unavailable (requires macOS and Xcode).
- No local Swift compilation, iOS build or simulator testing was possible on Linux.
- The initial opt-in revision (`7a4277d99`) subsequently built successfully via GitHub
  Actions run `41077745294` and was installed on the iPhone. The user reported no visible
  correction. That build does not validate the subsequent default-on revision.

## Required Mac / iPhone checks before relying on it

1. Run the three native test commands above, then compile a clean prebuild. Confirm
   long-pressing space no longer opens the prototype menu.
2. Enable the extension in iOS Settings and select it in Notes. Without any activation,
   manually type `nciht` and space; if the installed German dictionary offers `nicht`,
   expect `nicht `. Immediately backspace → `nciht`; space → `nciht `; another space → `nciht. `.
3. Test on at least Notes, Messages and a Safari textarea/contenteditable, with fast typing
   and delayed host updates. No correction is preferable to any wrong-location replacement.
4. Move the cursor, select text, switch fields/apps/documents/keyboards, dismiss/reopen the
   keyboard, edit using another input source, and test undo after each. No stale replacement.
5. Test `.no`, password, URL, email and opaque fields; `foo_bar`, `fooBar`, addresses, numbers,
   emoji surrounding a word, `ä/ö/ü/ß`, and decomposed accented characters. Exclusions stay intact.
6. Dictate and insert an assistant answer containing a typo, then space: output stays unchanged.
   Verify smart quotes, shift, double-space period, ordinary/held/accelerated backspace,
   landscape, and no lost/duplicated fast taps. Dismiss and reopen: correction stays available.
7. Where German is unavailable, typing must work without correction. Dictionary proposals
   and timing are OS-dependent and are not proven by the stub-provider controller tests.
