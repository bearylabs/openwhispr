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

test('autocorrection needs no opt-in and the space-bar settings gesture is removed', () => {
  const controller = fs.readFileSync(path.join(ios, 'KeyboardViewController.swift'), 'utf8');
  expect(controller).not.toContain('germanAutocorrectionPrototype');
  expect(controller).not.toContain('autocorrectionEnabled');
  expect(controller).not.toContain('showAutocorrectionOptions');
  expect(controller).not.toContain('spaceButton.addGestureRecognizer');
  // Default-on must not bypass host restrictions or move correction into all insertions.
  expect(controller).toContain('allowed: ordinaryField && !fieldHidesItsText');
  expect(controller).toContain('proxy.autocorrectionType != .no');
  expect(controller).toContain('!applyDoubleSpacePeriod() && !applyManualSpaceCorrection()');
});
