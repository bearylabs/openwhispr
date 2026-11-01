#!/usr/bin/env bash
# Dispatch the fork test workflow (on dev-rules) for one committed, pushed app revision.
set -euo pipefail
repo=bearylabs/openwhispr
ref=${1:?usage: run-all-tests.sh APP_BRANCH_OR_SHA}
sha=$(git rev-parse --verify "${ref}^{commit}")
remote_sha=$(gh api "repos/$repo/commits/$sha" --jq .sha) || { echo "Push $ref first." >&2; exit 1; }
[[ "$remote_sha" == "$sha" ]]
# Resolve by ID: works whether or not dev-rules is already the default branch.
workflow_id=$(gh api "repos/$repo/actions/workflows" --paginate --jq \
  '.workflows[] | select(.path == ".github/workflows/tests.yml") | .id')
[[ "$workflow_id" =~ ^[0-9]+$ ]] || { echo 'Workflow tests.yml not registered' >&2; exit 1; }
echo "Testing committed app source: $sha (uncommitted files are not included)"
gh workflow run "$workflow_id" --repo "$repo" --ref dev-rules -f source_ref="$sha"
