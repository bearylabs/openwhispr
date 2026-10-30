"""Test changes are manually reviewed, not restricted by push/export heuristics."""
from pathlib import Path
import subprocess
import sys
import unittest

import test_branch_safety as safety

ROOT = Path(__file__).resolve().parents[2]
EXISTING = 'openwhispr-mobile/plugins/keyboard-extension/tests/KeyboardTouchTests.swift'
NEW = 'openwhispr-mobile/plugins/keyboard-extension/tests/KeyboardAutocorrectionTests.swift'


class ManualTestReviewTests(unittest.TestCase):
    setUp = safety.BranchSafetyTests.setUp
    git = safety.BranchSafetyTests.git
    write = safety.BranchSafetyTests.write
    commit = safety.BranchSafetyTests.commit
    push = safety.BranchSafetyTests.push

    def assert_allowed(self, sha):
        pushed = self.push(sha, 'feat/product')
        self.assertEqual(pushed.returncode, 0, pushed.stderr)
        reviewed = subprocess.run([sys.executable, str(ROOT / 'tests/export-upstream.py'),
                                   '--source', sha, '--check-history'],
                                  cwd=self.root, text=True, capture_output=True)
        self.assertEqual(reviewed.returncode, 0, reviewed.stderr)
        self.assertIn('Manual review required', reviewed.stdout)

    def test_new_feature_test_allowed(self):
        self.write(NEW, '// feature coverage\n')
        self.assert_allowed(self.commit('new regression'))

    def test_existing_test_edits_allowed(self):
        self.write(EXISTING, '// revised expectations for intentional behavior\n')
        self.assert_allowed(self.commit('update existing regression'))

    def test_existing_test_deletion_allowed(self):
        self.git('rm', EXISTING)
        self.assert_allowed(self.commit('remove obsolete test'))

    def test_existing_test_rename_allowed(self):
        self.git('mv', EXISTING, NEW)
        self.assert_allowed(self.commit('rename test'))

    def test_temporary_and_fork_paths_are_not_classified(self):
        for name in ['tests/probe.py', 'fork-tests/probe.py',
                     'feature/__tests__/scratch.tmp.test.ts', '.github/workflows/mobile-ci.yml']:
            with self.subTest(name=name):
                self.git('reset', '--hard', self.feature)
                self.write(name, '// @temporary-test\n')
                self.assert_allowed(self.commit('requires manual scope review'))

    def test_marker_in_history_is_not_a_policy_gate(self):
        self.write(NEW, '// @headless-only-test\n')
        self.commit('probe')
        self.git('rm', NEW)
        self.assert_allowed(self.commit('remove probe'))

    def test_export_includes_revised_tests_and_preserves_checkout(self):
        self.write(EXISTING, '// revised existing tests\n')
        self.write(NEW, '// new feature tests\n')
        revision = self.commit('feature and regression changes')
        command = [sys.executable, str(ROOT / 'tests/export-upstream.py'), '--source', revision,
                   '--create-branch', 'pr/feature-tests']
        result = subprocess.run(command, cwd=self.root, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        exported = self.git('rev-parse', 'pr/feature-tests')
        self.assertEqual(self.git('rev-parse', 'pr/feature-tests^'), self.base)
        self.assertIn('revised existing', self.git('show', 'pr/feature-tests:' + EXISTING))
        self.assertIn('new feature', self.git('show', 'pr/feature-tests:' + NEW))
        self.assertEqual(self.git('rev-parse', 'HEAD'), revision)
        repeated = subprocess.run(command, cwd=self.root, text=True, capture_output=True)
        self.assertNotEqual(repeated.returncode, 0)
        self.assertEqual(self.git('rev-parse', 'pr/feature-tests'), exported)


if __name__ == '__main__':
    unittest.main()
