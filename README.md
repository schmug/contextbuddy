# ContextBuddy

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

```bash
claude code plugin install ./plugin/
```

(Verify the exact CLI surface against the current Claude Code docs — the plugin command may have evolved.)

### Bootstrap your first session anchor

In any project:

```
/inspect init
```

This drops a starter `session.md` at `~/.claude/inspector/sessions/<project-hash>/session.md`. Edit it to describe your goal, acceptance criteria, and scope. The grader uses this as ground truth for `confidence` and `drift` scoring.

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

The buddy aggregates these into seven states. Default thresholds (in `~/.claude/inspector/config.toml`):

| State | Trigger |
|---|---|
| `sleep` | No grade events in >5 min |
| `idle` | Active session, nothing flagged |
| `busy` | UserPromptSubmit fired without a matching Stop yet |
| `attention` | `confidence<4` or `atomicity<4` or `drift>6` or `pollution>7` |
| `celebrate` | 5 consecutive grades all-green |
| `dizzy` | 3 edits to the same file in 3 consecutive turns OR `tokens_used/tokens_limit > 85%` |
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
    "atomicity": {"value": 6, "rationale": "Single action (fix failing test) but third attempt"},
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
context_pressure_pct = 85   # tokens_used/tokens_limit > this triggers dizzy

[grader]
model = "claude-haiku-4-5-20251001"
sliding_window_turns = 3
inspect_model = "claude-sonnet-4-6"

[ui]
animations_enabled = true
token_row_pct = 70          # show ⚡ row when usage > this percent
```

Both the buddy and the plugin read this on each grade event. Hot-reload is automatic.

---

## File layout

```
~/.claude/inspector/
├── config.toml
└── sessions/
    └── <project-hash>/         # sha256(absolute_project_path)[:12]
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

## License

[MIT](LICENSE).
