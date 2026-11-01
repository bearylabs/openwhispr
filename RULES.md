# Rules

`origin` = `bearylabs/openwhispr` (fork), `upstream` = `OpenWhispr/openwhispr`.

## Branches

- `main` is an exact mirror of `upstream/main`. Never commit to it. Refresh:
  `git fetch upstream && git switch main && git merge --ff-only upstream/main && git push origin main`.
- `dev-rules` (default branch of the fork) holds only rules, workflows and `tools/`.
  Never merge it into anything, never merge anything into it.
- New work starts on a topic branch from `upstream/main` (`feat/…`, `fix/…`).
  One topic per branch; never stack on another feature unless asked.
- A branch with an open PR gets only finished, tested work as clean commits. Iterate on
  `<branch>-experimental` and move finished work over (cherry-pick or squash).
- Never push to `upstream`. Force-push only with `--force-with-lease` and only when asked.
  Never delete remote branches without asking.
- Install the push guard once per clone: `bash tools/install-guard.sh` (from a dev-rules checkout).

## Code

- Upstream's `CLAUDE.md` in the app branch is binding (architecture, i18n in all locales,
  icons, assets, Node 24 lockfile). Read it before changing code.
- Smallest change that solves the problem, in upstream's style. No unrelated refactors,
  reformatting or dependency bumps.
- Nothing fork-specific in an app branch: no workflows, adapters, probes, personal notes.

## Tests

- Every behavior change ships with tests in the same branch; they go upstream with it.
- Change an existing test only for an intentional behavior change, never to turn a run green.
  Never weaken security gates (audit exceptions, skipped assertions).
- Run what works locally on Linux; run the rest per `TESTING.md`.
- "Tested" means a green run for the exact SHA being proposed. Uncommitted edits are untested.

## Upstream PRs

- Before proposing: `git log --oneline upstream/main..BRANCH` and
  `git diff upstream/main...BRANCH` contain only the topic, nothing fork-specific.
- Commits: Conventional Commits (`feat(scope): …`), each self-contained, no WIP/fixup.
- PR from the fork branch to `OpenWhispr/openwhispr:main`, as draft. Description: what, why,
  how it was tested (link the run). Screenshots for UI changes.

## Ask first

Before pushing, opening or updating a PR, force-pushing, deleting branches,
or changing GitHub settings, ask and wait for a yes.
