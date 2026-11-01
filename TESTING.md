# Testing on GitHub runners

There is no local Mac. `.github/workflows/tests.yml` on this branch tests any pushed app
revision on Ubuntu and macOS runners. It only runs when dispatched manually.

## Run

Commit and push the app branch first, then dispatch for its SHA:

```sh
BRANCH=feat/my-topic
git push origin "$BRANCH"
git show origin/dev-rules:tools/run-all-tests.sh | bash -s "$BRANCH"
gh run list --repo bearylabs/openwhispr --workflow tests.yml --limit 3
gh run watch RUN_ID --repo bearylabs/openwhispr --exit-status
gh run view RUN_ID --repo bearylabs/openwhispr --log-failed
```

Check that the run summary shows the SHA you meant; an older green run proves nothing.

## What it covers

Mobile app only (`openwhispr-mobile/`): dependency integrity and blocking security audit,
lint/format/types/Expo config, all Jest tests, production iOS bundle, and all native Mac
suites. The desktop (Electron) tests are not covered: run `npm test` locally.
A JS bundle is no Xcode archive, signing or real-device test.

## Rules for the workflow

- The security audit is its own blocking job. Never add `continue-on-error`, allowlists or
  `||` to make it pass.
- The keyboard harness needs a headless adapter (`tools/headless-keyboard.patch`). It is applied
  to a temporary copy only, never to app source. If it stops applying, fix the patch here,
  never drop assertions.
- Infrastructure self-tests: `KEYBOARD_APP_SOURCE=<app checkout> python3 -m unittest discover -s tools/tests -v`.
- Upstream's own workflows are disabled in the fork's Actions settings; keep them disabled
  and their files identical to upstream.

## Installable iPhone build

Separate repo, after tests are green: see `/home/hrudek/dev/ios-builds/README.md`.

```sh
gh workflow run build-ios.yml --repo bearylabs/ios-builds -f app=openwhispr -f source_ref="$SHA" -f distribution=ad-hoc
```
