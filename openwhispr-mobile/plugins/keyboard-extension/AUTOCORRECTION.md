# German and English autocorrection prototype

## On by default, with a switch and languages in the app

Autocorrection runs automatically in eligible fields when manually tapping space.
There is no long-press menu or activation step in the keyboard. The app's
**Settings → Preferences → Keyboard → Autocorrection** screen (iOS only) has the on/off switch
(default on) and the languages to correct (multiple choice, default German and English, at
least one and at most three). The row on Preferences shows the selection, or "Off".

- The app saves `keyboardAutocorrectionEnabled` and `keyboardAutocorrectionLanguages` in its
  config and mirrors them to the App Group as `keyboard_autocorrection_enabled` (`"1"`/`"0"`)
  and `keyboard_autocorrection_languages` (`"de,en"`), see `src/lib/keyboardAutocorrectionSync.ts`.
- The keyboard reads both at every manual space, so a change applies without reopening it.
  Only an explicit `"0"` switches correction off. The language value is parsed by
  `KeyboardCorrectionLanguage.selection(from:)`: unknown codes are ignored, duplicates dropped,
  the list capped at three; nothing usable means German and English. The controller rebuilds
  `TextCheckerCorrectionProvider` only when the parsed selection changes.
- Correction needs no Full Access, but without Full Access the keyboard can't read the App
  Group, so it stays on with German and English whatever the app says.
- The disabled local preference saved by the earlier prototype (`germanAutocorrectionPrototype`)
  is still ignored. The host field's `.autocorrectionType == .no` and all safety exclusions
  remain respected.

### Adding a language

1. Add a `KeyboardCorrectionLanguage` in `ios/KeyboardAutocorrection.swift`: its code, its
   preferred `UITextChecker` identifiers and the lowercase letters its words may use (e.g.
   `é è ê ç …` for French), and list it in `all`.
2. Add the same code and label to `KEYBOARD_AUTOCORRECTION_LANGUAGES` in
   `src/lib/keyboardAutocorrection.ts`. A Jest test fails while the two lists differ.
3. Add rule tests with the language's letters and check it on an iPhone with that dictionary.

Context checks remain strict even with the expanded candidate rules below. If a host
reports stale/missing left context, or neither dictionary offers an eligible replacement,
the prototype deliberately inserts an ordinary space. A lack of correction on a device
still needs host/dictionary investigation; changing the default alone does not prove a fix.

## Deliberately small scope

- Only the manually tapped space key can initiate a correction. No suggestion bar,
  automatic language detection, extra engine, learned dictionary, network, or text logging.
- `TextCheckerCorrectionProvider` uses public `UITextChecker` APIs with the dictionaries of
  all selected languages at once, since the keyboard has no language switch. German prefers
  `de_DE`, `de-DE`, then `de`, then another available German variant; English prefers
  `en_US`, `en-US`, `en_GB`, `en-GB`, `en`, then another English variant. A missing
  dictionary is skipped; with none, it returns no suggestions.
- The complete original must be misspelled in **every** selected dictionary, so with German
  and English an English word in German text (or the reverse) is never replaced. The flip
  side: a German typo that happens to be an English word stays as typed; deselecting English
  avoids that. Each proposal must pass the dictionary that offered it, and all languages'
  proposals compete under the rules below (`teh` → `the`, `recieve` → `receive`,
  `becuse` → `because`).
- Only the selected languages' letters count (German: a–z and äöüß, English: a–z), limited
  further to languages whose dictionary is installed. With English alone, a word with an
  umlaut is left as typed.
- **Choosing a replacement** (`KeyboardCorrectionRules.replacement`): every candidate gets a
  score, its weighted edit distance to the typed word plus 0.3 per doubling of its frequency
  rank, and the lowest score wins. There is no "ambiguous, do nothing" any more: the user
  accepted more wrong corrections for more corrections; backspace right after undoes one.
  - Edit weights (`editCost`, an optimal-string-alignment distance): a wrong letter on the key
    beside the right one in its row 1, on a touching key in the row above or below 1.5
    (`keyNeighbors`, the keyboard's own QWERTY rows), a letter for its umlaut (a↔ä, o↔ö, u↔ü,
    s↔ß) 1, any other wrong letter 2, a swap of adjacent letters 1, a missing or extra letter
    1.5. Case must match (lowercase or title case), 3–20 of the selected languages' letters.
  - Most weight allowed (`maxEditCost`): 1.5 for three letters, 2.5 for four, 4 for five or
    six, 5 from seven letters: roughly one, two, three and four mistakes.
  - Frequency (`frequencyRank`): the candidate's position among UITextChecker's completions
    of its first two letters, which Apple orders by likelihood; cached per dictionary and
    prefix (at most 48 lists). Unknown counts as rank 20,000.
  - Examples: `nciht` → `nicht`, `teh` → `the`, `kalppt` → `klappt`, `fubktiojiert` →
    `funktioniert`, `njxbt` → `nicht`, `wirklixh` → `wirklich`. `hsbd` becomes `habe`, not
    `hand`: both are two slips away (`habe` with one diagonal), and `habe` is about three times
    as common.
- **ae/oe/ue/ss** (German selected only): an unknown word whose spelling with ä/ö/ü (Ä/Ö/Ü
  at the start of a capitalised word) or ß is a known word becomes that word, ahead of every
  other candidate (`schoen` → `schön`, `Aerger` → `Ärger`, `Strasse` → `Straße`, `gruesse` →
  `grüße`, `groesser` → `größer`). Each pair is a choice (`transcriptions`, at most six pairs);
  between several respellings, ß counts 0.5 and an umlaut 0.3, plus frequency. A known word is
  never touched, so `neue`, `Feuer`, `Michael`, `dass`, `muss` and `Masse` stay. If a dictionary
  on the device (or a word iOS has learned) accepts the ae spelling itself, it stays too.
- **Own candidates.** UITextChecker doesn't always propose swaps or missing/extra letters and
  rarely words several slips away, so the provider also builds variants itself and keeps
  those a selected dictionary knows: first every single swap, missing and extra letter
  (`singleEditCandidates`), then words with one, two and three neighbouring-key slips
  (`neighborSlipCandidates`, at most one slip in three-letter words, two in four-letter words).
  All levels are searched, since a common word with more slips can beat a rare one with
  fewer; a level that would pass 1,500 variants is skipped with the levels after it. The
  space press waits for this, so the search stops after 100 ms and drops the level it was in.
- **Tuning.** Weights and the frequency factor were chosen on the 50,000 most common German
  and English words (FrequencyWords lists, used only offline, not shipped) with random typos,
  on the production Swift code with a stand-in dictionary. Without Apple's own proposals
  (worst case): one mistake (mixed slips, swaps, missing and extra letters) 90% right, 9%
  wrong; two slips 75% right, 23% wrong; three slips 42% right, 21% wrong, the rest unchanged;
  two mixed mistakes in one word about a third each right, wrong and unchanged.
  Wrong corrections are more likely now; immediately backspace to undo.
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
immediately before deletion. Missing left context in a nonempty field, delayed, truncated
or contradictory context abandons the correction and inserts an ordinary space.

UIKit can return either `nil` or an empty string on the right at end-of-document;
these empty boundary representations (and nil/empty no-selection reports) compare as
equivalent, rather than globally disabling correction. Nonempty right context still
must match exactly. A `nil` left context seeds
tracking as empty only when the proxy explicitly reports `hasText == false`, the right
side has no text, there is no selection and the field passes all safety gates. It never
authorizes a replacement by itself: the complete self-typed word must subsequently be
reported on the left before any deletion.

Will-change callbacks suspend replacement. Did-change callbacks retain the pending word
or undo only if the newly reported context exactly matches the expected own insertion.
Mismatches invalidate it. A space/backspace before the completion report fails closed,
even if a stale read looks correct. Actual cursor moves, selections and field switches
therefore still discard tracking; mere acknowledgements of our own insert do not.
Keyboard appearances/disappearances, keyboard switches, other insertions and deleting
invalidate state as before. Conservative false negatives are intended.

Diagnostic OSLog entries contain only fixed reasons, booleans and proposal counts, never
words, surrounding text, proposals, document UUIDs or other text content. The controller
reports gates/tracking at manual space, and the provider reports dictionary availability,
misspelling rejection or whether there is a unique eligible proposal. These help locate
future device-only blockers without recording what the user typed.

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
ambiguity, excluded tokens, Unicode, context invalidation, delayed reports, nil document
boundaries, matching own-change acknowledgements, pending-change blocking and undo.
The existing Catalyst controller regression suite now also covers default-on behavior, the
Settings switch (read at each space), English correction and undo
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
Xcode workspace if needed. `KeyboardAutocorrection.swift` and `TextCheckerCorrectionProvider.swift` are registered
in `withKeyboardExtension.js`; do not copy them manually into generated `ios/`.
A native rebuild is required; a JS-only update is insufficient.

## Initial validation performed in this Linux worktree

- Node **24.22.1**, `npm ci --ignore-scripts --no-audit --no-fund`; lockfiles unchanged.
- `npm test -- --runInBand`: **326 suites passed; 4,332 tests passed, 1 Swift test skipped**.
  This Jest count does not demonstrate native rule/controller execution on Linux.
- `npm run typecheck`: passed.
- `npm run lint`: no errors, 177 existing warnings outside the changed files.
- `npm run format` and `git diff --check`: passed.
- Native rule/capitalization scripts: attempted, unavailable (`swiftc` not installed).
- Catalyst regression runner: attempted, unavailable (requires macOS and Xcode).
- No local Swift compilation, iOS build or simulator testing was possible on Linux.
- The initial opt-in revision (`7a4277d99`) subsequently built successfully via GitHub
  Actions run `41077745294` and was installed on the iPhone. The user reported no visible
  correction. That build does not validate the subsequent default-on revision.

## Validation of the settings and language selection (Linux)

- Swift 6.2.4 (swift.org Ubuntu 24.04 toolchain): `sh scripts/test-keyboard-autocorrection.sh`
  passes all 104 checks with no compiler warnings, so Jest's Swift test runs there too.
- `TextCheckerCorrectionProvider` and the controller's new provider/switch code compiled and
  ran against a stand-in `UITextChecker`/`Logger` with fake German and English dictionaries
  (selection combinations, missing dictionaries, `de-AT` variants, rebuild on change).
- `KeyboardViewController.swift` + `KeyboardTouchTests.swift` pass `swiftc -parse` only; the
  UIKit controller and the Catalyst touch suite still need macOS/Xcode.

## Required Mac / iPhone checks before relying on it

1. Run the three native test commands above, then compile a clean prebuild. Confirm
   long-pressing space no longer opens the prototype menu.
2. With Full Access on, open Settings → Preferences → Keyboard → Autocorrection and switch it
   off: `nciht` and space stays `nciht `. Switch it on again and, without reopening the
   keyboard, the next `nciht` + space becomes `nicht `. English: `teh` + space → `the `,
   backspace → `teh`. Mixed text: `Hand`, `the`, `und` are never touched.
3. Languages: deselect English → `teh` + space stays `teh `, `nciht` still → `nicht`.
   Select only English → `nciht` may become an English word or stay, `Mädcehn` stays as typed,
   `teh` → `the`. The last selected language can't be deselected.
4. More mistakes: `fubktiojiert` → `funktioniert`, `njxbt` → `nicht`, `kalppt` → `klappt`,
   `wirklixh` → `wirklich`, `hsbd` → `habe`; backspace restores each. Umlauts: `schoen`,
   `fuer`, `moechte`, `Aerger`, `Strasse`, `gruesse` → `schön`, `für`, `möchte`, `Ärger`,
   `Straße`, `grüße`; `neue`, `dass`, `muss` stay. Long words with three slips, umlauts mistyped, names and slang
   may stay or become a wrong word; backspace right after undoes it.
5. Test on at least Notes, Messages and a Safari textarea/contenteditable, with fast typing
   and delayed host updates. No correction is preferable to any wrong-location replacement.
6. Move the cursor, select text, switch fields/apps/documents/keyboards, dismiss/reopen the
   keyboard, edit using another input source, and test undo after each. No stale replacement.
7. Test `.no`, password, URL, email and opaque fields; `foo_bar`, `fooBar`, addresses, numbers,
   emoji surrounding a word, `ä/ö/ü/ß`, and decomposed accented characters. Exclusions stay intact.
8. Dictate and insert an assistant answer containing a typo, then space: output stays unchanged.
   Verify smart quotes, shift, double-space period, ordinary/held/accelerated backspace,
   landscape, and no lost/duplicated fast taps. Dismiss and reopen: correction stays available.
9. Where neither German nor English is available, typing must work without correction. Dictionary proposals
   and timing are OS-dependent and are not proven by the stub-provider controller tests.
