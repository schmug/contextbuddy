#!/usr/bin/env bash
# test_grader_status — a grader that cannot run leaves a trace on disk (issue #92).
#
# The defect this guards: with no reachable API key the hooks created the session
# dir, wrote meta.json, edits.jsonl and turns/.counter, logged one line to stderr
# and exited 0. Hook stderr is surfaced nowhere a user looks, so the condition was
# indistinguishable from a quiet session and 22 of 37 session dirs on the reporter's
# disk had no grade and no explanation.
#
# The assertions below are the contract in SPEC.md §4.10: every grader attempt
# writes grader_status.json, the reason class comes from invoke.sh's exit code,
# and the record never carries anything the backend printed.
#
# Runs the real hooks under a throwaway HOME. No network, no API key — which is
# exactly the condition under test.
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
  printf 'test_grader_status: jq is required to run these tests.\n' >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/inspector" "$TMP/bin"
export PATH="$TMP/bin:$PATH"
# The condition under test: no key anywhere the hook can reach. dotenv.sh searches
# $PWD/.env, <git toplevel>/.env and <main checkout>/.env — the project dirs below
# are bare temp dirs outside any repo, so none of the three exists.
unset TYPESAFE_API_KEY ANTHROPIC_API_KEY CONTEXTBUDDY_CLAUDE_CONFIG_DIR
export CONTEXTBUDDY_NODE="$TMP/bin/node"

PRE_PAYLOAD='{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"UserPromptSubmit","prompt":"add a rate limiter to the upload endpoint"}'
POST_PAYLOAD='{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"Stop","last_assistant_message":"done"}'

write_config() {
  # write_config <backend>
  printf '[grader]\nbackend = "%s"\n' "$1" > "$HOME/.claude/inspector/config.toml"
}

# A node stub standing in for grader/jev.mjs. The typesafe arm of invoke.sh never
# reaches it without a key, so it exists only so the arm's node pre-flight passes
# and the *key* check is what fails.
cat > "$TMP/bin/node" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'contextbuddy: stub node should not have been reached\n' >&2
exit 3
STUBEOF
chmod +x "$TMP/bin/node"

run_hook() {
  # run_hook <hook> <project_dir> <payload>; echoes the exit code
  ( cd "$2" && printf '%s' "$3" | bash "$1" >"$TMP/hook.out" 2>"$TMP/hook.err" )
  echo $?
}

status_file() {
  printf '%s/.claude/inspector/sessions/%s/grader_status.json' "$HOME" "$(project_hash "$1")"
}

# --- 1. typesafe with no key: the whole point of issue #92 ---------------------------
write_config typesafe
PROJ="$TMP/nokey"
mkdir -p "$PROJ"
rc="$(run_hook "$PRE_HOOK" "$PROJ" "$PRE_PAYLOAD")"
STATUS="$(status_file "$PROJ")"

[ "$rc" = "0" ] && ok "no key: hook still exits 0 (SPEC §13)" \
  || fail "no key: hook exit $rc ($(cat "$TMP/hook.err"))"
[ -f "$STATUS" ] && ok "no key: grader_status.json written" \
  || fail "no key: no grader_status.json at $STATUS ($(cat "$TMP/hook.err"))"

if [ -f "$STATUS" ]; then
  jq -e . "$STATUS" >/dev/null 2>&1 && ok "no key: record is valid JSON" \
    || fail "no key: record is not valid JSON: $(cat "$STATUS")"
  [ "$(jq -r '.status' "$STATUS")" = "error" ] \
    && ok "no key: status is error" \
    || fail "no key: status is '$(jq -r '.status' "$STATUS")', expected error"
  [ "$(jq -r '.reason' "$STATUS")" = "missing_key" ] \
    && ok "no key: reason class is missing_key" \
    || fail "no key: reason is '$(jq -r '.reason' "$STATUS")', expected missing_key"
  [ "$(jq -r '.backend' "$STATUS")" = "typesafe" ] \
    && ok "no key: record names the backend" \
    || fail "no key: backend is '$(jq -r '.backend' "$STATUS")', expected typesafe"
  [ "$(jq -r '.phase' "$STATUS")" = "pre" ] \
    && ok "no key: record names the phase" \
    || fail "no key: phase is '$(jq -r '.phase' "$STATUS")', expected pre"
  [ "$(jq -r '.turn' "$STATUS")" = "1" ] \
    && ok "no key: record names the turn" \
    || fail "no key: turn is '$(jq -r '.turn' "$STATUS")', expected 1"
  [ "$(jq -r '.schema_version' "$STATUS")" = "1" ] \
    && ok "no key: schema_version is 1" \
    || fail "no key: schema_version is '$(jq -r '.schema_version' "$STATUS")'"
  jq -e '.detail | type == "string" and length > 0' "$STATUS" >/dev/null 2>&1 \
    && ok "no key: detail is a non-empty string" \
    || fail "no key: detail missing or not a string"
  # The record is one line, like every other JSON the plugin writes.
  [ "$(wc -l < "$STATUS" | tr -d ' ')" = "1" ] \
    && ok "no key: record is a single line" \
    || fail "no key: record spans $(wc -l < "$STATUS" | tr -d ' ') lines"
fi

# The session dir must no longer be the bare meta/edits/.counter shell the issue
# reported: something in it has to say why there is no grade.
SDIR="$HOME/.claude/inspector/sessions/$(project_hash "$PROJ")"
grep -rlq 'missing_key' "$SDIR" 2>/dev/null \
  && ok "no key: session dir carries a greppable missing_key trace" \
  || fail "no key: nothing under $SDIR mentions missing_key ($(ls -A "$SDIR"))"

# No grade was produced, so nothing may have been written to the grade files.
[ ! -f "$SDIR/last.json" ] && ok "no key: no last.json is written" \
  || fail "no key: last.json exists but no grade was produced"
[ ! -f "$SDIR/history.jsonl" ] && ok "no key: no history.jsonl is written" \
  || fail "no key: history.jsonl exists but no grade was produced"

# --- 2. the record never carries what the backend printed ----------------------------
# Both models consulted on this design flagged backend stderr as a credential leak
# path (an echoed Authorization header, an `sk-…` in a response body). detail is a
# fixed string per reason class, so nothing the grader saw can reach the file.
write_config typesafe
PROJ2="$TMP/leaky"
mkdir -p "$PROJ2"
export TYPESAFE_API_KEY="sk-test-NOTAREALKEY-0123456789"
cat > "$TMP/bin/node" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'contextbuddy: HTTP 401 from typesafe: {"error":"bad key %s"}\n' "${TYPESAFE_API_KEY:-}" >&2
exit 3
STUBEOF
chmod +x "$TMP/bin/node"
run_hook "$PRE_HOOK" "$PROJ2" "$PRE_PAYLOAD" >/dev/null
STATUS2="$(status_file "$PROJ2")"
unset TYPESAFE_API_KEY

if [ -f "$STATUS2" ]; then
  ok "backend failure: grader_status.json written"
  [ "$(jq -r '.reason' "$STATUS2")" = "transport_failure" ] \
    && ok "backend failure: exit 3 maps to transport_failure" \
    || fail "backend failure: reason is '$(jq -r '.reason' "$STATUS2")', expected transport_failure"
  grep -q 'NOTAREALKEY' "$STATUS2" \
    && fail "backend failure: the record contains the API key value" \
    || ok "backend failure: the record does not contain the key value"
  grep -q 'HTTP 401' "$STATUS2" \
    && fail "backend failure: the record echoes backend stderr" \
    || ok "backend failure: the record carries no backend stderr"
else
  fail "backend failure: no grader_status.json at $STATUS2"
fi

# --- 3. a working grader records status ok -------------------------------------------
# The anthropic backend with a stub `claude` is the cheapest working grader available
# offline. A stale error must not outlive the turn that fixed it.
write_config anthropic
mkdir -p "$TMP/cfg"
export CONTEXTBUDDY_CLAUDE_CONFIG_DIR="$TMP/cfg"
cat > "$TMP/bin/claude" <<'STUBEOF'
#!/usr/bin/env bash
cat <<'JSONEOF'
{"schema_version":1,"phase":"pre","turn":1,"timestamp":"2026-09-20T00:00:00Z",
 "scores":{"confidence":{"value":8,"rationale":"r"},"atomicity":{"value":8,"rationale":"r"},
 "drift":{"value":1,"rationale":"r"},"pollution":{"value":2,"rationale":"r"}},
 "tokens_used":1000,"tokens_limit":200000,"dominant_signal":null,"summary_update":"s"}
JSONEOF
STUBEOF
chmod +x "$TMP/bin/claude"
PROJ3="$TMP/working"
mkdir -p "$PROJ3"
run_hook "$PRE_HOOK" "$PROJ3" "$PRE_PAYLOAD" >/dev/null
STATUS3="$(status_file "$PROJ3")"
if [ -f "$STATUS3" ]; then
  [ "$(jq -r '.status' "$STATUS3")" = "ok" ] \
    && ok "working grader: status is ok" \
    || fail "working grader: status is '$(jq -r '.status' "$STATUS3")', expected ok"
  jq -e '.reason == null' "$STATUS3" >/dev/null 2>&1 \
    && ok "working grader: reason is null" \
    || fail "working grader: reason is '$(jq -r '.reason' "$STATUS3")', expected null"
  [ -f "$HOME/.claude/inspector/sessions/$(project_hash "$PROJ3")/last.json" ] \
    && ok "working grader: the grade still lands" \
    || fail "working grader: no last.json — the status write broke grading"
else
  fail "working grader: no grader_status.json at $STATUS3"
fi

# --- 4. a later ok overwrites an earlier error ---------------------------------------
# Grok's point on the design: the worse failure is a key that dies AFTER a healthy
# session, because last.json then keeps showing a good grade. The converse must hold
# too — a fixed key must clear the warning on the very next turn.
write_config typesafe
PROJ4="$TMP/recover"
mkdir -p "$PROJ4"
run_hook "$PRE_HOOK" "$PROJ4" "$PRE_PAYLOAD" >/dev/null
STATUS4="$(status_file "$PROJ4")"
[ "$(jq -r '.reason' "$STATUS4" 2>/dev/null)" = "missing_key" ] \
  && ok "recovery: first turn records missing_key" \
  || fail "recovery: first turn recorded '$(jq -r '.reason' "$STATUS4" 2>/dev/null)'"
write_config anthropic
run_hook "$PRE_HOOK" "$PROJ4" "$PRE_PAYLOAD" >/dev/null
[ "$(jq -r '.status' "$STATUS4" 2>/dev/null)" = "ok" ] \
  && ok "recovery: the next working turn clears the error" \
  || fail "recovery: status is still '$(jq -r '.status' "$STATUS4" 2>/dev/null)'"

# --- 5. the post hook records too ----------------------------------------------------
write_config typesafe
PROJ5="$TMP/posthook"
mkdir -p "$PROJ5"
rc="$(run_hook "$POST_HOOK" "$PROJ5" "$POST_PAYLOAD")"
STATUS5="$(status_file "$PROJ5")"
[ "$rc" = "0" ] && ok "post hook: exits 0 with no key" \
  || fail "post hook: exit $rc ($(cat "$TMP/hook.err"))"
if [ -f "$STATUS5" ]; then
  [ "$(jq -r '.phase' "$STATUS5")" = "post" ] \
    && ok "post hook: record names phase post" \
    || fail "post hook: phase is '$(jq -r '.phase' "$STATUS5")'"
  [ "$(jq -r '.reason' "$STATUS5")" = "missing_key" ] \
    && ok "post hook: reason class is missing_key" \
    || fail "post hook: reason is '$(jq -r '.reason' "$STATUS5")'"
else
  fail "post hook: no grader_status.json at $STATUS5"
fi

# --- 6. an unwritable session dir never aborts the turn (SPEC §13) -------------------
write_config typesafe
PROJ6="$TMP/readonly"
mkdir -p "$PROJ6"
RO_DIR="$HOME/.claude/inspector/sessions/$(project_hash "$PROJ6")"
mkdir -p "$RO_DIR/turns"
chmod 500 "$RO_DIR"
rc="$(run_hook "$PRE_HOOK" "$PROJ6" "$PRE_PAYLOAD")"
chmod 700 "$RO_DIR"
[ "$rc" = "0" ] && ok "unwritable session dir: hook still exits 0" \
  || fail "unwritable session dir: hook exit $rc ($(cat "$TMP/hook.err"))"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
