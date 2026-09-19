#!/usr/bin/env bash
# test_history_one_line — every grade appended to history.jsonl is exactly one line,
# including grades whose dominant_signal the hooks rewrite mechanically (issue #26).
#
# Readers take the last line of history.jsonl (lib/job.sh prior pollution,
# lib/transcript.sh prior_summary), so a pretty-printed record hides the prior grade.
# Runs the real hooks under a throwaway HOME with a stub `claude` on PATH that prints
# the compact grade staged in $GRADE_FILE; CONTEXTBUDDY_CLAUDE_CONFIG_DIR points at a
# temp dir so the anthropic backend proceeds. No network, no keys.
# shellcheck disable=SC2015  # `A && ok || fail` is the intended assertion idiom here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PRE_HOOK="$REPO/plugin/hooks/user_prompt_submit.sh"
POST_HOOK="$REPO/plugin/hooks/stop.sh"
# shellcheck source=../../plugin/lib/project_hash.sh
. "$REPO/plugin/lib/project_hash.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

if ! command -v jq >/dev/null 2>&1; then
  printf 'test_history_one_line: jq is required to run these tests.\n' >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/project" "$TMP/cfg"
export PATH="$TMP/bin:$PATH"
export CONTEXTBUDDY_CLAUDE_CONFIG_DIR="$TMP/cfg"
unset TYPESAFE_API_KEY ANTHROPIC_API_KEY  # no Jev shadow, no key leak

GRADE_FILE="$TMP/grade.json"
cat > "$TMP/bin/claude" <<STUBEOF
#!/usr/bin/env bash
cat "$GRADE_FILE"
STUBEOF
chmod +x "$TMP/bin/claude"

# stage_grade <phase> <tokens_used> [pretty] — §4.1 grade the stub will return. Compact by
# default; "pretty" emits the multi-line JSON that claude -p (Haiku) and the other LLM
# backends actually return, so the hooks must compact at the write site, not only on the
# override branches.
stage_grade() {
  local flag="-c"; [ "${3:-}" = "pretty" ] && flag=""
  # shellcheck disable=SC2086  # $flag is intentionally empty or -c
  jq $flag -n --arg phase "$1" --argjson used "$2" '{
    schema_version: 1, phase: $phase, turn: 1, timestamp: "2026-09-18T00:00:00Z",
    scores: {
      confidence: {value: 7, rationale: "r"}, atomicity: {value: 7, rationale: "r"},
      drift: {value: 2, rationale: "r"}, pollution: {value: 4, rationale: "prior pollution"}
    },
    tokens_used: $used, tokens_limit: 200000, dominant_signal: null,
    summary_update: "one-line summary"
  }' > "$GRADE_FILE"
}

SESSION_DIR="$HOME/.claude/inspector/sessions/$(project_hash "$TMP/project")"
HISTORY="$SESSION_DIR/history.jsonl"
GRADES=0

run_hook() {
  # run_hook <hook> <payload>
  ( cd "$TMP/project" && printf '%s' "$2" | bash "$1" >"$TMP/hook.out" 2>"$TMP/hook.err" )
  echo $?
}
lines() { [ -f "$HISTORY" ] && wc -l < "$HISTORY" | tr -d ' ' || echo 0; }
# Read from last.json, not the last history line, so the precondition holds even when
# the record under test is pretty-printed (that is the bug, not the precondition).
last_dominant() { jq -r '.dominant_signal // "null"' "$SESSION_DIR/last.json" 2>/dev/null; }

# assert_one_line_per_grade <label> — the three issue #26 acceptance checks.
assert_one_line_per_grade() {
  local label="$1"
  [ "$(lines)" = "$GRADES" ] \
    && ok "$label: history.jsonl has $GRADES line(s) for $GRADES grade(s)" \
    || fail "$label: history.jsonl has $(lines) line(s) for $GRADES grade(s)"
  tail -n 1 "$HISTORY" | jq -e '.scores.pollution.value' >/dev/null 2>&1 \
    && ok "$label: tail -n 1 | jq .scores.pollution.value succeeds" \
    || fail "$label: tail -n 1 | jq .scores.pollution.value fails"
}

PRE_PAYLOAD='{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"UserPromptSubmit","prompt":"hello there"}'
POST_PAYLOAD='{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"Stop","tool_calls":[]}'
EDIT_PAYLOAD='{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"Stop","tool_calls":[{"name":"Edit","input":{"file_path":"/tmp/p/same.swift"}}]}'

# --- 1. pre-phase context_pressure override (173430/200000 = 86% > 85) ---------------
# The payload names no readable transcript, so lib/context_window.sh resolves the default
# 200000 window (issue #47); the staged 200000 below is overwritten with that same value.
stage_grade pre 173430
rc="$(run_hook "$PRE_HOOK" "$PRE_PAYLOAD")"; GRADES=$((GRADES+1))
[ "$rc" = "0" ] && ok "pre context_pressure: hook exits 0" || fail "pre context_pressure: hook exit $rc ($(cat "$TMP/hook.err"))"
[ -f "$HISTORY" ] && ok "pre context_pressure: grade written" || fail "pre context_pressure: no history.jsonl ($(cat "$TMP/hook.err"))"
[ "$(last_dominant)" = "context_pressure" ] \
  && ok "pre context_pressure: dominant_signal overridden" \
  || fail "pre context_pressure: dominant_signal is '$(last_dominant)' (override did not fire; test precondition)"
assert_one_line_per_grade "pre context_pressure"

# --- 2. post-phase context_pressure override --------------------------------------------
stage_grade post 173430
rc="$(run_hook "$POST_HOOK" "$POST_PAYLOAD")"; GRADES=$((GRADES+1))
[ "$rc" = "0" ] && ok "post context_pressure: hook exits 0" || fail "post context_pressure: hook exit $rc ($(cat "$TMP/hook.err"))"
[ "$(last_dominant)" = "context_pressure" ] \
  && ok "post context_pressure: dominant_signal overridden" \
  || fail "post context_pressure: dominant_signal is '$(last_dominant)' (override did not fire; test precondition)"
assert_one_line_per_grade "post context_pressure"

# --- 3. post-phase loop override: same file in 3 of last 3 edit records ----------------
# Two prior edit records seeded; the hook appends the third from EDIT_PAYLOAD.
printf '{"ts":"t","turn":1,"files":["/tmp/p/same.swift"]}\n{"ts":"t","turn":1,"files":["/tmp/p/same.swift"]}\n' \
  > "$SESSION_DIR/edits.jsonl"
stage_grade post 1000
rc="$(run_hook "$POST_HOOK" "$EDIT_PAYLOAD")"; GRADES=$((GRADES+1))
[ "$rc" = "0" ] && ok "post loop: hook exits 0" || fail "post loop: hook exit $rc ($(cat "$TMP/hook.err"))"
[ "$(last_dominant)" = "loop" ] \
  && ok "post loop: dominant_signal overridden" \
  || fail "post loop: dominant_signal is '$(last_dominant)' (override did not fire; test precondition)"
assert_one_line_per_grade "post loop"

# --- 4. no override: baseline stays one line (guards the assertion itself) -------------
stage_grade post 1000
rm -f "$SESSION_DIR/edits.jsonl"
rc="$(run_hook "$POST_HOOK" "$POST_PAYLOAD")"; GRADES=$((GRADES+1))
[ "$rc" = "0" ] && ok "no override: hook exits 0" || fail "no override: hook exit $rc"
[ "$(last_dominant)" = "null" ] && ok "no override: dominant_signal untouched" || fail "no override: dominant_signal is '$(last_dominant)'"
assert_one_line_per_grade "no override"

# --- 5. pretty-printed backend output, no override (the anthropic path in production) -----
# Session 30cf4cb32f42 on 2026-09-18: one Haiku grade, dominant_signal null, 28 lines.
stage_grade pre 1000 pretty
rc="$(run_hook "$PRE_HOOK" "$PRE_PAYLOAD")"; GRADES=$((GRADES+1))
[ "$rc" = "0" ] && ok "pretty pre: hook exits 0" || fail "pretty pre: hook exit $rc"
[ "$(last_dominant)" = "null" ] && ok "pretty pre: dominant_signal untouched" || fail "pretty pre: dominant_signal is '$(last_dominant)'"
assert_one_line_per_grade "pretty pre"

stage_grade post 1000 pretty
rc="$(run_hook "$POST_HOOK" "$POST_PAYLOAD")"; GRADES=$((GRADES+1))
[ "$rc" = "0" ] && ok "pretty post: hook exits 0" || fail "pretty post: hook exit $rc"
[ "$(last_dominant)" = "null" ] && ok "pretty post: dominant_signal untouched" || fail "pretty post: dominant_signal is '$(last_dominant)'"
assert_one_line_per_grade "pretty post"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
