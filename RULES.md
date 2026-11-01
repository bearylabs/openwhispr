# Rules

`origin` = `bearylabs/openwhispr` (fork), `upstream` = `OpenWhispr/openwhispr`.

## Branches

- `main` is an exact mirror of `upstream/main`. Never commit to it. Refresh:
  `git fetch upstream && git switch main && git merge --ff-only upstream/main && git push origin main`.
- `dev-rules` (default branch of the fork) holds only rules, workflows and `tools/`.
  Never merge it into anything, never merge anything into it.
- Every topic has two branches, paired by name:
  - `<type>/<topic>`: the feature branch. It becomes the upstream PR, so the name tells a
    reviewer what changes (`feat/ios-keyboard-autocorrection`). Protected: changes only
    through a squash-merged PR from its experimental branch.
  - `exp/<type>/<topic>`: the experimental branch. No rules: commit, revert, force-push freely.

  `type` is a Conventional Commit type (`feat fix chore docs refactor perf test ci build`),
  `topic` is lowercase kebab-case, no `wip`, `v2` or `test`. Other names are refused.
- One topic per pair; never stack on another feature unless asked.
- Never push to `upstream`. Never delete remote branches without asking.
- Install the push guard once per clone: `bash tools/install-guard.sh` (from a dev-rules checkout).

## Workflow per topic

1. Start: create both branches from `upstream/main`, push both. Work only in `exp/`.
2. Land a good state: tests green on the `exp/` SHA (`TESTING.md`), then a PR inside the fork,
   squash-merged. Its title is the commit message (Conventional Commit), its body the commit body:
   `gh pr create --repo bearylabs/openwhispr --base <type>/<topic> --head exp/<type>/<topic>`
   (without `--repo` gh targets upstream). Several ordered commits = several PRs, one per commit.
3. Right after: `git switch exp/<type>/<topic> && git merge origin/<type>/<topic>` and push, so
   the next PR shows only new work. The trees must then be equal
   (`git rev-parse origin/<type>/<topic>^{tree} origin/exp/<type>/<topic>^{tree}`), which makes
   the `exp/` test run valid for the feature branch.
4. Open the upstream PR from `<type>/<topic>` once the first good state has landed. Later
   landings update it automatically; never develop on the feature branch itself.
5. Rebasing a feature branch onto a newer `upstream/main` needs a force-push, which the ruleset
   blocks. Only when asked: disable the ruleset (`gh api -X PUT
   repos/bearylabs/openwhispr/rulesets/<id> -f enforcement=disabled`), rebase, push with
   `--force-with-lease --no-verify` (the push guard refuses it too), re-enable it (`-f enforcement=active`), then merge the result into `exp/`.

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
