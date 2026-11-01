"""Exercise push policy without network access or actual pushes."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BranchSafetyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git('init', '-q')
        self.git('config', 'user.email', 'tests@example.invalid')
        self.git('config', 'user.name', 'Guard Tests')
        self.write('openwhispr-mobile/plugins/keyboard-extension/tests/KeyboardTouchTests.swift',
                   'static var fullAccess = false\n')
        self.write('openwhispr-mobile/plugins/keyboard-extension/tests/run-keyboard-touch-tests.py',
                   '# unadapted harness\n')
        self.base = self.commit('upstream base')
        self.git('update-ref', 'refs/remotes/upstream/main', self.base)
        self.write('README.md', 'Infrastructure only\n')
        self.control = self.commit('test infrastructure')
        self.git('update-ref', 'refs/remotes/origin/dev-rules', self.control)
        self.git('reset', '--hard', self.base)
        self.write('app.txt', 'product change\n')
        self.feature = self.commit('clean product feature')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root,
                                       stderr=subprocess.PIPE).decode().strip()

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self, message):
        self.git('add', '.')
        self.git('commit', '-qm', message)
        return self.git('rev-parse', 'HEAD')

    def push(self, sha, branch, url='https://github.com/bearylabs/openwhispr.git', remote_sha='0' * 40):
        return subprocess.run(['bash', str(ROOT / 'tools/pre-push'), 'origin', url],
                              cwd=self.root, text=True, capture_output=True,
                              input=f'refs/heads/local {sha} refs/heads/{branch} {remote_sha}\n')

    def test_main_must_match_upstream(self):
        self.assertEqual(self.push(self.base, 'main').returncode, 0)
        self.assertNotEqual(self.push(self.feature, 'main').returncode, 0)

    def test_experimental_branches_take_anything(self):
        for sha in [self.feature, self.control]:
            self.assertEqual(self.push(sha, 'exp/feat/keyboard').returncode, 0)
            self.assertEqual(self.push(sha, 'exp/docs/keyboard', remote_sha=self.base).returncode, 0)

    def test_protected_branch_is_created_from_upstream_only(self):
        for kind in ['feat', 'fix', 'chore', 'docs', 'refactor', 'perf', 'test', 'ci', 'build']:
            with self.subTest(kind=kind):
                self.assertEqual(self.push(self.base, f'{kind}/keyboard').returncode, 0)
                self.assertNotEqual(self.push(self.feature, f'{kind}/keyboard').returncode, 0)

    def test_protected_branch_is_never_updated_directly(self):
        result = self.push(self.feature, 'feat/keyboard', remote_sha=self.base)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exp/feat/keyboard', result.stderr)

    def test_infrastructure_and_storage_branches_are_free(self):
        for branch in ['dev-rules', 'backup/old-main', 'pr-assets/keyboard']:
            self.assertEqual(self.push(self.control, branch).returncode, 0)

    def test_unknown_branch_names_are_refused(self):
        for branch in ['keyboard', 'feature/keyboard', 'feat/Keyboard', 'feat/keyboard-',
                       'feat/a/b', 'exp/keyboard', 'tests', 'feat/keyboard-experimental-v2_']:
            with self.subTest(branch=branch):
                self.assertNotEqual(self.push(self.base, branch).returncode, 0)

    def test_deletions_are_left_to_the_ruleset(self):
        self.assertEqual(self.push('0' * 40, 'feat/keyboard', remote_sha=self.base).returncode, 0)

    def test_direct_upstream_push_blocked(self):
        for url in ['https://github.com/OpenWhispr/openwhispr.git',
                    'git@github.com:OpenWhispr/openwhispr.git']:
            self.assertNotEqual(self.push(self.feature, 'exp/feat/keyboard', url).returncode, 0)


if __name__ == '__main__':
    unittest.main()
