#!/usr/bin/env python3
"""Run the keyboard harness with fork-only fixes in a temporary source copy."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PLUGIN = Path('openwhispr-mobile/plugins/keyboard-extension')
PATCHES = Path(__file__).with_name('headless-keyboard')
# The minimal voice keyboard's harness drives its compact tone menu, which needs the headless
# workarounds in minimal-keyboard.patch. base.patch is only for a harness that needs none of
# them: no simulated control events (the headless runner has no event dispatch) and no Full
# Access switch (its overlay hides the keys). Anything else is unknown and stops. The pick is
# by content, never by which patch happens to apply, so a changed harness still fails closed.
MINIMAL_KEYBOARD_MARKER = 'compactToneMenu'
HEADLESS_SENSITIVE = ('sendActions(', 'fullAccess')


def patch_for(plugin):
    tests = (plugin / 'tests/KeyboardTouchTests.swift').read_text()
    if MINIMAL_KEYBOARD_MARKER in tests:
        return PATCHES / 'minimal-keyboard.patch'
    found = [term for term in HEADLESS_SENSITIVE if term in tests]
    if found:
        sys.exit(f'Unknown keyboard harness (uses {", ".join(found)}): '
                 'add or update a tools/headless-keyboard patch.')
    return PATCHES / 'base.patch'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    source = args.source.resolve()
    # Copy only this self-contained native harness. Never patch the app checkout.
    with tempfile.TemporaryDirectory(prefix='openwhispr-tests-') as directory:
        root = Path(directory)
        plugin = root / PLUGIN
        shutil.copytree(source / PLUGIN, plugin)
        patch = patch_for(plugin)
        print(f'Headless adapter: {patch.name}')
        for command in [
            ['git', 'apply', '--check', str(patch)],
            ['git', 'apply', str(patch)],
        ]:
            subprocess.run(command, cwd=root, check=True)
        if not args.check_only:
            subprocess.run([sys.executable, str(plugin / 'tests/run-keyboard-touch-tests.py')], check=True)


if __name__ == '__main__':
    main()
