#!/usr/bin/env node
// Builds the keyboard's word rank lists (`KeyboardFrequencyList`) from the AOSP dictionary word
// lists at codeberg.org/Helium314/aosp-dictionaries, pinned below. Both lists are made from the
// Leipzig Corpora Collection (https://wortschatz.uni-leipzig.de), source lists under CC BY 4.0
// (https://creativecommons.org/licenses/by/4.0/). The legacy `main_en_US` list is not used: it
// comes from OpenBoard/AOSP with no stated license.
//
//   node scripts/build-keyboard-frequency-lists.mjs --out <dir> [--source <dir>] [--words 50000]
//   node scripts/build-keyboard-frequency-lists.mjs --fetch-sources <dir>   (download the pinned
//     source lists into <dir> unless they are there already; the benchmark's Linux dictionaries)
//
// Each list keeps the first `--words` entries of the source (ordered by frequency, most common
// first) that are words of the language's letters: two letters or more, not `not_a_word`,
// lowercased and NFC-normalised, the first (most common) form of each kept. A word's rank is its
// position among the kept words with the same first two letters, like the keyboard's fallback
// (its position among UITextChecker's completions of those letters), so the scoring weights keep
// their meaning.
//
// File format (little-endian), read by ios/KeyboardFrequencyList.swift:
//   0  "OWFR"             magic
//   4  u16 version (1)    6  u16 rank kind (1 = rank among words with the same first two letters)
//   8  u8[2] language     10 u16 reserved (0)
//   12 u32 count
//   16 u32 offsets[count + 1] into the word bytes, then u16 ranks[count], then the words:
//      UTF-8, sorted bytewise, no separators.

import { createHash } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPOSITORY = 'https://codeberg.org/Helium314/aosp-dictionaries/raw/commit';

export const SOURCES = [
  {
    language: 'de',
    file: 'main_de.combined',
    commit: 'ff0cd52be8d9530200fefe8b296c53d4f662091e',
    sha256: '873f0c90e104c574609d8da6a938e4a7c951d53e20cddc1b66301d4d37752b6d',
    letters: /^[a-zäöüß]+$/u,
  },
  {
    language: 'en',
    file: 'main_en_US__experimental.combined',
    commit: '5fc377b7d1bd6514f3183d751f0205946a47701d',
    sha256: '466c2eb4737fa1a9453e5f4a33337db8dd703f75012b70c2534490fd189c9487',
    letters: /^[a-z]+$/u,
  },
];

export const MAGIC = 'OWFR';
export const VERSION = 1;
export const RANK_KIND_PREFIX2 = 1;
export const MAX_RANK = 0xffff;

/** The kept words in source order (most common first). */
export function selectWords(text, letters, limit) {
  if (!Number.isInteger(limit) || limit < 1)
    throw new RangeError('limit must be a positive integer');
  const words = [];
  const seen = new Set();
  for (const line of text.split('\n')) {
    if (!line.startsWith(' word=')) continue;
    const fields = line.slice(1).split(',');
    const word = fields[0].slice('word='.length);
    if (fields.some((field) => field === 'not_a_word=true')) continue;
    const lower = word.toLowerCase().normalize('NFC');
    if ([...lower].length < 2 || !letters.test(lower) || seen.has(lower)) continue;
    seen.add(lower);
    words.push(lower);
    if (words.length >= limit) break;
  }
  return words;
}

/** Rank of each word among the kept words sharing its first two letters (characters). */
export function prefixRanks(words) {
  const next = new Map();
  return words.map((word) => {
    const prefix = [...word].slice(0, 2).join('');
    const rank = next.get(prefix) ?? 0;
    next.set(prefix, rank + 1);
    return Math.min(rank, MAX_RANK);
  });
}

export function encode(language, words, ranks) {
  const entries = words.map((word, index) => ({
    bytes: Buffer.from(word, 'utf8'),
    rank: ranks[index],
  }));
  entries.sort((a, b) => Buffer.compare(a.bytes, b.bytes));
  const count = entries.length;
  const blobLength = entries.reduce((sum, entry) => sum + entry.bytes.length, 0);
  const header = 16;
  const offsetsLength = 4 * (count + 1);
  const ranksLength = 2 * count;
  const buffer = Buffer.alloc(header + offsetsLength + ranksLength + blobLength);
  buffer.write(MAGIC, 0, 'ascii');
  buffer.writeUInt16LE(VERSION, 4);
  buffer.writeUInt16LE(RANK_KIND_PREFIX2, 6);
  buffer.write(language.padEnd(2).slice(0, 2), 8, 'ascii');
  buffer.writeUInt16LE(0, 10);
  buffer.writeUInt32LE(count, 12);
  let offset = 0;
  let blob = header + offsetsLength + ranksLength;
  entries.forEach((entry, index) => {
    buffer.writeUInt32LE(offset, header + 4 * index);
    buffer.writeUInt16LE(entry.rank, header + offsetsLength + 2 * index);
    entry.bytes.copy(buffer, blob);
    blob += entry.bytes.length;
    offset += entry.bytes.length;
  });
  buffer.writeUInt32LE(offset, header + 4 * count);
  return buffer;
}

function option(name, fallback) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

async function readSource(source, directory) {
  if (directory) return readFile(join(directory, source.file));
  const url = `${REPOSITORY}/${source.commit}/wordlists/${source.file}`;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  return Buffer.from(await response.arrayBuffer());
}

async function fetchSources(directory) {
  await mkdir(resolve(directory), { recursive: true });
  for (const source of SOURCES) {
    const file = join(resolve(directory), source.file);
    const existing = await readFile(file).catch(() => null);
    if (existing && createHash('sha256').update(existing).digest('hex') === source.sha256) continue;
    const bytes = await readSource(source, null);
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    if (sha256 !== source.sha256)
      throw new Error(`${source.file}: SHA-256 ${sha256}, expected ${source.sha256}`);
    await writeFile(file, bytes);
  }
}

async function main() {
  const fetchInto = option('--fetch-sources', null);
  if (fetchInto) return fetchSources(fetchInto);
  const out = option('--out');
  if (!out) throw new Error('--out <dir> is required');
  const directory = option('--source', null);
  const words = option('--words', '50000');
  if (!/^[1-9]\d*$/.test(words ?? '')) throw new Error('--words needs a positive whole number');
  const limit = Number(words);
  await mkdir(resolve(out), { recursive: true });
  for (const source of SOURCES) {
    const bytes = await readSource(source, directory);
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    if (sha256 !== source.sha256)
      throw new Error(`${source.file}: SHA-256 ${sha256}, expected ${source.sha256}`);
    const words = selectWords(bytes.toString('utf8'), source.letters, limit);
    const file = join(resolve(out), `KeyboardFrequency-${source.language}.bin`);
    await writeFile(file, encode(source.language, words, prefixRanks(words)));
    console.log(`${file}: ${words.length} words`);
  }
}

// Run as a script (also through a symlinked path), not when imported (from a file or stdin).
function isEntryPoint() {
  try {
    return realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
}

if (process.argv[1] && isEntryPoint()) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
