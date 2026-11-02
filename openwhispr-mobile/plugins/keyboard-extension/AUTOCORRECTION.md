# Keyboard autocorrection

The keyboard corrects a word the user typed by hand when they tap space, `?`, `!`, `.` or `,`. It is on by default
and works on the device only: public `UITextChecker` APIs, the app's dictionary and bundled
word pairs (below), no network, and no typed text in logs.

## Settings

**Settings → Preferences → Keyboard → Autocorrection** (iOS only) has an on/off switch
(default on) and the languages to correct: multiple choice, German and English by default, at
least one and at most three. The Preferences row shows the selection, or "Off".

- The app saves `keyboardAutocorrectionEnabled` and `keyboardAutocorrectionLanguages` in its
  config and mirrors them to the App Group as `keyboard_autocorrection_enabled` (`"1"`/`"0"`)
  and `keyboard_autocorrection_languages` (`"de,en"`), see `src/lib/keyboardAutocorrectionSync.ts`.
- The keyboard reads both at every manual space, so a change applies without reopening it.
  Only an explicit `"0"` switches correction off. `KeyboardCorrectionLanguage.selection(from:)`
  ignores unknown codes, drops duplicates and caps the list at three; nothing usable means
  German and English. The controller creates `TextCheckerCorrectionProvider` on demand and
  reuses it while the parsed selection is unchanged. It releases the provider and its caches
  when the keyboard disappears or gets a memory warning, since the extension stays resident
  under a tight memory limit; the next correction attempt (space or punctuation) creates it
  again. Dictionary lookups run in local `autoreleasepool` scopes to bound temporaries.
- Correction needs no Full Access, but without it the keyboard can't read the App Group, so it
  corrects German and English whatever the app says, without the app's dictionary.

## The app's dictionary

The dictionary (Dictionary tab: words the user added, words OpenWhispr learned when they
corrected a dictation, and the shared team words that apply, as dictation uses them) also guides
autocorrection.

- The app mirrors it to the App Group as `keyboard_autocorrection_words`,
  `{"v":1,"personal":[…],"shared":[…]}` (`src/lib/keyboardAutocorrectionWords.ts`,
  `buildDictationHintTiers(false)`: no snippet triggers, hidden shared words left out), on start
  and on every change of the dictionary, the shared words or the config. Entries are NFC, trimmed,
  without controls, invisible characters or any spacing but single spaces, at most 64 UTF-16
  units (a longer one is skipped), deduplicated case-insensitively with personal words first, and
  capped at 2,000 entries and 64 KiB, so team words go first. A failed write is retried on the
  next change, when the app comes back to the foreground and at the next start. While
  autocorrection is off the value is empty.
- Sign-out and an account switch empty the value before the stores reset and keep it empty until
  both have (`clearingKeyboardWords` in `syncEngine.ts`), so no mix of the two accounts' words is
  ever written. Afterwards the keyboard follows the dictionary dictation uses: the words still
  stored on the device apply again once the app reloads them, until another account's sign-in
  wipes them; a previous account's shared words don't.
- The keyboard reads it at every correction, only with Full Access, and parses it again only when
  it changed (`KeyboardUserDictionary`, which enforces the bounds again and drops it with the text
  checker on a memory warning or when the keyboard disappears).
  The dictionary comes before the system's dictionaries, since it is where the user puts what iOS
  gets wrong (`KeyboardUserDictionary.decide`), in this order:

1. **Its spelling.** A word typed like a single-word entry but for its case gets the entry's
   spelling, even when iOS knows the word (`iphone`, `Iphone` → `iPhone`; `ki` → `KI`; `pi` → `Pi`;
   `hrudek` → `Hrudek`). An all-lowercase entry keeps what was typed (`Kubectl` at a sentence
   start stays); a phrase's words get no case (`york` stays).
2. **Protected words.** Every other word in the dictionary, or a word of a phrase of up to four
   words in it, is never corrected: no swap, slip, respelling or capital (`kubectl`, `os` in a
   team list). Entries with digits or punctuation (`GPT-6`, addresses) protect nothing.
3. **Typos into its words.** A word iOS doesn't know (every selected dictionary flags it, or German
   accepts it only as a possible compound, like `Hrudke` at a sentence start) becomes the closest
   single-word entry, ahead of every ordinary candidate, German
   respellings and missing spaces included (`openwhsipr` → `OpenWhispr`, `Hrudke` → `Hrudek`,
   `iphnoe` → `iPhone`, `Tmi` → `Tim`, `Sinead` → `Sinéad`). Within an edit weight of 1.5 for
   three or four letters (one mistake: a key beside the right one, a swap, a missing or extra
   letter) and 2.5 from five (a slip and a swap, a wrong far-away key, a missing letter and a
   slip; ae/oe/ue/ss for ä/ö/ü/ß cost little). A personal entry wins over an equally close
   shared one; two equally close entries of the same list are no pick, and ordinary correction
   decides. It is typed as stored, capitalised when the typed word was and the entry is
   lowercase. A word iOS knows stays (`Tom`, with `Tim` in the dictionary). The scan shares the
   press's 100 ms; cut short, it gives nothing.

Entries may be any letters (`é`, Cyrillic, also outside the selected languages) whose lowercase
and capital are single letters, stored with at most 64 UTF-16 units. The keyboard tracks typed
words of 2 to 64 letters, lowercase or with a capital first letter, for the dictionary, while
ordinary correction
still stops at twenty letters and the selected languages' letters. A two-letter word becomes a
two-letter entry only by its letters swapped or one key beside the right one (`Po`, `pu`, `Pk` →
`Pi`), never when it is one of the languages' common or kept two-letter words (`so`, `am`, `ip`,
`km`); a longer word never becomes a two-letter entry, nor a two-letter word a longer one.
The only one-letter word ever looked at is `i` (English, below): the dictionary's spelling of
it applies (`I`), and a lowercase entry `i` keeps it; no word becomes a one-letter entry.

## What gets corrected

- Only a manually tapped space, `?`, `!`, `.` or `,` key starts a correction; the mark is
  typed after the replacement (`nciht?` → `nicht?`). Other punctuation doesn't. There is no
  suggestion bar. A word ending in `.` is corrected too, so a domain typed as a word can be
  (`openwhsipr.com`); backspace right after undoes it.
- A `?`, `!`, `.` or `,` typed after a single space that follows a letter or digit deletes
  that space first (`nicht ?` → `nicht?`, also after a correcting space), with autocorrection on,
  in fields where it's allowed and `smartInsertDeleteType` isn't `.no`
  (`KeyboardAutocorrection.removesSpace`). Two spaces, a space after punctuation
  (`- .`) and selections are left alone.
- Dictionaries: German prefers `de_DE`, `de-DE`, `de`, then another German variant; English
  `en_US`, `en-US`, `en_GB`, `en-GB`, `en`, then another English variant. A missing dictionary
  is skipped; with none, nothing is corrected.
- A word is corrected only when every selected dictionary flags the whole word as misspelled,
  so an English word in German text (or the reverse) stays. Two exceptions follow below: the
  sentence's language, and German typed without umlauts.
- **The sentence's language.** With several languages selected, the keyboard looks at the last
  eight words before the cursor (two letters or more). When some are known to only one
  selected language and none only to another, the sentence is in that language, and a word only
  another language knows counts as a typo, unless it is common there (among the first 25
  completions of its first two letters): `woe` in a German sentence becomes `wie`, while `cool`
  stays. Mixed or empty context keeps the rule above.
- Only the selected languages' letters count (German a–z and äöüß, English a–z), limited to
  languages whose dictionary is installed.

### English: `I`, `I’m`, `don’t`

With English selected and installed, and only when the words before the cursor are English
(**the sentence's language** above: some word only English knows, none only another language
knows), a fixed list
(`KeyboardCorrectionRules.englishContractions`) adds the capital or the apostrophe: `i` → `I`,
`im` → `I’m`, `ive` → `I’ve`, `dont`, `isnt`, `doesnt`, `didnt`, `wasnt`, `werent`, `havent`,
`hasnt`, `hadnt`, `wouldnt`, `couldnt`, `shouldnt`, `arent` → `…n’t`, `youre`, `theyre`,
`thats`, `whats` → `you’re`, `they’re`, `that’s`, `what’s`. A capital first letter is kept
(`Dont` → `Don’t`); mixed and all caps stay. Words that are words as typed aren't in it
(`id`, `ill`, `cant`, `wont`, `lets`, `its`, `were`, `well`, `hell`). With no words before
(`im` opening a field), mixed or German words (`ich bin im`), or English not selected, these
words are corrected as before, so `im` stays. The sentence is checked against every language
the keyboard knows whose dictionary is installed, selected or not, so with English alone
selected `ich bin im` and `so im` stay too; with no other dictionary installed to tell English
from, the list is off. The app's dictionary goes first: its spelling
(`IM`) or protection (`im`) wins. The list runs after the dictionary's decision and before
every ordinary candidate (`TextCheckerCorrectionProvider.englishContraction`); a press that runs
out of time reading the sentence corrects nothing and looks nothing more up, and `i`, which
nothing else corrects, never reaches ordinary correction. The apostrophe is
`’`, or `'` in fields without smart quotes, as the apostrophe key types there
(`KeyboardAutocorrection.correction(straightApostrophe:)`). Backspace right after undoes it
like any correction. The sentence's language doesn't reset at a full stop, so a German
sentence after an English one can still count as English for its first words.

### Choosing a replacement

`KeyboardCorrectionRules.replacement` scores every candidate: its weighted edit distance to the
typed word plus 0.3 per doubling of its frequency rank. The lowest score wins; there is no
"ambiguous, do nothing", so a wrong word is possible, and backspace right after undoes it.

- Edit weights (`editCost`, optimal string alignment): a wrong letter on the key beside the
  right one in its row 1, on a touching key in the row above or below 1.5 (`keyNeighbors`, the
  keyboard's own QWERTY rows), a letter for its umlaut (a↔ä, o↔ö, u↔ü, s↔ß) 1, any other wrong
  letter 2, a swap of adjacent letters 1, a missing or extra letter 1.5, and ae/oe/ue typed for
  ä/ö/ü 0.3 and ss for ß 0.5, so German typed without umlauts can carry typos too
  (`moeglichkwitne` → `Möglichkeiten`: ö, a slip and a swap, 2.3).
- Most weight allowed (`maxEditCost`): 1.5 for three letters, 2.5 for four, 4 for five or six,
  5 from seven: roughly one, two, three and four mistakes.
- Frequency (`frequencyRank`): the candidate's position among `UITextChecker`'s completions of
  its first two letters, which Apple orders by likelihood; cached per dictionary and prefix (at
  most 48 lists). Unknown counts as rank 20,000. The provider can score with corpus ranks
  instead (**Frequency lists** below); the keyboard doesn't yet.
- A capitalised word keeps its capital; case otherwise changes only for German nouns (below).
- Examples: `nciht` → `nicht`, `teh` → `the`, `kalppt` → `klappt`, `fubktiojiert` →
  `funktioniert`, `njxbt` → `nicht`, `wirklixh` → `wirklich`, `hsbd` → `habe` (two slips like
  `hand`, but about three times as common).
- **Two words for one** (`ichhabe` → `ich habe`): a candidate with one space costs 1 for the
  missing space plus the edit cost of its two words joined, within the same `maxEditCost`, and
  ranks as its rarer word. Both words need two letters or more and a frequency rank of at most
  100 (`maxSplitRank`), and the second word must be lowercase, so a German noun is never split
  off (`dashaus` stays, even if UITextChecker proposes `das Haus`). UITextChecker's own
  proposals with a space count only under the same rules, both words known in the dictionary
  that proposed them. This is a heuristic: two common words can still be split off an unknown
  compound or name; backspace right after undoes it.

### Two-letter words

A two-letter word is only ever corrected into its two letters swapped (`twoLetterSwap`): `os`
→ `so`, `mi` → `im`, `si` → `is`, `Os` → `So` at a sentence start. The swap must be one of the
common two-letter words of the sentence's language (of any selected language when the sentence
has none; `KeyboardCorrectionLanguage.twoLetterWords`) and known to its dictionary, and the typed
word none of any selected language's. A dictionary knowing the typed word doesn't stop it
(English knows `os`); the lists keep what people type (`na`, `eh`, `oh`, `on`, `no`), and
`keptTwoLetterWords` protects further words that are no swap target themselves (`hä`, `ma`,
`ta`, `ad`, `ow`, `ew`).

Otherwise a two-letter word may become a word one neighbouring key away (`twoLetterSlip`):
`ia` → `is` in an English sentence and `ja` in a German one, `qm` → `am`, `zi` → `zu`. Exactly
one of its slips must be a common two-letter word of the sentence's language (of any selected
one without a sentence language, so `ia` at a sentence start stays, being `is` or `ja`), the typed
word must be in no list and unknown to every selected dictionary (`km`, `ca`, `zb`, `nr` stay,
and are kept in the lists too). Nothing else is proposed for a two-letter word.

### Capitalised words German accepts as compounds

German's dictionary accepts almost any capitalised word as a possible compound noun, so
`Ichhabe` or `Moeglichkwitne` at the start of a sentence pass the misspelling check. Such a word
is still treated as a typo (`acceptedOnlyAsCompound`) when German is selected and accepts it, no
other selected language does (so `Michael` stays), it has no frequency rank (so `Haus` stays),
and every dictionary flags it in lowercase (so `Erleben` and `Einmal` stay). It is then only
corrected (`isCompoundCorrection`) into two common words with a German subject pronoun first
(`Ich habe`; never `Morgen rot`), or into a common (ranked) respelling or completion that
begins like one of the word's respellings up to and including an ä/ö/ü/ß the word spelled as
ae/oe/ue/ss (`möglichk…` → `Möglichkeiten`; an unrelated pair is no evidence, so `Feuerwache`
never becomes `Feuerwächter`). A press that runs out of time while checking this corrects
nothing. Apple's proposals, single edits
and slips aren't used for it.

The same check runs on candidates for an ordinary typo: a candidate German accepts only as a
possible compound (`Ichhabe`, a swap away from `Ichhaeb`, or `ichhabe` read as a noun) is no
word, so its common two-word splits take its place (`Ich habe`, `ich habe`;
`repairingCompounds`), and Apple's proposals and the word's own capital that are only that are
dropped. Out of time, only lowercase candidates stay, since the check may not have reached a
capitalised one. A rare compound starting with a pronoun (`Wirsing` → `Wir sing`)
or spelled with ae/oe/ue can still be corrected wrongly; backspace right after undoes it.

### Own candidates

`UITextChecker` doesn't always propose swaps or missing/extra letters and rarely words several
slips away, so the provider also builds variants and keeps those a selected dictionary knows:
every single swap, missing and extra letter (`singleEditCandidates`), then words with one, two
and three neighbouring-key slips (`neighborSlipCandidates`; one slip in three-letter words, two
in four-letter words). All levels are searched, since a common word with more slips can beat a
rare one with fewer; a level that would pass 1,500 variants is skipped with the levels after
it. The space press waits for this, so the search stops 100 ms after the press asked for
suggestions (Apple's proposals included) and drops the level it was in.

Two cheaper searches run first, inside the same 100 ms, which is checked before every
dictionary lookup and every scored completion; a search cut short by it gives nothing, like a
slip level, and the searches after it don't start. UITextChecker's proposals with a space are
checked against the split rules within the same 100 ms too:

- **Long words** (seven letters or more, `completionPrefixes`): UITextChecker's completions of
  the word's start, from one letter short down to half the word (five letters at least),
  longest first (`completionCandidates`). Per dictionary, it tries the German respellings
  first (most pairs replaced, `möglichk` for `moeglichkwitne`) and the word as typed last, four
  spellings at most. The longest prefix with a completion close enough (`editCost`) wins; after
  three prefixes that complete only to far-away words it gives up. At most 40 completions per
  prefix, in Apple's order. This finds long words whose end went wrong, which the slip search can't reach (too
  many variants) and Apple rarely proposes. A title-case word keeps its capital.
- **Missing spaces** (`splitCandidates`): every cut into two words of two letters or more
  that one selected dictionary knows as typed and ranks within `maxSplitRank` (`isCommonSplit`). A German noun
  typed in lowercase isn't known as typed, so it never becomes the second word.

### German without umlauts, and nouns

German selected only.

- **ae/oe/ue/ss**: an unknown word whose spelling with ä/ö/ü (Ä/Ö/Ü at the start of a
  capitalised word) or ß is a German word becomes that word, ahead of every other candidate
  (`schoen` → `schön`, `Aerger` → `Ärger`, `gruesse` → `grüße`, `groesser` → `größer`). Each
  pair is a choice (`transcriptions`, at most six pairs); the respelling replacing the most
  pairs wins (`grüße` over the Swiss `grüsse`), then ß 0.5 and an umlaut 0.3 plus frequency.
- A word some dictionary accepts as typed (English, Swiss spellings, words iOS has learned) is
  respelled only when it isn't a common word in any selected dictionary and the respelling is
  German (`moechte` → `möchte`); a ß respelling also needs German not to know the ss spelling,
  or the ß spelling to be common. So `neue`, `Feuer`, `Michael`, `dass`, `muss`, `Masse`,
  `Busse`, `sued` and `phoenix` stay.
- **Nouns** are capitalised for users who type in lowercase: a lowercase word that German's
  completions list only capitalised, and that no selected dictionary lists in lowercase, gets
  its capital, typed right (`haus` → `Haus`) or corrected (`strasse` → `Straße`, `hsus` →
  `Haus`). Words with both forms (`essen`/`Essen`, `morgen`/`Morgen`), verbs, adjectives and
  English words (`hand` with English selected) stay. Where the completions don't contain the
  word itself, it stays lowercase.

### Tuning

Weights and the frequency factor were chosen offline on the 50,000 most common German and
English words (FrequencyWords lists, not shipped) with random typos, running the production
Swift rules with a stand-in dictionary. Without Apple's own proposals (worst case): one mistake
(slips, swaps, missing and extra letters) about 90% right and 9% wrong; two slips 75% right and
23% wrong; three slips 42% right, 21% wrong and the rest unchanged.

### Context: the word before

The word before chooses between the candidates for a word that is being corrected anyway
(`ich hsbd` → `habe`, not `hand`; `das ist wue` → `wie`). Each candidate's score loses
0.15 edits per bit by which the corpus finds it more likely after that word than anywhere
(`KeyboardContextModel.bonus`, at most 8 bits; `TextCheckerCorrectionProvider.defaultContextWeight`
and `defaultContextCap`); a split takes its first word's. A pair missing from the file adds
nothing, so the score without it is today's. Context never makes a word a candidate, never
corrects a word iOS knows, comes after the app's dictionary (its spelling, protection and typo
targets are decided before any candidate is scored), and doesn't touch two-letter swaps and
slips, the English contractions, ae/oe/ue/ss respellings (they still win first), the
respelling of accepted words or noun capitals.

- **The word before** (`KeyboardCorrectionRules.wordContext(before:)`), from the text before
  the word that the keyboard has already read, kept in memory for the press only and never
  logged: the previous token when it is all letters (lowercased, NFC); a sentence start at the
  start of the field, after a line break, or after `.`, `!` or `?` ending a word of two letters
  or more; nothing otherwise (digits, URLs, apostrophes, hyphens, quotes, commas, `z.B.`, `a.`).
- **Language**: with one language selected, its file, unless one of the last eight words
  before is known only to another installed language (`hasForeignWords`: `ich vat` with
  English alone, or a mixed sentence); shared words and a field's start keep it. With several,
  the sentence's language
  (**the sentence's language** above), and none while it is unknown. A sentence start gets
  context only with one language selected, since the sentence before may be in another. The check shares the press's 100 ms; out of
  time, no context.
- **Data**: `KeyboardContext-de.bin` (2.0 MB) and `KeyboardContext-en.bin` (1.8 MB), bundled
  as resources of the keyboard target and memory-mapped from its bundle for the selected
  languages when the provider is created (and released with it on a memory warning or when
  the keyboard disappears). `node scripts/build-keyboard-context-lists.mjs --out ios` makes
  them, byte for byte the same each time, from the Leipzig Corpora Collection's
  `deu_news_2023_1M` and `eng_news_2023_1M` (checksummed): per language the 300,000 most
  frequent pairs seen at least three times among its 50,000 most common words, plus sentence
  starts, with their positive pointwise mutual information log2(P(next | previous) / P(next))
  in 1/16 bits; the probabilities count every word, so pruning doesn't inflate them.
  The Leipzig download corpora are licensed under CC BY 4.0 (Terms of Usage,
  wortschatz.uni-leipzig.de/en/usage, archived 2024-01-21 at web.archive.org: “All corpora
  provided for download are licensed under CC BY”); the app's licenses screen credits
  “© 2024 Universität Leipzig / Sächsische Akademie der Wissenschaften / InfAI” with the
  corpora and what was made of them.
- **Format** (little-endian): `OWCX`, version 1, value kind 1, language, word and pair counts,
  `u32` word offsets, the words sorted bytewise (`.` is the sentence start), padding to 4,
  `u32` pair keys (previous << 16 | next, ascending) and `u8` values. A wrong header or sizes
  is no model; lookups stay inside the file.
- **Cost** (Linux): opening 20–100 µs, a lookup 0.9 µs median, 1.6 µs at the 95th percentile.
  Nothing is decoded or kept beyond the mapping, whose pages are clean and droppable; a lookup
  allocates only its key's bytes. Not yet measured in
  the extension on an iPhone.
- **Tuning** (`sh scripts/benchmark-keyboard-autocorrection.sh --sentences`, Linux): one typo
  (the tuning mix: 50% a key beside in its row, 20% one row off, 10% each swap, missing, extra
  letter) in up to two words of 1,500 Wikipedia sentences per language and split
  (`deu_wikipedia_2021_300K`, `eng_wikipedia_2016_300K`; split by article into dev and test,
  duplicates and sentences also in the news corpora dropped;
  `scripts/build-keyboard-context-sentences.mjs`), typed after the sentence's own words before
  it. Weights 0.05–0.5 and caps 4 and 8 were compared on dev; 0.15 with cap 8 gains almost as
  much as the larger weights while losing far fewer words. 100,000 pairs (0.7 MB each) gain a
  little less, all pairs seen three times (2.8 MB each) a little more. Held-out test, right /
  wrong / unchanged, without → with context:

  | Series | Without | With | Changed |
  | --- | --- | --- | --- |
  | de, German and English | 2438 / 199 / 104 | 2469 / 168 / 104 | +35 −4 |
  | de, German only | 2531 / 183 / 27 | 2561 / 153 / 27 | +37 −7 |
  | en, German and English | 2377 / 335 / 23 | 2431 / 281 / 23 | +57 −3 |
  | en, English only | 2431 / 293 / 11 | 2478 / 246 / 11 | +51 −4 |

  Wrong corrections fall by 16–19%. The test sentences come from articles the dev sentences
  don't; one English census sentence template with other numbers still appears in both. With
  the word before mistyped too and left so (`--noisy-previous`), the gain shrinks and almost
  nothing is lost: +6 −0 (de, both), +8 −0 (de only), +14 −1 (en, both), +13 −1 (en only). The
  control (the same words typed right) and typos that make another real word change no more
  with context than without; one German control word, `starb` after a citation, becomes
  `star` either way. On the LibreOffice benchmark (`--with-context`) only `committe` and
  `committy` after `This is ` change, to `committed` instead of `committee`. These are Linux
  simulations (stand-in dictionaries, no Apple proposals, one typo with the right or one
  mistyped word before it); an Apple-backed run and a device check are still to come.

### Frequency lists (built, not enabled)

`TextCheckerCorrectionProvider(languages:frequencyLists:)` can score candidates with a corpus
rank per language (`KeyboardFrequencyList`) instead of UITextChecker's completion order: for
each of a language's 50,000 most common words, its rank among the list's words with the same
first two letters, the scale of the completion rank, so `frequencyWeight` and the 20,000 cap
keep their meaning. A word missing from a language's list takes its completion rank there; the
lowest over the selected languages counts. Only the score changes: whether a word is common at
all (both words of a split within `maxSplitRank`, the respelling of an accepted word, a word
common in another language, compound checks) is still decided by the completions
(`completionRank`, and `KeyboardCorrectionRules.replacement(splitRank:)` for splits).

The keyboard builds its provider without lists, and no list is bundled, because the benchmark
below couldn't show they help: on Linux the stand-in completions come from the same corpus as
the lists, so the comparison there says nothing about Apple's order. To decide, run
`sh scripts/benchmark-keyboard-autocorrection.sh --frequency` on a Mac (Apple's UITextChecker)
and enable them only if more words come out right and none more wrong, in both languages and
the control series, then measure the extension on an iPhone (below).

- **Data**: `node scripts/build-keyboard-frequency-lists.mjs --out <dir>` downloads the pinned
  AOSP word lists (codeberg.org/Helium314/aosp-dictionaries, `main_de` and
  `main_en_US__experimental`, checksummed) and writes `KeyboardFrequency-de.bin` (789 KiB) and
  `-en.bin` (663 KiB). Both are built from the Leipzig Corpora Collection
  (wortschatz.uni-leipzig.de), source lists under CC BY 4.0. The legacy `main_en_US` list
  (OpenBoard/AOSP) has no stated license and isn't used. Kept: words of the language's letters,
  two or more, not `not_a_word`, lowercased and NFC, in the source's frequency order.
- **Format**: little-endian; `OWFR`, version 1, rank kind 1 (two-letter prefix), the language,
  the count, `u32` offsets, `u16` ranks, then the words sorted bytewise. The file is
  memory-mapped; opening reads the header and two offsets, and a lookup binary-searches the
  mapped bytes with bounds checks, so it never reads outside the file. A missing file, or one
  whose header or sizes are wrong, is no list; the words' order and uniqueness aren't checked
  on opening (that would read the whole file) and are the generator's to guarantee.
- **Cost** (Linux, both lists, `--measure-lists`): opening 150 µs (German, cold) and 23 µs,
  a lookup in both 1.6 µs median and 3.1 µs at the 95th percentile, 36 KiB allocated; the
  mapped pages are clean file pages the system can drop. Not yet measured in the extension on
  an iPhone (Instruments: footprint with both languages, first and warm press latency,
  provider recreation after a memory warning).
- **Enabling** them: bundle the two files as resources of the keyboard target
  (`withKeyboardExtension.js` has no Resources phase yet), open them from the extension's bundle
  for the selected languages in `currentCorrectionProvider()`, and add the attribution to the
  app's licenses screen: “Word frequencies: Leipzig Corpora Collection, via
  Helium314/aosp-dictionaries, CC BY 4.0 (creativecommons.org/licenses/by/4.0); lowercased,
  reduced to the 50,000 most common words per language and ranked.”

### Never corrected

- Digits, punctuation, underscores, mixed or all caps, URL- and email-like tokens, emoji,
  decomposed combining sequences, one-letter words (except `i` in English, above), two-letter
  words except for their swap or slip (above), `im` in English and the app's dictionary, words
  over twenty letters (except for the app's dictionary), and words following punctuation.
- Fields other than default text fields: secure fields, fields hiding their text,
  `.autocorrectionType == .no`, URL, email, ASCII-only, numeric and other specialised keyboard
  types. Selections are never replaced.
- Existing text, dictation and assistant output: `typeText` only invalidates correction state.

## Replacement and undo safety

`KeyboardAutocorrection.swift` is Foundation-only; its provider protocol keeps proposals
independent of the controller. It tracks the expected host context after manual inserts, not
just the word. Before a replacement the controller reads both sides of the cursor, the
selection, field traits and document UUID, and requires an exact match with the expected
context; after querying the checker it reads them all again, immediately before deleting.
Missing left context in a non-empty field, or delayed, truncated or contradictory context,
abandons the correction and inserts an ordinary space.

UIKit may report `nil` or an empty string on the right at the end of a document; both compare
as equal, as do nil and empty selections. Non-empty right context must match exactly. A `nil`
left context seeds tracking as empty only when the proxy reports `hasText == false`, nothing on
the right and no selection; it never authorises a replacement by itself.

Will-change callbacks suspend replacement. Did-change callbacks keep the pending word or undo
only when the new context exactly matches the keyboard's own insertion; anything else
invalidates it, and a space or backspace before the report fails closed. Cursor moves,
selections, field and keyboard switches, appearing and disappearing invalidate tracking.

Backspace within **3 seconds** of a correction (`KeyboardAutocorrection.undoWindow`) deletes the
corrected word and its space, `?`, `!`, `.` or `,` (`Edit.delimiter`) and restores the original without
it; later, backspace is ordinary and deletes that character. Letters typed right after a
correcting mark are never tracked as a word. Undo needs the same document and an exact, freshly read
context, and is one-shot; the restored word isn't tracked, so the next space doesn't correct it
again. While a tap would undo, every built backspace key shows `arrow.uturn.backward` and
announces “undo autocorrection”; otherwise it shows `delete.left` and announces “delete”. The
face matches observable host state: will-change hides undo, and an exact matching did-change
report can restore it. A one-shot timer ends the indicator at the original deadline, without
another key press; acknowledgements and layout rebuilds never extend it. Shift and page switches
preserve undo. Held backspace drops undo and switches to the delete face before its first
repeated deletion. Tap-time context checks remain authoritative.

Word indexing and deletion use Swift `Character`; only the provider uses UTF-16
`NSRange(_:in:)` for Apple's API. Public proxy reads can't form an atomic transaction with the
host, so the keyboard fails closed on observable changes; it can't detect an unreported cursor
move to an identical context. No private host APIs are used.

OSLog entries contain only fixed reasons, flags, counts and the sentence's language code, never
words, surrounding text, proposals or document UUIDs.

## Tests

From `openwhispr-mobile/` (the native ones need macOS and Xcode, except the rules script,
which runs wherever `swiftc` and Foundation are installed):

```bash
sh scripts/test-keyboard-autocorrection.sh
python3 plugins/keyboard-extension/tests/run-keyboard-touch-tests.py
npm test -- --runInBand
sh scripts/benchmark-keyboard-autocorrection.sh   # [--frequency] [--rev <commit>] [--details]
```

- `tests/KeyboardAutocorrectionTests.swift`: the app's dictionary (parsing, bounds, its
  spelling, protection, targets, budgets, ties between and within its lists, precedence over the
  ordinary pick, long and accented words, and the state machine's edit), language selection, sentence language, scoring,
  key neighbours, generated candidates, respellings, completion prefixes, missing spaces,
  excluded tokens, Unicode, context invalidation, delayed reports, document boundaries,
  own-change acknowledgements, non-consuming undo queries and their consistency with consumption
  (including the inclusive 3-second window), the frequency list format (ranks, case and
  composition, misses, malformed files and offsets), the split rule's own ranks, and the
  English contractions (the table, title case, excluded words, `i` and `im` reaching the
  provider, the straight apostrophe, undo, the dictionary first). Jest runs it when `swiftc` is
  available and skips it otherwise.
- `tests/TextCheckerCorrectionProviderTests.swift` (off Apple platforms, run by the same
  script): the production provider with stand-in UIKit and os modules (`tests/linux/`) and
  small word lists: contractions only in English sentences (none without words before, in
  German, mixed or with English deselected), the dictionary first, ordinary correction
  unchanged, frequency lists that change the score but not the split rule, and word-pair
  context (`ich hsbd` → `habe`, other or unusable words before, weight 0, real and dictionary
  words untouched, the sentence's language with two selected).
- The word-pair format, `wordContext` and the context's place in the score are in
  `tests/KeyboardAutocorrectionTests.swift`.
- `tests/KeyboardTouchTests.swift` (Catalyst): the controller with a stub provider: correction,
  the Settings switch, English, neighbouring-key slips, umlaut respelling, noun capitalisation,
  long words, missing spaces, undo and its window, the undo image/label and timer, host-report
  hide/restore, rebuilt keys, disappearance, recorrection suppression, double space,
  silent hosts, cursor changes, field guards, transcript exclusion, held delete, and the app's
  dictionary (a protected word, a typo to the user's or a shared word and its undo, the
  dictionary's case and its undo, the user's word over the system's).
- Jest: the settings screen and Preferences row, the App Group mirror (dictionary included:
  serialization, bounds, change tracking, failed writes, the account reset), the language list kept in
  step with the keyboard's, and source registration in `withKeyboardExtension.js`.

`KeyboardAutocorrection.swift`, `KeyboardFrequencyList.swift`, `KeyboardContextModel.swift`
and `TextCheckerCorrectionProvider.swift` are registered in `withKeyboardExtension.js`, and
`KeyboardContext-{de,en}.bin` as the keyboard target's resources; a native rebuild is
required.

### Benchmark

`tests/benchmark/libreoffice-{de,en}.tsv` are LibreOffice's autocorrect word corrections
(`extras/source/autocorr/lang/{de,en-US}/DocumentList.xml`, Mozilla Public License 2.0; test
data only, never bundled or used by the keyboard), made by
`node scripts/build-keyboard-autocorrection-benchmark.mjs` from pinned, checksummed commits:
every entry typed as one word of letters whose correction is letters with single spaces,
apostrophes or hyphens, so typos, case changes, missing spaces and contractions; symbol, emoji
and pattern entries are dropped. 209 German and 843 English entries.
`scripts/benchmark-keyboard-autocorrection.sh` types each word letter by letter through
`KeyboardAutocorrection` and the production `TextCheckerCorrectionProvider`, then a space, with
no app dictionary: right (the expected word), wrong (another change), unchanged. Series: German
and English selected (the default), one language, and after a fixed `Das ist ` / `This is `;
the control series types each single-word correction itself, which must stay. On a Mac it uses
Apple's UITextChecker (Mac Catalyst; its dictionaries may differ from an iPhone's). On Linux it
uses stand-in modules with the 400,000 most common words of the AOSP lists as the dictionaries
and their completions, and no proposals of Apple's: a simulation of the rules, not of iOS.

Linux simulation, rules and provider at 52c234689 (before the English contractions):

| Series | Right | Wrong | Unchanged |
| --- | --- | --- | --- |
| de, German and English | 154 | 39 | 16 |
| de, German only | 164 | 23 | 22 |
| de, after `Das ist ` | 164 | 23 | 22 |
| en, German and English | 673 | 116 | 54 |
| en, English only | 679 | 106 | 58 |
| en, after `This is ` | 677 | 109 | 57 |
| control de (160) / en (556) | 159 / 556 | 1 / 0 | 0 / 0 |

With the contractions, after `This is ` the entries `couldnt`, `didnt`, `doesnt`, `dont`,
`shouldnt`, `werent` and `i` come out right (684 right, 105 wrong, 54 unchanged; before,
`didnt` → `dint`, `dont` → `don`, `werent` → `ardent`); every other series is unchanged, since
without English words before nothing in the list applies. Most wrong results in the simulation are rare corpus words (`challange` →
`challah`) and splits into short corpus words (`anbd` → `an bd`) that Apple's dictionaries
would likely not offer; the control's one change, `Accesoire` → `Accessoire`, is LibreOffice's
own misspelling.

Frequency lists in the simulation (`--frequency`): with completions in corpus order, as above,
two right words turn wrong and nothing else changes: `opnion` becomes `onion` instead of
`opinion` in each English series, and `Dockument` becomes `Document` instead of `Dokument` with
German and English selected. Each is a tie in edit cost (1.5) decided by rank: the stand-in
completions count case variants and hyphenated forms (`On`, `ON`, …), so `onion` ranks 22nd
there and 13th in the deduplicated list, which flips a near tie (0.03); and the lowest rank over
the selected languages lets English `document` outrank German `dokument`. In a sensitivity experiment with alphabetical
completions (`--alphabetical-completions`, an order that carries no frequency) the lists gain
37 German and 67 English words (German and English selected), the control unchanged. That
shows the score is sensitive to the rank source; it says nothing about whether Apple's order is
worse than the lists' or by how much. Apple's baseline and the extension's footprint are not
measured, so the lists stay off.

## Checks on an iPhone

1. With Full Access, switch Autocorrection off: `nciht` + space stays. Switch it on without
   reopening the keyboard: `nciht` + space → `nicht`. `teh` → `the`; backspace within three
   seconds → `teh`, later it only deletes the space.
2. Deselect English: `teh` stays, `nciht` → `nicht`. The last language can't be deselected.
3. `fubktiojiert`, `njxbt`, `kalppt`, `wirklixh` → `funktioniert`, `nicht`, `klappt`,
   `wirklich`. `schoen`, `moechte`, `strasse`, `gruesse` → `schön`, `möchte`, `Straße`,
   `grüße`; `dass`, `muss`, `Masse` stay. `haus` → `Haus`; `essen`, `morgen` stay.
   `das ist woe` → `wie`; `this is woe` and `das ist cool` stay. `moeglichkwitne` →
   `Möglichkeiten`, `ichhabe` → `ich habe` (backspace → `ichhabe`); `dashaus` stays.
   At a sentence start, `Ichhabe` → `Ich habe` and `Moeglichkwitne` → `Möglichkeiten`;
   `Donaudampfschiff` stays. `Ichhaeb` → `Ich habe`, `ichhaeb` → `ich habe`. `os`, `mi`, `Os` → `so`, `im`, `So`;
   `ia` → `is` in an English sentence, `ja` in a German one; `qm` → `am`; `am`, `na`, `on`,
   `km`, `ca` stay.
4. Notes, Messages and a Safari text area, with fast typing: no correction is better than one in
   the wrong place. Move the cursor, select text, switch fields, apps and keyboards: no stale
   replacement.
5. Context: `ich hsbd` → `ich habe`, `das ist wue` → `das ist wie`; `hsbd` alone and after a
   URL → `hand`. Measure the keyboard in Instruments: footprint with German and English,
   first press after appearing and warm presses, after a memory warning.
6. Add `Hrudek`, `OpenWhispr` and `iPhone` to the dictionary: `Hrudek` + space stays, `Hrudke`
   and `hrudke` → `Hrudek`, `openwhsipr` → `OpenWhispr` (backspace → `openwhsipr`), `iphone` and
   `Iphone` → `iPhone`; `Tom` stays with `Tim` in it. Add `Pi`: `pi` → `Pi`, `Pi` stays. Remove them: `Hrudek` is corrected
   like any word again. Switch accounts: the previous account's words no longer apply.
7. Password, URL, email and `.no` fields, `foo_bar`, `fooBar`, numbers, emoji, dictation and
   assistant output: unchanged.
