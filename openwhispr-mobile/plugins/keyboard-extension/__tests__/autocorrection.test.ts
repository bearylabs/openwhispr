import fs from 'fs';
import path from 'path';
import { spawnSync } from 'child_process';

const mobile = path.resolve(__dirname, '../../..');
const ios = path.join(__dirname, '../ios');

// Exercise the production Swift rules, not a JavaScript reimplementation. Linux CI without
// Swift explicitly skips this test; run the same script on macOS before device testing.
const hasSwift = spawnSync('swiftc', ['--version']).status === 0;
(hasSwift ? test : test.skip)('production Swift decision, invalidation and undo tests', () => {
  const result = spawnSync('sh', ['scripts/test-keyboard-autocorrection.sh'], {
    cwd: mobile,
    encoding: 'utf8',
  });
  expect(result.stderr).toBe('');
  expect(result.status).toBe(0);
  expect(result.stdout).toContain('checks passed');
});

test('all new native UI strings have translations in every supported language', () => {
  const catalog = JSON.parse(fs.readFileSync(path.join(ios, 'Localizable.xcstrings'), 'utf8'));
  const controller = fs.readFileSync(path.join(ios, 'KeyboardViewController.swift'), 'utf8');
  const keys = [...new Set(controller.match(/autocorrection\.[a-z]+/g))].filter((key) =>
    ['title', 'body', 'enable', 'disable', 'cancel', 'hint'].some((name) =>
      key.endsWith(`.${name}`),
    ),
  );
  expect(keys).toHaveLength(6);
  for (const key of keys) {
    for (const language of ['en', 'de', 'es', 'fr', 'it', 'pt', 'ru', 'zh-Hans', 'zh-Hant']) {
      expect(catalog.strings[key].localizations[language].stringUnit.value.trim()).not.toBe('');
    }
  }
});
