import {
  KEYBOARD_WORDS_MAX_BYTES,
  KEYBOARD_WORDS_MAX_ENTRIES,
  KEYBOARD_WORD_MAX_LENGTH,
  serializeKeyboardWords,
} from '@/lib/keyboardAutocorrectionWords';

const parse = (value: string) =>
  JSON.parse(value) as { v: number; personal: string[]; shared: string[] };

describe('serializeKeyboardWords', () => {
  it('is empty without words', () => {
    expect(serializeKeyboardWords([], [])).toBe('');
    expect(serializeKeyboardWords(['  ', '\n'], [''])).toBe('');
  });

  it('keeps personal words first and drops their case-insensitive duplicates', () => {
    expect(
      parse(
        serializeKeyboardWords(['OpenWhispr', 'openwhispr', 'Hrudek'], ['OPENWHISPR', 'Kubectl']),
      ),
    ).toEqual({
      v: 1,
      personal: ['OpenWhispr', 'Hrudek'],
      shared: ['Kubectl'],
    });
  });

  it('normalizes to NFC, so composed and decomposed spellings are one word', () => {
    const decomposed = 'Sine\u0301ad';
    const value = parse(serializeKeyboardWords([decomposed, 'Sin\u00e9ad'], []));
    expect(value.personal).toEqual(['Sin\u00e9ad']);
    expect(value.personal[0]).toBe('Sin\u00e9ad');
  });

  it('skips entries with line breaks, controls, invisible characters or odd spacing', () => {
    const value = parse(
      serializeKeyboardWords(
        [
          'a\nb',
          'a\rb',
          'a\u2028b',
          'zero\u200bwidth',
          'tab\there',
          'two  spaces',
          'New York',
          ' Trimmed ',
        ],
        [],
      ),
    );
    expect(value.personal).toEqual(['New York', 'Trimmed']);
  });

  it('skips an overlong entry and keeps the rest', () => {
    const long = 'x'.repeat(KEYBOARD_WORD_MAX_LENGTH + 1);
    expect(parse(serializeKeyboardWords([long, 'Hrudek'], [])).personal).toEqual(['Hrudek']);
  });

  it('caps the entries, dropping shared words before personal ones', () => {
    const personal = Array.from({ length: KEYBOARD_WORDS_MAX_ENTRIES - 1 }, (_, i) => `word${i}`);
    const value = parse(serializeKeyboardWords(personal, ['TeamOne', 'TeamTwo']));
    expect(value.personal).toHaveLength(KEYBOARD_WORDS_MAX_ENTRIES - 1);
    expect(value.shared).toEqual(['TeamOne']);
  });

  it('stays within the byte cap, counting UTF-8 bytes', () => {
    const personal = Array.from(
      { length: KEYBOARD_WORDS_MAX_ENTRIES },
      (_, i) => `ü${'ö'.repeat(30)}${i}`,
    );
    const value = serializeKeyboardWords(personal, []);
    expect(Buffer.byteLength(value, 'utf8')).toBeLessThanOrEqual(KEYBOARD_WORDS_MAX_BYTES);
    expect(parse(value).personal.length).toBeLessThan(KEYBOARD_WORDS_MAX_ENTRIES);
    expect(parse(value).personal[0]).toBe(personal[0]);
  });
});
