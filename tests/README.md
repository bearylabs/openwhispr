# OpenWhispr fork tests — read this in future sessions

This file exists **only on `tests`**. Never merge `tests` into an app/PR
branch and never open an upstream PR from it. This branch is infrastructure,
not an app release.

## Branch model (established 2026-10-30)

- `main`: exact mirror of the last fetched `upstream/main`, no personal commits.
- `feat/ios-minimal-keyboard`: clean upstream-based minimal keyboard feature,
  including initial self-sizing and explicit fitting-height fixes (two commits).
- `fix/mobile-uri-decoder`: independent URI security fix, based on upstream.
- `integration`: combines those two product branches for personal builds/tests.
  Never use it as an upstream PR source or merge it back into a feature branch.
- `tests`: personal workflows, headless adapter, guards and this documentation.
- `backup/main-before-upstream-sync-20261030`: preserved old main, including its
  old fork CI history. Recovery only; never use it as a PR source.

Create new topic branches from `upstream/main`, not `integration`. Merge topic
branches into `integration` when needed. Keep tests separate and dispatch an app
SHA. To refresh main: fetch upstream, switch to main with a clean worktree, run
`git merge --ff-only upstream/main`, then `git push origin main`. If it diverges,
inspect it rather than merging personal commits into main.

The existing draft PR #3015 still uses the OLD remote branch
`feat/ios-minimal-voice-keyboard`, which contains headless adaptations. It was
not rewritten during restructuring. Use `feat/ios-minimal-keyboard` for a clean
replacement or explicitly update the old PR branch after review. The old
`pr-assets/ios-minimal-voice-keyboard` branch is screenshot storage, not a PR source.

Suggested request to an assistant:

> Read `tests:tests/README.md`, then run all mobile/native tests for my
> current committed app revision. Keep fork-only adaptations out of the app.

## Read without switching branches

```sh
git fetch origin tests
git show origin/tests:tests/README.md
```

## Run everything (Linux machine, no local Mac needed)

Commit and push the **app** changes first. Never test uncommitted edits by claiming
a committed SHA covers them. In `/home/hrudek/dev/openwhispr`:

```sh
APP_SHA=$(git rev-parse integration) # or the exact feature branch to validate
git push origin integration         # push the same app branch
# Select the infrastructure branch explicitly; never merge it into the app.
WORKFLOW_ID=$(gh api repos/bearylabs/openwhispr/actions/workflows --paginate --jq '.workflows[] | select(.path == ".github/workflows/tests.yml") | .id')
gh workflow run "$WORKFLOW_ID" --repo bearylabs/openwhispr --ref tests -f source_ref="$APP_SHA"
gh run list --repo bearylabs/openwhispr --branch tests --limit 5
gh run watch RUN_ID --repo bearylabs/openwhispr --exit-status
gh run view RUN_ID --repo bearylabs/openwhispr --log-failed
```

Actions must remain enabled in the fork. The original `mobile-ci.yml` workflow is
disabled **in the fork's GitHub settings only**, since its unadapted headless tests
would otherwise fail on app pushes. Its source file stays identical to upstream;
`tests.yml` replaces it for fork development and runs the same mobile suites
plus the isolated adapter. Do not disable all repository Actions.

The numeric workflow ID is intentional: `gh workflow run tests.yml` tries to
look up that file on the default branch and returns 404, whereas dispatch by ID
with `--ref tests` works. Resolve the current ID with the command above.
Alternatively, extract/run `tests/run-all-tests.sh APP_BRANCH_OR_SHA`; it
resolves the workflow ID and verifies that the app commit is available on GitHub.

GitHub can require a one-time confirmation
on its Actions page; changing API permissions alone did not clear that fork gate.
A push to **tests** also tests the then-current `integration` automatically. App
pushes do **not** automatically invoke this branch's workflow: dispatch explicitly
with the command above. Do not confuse a green old run with validation of a new SHA.
The resolve job records one immutable app SHA for every job and the separate test
infrastructure SHA. All tests read app source from that SHA, not this branch's
possibly older app snapshot.

### Scope

- Mobile dependency integrity + advisory audit, `npm ci`, reviewed patch-package
  patches, and security regressions (Node 24).
- Formatting, ESLint, TypeScript, Expo doctor and dev/production configuration.
- Full mobile Jest suite and a production iOS JS bundle.
- All six native Mac suites: provider transport, keyboard return target, hardware
  hotkey logic, Live Activity resolver, keyboard layout/hit testing, capitalization.
- Adapter isolation and fail-closed checks.

This is the **mobile** test suite, not the unrelated Electron desktop suite. A JS
bundle is not an Xcode archive, signing test, or a real-device visual test.

## Headless isolation — important

`run-keyboard-tests.py` copies only the keyboard plugin into a temporary directory,
checks/applies `headless-keyboard.patch` there, and runs the original Swift harness
from that copy. The selected app checkout stays unchanged. The patch:

1. Gives the layout tests Full Access so the permissions overlay does not intercept
   their taps. It does not change the actual app's permissions behavior.
2. Checks target/action wiring and invokes the same tone handlers directly, because
   the headless Catalyst executable has no UIApplication event dispatch loop.
3. Compiles the exhaustive touch sweep with `-O`, as on the validated prior runner.

The small extracted tone-selection helper exists only in the patched temporary
copy. It must not be copied into app source just to accommodate this runner.
`git apply --check` is deliberate: if source changes invalidate the adapter, fix
and review the adapter **here**, never skip assertions to make a run green.

The adapter's changes were removed in the old app revision `2032c7534`.
The new feature branches preserve its clean product diff without the old fork CI
history. Real sizing code and genuine regression coverage remain in app source.
To run the adapter on a Mac:

```sh
python3 /path/to/test-branch/tests/run-keyboard-tests.py /path/to/app-checkout
```

## Upstream PR safety

A local pre-push guard is installed for this checkout. To install it on another
checkout, run `bash tests/install-guard.sh` from this branch. It refuses to
overwrite another hook manager. It blocks direct upstream pushes, requires fork
`main` to equal the fetched `upstream/main`, and checks all other app branches
(including `feat/*`) for known headless markers and fork infrastructure in their
net diff AND intermediate history. `tests`, `backup/*` and `pr-assets/*` are
explicitly exempt infrastructure/recovery/storage branches, never PR sources.
It reads the exporter from `origin/tests`, so fetch that ref first. This is local
enforcement, not a GitHub repository rule; `--no-verify`, another clone or the web
UI can bypass it. The guard cannot judge product scope or unknown adaptations.

Use the clean topic branches for upstream PRs. Inspect both diff and commits:

```sh
git log --oneline upstream/main..feat/ios-minimal-keyboard
git diff upstream/main...feat/ios-minimal-keyboard
```

For recovery from a mixed historical source ONLY, export a clean net diff:

```sh
git fetch upstream main
# Read/review or extract the helper from the test branch; no need to merge it:
git show origin/tests:tests/export-upstream.py > /tmp/openwhispr-export-upstream.py
python3 /tmp/openwhispr-export-upstream.py --source backup/main-before-upstream-sync-20261030
# After reviewing product scope (this backup includes keyboard AND URI fix):
python3 /tmp/openwhispr-export-upstream.py --source backup/main-before-upstream-sync-20261030 --create-branch pr/recovered-app
git diff upstream/main...pr/recovered-app --stat
git diff upstream/main...pr/recovered-app
```

The helper rejects test-branch files, the fork-only workflow and known headless
adaptations. It applies only the app's net patch onto `upstream/main` using a
**temporary index**, creates one local commit with upstream as its parent, and
never pushes, switches your checkout, overwrites a branch or rewrites history.
Conflicts or adapter markers fail closed. The clean branches already separate
the keyboard work from the URI security fix; do not export integration as one PR.
This is a guard, not a
server-side guarantee: a manually pushed branch/PR can bypass it. Always inspect
the final PR diff and commit list. Native/UI tests do not prove a PR is clean.

## Security audit vs test harness errors

Do not silence the advisory audit to make tests pass. `GHSA-qr28-fpjm-wq7f` affected
Expo Router's `decode-uri-component@0.2.2`. App commit `c1c152c72` backports the
single-pass 0.5.1 decoder while retaining its CommonJS/plus-sign contract. A scoped,
expiring audit exception is paired with patch-package and timeout-based regression
tests because npm audit does not recognize source patches. Review its expiry and
the existing node-forge/braces exceptions; do not extend them without review.
Always apply the checked-in patches before `npm run test:security`.

## Installable iPhone build (separate pipeline)

Read `/home/hrudek/dev/ios-builds/README.md` first. After tests are green:

```sh
gh workflow run build-ios.yml --repo bearylabs/ios-builds -f app=openwhispr -f source_ref="$APP_SHA" -f distribution=ad-hoc
```

Never build from the test branch. Check source SHA and successful signing before
installing. Encrypted artifacts and device install instructions live in ios-builds.
On an iPhone, cold-launch several apps, open the first text field and compare the
keyboard's toolbar/glass before and after switching keyboards. Test full/minimal
keyboards and portrait/landscape: Catalyst cannot verify iOS's system glass.

## Maintenance

Keep the adapter and workflow on `tests`. Do not merge app branches into it
just to test newer code: dispatch the new SHA. For maintenance, switch branches
only with a clean worktree, edit the test infrastructure and push `tests`.
Infrastructure checks run with:

```sh
python3 -m unittest discover -s tests/tests -v
python3 tests/run-keyboard-tests.py . --check-only
```

Before restructuring, old main and tests were additionally saved in
`.git/before-upstream-sync-20261030.bundle`. The remote backup branch preserves
old main as well. Earlier deleted helper branches remain recoverable from
`.git/branch-cleanup-20261030.bundle`; old remote branches were not deleted.
