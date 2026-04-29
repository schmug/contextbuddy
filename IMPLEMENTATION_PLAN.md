# IMPLEMENTATION_PLAN.md — ContextBuddy v1

> Authoritative input: [SPEC.md](SPEC.md). Every numbered cross-reference below points to a section of that document. Where the spec is locked (§4 schemas, §6 rubric, §11 scope, §15 non-negotiables), this plan inherits and does not adjust.

---

## 0. Context

ContextBuddy v1 ships two coupled artifacts that communicate **only through `~/.claude/inspector/`**:

1. A bash-only **Claude Code plugin** that grades each prompt (`UserPromptSubmit`) and each turn-completion (`Stop`) by calling Haiku 4.5, then writes JSON files plus a markdown suggestion log.
2. A **single-process SwiftUI menubar app** (`LSUIElement`, no Dock, no sandbox, macOS 14+) that watches those files via FSEvents and renders a 7-state buddy plus a popover. The Swift side is **read-only against the API** (§15) and writes only `feedback.jsonl` and `state.db`.

The plan below is the build sequence I would follow. It is structured to surface schema/state-machine bugs early (cheap to fix) and defer SwiftUI polish (expensive to fix late).

---

## 1. Component Dependency Graph

Build order is left-to-right. Each layer depends only on the ones to its left. Tests live alongside their layer.

```
┌──────────────┐
│ Schemas.swift│ (Codable types for §4.1–§4.6 + config.toml + edits.jsonl)
└──────┬───────┘
       │
       ▼
┌──────────────┐    ┌────────────────────┐
│ Storage.swift│    │ SessionDiscovery   │
│  (SQLite +   │    │ (project-hash, MRU,│
│   feedback   │    │  mtime resolution) │
│   writer)    │    └─────────┬──────────┘
└──────┬───────┘              │
       │                      │
       └──────────┬───────────┘
                  ▼
          ┌──────────────┐
          │StateMachine  │ (§5: scores → state, precedence,
          │  .swift      │  celebrate-counter, dizzy from
          └──────┬───────┘  dominant_signal sentinels)
                 │
                 ▼
          ┌──────────────┐
          │ Watcher.swift│ (FSEvents stream → debounced
          │              │  parsed last.json events)
          └──────┬───────┘
                 │
                 ▼
          ┌──────────────┐
          │  Core.swift  │ (public actor: subscribe(),
          │              │  recordFeedback(); composes
          └──────┬───────┘  Watcher + StateMachine + Storage)
                 │
       ┌─────────┴────────────────────┐
       ▼                              ▼
┌──────────────┐              ┌──────────────────┐
│Menubar       │              │ KeyboardShortcuts│
│Controller    │              │     .swift       │
│ + IconRender │              └──────────┬───────┘
└──────┬───────┘                         │
       │                                 │
       └────────────┬────────────────────┘
                    ▼
            ┌────────────────┐
            │ PopoverView    │
            │ ContextBuddyApp│ @main
            └────────────────┘
```

Plugin scripts depend on no Swift code. They are built and tested independently:

```
lib/project_hash.sh ─┐
lib/session_paths.sh ┤
lib/transcript.sh    ┴──► hooks/*.sh, commands/*.md
                          grader/invoke.sh
                          statusline.sh
```

---

## 2. File-by-File Outline

This confirms §3 and proposes three additions (called out inline).

### `Sources/ContextBuddyCore/`

- **`Schemas.swift`** — `Codable` value types: `Grade` (one per §4.1, used for `last.json`, history lines, and per-turn snapshots — they share a schema), `Score`, `Phase` (`pre`/`post`), `DominantSignal` enum (the four dimensions + `loop` + `context_pressure` + `null`), `FeedbackEvent` (§4.6), `SessionAnchor` (§4.4), `Config` (§4.8), `EditRecord` (for `edits.jsonl`, see §3 addition #1). Decoding ignores unknown fields (§4 rule). Phase-aware: `pollution` rationale prefix `"(carried from turn N)"` is data, not parsed specially.
- **`Watcher.swift`** — Wraps `FSEventStreamCreate` watching `~/.claude/inspector/sessions/`. Emits `(projectHash, lastJsonURL)` events. Debounces ~50 ms to coalesce atomic-rename pairs (write-temp + rename triggers two events). Re-parses `last.json` on each event; ignores partial/malformed reads.
- **`StateMachine.swift`** — Pure function `nextState(prev: BuddyState, grade: Grade, history: StateHistory, cfg: Config) -> Transition`. Implements §5 precedence and the celebrate consecutive-counter (lives in `StateHistory`). `heart` is set imperatively from `Core.recordFeedback(.ack, …)` and decays on a timer; the state machine here only handles grade-driven transitions.
- **`SessionDiscovery.swift`** — Computes `sha256(absolute_path)[:12]`. Lists `sessions/*/last.json` by mtime for MRU. Resolves "current session" as MRU unless explicitly pinned via `Core.pin(projectHash:)`.
- **`Storage.swift`** — SQLite wrapper around `state.db` (§4.7). Two writers: `recordFeedback` and `recordTransition`. Auto-creates schema. On `SQLITE_CORRUPT` or open failure, deletes file and recreates (§13). No reads in v1 — but expose `enumerateFeedback`/`enumerateTransitions` for the test suite to verify writes.
- **`Core.swift`** — `public actor BuddyCore`. Composes the above. API:
  - `subscribe() -> AsyncStream<BuddyState>`
  - `recordFeedback(action: FeedbackAction, signal: DominantSignal, scope: FeedbackScope) async`
  - `pinSession(_ hash: String?) async`
  - `currentSnapshot() async -> BuddySnapshot` (state + last grade + token usage; consumed by popover)
  - Owns the `heart` timer; reverts to grade-derived state when timer fires.
  - Hot-reloads `config.toml` on change (FSEvents on the file path).

### `Sources/ContextBuddyApp/`

- **`ContextBuddyApp.swift`** — `@main` SwiftUI `App` with a single `MenuBarExtra` (or `Settings { EmptyView() }` + `MenubarController`; see §6 risk). Owns one `BuddyCore` instance.
- **`MenubarController.swift`** — `NSStatusItem` lifecycle, button image binding, popover anchoring, right-click menu construction (§9.4), Recent Sessions submenu populated from `SessionDiscovery`.
- **`PopoverView.swift`** — Header (state + glyph), monospaced score row, optional token-economics row (only when `tokens_used/tokens_limit > 0.70` — note: this 0.70 is a **hard-coded UI constant**, not a config knob; flagged in §5 open questions), dominant rationale, action row. Hides "Mute" in `celebrate`/`heart` (§9.3).
- **`IconRendering.swift`** — `state -> (SFSymbolName, Tint, AnimationPolicy)`. Implements the §9.1 mapping. One-shot vs continuous animation handled here (uses `.symbolEffect(.bounce)` / `.wiggle, options: .repeating)` / `.pulse`). Honors `[ui].animations_enabled = false` by suppressing all motion.
- **`KeyboardShortcuts.swift`** — Local `NSEvent` monitor while popover is key: `A`/`M`/`I` per §9.5.

### `Tests/ContextBuddyCoreTests/`

- **`StateMachineTests.swift`** — Highest-priority target. See §3 below.
- **`SchemaTests.swift`** — Round-trip every type. Golden JSON files derived from §8 worked examples. Verifies unknown-field tolerance and `(carried from turn N)` rationale survives round-trip.
- **`SessionDiscoveryTests.swift`** — Project-hash determinism, MRU ordering by mtime, pinned-session override.
- **`StorageTests.swift`** *(addition — see §3 addition #2)* — Schema creation, feedback/transition inserts, corruption-recovery (delete-and-recreate), enumerate-after-write parity.

### `plugin/`

- **`plugin.json`** — Manifest declaring two hooks (`UserPromptSubmit`, `Stop`), four commands (`inspect`, `inspect_init`, `inspect_history`, `inspect_diff`), and a status line. **Per §10.4 the implementer must verify the current Claude Code plugin manifest schema at handoff time** — flagged in §5 open questions because the field names below may have evolved.
- **`hooks/user_prompt_submit.sh`** — Resolves project hash, ensures session dir, increments turn, assembles grader input, calls `grader/invoke.sh` with phase=`pre`, validates response, writes `turns/NNN-pre.json` atomically, copies to `last.json`, appends `history.jsonl`, computes `dominant_signal` mechanically (only `context_pressure` is computable pre-phase per §10.1), appends to `suggestions.md` if `attention`/`dizzy` would fire. Bash-strict (`set -euo pipefail`). Hook errors swallow to stderr — never abort the user's session (§13).
- **`hooks/stop.sh`** — Same pipeline phase=`post` plus: parse hook input for tool calls, append to `edits.jsonl`, run loop detection per §5.4, override `dominant_signal` to `"loop"` if triggered.
- **`commands/inspect.md`** — Sonnet 4.6 deep-dive prompt; output to `inspect_<turn>.md` in session dir (path **not explicit in spec — see open question Q3**).
- **`commands/inspect_init.md`** — Bootstraps `session.md` from `CLAUDE.md` if present, else interactive.
- **`commands/inspect_history.md`** — Renders timeline from `history.jsonl`.
- **`commands/inspect_diff.md`** — Diff between `turns/<a>-*.json` and `turns/<b>-*.json`.
- **`statusline.sh`** — Reads `last.json`, prints one line in <50 ms, colored leading dot per §10.2. No API calls. No process spawn beyond `cat`/`jq`.
- **`grader/system_prompt.md`** — The grader prompt I will author. Embeds §6 verbatim, specifies input bundle (§7.2), output schema with Worked Example 1 as the canonical example (§7.3), tone rules (§7.4), `dominant_signal` rules (§7.5 — grader never emits `loop`/`context_pressure`), and `summary_update` rules (§7.6). A second variant (or sibling file `inspect_system_prompt.md`) defines the deep-dive output schema for `/inspect` — see open question Q5.
- **`grader/invoke.sh`** — POSTs to Anthropic Messages API, parses strict JSON, retries once on transient error, fails silently on 4xx. Reads API key from `ANTHROPIC_API_KEY` env (open question Q4).
- **`lib/project_hash.sh`** — `printf '%s' "$PWD" | shasum -a 256 | cut -c1-12`. macOS-native (no GNU `sha256sum` dep).
- **`lib/session_paths.sh`** — All path helpers derive from `$PROJECT_HASH`. One source of truth.
- **`lib/transcript.sh`** — Sliding-window assembly. Reads `history.jsonl` tail for prior summary; reads last 3 turns from `turns/` directory verbatim (open question Q6: what does "verbatim" mean given we only have grade JSON, not raw prompts/responses?).

### Repo root

- **`Package.swift`** — Two targets (`ContextBuddyCore`, `ContextBuddyApp`), one test target, macOS 14 minimum, executable product `ContextBuddy`.
- **`README.md`** — Setup, the three §8 worked examples reproduced verbatim, a config reference.
- **`LICENSE`** — MIT.
- **`scripts/release.sh`** *(addition — implied by §12 but not in §3)* — `swift build -c release` → codesign → notarize → DMG.

### Three §3 additions, called out:

1. **`plugin/lib/edits.jsonl`** path-helper logic — §10.1 says `edits.jsonl` lives at `sessions/<hash>/edits.jsonl`, but §3 doesn't list it. Adding to `session_paths.sh`.
2. **`Tests/ContextBuddyCoreTests/StorageTests.swift`** — §3 lists three test files but §11 includes "storage" in the test scope. Adding the file.
3. **`scripts/release.sh`** — Implied by §12; not in §3. Adding.

---

## 3. Test Plan

Test scope = `ContextBuddyCore` only (§3, §11). No SwiftUI tests (§15).

### `StateMachineTests.swift` — highest priority

Each row below is one test. State machine is pure → table-driven `XCTest` with parameterized inputs.

| Test | Setup | Assert |
|---|---|---|
| `idle → attention` on confidence threshold | conf=3, others ok, default cfg | state == `attention`, dominant == `confidence` |
| `idle → attention` on atomicity | atom=3 | state == `attention`, dominant == `atomicity` |
| `idle → attention` on drift > threshold | drift=7 | state == `attention`, dominant == `drift` |
| `idle → attention` on pollution > threshold | pol=8 | state == `attention`, dominant == `pollution` |
| Attention auto-clears | prev=attention, all four within thresholds | state == `idle` |
| Celebrate fires on Nth consecutive all-≥7 | cfg.consecutive_n=5, feed 5 grades all-≥7 | grade #5 → `celebrate` |
| Celebrate counter resets on any sub-7 | feed 4 all-≥7 then one sub-7 | counter==0, no celebrate |
| Celebrate auto-decays after ~2.5 s | (use injectable clock) | reverts to derived state |
| Dizzy on `dominant_signal == "loop"` | grade with sentinel | state == `dizzy` |
| Dizzy on `dominant_signal == "context_pressure"` | grade with sentinel | state == `dizzy` |
| Dizzy clears when neither signal present | prev=dizzy, fresh grade with null | state == `idle` |
| Heart wins precedence | prev=attention, ack fired | state == `heart` for ~3 s |
| Heart reverts to derived state | after timer | state == grade-derived |
| Heart over dizzy reverts to dizzy | prev=dizzy, ack | heart for ~3 s, then `dizzy` again |
| Sleep on no events >5 min | last grade timestamp old | state == `sleep` |
| Sleep clears on next grade | feed grade after sleep | state per §5 derived |
| Busy on UserPromptSubmit without Stop | open-turn flag set | state == `busy` |
| Busy clears on matching Stop | post-grade arrives | derived state |
| Precedence: dizzy > attention | both fire | `dizzy` |
| Precedence: heart > dizzy | dizzy active, ack fired | `heart` |

**Injectable clock**: `StateMachine` and `BuddyCore` take a `protocol Clock` for timer-driven decays. Default = real, tests = manual tick.

### `SchemaTests.swift`

- Round-trip `last.json` from Worked Example 1, 2, 3 — byte-equivalent on re-encode (modulo key ordering; assert structural equality).
- Round-trip `feedback.jsonl` line.
- Round-trip `session.md` YAML (open question Q1: frontmatter delimiters or bare YAML?).
- Round-trip `config.toml` defaults.
- Unknown-field tolerance: inject `"future_field": "x"` into a `last.json` and confirm decode succeeds.
- `schema_version != 1` decodes successfully but `BuddyCore` logs warning (asserted via captured logger).

### `SessionDiscoveryTests.swift`

- `projectHash("/abs/path")` is deterministic and 12 hex chars.
- Two distinct paths produce different hashes (no collision in fixture set of 100 random paths).
- MRU returns sessions ordered by `last.json` mtime.
- Pinned session overrides MRU.
- Empty `~/.claude/inspector/sessions/` → empty MRU, no error.

### `StorageTests.swift`

- Fresh DB creates both tables with correct schema.
- `recordFeedback` then `enumerateFeedback` returns the record.
- `recordTransition` then `enumerateTransitions` returns the record.
- Open-on-corrupt-file → recreate (write 16 random bytes to `state.db`, open, verify schema).
- Concurrent writes from two tasks serialize correctly (actor guarantee).

---

## 4. Order of Work

Eight phases. Each phase ends with a green test run (where applicable) and is independently mergeable. Approximate sizing in parens.

1. **Phase A — Schemas + tests** *(small)*. Define every Codable type, golden-file tests from §8. **Locks the contract before anything else can drift.**
2. **Phase B — StateMachine + tests** *(medium)*. Pure function, injectable clock, full state-transition coverage. No I/O.
3. **Phase C — Storage + tests** *(small)*. SQLite wrapper, corruption recovery.
4. **Phase D — Watcher + SessionDiscovery + tests** *(medium)*. FSEvents, debounce, project-hash, MRU. End of phase D: `ContextBuddyCore` is feature-complete and fully tested.
5. **Phase E — Core actor + integration tests** *(small)*. Wires Watcher → StateMachine → Storage and exposes the public API. Smoke test: drop a fixture `last.json` into a temp dir, observe `BuddyState` stream.
6. **Phase F — Menubar plumbing** *(medium)*. `NSStatusItem`, icon rendering, glyph swap on state change. No popover yet — verify by visual smoke (state changes flip the icon). Manual verification only (§15).
7. **Phase G — Popover + keyboard + right-click menu** *(medium-large)*. Full §9 contract. Manual verification.
8. **Phase H — Plugin scripts + grader prompt** *(large)*. Bash hooks, status line, slash commands, grader system prompt with §6 verbatim, `invoke.sh`. End-to-end smoke test inside Claude Code.
9. **Phase I — Integration + release** *(small-medium)*. End-to-end manual run of all three §8 worked examples. `scripts/release.sh`. README.

**Why this order**: schemas first means every later phase can rely on the wire format. State machine before watcher means we can unit-test transitions without filesystem complexity. Plugin scripts last means we exercise the full pipeline only after the buddy is known-correct — this prevents the failure mode where buddy bugs are misattributed to plugin bugs (and vice versa).

**Parallelism**: phases C and D can run in parallel after B. Phases F and H can run in parallel after E (if two implementers).

---

## 5. Open Questions

These are genuine spec ambiguities. I am not inventing answers; I am surfacing them for review.

**Q1 — `session.md` format: bare YAML or YAML frontmatter?** §4.4 says "human-authored YAML frontmatter only (no body)" and shows a YAML block with no `---` delimiters. Frontmatter conventionally requires `---` fences. Decision needed: do hooks/grader expect `---\n<yaml>\n---\n`, or just YAML? Affects parser choice in `transcript.sh` and `Schemas.swift`.

**Q2 — `dominant_signal` precedence when multiple dimensions cross thresholds.** §4.1 says it's set to "the dimension whose threshold cross drove a state change", but if (say) confidence=3 *and* atomicity=3 both cross, which wins? The spec doesn't define a precedence among the four dimensions. Suggested default: ordered as `atomicity > confidence > drift > pollution` (atomicity is the most-actionable per §6 prose), but I want confirmation.

**Q3 — Output path for `/inspect` deep-dive (`inspect_<turn>.md`).** §10.3 mentions the filename but not the directory. Most natural: `~/.claude/inspector/sessions/<hash>/inspect_<turn>.md`. Confirm.

**Q4 — Anthropic API key sourcing in plugin scripts.** Spec doesn't specify. Default: `ANTHROPIC_API_KEY` env var, fail silently with stderr log if absent. If the user expects `~/.claude/auth` or a Claude Code-managed credential, the hook script changes.

**Q5 — `/inspect` deep-dive output schema.** §7 says "this is a separate output schema and should be documented as a v1 deliverable" but doesn't define the fields beyond a `deep_analysis` string. Proposed: same as §4.1 plus `deep_analysis: string` (multi-paragraph) and an array `recommendations: [{title, rationale, suggested_prompt?}]`. Confirm or specify.

**Q6 — "Last 3 turns verbatim" — verbatim what?** §7.2 says the grader gets "last 3 turns verbatim" but the only artifact stored is grade JSON. Are we storing raw prompt+response text somewhere not specified? Options: (a) the grader gets the last 3 grade JSONs as proxy; (b) the hook captures and stores raw prompt/response into `turns/NNN-raw.json` (a new file not in §3); (c) the hook input from Claude Code already contains the recent transcript, so we don't store it. Affects `turns/` schema.

**Q7 — Token-economics row threshold (0.70).** §9.3 hard-codes "0.70" but `[thresholds]` in §4.8 has no `token_row_pct`. Should this be configurable? I'll default to a `let` constant in `PopoverView` unless told otherwise.

**Q8 — `loop_edits_in_window` of `loop_window_turns`.** Defaults are both 3. So "3 of last 3" — Worked Example 3 confirms this. But §10.1 says `edits.jsonl` keeps "last 5 turns × edited files" — why 5 if loop window default is 3? Future-proofing? Confirm we cap at 5 regardless of `loop_window_turns`, or grow with config.

**Q9 — Sleep → first event transition.** §5.1 says sleep clears "when next grade event arrives". A `pre` grade fires `busy` (open turn) and a `post` grade fires whatever the scores indicate. Confirm: sleep + new pre-grade ⇒ `busy`, sleep + new post-grade ⇒ `idle`/`attention`/`celebrate`/`dizzy` per derivation.

**Q10 — Status-line color encoding.** §10.2 implies a colored dot. Bash status-line scripts in Claude Code typically use ANSI escapes — confirm the host's status-line rendering supports ANSI 256-color or just emoji glyphs.

**Q11 — Concurrent hook invocations.** What guarantees, if any, does Claude Code give about hook concurrency? `last.json` and `history.jsonl` writes need an exclusive lock if hooks can race. Default: `flock` on a sidecar lockfile in the session dir.

**Q12 — Plugin manifest schema currency.** Per §10.4 / §15, the manifest format may have evolved. I will treat `plugin.json` as a stub during plan review and finalize it during Phase H against current Claude Code docs at that time.

---

## 6. Risks and Mitigations

**R1 — FSEvents debouncing.** Atomic-rename writes (`temp + rename`) generate paired events. Without debounce, the parser sees a partial state. *Mitigation*: 50 ms coalescing window in `Watcher.swift`. If a parse fails, retry once after 25 ms before logging.

**R2 — SwiftUI menubar quirks on macOS 14.** `MenuBarExtra` has had popover-positioning bugs across 13/14/15. Right-click menus are awkward. *Mitigation*: use `NSStatusItem` + `NSPopover` directly (not `MenuBarExtra`) for predictable behavior. Cost: more imperative AppKit code but matches the §9 contract precisely.

**R3 — Symbol-effect support.** `.wiggle` requires SF Symbols 5 (macOS 14.0+). `.bounce` requires 14.0+. Verify on minimum target before depending on either.

**R4 — Strict JSON from Haiku.** Haiku occasionally wraps output in markdown fences despite instructions. *Mitigation*: `invoke.sh` strips a leading ```` ```json ```` / trailing ``` if present before parsing, and validates against the schema. On parse failure, log + skip per §13.

**R5 — Turn numbering races under multi-clauding.** Two Claude Code sessions in the same project would both read `max(turn) + 1` and collide. *Mitigation*: project-hash includes `$PWD` (one Claude per cwd in practice), plus `flock` on `sessions/<hash>/.turn.lock` during increment (R11).

**R6 — `session.md` not present.** §13 says grader notes absence and produces advisory grades. *Mitigation*: the grader prompt explicitly handles this branch; flagged rationales include `"session.md not found"` so the buddy can dim or annotate.

**R7 — SQLite from Swift.** No first-party Swift SQLite. *Mitigation*: use the system `libsqlite3` via a thin C-bridge target (`import SQLite3`). Avoid SPM SQLite packages — they bloat the binary and complicate notarization.

**R8 — Notarization hardening.** Non-sandboxed apps still need hardened runtime + entitlements (network client for FSEvents is not needed — but SQLite file access is). *Mitigation*: minimal entitlements (no network for the Swift app per §15, file access default). `scripts/release.sh` runs `notarytool` with explicit timeout + staple.

**R9 — `LSUIElement` + popover focus stealing.** macOS sometimes raises an LSUIElement to foreground when a popover opens. *Mitigation*: `NSPopover.behavior = .transient` and explicitly `NSApp.activate(ignoringOtherApps: false)` is *not* called.

**R10 — Hot-reload of `config.toml` during a state evaluation.** Race between watcher reading new thresholds mid-evaluation. *Mitigation*: `BuddyCore` snapshots `Config` once per grade event; reload swaps the snapshot atomically for the next event.

**R11 — Concurrent file writes from two hooks.** See R5 + Q11. *Mitigation*: `flock -x sessions/<hash>/.write.lock` around `last.json` / `history.jsonl` mutation in both hook scripts.

**R12 — Bash on macOS is bash 3.2.** `set -u` + arrays + `mapfile` differ from bash 4. *Mitigation*: target `/bin/sh`-portable POSIX where possible; explicit `#!/usr/bin/env bash` and use only bash-3.2 features. No `mapfile`.

**R13 — Spec/§15 conflict candidates.** Two soft tensions found, neither rises to "real conflict" but flagging:
  - §4.1 says `dominant_signal` may be `"loop"`/`"context_pressure"`, while §7.5 forbids the *grader* from setting them. Resolution: the *plugin* sets them post-grader — consistent, but worth confirming the grader prompt's instruction wording is unambiguous.
  - §9.3 hard-codes a 0.70 token threshold not present in §4.8. Resolution: hard-coded constant (Q7), no behavioral conflict, but worth confirming intent.

---

## 7. Verification (end-to-end)

1. **Unit**: `swift test` — all `ContextBuddyCore` tests green.
2. **Plugin smoke (no buddy)**: install plugin into a fresh Claude Code workspace, run a 3-turn session, verify `last.json`, `history.jsonl`, `turns/NNN-{pre,post}.json`, `suggestions.md` all populate per §8 examples. Run `statusline.sh` standalone and confirm <50 ms wall clock.
3. **Buddy smoke (no plugin)**: launch the app with no `~/.claude/inspector/` present. Verify menubar shows `sleep`, no errors. Create the directory, drop a fixture `last.json`, verify state changes.
4. **Full end-to-end**: reproduce each §8 worked example by hand:
   - Example 1 (attention/atomicity): paste the worked-example prompt, verify icon → orange triangle, popover content matches §8.1, suggestion log entry matches §8.1.
   - Example 2 (celebrate): script 5 consecutive all-≥7 grades into `history.jsonl` + `last.json`, verify `sparkles` bounce + popover.
   - Example 3 (dizzy/loop): script 3 consecutive `edits.jsonl` entries for the same file, verify `dominant_signal=loop` set by `stop.sh`, verify wiggle animation.
5. **Failure-mode probes per §13**: malformed `last.json`, missing `session.md`, API rate-limit response (mock), `state.db` corruption (write garbage to file then launch).
6. **Notarization**: run `scripts/release.sh`, install resulting DMG on a clean Mac, verify Gatekeeper opens cleanly without right-click-bypass.

---

## 8. What this plan does NOT do

Per §15 and §11:
- No preferences UI.
- No SwiftUI tests.
- No Anthropic API calls from Swift.
- No persistent (cross-session) mute scope.
- No notifications, sounds, or focus stealing.
- No telemetry.

End of plan. Awaiting review per §14 / §15.

---

## 9. Decisions Log (post-review)

Resolutions to §5 Open Questions and §6 R13, recorded after plan approval.

| # | Decision |
|---|---|
| Q1 | `session.md` uses **YAML frontmatter with `---` fences** (`---\n<yaml>\n---\n`). Plugin and any consumer parse the fenced YAML block. |
| Q2 | `dominant_signal` precedence among the four scored dimensions when multiple cross thresholds: **`atomicity > confidence > drift > pollution`**. Plugin computes mechanically. |
| Q3 | `/inspect` deep-dive output written to **`~/.claude/inspector/sessions/<hash>/inspect_<turn>.md`**. |
| Q4 | API auth uses the **Claude Code-managed credential** (not `ANTHROPIC_API_KEY`). `grader/invoke.sh` invokes whatever Claude Code exposes for plugin auth at handoff time; Phase H will finalize the exact mechanism. |
| Q5 | `/inspect` deep-dive schema = §4.1 fields + `deep_analysis: string` + `recommendations: [{title, rationale, suggested_prompt?}]`. |
| Q6 | "Last 3 turns verbatim" comes from **the Claude Code hook input transcript**. We do **not** add a new `turns/NNN-raw.json` artifact. Hook scripts pull the trailing window from the transcript provided by the hook payload. |
| Q7 | Token-economics row threshold is **configurable**. Add `token_row_pct = 70` to `[ui]` in `config.toml` (default 70). `Config` struct exposes it. |
| Q8 | `edits.jsonl` retention window matches `loop_window_turns` (default 3) — **not 5**. Plugin trims `edits.jsonl` to last `loop_window_turns` entries on each post-Stop write. |
| Q9 | Sleep clears per derivation: pre-grade ⇒ `busy`; post-grade ⇒ derived state. Confirmed. |
| Q10 | Status line uses **ANSI color codes** for the leading dot (e.g., `\033[32m●\033[0m` for green). `statusline.sh` emits ANSI directly. |
| Q11 | **Decision: `mkdir`-based mutex with bounded poll-and-retry** (macOS lacks GNU `flock` by default; portable `mkdir <dir>` is atomic on local filesystems and works on bash 3.2). Concrete pattern in `lib/session_paths.sh`: `acquire_lock <name>` busy-waits with 50 ms sleep up to 2 s, releases via `trap`. Used around `last.json` / `history.jsonl` / `edits.jsonl` mutations and the turn-number increment. |
| Q12 | Plugin manifest deferred to Phase H against current Claude Code docs. Confirmed. |
| R13 §4.1↔§7.5 | Plugin sets `loop` / `context_pressure` sentinels post-grader. Grader prompt explicitly forbids emitting them. Confirmed. |
| R13 §9.3 | Configurable per Q7 (was previously framed as hard-coded). |
| Q13 | §5.5 says celebrate fires on "all four scores ≥7", but §8.2 (canonical example) fires celebrate with `drift=1` and `pollution=3` — those dimensions are inverted (low = good per §6 rubric). **Decision (post-review confirmation): celebrate zone is confidence/atomicity ≥ 7 AND drift/pollution ≤ 3.** Locked in `StateMachine.highSideThreshold` / `lowSideThreshold`. |
| §15 / minimum macOS | Bumped from macOS 14 to **macOS 15** so that `.symbolEffect(.wiggle, .repeating)` per §9.1 works literally (no fallback). §15 forbade fallbacks for older macOS; bumping the minimum satisfies both rules. `Package.swift` and tools-version updated accordingly. |
| §9.1 animations (post-review) | All seven state animations now use the §9.1-literal SF Symbol effects: `.bounce` for attention's "300ms scale pulse" (closest scale-flavored one-shot), `.bounce` for celebrate, `.wiggle, .repeating` for dizzy, `.pulse` for heart, `.rotate, .repeating` for busy. |
| Q4 (re-resolved) | The Claude Code-managed credential is **not accessible to subprocess hooks**. `claude --bare` (the only flag set that gives an isolated, non-recursive grader call) explicitly requires `ANTHROPIC_API_KEY` and refuses to read OAuth/keychain. **Decision: invoke.sh requires `ANTHROPIC_API_KEY`** and skips grading with a clear error message when absent, per §13's "log and skip" pattern. The original Q4 answer ("use Claude Code managed credential") is not implementable; users must set the env var to enable grading. |
| MenubarController init | Refactored to async factory `MenubarController.create()` invoked from `AppDelegate.applicationDidFinishLaunching`. Removed the `DispatchSemaphore` blocking init pattern that was both a Swift 6 data race and a deadlock risk. |
| `inspectorRoot` plumbing | `MenubarController` now carries `inspectorRoot` and uses it consistently for the right-click "Recent sessions", "Open inspector folder", and "Preferences" menu items, instead of hard-coding `SessionDiscovery.defaultRoot`. |
| Hook recursion guard | `CONTEXTBUDDY_SKIP=1` env var is checked at the top of both hooks; defensive given that `claude --bare` skips hooks anyway, but cheap insurance against future CLI changes. |

These decisions are inputs to Phases A–I. Future sessions implementing this plan should treat the table above as authoritative.

