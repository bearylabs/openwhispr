#!/usr/bin/env python3
"""Run the keyboard harness with fork-only fixes in a temporary source copy."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    source = args.source.resolve()
    relative = Path('openwhispr-mobile/plugins/keyboard-extension')
    patch = Path(__file__).with_name('headless-keyboard.patch')
    # Copy only this self-contained native harness. Never patch the app checkout.
    with tempfile.TemporaryDirectory(prefix='openwhispr-fork-tests-') as directory:
        root = Path(directory)
        plugin = root / relative
        shutil.copytree(source / relative, plugin)
        for command in [
            ['git', 'apply', '--check', str(patch)],
            ['git', 'apply', str(patch)],
        ]:
            subprocess.run(command, cwd=root, check=True)
        if not args.check_only:
            subprocess.run([sys.executable, str(plugin / 'tests/run-keyboard-touch-tests.py')], check=True)


if __name__ == '__main__':
    main()
