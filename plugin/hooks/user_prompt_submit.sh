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

log_err() { printf 'contextbuddy: %s\n' "$1" >&2; }

PROJECT_HASH="$(project_hash "$PWD")"
ensure_session_dir "$PROJECT_HASH"

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

# Read config; fall back to defaults silently per §13.
CONFIG_PATH="$(config_path)"
GRADER_MODEL="claude-haiku-4-5-20251001"
CONTEXT_PRESSURE_PCT="85"
if [ -f "$CONFIG_PATH" ]; then
  GRADER_MODEL="$(grep -E '^model[[:space:]]*=' "$CONFIG_PATH" | head -1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' || true)"
  GRADER_MODEL="${GRADER_MODEL:-claude-haiku-4-5-20251001}"
  CONTEXT_PRESSURE_PCT="$(grep -E '^context_pressure_pct[[:space:]]*=' "$CONFIG_PATH" | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' || true)"
  CONTEXT_PRESSURE_PCT="${CONTEXT_PRESSURE_PCT:-85}"
fi

# Assemble grader input bundle.
INPUT_FILE="$(mktemp)"
trap 'rm -f "$INPUT_FILE"; release_lock "$PROJECT_HASH" "write"' EXIT
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

# Call grader. Failures here are non-fatal.
GRADE_JSON="$("$PLUGIN_ROOT/grader/invoke.sh" \
  "$PLUGIN_ROOT/grader/system_prompt.md" \
  "$INPUT_FILE" \
  "$GRADER_MODEL" 2>/dev/null || true)"

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

  # Mechanically compute dominant_signal for context_pressure on pre-phase.
  TOKENS_USED="$(printf '%s' "$GRADE_JSON" | jq -r '.tokens_used // 0')"
  TOKENS_LIMIT="$(printf '%s' "$GRADE_JSON" | jq -r '.tokens_limit // 200000')"
  if [ "$TOKENS_LIMIT" -gt 0 ] && \
     [ "$(( TOKENS_USED * 100 / TOKENS_LIMIT ))" -gt "$CONTEXT_PRESSURE_PCT" ]; then
    GRADE_JSON="$(printf '%s' "$GRADE_JSON" | jq '.dominant_signal = "context_pressure"')"
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
