#!/usr/bin/env bash
# stop — fired by Claude Code on every Stop (turn completion).
#
# Same pipeline as user_prompt_submit.sh but with phase=post and the
# additional responsibilities listed in §10.1:
#   - read this turn's Edit/Write tool_use records from the JSONL transcript at
#     hook.transcript_path (the payload carries no tool calls), append to edits.jsonl
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

HOOK_PAYLOAD="$(cat || true)"

if ! acquire_lock "$PROJECT_HASH" "write"; then
  log_err "could not acquire write lock; skipping grade"
  exit 0
fi

INPUT_FILE="$(mktemp)"
JOB_FILE="$(mktemp)"
cleanup() {
  rm -f "$INPUT_FILE" "$JOB_FILE"
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
CONFIG_PATH="$(config_path)"
LOOP_WINDOW="$(toml_get_section_int "$CONFIG_PATH" "thresholds" "loop_window_turns" 3)"
LOOP_EDITS_IN_WINDOW="$(toml_get_section_int "$CONFIG_PATH" "thresholds" "loop_edits_in_window" 3)"
GRADER_MODEL="$(toml_get_section_key "$CONFIG_PATH" "grader" "model")"
GRADER_MODEL="${GRADER_MODEL:-claude-haiku-4-5-20251001}"
CONTEXT_PRESSURE_PCT="$(toml_get_section_int "$CONFIG_PATH" "thresholds" "context_pressure_pct" 85)"

# This turn's window, token count and edited files come from the JSONL transcript at
# hook.transcript_path; the payload carries none of them (issue #9, lib/transcript.sh).
# The window is the [grader] sliding_window_turns the typesafe job also reads
# (lib/job.sh), default 3. On post the window keeps this turn's prompt last. A missing
# or unreadable transcript is an empty window plus a stderr warning, never a skip.
WINDOW_TURNS="$(toml_get_section_int "$CONFIG_PATH" "grader" "sliding_window_turns" 3)"
TRANSCRIPT_PATH="$(transcript_path_from_hook_payload "$HOOK_PAYLOAD")"
WINDOW_JSON="$(transcript_window "$TRANSCRIPT_PATH" "$WINDOW_TURNS")"
TOKENS_LINE="$(tokens_from_window "$WINDOW_JSON")"
TOKENS_USED_TX="${TOKENS_LINE%% *}"
TOKENS_LIMIT_TX="${TOKENS_LINE##* }"
TOKENS_TRUST="$(tokens_trust "$TOKENS_USED_TX" "$TOKENS_LIMIT_TX")"

if command -v jq >/dev/null 2>&1; then
  EDITED_FILES_JSON="$(edited_files_from_window "$WINDOW_JSON")"
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
  printf '## tokens\n%s\n\n' "$TOKENS_LINE"
  printf '## last %s turns (from hook transcript)\n```json\n%s\n```\n\n' \
    "$WINDOW_TURNS" "$(prompts_from_window "$WINDOW_JSON")"
  printf '## files edited in last 5 turns\n```json\n%s\n```\n\n' \
    "$(files_edited_recent "$PROJECT_HASH" 5)"
  printf '## completed turn\n%s\n' "$HOOK_PAYLOAD"
} > "$INPUT_FILE"

# Job file for the typesafe backend (see user_prompt_submit.sh).
build_job "post" "$TURN" "$TIMESTAMP" "$HOOK_PAYLOAD" \
  "$(session_md_path "$PROJECT_HASH")" "$(history_jsonl_path "$PROJECT_HASH")" "$CONFIG_PATH" \
  > "$JOB_FILE" 2>/dev/null || printf '{}' > "$JOB_FILE"

GRADE_JSON="$(CONTEXTBUDDY_JOB="$JOB_FILE" "$PLUGIN_ROOT/grader/invoke.sh" \
  "$PLUGIN_ROOT/grader/system_prompt.md" \
  "$INPUT_FILE" \
  "$GRADER_MODEL" \
  "$CONFIG_PATH" 2>/dev/null || true)"

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

  # One document per line (issue #26): LLM backends emit whatever the model printed and
  # Haiku pretty-prints, while history.jsonl readers take the last line (lib/job.sh prior
  # pollution, lib/transcript.sh prior_summary). Compact once here so every write below,
  # override or not, is a single line.
  GRADE_JSON="$(printf '%s' "$GRADE_JSON" | jq -c .)"

  # Token economics are measured by the plugin, not the grader (SPEC.md §5.4). The
  # transcript pair replaces both token fields in one failure-safe jq call only when
  # 0 < used <= limit; above the limit the grader's fields stand, a warning goes to
  # stderr and no context_pressure is derived (see user_prompt_submit.sh for the why).
  case "$TOKENS_TRUST" in
    ok)
      NEW="$(printf '%s' "$GRADE_JSON" | jq -c --argjson u "$TOKENS_USED_TX" --argjson l "$TOKENS_LIMIT_TX" \
        '.tokens_used = $u | .tokens_limit = $l' 2>/dev/null)" && [ -n "$NEW" ] && GRADE_JSON="$NEW"
      ;;
    over)
      log_err "tokens_used $TOKENS_USED_TX exceeds tokens_limit $TOKENS_LIMIT_TX; limit unknown for this model, leaving the grader's token fields"
      ;;
  esac

  # Mechanically override dominant_signal: loop wins over context_pressure
  # which wins over the grader's dimension choice. context_pressure reads the grade's
  # own fields and is skipped when the transcript count exceeds the limit (the grader
  # copied that same count from the bundle).
  if [ "$LOOP_DETECTED" = "true" ]; then
    GRADE_JSON="$(printf '%s' "$GRADE_JSON" | jq -c '.dominant_signal = "loop"')"
  elif [ "$TOKENS_TRUST" != "over" ]; then
    TOKENS_USED="$(printf '%s' "$GRADE_JSON" | jq -r '.tokens_used // 0')"
    TOKENS_LIMIT="$(printf '%s' "$GRADE_JSON" | jq -r '.tokens_limit // 200000')"
    if [ "$TOKENS_LIMIT" -gt 0 ] && \
       [ "$(( TOKENS_USED * 100 / TOKENS_LIMIT ))" -gt "$CONTEXT_PRESSURE_PCT" ]; then
      GRADE_JSON="$(printf '%s' "$GRADE_JSON" | jq -c '.dominant_signal = "context_pressure"')"
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
