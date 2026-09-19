# ContextBuddy — working notes for agents

A macOS menubar buddy that grades the quality of Claude Code prompts and turns.
Two halves that ship from this one repo and must stay in sync:

- **`Sources/`** — the Swift menubar app. `ContextBuddyCore` holds the logic
  (schemas, state machine, storage, file watcher, score meter);
  `ContextBuddyApp` holds the AppKit/SwiftUI surface (status item, popover).
- **`plugin/`** — the Claude Code plugin. `hooks/` fire inside the user's turn,
  `grader/` runs the actual grading (several backends), `lib/` is shared shell,
  `commands/` are the `/inspect*` slash commands.

The app never calls the grader. The plugin writes grade records to disk; the
app watches those files. That file contract is the whole integration.

## Read first

- **`SPEC.md`** is authoritative for behaviour — grade schema, state machine,
  file layout, release process. If code and SPEC disagree, that is a bug in one
  of them; decide which and fix it explicitly.
- `IMPLEMENTATION_PLAN.md` is the build-out plan and running status.
- `README.md` is the user-facing surface: install, config keys, backends.
- `CONTRIBUTING.md` has the full build/test/PR rules. This file is the short version.

## Commands

```bash
swift build                          # debug build
swift run ContextBuddy               # launch the menubar app
claude --plugin-dir ./plugin/        # load the plugin for one session

bash scripts/test_plugin.sh          # python + shell + node tests, shellcheck, ruff
swift test                           # ContextBuddyCoreTests + ContextBuddyAppTests
```

Run **both** suites before declaring work done — CI runs exactly these two, in
this order, and a red check blocks the merge.

## Invariants worth knowing before you change anything

- **`history.jsonl` is one JSON object per grade, per line, for every backend.**
  Several past fixes exist only to preserve this. `Tests/plugin/test_history_one_line.sh`
  guards it. Pretty-printed JSON from a backend must be compacted before it is
  appended.
- **Hooks run inside the user's turn.** Anything slow belongs in the background
  job (`plugin/lib/job.sh`), not in the hook. A hook that blocks is a hook that
  makes the product feel broken.
- **Tests never touch the network or a real `~/.claude`.** Grader tests inject
  their own transport; shell tests run under a throwaway `HOME`. Keep it that
  way — `scripts/test_plugin.sh` is expected to pass offline with no API keys.
- **Backends must behave identically at the seam.** `haiku`, `claude -p`, and
  `typesafe` (Jev) produce different payloads; everything downstream of the
  grader sees one normalized record.
- **`.env` is local-only.** `TYPESAFE_API_KEY` and friends are read from it and
  it is gitignored. Never read a secret from a committed default.

## Conventions

- Shell: passes `shellcheck -S error`. Python: `ruff check --line-length 120`.
- Swift 6 tools version, `.macOS(.v15)` minimum.
- Conventional Commits with a scope naming the half or subsystem:
  `feat(grader):`, `fix(hooks):`, `fix(ui):`, `docs:`.
- Every change lands through a PR against `main`. The required status check is
  the job named `test` in `.github/workflows/test.yml` — renaming that job
  breaks the merge gate and requires a matching ruleset change.

## Local layout gotchas

- `.claude/worktrees/` holds agent worktrees and can reach several GB. It and
  `.claude/plans/` are gitignored. Never `git add` them.
- `Package.resolved` is gitignored, so the CI build cache keys on
  `Package.swift` plus sources.

## When in doubt

Changing what a grade means, what gets written to disk, or the shape of a
record is a SPEC change. Update `SPEC.md` in the same PR, or ask before
proceeding — the app and the plugin are versioned together and a silent schema
drift breaks the watcher with no error.
