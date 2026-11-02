import Foundation

/// A language's word ranks from a corpus (`scripts/build-keyboard-frequency-lists.mjs`): for each
/// of its most common words, the rank among the list's words with the same first two letters,
/// the scale `TextCheckerCorrectionProvider` uses for UITextChecker's completions, so the
/// scoring weights keep their meaning. Read from a memory-mapped file; only the pages a lookup
/// touches are read, and nothing is copied out but the rank.
///
/// Format (little-endian): "OWFR", u16 version 1, u16 rank kind 1, two ASCII language letters,
/// u16 reserved, u32 count, u32 offsets[count + 1], u16 ranks[count], then the words as UTF-8,
/// lowercase and NFC, sorted bytewise. A wrong header or sizes is no list. The words' order and
/// uniqueness are the generator's to guarantee: they aren't checked when the file opens (that
/// would read all of it), and lookups stay inside the file whatever its offsets say.
struct KeyboardFrequencyList {
  static let magic: [UInt8] = Array("OWFR".utf8)
  static let version: UInt16 = 1
  static let rankKindPrefix2: UInt16 = 1
  static let headerSize = 16
  /// Longer keys aren't looked up; the lists hold words of at most a few dozen letters.
  static let maxKeyBytes = 256

  let language: String
  let count: Int
  private let data: Data
  private let offsetsStart: Int
  private let ranksStart: Int
  private let wordsStart: Int

  /// Maps the file; nil when it is missing or malformed.
  init?(contentsOf url: URL) {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
    self.init(data: data)
  }

  init?(data: Data) {
    guard data.count >= Self.headerSize else { return nil }
    let header: (magic: [UInt8], version: UInt16, kind: UInt16, language: [UInt8], reserved: UInt16, count: Int) =
      data.withUnsafeBytes { raw in
        (Array(raw[0..<4]), Self.u16(raw, 4), Self.u16(raw, 6), Array(raw[8..<10]), Self.u16(raw, 10),
         Int(Self.u32(raw, 12)))
      }
    guard header.magic == Self.magic, header.version == Self.version, header.kind == Self.rankKindPrefix2,
          header.reserved == 0, header.language.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) }),
          let language = String(bytes: header.language, encoding: .ascii) else { return nil }
    let count = header.count
    let offsetsStart = Self.headerSize
    let ranksStart = offsetsStart + 4 * (count + 1)
    let wordsStart = ranksStart + 2 * count
    guard count < Int(UInt32.max) / 8, wordsStart <= data.count else { return nil }
    // The words run from the first offset to the end of the file. Opening reads only the header
    // and these two offsets, so it touches two pages; each lookup checks the bounds it reads.
    let valid = data.withUnsafeBytes { raw -> Bool in
      Self.u32(raw, offsetsStart) == 0 && wordsStart + Int(Self.u32(raw, ranksStart - 4)) == data.count
    }
    guard valid else { return nil }
    self.language = language
    self.count = count
    self.data = data
    self.offsetsStart = offsetsStart
    self.ranksStart = ranksStart
    self.wordsStart = wordsStart
  }

  /// The word's rank (0 = most common among words with its first two letters), or nil.
  func rank(of word: String) -> Int? {
    let key = Array(word.lowercased().precomposedStringWithCanonicalMapping.utf8)
    guard !key.isEmpty, key.count <= Self.maxKeyBytes, count > 0 else { return nil }
    return data.withUnsafeBytes { raw -> Int? in
      var low = 0, high = count - 1
      while low <= high {
        let middle = (low + high) / 2
        let start = wordsStart + Int(Self.u32(raw, offsetsStart + 4 * middle))
        let end = wordsStart + Int(Self.u32(raw, offsetsStart + 4 * (middle + 1)))
        guard start <= end, end <= raw.count else { return nil }
        let order = Self.compare(key, raw, start, end)
        if order == 0 { return Int(Self.u16(raw, ranksStart + 2 * middle)) }
        if order < 0 { high = middle - 1 } else { low = middle + 1 }
      }
      return nil
    }
  }

  /// Bytewise order of `key` against the stored word in `start..<end`.
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
