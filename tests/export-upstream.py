#!/usr/bin/env python3
"""Check a source diff, optionally export a clean PR commit based on upstream/main."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

FORBIDDEN = ('tests/', 'fork-tests/', '.github/workflows/minimal-keyboard-native-tests.yml',
             '.github/workflows/tests.yml', '.github/workflows/fork-tests.yml',
             '.github/workflows/mobile-ci.yml')


def git(*args, **kwargs):
    return subprocess.check_output(['git', *args], **kwargs).decode().strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', default='main')
    parser.add_argument('--base', default='upstream/main')
    parser.add_argument('--create-branch', help='Create a NEW local pr/... branch; never push it')
    args = parser.parse_args()
    root = git('rev-parse', '--show-toplevel')
    os.chdir(root)
    source = git('rev-parse', '--verify', args.source + '^{commit}')
    base = git('rev-parse', '--verify', args.base + '^{commit}')
    ancestor = git('merge-base', base, source)
    names = git('diff', '--name-only', ancestor, source).splitlines()
    forbidden = [name for name in names if any(name.startswith(prefix) for prefix in FORBIDDEN)]
    if forbidden:
        raise SystemExit('REFUSED: fork-only test infrastructure in source diff: ' + ', '.join(forbidden))
    # These adaptations belong ONLY to the temporary headless copy.
    tests = git('show', source + ':openwhispr-mobile/plugins/keyboard-extension/tests/KeyboardTouchTests.swift')
    runner = git('show', source + ':openwhispr-mobile/plugins/keyboard-extension/tests/run-keyboard-touch-tests.py')
    if 'static var fullAccess = true' in tests or 'selectCompactTone(' in tests or '"-O"' in runner:
        raise SystemExit('REFUSED: headless-only keyboard adaptation in app source')
    print('Reviewed source:', source, '\nUpstream base:', base)
    print('Files in the proposed upstream diff:\n' + '\n'.join(names))
    if not args.create_branch:
        print('CHECK ONLY. Review the diff; use --create-branch pr/<name> to export without fork history.')
        return
    if not args.create_branch.startswith('pr/'):
        raise SystemExit('Export branches must start with pr/')
    subprocess.run(['git', 'check-ref-format', '--branch', args.create_branch], check=True, stdout=subprocess.DEVNULL)
    ref = 'refs/heads/' + args.create_branch
    if subprocess.run(['git', 'show-ref', '--verify', '--quiet', ref]).returncode == 0:
        raise SystemExit('REFUSED: branch already exists; no branches are overwritten')
    patch = subprocess.check_output(['git', 'diff', '--binary', ancestor, source])
    if not patch:
        raise SystemExit('No changes to export')
    with tempfile.TemporaryDirectory(prefix='openwhispr-pr-index-') as directory:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(directory) / 'index'))
        subprocess.run(['git', 'read-tree', base], env=env, check=True)
        subprocess.run(['git', 'apply', '--cached', '--check'], input=patch, env=env, check=True)
        subprocess.run(['git', 'apply', '--cached'], input=patch, env=env, check=True)
        tree = git('write-tree', env=env)
        commit = git('commit-tree', tree, '-p', base, '-m', 'fix(ios): improve keyboard sizing and minimal layout')
        subprocess.run(['git', 'update-ref', ref, commit, '0' * 40], check=True)
    print('Created clean local branch:', args.create_branch, commit)
    print('No fork test infrastructure or fork commit history included. Review before pushing.')


if __name__ == '__main__':
    main()
