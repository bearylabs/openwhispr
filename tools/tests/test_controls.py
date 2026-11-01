import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = Path('openwhispr-mobile/plugins/keyboard-extension')
RUNNER = ROOT / 'tools/run-keyboard-tests.py'
# The app checkout the adapter is validated against; CI passes the commit under test.
APP_ROOT = (ROOT / os.environ.get('KEYBOARD_APP_SOURCE', '.')).resolve()


def fingerprint(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


class AdapterTests(unittest.TestCase):
    def test_adapter_patches_only_a_temporary_copy(self):
        before = fingerprint(APP_ROOT / PLUGIN)
        subprocess.run([sys.executable, str(RUNNER), str(APP_ROOT), '--check-only'], check=True)
        self.assertEqual(before, fingerprint(APP_ROOT / PLUGIN))

    def assert_fails_closed(self, relative, original, changed):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            shutil.copytree(APP_ROOT / PLUGIN, source / PLUGIN)
            target = source / PLUGIN / relative
            text = target.read_text()
            self.assertIn(original, text)
            target.write_text(text.replace(original, changed))
            result = subprocess.run([sys.executable, str(RUNNER), str(source), '--check-only'],
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_changed_harness_fails_closed(self):
        # Every patch adapts the compiler call, so this covers whichever one is picked.
        self.assert_fails_closed('tests/run-keyboard-touch-tests.py',
                                 '"swiftc", "-swift-version"', '"swiftc", "-unexpected"')
        tests = (APP_ROOT / PLUGIN / 'tests/KeyboardTouchTests.swift').read_text()
        if 'compactToneMenu' in tests:
            self.assert_fails_closed('tests/KeyboardTouchTests.swift',
                                     'static var fullAccess = false',
                                     'static var fullAccess = unexpected')

    def test_patch_is_picked_by_feature(self):
        spec = importlib.util.spec_from_file_location('runner', RUNNER)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with tempfile.TemporaryDirectory() as directory:
            plugin = Path(directory)
            (plugin / 'tests').mkdir()
            tests = plugin / 'tests/KeyboardTouchTests.swift'
            tests.write_text('controller.toneButton')
            self.assertEqual(runner.patch_for(plugin).name, 'base.patch')
            tests.write_text('controller.compactToneMenu.isHidden')
            self.assertEqual(runner.patch_for(plugin).name, 'minimal-keyboard.patch')
            # A harness that needs a headless workaround but lost the marker stops.
            for unknown in ['controller.compactTonePanel; static var fullAccess = false',
                            'controller.toneButton.sendActions(for: .touchUpInside)']:
                tests.write_text(unknown)
                with self.assertRaises(SystemExit):
                    runner.patch_for(plugin)

    def test_marker_loss_fails_closed(self):
        tests = (APP_ROOT / PLUGIN / 'tests/KeyboardTouchTests.swift').read_text()
        if 'compactToneMenu' not in tests:
            return
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            shutil.copytree(APP_ROOT / PLUGIN, source / PLUGIN)
            for relative in ['tests/KeyboardTouchTests.swift', 'ios/KeyboardViewController.swift']:
                path = source / PLUGIN / relative
                path.write_text(path.read_text().replace('compactToneMenu', 'compactTonePanel'))
            result = subprocess.run([sys.executable, str(RUNNER), str(source), '--check-only'],
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_patch_touches_only_reviewed_keyboard_harness_files(self):
        expected = {
            'base.patch': {str(PLUGIN / 'tests/run-keyboard-touch-tests.py')},
            'minimal-keyboard.patch': {
                str(PLUGIN / 'ios/KeyboardViewController.swift'),
                str(PLUGIN / 'tests/KeyboardTouchTests.swift'),
                str(PLUGIN / 'tests/run-keyboard-touch-tests.py'),
            },
        }
        patches = sorted((ROOT / 'tools/headless-keyboard').glob('*.patch'))
        self.assertEqual({p.name for p in patches}, set(expected))
        for patch in patches:
            paths = {line.split(' b/', 1)[1] for line in patch.read_text().splitlines()
                     if line.startswith('diff --git ')}
            self.assertEqual(paths, expected[patch.name], patch.name)


if __name__ == '__main__':
    unittest.main()
