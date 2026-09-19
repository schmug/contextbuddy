#!/usr/bin/env bash
# user_prompt_submit — fired by Claude Code on every UserPromptSubmit.
#
# Pipeline (SPEC.md §10.1):
#   1. Resolve project hash from the canonical (symlink-resolved) $PWD.
#   2. Ensure session dir exists.
#   3. Read hook payload from stdin.
#   4. Determine current turn = max(turns/) + 1.
#   5. Assemble grader input (session.md, latest prompt, the last N typed prompts
#      (N = [grader] sliding_window_turns, default 3) and token count from the
#      JSONL transcript at hook.transcript_path, prior summary, edited files).
#   6. Call grader/invoke.sh with phase=pre.
#   7. Validate response conforms to §4.1.
#   8. Mechanically compute dominant_signal (only context_pressure is
#      computable on pre-phase per §10.1 — loop requires post edit history).
#   9. Atomically write turns/NNN-pre.json, copy to last.json, append to
#      history.jsonl.
#  10. If state would transition to attention/dizzy, append section to
#      suggestions.md.
#
# Errors are swallowed to stderr — never abort the user's session (§13).

set -uo pipefail

# Recursion guard: invoke.sh sets CONTEXTBUDDY_SKIP=1 when calling `claude`
# for grader inference. Without this, every grader call would re-trigger
# UserPromptSubmit and infinitely recurse.
if [ -n "${CONTEXTBUDDY_SKIP:-}" ]; then
  exit 0
fi

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/project_hash.sh
. "$PLUGIN_ROOT/lib/project_hash.sh"
# shellcheck source=../lib/session_paths.sh
. "$PLUGIN_ROOT/lib/session_paths.sh"
# shellcheck source=../lib/transcript.sh
. "$PLUGIN_ROOT/lib/transcript.sh"
# shellcheck source=../lib/dotenv.sh
. "$PLUGIN_ROOT/lib/dotenv.sh"
# shellcheck source=../lib/config.sh
. "$PLUGIN_ROOT/lib/config.sh"
# shellcheck source=../lib/job.sh
. "$PLUGIN_ROOT/lib/job.sh"

log_err() { printf 'contextbuddy: %s\n' "$1" >&2; }

# Canonical (symlink-resolved) project path, so /tmp/x and /private/tmp/x land in
# one session dir whichever form Claude Code hands this hook (issue #4).
PROJECT_PATH="$(canonical_project_path "$PWD")"
PROJECT_HASH="$(project_hash "$PROJECT_PATH")"
ensure_session_dir "$PROJECT_HASH"

# Record the project path for the buddy's popover project footer row (issue #38).
# Deliberately the same canonical string that was just hashed (SPEC.md §4.9), so
# the recorded path and the session dir name can never name different projects.
# Non-fatal per §13.
write_session_meta "$PROJECT_HASH" "$PROJECT_PATH" 2>/dev/null \
  || log_err "could not write meta.json; popover falls back to the project hash"

# Read hook payload (Claude Code passes JSON on stdin).
HOOK_PAYLOAD="$(cat || true)"

# Acquire writer lock for the duration of the turn-numbering increment +
# file writes.
if ! acquire_lock "$PROJECT_HASH" "write"; then
  log_err "could not acquire write lock; skipping grade"
  exit 0
fi
trap 'release_lock "$PROJECT_HASH" "write"' EXIT

TURN="$(next_turn_number "$PROJECT_HASH")"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Jev shadow grader (Request A). Advisory, async, acts on nothing. Spawned detached
# BEFORE the Haiku call so the two run concurrently; the child polls for the Haiku
# turn file (turns/NNN-pre.json) to copy its scores into the shadow row it writes
# (turns/NNN-pre.jev.json + jev.jsonl). Nothing below this block changes: on any
# failure here the Haiku grade proceeds exactly as before. Key comes from
# TYPESAFE_API_KEY or a .env (lib/dotenv.sh) and is passed only via the child's env.
# CONTEXTBUDDY_JEV_RUNNER overrides the runner for tests.
spawn_jev_shadow() {
  local key="${TYPESAFE_API_KEY:-}"
  [ -n "$key" ] || key="$(dotenv_value TYPESAFE_API_KEY || true)"
  [ -n "$key" ] || return 0
  local script="$PLUGIN_ROOT/grader/jev_shadow.py"
  local cmd
  if [ -n "${CONTEXTBUDDY_JEV_RUNNER:-}" ]; then
    [ -x "$CONTEXTBUDDY_JEV_RUNNER" ] || return 0
    cmd=("$CONTEXTBUDDY_JEV_RUNNER")
  else
    local uv
    uv="$(command -v uv 2>/dev/null || true)"
    [ -z "$uv" ] && [ -x "$HOME/.local/bin/uv" ] && uv="$HOME/.local/bin/uv"
    if [ -n "$uv" ]; then
      cmd=("$uv" run -q --script "$script")
    elif python3 -c 'import typesafe_sdk' >/dev/null 2>&1; then
      cmd=(python3 "$script")
    else
      return 0
    fi
  fi
  local payload_file
  payload_file="$(mktemp "${TMPDIR:-/tmp}/contextbuddy-jev.XXXXXX")" || return 0
  printf '%s' "$HOOK_PAYLOAD" > "$payload_file"
  local sdir
  sdir="$(session_dir "$PROJECT_HASH")"
  TYPESAFE_API_KEY="$key" nohup "${cmd[@]}" \
    --payload "$payload_file" \
    --turn "$TURN" \
    --timestamp "$TIMESTAMP" \
    --project-hash "$PROJECT_HASH" \
    --session-dir "$sdir" \
    --system-prompt "$PLUGIN_ROOT/grader/system_prompt.md" \
    </dev/null >>"$sdir/jev.log" 2>&1 &
  disown 2>/dev/null || true
}
spawn_jev_shadow || true

# Read config; fall back to defaults silently per §13.
CONFIG_PATH="$(config_path)"
GRADER_MODEL="$(toml_get_section_key "$CONFIG_PATH" "grader" "model")"
GRADER_MODEL="${GRADER_MODEL:-claude-haiku-4-5-20251001}"
CONTEXT_PRESSURE_PCT="$(toml_get_section_int "$CONFIG_PATH" "thresholds" "context_pressure_pct" 85)"

# Turn window and token count come from the JSONL transcript at hook.transcript_path;
# the payload carries neither (issue #9, lib/transcript.sh). The window is the
# [grader] sliding_window_turns the typesafe job also reads (lib/job.sh), default 3.
# The current prompt is dropped from the window when the harness already appended it.
# A missing or unreadable transcript is an empty window plus a stderr warning, never
# a skip.
WINDOW_TURNS="$(toml_get_section_int "$CONFIG_PATH" "grader" "sliding_window_turns" 3)"
TRANSCRIPT_PATH="$(transcript_path_from_hook_payload "$HOOK_PAYLOAD")"
CURRENT_PROMPT="$(printf '%s' "$HOOK_PAYLOAD" | jq -r '.prompt // ""' 2>/dev/null || true)"
WINDOW_JSON="$(transcript_window "$TRANSCRIPT_PATH" "$WINDOW_TURNS" "$CURRENT_PROMPT")"
TOKENS_USED_TX="$(tokens_used_from_window "$WINDOW_JSON")"

# Context window for this session (issue #47, lib/context_window.sh): model from the
# transcript tail, limit from the override / auto-compact window / model table, floored
# against the transcript count above so used <= limit always. Resolved once: the
# "## tokens" line the LLM backends copy, the typesafe job and the grade written below
# all carry this one pair.
CTX="$(resolve_context_window "$TRANSCRIPT_PATH" "$TOKENS_USED_TX")"
TOKENS_LINE="$(tokens_line_from_context "$CTX")"

# Assemble grader input bundle.
INPUT_FILE="$(mktemp)"
JOB_FILE="$(mktemp)"
trap 'rm -f "$INPUT_FILE" "$JOB_FILE"; release_lock "$PROJECT_HASH" "write"' EXIT
{
  printf '## session.md\n```yaml\n'
  read_session_md "$PROJECT_HASH"
  printf '\n```\n\n'
  printf '## phase\npre\n\n'
  printf '## turn\n%s\n\n' "$TURN"
  printf '## timestamp\n%s\n\n' "$TIMESTAMP"
  printf '## prior summary\n%s\n\n' "$(prior_summary "$PROJECT_HASH")"
  printf '## tokens\n%s\n\n' "$TOKENS_LINE"
  printf '## last %s turns (from hook transcript)\n```json\n%s\n```\n\n' \
    "$WINDOW_TURNS" "$(prompts_from_window "$WINDOW_JSON")"
  printf '## files edited in last 5 turns\n```json\n%s\n```\n\n' \
    "$(files_edited_recent "$PROJECT_HASH" 5)"
  printf '## latest prompt\n%s\n' "$HOOK_PAYLOAD"
} > "$INPUT_FILE"

# Job file for the typesafe backend (grader/jev.mjs reads it on stdin; other
# backends ignore it). A build failure leaves {} so the grader exits 2 and
# this hook logs and skips, never blocks.
build_job "pre" "$TURN" "$TIMESTAMP" "$HOOK_PAYLOAD" \
  "$(session_md_path "$PROJECT_HASH")" "$(history_jsonl_path "$PROJECT_HASH")" "$CONFIG_PATH" "$CTX" \
  > "$JOB_FILE" 2>/dev/null || printf '{}' > "$JOB_FILE"

# Call grader. Failures here are non-fatal.
GRADE_JSON="$(CONTEXTBUDDY_JOB="$JOB_FILE" "$PLUGIN_ROOT/grader/invoke.sh" \
  "$PLUGIN_ROOT/grader/system_prompt.md" \
  "$INPUT_FILE" \
  "$GRADER_MODEL" \
  "$CONFIG_PATH" 2>/dev/null || true)"

if [ -z "$GRADE_JSON" ]; then
  log_err "grader returned no output for turn $TURN; skipping"
  exit 0
fi

# Validate JSON structure if jq is available.
if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$GRADE_JSON" | jq -e '
    .schema_version == 1
    and (.scores.confidence.value | type == "number")
    and (.scores.atomicity.value | type == "number")
    and (.scores.drift.value | type == "number")
    and (.scores.pollution.value | type == "number")
  ' >/dev/null 2>&1; then
    log_err "grade output failed schema validation; skipping"
    exit 0
  fi

  # One document per line (issue #26): LLM backends emit whatever the model printed and
  # Haiku pretty-prints, while history.jsonl readers take the last line (lib/job.sh prior
  # pollution, lib/transcript.sh prior_summary). Compact once here so every write below,
  # override or not, is a single line.
  GRADE_JSON="$(printf '%s' "$GRADE_JSON" | jq -c .)"

  # dominant_signal is model output. SPEC §4.1 allows exactly four dimension names plus the
  # two mechanical sentinels or null; anything else is cleared here so a prompt-injected
  # grader cannot steer the suggestions lookup below (the string used to be spliced into a
  # jq program, which turned it into code).
  DOM_RAW="$(printf '%s' "$GRADE_JSON" | jq -r '.dominant_signal // empty')"
  case "$DOM_RAW" in
    ''|confidence|atomicity|drift|pollution|loop|context_pressure) ;;
    *)
      log_err "dominant_signal not one of the allowed values; cleared"
      GRADE_JSON="$(printf '%s' "$GRADE_JSON" | jq -c '.dominant_signal = null')"
      ;;
  esac

  # Token economics are measured by the plugin, not the grader (SPEC.md §5.4): tokens_used
  # from the transcript (lib/transcript.sh), tokens_limit per session model with the
  # evidence floor (lib/context_window.sh, issue #47). When the transcript carries no
  # usage yet (count 0) the grader's tokens_used stands and the floor is re-applied
  # against it, so no grade is ever written with tokens_used > tokens_limit. All four
  # fields are stamped in one jq call so they can never disagree; `NEW=... &&
  # GRADE_JSON=$NEW` keeps the validated grade if jq fails rather than leaving GRADE_JSON
  # empty, which would write an empty last.json, turn file and history line.
  TOKENS_USED="$TOKENS_USED_TX"
  [ "$TOKENS_USED" -gt 0 ] 2>/dev/null || TOKENS_USED="$(printf '%s' "$GRADE_JSON" | jq -r '.tokens_used // 0')"
  case "$TOKENS_USED" in ''|*[!0-9]*) TOKENS_USED=0 ;; esac
  CTX_MODEL="$(printf '%s' "$CTX" | jq -r '.model // empty')"
  # shellcheck disable=SC2046  # two space-separated words by construction
  set -- $(context_window_floor "$TOKENS_USED" "$(printf '%s' "$CTX" | jq -r '.tokens_limit')" "$(printf '%s' "$CTX" | jq -r '.limit_source')")
  TOKENS_LIMIT="$1"; LIMIT_SOURCE="$2"
  NEW="$(printf '%s' "$GRADE_JSON" | jq -c \
    --argjson used "$TOKENS_USED" --argjson lim "$TOKENS_LIMIT" --arg src "$LIMIT_SOURCE" --arg model "$CTX_MODEL" \
    '.tokens_used = $used | .tokens_limit = $lim | .limit_source = $src
     | .model = (if $model == "" then null else $model end)' 2>/dev/null)" \
    && [ -n "$NEW" ] && GRADE_JSON="$NEW"

  # Mechanically compute dominant_signal for context_pressure on pre-phase.
  if [ "$TOKENS_LIMIT" -gt 0 ] && \
     [ "$(( TOKENS_USED * 100 / TOKENS_LIMIT ))" -gt "$CONTEXT_PRESSURE_PCT" ]; then
    GRADE_JSON="$(printf '%s' "$GRADE_JSON" | jq -c '.dominant_signal = "context_pressure"')"
  fi
fi

# Write atomically.
TURN_PATH="$(turn_file_path "$PROJECT_HASH" "$TURN" "pre")"
LAST_PATH="$(last_json_path "$PROJECT_HASH")"
HISTORY_PATH="$(history_jsonl_path "$PROJECT_HASH")"

printf '%s\n' "$GRADE_JSON" | atomic_write "$TURN_PATH"
printf '%s\n' "$GRADE_JSON" | atomic_write "$LAST_PATH"
printf '%s\n' "$GRADE_JSON" >> "$HISTORY_PATH"

# Append suggestion if state would be attention or dizzy.
if command -v jq >/dev/null 2>&1; then
  DOMINANT="$(printf '%s' "$GRADE_JSON" | jq -r '.dominant_signal // empty')"
  if [ -n "$DOMINANT" ]; then
    SUGG_PATH="$(suggestions_md_path "$PROJECT_HASH")"
    {
      printf '\n## Turn %s — %s — %s\n\n' "$TURN" "$TIMESTAMP" "$DOMINANT"
      printf '**Phase**: pre\n\n'
      RATIONALE="$(printf '%s' "$GRADE_JSON" | jq -r --arg d "$DOMINANT" '.scores[$d].rationale // .summary_update')"
      printf '**Issue**: %s\n\n' "$RATIONALE"
      printf 'Status: open\n'
    } >> "$SUGG_PATH"
  fi
fi

exit 0
