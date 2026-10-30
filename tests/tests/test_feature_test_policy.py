"""New feature coverage may ship; upstream test edits and temporary tests may not."""
from pathlib import Path
import subprocess
import sys
import unittest

import test_branch_safety as safety

ROOT = Path(__file__).resolve().parents[2]
EXISTING = 'openwhispr-mobile/plugins/keyboard-extension/tests/KeyboardTouchTests.swift'
NEW = 'openwhispr-mobile/plugins/keyboard-extension/tests/KeyboardAutocorrectionTests.swift'


class FeatureTestPolicyTests(unittest.TestCase):
    # Use the same isolated Git repository + real hook/exporter as the branch tests.
    setUp = safety.BranchSafetyTests.setUp
    git = safety.BranchSafetyTests.git
    write = safety.BranchSafetyTests.write
    commit = safety.BranchSafetyTests.commit
    push = safety.BranchSafetyTests.push

    def assert_allowed(self, sha):
        result = self.push(sha, 'feat/product')
        self.assertEqual(result.returncode, 0, result.stderr)

    def assert_blocked(self, sha, reason):
        result = self.push(sha, 'feat/product')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(reason, result.stderr)

    def test_new_permanent_feature_test_files_allowed(self):
        for name in [NEW, 'test/helpers/feature.test.js',
                     'openwhispr-mobile/src/__tests__/feature.spec.ts',
                     'openwhispr-mobile/scripts/test-feature.sh',
                     'examples/feature/test_example.py', 'feature/widget_test.go',
                     'feature/tests/run-feature-tests.py', 'feature/jest.config.js']:
            with self.subTest(name=name):
                self.git('reset', '--hard', self.feature)
                self.write(name, '// Permanent feature regression coverage\n')
                self.assert_allowed(self.commit('add feature regression'))

    def test_new_feature_test_can_be_updated_in_later_commits(self):
        self.write(NEW, '// initial feature coverage\n')
        self.commit('add feature tests')
        self.write(NEW, '// additional permanent cases\n')
        self.assert_allowed(self.commit('extend this feature test'))

    def test_existing_test_edits_blocked_even_if_only_adding_assertions(self):
        original = (self.root / EXISTING).read_text()
        self.write(EXISTING, original + '// additional assertion\n')
        self.assert_blocked(self.commit('extend existing test'), 'existing upstream test')

    def test_existing_test_deletion_blocked(self):
        self.git('rm', EXISTING)
        self.assert_blocked(self.commit('remove existing test'), 'existing upstream test')

    def test_existing_test_rename_blocked(self):
        self.git('mv', EXISTING, NEW)
        self.assert_blocked(self.commit('rename existing test'), 'existing upstream test')

    def test_existing_test_edit_then_revert_still_blocks_history(self):
        original = (self.root / EXISTING).read_text()
        self.write(EXISTING, original + '// change then revert\n')
        self.commit('edit existing test')
        self.write(EXISTING, original)
        cleaned = self.commit('restore existing test')
        self.assert_blocked(cleaned, 'commit history')

    def test_merge_history_cannot_hide_an_existing_test_edit(self):
        original = (self.root / EXISTING).read_text()
        self.git('checkout', '-qb', 'side')
        self.write(EXISTING, original + '// side-branch change\n')
        self.commit('change test on side branch')
        self.write(EXISTING, original)
        self.commit('restore test on side branch')
        self.git('checkout', '--detach', self.feature)
        self.write('another-product.txt', 'feature\n')
        self.commit('independent feature work')
        self.git('merge', '--no-ff', '-m', 'merge side history', 'side')
        self.assert_blocked(self.git('rev-parse', 'HEAD'), 'commit history')

    def test_existing_runner_changes_blocked(self):
        name = 'openwhispr-mobile/plugins/keyboard-extension/tests/run-keyboard-touch-tests.py'
        self.write(name, '# different runner\n')
        self.assert_blocked(self.commit('change test runner'), 'existing upstream test')

    def test_temporary_test_paths_blocked(self):
        for name in ['feature/__tests__/temporary.test.ts', 'tmp/feature.test.js',
                     'feature/tests/scratch.swift', 'feature/headless-tests/check.py',
                     'feature/tests/foo.tmp.swift', 'feature/test_temp.py']:
            with self.subTest(name=name):
                self.git('reset', '--hard', self.feature)
                self.write(name, '// probe\n')
                self.assert_blocked(self.commit('add probe'), 'temporary/fork-only test')

    def test_temporary_test_markers_blocked_in_regular_file_names(self):
        for marker in ['// @temporary-test', '# @fork-only-test',
                       '/* HEADLESS-ONLY TEST', '// Temporary test for debugging']:
            with self.subTest(marker=marker):
                self.git('reset', '--hard', self.feature)
                self.write(NEW, marker + '\n')
                self.assert_blocked(self.commit('add marked test'), 'temporary/fork-only test marker')

    def test_removing_temporary_marker_later_does_not_clean_pr_history(self):
        self.write(NEW, '// @temporary-test\n')
        self.commit('add temporary probe')
        self.write(NEW, '// now called permanent\n')
        self.assert_blocked(self.commit('remove marker'), 'commit history')

    def test_temporary_test_added_then_removed_still_blocks_history(self):
        self.write(NEW, '// diagnostic probe with an innocent filename\n')
        self.commit('probe')
        self.git('rm', NEW)
        self.assert_blocked(self.commit('remove probe'), 'temporary test only present in commit history')

    def test_temporary_test_path_added_then_removed_still_blocks_history(self):
        name = 'feature/__tests__/scratch.test.ts'
        self.write(name, '// probe\n')
        self.commit('probe')
        self.git('rm', name)
        self.assert_blocked(self.commit('remove probe'), 'commit history')

    def test_new_test_symlinks_blocked(self):
        name = self.root / NEW
        name.symlink_to('KeyboardTouchTests.swift')
        self.assert_blocked(self.commit('test symlink'), 'regular files')

    def test_binary_feature_fixture_allowed(self):
        name = self.root / 'feature/tests/fixtures/new.bin'
        name.parent.mkdir(parents=True)
        name.write_bytes(b'\x89PNG\xff\x00binary fixture\n')
        self.assert_allowed(self.commit('add permanent fixture'))

    def test_spaces_and_newlines_in_test_paths_do_not_bypass_guards(self):
        name = 'feature/__tests__/with\nnewline.tmp.test.ts'
        self.write(name, '// probe\n')
        self.assert_blocked(self.commit('probe'), 'temporary/fork-only test')

    def test_fork_infrastructure_remains_reserved(self):
        self.write('tests/new-feature.test.py', '# wrong namespace: fork infrastructure\n')
        self.assert_blocked(self.commit('add root test infrastructure'), 'fork-only test infrastructure')

    def test_upstream_ci_changes_still_blocked(self):
        self.write('.github/workflows/mobile-ci.yml', 'name: changed\n')
        self.assert_blocked(self.commit('change upstream CI'), 'fork-only test infrastructure')

    def test_clean_export_includes_new_tests_and_keeps_upstream_parent(self):
        self.write(NEW, '// permanent feature regression\n')
        revision = self.commit('feature tests')
        result = subprocess.run([sys.executable, str(ROOT / 'tests/export-upstream.py'),
                                 '--source', revision, '--check-history',
                                 '--create-branch', 'pr/feature-tests'],
                                cwd=self.root, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git('rev-parse', 'pr/feature-tests^'), self.base)
        self.assertIn('permanent', self.git('show', 'pr/feature-tests:' + NEW))
        self.assertEqual(self.git('rev-parse', 'HEAD'), revision)


if __name__ == '__main__':
    unittest.main()
