import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = Path('openwhispr-mobile/plugins/keyboard-extension')
RUNNER = ROOT / 'tests/run-keyboard-tests.py'


def fingerprint(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


class AdapterTests(unittest.TestCase):
    def test_adapter_patches_only_a_temporary_copy(self):
        before = fingerprint(ROOT / PLUGIN)
        subprocess.run([sys.executable, str(RUNNER), str(ROOT), '--check-only'], check=True)
        self.assertEqual(before, fingerprint(ROOT / PLUGIN))

    def test_changed_harness_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            shutil.copytree(ROOT / PLUGIN, source / PLUGIN)
            tests = source / PLUGIN / 'tests/KeyboardTouchTests.swift'
            tests.write_text(tests.read_text().replace('static var fullAccess = false',
                                                       'static var fullAccess = unexpected'))
            result = subprocess.run([sys.executable, str(RUNNER), str(source), '--check-only'],
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_patch_touches_only_reviewed_keyboard_harness_files(self):
        patch = (ROOT / 'tests/headless-keyboard.patch').read_text()
        paths = [line.split(' b/', 1)[1] for line in patch.splitlines()
                 if line.startswith('diff --git ')]
        self.assertEqual(set(paths), {
            str(PLUGIN / 'ios/KeyboardViewController.swift'),
            str(PLUGIN / 'tests/KeyboardTouchTests.swift'),
            str(PLUGIN / 'tests/run-keyboard-touch-tests.py'),
        })


if __name__ == '__main__':
    unittest.main()
