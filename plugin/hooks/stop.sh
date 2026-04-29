#!/usr/bin/env bash
# stop — fired by Claude Code on every Stop (turn completion).
#
# Same pipeline as user_prompt_submit.sh but with phase=post and the
# additional responsibilities listed in §10.1:
#   - parse hook input for tool calls, append to edits.jsonl
#   - run loop detection per §5.4
#   - override dominant_signal to "loop" if triggered

set -uo pipefail

# Recursion guard. See note in user_prompt_submit.sh.
if [ -n "${CONTEXTBUDDY_SKIP:-}" ]; then
  exit 0
fi

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN_ROOT/lib/project_hash.sh"
. "$PLUGIN_ROOT/lib/session_paths.sh"
. "$PLUGIN_ROOT/lib/transcript.sh"

log_err() { printf 'contextbuddy: %s\n' "$1" >&2; }

PROJECT_HASH="$(project_hash "$PWD")"
ensure_session_dir "$PROJECT_HASH"

HOOK_PAYLOAD="$(cat || true)"

if ! acquire_lock "$PROJECT_HASH" "write"; then
  log_err "could not acquire write lock; skipping grade"
  exit 0
fi

INPUT_FILE="$(mktemp)"
cleanup() {
  rm -f "$INPUT_FILE"
  release_lock "$PROJECT_HASH" "write"
}
trap cleanup EXIT

# Turn number = current max (post matches the pre we just wrote).
LAST_PRE="$(ls -1 "$(turns_dir "$PROJECT_HASH")" 2>/dev/null \
  | grep -E '^[0-9]{3}-pre\.json$' \
  | sort -n | tail -1 | cut -c1-3)"
TURN="${LAST_PRE:-1}"
TURN="$((10#$TURN))"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Append edited files to edits.jsonl. Q8 decision: keep last loop_window_turns
# (default 3) entries.
EDITS_PATH="$(edits_jsonl_path "$PROJECT_HASH")"
LOOP_WINDOW="3"
LOOP_EDITS_IN_WINDOW="3"
CONFIG_PATH="$(config_path)"
GRADER_MODEL="claude-haiku-4-5-20251001"
CONTEXT_PRESSURE_PCT="85"
if [ -f "$CONFIG_PATH" ]; then
  LOOP_WINDOW="$(grep -E '^loop_window_turns[[:space:]]*=' "$CONFIG_PATH" | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' || echo 3)"
  LOOP_WINDOW="${LOOP_WINDOW:-3}"
  LOOP_EDITS_IN_WINDOW="$(grep -E '^loop_edits_in_window[[:space:]]*=' "$CONFIG_PATH" | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' || echo 3)"
  LOOP_EDITS_IN_WINDOW="${LOOP_EDITS_IN_WINDOW:-3}"
  GRADER_MODEL="$(grep -E '^model[[:space:]]*=' "$CONFIG_PATH" | head -1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' || true)"
  GRADER_MODEL="${GRADER_MODEL:-claude-haiku-4-5-20251001}"
  CONTEXT_PRESSURE_PCT="$(grep -E '^context_pressure_pct[[:space:]]*=' "$CONFIG_PATH" | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' || true)"
  CONTEXT_PRESSURE_PCT="${CONTEXT_PRESSURE_PCT:-85}"
fi

if command -v jq >/dev/null 2>&1; then
  EDITED_FILES_JSON="$(printf '%s' "$HOOK_PAYLOAD" | jq -c '
    [
      (.tool_calls // .turn.tool_calls // [])[]?
      | select((.name // "") | test("(Edit|Write|MultiEdit)"; "i"))
      | (.input.file_path // .input.path // empty)
    ] | unique
  ' 2>/dev/null || printf '[]')"
  EDIT_RECORD="$(jq -c -n --arg ts "$TIMESTAMP" --argjson turn "$TURN" --argjson files "$EDITED_FILES_JSON" \
    '{ts: $ts, turn: $turn, files: $files}')"
  printf '%s\n' "$EDIT_RECORD" >> "$EDITS_PATH"

  # Trim edits.jsonl to last LOOP_WINDOW entries (Q8).
  if [ -f "$EDITS_PATH" ]; then
    TRIMMED="$(tail -n "$LOOP_WINDOW" "$EDITS_PATH")"
    printf '%s\n' "$TRIMMED" > "$EDITS_PATH"
  fi
fi

# Loop detection: if any single file path appears in LOOP_EDITS_IN_WINDOW of
# the last LOOP_WINDOW edit records, set loop sentinel.
LOOP_DETECTED="false"
if [ -f "$EDITS_PATH" ] && command -v jq >/dev/null 2>&1; then
  REPEAT_COUNT="$(tail -n "$LOOP_WINDOW" "$EDITS_PATH" | jq -s '
    [.[].files[]?] | group_by(.) | map(length) | max // 0
  ' 2>/dev/null)"
  if [ -n "$REPEAT_COUNT" ] && [ "$REPEAT_COUNT" -ge "$LOOP_EDITS_IN_WINDOW" ]; then
    LOOP_DETECTED="true"
  fi
fi

# Assemble grader input.
{
  printf '## session.md\n```yaml\n'
  read_session_md "$PROJECT_HASH"
  printf '\n```\n\n'
  printf '## phase\npost\n\n'
  printf '## turn\n%s\n\n' "$TURN"
  printf '## timestamp\n%s\n\n' "$TIMESTAMP"
  printf '## prior summary\n%s\n\n' "$(prior_summary "$PROJECT_HASH")"
  printf '## tokens\n%s\n\n' "$(tokens_from_hook_payload "$HOOK_PAYLOAD")"
  printf '## last 3 turns (from hook transcript)\n```json\n%s\n```\n\n' \
    "$(recent_turns_from_hook_payload "$HOOK_PAYLOAD" 3)"
  printf '## files edited in last 5 turns\n```json\n%s\n```\n\n' \
    "$(files_edited_recent "$PROJECT_HASH" 5)"
  printf '## completed turn\n%s\n' "$HOOK_PAYLOAD"
} > "$INPUT_FILE"

GRADE_JSON="$("$PLUGIN_ROOT/grader/invoke.sh" \
  "$PLUGIN_ROOT/grader/system_prompt.md" \
  "$INPUT_FILE" \
  "$GRADER_MODEL" 2>/dev/null || true)"

if [ -z "$GRADE_JSON" ]; then
  log_err "grader returned no output for turn $TURN (post); skipping"
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$GRADE_JSON" | jq -e '
    .schema_version == 1
    and (.scores.confidence.value | type == "number")
    and (.scores.atomicity.value | type == "number")
    and (.scores.drift.value | type == "number")
    and (.scores.pollution.value | type == "number")
  ' >/dev/null 2>&1; then
    log_err "grade output failed schema validation (post); skipping"
    exit 0
  fi

  # Mechanically override dominant_signal: loop wins over context_pressure
  # which wins over the grader's dimension choice.
  if [ "$LOOP_DETECTED" = "true" ]; then
    GRADE_JSON="$(printf '%s' "$GRADE_JSON" | jq '.dominant_signal = "loop"')"
  else
    TOKENS_USED="$(printf '%s' "$GRADE_JSON" | jq -r '.tokens_used // 0')"
    TOKENS_LIMIT="$(printf '%s' "$GRADE_JSON" | jq -r '.tokens_limit // 200000')"
    if [ "$TOKENS_LIMIT" -gt 0 ] && \
       [ "$(( TOKENS_USED * 100 / TOKENS_LIMIT ))" -gt "$CONTEXT_PRESSURE_PCT" ]; then
      GRADE_JSON="$(printf '%s' "$GRADE_JSON" | jq '.dominant_signal = "context_pressure"')"
    fi
  fi
fi

TURN_PATH="$(turn_file_path "$PROJECT_HASH" "$TURN" "post")"
LAST_PATH="$(last_json_path "$PROJECT_HASH")"
HISTORY_PATH="$(history_jsonl_path "$PROJECT_HASH")"

printf '%s\n' "$GRADE_JSON" | atomic_write "$TURN_PATH"
printf '%s\n' "$GRADE_JSON" | atomic_write "$LAST_PATH"
printf '%s\n' "$GRADE_JSON" >> "$HISTORY_PATH"

if command -v jq >/dev/null 2>&1; then
  DOMINANT="$(printf '%s' "$GRADE_JSON" | jq -r '.dominant_signal // empty')"
  if [ -n "$DOMINANT" ]; then
    SUGG_PATH="$(suggestions_md_path "$PROJECT_HASH")"
    {
      printf '\n## Turn %s — %s — %s\n\n' "$TURN" "$TIMESTAMP" "$DOMINANT"
      printf '**Phase**: post\n\n'
      if [ "$DOMINANT" = "loop" ]; then
        printf '**Pattern**: same file edited in %s of last %s turns.\n\n' \
          "$LOOP_EDITS_IN_WINDOW" "$LOOP_WINDOW"
      elif [ "$DOMINANT" = "context_pressure" ]; then
        printf '**Pattern**: context pressure exceeded %s%%.\n\n' "$CONTEXT_PRESSURE_PCT"
      else
        RATIONALE="$(printf '%s' "$GRADE_JSON" | jq -r ".scores.${DOMINANT}.rationale // .summary_update")"
        printf '**Issue**: %s\n\n' "$RATIONALE"
      fi
      printf 'Status: open\n'
    } >> "$SUGG_PATH"
  fi
fi

exit 0
