import Foundation
import UIKit

/// The LibreOffice benchmark (`tests/benchmark/libreoffice-*.tsv`): each typed word goes letter by
/// letter through `KeyboardAutocorrection` with the production `TextCheckerCorrectionProvider`,
/// then a space, with no app dictionary. Outcomes: right (the expected word), wrong (another
/// word), unchanged. The control series types each single-word correction itself, which must stay.
///
/// On macOS (Mac Catalyst) the provider uses Apple's UITextChecker. On Linux it uses a word list
/// in its place (`tests/linux/UIKit.swift`): a simulation of the rules, not of Apple's
/// dictionaries, completions or proposals (it proposes none).
///
///   keyboard-autocorrection-benchmark --fixtures <dir> [--lexicons <dir>] [--frequency <dir>]
///     [--alphabetical-completions] [--details]
///   keyboard-autocorrection-benchmark --measure-lists <dir>   (open time, lookup latency, memory)
///
/// Built with `-D BASELINE` it runs against an earlier provider without frequency lists
/// (`scripts/benchmark-keyboard-autocorrection.sh --rev <commit>`).
@main
enum KeyboardAutocorrectionBenchmark {
  struct Case {
    let typed: String
    let expected: String
    let tags: [String]
  }

  enum Outcome: String { case right, wrong, unchanged }

  struct Series {
    let name: String
    let languages: [KeyboardCorrectionLanguage]
    let prefix: String
    let cases: [Case]
    /// Correct words that must stay as typed.
    let control: Bool
  }

  static func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }

  static func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

  static func loadCases(_ url: URL) -> [Case] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      fatalError("Missing fixtures: \(url.path)")
    }
    return text.split(separator: "\n").compactMap { line in
      guard !line.hasPrefix("#") else { return nil }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count >= 2 else { return nil }
      return Case(typed: fields[0], expected: fields[1],
                  tags: fields.count > 2 ? fields[2].split(separator: ",").map(String.init) : [])
    }
  }

  static func classify(_ series: Series, _ results: [String]) -> [Outcome] {
    zip(series.cases, results).map { item, result in
      if result == item.expected { return .right }
      return result == item.typed ? .unchanged : .wrong
    }
  }

  static func outcomeText(_ series: Series, provider: KeyboardCorrectionProvider) -> [String] {
    series.cases.map { item in
      let document = UUID()
      var state = KeyboardAutocorrection()
      var context = KeyboardCorrectionContext(document: document, before: series.prefix, after: "",
                                              selection: nil, allowed: true)
      for letter in item.typed {
        state.manualInsertion(String(letter), in: context)
        context = context.inserting(String(letter))
        state.reconcile(context)
      }
      return state.correction(in: context, provider: provider)?.replacement ?? item.typed
    }
  }

  static func summary(_ outcomes: [Outcome]) -> String {
    let right = outcomes.filter { $0 == .right }.count
    let wrong = outcomes.filter { $0 == .wrong }.count
    let unchanged = outcomes.filter { $0 == .unchanged }.count
    return "right \(right)  wrong \(wrong)  unchanged \(unchanged)  (of \(outcomes.count))"
  }

  #if os(Linux)
  /// A Linux stand-in dictionary: the first `limit` words of an AOSP word list (most common first).
  static func loadLexicon(_ url: URL, language: String, limit: Int, alphabetical: Bool) -> StandInLexicon {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { fatalError("Missing lexicon: \(url.path)") }
    var words: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix(" word=") {
      let fields = line.dropFirst().split(separator: ",")
      guard !fields.contains("not_a_word=true") else { continue }
      words.append(String(fields[0].dropFirst("word=".count)).precomposedStringWithCanonicalMapping)
      if words.count >= limit { break }
    }
    return StandInLexicon(language: language, wordsByFrequency: alphabetical ? words.sorted() : words)
  }
  #endif

  /// Resident memory in KiB, anonymous (allocated) and file-backed (mapped files: clean pages
  /// the system can drop), on Linux; nil elsewhere.
  static func residentKiB() -> (anonymous: Int, file: Int)? {
    #if os(Linux)
    guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return nil }
    func value(_ key: String) -> Int? {
      status.split(separator: "\n").first { $0.hasPrefix(key) }
        .flatMap { Int($0.split(separator: " ").dropFirst().first ?? "") }
    }
    guard let anonymous = value("RssAnon:"), let file = value("RssFile:") else { return nil }
    return (anonymous, file)
    #else
    return nil
    #endif
  }

  #if !BASELINE
  /// Opening both lists and looking words up: time per open, per lookup (hits and misses), and
  /// resident memory before, after opening and after the lookups.
  static func measureLists(_ directory: URL) {
    let probe = ["nicht", "habe", "möglichkeiten", "straße", "the", "because", "definitely", "zzzzq",
                 "xylophonist", "aber", "über", "receive", "nichtsdestotrotz", "abcdef"]
    // Foundation's own first use (URLs, file attributes) isn't the lists' cost.
    _ = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]), options: .alwaysMapped)
    var timings: [Double] = []
    timings.reserveCapacity(2_000 * probe.count)
    let base = residentKiB()
    var lists: [KeyboardFrequencyList] = []
    for code in ["de", "en"] {
      let url = directory.appendingPathComponent("KeyboardFrequency-\(code).bin")
      let start = DispatchTime.now().uptimeNanoseconds
      guard let list = KeyboardFrequencyList(contentsOf: url) else { fatalError("Unreadable list: \(url.path)") }
      let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000
      print("open \(code): \(String(format: "%.1f", micros)) µs, \(list.count) words")
      lists.append(list)
    }
    let opened = residentKiB()
    var hits = 0
    for _ in 0..<2_000 {
      for word in probe {
        let start = DispatchTime.now().uptimeNanoseconds
        for list in lists where list.rank(of: word) != nil { hits += 1 }
        timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000)
      }
    }
    timings.sort()
    func percentile(_ p: Double) -> Double { timings[min(timings.count - 1, Int(Double(timings.count) * p))] }
    print("lookup in both lists: p50 \(String(format: "%.2f", percentile(0.5))) µs, p95 \(String(format: "%.2f", percentile(0.95))) µs, max \(String(format: "%.1f", timings.last ?? 0)) µs (\(timings.count) lookups, \(hits) hits)")
    if let base, let opened, let after = residentKiB() {
      print("resident, allocated: +\(opened.anonymous - base.anonymous) KiB after opening, +\(after.anonymous - base.anonymous) KiB after the lookups")
      print("resident, mapped file pages: +\(opened.file - base.file) KiB after opening, +\(after.file - base.file) KiB after the lookups (of \(lists.count) files)")
    }
  }
  #endif

  #if !BASELINE && os(Linux)
  /// SplitMix64: the same typos on every run and platform.
  struct Random {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
  }

  /// One typo, as the weights were tuned for: a key beside the right one in its row (50%), one
  /// row up or down (20%), two letters swapped, one missing, or one extra beside a typed letter
  /// (10% each). The first letter keeps its case.
  static func typo(of word: String, random: inout Random) -> String {
    let title = word != word.lowercased()
    var letters = Array(word.lowercased())
    func neighbors(_ letter: Character, sameRow: Bool) -> [Character] {
      (KeyboardCorrectionRules.keyNeighbors[letter] ?? []).sorted().filter {
        (KeyboardCorrectionRules.substitutionCost(letter, $0) == KeyboardCorrectionRules.rowSlipCost) == sameRow
      }
    }
    let roll = random.below(100)
    let index = random.below(letters.count)
    if roll < 70 {
      let options = neighbors(letters[index], sameRow: roll < 50)
      guard !options.isEmpty else { return word }
      letters[index] = options[random.below(options.count)]
    } else if roll < 80 {
      guard letters.count >= 2 else { return word }
      let at = min(index, letters.count - 2)
      letters.swapAt(at, at + 1)
    } else if roll < 90 {
      letters.remove(at: index)
    } else {
      let options = neighbors(letters[index], sameRow: true)
      guard !options.isEmpty else { return word }
      letters.insert(options[random.below(options.count)], at: index + random.below(2))
    }
    let result = String(letters)
    return title ? KeyboardCorrectionRules.capitalized(result) : result
  }

  struct SentenceCase {
    let before: String
    let word: String
    let typed: String
    /// The typo is a word the dictionaries know: nothing should change it.
    let realWord: Bool
  }

  /// Up to two words per sentence (letters, 3 to 20, lowercase or capitalised, after a space or
  /// at the start), each with one typo, typed after the sentence's own words before it.
  static func sentenceCases(_ url: URL, letters: Set<Character>, seed: UInt64, noisyPrevious: Bool = false,
                            knows: (String) -> Bool) -> [SentenceCase] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { fatalError("Missing sentences: \(url.path)") }
    var random = Random(state: seed)
    var cases: [SentenceCase] = []
    for line in text.split(separator: "\n") {
      let sentence = String(line)
      var candidates: [(before: String, word: String)] = []
      var index = sentence.startIndex
      while index < sentence.endIndex {
        guard sentence[index].isLetter else { index = sentence.index(after: index); continue }
        let start = index
        while index < sentence.endIndex, sentence[index].isLetter { index = sentence.index(after: index) }
        let word = String(sentence[start..<index])
        let before = String(sentence[..<start])
        let endsWord = index == sentence.endIndex || !(sentence[index].isLetter || sentence[index].isNumber
          || sentence[index] == "-" || sentence[index] == "'" || sentence[index] == "\u{2019}")
        if endsWord, before.isEmpty || before.last == " ", KeyboardCorrectionRules.isWord(word, letters: letters),
           knows(word) {
          candidates.append((before, word))
        }
      }
      for _ in 0..<min(2, candidates.count) {
        let pick = candidates.remove(at: random.below(candidates.count))
        let typed = typo(of: pick.word, random: &random)
        guard typed != pick.word, typed.count >= 3 else { continue }
        var before = pick.before
        if noisyPrevious {
          // The word before mistyped too and left so (the user didn't correct it): the
          // context then reads a word the model rarely knows.
          let trimmed = before.dropLast()
          let previous = String(trimmed.reversed().prefix { $0.isLetter }.reversed())
          if previous.count >= 3 {
            before = String(trimmed.dropLast(previous.count)) + typo(of: previous, random: &random) + " "
          }
        }
        cases.append(SentenceCase(before: before, word: pick.word, typed: typed, realWord: knows(typed)))
      }
    }
    return cases
  }

  static func correct(_ typed: String, before: String, provider: KeyboardCorrectionProvider) -> String {
    var state = KeyboardAutocorrection()
    var context = KeyboardCorrectionContext(document: UUID(), before: before, after: "", selection: nil, allowed: true)
    for letter in typed {
      state.manualInsertion(String(letter), in: context)
      context = context.inserting(String(letter))
      state.reconcile(context)
    }
    return state.correction(in: context, provider: provider)?.replacement ?? typed
  }

  /// `--sentences <dir> --context <dir> --split dev|test [--weights 0,0.1,…] [--caps 8]`: each
  /// weight and cap against weight 0, on typos and on the words typed right (control).
  static func sentenceBenchmark(sentences: URL, context: URL) {
    let split = option("--split") ?? "dev"
    let weights = (option("--weights") ?? "0,0.05,0.1,0.15,0.2,0.3,0.5").split(separator: ",").compactMap { Double($0) }
    let caps = (option("--caps") ?? "8").split(separator: ",").compactMap { Double($0) }
    let limit = Int(option("--sentence-cases") ?? "") ?? Int.max
    var models: [String: KeyboardContextModel] = [:]
    for code in ["de", "en"] {
      let url = context.appendingPathComponent("KeyboardContext-\(code).bin")
      guard let model = KeyboardContextModel(contentsOf: url) else { fatalError("Unreadable context: \(url.path)") }
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
      print("context \(code): \(model.pairCount) pairs, \(model.wordCount) words, \(size / 1024) KiB")
      models[code] = model
    }
    let both: [KeyboardCorrectionLanguage] = [.german, .english]
    for (code, language) in [("de", KeyboardCorrectionLanguage.german), ("en", .english)] {
      let lexicon = UITextChecker.lexicons[code == "de" ? "de_DE" : "en_US"]!
      let all = sentenceCases(sentences.appendingPathComponent("sentences-\(code)-\(split).txt"),
                              letters: language.letters, seed: code == "de" ? 1 : 2,
                              noisyPrevious: flag("--noisy-previous"), knows: { lexicon.knows($0) })
      let cases = Array(all.prefix(limit))
      let typos = cases.filter { !$0.realWord }
      let real = cases.filter { $0.realWord }
      for (name, languages) in [("\(code) sentences, German and English selected", both), ("\(code) sentences, \(code) only", [language])] {
        func run(weight: Double, cap: Double) -> (typos: [String], real: [String], control: [String]) {
          let provider = TextCheckerCorrectionProvider(languages: languages, contextModels: models,
                                                       contextWeight: weight, contextCap: cap)
          return (typos.map { correct($0.typed, before: $0.before, provider: provider) },
                  real.map { correct($0.typed, before: $0.before, provider: provider) },
                  typos.map { correct($0.word, before: $0.before, provider: provider) })
        }
        func outcome(_ results: [String]) -> (right: Int, wrong: Int, unchanged: Int) {
          var counts = (right: 0, wrong: 0, unchanged: 0)
          for (item, result) in zip(typos, results) {
            if result == item.word { counts.right += 1 } else if result == item.typed { counts.unchanged += 1 } else { counts.wrong += 1 }
          }
          return counts
        }
        let baseline = run(weight: 0, cap: 8)
        let base = outcome(baseline.typos)
        let controlChanged = zip(typos, baseline.control).filter { $0.0.word != $0.1 }.count
        let realChanged = zip(real, baseline.real).filter { $0.0.typed != $0.1 }.count
        print("\n\(name) [\(split)\(flag("--noisy-previous") ? ", word before mistyped" : "")]: \(typos.count) typos (\(real.count) more make real words)")
        print("  weight 0: right \(base.right)  wrong \(base.wrong)  unchanged \(base.unchanged); control changed \(controlChanged), real-word typos changed \(realChanged)")
        for cap in caps {
          for weight in weights where weight > 0 {
            let result = run(weight: weight, cap: cap)
            let counts = outcome(result.typos)
            var gained = 0, lost = 0
            for (index, item) in typos.enumerated() {
              let before = baseline.typos[index] == item.word, after = result.typos[index] == item.word
              if after && !before { gained += 1 }
              if before && !after { lost += 1 }
            }
            let control = zip(typos, result.control).filter { $0.0.word != $0.1 }.count
            let realWords = zip(real, result.real).filter { $0.0.typed != $0.1 }.count
            print("  weight \(weight) cap \(cap): right \(counts.right)  wrong \(counts.wrong)  unchanged \(counts.unchanged)  (+\(gained) −\(lost)); control changed \(control), real-word typos changed \(realWords)")
            if flag("--details") {
              for (index, item) in typos.enumerated() where baseline.typos[index] != result.typos[index] {
                print("    \(item.typed): \(baseline.typos[index]) → \(result.typos[index]) (expected \(item.word))")
              }
            }
          }
        }
      }
    }
  }
  #endif

  static func main() {
    #if !BASELINE
    if let directory = option("--measure-lists") {
      measureLists(URL(fileURLWithPath: directory))
      return
    }
    #endif
    guard let fixtures = option("--fixtures").map({ URL(fileURLWithPath: $0) }) else {
      fatalError("--fixtures <dir> is required")
    }
    #if os(Linux)
    guard let lexicons = option("--lexicons").map({ URL(fileURLWithPath: $0) }) else {
      fatalError("--lexicons <dir with main_de.combined, main_en_US__experimental.combined> is required on Linux")
    }
    let alphabetical = flag("--alphabetical-completions")
    let limit = Int(option("--lexicon-words") ?? "") ?? 400_000
    UITextChecker.lexicons = [
      "de_DE": loadLexicon(lexicons.appendingPathComponent("main_de.combined"), language: "de_DE",
                           limit: limit, alphabetical: alphabetical),
      "en_US": loadLexicon(lexicons.appendingPathComponent("main_en_US__experimental.combined"),
                           language: "en_US", limit: limit, alphabetical: alphabetical),
    ]
    print("Linux simulation: stand-in dictionaries of \(limit) AOSP words, no Apple proposals, completions \(alphabetical ? "alphabetical" : "by corpus frequency").")
    #if !BASELINE && os(Linux)
    if let sentences = option("--sentences"), let context = option("--context") {
      sentenceBenchmark(sentences: URL(fileURLWithPath: sentences), context: URL(fileURLWithPath: context))
      return
    }
    #endif
    #else
    print("Apple's UITextChecker: \(UITextChecker.availableLanguages.filter { $0.hasPrefix("de") || $0.hasPrefix("en") }.joined(separator: ", "))")
    #endif

    let german = loadCases(fixtures.appendingPathComponent("libreoffice-de.tsv"))
    let english = loadCases(fixtures.appendingPathComponent("libreoffice-en.tsv"))
    func controls(_ cases: [Case]) -> [Case] {
      var seen = Set<String>()
      return cases.filter { !$0.expected.contains(" ") && seen.insert($0.expected).inserted }
        .map { Case(typed: $0.expected, expected: $0.expected, tags: ["control"]) }
    }
    let both: [KeyboardCorrectionLanguage] = [.german, .english]
    let series = [
      Series(name: "de, German and English selected", languages: both, prefix: "", cases: german, control: false),
      Series(name: "de, German only", languages: [.german], prefix: "", cases: german, control: false),
      Series(name: "de, after \"Das ist \"", languages: both, prefix: "Das ist ", cases: german, control: false),
      Series(name: "en, German and English selected", languages: both, prefix: "", cases: english, control: false),
      Series(name: "en, English only", languages: [.english], prefix: "", cases: english, control: false),
      Series(name: "en, after \"This is \"", languages: both, prefix: "This is ", cases: english, control: false),
      Series(name: "control de (corrections typed right)", languages: both, prefix: "", cases: controls(german), control: true),
      Series(name: "control en (corrections typed right)", languages: both, prefix: "", cases: controls(english), control: true),
    ]

    var frequencyLists: [String: KeyboardFrequencyList] = [:]
    #if !BASELINE
    if let directory = option("--frequency") {
      for code in ["de", "en"] {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("KeyboardFrequency-\(code).bin")
        let start = DispatchTime.now().uptimeNanoseconds
        guard let list = KeyboardFrequencyList(contentsOf: url) else { fatalError("Unreadable list: \(url.path)") }
        let opened = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("frequency list \(code): \(list.count) words, \(size / 1024) KiB, opened in \(String(format: "%.1f", opened)) µs")
        frequencyLists[code] = list
      }
    }
    #endif

    let details = flag("--details")
    for item in series {
      let baseline = TextCheckerCorrectionProvider(languages: item.languages)
      let started = DispatchTime.now().uptimeNanoseconds
      let before = outcomeText(item, provider: baseline)
      let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
      let beforeOutcomes = classify(item, before)
      print("\n\(item.name): \(summary(beforeOutcomes))  [\(String(format: "%.1f", seconds * 1000 / Double(max(item.cases.count, 1)))) ms/word]")
      if !item.control {
        var tagged: [String: [Outcome]] = [:]
        for (index, test) in item.cases.enumerated() {
          for tag in test.tags { tagged[tag, default: []].append(beforeOutcomes[index]) }
        }
        for tag in tagged.keys.sorted() { print("  \(tag): \(summary(tagged[tag]!))") }
      }
      if details {
        for (index, test) in item.cases.enumerated() where beforeOutcomes[index] != .right {
          print("  \(beforeOutcomes[index].rawValue)\t\(test.typed)\t→ \(before[index])\t(expected \(test.expected))")
        }
      }
      #if !BASELINE
      if let directory = option("--context") {
        var models: [String: KeyboardContextModel] = [:]
        for code in ["de", "en"] {
          models[code] = KeyboardContextModel(contentsOf: URL(fileURLWithPath: directory)
            .appendingPathComponent("KeyboardContext-\(code).bin"))
        }
        let contextual = TextCheckerCorrectionProvider(languages: item.languages, contextModels: models)
        let after = outcomeText(item, provider: contextual)
        let afterOutcomes = classify(item, after)
        print("  with word-pair context: \(summary(afterOutcomes))")
        for index in item.cases.indices where before[index] != after[index] {
          print("  context changed\t\(item.cases[index].typed)\t\(before[index]) → \(after[index])\t(expected \(item.cases[index].expected))")
        }
      }
      #endif
      guard !frequencyLists.isEmpty else { continue }
      #if !BASELINE
      let ranked = TextCheckerCorrectionProvider(languages: item.languages, frequencyLists: frequencyLists)
      let after = outcomeText(item, provider: ranked)
      let afterOutcomes = classify(item, after)
      print("  with frequency lists: \(summary(afterOutcomes))")
      var transitions: [String: Int] = [:]
      for index in item.cases.indices where beforeOutcomes[index] != afterOutcomes[index] || before[index] != after[index] {
        transitions["\(beforeOutcomes[index].rawValue) → \(afterOutcomes[index].rawValue)", default: 0] += 1
        if details {
          print("  changed\t\(item.cases[index].typed)\t\(before[index]) → \(after[index])\t(expected \(item.cases[index].expected))")
        }
      }
      for key in transitions.keys.sorted() { print("  \(key): \(transitions[key]!)") }
      #endif
    }
  }
}
