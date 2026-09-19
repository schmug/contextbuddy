#!/usr/bin/env bash
# test_transcript_window — the grader's turn window, token count and this turn's edited
# files come from the JSONL transcript at hook.transcript_path, not from hook payload
# keys Claude Code never sends (issue #9). The record filters mirror the ones
# Tests/plugin/test_jev_grader.mjs pins for grader/jev.mjs parseTranscript, against the
# same fixture, so the bash and node windows cannot drift.
#
# Part 1 asserts lib/transcript.sh transcript_window directly with jq, including the
# untrusted-path cases (missing, unreadable, option-shaped, spaces). Part 2 runs the real
# hooks under a throwaway HOME with a stub `claude` on PATH that records the input bundle
# it was handed and prints the compact grade staged in $GRADE_FILE;
# CONTEXTBUDDY_CLAUDE_CONFIG_DIR points at a temp dir so the anthropic backend proceeds.
# No network, no keys.
# shellcheck disable=SC2015  # `A && ok || fail` is the intended assertion idiom here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FIXTURE="$HERE/fixtures/transcript_window.jsonl"
PRE_HOOK="$REPO/plugin/hooks/user_prompt_submit.sh"
POST_HOOK="$REPO/plugin/hooks/stop.sh"
# shellcheck source=../../plugin/lib/project_hash.sh
. "$REPO/plugin/lib/project_hash.sh"
# shellcheck source=../../plugin/lib/transcript.sh
. "$REPO/plugin/lib/transcript.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

if ! command -v jq >/dev/null 2>&1; then
  printf 'test_transcript_window: jq is required to run these tests.\n' >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# check <label> <json> <jq-expr>
check() {
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then ok "$1"; else fail "$1: $3"; printf '%s\n' "$2" >&2; fi
}
EMPTY='{"prompts":[],"tokens_used":0,"edited_files":[]}'
LAST_THREE='["Now migrate the login route","Run the auth tests","still failing. the expired-token test in tests/auth/jwt.test.ts is red again, fix it"]'

# --- 1. transcript_window on the fixture: the jev.mjs window, from bash -----------------
W="$(transcript_window "$FIXTURE" 3 2>"$TMP/err")"
check "window 3: last three typed prompts, oldest first" "$W" ".prompts == $LAST_THREE"
check "window 3: tokens_used = input + cache read + cache creation of the last assistant call" "$W" '.tokens_used == 60200'
check "window 3: no Edit/Write after the fixture's last typed prompt" "$W" '.edited_files == []'
[ ! -s "$TMP/err" ] && ok "window 3: nothing on stderr" || fail "window 3: stderr: $(cat "$TMP/err")"

W="$(transcript_window "$FIXTURE" 10)"
check "window 10: five typed prompts" "$W" '.prompts | length == 5'
check "window 10: isMeta skill expansion skipped" "$W" '.prompts | any(startswith("Base directory")) | not'
check "window 10: sidechain prompt skipped" "$W" '.prompts | any(contains("sidechain")) | not'
check "window 10: slash-command records skipped" "$W" '.prompts | any(startswith("<command-name>") or startswith("<local-command-stdout>")) | not'
check "window 10: <system-reminder> blocks stripped, reminder-only record dropped" "$W" '.prompts | any(contains("system-reminder") or contains("reminder-only")) | not'
check "window 10: tool_result-only user records are not prompts" "$W" '.prompts | any(contains("validateToken")) | not'
check "window 10: first typed prompt kept with its reminder stripped" "$W" '.prompts[0] == "Refactor the auth module to use JWT instead of session cookies. Use jose."'

# Pre hook: the harness may already have appended the current prompt; drop it, as
# jev.mjs buildState does, so the window never repeats "## latest prompt".
W="$(transcript_window "$FIXTURE" 3 "still failing. the expired-token test in tests/auth/jwt.test.ts is red again, fix it")"
check "current prompt already in the transcript is dropped from the window" "$W" '.prompts == ["Now migrate the login route","Run the auth tests"]'
W="$(transcript_window "$FIXTURE" 3 "a prompt the transcript does not hold yet")"
check "current prompt absent from the transcript leaves the window whole" "$W" ".prompts == $LAST_THREE"

# --- 2. edited files: this turn's Edit/Write tool_use records only ----------------------
LOOP_T="$TMP/loop.jsonl"
{
  printf '{"type":"user","message":{"content":"first prompt"}}\n'
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/old/turn.ts"}}],"usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}\n'
  printf '{"type":"user","message":{"content":"fix the expiry check in jwt.ts"}}\n'
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"src/auth/jwt.ts"}},{"type":"tool_use","name":"Edit","input":{"file_path":"src/auth/jwt.ts","old_string":"a","new_string":"b"}},{"type":"tool_use","name":"Write","input":{"file_path":"src/auth/jwt.ts"}},{"type":"tool_use","name":"Edit","input":{}},{"type":"text","text":"Done."}],"usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":0}}}\n'
  printf 'not json\n'
} > "$LOOP_T"
W="$(transcript_window "$LOOP_T" 3)"
check "edits: Edit/Write after the last typed prompt, unique; Read and pathless tool_use ignored" "$W" '.edited_files == ["src/auth/jwt.ts"]'
check "edits: an earlier turn's edit is not counted" "$W" '.edited_files | index("src/old/turn.ts") == null'
check "edits: tokens from the last assistant record" "$W" '.tokens_used == 1000'
check "edits: unparseable trailing line tolerated" "$W" '.prompts == ["first prompt","fix the expiry check in jwt.ts"]'

# --- 3. transcript_path is untrusted hook input --------------------------------------
W="$(transcript_window "$TMP/does-not-exist.jsonl" 3 2>"$TMP/err")"; rc=$?
[ "$rc" = "0" ] && ok "missing file: returns 0" || fail "missing file: returned $rc"
check "missing file: empty window" "$W" ". == $EMPTY"
grep -q '^contextbuddy: ' "$TMP/err" && ok "missing file: contextbuddy: warning on stderr" || fail "missing file: no warning ($(cat "$TMP/err"))"

W="$(transcript_window "" 3 2>"$TMP/err")"; rc=$?
[ "$rc" = "0" ] && check "empty path: returns 0 with the empty window" "$W" ". == $EMPTY" || fail "empty path: returned $rc"

W="$(transcript_window "$TMP" 3 2>"$TMP/err")"; rc=$?
[ "$rc" = "0" ] && check "directory: returns 0 with the empty window" "$W" ". == $EMPTY" || fail "directory: returned $rc"

W="$(transcript_window "--slurp" 3 2>"$TMP/err")"; rc=$?
[ "$rc" = "0" ] && check "option-shaped path: never parsed as a jq flag" "$W" ". == $EMPTY" || fail "option-shaped path: returned $rc"

mkdir -p "$TMP/dir with spaces"
cp "$FIXTURE" "$TMP/dir with spaces/t; echo pwned.jsonl"
W="$(transcript_window "$TMP/dir with spaces/t; echo pwned.jsonl" 3 2>"$TMP/err")"
check "path with spaces and a semicolon: read as one file name" "$W" '.tokens_used == 60200'
[ ! -s "$TMP/err" ] && ok "path with spaces: nothing on stderr" || fail "path with spaces: stderr: $(cat "$TMP/err")"

if [ "$(id -u)" != "0" ]; then
  cp "$FIXTURE" "$TMP/unreadable.jsonl"; chmod 000 "$TMP/unreadable.jsonl"
  W="$(transcript_window "$TMP/unreadable.jsonl" 3 2>"$TMP/err")"; rc=$?
  [ "$rc" = "0" ] && check "unreadable file: returns 0 with the empty window" "$W" ". == $EMPTY" || fail "unreadable file: returned $rc"
  grep -q '^contextbuddy: ' "$TMP/err" && ok "unreadable file: warning on stderr" || fail "unreadable file: no warning"
  chmod 600 "$TMP/unreadable.jsonl"
fi

P="$(transcript_path_from_hook_payload '{"transcript_path":"/a b/t.jsonl","prompt":"x"}')"
[ "$P" = "/a b/t.jsonl" ] && ok "payload: transcript_path extracted verbatim" || fail "payload: got '$P'"
P="$(transcript_path_from_hook_payload '{"transcript_path":42}')"
[ -z "$P" ] && ok "payload: non-string transcript_path yields empty" || fail "payload: got '$P'"
P="$(transcript_path_from_hook_payload 'not json')"
[ -z "$P" ] && ok "payload: unparseable payload yields empty" || fail "payload: got '$P'"

# --- 4. the hooks, end to end, with a stub claude that records its input bundle ---------
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/project" "$TMP/cfg"
export PATH="$TMP/bin:$PATH"
export CONTEXTBUDDY_CLAUDE_CONFIG_DIR="$TMP/cfg"
unset TYPESAFE_API_KEY ANTHROPIC_API_KEY  # no Jev shadow, no key leak

GRADE_FILE="$TMP/grade.json"
INPUT_COPY="$TMP/input.md"
cat > "$TMP/bin/claude" <<STUBEOF
#!/usr/bin/env bash
# Records the -p argument (the grader input bundle), then returns the staged grade.
last=""; for a in "\$@"; do last="\$a"; done
printf '%s' "\$last" > "$INPUT_COPY"
cat "$GRADE_FILE"
STUBEOF
chmod +x "$TMP/bin/claude"

# stage_grade <phase> <tokens_used> — the §4.1 grade the stub returns. tokens_used is
# deliberately not the transcript's count, so the stamp is observable.
stage_grade() {
  jq -c -n --arg phase "$1" --argjson used "$2" '{
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
run_hook() {
  # run_hook <hook> <payload>
  : > "$INPUT_COPY"
  ( cd "$TMP/project" && printf '%s' "$2" | bash "$1" >"$TMP/hook.out" 2>"$TMP/hook.err" )
  echo $?
}
# section <heading-prefix> — body of that "## " section of the recorded bundle, fences dropped.
section() { awk -v h="$1" 'index($0, h) == 1 {on=1; next} /^## / {on=0} on' "$INPUT_COPY" | sed '/^```/d'; }
payload() { # payload <event> <transcript_path> <extra-json-object>
  jq -c -n --arg ev "$1" --arg t "$2" --argjson extra "$3" \
    '{session_id: "s1", transcript_path: $t, cwd: "/tmp/p", hook_event_name: $ev} + $extra'
}
last_field() { jq -r ".$1 // \"null\"" "$SESSION_DIR/last.json" 2>/dev/null; }

# 4a. pre with the fixture: the anthropic bundle and the written grade
stage_grade pre 1000
rc="$(run_hook "$PRE_HOOK" "$(payload UserPromptSubmit "$FIXTURE" '{"prompt":"and add a regression test"}')")"
[ "$rc" = "0" ] && ok "pre fixture: hook exits 0" || fail "pre fixture: exit $rc ($(cat "$TMP/hook.err"))"
[ -s "$INPUT_COPY" ] && ok "pre fixture: grader received an input bundle" || fail "pre fixture: stub claude never ran ($(cat "$TMP/hook.err"))"
check "pre fixture: last 3 turns section holds the last three typed prompts" "$(section '## last 3 turns')" ". == $LAST_THREE"
grep -q 'Base directory for this skill' "$INPUT_COPY" \
  && fail "pre fixture: isMeta skill expansion leaked into the bundle" \
  || ok "pre fixture: no 'Base directory for this skill' text in the bundle"
grep -q 'validateToken\|xxxxxxxxxx' "$INPUT_COPY" \
  && fail "pre fixture: tool_result content leaked into the bundle" \
  || ok "pre fixture: no tool output in the bundle"
[ "$(section '## tokens' | tr -d '\n')" = "60200 200000" ] \
  && ok "pre fixture: tokens section is 60200 200000" \
  || fail "pre fixture: tokens section is '$(section '## tokens' | tr -d '\n')'"
[ "$(last_field tokens_used)" = "60200" ] \
  && ok "pre fixture: written grade carries tokens_used 60200 from the transcript" \
  || fail "pre fixture: written grade tokens_used is $(last_field tokens_used)"
[ ! -s "$TMP/hook.err" ] && ok "pre fixture: nothing on stderr" || fail "pre fixture: stderr: $(cat "$TMP/hook.err")"

# 4b. pre with a missing transcript: empty window, warning, grade still written
stage_grade pre 1000
rc="$(run_hook "$PRE_HOOK" "$(payload UserPromptSubmit "$TMP/gone.jsonl" '{"prompt":"hello"}')")"
[ "$rc" = "0" ] && ok "pre missing: hook exits 0" || fail "pre missing: exit $rc"
check "pre missing: last 3 turns section is []" "$(section '## last 3 turns')" '. == []'
[ "$(section '## tokens' | tr -d '\n')" = "0 200000" ] && ok "pre missing: tokens section is 0 200000" || fail "pre missing: tokens '$(section '## tokens')'"
grep -q '^contextbuddy: .*transcript' "$TMP/hook.err" && ok "pre missing: warning on stderr" || fail "pre missing: no warning ($(cat "$TMP/hook.err"))"
[ "$(last_field tokens_used)" = "1000" ] && ok "pre missing: grader's tokens_used kept when the transcript has none" || fail "pre missing: tokens_used $(last_field tokens_used)"
[ -f "$SESSION_DIR/turns/002-pre.json" ] && ok "pre missing: grade written" || fail "pre missing: no turns/002-pre.json"

# 4c. three consecutive Stops whose transcript edits src/auth/jwt.ts → loop
stage_grade post 7
for i in 1 2 3; do
  rc="$(run_hook "$POST_HOOK" "$(payload Stop "$LOOP_T" '{"stop_reason":"end_turn","last_assistant_message":"Done."}')")"
  [ "$rc" = "0" ] && ok "post $i: hook exits 0" || fail "post $i: exit $rc ($(cat "$TMP/hook.err"))"
  if [ "$i" -lt 3 ]; then
    [ "$(last_field dominant_signal)" = "null" ] && ok "post $i: no loop after $i edit(s)" || fail "post $i: dominant_signal '$(last_field dominant_signal)'"
  else
    [ "$(last_field dominant_signal)" = "loop" ] \
      && ok "post 3: third consecutive edit of src/auth/jwt.ts sets dominant_signal loop" \
      || fail "post 3: dominant_signal '$(last_field dominant_signal)'"
  fi
done
check "post: edits.jsonl records the transcript's edited file" "$(tail -n 1 "$SESSION_DIR/edits.jsonl")" '.files == ["src/auth/jwt.ts"]'
[ "$(last_field tokens_used)" = "1000" ] && ok "post: written grade carries the transcript's tokens_used" || fail "post: tokens_used $(last_field tokens_used)"
check "post: last 3 turns section holds this turn's prompt last" "$(section '## last 3 turns')" '. == ["first prompt","fix the expiry check in jwt.ts"]'
grep -q 'loop detection' "$SESSION_DIR/suggestions.md" 2>/dev/null || grep -q 'same file edited' "$SESSION_DIR/suggestions.md" \
  && ok "post: suggestions.md notes the loop" || fail "post: suggestions.md has no loop entry"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
