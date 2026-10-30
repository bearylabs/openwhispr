#!/usr/bin/env python3
"""Check an app diff/PR history, optionally export a clean commit based on upstream/main."""
import argparse
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile

# Reserved personal infrastructure, not the regular upstream test directories.
FORBIDDEN = ('tests/', 'fork-tests/', '.github/workflows/minimal-keyboard-native-tests.yml',
             '.github/workflows/tests.yml', '.github/workflows/fork-tests.yml',
             '.github/workflows/mobile-ci.yml')
TEST_DIRECTORIES = {'test', 'tests', '__tests__', '__snapshots__', '__fixtures__', '__mocks__'}
TEMPORARY_PART = re.compile(r'(^|[._-])(tmp|temp|temporary|scratch|headless|fork)([._-]|$)', re.I)
TEMPORARY_HEADER = re.compile(
    r'^\s*(?:#|//|/\*|\*)\s*(?:@(?:temporary|fork-only|headless-only)-test\b|'
    r'(?:temporary|scratch|fork-only|headless-only)\s+tests?\b)', re.I | re.M)


def git(*args, **kwargs):
    return subprocess.check_output(['git', *args], **kwargs).decode().strip()


def paths(*args):
    # Do not split on newlines or strip filenames: Git supports both in a path.
    return [name for name in subprocess.check_output(['git', *args]).decode().split('\0') if name]


def is_test_path(name):
    path = PurePosixPath(name)
    lower = path.name.lower()
    return (any(part.lower() in TEST_DIRECTORIES
                or re.search(r'(?:^|[-_])tests?(?:$|[-_])', part.lower())
                for part in path.parts[:-1])
            or bool(re.search(r'(?:^test[-_]|[._-](?:test|spec)(?:[._-]|$)|tests?\.swift$|'
                              r'^run[-_].*tests?[._-])', lower))
            or lower in {'pytest.ini', 'conftest.py'}
            or bool(re.match(r'^(?:jest|vitest|playwright|cypress)\.config\.', lower)))


def is_temporary_test_path(name):
    return is_test_path(name) and any(TEMPORARY_PART.search(part)
                                      for part in PurePosixPath(name).parts)


def check_changes(revision, names, upstream_tests, source_paths, history=False):
    where = ' in commit history' if history else ' in source diff'
    # mobile-ci.yml is upstream CI: keep its existing net-diff ban, not a history ban.
    forbidden = FORBIDDEN[:-1] if history else FORBIDDEN
    for name in names:
        if any(name.startswith(prefix) for prefix in forbidden):
            raise SystemExit('REFUSED: fork-only test infrastructure' + where + ': ' + repr(name))
        if name in upstream_tests:
            raise SystemExit('REFUSED: existing upstream test changed/deleted/renamed' + where
                             + ': ' + repr(name) + '; add a separate permanent feature test file')
        if is_temporary_test_path(name):
            raise SystemExit('REFUSED: temporary/fork-only test' + where + ': ' + repr(name))
        if not is_test_path(name):
            continue
        if history and name not in source_paths:
            raise SystemExit('REFUSED: temporary test only present in commit history: ' + repr(name))
        entries = paths('ls-tree', '-z', revision, '--', name)
        if not entries:  # Deletion of a feature-local test, never an upstream test.
            continue
        mode = entries[0].split(' ', 1)[0]
        if mode not in {'100644', '100755'}:
            raise SystemExit('REFUSED: feature tests must be regular files' + where + ': ' + repr(name))
        content = subprocess.check_output(['git', 'show', revision + ':' + name]).decode(errors='replace')
        if TEMPORARY_HEADER.search(content):
            raise SystemExit('REFUSED: temporary/fork-only test marker' + where + ': ' + repr(name))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', default='integration')
    parser.add_argument('--check-history', action='store_true',
                        help='Also reject existing-test edits and temporary/fork tests in PR ancestry')
    parser.add_argument('--base', default='upstream/main')
    parser.add_argument('--create-branch', help='Create a NEW local pr/... branch; never push it')
    args = parser.parse_args()
    root = git('rev-parse', '--show-toplevel')
    os.chdir(root)
    source = git('rev-parse', '--verify', args.source + '^{commit}')
    base = git('rev-parse', '--verify', args.base + '^{commit}')
    ancestor = git('merge-base', base, source)
    upstream_tests = {name for name in paths('ls-tree', '-r', '--name-only', '-z', ancestor)
                      if is_test_path(name)}
    source_paths = set(paths('ls-tree', '-r', '--name-only', '-z', source))
    names = paths('diff', '--no-renames', '--name-only', '-z', ancestor, source)
    check_changes(source, names, upstream_tests, source_paths)
    if args.check_history:
        # Check each commit, including each merge parent, against the SAME upstream
        # baseline. A test added by this feature may be revised in later feature commits.
        # Renames are deliberately shown as deletion + addition to catch existing tests.
        for revision in git('rev-list', ancestor + '..' + source).splitlines():
            changed = paths('diff-tree', '--root', '-m', '-r', '--no-commit-id',
                            '--no-renames', '--name-only', '-z', revision)
            check_changes(revision, changed, upstream_tests, source_paths, history=True)
    # These adaptations belong ONLY to the temporary headless copy.
    tests = git('show', source + ':openwhispr-mobile/plugins/keyboard-extension/tests/KeyboardTouchTests.swift')
    runner = git('show', source + ':openwhispr-mobile/plugins/keyboard-extension/tests/run-keyboard-touch-tests.py')
    if 'static var fullAccess = true' in tests or 'selectCompactTone(' in tests or '"-O"' in runner:
        raise SystemExit('REFUSED: headless-only keyboard adaptation in app source')
    print('Reviewed source:', source, '\nUpstream base:', base)
    print('Files in the proposed upstream diff:\n' + '\n'.join(names))
    print('Test policy: new permanent feature files allowed; existing upstream tests unchanged.')
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
