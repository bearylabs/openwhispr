# Current state (update when it changes)

| Feature branch | Upstream PR | Experimental branch |
|---|---|---|
| `feat/ios-keyboard-autocorrection` | #3039 | `exp/feat/ios-keyboard-autocorrection` |
| `fix/mobile-uri-decoder` | #3024 | create when needed |
| `feat/ios-minimal-voice-keyboard` | #3015 (draft; contains headless adaptations) | create when needed |
| `feat/ios-minimal-keyboard` | none; clean replacement for #3015 | create when needed |

- `backup/ios-autocorrection-history`: the original autocorrection development (11 commits).
  Its last commit (backspace undo limited to three seconds) may not be in #3039 yet.
- `backup/*`: recovery only, never a PR source. `pr-assets/*`: screenshots for PRs.
- `tests`: superseded by `dev-rules`, to be deleted.

Fork settings: ruleset `feature-branches-via-pr` (id 26306024) on `feat fix chore docs refactor
perf test ci build`/**: PR only, squash only, no force-push, no deletion. Repo: squash merge only,
branches are kept after merge. Linear history is deliberately not required: upstream `main`
contains merge commits, so no branch could be created from it.
