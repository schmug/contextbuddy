# ContextBuddy

[![test](https://github.com/schmug/contextbuddy/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/schmug/contextbuddy/actions/workflows/test.yml)

> A peripheral macOS menubar buddy that grades the quality of your Claude Code prompts and turns — so you can become a better prompt-writer over time.

ContextBuddy has two halves:

1. **A Claude Code plugin** that grades each `UserPromptSubmit` and `Stop` event against a `session.md` anchor you author, using Haiku 4.5. Results are written as JSON files under `~/.claude/inspector/sessions/<project-hash>/`.
2. **A macOS menubar app** (Swift, SwiftUI, FSEvents) that watches those files and renders one of seven states via a small SF Symbol icon: `sleep`, `idle`, `busy`, `attention`, `celebrate`, `dizzy`, `heart`. Click for a popover with scores and a one-line rationale.

The two halves communicate **only through the file system**. Either runs without the other.

---

## Install

### Build and install the menubar app

```bash
git clone https://github.com/<you>/contextbuddy.git
cd contextbuddy
swift build -c release
open .build/release/ContextBuddy &
```

For a notarized release build with a hardened runtime + DMG, use `scripts/release.sh` (requires a Developer ID).

### Install the Claude Code plugin

For local development (loads the plugin only for the session you launch):

```bash
claude --plugin-dir ./plugin/
```

For a persistent install (the desktop app has no `--plugin-dir`), add this repo as a marketplace (`.claude-plugin/marketplace.json` at the repo root lists the plugin at `./plugin`) and install from it:

```bash
claude plugin marketplace add /path/to/contextbuddy   # or: schmug/contextbuddy
claude plugin install contextbuddy@contextbuddy
```

A local path lets you iterate without pushing; `claude plugin marketplace update contextbuddy` picks up new commits either way. The installed copy is cached by the version in `plugin/.claude-plugin/plugin.json`, so after new commits reinstall it (`claude plugin uninstall contextbuddy@contextbuddy && claude plugin install contextbuddy@contextbuddy`); `claude plugin update` reports up to date and changes nothing.

Working on the plugin or the app? [CLAUDE.md](CLAUDE.md) holds the repo's working agreements for agents, including the live hook run every plugin PR must show.

To verify the plugin manifest:

```bash
claude plugin validate ./plugin
```

**Status line**: ContextBuddy ships a `plugin/statusline.sh` that prints the current grade compactly. The Claude Code plugin schema does not yet have a status-line declaration; wire it up manually by adding the script path to `~/.claude/settings.json` under `statusLine` if you want it.

### Bootstrap your first session anchor

In any project:

```
/inspect init
```

This drops a starter `session.md` at `~/.claude/inspector/sessions/<project-hash>/session.md`. Edit it to describe your goal, acceptance criteria, and scope. The grader uses this as ground truth for `confidence` and `drift` scoring.

### Pick a grader backend

The grader runs once per turn and needs a model. You have four options — see [Backends](#backends) below for the full picture:

- **Anthropic Haiku 4.5** (default): runs `claude -p` on a second Claude account; point `CONTEXTBUDDY_CLAUDE_CONFIG_DIR` (env or `.env`) at that account's config dir. Billed to that account; quality floor.
- **Local via Ollama**: install Ollama, pull a model, edit `config.toml`. No API key, no per-grade cost.
- **OpenAI-compatible local server** (LM Studio, llama.cpp, vLLM, …): edit `config.toml`. No API key required for unauthenticated local servers.
- **TypeSafe Jev** (System One): set `TYPESAFE_API_KEY`, set `backend = "typesafe"`. One ~0.4 s request per turn, typed probabilities instead of generated JSON, about $0.0002 per turn.

---

## How it grades

Four dimensions, each scored 0-10. Definitions are locked — see `plugin/grader/system_prompt.md` for the full rubric prose.

| Dimension | Question |
|---|---|
| **Confidence** | how clear is the prompt itself? |
| **Atomicity** | is it one thing? |
| **Drift** | are we still doing what we said? |
| **Pollution** | how much of the context is dead weight? |

Confidence and atomicity are "high is good" (≥7 = green). Drift and pollution are inverted: "low is good" (≤3 = green).

**Jev shadow grader (Request A).** If `TYPESAFE_API_KEY` is in the environment Claude Code inherits, or in a `.env` in the project directory, every UserPromptSubmit also sends a small state (the session's first prompt, the last three prompts, and the prompt being submitted; no tool output) to TypeSafe's `jev-1.13.0` and asks for `specificity`, `atomicity`, and `drift` as Score questions over the same rubric rows, plus an `intent` Choice. The answer is logged to `turns/NNN-pre.jev.json` and `jev.jsonl` beside the Haiku grade, with the full probability distribution, confidence, argmax level, latency, and the Haiku scores for the same turn. It runs detached, never slows the prompt, and drives nothing: the buddy reads only `last.json`. Missing key or a failed call means no row and a line in `jev.log`. Cost is under $0.001 per turn at published pricing. Details: `plugin/grader/jev_shadow.py`.

The buddy aggregates these into seven states. Default thresholds (in `~/.claude/inspector/config.toml`):

| State | Trigger |
|---|---|
| `sleep` | No grade events in >5 min |
| `idle` | Active session, nothing flagged |
| `busy` | UserPromptSubmit fired without a matching Stop yet |
| `attention` | `confidence<4` or `atomicity<4` or `drift>6` or `pollution>7` |
| `celebrate` | 5 consecutive grades all-green |
| `dizzy` | 3 edits to the same file in 3 consecutive turns OR `tokens_used/tokens_limit > 85%` (`tokens_limit` is the session model's window, see [Context window](#context-window)) |
| `heart` | You acked a suggestion |

---

## Worked examples

The three canonical examples below are reproduced verbatim from the spec.

### Example 1 — Attention (atomicity bundling)

**Session anchor (`session.md`)**:
```yaml
goal: Refactor auth module to use JWT instead of session cookies
acceptance:
  - Existing routes accept JWT in Authorization header
  - Session cookie code paths removed
  - All auth tests pass
in_scope: [src/auth/, src/middleware/auth.ts, tests/auth/]
out_of_scope: [src/users/, frontend/, deployment configs]
constraints:
  - Use jose library, not jsonwebtoken
  - Refresh tokens out of v1 scope
created_at: 2026-04-29T09:14:00Z
```

**User prompt (turn 14)**:
> "fix the auth bug where the JWT validation is failing on expired tokens, and also refactor that whole token validation function while you're in there, and add a test for the new behavior"

**Grade JSON (`turns/014-pre.json`)**:
```json
{
  "schema_version": 1,
  "phase": "pre",
  "turn": 14,
  "timestamp": "2026-04-29T11:42:18Z",
  "scores": {
    "confidence": {"value": 6, "rationale": "Goal clear (fix expired-token bug) but acceptance criteria absent for the refactor"},
    "atomicity": {"value": 3, "rationale": "Bundles bug fix + opportunistic refactor + test addition in one prompt"},
    "drift": {"value": 2, "rationale": "Aligned with auth refactor goal; in-scope file"},
    "pollution": {"value": 4, "rationale": "(carried from turn 13) Three superseded plans from turns 8-11 still present"}
  },
  "tokens_used": 47823,
  "tokens_limit": 200000,
  "dominant_signal": "atomicity",
  "summary_update": "User refactoring auth to JWT. Through turn 13, validation logic and middleware updated. Turn 14 expands scope to bundled bug fix + refactor + test."
}
```

**Buddy state**: `idle` → `attention` (atomicity 3 < 4 threshold). Orange triangle in menubar.

**Popover**:
```
🟡 attention
─────────────
conf:6  atom:3  drift:2  pol:4

Atomicity: prompt bundles bug fix +
opportunistic refactor + test addition.
Try splitting into three prompts.

[Ack]  [Mute "atomicity"]  [Open inspector]
```

**Suggestion log entry** (`suggestions.md`):
```markdown
## Turn 14 — 2026-04-29 11:42 — atomicity (3/10)

**Prompt**: "fix the auth bug where the JWT validation is failing on expired tokens, and also refactor that whole token validation function while you're in there, and add a test for the new behavior"

**Issue**: Bundles bug fix + opportunistic refactor + test addition in one prompt.

**Suggested rewrite (atomic split)**:
1. "Fix the JWT validation bug — expired tokens are not being rejected. Acceptance: validation returns 401 for tokens past `exp`."
2. "Refactor the token validation function for clarity. Behavior must be unchanged. Acceptance: all existing tests pass."
3. "Add a test for the expired-token rejection case."

Status: open
```

### Example 2 — Celebrate (sustained quality)

Turns 18-22 all produced post-Stop grades with all four scores in the green zone (confidence/atomicity ≥ 7, drift/pollution ≤ 3). Turn 22 is the fifth such grade.

**Grade JSON (`turns/022-post.json`)**:
```json
{
  "schema_version": 1,
  "phase": "post",
  "turn": 22,
  "timestamp": "2026-04-29T12:31:04Z",
  "scores": {
    "confidence": {"value": 8, "rationale": "Prompt specified acceptance and constraint; agent followed precisely"},
    "atomicity": {"value": 9, "rationale": "Single action: rename and relocate utility function with no other changes"},
    "drift": {"value": 1, "rationale": "Tightly aligned with anchor; in-scope file"},
    "pollution": {"value": 3, "rationale": "Some accumulated tool results from turn 19 file read"}
  },
  "tokens_used": 58104,
  "tokens_limit": 200000,
  "dominant_signal": null,
  "summary_update": "Turns 18-22: clean refactor sequence, atomic prompts, no scope drift. JWT validation now passes existing tests."
}
```

**Buddy state**: `idle` → `celebrate`. The `sparkles` icon bounces for ~2.5 sec, then settles back to `idle`.

### Example 3 — Dizzy (loop detection)

Turns 27, 28, 29 all included edits to `src/auth/jwt.ts`. Three consecutive edits to the same file triggers loop detection.

**Grade JSON (`turns/029-post.json`)**:
```json
{
  "schema_version": 1,
  "phase": "post",
  "turn": 29,
  "timestamp": "2026-04-29T13:08:51Z",
  "scores": {
    "confidence": {"value": 7, "rationale": "Prompt clear; agent attempting test-driven fix iteration"},
    "atomicity": {"value": 9, "rationale": "One action with a clear boundary: fix the failing expired-token test in tests/auth/jwt.test.ts"},
    "drift": {"value": 2, "rationale": "Still aligned with auth refactor goal"},
    "pollution": {"value": 5, "rationale": "Three iterations of jwt.ts read + edit cycle accumulated"}
  },
  "tokens_used": 71402,
  "tokens_limit": 200000,
  "dominant_signal": "loop",
  "summary_update": "Turns 27-29 all editing src/auth/jwt.ts in fix-test-fix cycle. Test still failing. Possible loop."
}
```

No individual *score* crossed an attention threshold. Dizzy is triggered by behavioral pattern detection, not score thresholds. The plugin sets `dominant_signal: "loop"` mechanically (not the grader).

**Buddy state**: `idle` → `dizzy`. Wiggling icon (or pulsing on macOS 14, where SF Symbols' `.wiggle` isn't available).

---

## Configuration

`~/.claude/inspector/config.toml` — edited directly. v1 has no preferences UI.

```toml
[thresholds]
confidence_attention = 4    # confidence < this triggers attention
atomicity_attention = 4
drift_attention = 6         # drift > this triggers attention
pollution_attention = 7
celebrate_consecutive_n = 5
loop_edits_in_window = 3    # N edits to same file in N consecutive turns
loop_window_turns = 3
context_pressure_pct = 85   # tokens_used/tokens_limit > this triggers dizzy (limit: see Context window)

[grader]
backend = "anthropic"       # "anthropic" | "ollama" | "openai_compatible"
model = "claude-haiku-4-5-20251001"
sliding_window_turns = 3
inspect_model = "claude-sonnet-4-6"

[grader.ollama]             # used when backend = "ollama"
endpoint = "http://localhost:11434"

[grader.openai_compatible]  # used when backend = "openai_compatible"
endpoint = "http://localhost:1234/v1"
api_key_env = ""            # name of an env var holding a bearer token; "" = no auth

[ui]
animations_enabled = true
token_row_pct = 70          # show ⚡ row when usage > this percent
```

Both the buddy and the plugin read this on each grade event. Hot-reload is automatic.

### Context window

`tokens_limit` is resolved per grade from the session's actual model, not hardcoded. Hook payloads carry no model, so the plugin reads `message.model` from the last assistant record of the session transcript (`<synthetic>` placeholder records are skipped). Resolution order, first hit wins; the grade records the winner in `limit_source`:

1. `override` — `CONTEXTBUDDY_CONTEXT_WINDOW` in the environment or a `.env` in the project (same lookup as `CONTEXTBUDDY_CLAUDE_CONFIG_DIR`). Accepts `300000`, `300k`, `1m`. Not a `config.toml` key: the app's parser drops the whole file on an unknown key.
2. `autocompact` — Claude Code's auto-compact window: `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, else `autoCompactWindow` in `~/.claude/settings.json` (respects `CLAUDE_CONFIG_DIR`), as written by `/autocompact 500k`. Pressure is measured against the ceiling you will actually hit.
3. `model` — prefix table in `plugin/lib/context_windows.json`: 1M for `claude-fable-*`, `claude-mythos-*`, `claude-sonnet-5*`, `claude-opus-5*`, `claude-opus-4-8*`, `claude-opus-4-7*`; 200K for Haiku, Sonnet 4.6 / 4.5, Opus 4.6 / 4.5 and any unknown id. `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` caps the 1M rows at 200K. `[1m]` variants of Sonnet 4.6 / Opus 4.6 are not detected; they resolve to 200K and rely on step 5.
4. `default` — no transcript or no model: 200K.
5. `observed` — evidence floor: if `tokens_used` exceeds the limit from steps 1-4, the assumption is provably wrong and the limit is raised to the next tier (200K → 1M). No grade is ever written with `tokens_used > tokens_limit`.

Every grade also carries `model` (the session's Claude model id, or `null`). The status line and popover print a 1M window as `1M` (`⚡176k/1M`). The same resolver runs in the hooks (all four backends get the same limit), in the typesafe grader and in the Jev shadow grader.

---

## Backends

The grader system prompt is model-agnostic — it specifies inputs and a strict JSON output schema. Any model capable of following that schema can grade.

### `anthropic` (default)

Uses `claude -p` to invoke Haiku 4.5 (or any Claude model you set via `[grader].model`) as a **second Claude account**: `CONTEXTBUDDY_CLAUDE_CONFIG_DIR` (environment, or a `.env` in the project) points at a Claude config directory signed in as the grader account, and the child runs with `CLAUDE_CONFIG_DIR` set to it, `ANTHROPIC_API_KEY` scrubbed, tools and MCP off, and extended thinking off (`MAX_THINKING_TOKENS=0`, about 6 s per grade). Subprocess hooks cannot reach the session's own keychain credential, which is why a separate config dir is required. Missing or invalid dir: the grade is skipped (exit 5) and logged.

```toml
[grader]
backend = "anthropic"
model = "claude-haiku-4-5-20251001"
```

```bash
# once: sign in the grader account into its own config dir
CLAUDE_CONFIG_DIR=~/.claude-grader claude login
# then, in the environment Claude Code inherits or in the project's .env
export CONTEXTBUDDY_CLAUDE_CONFIG_DIR=~/.claude-grader
```

### `ollama`

Runs grading entirely locally via [Ollama](https://ollama.com). No API key, no per-grade cost, works offline.

```bash
brew install ollama
ollama serve &
ollama pull qwen2.5:14b-instruct
```

```toml
[grader]
backend = "ollama"
model = "qwen2.5:14b-instruct"

[grader.ollama]
endpoint = "http://localhost:11434"
```

The plugin sends `format: "json"` so Ollama constrains the model to schema-conformant output.

### `openai_compatible`

For LM Studio, llama.cpp's `--server`, vLLM, or any hosted OpenAI-compatible gateway.

```toml
[grader]
backend = "openai_compatible"
model = "your-model-id"

[grader.openai_compatible]
endpoint = "http://localhost:1234/v1"
api_key_env = ""            # set to e.g. "OPENROUTER_API_KEY" for hosted gateways
```

The plugin sends `response_format: {type: "json_object"}` for schema conformance.

### `typesafe`

Grades with [TypeSafe's](https://docs.typesafe.ai) Jev, a System One model: it returns typed answers and calibrated probabilities rather than generated text, so there is no JSON to parse or repair and a turn grades in about 0.4 s. The grader is `plugin/grader/jev.mjs` (Node 20+, no dependencies).

```toml
[grader]
backend = "typesafe"
model = "jev-1.13.0"
```

```bash
export TYPESAFE_API_KEY=...        # in the environment Claude Code inherits,
                                   # or a TYPESAFE_API_KEY= line in a .env in the
                                   # project, worktree root, or main checkout
                                   # (plugin/lib/dotenv.sh; the desktop app's hooks
                                   # see no shell exports, so .env is the route there)
# optional: export TYPESAFE_BASE_URL=https://api.typesafe.ai
# optional: export CONTEXTBUDDY_NODE=/path/to/node   # if node is not on the hook's PATH
```

No other `config.toml` keys: the menubar app's config parser rejects unknown keys and then ignores the whole file, thresholds included, so the backend is configured through the environment.

How it differs from the LLM backends:

- **Questions, not a prompt.** Each rubric dimension is a Score question whose levels are the §6 rubric rows rewritten as standalone situations; intent is a Choice; correction, destructive-operation and guard-bypass are yes/no questions. `scripts/jev-probe.mjs` runs the shipped question set against the README worked examples and your own recent prompts so you can see the numbers before trusting them.
- **Rationales are the winning level's text.** Jev writes no prose. `summary_update` is a factual one-liner (intent, correction, harm probabilities) assembled in code.
- **Pollution is counted, not judged.** Re-reads of one file, reads made stale by a later edit, and tool results over 8k characters, from the transcript. Jev does not count reliably, so nothing about context size is asked of it.
- **Not a prompt, no grade.** An `is_task` question gates the turn: pasted logs, tool output and documents skip grading instead of producing an "attention" the buddy would render.
- **Extra `signals` field.** Each grade carries a top-level `signals` object (intent distribution, correction, destructive, bypass, severity, threshold probability masses). The app ignores it today; it is there for the next iteration.

What leaves the machine: the session anchor, the first prompt, the last three typed prompts, the current prompt and the last assistant reply, each cut to 2,000 characters. Never tool output, never file contents. Metered: Jev is priced per input token (about 2k tokens a turn at $0.042 per million); output is free. The `anthropic`, `ollama` and `openai_compatible` backends now transmit the same last N typed prompts (N = `sliding_window_turns`, default 3) in their input bundle; earlier releases sent them an empty window.

### Recommended local models

| Model | Notes |
|---|---|
| `qwen2.5:14b-instruct` | Practical floor for the rubric. ~9 GB, runs on Apple Silicon with ≥16 GB RAM. |
| `llama3.3:70b` | Better atomicity scoring; needs ~40 GB RAM or quantized variant. |
| Smaller models (≤7B) | Will score the **atomicity** dimension noisily — bundles, side-quests, and acceptance gaps get conflated. A noisy attention signal trains you to mute the buddy, which defeats the point. Avoid for production grading; fine for smoke-testing the loop. |

Different backends produce different score distributions; don't mix-and-match within a session if you care about consecutive-N celebrate streaks.

---

## File layout

```
~/.claude/inspector/
├── config.toml
└── sessions/
    └── <project-hash>/         # sha256(canonical_project_path)[:12]
        ├── session.md          # YAML frontmatter; you author this
        ├── last.json           # most recent grade
        ├── history.jsonl       # append-only grade log
        ├── suggestions.md      # append-only attention/dizzy log
        ├── feedback.jsonl      # append-only ack/mute log (buddy writes)
        ├── edits.jsonl         # last 3 turns × edited files
        ├── inspect_NNN.md      # /inspect deep-dive output
        └── turns/
            ├── NNN-pre.json
            └── NNN-post.json

~/Library/Application Support/ContextBuddy/
└── state.db                    # buddy's SQLite (transitions + feedback)
```

`<project-hash>` is computed from the project path with symlinks resolved (`realpath`), so `/tmp/foo` and `/private/tmp/foo` share one session directory. Before this, the two forms hashed differently and a session could split across two directories mid-conversation.

**Migration note:** sessions created under a symlinked path before this change (anything under `/tmp` or `/var`, a symlinked Homebrew prefix, a mounted dev volume) were hashed from the unresolved string, and the plugin and the app now read the canonical hash directory instead. Nothing is migrated automatically. To keep an old session, copy its files into the canonical directory (or rename the directory if the canonical one does not exist yet); `source plugin/lib/project_hash.sh && project_hash "$PWD"` prints the new name from inside the project. Leaving the old directory in place is harmless.

---

## What the buddy will NOT do

By design (§9.6 / §15):

- No notifications via `UNUserNotificationCenter`. The icon IS the notification.
- No sound output.
- No focus stealing.
- No Dock icon (`LSUIElement = true`).
- No telemetry.
- No automatic API calls from the Swift app — all model calls happen in the plugin (bash).

---

## Slash commands

| Command | Effect |
|---|---|
| `/inspect init` | Bootstrap `session.md` (uses `CLAUDE.md` as a draft if present). |
| `/inspect` | Sonnet 4.6 deep-dive grade. Writes `inspect_<turn>.md`. |
| `/inspect history` | Compact timeline of grades from `history.jsonl`. |
| `/inspect diff <turn1> <turn2>` | Diff two grade JSONs side-by-side. |

---

## Tests

```bash
swift test                    # core (Schemas, StateMachine, Storage, Watcher, …)
bash scripts/test_plugin.sh   # plugin shell layer (grader dispatcher, hook job builder, context window resolver, hooks) + node grader tests
node --test Tests/plugin/test_jev_grader.mjs   # typesafe grader alone (no network; fetch is injected)
```

---

## License

[MIT](LICENSE).
