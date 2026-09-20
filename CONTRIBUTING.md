# Contributing to ContextBuddy

ContextBuddy is two halves that ship together: a Swift menubar app
(`Sources/`) and a Claude Code plugin (`plugin/`) whose hooks grade prompts
and write results the app watches. A change to one usually implies a change to
the other, so read [SPEC.md](SPEC.md) before touching the grade pipeline — it
is the authoritative description of the contract between the halves.

## Requirements

- macOS 15 or newer (`Package.swift` pins `.macOS(.v15)`)
- Swift 6 toolchain (`swift-tools-version:6.0`)
- `jq`, `shellcheck`, `ruff`, `python3`, and `node` for the plugin test suite:
  `brew install shellcheck ruff jq node`

## Build and run

```bash
swift build                          # debug build
swift run ContextBuddy               # launch the menubar app
claude --plugin-dir ./plugin/        # load the plugin for one session
```

## Tests

Run both suites before opening a PR. These are the same two commands CI runs,
in the same order:

```bash
bash scripts/test_plugin.sh   # python unittest, shell hook tests, node grader, shellcheck, ruff
swift test                    # ContextBuddyCoreTests + ContextBuddyAppTests
```

`scripts/test_plugin.sh` needs no network and no API keys — every grader test
injects its own `fetch`/transport. Keep it that way: a test that reaches the
network or reads a real `~/.claude` will fail for everyone else.

### Linting

`scripts/test_plugin.sh` runs the linters, so there is nothing separate to
invoke, but it is worth knowing what they enforce:

- `shellcheck -S error` over `plugin/hooks/*.sh`, `plugin/lib/*.sh`,
  `plugin/grader/*.sh`, `plugin/statusline.sh`, `scripts/*.sh`, and
  `Tests/plugin/*.sh`. Severity is capped at `error` because default severity
  still flags pre-existing SC2010/SC2034 in `stop.sh`, `session_paths.sh`, and
  `statusline.sh` — if you touch those files, fixing the warning is welcome but
  not required.
- `ruff check --line-length 120` over `plugin/grader/jev_shadow.py` and
  `Tests/plugin/*.py`.

## Pull requests

`main` is protected by a required status check named `test`
(`.github/workflows/test.yml`). Every change lands through a PR.

1. Branch from an up-to-date `main`.
2. Keep the change focused. A PR that fixes a hook bug and restyles the
   popover is two PRs.
3. Write a test that fails before your change and passes after it, whenever the
   change is observable.
4. Update `SPEC.md` in the same PR if you changed behaviour it describes, and
   `README.md` if you changed something a user types or sees.
5. Open the PR and let CI run. A red `test` check blocks the merge.

### Commit messages

The history uses Conventional Commits with a scope naming the half or the
subsystem you touched:

```
feat(grader): typesafe (Jev) backend
fix(hooks): compact the grade once after validation
docs: add CI status badge to README
```

Common scopes: `app`, `ui`, `popover`, `grader`, `hooks`, `plugin`, `spec`.

### If you rename the CI job

The job id and the job name in `.github/workflows/test.yml` are both `test`,
and `test` is the required status check in the `main` ruleset. Renaming either
one silently breaks the merge gate — update the ruleset's
`required_status_checks` context in the same change.

## Things that will get a PR sent back

- **Real prompt text in fixtures.** Test fixtures under `Tests/plugin/fixtures`
  and `Tests/ContextBuddyCoreTests/Fixtures` must be synthetic. Never paste a
  transcript from a session you actually ran.
- **Secrets.** `.env` and `.env.*` are gitignored. API keys belong there or in
  the environment, never in a committed file, a test, or a default.
- **Slow hooks.** `plugin/hooks/*` run inside the user's Claude Code turn. Work
  that can be deferred to the background job belongs in the background job.
- **A grade line that is not one line.** `history.jsonl` is one JSON object per
  grade per line, for every backend. Several past fixes exist only to preserve
  that; there are tests guarding it (`Tests/plugin/test_history_one_line.sh`).

## Local worktrees

If you use `git worktree` for parallel agent work, put the trees under
`.claude/worktrees/` — `.gitignore` already excludes that path and
`.claude/plans/`. They can grow to gigabytes; do not let them into a commit.
