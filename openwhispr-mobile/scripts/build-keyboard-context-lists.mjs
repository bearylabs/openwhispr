#!/usr/bin/env node
// Builds the keyboard's word-pair context (`KeyboardContextModel`) from the Leipzig Corpora
// Collection (https://wortschatz.uni-leipzig.de), the source of the AOSP word lists the frequency
// lists come from: deu_news_2023_1M and eng_news_2023_1M, pinned by checksum below. The AOSP lists
// carry at most three next words per word and no sentence starts, too few for context.
//
//   node scripts/build-keyboard-context-lists.mjs --out <dir> [--source <dir>] [--pairs 300000]
//     [--words 50000] [--min-count 3]
//   node scripts/build-keyboard-context-lists.mjs --fetch-sources <dir>
//
// Sentences are split into words (letters, with apostrophes inside) and single other characters.
// A pair is two words with only spaces between them; `.`, `!` and `?` before a space or the line's
// end, and a line's start, make the next word a sentence start (the context `.`); any other
// character breaks the context (`x.com`, `z.B.`'s inner dot, digits, quotes). Words are
// lowercased and NFC; only the language's letters count. The vocabulary is the `--words` most
// common words; of the pairs seen at least `--min-count` times whose words are both in it, the
// `--pairs` most common with a positive association are kept (ties by word order), each with its
// pointwise mutual information log2(P(next | previous) / P(next)), in 1/16 bits (at most 255).
// The probabilities count every word with a context, so pruning doesn't inflate them.
//
// File format (little-endian), read by ios/KeyboardContextModel.swift:
//   0  "OWCX"   4 u16 version (1)   6 u16 value kind (1 = PMI in 1/16 bits)   8 u8[2] language
//   10 u16 reserved (0)   12 u32 word count   16 u32 pair count   20 u32 reserved (0)
//   24 u32 word offsets[word count + 1], the words (UTF-8, sorted bytewise; `.` is the sentence
//      start), zero bytes up to a multiple of 4, u32 pair keys[pair count] (previous word's index
//      << 16 | next word's index, ascending), u8 values[pair count].

import { createHash } from 'node:crypto';
import { createReadStream, realpathSync } from 'node:fs';
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const DOWNLOADS = 'https://downloads.wortschatz-leipzig.de/corpora';

export const SOURCES = [
  {
    language: 'de',
    corpus: 'deu_news_2023_1M',
    sha256: '392065f34be70e3612d6ef6b3edc6687b026524e57e00eef47f0528456deb1ba',
    letters: /^[a-zäöüß]+$/u,
  },
  {
    language: 'en',
    corpus: 'eng_news_2023_1M',
    sha256: 'c8a5a5e72897aa5e367b0319c1884831c02aaf29bf81342de31ca1b1cc8f3e4c',
    letters: /^[a-z]+$/u,
  },
];

export const MAGIC = 'OWCX';
export const VERSION = 1;
export const VALUE_KIND_PMI16 = 1;
export const SENTENCE_START = '.';
const MAX_VALUE = 255;

const TOKEN = /\p{L}+(?:['’]\p{L}+)*|\S/gu;
const SENTENCE_END = new Set(['.', '!', '?']);

/**
 * The words of a sentence line with what comes before each: the previous word, the sentence
 * start, or null (other punctuation, digits). Words keep their case; `letters` filters nothing.
 */
export function* contexts(line) {
  let previous = SENTENCE_START;
  for (const match of line.matchAll(TOKEN)) {
    const token = match[0];
    if (/^\p{L}/u.test(token)) {
      const word = token.toLowerCase().normalize('NFC');
      yield { previous, word };
      previous = word;
    } else {
      // `.`, `!` or `?` ends a sentence only before a space or the line's end (not in `x.com`).
      const after = line[match.index + token.length];
      previous =
        SENTENCE_END.has(token) && (after === undefined || /\s/u.test(after))
          ? SENTENCE_START
          : null;
    }
  }
}

/** Sentences of a Leipzig `-sentences.txt` (`id\ttext`) inside its tarball, line by line. */
async function* sentences(tarball, corpus) {
  const tar = spawn('tar', ['-xzOf', tarball, `${corpus}/${corpus}-sentences.txt`], {
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  const lines = createInterface({ input: tar.stdout, crlfDelay: Infinity });
  for await (const line of lines) {
    const tab = line.indexOf('\t');
    yield tab >= 0 ? line.slice(tab + 1) : line;
  }
  const code = await new Promise((done) => tar.on('close', done));
  if (code !== 0) throw new Error(`tar failed on ${tarball}`);
}

/** Counts words, then pairs, over the corpus; returns the kept vocabulary and pairs. */
export async function buildModel(
  lineSource,
  letters,
  { words = 50_000, pairs = 300_000, minCount = 3 },
) {
  const unigrams = new Map();
  for await (const line of lineSource()) {
    for (const { word } of contexts(line)) {
      if (letters.test(word)) unigrams.set(word, (unigrams.get(word) ?? 0) + 1);
    }
  }
  const vocabulary = [...unigrams.entries()]
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
    .slice(0, words)
    .map(([word]) => word);
  const index = new Map(vocabulary.map((word, i) => [word, i + 1]));
  index.set(SENTENCE_START, 0);
  // Marginals over every word that has a context (any word, in the vocabulary or not), so
  // dropping rare words or pairs doesn't inflate an association.
  const counts = new Map();
  const left = new Map();
  const right = new Map();
  let total = 0;
  for await (const line of lineSource()) {
    for (const { previous, word } of contexts(line)) {
      if (previous === null) continue;
      total += 1;
      const p = index.get(previous);
      const n = letters.test(word) ? index.get(word) : undefined;
      if (p !== undefined) left.set(p, (left.get(p) ?? 0) + 1);
      if (n !== undefined && n !== 0) right.set(n, (right.get(n) ?? 0) + 1);
      if (p === undefined || n === undefined || n === 0) continue;
      const key = p * 65_536 + n;
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
  }
  const kept = [];
  for (const [key, count] of counts) {
    if (count < minCount) continue;
    const p = Math.floor(key / 65_536);
    const n = key % 65_536;
    const pmi = Math.log2((count * total) / (left.get(p) * right.get(n)));
    const value = Math.min(MAX_VALUE, Math.round(pmi * 16));
    if (value > 0) kept.push({ p, n, count, value });
  }
  kept.sort((a, b) => b.count - a.count || a.p - b.p || a.n - b.n);
  const names = [SENTENCE_START, ...vocabulary];
  return {
    pairs: kept
      .slice(0, pairs)
      .map(({ p, n, value }) => ({ previous: names[p], next: names[n], value })),
    stats: { vocabulary: vocabulary.length, distinctPairs: counts.size, total },
  };
}

export function encode(language, pairs) {
  const words = [...new Set(pairs.flatMap((pair) => [pair.previous, pair.next]))]
    .map((word) => Buffer.from(word, 'utf8'))
    .sort(Buffer.compare);
  const id = new Map(words.map((bytes, i) => [bytes.toString('utf8'), i]));
  if (words.length > 65_536) throw new Error('more than 65,536 words');
  const entries = pairs
    .map((pair) => ({ key: id.get(pair.previous) * 65_536 + id.get(pair.next), value: pair.value }))
    .sort((a, b) => a.key - b.key);
  const blob = Buffer.concat(words);
  const padded = Math.ceil(blob.length / 4) * 4;
  const header = 24;
  const offsets = 4 * (words.length + 1);
  const buffer = Buffer.alloc(header + offsets + padded + 4 * entries.length + entries.length);
  buffer.write(MAGIC, 0, 'ascii');
  buffer.writeUInt16LE(VERSION, 4);
  buffer.writeUInt16LE(VALUE_KIND_PMI16, 6);
  buffer.write(language.slice(0, 2), 8, 'ascii');
  buffer.writeUInt32LE(words.length, 12);
  buffer.writeUInt32LE(entries.length, 16);
  let offset = 0;
  words.forEach((bytes, i) => {
    buffer.writeUInt32LE(offset, header + 4 * i);
    offset += bytes.length;
  });
  buffer.writeUInt32LE(offset, header + 4 * words.length);
  blob.copy(buffer, header + offsets);
  const keys = header + offsets + padded;
  entries.forEach((entry, i) => {
    buffer.writeUInt32LE(entry.key, keys + 4 * i);
    buffer.writeUInt8(entry.value, keys + 4 * entries.length + i);
  });
  return buffer;
}

function option(name, fallback) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

function positive(name, fallback) {
  const value = option(name, fallback);
  if (!/^[1-9]\d*$/.test(value ?? '')) throw new Error(`${name} needs a positive whole number`);
  return Number(value);
}

async function checksum(file) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}

async function fetchSources(directory) {
  await mkdir(resolve(directory), { recursive: true });
  for (const source of SOURCES) {
    const file = join(resolve(directory), `${source.corpus}.tar.gz`);
    const present = await stat(file).catch(() => null);
    if (present && (await checksum(file)) === source.sha256) continue;
    const response = await fetch(`${DOWNLOADS}/${source.corpus}.tar.gz`);
    if (!response.ok) throw new Error(`${source.corpus}: HTTP ${response.status}`);
    await writeFile(file, Buffer.from(await response.arrayBuffer()));
    const sha256 = await checksum(file);
    if (sha256 !== source.sha256)
      throw new Error(`${source.corpus}: SHA-256 ${sha256}, expected ${source.sha256}`);
  }
}

async function main() {
  const fetchInto = option('--fetch-sources', null);
  if (fetchInto) return fetchSources(fetchInto);
  const out = option('--out');
  if (!out) throw new Error('--out <dir> is required');
  const directory = option('--source', join(process.env.HOME ?? '.', '.cache/openwhispr/leipzig'));
  const settings = {
    words: positive('--words', '50000'),
    pairs: positive('--pairs', '300000'),
    minCount: positive('--min-count', '3'),
  };
  await fetchSources(directory);
  await mkdir(resolve(out), { recursive: true });
  for (const source of SOURCES) {
    const tarball = join(resolve(directory), `${source.corpus}.tar.gz`);
    const { pairs, stats } = await buildModel(
      () => sentences(tarball, source.corpus),
      source.letters,
      settings,
    );
    const file = join(resolve(out), `KeyboardContext-${source.language}.bin`);
    const bytes = encode(source.language, pairs);
    await writeFile(file, bytes);
    console.log(
      `${file}: ${pairs.length} pairs of ${stats.distinctPairs} (${stats.total} counted), ${Math.round(bytes.length / 1024)} KiB`,
    );
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
