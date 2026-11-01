import { AppState, Platform } from 'react-native';
import { useConfigStore } from '@/store/useConfigStore';
import { useDictionaryStore } from '@/store/useDictionaryStore';
import { useSharedDictionaryStore } from '@/store/useSharedDictionaryStore';
import { buildDictationHintTiers } from '@/lib/dictationHints';
import {
  normalizeKeyboardAutocorrectionLanguages,
  type KeyboardAutocorrectionLanguage,
} from '@/lib/keyboardAutocorrection';
import { serializeKeyboardWords } from '@/lib/keyboardAutocorrectionWords';
import { AppGroupStorage, APP_GROUP_KEYS } from '../../modules/app-group-storage/src';

// Default on: the keyboard also treats a missing key (fresh install, no Full Access) as on.
export function isKeyboardAutocorrectionEnabled(): boolean {
  return useConfigStore.getState().config?.keyboardAutocorrectionEnabled ?? true;
}

export function keyboardAutocorrectionLanguages(): KeyboardAutocorrectionLanguage[] {
  return normalizeKeyboardAutocorrectionLanguages(
    useConfigStore.getState().config?.keyboardAutocorrectionLanguages,
  );
}

function writeLanguages(languages: readonly string[]): void {
  // "de,en": the keyboard parses the same comma-separated codes.
  AppGroupStorage.setItem(
    APP_GROUP_KEYS.KEYBOARD_AUTOCORRECTION_LANGUAGES,
    normalizeKeyboardAutocorrectionLanguages(languages).join(','),
  );
}

function writeAppGroupAutocorrection(): void {
  AppGroupStorage.setItem(
    APP_GROUP_KEYS.KEYBOARD_AUTOCORRECTION_ENABLED,
    isKeyboardAutocorrectionEnabled() ? '1' : '0',
  );
  writeLanguages(keyboardAutocorrectionLanguages());
}

// The last value the App Group accepted; null until then, or after a failed write, so the next
// change retries it.
let writtenWords: string | null = null;
let clearing = 0;

// The words the dictionary applies to dictation (personal, then the shared ones that apply; no
// snippet triggers), only while autocorrection is on, so the keyboard keeps no copy it doesn't use.
function keyboardWordsValue(): string {
  if (clearing > 0 || !isKeyboardAutocorrectionEnabled()) return '';
  const [personal = [], space = [], workspace = []] = buildDictationHintTiers(false);
  return serializeKeyboardWords(personal, [...space, ...workspace]);
}

function writeKeyboardWords(): void {
  if (Platform.OS !== 'ios') return;
  const value = keyboardWordsValue();
  if (value === writtenWords) return;
  writtenWords = AppGroupStorage.setItem(APP_GROUP_KEYS.KEYBOARD_AUTOCORRECTION_WORDS, value)
    ? value
    : null;
}

/**
 * Runs `reset` (clearing an account's dictionary stores) with the keyboard's copy emptied first
 * and kept empty until it returns: the stores reset one after the other, and a mirror written in
 * between would publish what is left of the previous account's words.
 */
export function clearingKeyboardWords(reset: () => void): void {
  clearing += 1;
  try {
    writeKeyboardWords();
    reset();
  } finally {
    clearing -= 1;
    writeKeyboardWords();
  }
}

// Settings controls: write the App Group key first so the keyboard follows at once, without
// waiting on async config persistence.
export function setKeyboardAutocorrectionEnabled(enabled: boolean): void {
  AppGroupStorage.setItem(APP_GROUP_KEYS.KEYBOARD_AUTOCORRECTION_ENABLED, enabled ? '1' : '0');
  useConfigStore
    .getState()
    .updateConfig({ keyboardAutocorrectionEnabled: enabled })
    .catch(() => {});
}

export function setKeyboardAutocorrectionLanguages(languages: readonly string[]): void {
  const normalized = normalizeKeyboardAutocorrectionLanguages(languages);
  writeLanguages(normalized);
  useConfigStore
    .getState()
    .updateConfig({ keyboardAutocorrectionLanguages: normalized })
    .catch(() => {});
}

// Config is the source of truth (only the app writes these keys); mirror it out now and on
// every config change.
export function startKeyboardAutocorrectionSync(): () => void {
  writeAppGroupAutocorrection();
  // Written at every start, whatever an earlier start wrote.
  writtenWords = null;
  writeKeyboardWords();
  const unsubscribers = [
    useConfigStore.subscribe(() => {
      writeAppGroupAutocorrection();
      writeKeyboardWords();
    }),
    useDictionaryStore.subscribe(writeKeyboardWords),
    useSharedDictionaryStore.subscribe(writeKeyboardWords),
  ];
  // A write that failed is retried when the app comes back, even if nothing changed meanwhile.
  const appState = AppState.addEventListener('change', (state) => {
    if (state === 'active') writeKeyboardWords();
  });
  return () => {
    for (const unsubscribe of unsubscribers) unsubscribe();
    appState.remove();
  };
}
