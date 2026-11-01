# dev-rules: binding rules for developing this fork

`origin` = `bearylabs/openwhispr`, `upstream` = `OpenWhispr/openwhispr`. No app code here.
The app branch's `CLAUDE.md` is binding as well.

## Branches

- `main`: exact mirror of `upstream/main`, updated only with `git merge --ff-only upstream/main`.
- `dev-rules`: this branch. Never merge into or out of it.
- Per topic, both from `upstream/main`:
  - `<type>/<topic>`: becomes the upstream PR. Protected: changes only by squash PR from `exp/`.
  - `exp/<type>/<topic>`: free. Commit, revert, force-push, experiment.

  `type`: `feat fix chore docs refactor perf test ci build`. `topic`: lowercase kebab-case that
  tells a reviewer what changes. One topic per pair.
- `backup/*`, `pr-assets/*`: storage, never a PR source.
- Once per clone, in a dev-rules checkout: `bash tools/install-guard.sh` (push guard).

## Workflow

1. Create and push both branches. Work only in `exp/`.
2. Test the pushed `exp/` SHA (mobile and native Mac on GitHub runners; desktop: `npm test`):
   `git show origin/dev-rules:tools/run-all-tests.sh | bash -s exp/<type>/<topic>`, then
   `gh run watch <id> --repo bearylabs/openwhispr --exit-status`. Only a green run for that SHA counts.
3. Land: one fork PR per clean commit.
   ```sh
   gh pr create --repo bearylabs/openwhispr --base <type>/<topic> --head exp/<type>/<topic> --title "<title>" --body "<body>"
   gh pr merge <n> --repo bearylabs/openwhispr --squash --subject "<title>" --body "<body>"
   ```
   Conventional Commit title. `--repo` is required (default is upstream), `--subject` too
   (otherwise GitHub appends the fork's `(#n)`).
4. Merge `origin/<type>/<topic>` back into `exp/` and push. Both trees must be equal.
5. Upstream PR (draft) from `<type>/<topic>`: what, why, link to the test run. Later landings update it.

Rebase a feature branch only when asked: disable ruleset 26306024
(`gh api -X PUT repos/bearylabs/openwhispr/rulesets/26306024 -f enforcement=disabled`),
`push --force-with-lease --no-verify`, re-enable (`enforcement=active`), merge into `exp/`.

## Quality

- Smallest change in upstream's style; no unrelated edits; nothing fork-specific in app branches.
- Behavior changes ship with tests. Change a test only for intended behavior. Never weaken the
  security audit or skip assertions; if `tools/headless-keyboard.patch` stops applying, fix it.
- Before the upstream PR, `git diff upstream/main...<type>/<topic>` contains only the topic.

## Ask first

Landing in a feature branch, opening or updating upstream PRs, rebasing, deleting branches,
changing GitHub settings. Pushing `exp/` needs no permission.

## State

| Feature branch | Upstream PR | Note |
|---|---|---|
| `feat/ios-keyboard-autocorrection` | #3039 | `backup/ios-autocorrection-history` tip (3 s backspace undo) may be missing |
| `fix/mobile-uri-decoder` | #3024 | |
| `feat/ios-minimal-voice-keyboard` | #3015 | contains headless adaptations; `feat/ios-minimal-keyboard` is the clean version |
