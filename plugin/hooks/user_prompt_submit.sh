#!/usr/bin/env bash
# user_prompt_submit — fired by Claude Code on every UserPromptSubmit.
#
# Pipeline (SPEC.md §10.1):
#   1. Resolve project hash from $PWD.
#   2. Ensure session dir exists.
#   3. Read hook payload from stdin.
#   4. Determine current turn = max(turns/) + 1.
#   5. Assemble grader input (session.md, latest prompt, last 3 turns
#      verbatim from hook payload, prior summary, tokens, edited files).
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

PROJECT_HASH="$(project_hash "$PWD")"
ensure_session_dir "$PROJECT_HASH"

# Record the project path for the buddy's popover project footer row (issue #38).
# Deliberately the same "$PWD" that was just hashed, so the recorded path and the
# session dir name can never name different projects. Non-fatal per §13.
write_session_meta "$PROJECT_HASH" "$PWD" 2>/dev/null \
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
  printf '## tokens\n%s\n\n' "$(tokens_from_hook_payload "$HOOK_PAYLOAD")"
  printf '## last 3 turns (from hook transcript)\n```json\n%s\n```\n\n' \
    "$(recent_turns_from_hook_payload "$HOOK_PAYLOAD" 3)"
  printf '## files edited in last 5 turns\n```json\n%s\n```\n\n' \
    "$(files_edited_recent "$PROJECT_HASH" 5)"
  printf '## latest prompt\n%s\n' "$HOOK_PAYLOAD"
} > "$INPUT_FILE"

# Job file for the typesafe backend (grader/jev.mjs reads it on stdin; other
# backends ignore it). A build failure leaves {} so the grader exits 2 and
# this hook logs and skips, never blocks.
build_job "pre" "$TURN" "$TIMESTAMP" "$HOOK_PAYLOAD" \
  "$(session_md_path "$PROJECT_HASH")" "$(history_jsonl_path "$PROJECT_HASH")" "$CONFIG_PATH" \
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

  # Mechanically compute dominant_signal for context_pressure on pre-phase.
  TOKENS_USED="$(printf '%s' "$GRADE_JSON" | jq -r '.tokens_used // 0')"
  TOKENS_LIMIT="$(printf '%s' "$GRADE_JSON" | jq -r '.tokens_limit // 200000')"
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
      RATIONALE="$(printf '%s' "$GRADE_JSON" | jq -r ".scores.${DOMINANT}.rationale // .summary_update")"
      printf '**Issue**: %s\n\n' "$RATIONALE"
      printf 'Status: open\n'
    } >> "$SUGG_PATH"
  fi
fi

exit 0
