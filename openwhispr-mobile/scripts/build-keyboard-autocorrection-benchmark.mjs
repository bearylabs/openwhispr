#!/usr/bin/env node
// Builds the keyboard autocorrection benchmark from LibreOffice's autocorrect lists
// (extras/source/autocorr/lang/{de,en-US}/DocumentList.xml, MPL 2.0), pinned below.
// Test data only: the keyboard never reads these lists, and nothing from them is in its code.
//
//   node scripts/build-keyboard-autocorrection-benchmark.mjs [--source <dir with de.xml, en-US.xml>]
//
// Keeps every entry whose typed form is one word of letters and whose correction is letters
// with single spaces, apostrophes or hyphens between them: typos, case changes, missing spaces
// and contractions. Drops symbol and emoji substitutions (`:...:`, `-->`, `(c)`), digits,
// patterns and entries whose typed form already has a space or apostrophe.

import { createHash } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OUT_DIR = join(ROOT, 'plugins/keyboard-extension/tests/benchmark');

// The last commits that changed each list (checked 2026-11-02), and the files' SHA-256.
export const SOURCES = [
  {
    language: 'de',
    path: 'extras/source/autocorr/lang/de/DocumentList.xml',
    commit: '7c1bad415ae48635dc67041c413bb7b76a530c22',
    sha256: '83a1a1e44f932ac76b528a9af3559a60284f3ec6e734cb7b5888b5440788dd22',
    file: 'de.xml',
  },
  {
    language: 'en',
    path: 'extras/source/autocorr/lang/en-US/DocumentList.xml',
    commit: '26cc060303b98a64daf2c71457811241dc4a0b45',
    sha256: 'e7e3591f3809c0d6dd118a4806882aaab6816766e8d1c09bfddd42a170ceddf3',
    file: 'en-US.xml',
  },
];

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

function decode(value) {
  return value.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (match, name) => {
    if (name[0] === '#') {
      const code =
        name[1].toLowerCase() === 'x' ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      return String.fromCodePoint(code);
    }
    return ENTITIES[name] ?? match;
  });
}

const LETTERS = /^\p{L}+$/u;
const TARGET = /^\p{L}+(?:[ '’-]\p{L}+)*$/u;

/** The entries of one DocumentList.xml, filtered, with the counts of what was dropped. */
export function parseDocumentList(xml) {
  const blocks = [...xml.matchAll(/<block-list:block\s+([^>]*?)\/>/g)].map((match) => {
    const attributes = Object.fromEntries(
      [...match[1].matchAll(/block-list:([a-z-]+)="([^"]*)"/g)].map((a) => [a[1], decode(a[2])]),
    );
    return { typed: attributes['abbreviated-name'], expected: attributes.name };
  });
  const kept = [];
  const seen = new Map();
  let dropped = 0;
  let conflicts = 0;
  for (const { typed, expected } of blocks) {
    if (
      !typed ||
      !expected ||
      typed === expected ||
      !LETTERS.test(typed) ||
      !TARGET.test(expected)
    ) {
      dropped += 1;
      continue;
    }
    if (seen.has(typed)) {
      // Never overwrite silently: a second, different correction for the same word is reported.
      if (seen.get(typed) !== expected) conflicts += 1;
      continue;
    }
    seen.set(typed, expected);
    kept.push({ typed: typed.normalize('NFC'), expected: expected.normalize('NFC') });
  }
  return { total: blocks.length, kept, dropped, conflicts };
}

/** Tags for the report; one entry may have several. */
export function tags(typed, expected) {
  const result = [];
  if (typed.toLowerCase() === expected.toLowerCase()) result.push('case');
  if (expected.includes(' ')) result.push('space');
  if (/['’]/.test(expected)) result.push('apostrophe');
  if (expected.includes('-')) result.push('hyphen');
  if (
    expected !== expected.toLowerCase() &&
    typed === typed.toLowerCase() &&
    !result.includes('case')
  ) {
    result.push('capital');
  }
  if ([...typed].length > 20) result.push('long');
  if ([...typed].length <= 2) result.push('short');
  if (result.length === 0) result.push('word');
  return result;
}

async function readSource(source, directory) {
  if (directory) return readFile(join(directory, source.file));
  const url = `https://raw.githubusercontent.com/LibreOffice/core/${source.commit}/${source.path}`;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  return Buffer.from(await response.arrayBuffer());
}

async function main() {
  const index = process.argv.indexOf('--source');
  const directory = index >= 0 ? process.argv[index + 1] : null;
  await mkdir(OUT_DIR, { recursive: true });
  for (const source of SOURCES) {
    const bytes = await readSource(source, directory);
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    if (sha256 !== source.sha256)
      throw new Error(`${source.path}: SHA-256 ${sha256}, expected ${source.sha256}`);
    const { total, kept, dropped, conflicts } = parseDocumentList(bytes.toString('utf8'));
    const lines = [
      `# LibreOffice autocorrect, ${source.path} at ${source.commit}`,
      '# Mozilla Public License 2.0 (https://mozilla.org/MPL/2.0/); test data only, not shipped.',
      `# Generated by scripts/build-keyboard-autocorrection-benchmark.mjs: ${total} entries, ${kept.length} kept, ${dropped} symbol/pattern entries dropped, ${conflicts} conflicting duplicates dropped.`,
      '# typed\texpected\ttags',
      ...kept.map(
        ({ typed, expected }) => `${typed}\t${expected}\t${tags(typed, expected).join(',')}`,
      ),
    ];
    const out = join(OUT_DIR, `libreoffice-${source.language}.tsv`);
    await writeFile(out, lines.join('\n') + '\n');
    console.log(`${out}: ${kept.length} of ${total} entries`);
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
