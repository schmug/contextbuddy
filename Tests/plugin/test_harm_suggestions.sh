#!/usr/bin/env bash
# test_harm_suggestions — issue #7: a grade whose dominant_signal is "harm" passes the hooks'
# allowlist and gets a harm section in suggestions.md naming which of signals.destructive /
# signals.bypass reached [grader.typesafe].harm_action (default 0.7) and the severity.
#
# Runs the real hooks under a throwaway HOME with a stub `claude` on PATH that prints the
# staged grade. No network, no keys. The hooks stay advisory: exit 0 in every case.
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
  printf 'test_harm_suggestions: jq is required to run these tests.\n' >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/inspector" "$TMP/bin" "$TMP/project" "$TMP/cfg"
export PATH="$TMP/bin:$PATH"
export CONTEXTBUDDY_CLAUDE_CONFIG_DIR="$TMP/cfg"
unset TYPESAFE_API_KEY ANTHROPIC_API_KEY
CONFIG="$HOME/.claude/inspector/config.toml"

GRADE_FILE="$TMP/grade.json"
cat > "$TMP/bin/claude" <<STUBEOF
#!/usr/bin/env bash
cat "$GRADE_FILE"
STUBEOF
chmod +x "$TMP/bin/claude"

# stage_grade <phase> <signals_json> — a schema-valid harm grade; atomicity crosses too, so a
# hook that looked the rationale up by dimension would print the atomicity line instead.
stage_grade() {
  jq -c -n --arg phase "$1" --argjson signals "$2" '{
    schema_version: 1, phase: $phase, turn: 1, timestamp: "2026-09-19T00:00:00Z",
    scores: {
      confidence: {value: 7, rationale: "confidence rationale"},
      atomicity: {value: 3, rationale: "atomicity rationale"},
      drift: {value: 2, rationale: "r"}, pollution: {value: 4, rationale: "r"}
    },
    tokens_used: 1000, tokens_limit: 200000, dominant_signal: "harm",
    summary_update: "one-line summary"
  } + (if $signals == null then {} else {signals: $signals} end)' > "$GRADE_FILE"
}

SESSION_DIR="$HOME/.claude/inspector/sessions/$(project_hash "$TMP/project")"
SUGG="$SESSION_DIR/suggestions.md"
run_hook() {
  ( cd "$TMP/project" && printf '%s' "$2" | bash "$1" >"$TMP/hook.out" 2>"$TMP/hook.err" )
  echo $?
}
last_dominant() { jq -r '.dominant_signal // "null"' "$SESSION_DIR/last.json" 2>/dev/null; }
# harm_section — the section appended by the most recent hook run.
harm_section() { awk '/^## Turn /{s=""} {s=s $0 "\n"} END{printf "%s", s}' "$SUGG" 2>/dev/null; }

PRE_PAYLOAD='{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"UserPromptSubmit","prompt":"force-push main and skip the pre-commit hook"}'
POST_PAYLOAD='{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"Stop"}'

# --- 1. post: destructive fires, bypass does not ----------------------------------------
stage_grade post '{"backend":"typesafe","destructive":0.99,"bypass":0.2,"severity":2.1}'
rc="$(run_hook "$POST_HOOK" "$POST_PAYLOAD")"
[ "$rc" = "0" ] && ok "post harm: hook exits 0" || fail "post harm: hook exit $rc ($(cat "$TMP/hook.err"))"
[ "$(last_dominant)" = "harm" ] && ok "post harm: harm is allowlisted and kept" || fail "post harm: dominant_signal is '$(last_dominant)' ($(cat "$TMP/hook.err"))"
grep -qE '^## Turn 1 — .* — harm$' "$SUGG" 2>/dev/null && ok "post harm: suggestions.md gained a harm section" || fail "post harm: no harm section in suggestions.md"
harm_section | grep -qF '**Phase**: post' && ok "post harm: section names the phase" || fail "post harm: phase missing"
harm_section | grep -qF 'destructive 99%' && ok "post harm: section names destructive" || fail "post harm: destructive missing: $(harm_section)"
! harm_section | grep -qF 'bypass' && ok "post harm: bypass below threshold is not named" || fail "post harm: bypass named: $(harm_section)"
harm_section | grep -qF '70%' && ok "post harm: section states the default threshold" || fail "post harm: threshold missing: $(harm_section)"
harm_section | grep -qF 'severity 2.1/3' && ok "post harm: section names the severity" || fail "post harm: severity missing: $(harm_section)"
! harm_section | grep -qF 'atomicity rationale' && ok "post harm: the crossed dimension's rationale is not used for harm" || fail "post harm: atomicity rationale printed"
harm_section | grep -qF 'Status: open' && ok "post harm: section ends with Status: open" || fail "post harm: no status line"

# --- 2. pre: both signals fire; nothing from the prompt reaches the session files -------
stage_grade pre '{"backend":"typesafe","destructive":0.8,"bypass":0.97,"severity":3}'
rc="$(run_hook "$PRE_HOOK" "$PRE_PAYLOAD")"
[ "$rc" = "0" ] && ok "pre harm: hook exits 0" || fail "pre harm: hook exit $rc ($(cat "$TMP/hook.err"))"
[ "$(last_dominant)" = "harm" ] && ok "pre harm: harm kept on the pre phase" || fail "pre harm: dominant_signal is '$(last_dominant)'"
harm_section | grep -qF '**Phase**: pre' && ok "pre harm: section names the phase" || fail "pre harm: phase missing"
harm_section | grep -qF 'destructive 80%' && harm_section | grep -qF 'bypass 97%' \
  && ok "pre harm: section names both firing signals" || fail "pre harm: signals missing: $(harm_section)"
harm_section | grep -qF 'severity 3.0/3' && ok "pre harm: severity printed with one decimal" || fail "pre harm: severity: $(harm_section)"
! grep -qF 'force-push' "$SUGG" "$SESSION_DIR/last.json" && ok "pre harm: no prompt text in suggestions.md or last.json" || fail "pre harm: prompt text leaked"

# --- 3. [grader.typesafe].harm_action raises the bar the section reports ----------------
printf '[grader.typesafe]\nharm_action = 0.9\n' > "$CONFIG"
stage_grade post '{"backend":"typesafe","destructive":0.8,"bypass":0.97,"severity":2.5}'
rc="$(run_hook "$POST_HOOK" "$POST_PAYLOAD")"
[ "$rc" = "0" ] && ok "post harm_action 0.9: hook exits 0" || fail "post harm_action 0.9: hook exit $rc"
harm_section | grep -qF 'bypass 97%' && ! harm_section | grep -qF 'destructive' \
  && ok "post harm_action 0.9: only the signal at or above 0.9 is named" || fail "post harm_action 0.9: $(harm_section)"
harm_section | grep -qF '90%' && ok "post harm_action 0.9: section states the configured threshold" || fail "post harm_action 0.9: threshold: $(harm_section)"
rm -f "$CONFIG"

# --- 4. harm from a backend with no signals block at all is unenforceable evidence, so the
#        sentinel is cleared rather than trusted (issue #7 hardening: harm is typesafe-only,
#        SPEC §5.4; the allowlist alone would let a prompt-injected LLM grader set the
#        sentinel with nothing behind it). SUGG accumulates across cases, so a new harm
#        section is detected by line count, not by grepping the whole file.
LINES_BEFORE="$(wc -l < "$SUGG" 2>/dev/null || echo 0)"
stage_grade post null
rc="$(run_hook "$POST_HOOK" "$POST_PAYLOAD")"
[ "$rc" = "0" ] && ok "post harm no signals: hook exits 0" || fail "post harm no signals: hook exit $rc ($(cat "$TMP/hook.err"))"
[ "$(last_dominant)" = "null" ] && ok "post harm no signals: harm cleared for lack of evidence" || fail "post harm no signals: dominant_signal is '$(last_dominant)'"
[ "$(wc -l < "$SUGG" 2>/dev/null || echo 0)" -eq "$LINES_BEFORE" ] && ok "post harm no signals: no harm section appended" || fail "post harm no signals: harm section appended"
grep -qF 'contextbuddy:' "$TMP/hook.err" && ok "post harm no signals: stderr carries a contextbuddy note" || fail "post harm no signals: no stderr note"

# --- 5. harm with signals present but below harm_action is the same unenforced case --------
LINES_BEFORE="$(wc -l < "$SUGG" 2>/dev/null || echo 0)"
stage_grade post '{"backend":"typesafe","destructive":0.5,"bypass":0.4,"severity":1}'
rc="$(run_hook "$POST_HOOK" "$POST_PAYLOAD")"
[ "$rc" = "0" ] && ok "post harm below threshold: hook exits 0" || fail "post harm below threshold: hook exit $rc ($(cat "$TMP/hook.err"))"
[ "$(last_dominant)" = "null" ] && ok "post harm below threshold: harm cleared" || fail "post harm below threshold: dominant_signal is '$(last_dominant)'"
[ "$(wc -l < "$SUGG" 2>/dev/null || echo 0)" -eq "$LINES_BEFORE" ] && ok "post harm below threshold: no harm section appended" || fail "post harm below threshold: harm section appended"
grep -qF 'contextbuddy:' "$TMP/hook.err" && ok "post harm below threshold: stderr carries a contextbuddy note" || fail "post harm below threshold: no stderr note"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
