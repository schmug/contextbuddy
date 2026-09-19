#!/usr/bin/env bash
# test_context_window_hooks — both hooks write tokens_limit, model and limit_source resolved
# per session model (issue #47, lib/context_window.sh) and compare context pressure against
# that limit, whatever the grader backend returned.
#
# Runs the real hooks under a throwaway HOME with a stub `claude` on PATH that records the
# input it was handed (-p) and prints a staged grade carrying a STALE tokens_limit of 200000
# and, where noted, a stale tokens_used, so a passing assertion proves the hook stamped the
# resolved pair rather than trusting the backend. tokens_used comes from the transcript's
# last assistant usage (issue #9, lib/transcript.sh), so the ## tokens line and the floor
# both see that count. CONTEXTBUDDY_CLAUDE_CONFIG_DIR points at a temp dir so the anthropic
# backend proceeds. No network, no keys.
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
  printf 'test_context_window_hooks: jq is required to run these tests.\n' >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/project" "$TMP/cfg"
export PATH="$TMP/bin:$PATH"
export CONTEXTBUDDY_CLAUDE_CONFIG_DIR="$TMP/cfg"
unset TYPESAFE_API_KEY ANTHROPIC_API_KEY  # no Jev shadow, no key leak
unset CONTEXTBUDDY_CONTEXT_WINDOW CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_DISABLE_1M_CONTEXT CLAUDE_CONFIG_DIR

GRADE_FILE="$TMP/grade.json"
STUB="$TMP/bin/claude"
cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
# Records the grader input (the -p argument) and prints the staged grade.
while [ \$# -gt 0 ]; do
  if [ "\$1" = "-p" ]; then printf '%s\\n' "\$2" > "$TMP/input.md"; break; fi
  shift
done
cat "$GRADE_FILE"
STUBEOF
chmod +x "$STUB"

# stage_grade <phase> <tokens_used> — §4.1 grade with the stale 200000 limit the old code hardcoded.
stage_grade() {
  jq -c -n --arg phase "$1" --argjson used "$2" '{
    schema_version: 1, phase: $phase, turn: 1, timestamp: "2026-09-19T00:00:00Z",
    scores: {
      confidence: {value: 7, rationale: "r"}, atomicity: {value: 7, rationale: "r"},
      drift: {value: 2, rationale: "r"}, pollution: {value: 4, rationale: "r"}
    },
    tokens_used: $used, tokens_limit: 200000, dominant_signal: null,
    summary_update: "s"
  }' > "$GRADE_FILE"
}

# transcript <path> <model...> — usage 2 + $CACHE_READ (default 176000) + 472 per record,
# so the transcript's tokens_used is 176474 unless CACHE_READ is set for the call.
transcript() {
  local path="$1"; shift
  local cr="${CACHE_READ:-176000}"
  printf '{"type":"user","message":{"role":"user","content":"hello"}}\n' > "$path"
  local m
  for m in "$@"; do
    printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":2,"cache_read_input_tokens":%s,"cache_creation_input_tokens":472}}}\n' "$m" "$cr" >> "$path"
  done
}
FABLE="$TMP/fable.jsonl"; transcript "$FABLE" claude-fable-5-1
HAIKU="$TMP/haiku.jsonl"; transcript "$HAIKU" claude-haiku-4-5-20251001
MIXED="$TMP/mixed.jsonl"; transcript "$MIXED" claude-haiku-4-5-20251001 claude-fable-5-1 '<synthetic>'

SESSION_DIR="$HOME/.claude/inspector/sessions/$(project_hash "$TMP/project")"
LAST="$SESSION_DIR/last.json"
HISTORY="$SESSION_DIR/history.jsonl"

# payload <event> <transcript>
payload() {
  jq -c -n --arg ev "$1" --arg t "$2" '{session_id:"s1",transcript_path:$t,cwd:"/tmp/p",hook_event_name:$ev,prompt:"hello there"}'
}
run_hook() { # run_hook <hook> <payload>
  ( cd "$TMP/project" && printf '%s' "$2" | bash "$1" >"$TMP/hook.out" 2>"$TMP/hook.err" )
  echo $?
}
last() { jq -r "$1" "$LAST" 2>/dev/null; }
tokens_line() { grep -A1 '^## tokens' "$TMP/input.md" 2>/dev/null | tail -n 1; }

# assert_grade <label> <model> <limit> <source> <dominant>
assert_grade() {
  local label="$1" model="$2" limit="$3" source="$4" dominant="$5"
  [ "$(last '.model // "null"')" = "$model" ] && ok "$label: model $model" || fail "$label: model '$(last '.model')' (want $model)"
  [ "$(last '.tokens_limit')" = "$limit" ] && ok "$label: tokens_limit $limit" || fail "$label: tokens_limit '$(last '.tokens_limit')' (want $limit)"
  [ "$(last '.limit_source // "null"')" = "$source" ] && ok "$label: limit_source $source" || fail "$label: limit_source '$(last '.limit_source')' (want $source)"
  [ "$(last '.dominant_signal // "null"')" = "$dominant" ] && ok "$label: dominant_signal $dominant" || fail "$label: dominant_signal '$(last '.dominant_signal')' (want $dominant)"
}

# --- 1. pre hook, Fable 5.1 at 176474 tokens: 1M window, no context pressure -------------
stage_grade pre 176474
rc="$(run_hook "$PRE_HOOK" "$(payload UserPromptSubmit "$FABLE")")"
[ "$rc" = "0" ] && ok "pre fable: hook exits 0" || fail "pre fable: hook exit $rc ($(cat "$TMP/hook.err"))"
[ -f "$LAST" ] && ok "pre fable: grade written" || fail "pre fable: no last.json ($(cat "$TMP/hook.err"))"
assert_grade "pre fable" claude-fable-5-1 1000000 model null
[ "$(tokens_line)" = "176474 1000000" ] && ok "pre fable: grader input ## tokens line carries the transcript count and the resolved limit" \
  || fail "pre fable: ## tokens line is '$(tokens_line)' (want '176474 1000000')"
[ "$(wc -l < "$HISTORY" | tr -d ' ')" = "1" ] && ok "pre fable: history.jsonl one line" || fail "pre fable: history.jsonl $(wc -l < "$HISTORY") lines"

# --- 2. stop hook, same transcript ------------------------------------------------------------
stage_grade post 176474
rc="$(run_hook "$POST_HOOK" "$(payload Stop "$FABLE")")"
[ "$rc" = "0" ] && ok "post fable: hook exits 0" || fail "post fable: hook exit $rc ($(cat "$TMP/hook.err"))"
[ "$(last '.phase')" = "post" ] && ok "post fable: post grade written" || fail "post fable: last.json phase '$(last '.phase')'"
assert_grade "post fable" claude-fable-5-1 1000000 model null
[ "$(tokens_line)" = "176474 1000000" ] && ok "post fable: grader input ## tokens line carries the transcript count and the resolved limit" \
  || fail "post fable: ## tokens line is '$(tokens_line)'"

# --- 3. Haiku 4.5 at 176474: 200K window, context pressure (88% > 85) ---------------------
stage_grade pre 176474
run_hook "$PRE_HOOK" "$(payload UserPromptSubmit "$HAIKU")" >/dev/null
assert_grade "pre haiku" claude-haiku-4-5-20251001 200000 model context_pressure
stage_grade post 176474
run_hook "$POST_HOOK" "$(payload Stop "$HAIKU")" >/dev/null
assert_grade "post haiku" claude-haiku-4-5-20251001 200000 model context_pressure

# --- 4. a trailing <synthetic> record is skipped ---------------------------------------------
stage_grade pre 176474
run_hook "$PRE_HOOK" "$(payload UserPromptSubmit "$MIXED")" >/dev/null
assert_grade "synthetic skipped" claude-fable-5-1 1000000 model null

# --- 5. evidence floor: 250065 in the transcript on a 200K model can only mean a bigger window
# The count comes from the transcript (issue #9), so the staged grade's stale 1000 is
# irrelevant: the hook stamps 250065 / 345106 and floors the limit to the next tier.
FLOOR_PRE="$TMP/floor_pre.jsonl";   CACHE_READ=249591 transcript "$FLOOR_PRE" claude-haiku-4-5-20251001
FLOOR_POST="$TMP/floor_post.jsonl"; CACHE_READ=344632 transcript "$FLOOR_POST" claude-haiku-4-5-20251001
stage_grade pre 1000
run_hook "$PRE_HOOK" "$(payload UserPromptSubmit "$FLOOR_PRE")" >/dev/null
assert_grade "observed pre" claude-haiku-4-5-20251001 1000000 observed null
[ "$(last '.tokens_used')" = "250065" ] && ok "observed pre: tokens_used 250065 from the transcript" || fail "observed pre: tokens_used '$(last '.tokens_used')'"
stage_grade post 1000
run_hook "$POST_HOOK" "$(payload Stop "$FLOOR_POST")" >/dev/null
assert_grade "observed post" claude-haiku-4-5-20251001 1000000 observed null
[ "$(last '.tokens_used')" = "345106" ] && ok "observed post: tokens_used 345106 from the transcript" || fail "observed post: tokens_used '$(last '.tokens_used')'"

# --- 6. CONTEXTBUDDY_CONTEXT_WINDOW override, env and .env ------------------------------------
stage_grade pre 176474
CONTEXTBUDDY_CONTEXT_WINDOW=300000 run_hook "$PRE_HOOK" "$(payload UserPromptSubmit "$FABLE")" >/dev/null
assert_grade "env override" claude-fable-5-1 300000 override null
[ "$(tokens_line)" = "176474 300000" ] && ok "env override: ## tokens line agrees" || fail "env override: ## tokens line is '$(tokens_line)'"
printf 'CONTEXTBUDDY_CONTEXT_WINDOW=300000\n' > "$TMP/project/.env"
stage_grade post 176474
run_hook "$POST_HOOK" "$(payload Stop "$FABLE")" >/dev/null
rm -f "$TMP/project/.env"
assert_grade "dotenv override" claude-fable-5-1 300000 override null
stage_grade pre 176474
CONTEXTBUDDY_CONTEXT_WINDOW=200000 run_hook "$PRE_HOOK" "$(payload UserPromptSubmit "$FABLE")" >/dev/null
assert_grade "override below the model window still trips pressure" claude-fable-5-1 200000 override context_pressure

# --- 7. auto-compact window from settings.json under CLAUDE_CONFIG_DIR -----------------------
mkdir -p "$TMP/cfgdir"; printf '{"autoCompactWindow":"500k"}\n' > "$TMP/cfgdir/settings.json"
stage_grade pre 176474
CLAUDE_CONFIG_DIR="$TMP/cfgdir" run_hook "$PRE_HOOK" "$(payload UserPromptSubmit "$FABLE")" >/dev/null
assert_grade "autocompact" claude-fable-5-1 500000 autocompact null
stage_grade pre 176474
CLAUDE_CODE_AUTO_COMPACT_WINDOW=180k run_hook "$PRE_HOOK" "$(payload UserPromptSubmit "$FABLE")" >/dev/null
assert_grade "autocompact env" claude-fable-5-1 180000 autocompact context_pressure
stage_grade pre 176474
CLAUDE_CODE_AUTO_COMPACT_WINDOW=150k run_hook "$PRE_HOOK" "$(payload UserPromptSubmit "$FABLE")" >/dev/null
assert_grade "autocompact below usage is floored to the next tier" claude-fable-5-1 200000 observed context_pressure

# --- 8. no transcript: default, still one line per grade ---------------------------------------
stage_grade pre 1000
run_hook "$PRE_HOOK" '{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"UserPromptSubmit","prompt":"hello there"}' >/dev/null
assert_grade "no transcript" null 200000 default null
[ "$(last '.tokens_used')" = "1000" ] && ok "no transcript: the grader's tokens_used 1000 stands" || fail "no transcript: tokens_used '$(last '.tokens_used')'"

# --- 9. invariant over everything written: tokens_used <= tokens_limit, one line each --------
n="$(wc -l < "$HISTORY" | tr -d ' ')"
bad="$(jq -r 'select(.tokens_used > .tokens_limit) | "\(.turn) \(.phase) \(.tokens_used)/\(.tokens_limit)"' "$HISTORY")"
[ -z "$bad" ] && ok "no grade has tokens_used > tokens_limit ($n grades)" || fail "grades with tokens_used > tokens_limit: $bad"
[ "$(jq -c . "$HISTORY" | wc -l | tr -d ' ')" = "$n" ] && ok "history.jsonl is one document per line" || fail "history.jsonl has a multi-line record"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
