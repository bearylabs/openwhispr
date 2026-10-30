#!/usr/bin/env python3
"""List a proposed PR diff for manual review, optionally export a clean upstream-based commit."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def git(*args, **kwargs):
    return subprocess.check_output(['git', *args], **kwargs).decode().strip()


def paths(*args):
    return [name for name in subprocess.check_output(['git', *args]).decode().split('\0') if name]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', default='integration')
    # Retained for compatibility; history is displayed for review, never classified.
    parser.add_argument('--check-history', action='store_true',
                        help='Display commit history for manual review; no test-change restrictions')
    parser.add_argument('--base', default='upstream/main')
    parser.add_argument('--create-branch', help='Create a NEW local pr/... branch; never push it')
    args = parser.parse_args()
    os.chdir(git('rev-parse', '--show-toplevel'))
    source = git('rev-parse', '--verify', args.source + '^{commit}')
    base = git('rev-parse', '--verify', args.base + '^{commit}')
    ancestor = git('merge-base', base, source)
    names = paths('diff', '--no-renames', '--name-only', '-z', ancestor, source)
    print('Source:', source, '\nUpstream base:', base)
    print('Files in the proposed upstream diff:\n' + '\n'.join(names))
    if args.check_history:
        print('Commit history for manual review:\n' + git('log', '--oneline', ancestor + '..' + source))
    print('Manual review required: test changes, temporary probes, adapters and PR scope are not automatically restricted.')
    if not args.create_branch:
        print('REVIEW ONLY. Use --create-branch pr/<name> to export after reviewing the diff.')
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
        commit = git('commit-tree', tree, '-p', base, '-m', 'chore: export reviewed app changes')
        subprocess.run(['git', 'update-ref', ref, commit, '0' * 40], check=True)
    print('Created local branch:', args.create_branch, commit)
    print('Exported the complete net diff, including test changes. Review before pushing; nothing was pushed.')


if __name__ == '__main__':
    main()
