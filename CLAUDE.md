# CLAUDE.md — contextbuddy

Working agreements for agents in this repo. `~/.claude/CLAUDE.md` still applies;
this file adds the repo's gates, invariants and file pointers. Setup and product
docs live in [README.md](README.md); do not repeat them here. [SPEC.md](SPEC.md)
§4 (schemas), §5 (state machine) and §6 (rubric) are locked input.

## Map

| Path | What it is |
|---|---|
| `plugin/hooks/` | `user_prompt_submit.sh` (pre phase), `stop.sh` (post phase). Async (`hooks.json`); every error path logs to stderr and exits 0 (SPEC §13). |
| `plugin/lib/` | `config.sh` (TOML-lite reader), `dotenv.sh` (one var from `.env`, never sourced), `job.sh`, `session_paths.sh`, `transcript.sh`, `project_hash.sh`. |
| `plugin/grader/` | `invoke.sh` (backend dispatcher), `jev.mjs` (typesafe), `jev_shadow.py`, `system_prompt.md` (rubric, locked). |
| `plugin/.claude-plugin/plugin.json` | Plugin manifest. `.claude-plugin/marketplace.json` at the repo root is the marketplace that lists it. |
| `Sources/ContextBuddyCore/` | `Schemas.swift` (Grade, Config), `StateMachine.swift`, `Storage.swift`, `Watcher.swift`, `Core.swift` (engine; watches `last.json`). |
| `Sources/ContextBuddyApp/` | Menubar app. Makes no model calls; writes only `feedback.jsonl` and `state.db` (SPEC §15). |
| `Tests/plugin/` | Shell, Python and Node tests. No network, no key: `claude` is stubbed, `fetch` is injected. |
| `Tests/ContextBuddy*Tests/` | XCTest. |
| `~/.claude/inspector/` | Runtime data: `config.toml`, `sessions/<hash>/` (layout: README "File layout"). |

## Gates

- Local: `bash scripts/test_plugin.sh` (python unittest, `Tests/plugin/test_*.sh`,
  `node --test`, `shellcheck -S error`, `ruff`) and `swift test`. Report counts.
- CI: `.github/workflows/test.yml`, job `test`, is the required status check in
  the `main` ruleset (id 23660112, strict). Renaming the job breaks the gate;
  update the ruleset in the same change.
- Land with `gh pr merge <n> --squash --auto`. Strict policy: a PR behind `main`
  waits until `gh pr update-branch <n>`.
- CI compiles with the `macos-15` runner's Swift (6.1.2 on 2026-09-18); local is
  newer. Strict-concurrency and type-check-budget failures compile locally and
  fail the gate (#43, #46). For Swift changes, a local `swift test` is
  provisional until `test` is green.
- `ruff.toml` pins the rule set so the runner's ruff and the local one agree.
- Conventional commit prefixes (`feat:`, `fix:`, `docs:`, `test:`, `chore:`).

## Live hook run: required in every plugin PR

A PR that touches `plugin/hooks/`, `plugin/lib/` or `plugin/grader/` carries in
its body the output of one real hook run. The stubbed suite is not that
evidence: it checks the author's model of the hook payload and the model output,
not the real shapes, and CI has no key and no plugin install. On 2026-09-18,
#11, #12, #18, #28 and #29 passed CI and merged, and each had a defect one live
run would have shown (#25, #26, #27, #30).

Recipe. Measured 2026-09-19 with `backend = "typesafe"`: 8 s wall, of which
the reinstall was 1 s and the turn 7 s; the post grade was on disk when
`claude -p` returned.

```bash
# 1. Refresh the installed copy. `claude plugin update` is a no-op here (see Facts).
claude plugin uninstall contextbuddy@contextbuddy && claude plugin install contextbuddy@contextbuddy

# 2. One real turn from a project directory. Hooks load at session start, so a
#    session that is already running does not count; -p starts a fresh one.
cd /path/to/some/project
claude -p "Reply with the single word ok." --max-turns 1

# 3. Evidence: the turn files this run wrote, and the history line count.
S=~/.claude/inspector/sessions/$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12)
grep -E '^backend' ~/.claude/inspector/config.toml
for f in "$S"/turns/[0-9][0-9][0-9]-pre.json "$S"/turns/[0-9][0-9][0-9]-post.json; do
  [ -f "$f" ] || continue
  jq -r '"\(input_filename | split("/") | last)  turn \(.turn) \(.phase)  tokens \(.tokens_used)/\(.tokens_limit)  dominant_signal \(.dominant_signal)  confidence \(.scores.confidence.value)  atomicity \(.scores.atomicity.value)  drift \(.scores.drift.value)  pollution \(.scores.pollution.value)"' "$f"
done
printf 'history.jsonl: %s lines for %s grade files\n' \
  "$(wc -l < "$S/history.jsonl" | tr -d ' ')" \
  "$(ls "$S/turns" | grep -cE '^[0-9]{3}-(pre|post)\.json$')"
```

Paste the output into the PR body under a `## Live run` heading, with the wall
time, in this shape (the 2026-09-19 measurement, from a fresh session dir):

```
backend = "typesafe"
001-pre.json  turn 1 pre  tokens 0/200000  dominant_signal null  confidence 9  atomicity 10  drift 0  pollution 0
001-post.json  turn 1 post  tokens 53631/200000  dominant_signal null  confidence 9  atomicity 10  drift 0  pollution 0
history.jsonl: 2 lines for 2 grade files
wall 8 s (reinstall 1 s, turn 7 s)
```

The line count must equal the grade-file count. Readers take the last line of
`history.jsonl` (`plugin/lib/job.sh`, `plugin/lib/transcript.sh`), so one
multi-line record hides the prior grade (#26, #30;
`Tests/plugin/test_history_one_line.sh`). Anything the run surfaces that the PR
does not fix goes in the body as a follow-up issue, the way #25 did.

A branch that is not on the main checkout (the marketplace points at
`/Users/cory/contextbuddy`): skip step 1 and run step 2 from the worktree as
`claude --plugin-dir "$PWD/plugin" -p "Reply with the single word ok." --max-turns 1`.
Verified 2026-09-19 with a marker in the worktree copy: the worktree hooks ran,
the installed copy did not, one grade pair per turn. Note the flag in the PR
body.

## Facts every agent has rediscovered

**`claude plugin update` changes nothing.** The plugin is installed from a
directory marketplace (`claude plugin marketplace add /Users/cory/contextbuddy`,
then `claude plugin install contextbuddy@contextbuddy`) and cached under
`~/.claude/plugins/cache/contextbuddy/contextbuddy/<version>/`. `claude plugin
update contextbuddy@contextbuddy` compares versions only. `plugin/.claude-plugin/plugin.json`
has said `1.0.0` since its one edit (2c4d6b4, #10) and through every merge since,
so update reports "already at the latest version" and the cache keeps the old
hooks. `claude plugin marketplace update contextbuddy` refreshes the marketplace
listing, not the cache. Uninstall then install (step 1 above), or bump the
version in `plugin.json`.

**An unknown `config.toml` key discards the whole file.** `Config.parse`
(`Sources/ContextBuddyCore/Schemas.swift:416-418`; throw sites at `:433` and
`:456-494`) throws on any unknown section or key. `Config.load`
(`Schemas.swift:507`) catches and returns `Config.defaults`; the app calls it
from `reloadConfig` (`Core.swift:329`) and logs one line to stderr. Result: the
buddy runs on compiled-in defaults, thresholds included, and nothing in the UI
says so. The plugin side (`plugin/lib/config.sh`) tolerates unknown keys, so the
hooks keep grading and the mismatch stays silent. `~/.claude/inspector/config.toml`
may contain only the keys in README "Configuration". A new setting goes in the
environment or `.env` via `plugin/lib/dotenv.sh` (the route `TYPESAFE_API_KEY`
and `CONTEXTBUDDY_CLAUDE_CONFIG_DIR` use), or it is added to `Schemas.swift`,
`Tests/ContextBuddyCoreTests/Fixtures/config_default.toml` and the README block
in one PR.

## Invariants

- `history.jsonl` is one line per grade. Both hooks run the validated grade
  through `jq -c .` once; every write after that point stays compact.
- `turns/NNN-{pre,post}.json`, `last.json` and `history.jsonl` are written by
  the plugin only. The Jev shadow writes `NNN-pre.jev.json`, `jev.jsonl` and
  `jev.log`, nothing else.
- The anthropic grader child (`plugin/grader/invoke.sh`): `CONTEXTBUDDY_SKIP=1`,
  `ANTHROPIC_API_KEY` removed, `MAX_THINKING_TOKENS=0`, neutral cwd, real
  `HOME` (`Tests/plugin/test_invoke_config_dir.sh`). Change the thinking budget
  only with a fresh wall-clock measurement; the header comment has the numbers.
- Secrets: `TYPESAFE_API_KEY` and `CONTEXTBUDDY_CLAUDE_CONFIG_DIR` come from the
  environment or a `.env` that `plugin/lib/dotenv.sh` finds (project, worktree
  root, main checkout). Settings deny reading `.env`; check presence with
  `[ -f .env ]`. Never print a value, in a PR body or a log.
- Hooks never block the turn: async in `plugin/hooks/hooks.json`, `exit 0` on
  every error path, a grader that returns nothing is logged and skipped.
