#!/usr/bin/env bash
# test_user_prompt_submit_shadow — the UserPromptSubmit hook spawns the Jev shadow
# grader only when a TypeSafe key is present, and never touches the Haiku path.
#
# Runs the real hook under a throwaway HOME with a stub `claude` on PATH (the Haiku
# grader exits 5 without CONTEXTBUDDY_CLAUDE_CONFIG_DIR, so no Haiku file is written either way)
# and a stub runner via CONTEXTBUDDY_JEV_RUNNER that records how it was called.
# shellcheck disable=SC2015  # `A && ok || fail` is the intended assertion idiom here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HOOK="$REPO/plugin/hooks/user_prompt_submit.sh"
# shellcheck source=../../plugin/lib/project_hash.sh
. "$REPO/plugin/lib/project_hash.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/project" "$TMP/project-nokey"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/claude"; chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"
unset CONTEXTBUDDY_CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY  # keep the Haiku path inert whatever the dev shell has

STUB="$TMP/bin/jev_stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Records argv and whether the key reached the child; never prints the key.
{
  printf 'argv:%s\n' "$*"
  [ -n "${TYPESAFE_API_KEY:-}" ] && printf 'key:present\n' || printf 'key:absent\n'
  # The payload file must still exist when we run (hook must not delete it under us).
  for a in "$@"; do [ -f "$a" ] && printf 'payload_exists:yes\n'; done
} >> "$0.log"
STUBEOF
chmod +x "$STUB"

# The runner is spawned detached; poll for its log instead of a fixed sleep.
wait_log() {
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -f "$STUB.log" ] && [ "$(grep -c '^argv:' "$STUB.log")" -ge "${1:-1}" ] && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

PAYLOAD='{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"UserPromptSubmit","prompt":"hello there"}'
SESSION_ROOT="$HOME/.claude/inspector/sessions"
SESSION_DIR="$SESSION_ROOT/$(project_hash "$TMP/project")"

run_hook() {
  # run_hook [project_dir]  — each project dir is its own session (own turn counter).
  ( cd "${1:-$TMP/project}" && printf '%s' "$PAYLOAD" | bash "$HOOK" >"$TMP/hook.out" 2>"$TMP/hook.err" )
  echo $?
}

# --- 1. key unset: exit 0, no runner call, no jev files -------------------------------
# Own project dir: a prompt consumes a turn number even with no grader, and the
# sections below assert on turn 1 / turn 2 of a fresh session.
unset TYPESAFE_API_KEY
rm -f "$STUB.log"
rc="$(CONTEXTBUDDY_JEV_RUNNER="$STUB" run_hook "$TMP/project-nokey")"
[ "$rc" = "0" ] && ok "key unset: hook exits 0" || fail "key unset: hook exit $rc"
[ ! -f "$STUB.log" ] && ok "key unset: runner not spawned" || fail "key unset: runner was spawned"
[ -z "$(find "$SESSION_ROOT" -name '*.jev.json' -o -name 'jev.jsonl' 2>/dev/null)" ] \
  && ok "key unset: no jev files" || fail "key unset: jev files written"
[ -s "$TMP/hook.out" ] && fail "key unset: hook wrote to stdout" || ok "key unset: hook stdout empty"
grep -q 'No such file' "$TMP/hook.err" && fail "key unset: stderr noise: $(grep 'No such file' "$TMP/hook.err")" || ok "key unset: no missing-file noise on stderr"

# --- 2. key set via env: runner spawned once with payload path + turn ------------------
rm -f "$STUB.log"
rc="$(TYPESAFE_API_KEY=not-a-real-key CONTEXTBUDDY_JEV_RUNNER="$STUB" run_hook)"
wait_log 1 || true
[ "$rc" = "0" ] && ok "key set: hook exits 0" || fail "key set: hook exit $rc"
if [ -f "$STUB.log" ]; then
  n="$(grep -c '^argv:' "$STUB.log")"
  [ "$n" = "1" ] && ok "key set: runner spawned exactly once" || fail "key set: runner spawned $n times"
  grep -q '^key:present' "$STUB.log" && ok "key set: key reached the child" || fail "key set: key missing in child"
  grep -q 'payload_exists:yes' "$STUB.log" && ok "key set: payload file present for child" || fail "key set: payload file missing"
  grep -q -- '--turn 1\b' "$STUB.log" && ok "key set: turn 1 passed to child" || fail "key set: turn not passed: $(cat "$STUB.log")"
else
  fail "key set: runner never spawned"
fi
[ -s "$TMP/hook.out" ] && fail "key set: hook wrote to stdout" || ok "key set: hook stdout empty"

# --- 2b. second prompt, Haiku still skipping: the turn counter advances anyway --------
# Issue #14: nothing wrote turns/NNN-pre.json, so a file-max derivation repeats turn 1
# and every shadow row overwrites the last. The counter must advance regardless.
rm -f "$STUB.log"
rc="$(TYPESAFE_API_KEY=not-a-real-key CONTEXTBUDDY_JEV_RUNNER="$STUB" run_hook)"
wait_log 1 || true
[ "$rc" = "0" ] && ok "second prompt: hook exits 0" || fail "second prompt: hook exit $rc"
[ -f "$STUB.log" ] && grep -q -- '--turn 2\b' "$STUB.log" \
  && ok "second prompt: turn 2 passed to child (Haiku skipped)" \
  || fail "second prompt: expected --turn 2, got: $(grep '^argv:' "$STUB.log" 2>/dev/null)"

# --- 2c. an existing Haiku turn file still counts: counter seeds from max(turns/) -----
# Sessions graded before the counter existed have NNN-{pre,post}.json but no counter;
# the next number must clear them so no earlier file is overwritten.
rm -f "$STUB.log"
TURNS_DIR="$SESSION_DIR/turns"
[ -d "$TURNS_DIR" ] && printf '{}\n' > "$TURNS_DIR/009-pre.json" || fail "existing 009-pre.json: turns dir not found"
rc="$(TYPESAFE_API_KEY=not-a-real-key CONTEXTBUDDY_JEV_RUNNER="$STUB" run_hook)"
wait_log 1 || true
[ -f "$STUB.log" ] && grep -q -- '--turn 10\b' "$STUB.log" \
  && ok "existing 009-pre.json: next turn is 10" \
  || fail "existing 009-pre.json: expected --turn 10, got: $(grep '^argv:' "$STUB.log" 2>/dev/null)"
rm -f "$TURNS_DIR/009-pre.json"

# --- 3. key from .env in the project cwd ----------------------------------------------
rm -f "$STUB.log"
printf 'OTHER=1\nTYPESAFE_API_KEY="from-dotenv"\n' > "$TMP/project/.env"
unset TYPESAFE_API_KEY
rc="$(CONTEXTBUDDY_JEV_RUNNER="$STUB" run_hook)"
wait_log 1 || true
[ "$rc" = "0" ] && ok "dotenv: hook exits 0" || fail "dotenv: hook exit $rc"
[ -f "$STUB.log" ] && grep -q '^key:present' "$STUB.log" && ok "dotenv: key loaded from .env" || fail "dotenv: key not loaded"
rm -f "$TMP/project/.env"

# --- 4. runner missing: exit 0, silent --------------------------------------------------
rc="$(TYPESAFE_API_KEY=x CONTEXTBUDDY_JEV_RUNNER="$TMP/bin/does-not-exist" run_hook)"
[ "$rc" = "0" ] && ok "runner missing: hook exits 0" || fail "runner missing: hook exit $rc"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
