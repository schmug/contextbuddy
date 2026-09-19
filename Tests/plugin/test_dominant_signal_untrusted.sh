#!/usr/bin/env bash
# test_dominant_signal_untrusted — the grader's dominant_signal is model output and must
# never reach a jq program as code, and must never leave the seven values SPEC §4.1 names.
#
# Before this test the hooks ran `jq -r ".scores.${DOMINANT}.rationale // .summary_update"`,
# so a grader that returned dominant_signal 'x.r // (env.SECRET_DEMO) //' made the hook read an
# environment variable and write it into suggestions.md. Runs the real hooks under a throwaway
# HOME with a stub `claude` on PATH that prints the staged grade. No network, no keys.
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
  printf 'test_dominant_signal_untrusted: jq is required to run these tests.\n' >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/project" "$TMP/cfg"
export PATH="$TMP/bin:$PATH"
export CONTEXTBUDDY_CLAUDE_CONFIG_DIR="$TMP/cfg"
unset TYPESAFE_API_KEY ANTHROPIC_API_KEY
export SECRET_DEMO="canary-4f2a9c-do-not-leak"

GRADE_FILE="$TMP/grade.json"
cat > "$TMP/bin/claude" <<STUBEOF
#!/usr/bin/env bash
cat "$GRADE_FILE"
STUBEOF
chmod +x "$TMP/bin/claude"

# stage_grade <phase> <dominant_signal_string> — a schema-valid grade whose dominant_signal
# is whatever string the (possibly prompt-injected) model chose.
stage_grade() {
  jq -c -n --arg phase "$1" --arg dom "$2" '{
    schema_version: 1, phase: $phase, turn: 1, timestamp: "2026-09-19T00:00:00Z",
    scores: {
      confidence: {value: 7, rationale: "confidence rationale"},
      atomicity: {value: 3, rationale: "atomicity rationale"},
      drift: {value: 2, rationale: "r"}, pollution: {value: 4, rationale: "r"}
    },
    tokens_used: 1000, tokens_limit: 200000, dominant_signal: $dom,
    summary_update: "one-line summary"
  }' > "$GRADE_FILE"
}

SESSION_DIR="$HOME/.claude/inspector/sessions/$(project_hash "$TMP/project")"
SUGG="$SESSION_DIR/suggestions.md"
run_hook() {
  ( cd "$TMP/project" && printf '%s' "$2" | bash "$1" >"$TMP/hook.out" 2>"$TMP/hook.err" )
  echo $?
}
last_dominant() { jq -r '.dominant_signal // "null"' "$SESSION_DIR/last.json" 2>/dev/null; }

PRE_PAYLOAD='{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"UserPromptSubmit","prompt":"hello there"}'
POST_PAYLOAD='{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"Stop"}'
INJECT='x.rationale // (env.SECRET_DEMO) //'

# --- 1. injected dominant_signal on the pre phase --------------------------------------
stage_grade pre "$INJECT"
rc="$(run_hook "$PRE_HOOK" "$PRE_PAYLOAD")"
[ "$rc" = "0" ] && ok "pre inject: hook exits 0" || fail "pre inject: hook exit $rc ($(cat "$TMP/hook.err"))"
[ -f "$SESSION_DIR/last.json" ] && ok "pre inject: grade still written" || fail "pre inject: no last.json ($(cat "$TMP/hook.err"))"
[ "$(last_dominant)" = "null" ] && ok "pre inject: dominant_signal cleared to null" || fail "pre inject: dominant_signal is '$(last_dominant)'"
! grep -qF "$SECRET_DEMO" "$SUGG" 2>/dev/null && ok "pre inject: secret not in suggestions.md" || fail "pre inject: SECRET_DEMO leaked into suggestions.md"
grep -q 'dominant_signal' "$TMP/hook.err" && ok "pre inject: stderr names the cleared field" || fail "pre inject: no stderr warning"

# --- 2. injected dominant_signal on the post phase -------------------------------------
stage_grade post "$INJECT"
rc="$(run_hook "$POST_HOOK" "$POST_PAYLOAD")"
[ "$rc" = "0" ] && ok "post inject: hook exits 0" || fail "post inject: hook exit $rc ($(cat "$TMP/hook.err"))"
[ "$(last_dominant)" = "null" ] && ok "post inject: dominant_signal cleared to null" || fail "post inject: dominant_signal is '$(last_dominant)'"
! grep -qF "$SECRET_DEMO" "$SUGG" 2>/dev/null && ok "post inject: secret not in suggestions.md" || fail "post inject: SECRET_DEMO leaked into suggestions.md"

# --- 3. a legitimate value still selects its rationale ---------------------------------
stage_grade post atomicity
rc="$(run_hook "$POST_HOOK" "$POST_PAYLOAD")"
[ "$rc" = "0" ] && ok "post atomicity: hook exits 0" || fail "post atomicity: hook exit $rc"
[ "$(last_dominant)" = "atomicity" ] && ok "post atomicity: allowlisted value kept" || fail "post atomicity: dominant_signal is '$(last_dominant)'"
grep -qF '**Issue**: atomicity rationale' "$SUGG" && ok "post atomicity: rationale looked up by key" || fail "post atomicity: rationale missing from suggestions.md"

stage_grade pre confidence
rc="$(run_hook "$PRE_HOOK" "$PRE_PAYLOAD")"
[ "$rc" = "0" ] && ok "pre confidence: hook exits 0" || fail "pre confidence: hook exit $rc"
grep -qF '**Issue**: confidence rationale' "$SUGG" && ok "pre confidence: rationale looked up by key" || fail "pre confidence: rationale missing from suggestions.md"

# --- 4. a plausible-looking but unknown value is cleared, not looked up ------------------
# (`harm` joined the allowlist with issue #7 — test_harm_suggestions.sh covers it — so the
# unknown value here is another signals-block field name the grader could plausibly emit.)
stage_grade post severity
rc="$(run_hook "$POST_HOOK" "$POST_PAYLOAD")"
[ "$rc" = "0" ] && ok "post unknown: hook exits 0" || fail "post unknown: hook exit $rc"
[ "$(last_dominant)" = "null" ] && ok "post unknown: unlisted value cleared" || fail "post unknown: dominant_signal is '$(last_dominant)'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
