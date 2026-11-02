import Foundation

/// What comes before a word, as the context model reads it: the previous word, or the start of a
/// sentence. `KeyboardCorrectionRules.wordContext(before:)` derives it from the text before the
/// word, which the keyboard has already read; it is never stored or logged.
enum KeyboardWordContext: Equatable {
  case sentenceStart
  /// Lowercase and NFC.
  case word(String)
}

/// A language's word pairs from a corpus (`scripts/build-keyboard-context-lists.mjs`): how much
/// more likely a word is after a given word, or at a sentence start, than anywhere (positive
/// pointwise mutual information, in bits). Read from a memory-mapped file; only the pages a
/// lookup touches are read.
///
/// Format (little-endian): "OWCX", u16 version 1, u16 value kind 1, two ASCII language letters
/// a–z, u16 reserved 0, u32 word count, u32 pair count, u32 reserved 0, u32 offsets[words + 1],
/// the words (UTF-8, lowercase NFC, sorted bytewise; `.` is the sentence start) padded with zero
/// bytes to a multiple of 4, u32 keys[pairs] (previous index << 16 | next index, ascending),
/// u8 values[pairs] (1/16 bits). A wrong header or sizes is no model; order and uniqueness are
/// the generator's to guarantee, and lookups stay inside the file whatever its contents say.
struct KeyboardContextModel {
  static let magic: [UInt8] = Array("OWCX".utf8)
  static let version: UInt16 = 1
  static let valueKindPMI16: UInt16 = 1
  static let headerSize = 24
  static let maxWords = 65_536
  static let maxKeyBytes = 256
  /// The word standing for a sentence start; no letter word can be it.
  static let sentenceStartWord = "."

  let language: String
  let wordCount: Int
  let pairCount: Int
  private let data: Data
  private let wordsStart: Int
  private let keysStart: Int
  private let valuesStart: Int

  init?(contentsOf url: URL) {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
    self.init(data: data)
  }

  init?(data: Data) {
    guard data.count >= Self.headerSize else { return nil }
    let header = data.withUnsafeBytes { raw in
      (magic: Array(raw[0..<4]), version: Self.u16(raw, 4), kind: Self.u16(raw, 6),
       language: Array(raw[8..<10]), reserved: Self.u16(raw, 10), words: Int(Self.u32(raw, 12)),
       pairs: Int(Self.u32(raw, 16)), reserved2: Self.u32(raw, 20))
    }
    guard header.magic == Self.magic, header.version == Self.version, header.kind == Self.valueKindPMI16,
          header.reserved == 0, header.reserved2 == 0, header.words <= Self.maxWords,
          header.language.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) }),
          let language = String(bytes: header.language, encoding: .ascii) else { return nil }
    let wordsStart = Self.headerSize + 4 * (header.words + 1)
    guard header.pairs <= Int(UInt32.max) / 8, wordsStart <= data.count else { return nil }
    let blobLength = data.withUnsafeBytes { raw in
      Self.u32(raw, Self.headerSize) == 0 ? Int(Self.u32(raw, wordsStart - 4)) : -1
    }
    guard blobLength >= 0 else { return nil }
    let keysStart = wordsStart + (blobLength + 3) / 4 * 4
    let valuesStart = keysStart + 4 * header.pairs
    guard valuesStart + header.pairs == data.count else { return nil }
    self.language = language
    self.wordCount = header.words
    self.pairCount = header.pairs
    self.data = data
    self.wordsStart = wordsStart
    self.keysStart = keysStart
    self.valuesStart = valuesStart
  }

  /// How much more likely `word` is after `context` than anywhere, in bits (0 when the pair isn't
  /// in the model, so a missing pair never counts against a word).
  func bonus(for word: String, after context: KeyboardWordContext) -> Double {
    let previous: String
    switch context {
    case .sentenceStart: previous = Self.sentenceStartWord
    case .word(let word): previous = word
    }
    let next = word.lowercased().precomposedStringWithCanonicalMapping
    guard pairCount > 0, let p = index(of: previous), let n = index(of: next) else { return 0 }
    let key = UInt32(p) << 16 | UInt32(n)
    return data.withUnsafeBytes { raw -> Double in
      var low = 0, high = pairCount - 1
      while low <= high {
        let middle = (low + high) / 2
        let stored = Self.u32(raw, keysStart + 4 * middle)
        if stored == key { return Double(raw[valuesStart + middle]) / 16 }
        if stored < key { low = middle + 1 } else { high = middle - 1 }
      }
      return 0
    }
  }

  /// The index of a word in the model's word table, or nil.
  private func index(of word: String) -> Int? {
    let key = Array(word.utf8)
    guard !key.isEmpty, key.count <= Self.maxKeyBytes, wordCount > 0 else { return nil }
    return data.withUnsafeBytes { raw -> Int? in
      var low = 0, high = wordCount - 1
      while low <= high {
        let middle = (low + high) / 2
        let start = wordsStart + Int(Self.u32(raw, Self.headerSize + 4 * middle))
        let end = wordsStart + Int(Self.u32(raw, Self.headerSize + 4 * (middle + 1)))
        guard start <= end, end <= keysStart else { return nil }
        let order = Self.compare(key, raw, start, end)
        if order == 0 { return middle }
        if order < 0 { high = middle - 1 } else { low = middle + 1 }
      }
      return nil
    }
  }

  private static func compare(_ key: [UInt8], _ raw: UnsafeRawBufferPointer, _ start: Int, _ end: Int) -> Int {
    let length = end - start
    for index in 0..<min(key.count, length) {
      let stored = raw[start + index]
      if key[index] != stored { return key[index] < stored ? -1 : 1 }
    }
    return key.count == length ? 0 : (key.count < length ? -1 : 1)
  }

  private static func u16(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
    UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8
  }

  private static func u32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
    UInt32(raw[offset]) | UInt32(raw[offset + 1]) << 8 | UInt32(raw[offset + 2]) << 16
      | UInt32(raw[offset + 3]) << 24
  }
}
