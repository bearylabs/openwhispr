import { sharedWordKey } from './sharedDictionaryHints';

// The dictionary as the keyboard's autocorrection reads it from the App Group: every word is
// protected from correction, and the user's own words (`personal`) are also targets for a typo
// (`KeyboardUserDictionary` in plugins/keyboard-extension/ios/KeyboardAutocorrection.swift,
// which parses the same format and enforces the same bounds again).
export const KEYBOARD_WORDS_VERSION = 1;
export const KEYBOARD_WORDS_MAX_ENTRIES = 2000;
/** UTF-8 bytes of the whole JSON value. */
export const KEYBOARD_WORDS_MAX_BYTES = 64 * 1024;
/** UTF-16 code units per entry; a longer entry is skipped. */
export const KEYBOARD_WORD_MAX_LENGTH = 64;

// Control, format and line/paragraph separator characters, and any whitespace but a single
// ASCII space between words.
const UNSAFE_CHARACTERS = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u;
const OTHER_WHITESPACE = /[^\S ]| {2}/u;

function utf8Length(text: string): number {
  let bytes = 0;
  for (const char of text) {
    const code = char.codePointAt(0) ?? 0;
    bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
  }
  return bytes;
}

function cleanEntry(word: string): string | null {
  const entry = word.normalize('NFC').trim();
  if (
    !entry ||
    entry.length > KEYBOARD_WORD_MAX_LENGTH ||
    UNSAFE_CHARACTERS.test(entry) ||
    OTHER_WHITESPACE.test(entry)
  ) {
    return null;
  }
  return entry;
}

/**
 * `{"v":1,"personal":[…],"shared":[…]}`, or "" without words. Personal words come first and win
 * a case-insensitive duplicate; the list stops at KEYBOARD_WORDS_MAX_ENTRIES entries or
 * KEYBOARD_WORDS_MAX_BYTES, so the cap drops team words before the user's own.
 */
export function serializeKeyboardWords(
  personal: readonly string[],
  shared: readonly string[],
): string {
  const result: { v: number; personal: string[]; shared: string[] } = {
    v: KEYBOARD_WORDS_VERSION,
    personal: [],
    shared: [],
  };
  let bytes = utf8Length(JSON.stringify(result));
  const seen = new Set<string>();
  // False once the list is full, which ends the fill: personal words first, then shared ones.
  const add = (word: string, target: string[]): boolean => {
    if (seen.size >= KEYBOARD_WORDS_MAX_ENTRIES) return false;
    const entry = cleanEntry(word);
    if (!entry) return true;
    const key = sharedWordKey(entry);
    if (seen.has(key)) return true;
    // The quoted entry plus a comma.
    const cost = utf8Length(JSON.stringify(entry)) + 1;
    if (bytes + cost > KEYBOARD_WORDS_MAX_BYTES) return false;
    seen.add(key);
    target.push(entry);
    bytes += cost;
    return true;
  };
  if (personal.every((word) => add(word, result.personal))) {
    shared.every((word) => add(word, result.shared));
  }
  return seen.size === 0 ? '' : JSON.stringify(result);
}
