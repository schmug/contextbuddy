# ContextBuddy — Specification (v1)

> **For the implementer**: this document is authoritative. Read it end-to-end before producing the implementation plan. Do not modify the rubric in §6, the JSON schemas in §4, or the state machine in §5 — these are fixed input. The grader prompt's rubric prose is locked; you will author the wrapper around it (§7). Produce `IMPLEMENTATION_PLAN.md` and stop. Wait for review before writing any code.

---

## 1. Product Description

ContextBuddy is a developer tool that grades the quality of prompts and context state during Claude Code sessions and surfaces the result through an ambient macOS menubar buddy. Its purpose is to make the developer a better prompt-writer over time — not to gate or control the agent.

The buddy is **peripheral and quiet by default**. It earns its place by being glanceable, not by demanding attention. The menubar icon reflects current state via a small set of SF Symbols; a popover on click shows scores and a one-line rationale. Animation is reserved for transitions the user should notice (attention, celebrate, dizzy, heart). Routine transitions (idle ↔ busy) are silent and instantaneous.

The product has two halves:

1. **The plugin** (`plugin/`) — a Claude Code plugin with hooks (`UserPromptSubmit`, `Stop`), a status line script, and slash commands (`/inspect`, `/inspect init`, `/inspect history`, `/inspect diff`). The plugin invokes Haiku 4.5 to grade prompts and turns against a session anchor file the user authors (`session.md`), and writes results as JSON files under `~/.claude/inspector/sessions/<project-hash>/`.

2. **The buddy** (`Sources/ContextBuddyApp/` + `Sources/ContextBuddyCore/`) — a single Swift menubar app that watches the inspector files via FSEvents, renders state changes through a small set of SF Symbol glyphs, and provides ack/mute interactions that feed back into the plugin via `feedback.jsonl` and a local SQLite store.

The two halves communicate exclusively through the file system. The plugin owns writes to grade files and history; the buddy owns writes to feedback and state.db. Neither component has direct knowledge of the other's internals — this enables future sinks (BLE hardware, ntfy, web dashboards) to be added without redesigning either side.

---

## 2. Architecture

```
┌────────────────────────────┐
│       Claude Code           │
│    (CLI, plugin host)       │
└──────────────┬──────────────┘
               │  hooks fire on
               │  UserPromptSubmit, Stop
               ▼
┌────────────────────────────┐
│    Plugin scripts (bash)    │
│  hooks/, commands/,         │
│  statusline.sh              │
│                             │
│  Calls Anthropic API        │
│  (Haiku for grade,          │
│   Sonnet for /inspect)      │
└──────────────┬──────────────┘
               │  writes
               ▼
┌────────────────────────────┐
│  ~/.claude/inspector/       │
│  sessions/<project-hash>/   │
│    meta.json                │
│    session.md               │
│    last.json                │
│    history.jsonl            │
│    suggestions.md           │
│    turns/NNN-pre.json       │
│    turns/NNN-post.json      │
│    feedback.jsonl  ◄──────┐ │
└──────────────┬────────────┼─┘
               │ FSEvents   │ writes
               ▼            │
┌────────────────────────────┐
│   ContextBuddy.app          │
│                             │
│  ContextBuddyCore (actor)   │
│   - FSEvents watcher        │
│   - JSON parsing            │
│   - State machine           │
│   - SQLite (state.db)       │
│                             │
│  ContextBuddyApp (SwiftUI)  │
│   - NSStatusItem button     │
│   - Popover                 │
│   - SF Symbol rendering     │
└────────────────────────────┘
```

**Process model**: a single Swift process. Internally, `ContextBuddyCore` is an actor exposing `subscribe() -> AsyncStream<BuddyState>` and `recordFeedback(...)` methods. `ContextBuddyApp` is a thin SwiftUI client that subscribes and renders. This separation makes the watcher extractable into a CLI daemon later if hardware sinks are revisited.

**Discovery and multi-project**: the buddy watches `~/.claude/inspector/sessions/` at the directory level via FSEvents. The plugin writes to `sessions/<project-hash>/`, where `<project-hash>` is `sha256(canonical_project_path)[:12]` — the absolute path with symlinks resolved (realpath(3)), so `/tmp/x` and `/private/tmp/x` are one project (issue #4). The buddy reflects the most-recently-updated session by default; the right-click menu lists recently-active sessions for explicit pinning.

**Sandboxing**: do not sandbox in v1. Notarize-only distribution. `LSUIElement = true` (no Dock icon).

**Bundle identifier**: `com.donthype.contextbuddy`.

**Minimum macOS**: 14.0 (Sonoma). Rely on animated SF Symbols (`.symbolEffect`) and modern `NSStatusItem` button-style API. Do not write fallbacks for older macOS.

---

## 3. Repository Structure

```
contextbuddy/
├── Package.swift                       # SPM, no Xcode project
├── README.md
├── LICENSE                             # MIT
├── SPEC.md                             # this file
├── IMPLEMENTATION_PLAN.md              # produced by Opus, reviewed before coding
├── Sources/
│   ├── ContextBuddyCore/               # actor, state machine, schemas, SQLite
│   │   ├── Schemas.swift               # Codable types for JSON contracts
│   │   ├── Watcher.swift               # FSEvents wrapper, debounce
│   │   ├── StateMachine.swift          # score → state mapping
│   │   ├── SessionDiscovery.swift      # multi-project session resolution
│   │   ├── Storage.swift               # SQLite (state.db) wrapper
│   │   └── Core.swift                  # public actor API
│   └── ContextBuddyApp/                # SwiftUI menubar app
│       ├── ContextBuddyApp.swift       # @main entry
│       ├── MenubarController.swift     # NSStatusItem lifecycle
│       ├── PopoverView.swift           # the score popover
│       ├── IconRendering.swift         # state → SF Symbol + color + animation
│       └── KeyboardShortcuts.swift     # A/M/I in popover
├── Tests/
│   └── ContextBuddyCoreTests/
│       ├── StateMachineTests.swift     # threshold logic, hysteresis-equivalent
│       ├── SchemaTests.swift           # JSON parse/serialize round-trips
│       └── SessionDiscoveryTests.swift # project-hash resolution, MRU
├── plugin/
│   ├── plugin.json                     # Claude Code plugin manifest
│   ├── hooks/
│   │   ├── user_prompt_submit.sh
│   │   └── stop.sh
│   ├── commands/
│   │   ├── inspect.md                  # default deep dive
│   │   ├── inspect_init.md             # bootstrap session.md
│   │   ├── inspect_history.md
│   │   └── inspect_diff.md
│   ├── statusline.sh
│   ├── grader/
│   │   ├── system_prompt.md            # the grader prompt (Opus authors wrapper)
│   │   └── invoke.sh                   # POSTs to Anthropic API, writes JSON
│   └── lib/
│       ├── project_hash.sh             # sha256(realpath(absolute_path))[:12]
│       ├── session_paths.sh            # resolves all paths from project hash
│       └── transcript.sh               # sliding window assembly
└── docs/
    └── (empty in v1; future expansion target)
```

**Test scope**: unit-test `ContextBuddyCore` only. State machine, schema parsing, session discovery, storage operations. Do not write tests for SwiftUI views — visual iteration is faster manually.

---

## 4. JSON Schemas

These are the contracts between plugin and buddy. **Field names, types, and value ranges are fixed.** Do not invent fields. Unknown fields in incoming JSON must be ignored, not error.

### 4.1 `last.json`

A single grade. Always reflects the most recent grade event (whether `pre` or `post`). The status line and the buddy both read this file.

```json
{
  "schema_version": 1,
  "phase": "pre",
  "turn": 14,
  "timestamp": "2026-04-29T11:42:18Z",
  "scores": {
    "confidence": {
      "value": 6,
      "rationale": "Goal clear (fix expired-token bug) but acceptance criteria absent for the refactor"
    },
    "atomicity": {
      "value": 3,
      "rationale": "Bundles bug fix + opportunistic refactor + test addition in one prompt"
    },
    "drift": {
      "value": 2,
      "rationale": "Aligned with auth refactor goal; in-scope file"
    },
    "pollution": {
      "value": 4,
      "rationale": "Three superseded plans from turns 8-11 still present"
    }
  },
  "tokens_used": 47823,
  "tokens_limit": 200000,
  "dominant_signal": "atomicity",
  "summary_update": "User refactoring auth to JWT. Through turn 13, validation logic and middleware updated. Turn 14 expands scope to bundled bug fix + refactor + test."
}
```

**Field rules**:
- `schema_version` — always `1` in v1. Buddy reads and warns (does not error) on unknown versions.
- `phase` — `"pre"` (UserPromptSubmit) or `"post"` (Stop). Same schema; phase discriminates.
- `turn` — monotonically increasing integer per session, 1-indexed.
- `timestamp` — ISO 8601 UTC.
- `scores.<dimension>.value` — integer 0-10 inclusive.
- `scores.<dimension>.rationale` — string, max ~120 chars, references concrete turns/files where possible.
- `tokens_used`, `tokens_limit` — integers. Token economics is *measured, not graded*. `tokens_limit` is the session model's context window, resolved per grade by `plugin/lib/context_window.sh` (§5.4), never a constant; `tokens_used ≤ tokens_limit` always holds.
- `model` — optional string, additive. The session's Claude model id as read from the last non-`<synthetic>` assistant record of the transcript (`claude-fable-5-1`, `claude-haiku-4-5-20251001`), or `null` when no transcript was readable. Not the grader's model (that is `signals.model`).
- `limit_source` — optional string, additive. Where `tokens_limit` came from: `"override"` (`CONTEXTBUDDY_CONTEXT_WINDOW`), `"autocompact"` (Claude Code's auto-compact window), `"model"` (prefix table), `"observed"` (evidence floor), `"default"` (200000 fallback). See §5.4.
- `dominant_signal` — string. One of `"confidence"`, `"atomicity"`, `"drift"`, `"pollution"` (when a score drove a state change), or sentinel values `"loop"`, `"context_pressure"` (when a non-score signal drove dizzy state), or `null` (no state-changing signal).
- `summary_update` — the rolling ~200-token summary maintained by the grader. Reflects state after this turn.
- `signals` — optional object, backend-specific. Emitted by the `typesafe` backend only; absent for `anthropic`, `ollama` and `openai_compatible`. Every field inside is optional and consumers must tolerate new ones (§13). Known fields: `backend`, `model`, `is_task`, `task_gated`, `intent` (`choice`, `probabilities` map, `confidence`), `is_correction`, `destructive`, `bypass`, `severity`, `masses` (`confidence_low`, `atomicity_low`, `drift_high`, `pollution_high`). Surfaced in the popover's "Why this grade" disclosure (§9.3).
  - Note for consumers: the keys of `intent.probabilities` are data, not schema. Swift's `.convertFromSnakeCase` does not rewrite dictionary keys, so they arrive verbatim (`fix_bug`, not `fixBug`).

### 4.2 `history.jsonl`

Append-only JSONL. One line per grade. Each line is structurally identical to `last.json`. The most recent line in `history.jsonl` matches `last.json`. Do not rewrite, only append.

### 4.3 `turns/NNN-pre.json` and `turns/NNN-post.json`

Per-turn snapshots. Identical schema to `last.json`. Filename convention: zero-padded 3-digit turn number + phase suffix. Files are written atomically (temp file + rename).

### 4.4 `session.md`

Human-authored YAML frontmatter only (no body). The anchor for grading.

```yaml
goal: <one sentence>
acceptance:
  - <criterion 1>
  - <criterion 2>
in_scope:
  - <path/glob>
  - <path/glob>
out_of_scope:
  - <path/glob>
constraints:
  - <constraint>
  - <constraint>
created_at: <ISO 8601>
```

`/inspect init` writes a starter `session.md` if one does not exist. The plugin grader reads this file on every grade and includes it in the grader system prompt.

### 4.5 `suggestions.md`

Human-readable, append-only Markdown. The plugin appends a section every time a grade triggers `attention` or `dizzy`. The buddy reads this file only when the user opens it via the popover; it is not parsed for state. Format per worked examples in §8.

### 4.6 `feedback.jsonl`

Append-only JSONL written by the buddy. One line per ack or mute event.

```json
{"timestamp": "2026-04-29T11:43:02Z", "turn": 14, "action": "ack", "signal": "atomicity"}
{"timestamp": "2026-04-29T11:43:08Z", "turn": 14, "action": "mute", "signal": "atomicity", "scope": "session"}
```

`action` is `"ack"` or `"mute"`. `signal` matches the `dominant_signal` field on the grade being ack'd/muted, including the `"loop"` and `"context_pressure"` sentinels. `scope` is `"session"` (mute only this session) or `"persistent"` (mute across all future sessions until cleared) — v1 only emits `"session"`; persistent mute is v2.

### 4.7 `state.db` (SQLite)

Owned by the buddy. Schema:

```sql
CREATE TABLE feedback_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_hash TEXT NOT NULL,
  turn INTEGER NOT NULL,
  action TEXT NOT NULL,           -- 'ack' | 'mute'
  signal TEXT NOT NULL,
  scope TEXT NOT NULL,            -- 'session' | 'persistent'
  ts TEXT NOT NULL                -- ISO 8601
);

CREATE TABLE state_transitions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_hash TEXT NOT NULL,
  from_state TEXT NOT NULL,
  to_state TEXT NOT NULL,
  trigger TEXT NOT NULL,          -- e.g., 'atomicity<4', 'loop', 'context_pressure'
  turn INTEGER,
  ts TEXT NOT NULL
);
```

Stored at `~/Library/Application Support/ContextBuddy/state.db`.

The buddy logs every state transition and every feedback event. v2 will read these for corpus-aware grading and personal analytics. v1 only writes — no read consumers exist yet.

### 4.8 `config.toml`

User-editable preferences. v1 has no preferences UI; the file is edited directly. Stored at `~/.claude/inspector/config.toml`.

```toml
[thresholds]
confidence_attention = 4    # confidence < this triggers attention
atomicity_attention = 4
drift_attention = 6         # drift > this triggers attention
pollution_attention = 7
celebrate_consecutive_n = 5
loop_edits_in_window = 3    # N edits to same file in N consecutive turns
loop_window_turns = 3
context_pressure_pct = 85   # tokens_used/tokens_limit > this triggers dizzy (limit per §5.4)

[grader]
model = "claude-haiku-4-5-20251001"
sliding_window_turns = 3    # last N turns verbatim
inspect_model = "claude-sonnet-4-6"

[ui]
animations_enabled = true   # false: no icon motion. macOS Reduce Motion has the same effect; the two compose as AND (§9.6)
token_row_pct = 70          # §9.3 ⚡ row is de-emphasized at or below this percent
```

The buddy and plugin both read `config.toml` on each grade event. Hot-reload on file change; no restart required. The buddy also checks the file on its 30 s sleep tick, so an edit with no grade in flight lands within one tick.

### 4.9 `meta.json`

Project identity for the session directory. The project hash is one-way, so this file is the only record of which project a session directory belongs to. Written atomically by both hooks on every turn — not only the first, so directories created before this file existed self-heal on their next graded turn.

```json
{
  "schema_version": 1,
  "project_path": "/Users/cory/dev/contextbuddy"
}
```

**Field rules**:
- `schema_version` — always `1` in v1.
- `project_path` — the absolute project path, **byte-identical to the string the hook passed to `project_hash`**. `sha256(project_path)[:12]` must equal the name of the directory this file sits in; if the two disagree, the buddy names a different project than the scores belong to. The hooks pass the canonical (symlink-resolved) path (issue #4), so that is what gets recorded — there is no second normalization step here.

Deliberately *not* a field on `last.json`: project identity is session metadata rather than a graded score, `last.json` is version-gated as the grader's validated output schema (§4.1), and the project name must be correct from turn one rather than only after the first successful grade.

The buddy treats this file as optional. When it is absent or unparseable, the popover's project footer row falls back to the project-hash prefix (§9.3).

---

## 5. State Machine

The buddy renders one of seven states. Transitions occur on grade events and on session lifecycle events. There is no time-based hysteresis — state reflects the latest grade.

### 5.1 States and triggers

| State | Trigger | Auto-clear |
|---|---|---|
| `sleep` | No active Claude Code session detected (no grade events for >5 min and no open turn) | When next grade event arrives |
| `idle` | Session active, no other state firing | (default state) |
| `busy` | UserPromptSubmit fired without subsequent Stop | When matching Stop arrives |
| `attention` | Any of: `confidence < confidence_attention`, `atomicity < atomicity_attention`, `drift > drift_attention`, `pollution > pollution_attention` | When subsequent grade has all four within thresholds |
| `celebrate` | All four scores ≥7 for `celebrate_consecutive_n` consecutive grades | After ~2.5 sec animation completes |
| `dizzy` | Loop detected (same file edited in `loop_edits_in_window` of the last `loop_window_turns` grades) OR `tokens_used/tokens_limit > context_pressure_pct` | When loop pattern broken AND context pressure resolved |
| `heart` | User ack'd a suggestion via popover or right-click menu | After ~3 sec, return to idle |

### 5.2 State precedence

When multiple conditions could fire, precedence is (highest to lowest):

1. `heart` (transient feedback, always wins briefly)
2. `dizzy` (behavioral red flag)
3. `attention` (score-driven warning)
4. `celebrate` (positive feedback, transient)
5. `busy`
6. `idle`
7. `sleep`

`heart` is special: it always interrupts whatever state was current, holds for ~3 sec, then returns the buddy to whatever state would otherwise be current (re-evaluated against latest grade).

### 5.3 Attention auto-clear and suggestions log

When `attention` fires, the plugin appends a section to `suggestions.md` with the rationale and (where applicable) a suggested rewrite or intervention. The buddy state itself clears as soon as scores recover, but the log entry persists. This means: a brief blip into attention is recoverable in the log even if the buddy returned to idle quickly.

### 5.4 Dizzy detection

Two distinct triggers, both of which set `dominant_signal` to a sentinel value:

- **Loop**: scan the last `loop_window_turns` post-Stop grades. If any single file path appears in the edited-files list of `loop_edits_in_window` of them, dizzy fires. `dominant_signal: "loop"`.
- **Context pressure**: `tokens_used / tokens_limit > context_pressure_pct / 100`. `dominant_signal: "context_pressure"`.

The plugin computes both and sets `dominant_signal` accordingly. The grader prompt does not need to know about these — they are mechanical, not semantic.

**Token usage.** Hook payloads carry no usage either, so `tokens_used` is measured by the hooks from the transcript at `transcript_path`: `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` of the last `type: "assistant"` record carrying `usage` whose model is not `<synthetic>` (`plugin/lib/transcript.sh transcript_window`, the same arithmetic as `grader/jev.mjs parseTranscript`). That count is what the resolver below floors against. No transcript, or none with assistant usage yet, leaves the grader's `tokens_used` standing and the floor is re-applied against it.

**Context window resolution.** Hook payloads carry no model or window, so `tokens_limit` is resolved per grade by `plugin/lib/context_window.sh` (mirrored in `grader/jev.mjs` and `grader/jev_shadow.py`; the prefix table is `plugin/lib/context_windows.json`, read by all three). First hit wins and is recorded as `limit_source` (§4.1):

1. `override` — `CONTEXTBUDDY_CONTEXT_WINDOW` from the environment or a `.env` found by `lib/dotenv.sh`. Accepts `300000` / `300k` / `1m`. Deliberately not a `config.toml` key: the Swift parser drops the whole file on an unknown key (§4.8).
2. `autocompact` — `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, else `autoCompactWindow` in `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` (what `/autocompact` writes), same spellings. The effective ceiling is the compact trigger, not the raw window.
3. `model` — `message.model` of the last `type: "assistant"` record in `hook.transcript_path` whose model is not `<synthetic>`, mapped by prefix: 1M for `claude-fable-*`, `claude-mythos-*`, `claude-sonnet-5*`, `claude-opus-5*`, `claude-opus-4-8*`, `claude-opus-4-7*`; 200K for `claude-haiku-*`, `claude-sonnet-4-6*`, `claude-opus-4-6*`, `claude-*-4-5*` and anything else (conservative). `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` forces 200K on the 1M rows. `[1m]` variants and gateway aliases are out of scope and rely on step 5.
4. `default` — no transcript, no model: 200000.
5. `observed` — evidence floor, applied after 1-4 against the measured `tokens_used`: a limit below `tokens_used` is raised to the next tier (200K → 1M; past the last tier, to `tokens_used` itself). Never lower the limit below observed usage. This is why a 697327-token transcript on a model the table does not know grades against 1M, not 200K: the limit was unknown, not the context full.

The hooks resolve once per grade, print the pair on the `## tokens` line the LLM backends copy, embed it in the typesafe job, and stamp `tokens_used` / `tokens_limit` / `model` / `limit_source` onto the grade in one write before the context-pressure comparison, so the four fields can never disagree, `tokens_used ≤ tokens_limit` holds for every grade written, and all four backends agree. Budget: `tail` plus `jq` over the transcript and `settings.json`; no API calls.

### 5.5 Celebrate consecutive counting

Maintain a counter: increment on each grade where all four scores ≥7, reset to zero on any grade where any score drops below 7. When counter reaches `celebrate_consecutive_n`, fire celebrate (then continue counting; subsequent celebrates require another `celebrate_consecutive_n` clean grades).

---

## 6. Rubric — Grader Definitions (FIXED)

> **Implementer**: this prose is locked. It must appear verbatim in the grader system prompt. You will write the wrapper around it (see §7).

All scores are 0-10 integers. The grader produces a `value` and a one-line `rationale` for each dimension on each grade event. Rationale is concrete and references specific prompt text, turns, or files where possible — never abstract.

### Confidence — *how clear is the prompt itself?*

Measures specification quality of the prompt as written. A confident prompt makes the goal, acceptance criteria, scope, and constraints explicit enough that a competent agent could not reasonably misinterpret it.

| Score | Meaning |
|---|---|
| 0-2 | Goal itself is ambiguous. Multiple reasonable interpretations exist. |
| 3-4 | Goal stated but acceptance criteria absent. "Done" is undefined. |
| 5-6 | Goal + implicit acceptance, but scope and constraints unstated. |
| 7-8 | Goal + acceptance + scope explicit. Constraints implied or partially stated. |
| 9-10 | Goal + acceptance + scope + constraints all explicit. No reasonable misinterpretation possible. |

Confidence is a property of *the prompt text*, evaluated against the session anchor. It does not predict whether the agent will succeed — only whether the prompt is well-specified enough that success is well-defined.

### Atomicity — *is it one thing?*

Measures whether the prompt requests a single decision OR a single action, not both and not multiple of either. Atomic prompts have one thing to do; non-atomic prompts bundle distinct decisions or actions, often disguised as a single ask.

| Score | Meaning |
|---|---|
| 0-2 | Multiple decisions AND multiple actions mixed together. |
| 3-4 | Mixed: requires a decision THEN an action based on the decision. |
| 5-6 | Two related actions or two related decisions bundled. |
| 7-8 | One primary thing with one minor subordinate task. |
| 9-10 | One decision OR one action, with a clear boundary. |

The common antipattern: a prompt phrased as one thing ("fix the auth bug") that actually requires deciding how, implementing, and updating tests. Atomicity catches that bundling. Splitting non-atomic prompts into atomic ones is the most reliable lever for improving agent output.

### Drift — *are we still doing what we said?*

Measures distance from the session anchor's stated goal plus encroachment into items the anchor explicitly marks `out_of_scope`. Drift is evaluated against `session.md`, not against the prior prompt.

| Score | Meaning |
|---|---|
| 0-2 | Tightly aligned with anchor goal. No scope creep. |
| 3-4 | Aligned with goal, minor adjacent territory. |
| 5-6 | Adjacent but defensible — same problem space, different facet. |
| 7-8 | Clear scope expansion or partial out_of_scope encroachment. |
| 9-10 | Working on something the anchor explicitly excludes, or unrelated to anchor goal. |

A high drift score does not mean the work is wrong — sometimes the user has legitimately changed direction. It means the work no longer matches the recorded session intent, and the anchor should be updated or the prompt redirected. The buddy surfaces the discrepancy; the user decides which to change.

### Pollution — *how much of the context is dead weight?*

Measures the fraction of the context window occupied by stale content, redundancy, or low-value high-token blocks. Three distinct sub-types contribute, and the rationale should name which dominated.

| Score | Meaning |
|---|---|
| 0-2 | Context is clean. Recent and relevant throughout. |
| 3-4 | Some stale content but not crowding active work. |
| 5-6 | Notable accumulation: superseded plans, redundant reads, or one large low-value block. |
| 7-8 | Active work is competing with dead weight for attention. Compaction would help. |
| 9-10 | Context is dominated by stale, redundant, or low-value content. Compaction or reset is warranted. |

Sub-types:
- **Stale content** — tool results made obsolete by subsequent edits (a file read where the file has changed since)
- **Redundancy** — same information present in multiple blocks (re-reads of the same file, repeated web fetches)
- **Low-value high-token** — large outputs (full file dumps, scraped pages, verbose error logs) that contributed minimally to current state

Pollution is graded only on `post` (Stop) phase. On `pre` (UserPromptSubmit) phase, the grader copies forward the previous turn's pollution score with rationale prefixed `"(carried from turn N)"` — pollution does not change between Stop and the next UserPromptSubmit.

---

## 7. Grader Prompt Wrapper (Opus authors)

You will write the grader system prompt as a complete, locked artifact at `plugin/grader/system_prompt.md`. It must:

1. **Embed §6 verbatim** as the rubric definitions. Do not paraphrase, do not condense, do not "improve" the rubric prose. The exact words in §6 are the IP.
2. **Specify the input context the grader receives**: session.md content, latest prompt (for `pre`) or latest turn including agent response and tool calls (for `post`), the last N typed prompts verbatim (N = `[grader] sliding_window_turns`, default 3, read from the transcript at `transcript_path` as §10.1 describes — typed prompts only, no assistant replies and no tool calls), prior rolling summary, current `tokens_used`/`tokens_limit`, list of files edited in the last 5 turns (for loop pre-detection — the grader does not detect loops itself, but the rationale may reference the pattern).
3. **Specify the output schema**: must produce JSON conforming to §4.1 exactly. Include a worked output example (use Worked Example 1 from §8 as the canonical example). Strict JSON only — no preamble, no chain-of-thought, no markdown fences around the output.
4. **Instruct on rationale tone**: concrete, references turns/files, under ~120 chars, action-mappable where possible.
5. **Instruct on `dominant_signal`**: set to the dimension whose threshold cross drove a state change, OR `null` if no threshold crossed. Do not set to `"loop"` or `"context_pressure"` — those are set mechanically by the plugin, not the grader.
6. **Instruct on `summary_update`**: maintain a rolling summary under ~200 tokens that captures session state, recent direction, and any open issues. Update each grade.

The grader prompt should be model-agnostic in structure (so the same prompt works for Haiku and Sonnet) but it will be primarily called against `claude-haiku-4-5-20251001` for `pre`/`post` grades and `claude-sonnet-4-6` for `/inspect` deep dives. The deep-dive variant additionally produces a `deep_analysis` field with multi-paragraph prose; this is a separate output schema and should be documented as a v1 deliverable too.

---

## 8. Worked Examples

These three examples are the canonical reference for JSON shape, rationale tone, popover layout, and suggestion log format. They should appear in the README and be referenced from the grader prompt as format exemplars.

### 8.1 Example 1 — Attention (atomicity bundling)

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
    "confidence": {
      "value": 6,
      "rationale": "Goal clear (fix expired-token bug) but acceptance criteria absent for the refactor"
    },
    "atomicity": {
      "value": 3,
      "rationale": "Bundles bug fix + opportunistic refactor + test addition in one prompt"
    },
    "drift": {
      "value": 2,
      "rationale": "Aligned with auth refactor goal; in-scope file"
    },
    "pollution": {
      "value": 4,
      "rationale": "(carried from turn 13) Three superseded plans from turns 8-11 still present"
    }
  },
  "tokens_used": 47823,
  "tokens_limit": 200000,
  "dominant_signal": "atomicity",
  "summary_update": "User refactoring auth to JWT. Through turn 13, validation logic and middleware updated. Turn 14 expands scope to bundled bug fix + refactor + test."
}
```

**Buddy state transition**: `idle` → `attention` (atomicity 3 < 4 threshold)

**Menubar icon**: `exclamationmark.triangle` with orange tint, brief 300ms scale pulse on transition

**Popover content (on click)**:
```
🟡 attention   turn 14 · pre              a1b2c3…
──────────────────────────────────────────
Confidence  ▓▓▓▓▓▓╎░░░░  6/10
Atomicity   ▓▓▓╎░░░░░░░  3/10  ⚠
Drift       ▓▓░░░░░╎░░░  2/10
Pollution   ▓▓▓▓░░░╎░░░  4/10
⚡ 48k / 200k (24%)

Atomicity: prompt bundles bug fix +
opportunistic refactor + test addition.
Try splitting into three prompts.

› Why this grade

[Ack]  [Mute "atomicity"]  [Open inspector]
```

**Suggestion log entry** (appended to `suggestions.md`):
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

### 8.2 Example 2 — Celebrate (sustained quality)

Turns 18-22 have all produced post-Stop grades with all four scores ≥7. Turn 22 is the fifth such grade.

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

**Buddy state transition**: `idle` → `celebrate` (5th consecutive all-green grade)

**Menubar icon**: `sparkles` with built-in animation, plays for ~2.5 seconds, then settles back to `idle`

**Popover content (on click during celebrate)**:
```
✨ celebrate
─────────────
Confidence  ▓▓▓▓▓▓▓▓╎░░  8/10
Atomicity   ▓▓▓▓▓▓▓▓▓░░  9/10
Drift       ▓░░░░░╎░░░░  1/10
Pollution   ▓▓▓░░░░╎░░░  3/10

5 consecutive all-green grades.
Sustained quality on the JWT refactor.

[Ack]  [Open inspector]
```

**No suggestion log entry** — celebrate is positive feedback, not a suggestion. The history.jsonl entry records the celebrate event for later analytics.

### 8.3 Example 3 — Dizzy (loop detection)

Turns 27, 28, 29 all included edits to `src/auth/jwt.ts`. The file has been edited in three consecutive turns. Other scores are not threshold-crossing.

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

Note: no individual *score* crossed an attention threshold. Dizzy is triggered by behavioral pattern detection, not score thresholds. `dominant_signal` is set to `"loop"` by the *plugin* (not the grader), which then writes `last.json` with this value.

**Buddy state transition**: `idle` → `dizzy`

**Menubar icon**: `exclamationmark.arrow.circlepath` with continuous wiggle animation (built-in SF Symbol effect), repeats while in dizzy state

**Popover content (on click)**:
```
🌀 dizzy
─────────────
Confidence  ▓▓▓▓▓▓▓╎░░░  7/10
Atomicity   ▓▓▓▓▓▓▓▓▓░░  9/10
Drift       ▓▓░░░░░╎░░░  2/10
Pollution   ▓▓▓▓▓░░╎░░░  5/10

Loop: 3 consecutive edits to
src/auth/jwt.ts. Test still failing
after each iteration.

Consider: rolling back, or escalating
the failure mode for human review.

[Ack]  [Mute "loop"]  [Open inspector]
```

**Suggestion log entry**:
```markdown
## Turn 29 — 2026-04-29 13:08 — loop detection

**Pattern**: src/auth/jwt.ts edited in turns 27, 28, 29 (3 consecutive). Same test continues to fail.

**Possible causes**:
- Agent's mental model of the failure is wrong; further edits compound the error
- Test is wrong, not the implementation
- Missing context that would resolve the actual cause

**Suggested intervention**:
- Stop and ask the agent to summarize what it has tried and why each attempt failed
- Or roll back to turn 26 and reframe the prompt with a stricter acceptance criterion

Status: open
```

---

## 9. Menubar UI Contract

This section is non-negotiable. The buddy is peripheral and quiet; deviations from this contract change what the product *is*.

### 9.1 Icon mapping

| State | SF Symbol | Tint | Animation |
|---|---|---|---|
| `sleep` | `moon.zzz` | `.secondary` (dimmed) | none |
| `idle` | `circle` | `.primary` | none |
| `busy` | `circle.dotted` | `.primary` | subtle rotation, indefinite |
| `attention` | `exclamationmark.triangle` | `.orange` | 300ms scale pulse on transition (one-shot) |
| `celebrate` | `sparkles` | `.yellow` | `.symbolEffect(.bounce)`, ~2.5s |
| `dizzy` | `exclamationmark.arrow.circlepath` | `.orange` | `.symbolEffect(.wiggle, options: .repeating)` while in state |
| `heart` | `heart.fill` | `.pink` | `.symbolEffect(.pulse)` once, hold ~3s |

### 9.2 Animation policy

- **Routine transitions** (idle ↔ busy) are silent and instantaneous. No motion.
- **Attention/celebrate/dizzy/heart** transitions are animated. Animation is the attention signal.
- All animations under 800ms total wall-clock unless the state itself is held (dizzy wiggles continuously while in state; celebrate plays once and ends).
- The status item is an AppKit `NSStatusItem`, so the effects in §9.1 run as the same SF Symbol effects through `NSImageView.addSymbolEffect` (`.bounce`, `.wiggle`, `.pulse`, `.rotate`) on an image view hosted in the item's button. A one-shot plays once per transition into its state; a snapshot that repeats the state does not replay it.

### 9.3 Popover

- Opens on left-click of the menubar item.
- Dismisses on outside click. Dismisses on Esc.
- Width: ~320pt. Height: variable based on content, but never tall enough to feel like a window.
- Content (top to bottom):
  - State name + emoji (e.g., "🟡 attention"), the turn/phase badge (`turn 7 · post`), and the project hash fragment
  - Horizontal rule
  - Score meters — one row per dimension (see below)
  - Token economics row
  - Dominant rationale (the rationale of the dimension whose threshold cross drove the state, OR a synthesized line for `loop`/`context_pressure`/`celebrate`)
  - "Why this grade" disclosure, collapsed by default (see below)
  - Action row: `[Ack]  [Mute "<signal>"]  [Open inspector]` (Mute button hidden in celebrate/heart states)
  - Horizontal rule
  - Project footer row, pinned to the bottom: `📁 <project name>` — the name of the repository `project_path` from `meta.json` (§4.9) sits in, naming the project the scores belong to. The buddy walks up from `project_path` to the nearest ancestor holding a `.git` entry: a `.git` directory names that ancestor; a linked worktree's `.git` file (`gitdir: <main>/.git/worktrees/<name>`) names the main checkout, so a session in `.claude/worktrees/objective-cerf-9a0580` shows `contextbuddy`; any other `.git` file names the directory holding it. With no repository above the path, the name is the last path component. Resolution reads the `.git` entry directly (the buddy never shells out to `git`) and is cached per session hash, never recomputed per snapshot. Truncated in the middle, never wrapped. The recorded `project_path` — not the resolved repository root — is the row's tooltip only, never rendered inline (it leaks `/Users/<username>/…` into a screenshot-able surface and does not fit 320pt). Falls back to the project-hash prefix when `meta.json` is absent. Distinct from `plugin/statusline.sh`, which is Claude Code's status line (§10.2) and needs no project label.

**Score meters.** The four dimensions render as one labelled row each, in §6
rubric order, replacing the former one-line `conf:N atom:N drift:N pol:N` row.
That format could not express the property a reader most needs: confidence and
atomicity are higher-is-better while drift and pollution are higher-is-worse
(§6), so `conf:2 atom:5 drift:0 pol:1` renders the alarm (`conf:2`) and the
best possible score (`drift:0`) identically.

Each row is: full-word dimension name, a bar drawing the raw score with a tick
at that dimension's own attention threshold, the value as `N/10`, and a marker
when the dimension is the grade's `dominant_signal`.

Colour encodes distance from the threshold, never raw magnitude:

| Condition | Colour |
|---|---|
| Past the §5.2 attention threshold | orange (the `attention` icon tint, §9.1) |
| Exactly at the threshold | yellow |
| Otherwise | secondary/neutral |

So orange means "this one is the problem" on all four dimensions regardless of
which direction is bad, and the user never has to know the polarity to read the
row. The bar draws the raw value rather than "goodness" — an inverted bar for
drift and pollution would visibly disagree with the number beside it.

**Tooltips.** Every element carries a `.help()` tooltip: each meter gives its
rubric question, polarity, threshold and that dimension's full grader rationale
(three of the four rationales are otherwise never shown); the state name
explains what will clear it; the token row gives exact token counts; the hash
gives the full 12 chars; each action button says what it writes and its
keyboard shortcut. The same strings back the VoiceOver labels.

**Token economics row** is always rendered when `tokens_limit > 0`, formatted
`⚡ 142k / 200k (71%)` (a 1M window prints as `1M`: `⚡ 176k / 1M (17%)`,
`TokenFormat.short`), de-emphasized below `[ui].token_row_pct` and orange
above it. It was previously hidden entirely below the threshold; "how close am
I to a compact?" is a question the user asks deliberately, and a row that
vanishes cannot answer it.

**"Why this grade" disclosure** is collapsed by default and holds the
backend's `signals` block when present (§4.1): the top intents with their
probabilities, the harm signals (`correction`, `destructive`, `bypass`,
`severity`) in two columns, and the grader backend/model. `summary_update` is
shown here only for backends that emit no `signals`, because the typesafe
backend packs the same digest into it and rendering both repeats every number.

### 9.4 Right-click menu

- "Ack current state" (disabled when in `idle`/`sleep`/`busy`)
- "Mute current signal — this session"
- "Recent sessions ▶" (submenu listing the last 5 sessions by project name, allowing pin-to). Each item is titled with the project name resolved from the session's `meta.json` (§4.9), the same name as the §9.3 footer row; a session dir with no `meta.json` shows the hash prefix (`abcdef…`), never a blank row. Two visible sessions that resolve to the same name each carry their hash prefix as a suffix (`api (abcdef)`) so the rows stay distinguishable. The item's pin target and its checkmark are keyed on the full hash, never the title.
- "Open inspector folder"
- separator
- "Preferences (edit config.toml)"
- "About ContextBuddy"
- "Quit"

### 9.5 In-popover keyboard shortcuts

When popover is focused:
- `A` → Ack
- `M` → Mute current signal
- `I` → Open inspector folder

### 9.6 What the buddy must NOT do

- No notifications via `UNUserNotificationCenter`. The icon IS the notification.
- No sound output of any kind in v1.
- No focus stealing. The popover does not steal focus from the active app.
- No Dock icon (`LSUIElement = true`).
- No window other than the popover.
- No automatic quit or sleep behavior beyond OS defaults.
- No motion the user has turned off. `[ui].animations_enabled = false` and the macOS Reduce Motion setting (System Settings > Accessibility > Display) each suppress every §9.1 effect, held and one-shot; the glyph and tint still change. They compose as AND — neither overrides the other — and both take effect without a restart.

---

## 10. Plugin Behavior

### 10.1 Hooks

**`hooks/user_prompt_submit.sh`**:
- Resolves the project hash from `$PWD`.
- Ensures the session directory exists.
- Records `meta.json` (§4.9) with that same `$PWD`, atomically. Failure is logged and skipped like any other hook error (§13) — the buddy falls back to the hash.
- Determines the current turn number: advances `turns/.counter` under the write lock (seeded from the max `turns/NNN-*.json`), so a skipped grade still consumes a number.
- Assembles grader input: session.md, latest prompt (from hook input), last 3 typed prompts verbatim and `tokens_used` from the JSONL transcript at the hook input's `transcript_path` (the payload itself carries no turns or usage), prior summary from history.jsonl tail.
- Calls Anthropic Messages API with Haiku model, grader system prompt, assembled input.
- Parses response JSON. Validates conforms to schema §4.1. On parse failure, log error and skip — do not crash the user's session.
- Writes `turns/NNN-pre.json` atomically.
- Computes `dominant_signal` mechanically (overrides grader's value if loop or context_pressure detected — but at the pre-phase, only context_pressure is computable; loop requires post-phase edit history).
- Copies to `last.json` atomically.
- Appends to `history.jsonl`.
- If state would transition to `attention` or `dizzy`, appends a section to `suggestions.md`.

**`hooks/stop.sh`**: identical pipeline but with phase=`post` (including the `meta.json` write, since a Stop can be the first hook to create the session directory). Additionally:
- Reads this turn's `Edit`/`Write`/`MultiEdit` `tool_use` records — the assistant records after the last typed prompt in the transcript at `transcript_path` — to extract the list of files edited. The hook input carries no tool calls.
- Maintains a rolling edit history (last 5 turns × edited files) in a small file under `sessions/<hash>/edits.jsonl`.
- Computes loop detection per §5.4 and overrides `dominant_signal` to `"loop"` if triggered.
- Writes `turns/NNN-post.json`, updates `last.json`, appends history.

### 10.2 Status line

`statusline.sh` reads `last.json` and prints a single line:

```
🟢 conf:8 atom:7 drift:2 pol:3 ⚡48k/200k
```

The token pair abbreviates like the popover row: `k` for thousands, `M` for millions (`⚡176k/1M` on a 1M-window model).

Color of the leading dot maps to current state (green for idle/celebrate, yellow for attention, orange for dizzy, gray for sleep, blue spinner for busy). Status line script must complete in <50ms; do not call APIs.

### 10.3 Slash commands

- **`/inspect init`** — Bootstraps `session.md`. If a `CLAUDE.md` exists, propose a draft based on it. Otherwise, prompt the user inline for goal/acceptance/scope.
- **`/inspect`** — Triggers a Sonnet 4.6 deep-dive grade on current context. Output is a multi-paragraph analysis written to `inspect_<turn>.md` and printed inline.
- **`/inspect history`** — Renders a compact timeline of grades from `history.jsonl`, highlighting state transitions.
- **`/inspect diff <turn1> <turn2>`** — Diffs two `turns/NNN-*.json` files, surfacing which scores changed and why.

### 10.4 Plugin manifest

`plugin/plugin.json` declares hooks and commands per Claude Code plugin spec. Implementer should consult Anthropic's plugin documentation at handoff time for the current schema (the manifest format may have evolved since this spec was written).

---

## 11. v1 Scope

**In scope**:
- Plugin: hooks, status line, four slash commands
- Buddy: menubar app, seven states, popover, right-click menu, keyboard shortcuts
- Multi-project session discovery via project-hash subdirs
- Feedback loop: ack/mute writes to feedback.jsonl AND state.db
- All file formats per §4
- Grader prompt (Opus authors wrapper around fixed §6 rubric)
- Three worked examples in README
- Tests for ContextBuddyCore (state machine, schemas, session discovery, storage)

**Out of scope (v1)**:
- Preferences UI. `config.toml` is edited directly.
- Onboarding flow. README explains setup.
- Auto-update / Sparkle integration.
- Telemetry of any kind.
- Tests for SwiftUI views.
- Persistent (cross-session) mute scope. v1 only emits `scope: "session"`.
- Corpus-aware grader calibration. v1 grades use anchor only.
- BLE or other hardware sinks.
- Web dashboard.
- Windows or Linux support.
- Localization. English only.
- Dark/light mode customization beyond what SF Symbols provides automatically.
- Accessibility audit beyond what SwiftUI provides by default. (Should still be functional with VoiceOver, but no explicit a11y design pass.)
- Heart state via prompt-quality trigger. v1 heart only fires on user ack.

---

## 12. Build and Distribution

- `swift build` from the repo root produces the app bundle.
- `swift test` runs ContextBuddyCore tests.
- Distribution: notarized DMG via `notarytool`. No Mac App Store distribution.
- Plugin install: `claude code plugin install path/to/plugin/` (or whatever the current Claude Code CLI command is at handoff time).
- Code signing: developer ID required for notarization. Implementer should produce a `scripts/release.sh` that handles build → sign → notarize → DMG.

---

## 13. Failure Modes and Resilience

The buddy and the plugin must each fail gracefully when the other is absent or misbehaving.

- **Plugin without buddy**: writes files normally. Status line works. No menubar UI, but no error.
- **Buddy without plugin**: menubar shows `sleep`. Polls FSEvents normally; no events arrive; state remains `sleep`.
- **Malformed `last.json`**: buddy logs to stderr, retains previous state, continues watching.
- **Missing `session.md`**: plugin grader prompt notes its absence; scores produced are advisory but flagged with reduced confidence in rationale ("session.md not found — grading against prompt only").
- **Anthropic API error (rate limit, timeout)**: plugin logs and skips that grade. No file is written. Buddy state remains as-of-previous-grade.
- **`transcript_path` missing, unreadable, or not a regular file**: the hook grades with an empty turn window and a transcript `tokens_used` of 0 (the grader's own token fields stand), writes one `contextbuddy:` warning to stderr, exits 0, and still writes the grade.
- **`jq` missing**: `transcript_window` degrades to the same empty window with a `contextbuddy:` warning and the hook continues; exit 0 in every case. On the default `anthropic` backend the grade is still written, unvalidated, because the §4.1 check and the mechanical `dominant_signal` overrides need jq. `ollama` and `openai_compatible` refuse up front in `grader/invoke.sh` and `typesafe` cannot build its job file, so those grades are logged and skipped.
- **SQLite corruption**: buddy logs error and recreates state.db with empty tables. Feedback events are lost; state.db is best-effort, not durable contract.
- **Project hash collision**: vanishingly unlikely with 12-char sha256 prefix. Not handled.
- **`config.toml` malformed**: plugin and buddy fall back to compiled-in defaults (matching the values in §4.8). Log warning.

---

## 14. Implementation Plan Requirements

Before writing any code, produce `IMPLEMENTATION_PLAN.md` containing:

1. **Component dependency graph**: which modules depend on which, in build order.
2. **File-by-file outline**: every file in §3 with a 1-3 sentence description of its responsibilities. Confirm or propose adjustments to the §3 layout.
3. **Test plan**: which behaviors of ContextBuddyCore will be covered by which test files. State machine transitions are the highest-priority test target.
4. **Order of work**: phased build sequence. Suggested phases: (a) ContextBuddyCore schemas + tests, (b) Watcher actor + tests, (c) StateMachine + tests, (d) Storage + tests, (e) ContextBuddyApp menubar plumbing, (f) Popover UI, (g) plugin scripts, (h) grader prompt, (i) integration.
5. **Open questions**: anything ambiguous in the spec that must be resolved before coding. Flag specifically; do not invent answers.
6. **Risks**: things you predict will be hard, with proposed mitigations.

Stop after writing `IMPLEMENTATION_PLAN.md`. Wait for review before any further work.

---

## 15. Non-Negotiables (read before coding)

- **Do not modify §6 (the rubric)**. Embed verbatim.
- **Do not invent JSON schema fields**. §4 is the contract.
- **Do not add features outside §11 v1 scope** without checking in.
- **Do not add a preferences UI**. Edit `config.toml` directly.
- **Do not add tests for SwiftUI views**.
- **Do not add notifications, sounds, or focus-stealing behavior**.
- **Do not assume polling works for file watching**. Use FSEvents.
- **Do not write a Dock-icon-bearing app**. `LSUIElement = true`.
- **Do not call the Anthropic API from Swift**. The Swift app is read-only against the file system; all API calls live in the plugin.

If any of these constraints conflict with something in the spec body, the constraint wins. If the conflict seems substantive, flag it in `IMPLEMENTATION_PLAN.md` rather than resolving it unilaterally.
