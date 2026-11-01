import {
  clearingKeyboardWords,
  setKeyboardAutocorrectionEnabled,
  setKeyboardAutocorrectionLanguages,
  startKeyboardAutocorrectionSync,
} from '@/lib/keyboardAutocorrectionSync';
import { useConfigStore } from '@/store/useConfigStore';

const store: Record<string, string> = {};
let mockFailWrites = false;
const mockWrites: Array<[string, string]> = [];

// Stand-ins for the dictionary stores: the mirror only subscribes to them and reads the tiers.
let mockTiers: string[][] = [[], [], []];
type MockStore = {
  subscribe: (listener: () => void) => () => void;
  emit: () => void;
  listenerCount: () => number;
};
jest.mock('@/store/useDictionaryStore', () => ({
  useDictionaryStore: (() => {
    const listeners = new Set<() => void>();
    return {
      subscribe: (listener: () => void) => {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      emit: () => listeners.forEach((listener) => listener()),
      listenerCount: () => listeners.size,
    };
  })(),
}));
jest.mock('@/store/useSharedDictionaryStore', () => ({
  useSharedDictionaryStore: (() => {
    const listeners = new Set<() => void>();
    return {
      subscribe: (listener: () => void) => {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      emit: () => listeners.forEach((listener) => listener()),
      listenerCount: () => listeners.size,
    };
  })(),
}));
const mockDictionaryStore = jest.requireMock('@/store/useDictionaryStore')
  .useDictionaryStore as MockStore;
const mockSharedStore = jest.requireMock('@/store/useSharedDictionaryStore')
  .useSharedDictionaryStore as MockStore;
jest.mock('@/lib/dictationHints', () => ({
  buildDictationHintTiers: (includeSnippetTriggers: boolean) => {
    if (includeSnippetTriggers) throw new Error('snippet triggers are no dictionary words');
    return mockTiers;
  },
}));

jest.mock('../../../modules/app-group-storage/src', () => ({
  AppGroupStorage: {
    getItem: (key: string) => store[key] ?? null,
    setItem: (key: string, value: string) => {
      mockWrites.push([key, value]);
      if (mockFailWrites) return false;
      store[key] = value;
      return true;
    },
  },
  APP_GROUP_KEYS: {
    KEYBOARD_AUTOCORRECTION_ENABLED: 'keyboard_autocorrection_enabled',
    KEYBOARD_AUTOCORRECTION_LANGUAGES: 'keyboard_autocorrection_languages',
    KEYBOARD_AUTOCORRECTION_WORDS: 'keyboard_autocorrection_words',
  },
}));

jest.mock('@/services/storage/StorageService', () => ({
  StorageService: { saveConfig: jest.fn(async () => {}) },
}));

beforeEach(() => {
  for (const key of Object.keys(store)) delete store[key];
  mockWrites.length = 0;
  mockFailWrites = false;
  mockTiers = [[], [], []];
});

const words = () => store.keyboard_autocorrection_words;
const wordWrites = () => mockWrites.filter(([key]) => key === 'keyboard_autocorrection_words');

describe('keyboard dictionary mirror', () => {
  it('mirrors personal and shared words and follows dictionary changes', () => {
    useConfigStore.setState({ config: { defaultMode: 'cloud' } as any });
    mockTiers = [['OpenWhispr', 'Hrudek'], ['Kubernetes'], ['Sinéad']];
    const stop = startKeyboardAutocorrectionSync();
    expect(JSON.parse(words())).toEqual({
      v: 1,
      personal: ['OpenWhispr', 'Hrudek'],
      shared: ['Kubernetes', 'Sinéad'],
    });
    mockTiers = [['OpenWhispr'], [], []];
    mockDictionaryStore.emit();
    expect(JSON.parse(words()).personal).toEqual(['OpenWhispr']);
    mockTiers = [[], [], []];
    mockSharedStore.emit();
    expect(words()).toBe('');
    stop();
    expect(mockDictionaryStore.listenerCount()).toBe(0);
    expect(mockSharedStore.listenerCount()).toBe(0);
  });

  it('keeps no copy while autocorrection is off', () => {
    useConfigStore.setState({
      config: { defaultMode: 'cloud', keyboardAutocorrectionEnabled: false } as any,
    });
    mockTiers = [['Hrudek'], [], []];
    const stop = startKeyboardAutocorrectionSync();
    expect(words()).toBe('');
    useConfigStore.setState({ config: { defaultMode: 'cloud' } as any });
    expect(JSON.parse(words()).personal).toEqual(['Hrudek']);
    stop();
  });

  it('writes only changed values and retries a failed write', () => {
    useConfigStore.setState({ config: { defaultMode: 'cloud' } as any });
    mockTiers = [['Hrudek'], [], []];
    mockFailWrites = true;
    const stop = startKeyboardAutocorrectionSync();
    expect(words()).toBeUndefined();
    mockFailWrites = false;
    mockDictionaryStore.emit();
    expect(JSON.parse(words()).personal).toEqual(['Hrudek']);
    const count = wordWrites().length;
    mockDictionaryStore.emit();
    expect(wordWrites()).toHaveLength(count);
    stop();
  });

  it('empties the copy before an account reset and publishes nothing in between', () => {
    useConfigStore.setState({ config: { defaultMode: 'cloud' } as any });
    mockTiers = [['Hrudek'], ['Kubernetes'], []];
    const stop = startKeyboardAutocorrectionSync();
    const seen: string[] = [];
    const before = wordWrites().length;
    clearingKeyboardWords(() => {
      seen.push(words());
      // The personal store resets first; the shared words are still loaded.
      mockTiers = [[], ['Kubernetes'], []];
      mockDictionaryStore.emit();
      seen.push(words());
      mockTiers = [[], [], []];
      mockSharedStore.emit();
    });
    expect(seen).toEqual(['', '']);
    expect(words()).toBe('');
    expect(
      wordWrites()
        .slice(before)
        .map(([, value]) => value),
    ).toEqual(['']);
    stop();
  });
});

describe('keyboard autocorrection mirror', () => {
  it('is on for a config that never set it', () => {
    useConfigStore.setState({ config: { defaultMode: 'cloud' } as any });
    const stop = startKeyboardAutocorrectionSync();
    expect(store.keyboard_autocorrection_enabled).toBe('1');
    expect(store.keyboard_autocorrection_languages).toBe('de,en');
    stop();
  });

  it('mirrors the saved languages, normalized', () => {
    useConfigStore.setState({
      config: { defaultMode: 'cloud', keyboardAutocorrectionLanguages: ['en', 'xx'] } as any,
    });
    const stop = startKeyboardAutocorrectionSync();
    expect(store.keyboard_autocorrection_languages).toBe('en');
    stop();
  });

  it('the language picker writes the key at once and saves config', async () => {
    useConfigStore.setState({ config: { defaultMode: 'cloud' } as any });
    setKeyboardAutocorrectionLanguages(['en']);
    expect(store.keyboard_autocorrection_languages).toBe('en');
    await new Promise((resolve) => setImmediate(resolve));
    expect(useConfigStore.getState().config?.keyboardAutocorrectionLanguages).toEqual(['en']);
  });

  it('mirrors a saved off and later config changes', () => {
    useConfigStore.setState({
      config: { defaultMode: 'cloud', keyboardAutocorrectionEnabled: false } as any,
    });
    const stop = startKeyboardAutocorrectionSync();
    expect(store.keyboard_autocorrection_enabled).toBe('0');
    useConfigStore.setState({
      config: { defaultMode: 'cloud', keyboardAutocorrectionEnabled: true } as any,
    });
    expect(store.keyboard_autocorrection_enabled).toBe('1');
    stop();
  });

  it('the Settings switch writes the key at once and saves config', async () => {
    useConfigStore.setState({ config: { defaultMode: 'cloud' } as any });
    setKeyboardAutocorrectionEnabled(false);
    expect(store.keyboard_autocorrection_enabled).toBe('0');
    await Promise.resolve();
    await new Promise((resolve) => setImmediate(resolve));
    expect(useConfigStore.getState().config?.keyboardAutocorrectionEnabled).toBe(false);
  });
});
