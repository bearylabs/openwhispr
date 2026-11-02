#!/usr/bin/env node
// Test sentences for the keyboard's context benchmark (`scripts/benchmark-keyboard-autocorrection.sh
// --sentences`), from Leipzig Wikipedia corpora (deu_wikipedia_2021_300K, eng_wikipedia_2016_300K,
// pinned by checksum), never from the news corpora the word pairs are counted in. Test data only,
// written to a cache directory, never into the repository or the keyboard.
//
//   node scripts/build-keyboard-context-sentences.mjs [--source <dir>] [--out <dir>] [--per-split 1500]
//
// Sentences are split by article (dev and test never share one), duplicates are dropped, and so is
// any sentence that also occurs in the news corpus. Kept: 6 to 40 words, the first `--per-split`
// per split in a fixed pseudo-random order. Output: sentences-<language>-<dev|test>.txt.

import { createHash } from 'node:crypto';
import { createReadStream, realpathSync } from 'node:fs';
import { mkdir, stat, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { SOURCES as TRAINING } from './build-keyboard-context-lists.mjs';

const DOWNLOADS = 'https://downloads.wortschatz-leipzig.de/corpora';

export const SOURCES = [
  {
    language: 'de',
    corpus: 'deu_wikipedia_2021_300K',
    sha256: 'ab891f4b7ed4ce71e58e0f1ef4edcbc02417ccc00c998b28bb68e2b4644d90bf',
  },
  {
    language: 'en',
    corpus: 'eng_wikipedia_2016_300K',
    sha256: 'e5ddb839d17b9860849749a486bf3ce3134de25eed9659e2e842c02e34133d72',
  },
];

const hash = (text) => createHash('sha256').update(text).digest('hex');
const normalized = (text) => text.normalize('NFC').replace(/\s+/g, ' ').trim().toLowerCase();

async function* lines(tarball, member) {
  const tar = spawn('tar', ['-xzOf', tarball, member], { stdio: ['ignore', 'pipe', 'inherit'] });
  for await (const line of createInterface({ input: tar.stdout, crlfDelay: Infinity })) yield line;
  const code = await new Promise((done) => tar.on('close', done));
  if (code !== 0) throw new Error(`tar failed on ${tarball}`);
}

async function checksum(file) {
  const digest = createHash('sha256');
  for await (const chunk of createReadStream(file)) digest.update(chunk);
  return digest.digest('hex');
}

async function ensure(directory, source) {
  const file = join(directory, `${source.corpus}.tar.gz`);
  const present = await stat(file).catch(() => null);
  if (!present || (await checksum(file)) !== source.sha256) {
    const response = await fetch(`${DOWNLOADS}/${source.corpus}.tar.gz`);
    if (!response.ok) throw new Error(`${source.corpus}: HTTP ${response.status}`);
    await writeFile(file, Buffer.from(await response.arrayBuffer()));
    if ((await checksum(file)) !== source.sha256)
      throw new Error(`${source.corpus}: wrong SHA-256`);
  }
  return file;
}

function option(name, fallback) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

async function main() {
  const home = process.env.HOME ?? '.';
  const directory = resolve(option('--source', join(home, '.cache/openwhispr/leipzig')));
  const out = resolve(option('--out', join(home, '.cache/openwhispr/context-sentences')));
  const perSplit = option('--per-split', '1500');
  if (!/^[1-9]\d*$/.test(perSplit)) throw new Error('--per-split needs a positive whole number');
  await mkdir(out, { recursive: true });
  for (const source of SOURCES) {
    const training = TRAINING.find((item) => item.language === source.language);
    const tarball = await ensure(directory, source);
    const trainingTarball = await ensure(directory, training);
    const seen = new Set();
    const member = `${training.corpus}/${training.corpus}-sentences.txt`;
    for await (const line of lines(trainingTarball, member)) {
      seen.add(hash(normalized(line.slice(line.indexOf('\t') + 1))).slice(0, 16));
    }
    const article = new Map();
    for await (const line of lines(tarball, `${source.corpus}/${source.corpus}-inv_so.txt`)) {
      const [sourceId, sentenceId] = line.split('\t');
      if (!article.has(sentenceId)) article.set(sentenceId, sourceId);
    }
    const splits = { dev: [], test: [] };
    for await (const line of lines(tarball, `${source.corpus}/${source.corpus}-sentences.txt`)) {
      const tab = line.indexOf('\t');
      const id = line.slice(0, tab);
      const text = line
        .slice(tab + 1)
        .replace(/\s+/g, ' ')
        .trim();
      const words = text.match(/\p{L}+/gu) ?? [];
      if (words.length < 6 || words.length > 40) continue;
      const key = hash(normalized(text)).slice(0, 16);
      if (seen.has(key)) continue;
      seen.add(key);
      const split =
        parseInt(hash(`article:${article.get(id) ?? id}`).slice(0, 8), 16) % 2 ? 'test' : 'dev';
      splits[split].push({ order: hash(`order:${text}`), text });
    }
    for (const [name, sentences] of Object.entries(splits)) {
      const kept = sentences
        .sort((a, b) => (a.order < b.order ? -1 : 1))
        .slice(0, Number(perSplit));
      const file = join(out, `sentences-${source.language}-${name}.txt`);
      await writeFile(file, kept.map((item) => item.text).join('\n') + '\n');
      console.log(`${file}: ${kept.length} of ${sentences.length}`);
    }
  }
}

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
