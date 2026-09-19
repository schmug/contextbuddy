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
# [grader.typesafe].harm_action (issue #7): see user_prompt_submit.sh. Read only to name the
# firing signals in the suggestions.md harm section below.
HARM_ACTION="$(toml_get_section_float "$CONFIG_PATH" "grader.typesafe" "harm_action" 0.7)"

# This turn's window, token count and edited files come from the JSONL transcript at
# hook.transcript_path; the payload carries none of them (issue #9, lib/transcript.sh).
# The window is the [grader] sliding_window_turns the typesafe job also reads
# (lib/job.sh), default 3. On post the window keeps this turn's prompt last. A missing
# or unreadable transcript is an empty window plus a stderr warning, never a skip.
WINDOW_TURNS="$(toml_get_section_int "$CONFIG_PATH" "grader" "sliding_window_turns" 3)"
TRANSCRIPT_PATH="$(transcript_path_from_hook_payload "$HOOK_PAYLOAD")"
WINDOW_JSON="$(transcript_window "$TRANSCRIPT_PATH" "$WINDOW_TURNS")"
TOKENS_USED_TX="$(tokens_used_from_window "$WINDOW_JSON")"

# Context window for this session (issue #47, lib/context_window.sh): model from the
# transcript tail, limit from the override / auto-compact window / model table, floored
# against the transcript count above so used <= limit always. Resolved once: the
# "## tokens" line the LLM backends copy, the typesafe job and the grade written below
# all carry this one pair.
CTX="$(resolve_context_window "$TRANSCRIPT_PATH" "$TOKENS_USED_TX")"
TOKENS_LINE="$(tokens_line_from_context "$CTX")"

# This turn's window, token count and edited files come from the JSONL transcript at
# hook.transcript_path; the payload carries none of them (issue #9, lib/transcript.sh).
# The window is the [grader] sliding_window_turns the typesafe job also reads
# (lib/job.sh), default 3. On post the window keeps this turn's prompt last. A missing
# or unreadable transcript is an empty window plus a stderr warning, never a skip.
WINDOW_TURNS="$(toml_get_section_int "$CONFIG_PATH" "grader" "sliding_window_turns" 3)"
TRANSCRIPT_PATH="$(transcript_path_from_hook_payload "$HOOK_PAYLOAD")"
WINDOW_JSON="$(transcript_window "$TRANSCRIPT_PATH" "$WINDOW_TURNS")"
TOKENS_USED_TX="$(tokens_used_from_window "$WINDOW_JSON")"

# Context window for this session (issue #47, lib/context_window.sh): model from the
# transcript tail, limit from the override / auto-compact window / model table, floored
# against the transcript count above so used <= limit always. Resolved once: the
# "## tokens" line the LLM backends copy, the typesafe job and the grade written below
# all carry this one pair.
CTX="$(resolve_context_window "$TRANSCRIPT_PATH" "$TOKENS_USED_TX")"
TOKENS_LINE="$(tokens_line_from_context "$CTX")"

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
  "$(session_md_path "$PROJECT_HASH")" "$(history_jsonl_path "$PROJECT_HASH")" "$CONFIG_PATH" "$CTX" \
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

  # dominant_signal is model output. SPEC §4.1 allows exactly four dimension names plus the
  # loop, context_pressure and harm sentinels or null; anything else is cleared here so a
  # prompt-injected grader cannot steer the suggestions lookup below (the string used to be
  # spliced into a jq program, which turned it into code).
  DOM_RAW="$(printf '%s' "$GRADE_JSON" | jq -r '.dominant_signal // empty')"
  case "$DOM_RAW" in
    ''|confidence|atomicity|drift|pollution|loop|context_pressure|harm) ;;
    *)
      log_err "dominant_signal not one of the allowed values; cleared"
      GRADE_JSON="$(printf '%s' "$GRADE_JSON" | jq -c '.dominant_signal = null')"
      ;;
  esac

  # harm is typesafe-only (SPEC §5.4): the allowlist above accepts the string from any
  # backend, so an LLM grader could still set dominant_signal "harm" with no signals
  # evidence to force the attention state (issue #55 exists for the same reason on the
  # dimension names). Keep it only when a numeric signals.destructive or signals.bypass
  # is at or above the resolved harm_action; otherwise clear it before it reaches
  # suggestions.md or last.json.
  if [ "$DOM_RAW" = "harm" ]; then
    NEW="$(printf '%s' "$GRADE_JSON" | jq -c --argjson t "$HARM_ACTION" '
      (.signals.destructive // null) as $d | (.signals.bypass // null) as $b
      | if (($d|type) == "number" and $d >= $t) or (($b|type) == "number" and $b >= $t)
        then . else .dominant_signal = null end
    ' 2>/dev/null)" && [ -n "$NEW" ] && GRADE_JSON="$NEW"
    if [ "$(printf '%s' "$GRADE_JSON" | jq -r '.dominant_signal // empty')" != "harm" ]; then
      log_err "dominant_signal harm has no signals evidence at or above harm_action ($HARM_ACTION); cleared"
    fi
  fi

  # Token economics are measured by the plugin, not the grader (SPEC.md §5.4): the
  # transcript's tokens_used and the per-model, floored tokens_limit from lib/context_window.sh
  # (issue #47) replace the grader's four token fields in one failure-safe jq call; the
  # grader's tokens_used stands only when the transcript has none (see
  # user_prompt_submit.sh for the full note).
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

  # Mechanically override dominant_signal: loop wins over context_pressure
  # which wins over the grader's dimension or harm choice.
  if [ "$LOOP_DETECTED" = "true" ]; then
    GRADE_JSON="$(printf '%s' "$GRADE_JSON" | jq -c '.dominant_signal = "loop"')"
  else
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
      elif [ "$DOMINANT" = "harm" ]; then
        # Issue #7: name the signals that reached harm_action and the severity. Nothing from
        # the prompt is read here, and a grade without a signals block still gets a section.
        HARM_LINE="$(printf '%s' "$GRADE_JSON" | jq -r --argjson t "$HARM_ACTION" '
          def pct: (. * 100 | round | tostring) + "%";
          def one_dp: (. * 10 | round) as $n | "\($n / 10 | floor).\($n % 10)";
          ([(.signals.destructive | numbers | select(. >= $t) | "destructive \(pct)"),
            (.signals.bypass | numbers | select(. >= $t) | "bypass \(pct)")]
           | if length == 0 then "harm set by the grader with no signal at threshold"
             else "\(join(", ")) at or above \($t | pct)" end)
          + "; severity \([.signals.severity | numbers] | if length == 0 then "n/a" else "\(.[0] | one_dp)/3" end)."
        ' 2>/dev/null)"
        printf '**Pattern**: %s\n\n' "${HARM_LINE:-harm signal (details unavailable)}"
      else
        RATIONALE="$(printf '%s' "$GRADE_JSON" | jq -r --arg d "$DOMINANT" '.scores[$d].rationale // .summary_update')"
        printf '**Issue**: %s\n\n' "$RATIONALE"
      fi
      printf 'Status: open\n'
    } >> "$SUGG_PATH"
  fi
fi

exit 0
