# OpenWhispr fork tests — read this in future sessions

This file exists **only on `fork-tests`**. The app lives on `main` or feature
branches. Never merge `fork-tests` into an app/PR branch and never open an upstream
PR from it. The test branch is infrastructure, not an app release.

Suggested request to an assistant:

> Read `fork-tests:fork-tests/README.md`, then run all mobile/native tests for my
> current committed app revision. Keep fork-only adaptations out of the app.

## Read without switching branches

```sh
git fetch origin fork-tests
git show origin/fork-tests:fork-tests/README.md
```

## Run everything (Linux machine, no local Mac needed)

Commit and push the **app** changes first. Never test uncommitted edits by claiming
a committed SHA covers them. In `/home/hrudek/dev/openwhispr`:

```sh
APP_SHA=$(git rev-parse main) # use your feature branch instead of main if appropriate
git push origin main       # likewise use the actual app branch
# Select the infrastructure branch explicitly; never merge it into the app.
gh workflow run fork-tests.yml --repo bearylabs/openwhispr --ref fork-tests -f source_ref="$APP_SHA"
gh run list --repo bearylabs/openwhispr --branch fork-tests --limit 5
gh run watch RUN_ID --repo bearylabs/openwhispr --exit-status
gh run view RUN_ID --repo bearylabs/openwhispr --log-failed
```

Actions must remain enabled in the fork. The original `mobile-ci.yml` workflow is
disabled **in the fork's GitHub settings only**, since its unadapted headless tests
would otherwise fail on app pushes. Its source file stays identical to upstream;
`fork-tests.yml` replaces it for fork development and runs the same mobile suites
plus the isolated adapter. Do not disable all repository Actions.

Actions must remain enabled in the fork. GitHub can require a one-time confirmation
on its Actions page; changing API permissions alone did not clear that fork gate.
A push to **fork-tests** also tests the then-current `main` automatically. App
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

The adapter's changes were removed from `main` by `2032c7534`; history was not
rewritten. Real sizing code and genuine regression coverage remain in app source.
To run the adapter on a Mac:

```sh
python3 /path/to/test-branch/fork-tests/run-keyboard-tests.py /path/to/app-checkout
```

## Upstream PR safety

**Never PR `fork-tests` or fork `main` directly.** Even though the app's net diff
has been cleaned, its history still contains yesterday's fork-only CI commits.
Export a new PR branch from the current upstream base instead:

```sh
git fetch upstream main
# Read/review or extract the helper from the test branch; no need to merge it:
git show origin/fork-tests:fork-tests/export-upstream.py > /tmp/openwhispr-export-upstream.py
python3 /tmp/openwhispr-export-upstream.py --source main
# After reviewing the printed file list and actual diff:
python3 /tmp/openwhispr-export-upstream.py --source main --create-branch pr/ios-keyboard-sizing
git diff upstream/main...pr/ios-keyboard-sizing --stat
git diff upstream/main...pr/ios-keyboard-sizing
```

The helper rejects test-branch files, the fork-only workflow and known headless
adaptations. It applies only the app's net patch onto `upstream/main` using a
**temporary index**, creates one local commit with upstream as its parent, and
never pushes, switches your checkout, overwrites a branch or rewrites history.
Conflicts or adapter markers fail closed. Review product scope too: the current
app diff contains the optional minimal keyboard, sizing fix and URI security fix;
split these into separate PRs if desired before exporting. This is a guard, not a
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

Keep the adapter and workflow on `fork-tests`. Do not merge app branches into it
just to test newer code: dispatch the new SHA. For maintenance, switch branches
only with a clean worktree, edit the test infrastructure and push `fork-tests`.
Infrastructure checks run with:

```sh
python3 -m unittest discover -s fork-tests/tests -v
python3 fork-tests/run-keyboard-tests.py . --check-only
```

Local branch cleanup on 2026-10-30 kept `main` and `fork-tests`. Old helper/backup
branches are recoverable from `.git/branch-cleanup-20261030.bundle`; no remote
branches were deleted.
