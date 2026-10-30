#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel)
# Respect existing hook managers rather than silently replacing them.
if [[ -n "$(git config --get core.hooksPath || true)" ]]; then
  echo 'A custom core.hooksPath is configured; integrate fork-tests/pre-push there manually.' >&2
  exit 1
fi
hook=$(git rev-parse --git-path hooks/pre-push)
if [[ -e "$hook" ]] && ! grep -q 'openwhispr-fork-tests-guard-v1' "$hook"; then
  echo "Existing $hook is not ours; refusing to overwrite it." >&2
  exit 1
fi
install -m 755 "$root/fork-tests/pre-push" "$hook"
echo "Installed local PR/main safety guard: $hook"
