# dev-rules — how this fork is developed

This branch holds no app code. It holds the rules, test workflows and tooling for
developing the `bearylabs/openwhispr` fork and proposing changes upstream.

Read in this order, then follow them:

1. `RULES.md` — branches, code, tests, upstream PRs (binding)
2. `TESTING.md` — how to run the tests on GitHub runners (incl. macOS)
3. `STATE.md` — current branches and open PRs (may be outdated; verify with git/gh)

Read without switching branches:

```sh
git fetch origin dev-rules
git show origin/dev-rules:RULES.md
```

Prompt for a new agent:

> Read `README.md`, `RULES.md`, `TESTING.md` and `STATE.md` on branch `origin/dev-rules`
> and follow them strictly.
