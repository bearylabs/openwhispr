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
        self.write('tests/export-upstream.py', (ROOT / 'tests/export-upstream.py').read_text())
        self.write('tests/README.md', 'Infrastructure only\n')
        self.control = self.commit('test infrastructure')
        self.git('update-ref', 'refs/remotes/origin/tests', self.control)
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

    def push(self, sha, branch, url='https://github.com/bearylabs/openwhispr.git'):
        return subprocess.run(['bash', str(ROOT / 'tests/pre-push'), 'origin', url],
                              cwd=self.root, text=True, capture_output=True,
                              input=f'refs/heads/local {sha} refs/heads/{branch} {"0" * 40}\n')

    def test_main_must_match_upstream(self):
        self.assertEqual(self.push(self.base, 'main').returncode, 0)
        self.assertNotEqual(self.push(self.feature, 'main').returncode, 0)

    def test_clean_feature_allowed_but_infrastructure_blocked(self):
        self.assertEqual(self.push(self.feature, 'feat/keyboard').returncode, 0)
        self.assertNotEqual(self.push(self.control, 'feat/keyboard').returncode, 0)
        self.assertEqual(self.push(self.control, 'tests').returncode, 0)

    def test_removed_infrastructure_still_blocks_history(self):
        self.write('.github/workflows/minimal-keyboard-native-tests.yml', 'name: personal\n')
        self.commit('add personal CI')
        shutil.rmtree(self.root / '.github')
        cleaned = self.commit('remove personal CI')
        result = self.push(cleaned, 'feat/keyboard')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('commit history', result.stderr)
        self.assertEqual(self.push(cleaned, 'backup/old-main').returncode, 0)

    def test_headless_markers_block_feature(self):
        self.write('openwhispr-mobile/plugins/keyboard-extension/tests/KeyboardTouchTests.swift',
                   'static var fullAccess = true\n')
        adapted = self.commit('headless adaptation')
        self.assertNotEqual(self.push(adapted, 'feat/keyboard').returncode, 0)

    def test_direct_upstream_push_blocked(self):
        for url in ['https://github.com/OpenWhispr/openwhispr.git',
                    'git@github.com:OpenWhispr/openwhispr.git']:
            self.assertNotEqual(self.push(self.feature, 'feat/keyboard', url).returncode, 0)


if __name__ == '__main__':
    unittest.main()
