#!/usr/bin/env bash
# Can also be read/extracted with git show origin/tests:tests/run-all-tests.sh.
set -euo pipefail
repo=bearylabs/openwhispr
ref=${1:-main}
sha=$(git rev-parse --verify "${ref}^{commit}")
# GitHub CLI cannot resolve a filename absent from the default branch; API IDs work.
workflow_id=$(gh api "repos/$repo/actions/workflows" --paginate --jq \
  '.workflows[] | select(.path == ".github/workflows/tests.yml") | .id')
[[ "$workflow_id" =~ ^[0-9]+$ ]] || { echo 'Fork-test workflow not registered' >&2; exit 1; }
remote_sha=$(gh api "repos/$repo/commits/$sha" --jq .sha)
[[ "$remote_sha" == "$sha" ]]
echo "Testing committed app source: $sha (uncommitted files are not included)"
gh workflow run "$workflow_id" --repo "$repo" --ref tests -f source_ref="$sha"
