#!/usr/bin/env bash
# test_user_prompt_submit_shadow — the UserPromptSubmit hook spawns the Jev shadow
# grader only when a TypeSafe key is present, and never touches the Haiku path.
#
# Runs the real hook under a throwaway HOME with a stub `claude` on PATH (the Haiku
# grader exits 5 without ANTHROPIC_API_KEY, so no Haiku file is written either way)
# and a stub runner via CONTEXTBUDDY_JEV_RUNNER that records how it was called.
# shellcheck disable=SC2015  # `A && ok || fail` is the intended assertion idiom here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HOOK="$REPO/plugin/hooks/user_prompt_submit.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/project"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/claude"; chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"

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

PAYLOAD='{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"UserPromptSubmit","prompt":"hello there"}'
SESSION_ROOT="$HOME/.claude/inspector/sessions"

run_hook() {
  ( cd "$TMP/project" && printf '%s' "$PAYLOAD" | bash "$HOOK" >"$TMP/hook.out" 2>"$TMP/hook.err" )
  echo $?
}

# --- 1. key unset: exit 0, no runner call, no jev files -------------------------------
unset TYPESAFE_API_KEY
rm -f "$STUB.log"
rc="$(CONTEXTBUDDY_JEV_RUNNER="$STUB" run_hook)"
[ "$rc" = "0" ] && ok "key unset: hook exits 0" || fail "key unset: hook exit $rc"
[ ! -f "$STUB.log" ] && ok "key unset: runner not spawned" || fail "key unset: runner was spawned"
[ -z "$(find "$SESSION_ROOT" -name '*.jev.json' -o -name 'jev.jsonl' 2>/dev/null)" ] \
  && ok "key unset: no jev files" || fail "key unset: jev files written"
[ -s "$TMP/hook.out" ] && fail "key unset: hook wrote to stdout" || ok "key unset: hook stdout empty"

# --- 2. key set via env: runner spawned once with payload path + turn ------------------
rm -f "$STUB.log"
rc="$(TYPESAFE_API_KEY=not-a-real-key CONTEXTBUDDY_JEV_RUNNER="$STUB" run_hook)"
sleep 0.5
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

# --- 3. key from .env in the project cwd ----------------------------------------------
rm -f "$STUB.log"
printf 'OTHER=1\nTYPESAFE_API_KEY="from-dotenv"\n' > "$TMP/project/.env"
unset TYPESAFE_API_KEY
rc="$(CONTEXTBUDDY_JEV_RUNNER="$STUB" run_hook)"
sleep 0.5
[ "$rc" = "0" ] && ok "dotenv: hook exits 0" || fail "dotenv: hook exit $rc"
[ -f "$STUB.log" ] && grep -q '^key:present' "$STUB.log" && ok "dotenv: key loaded from .env" || fail "dotenv: key not loaded"
rm -f "$TMP/project/.env"

# --- 4. runner missing: exit 0, silent --------------------------------------------------
rc="$(TYPESAFE_API_KEY=x CONTEXTBUDDY_JEV_RUNNER="$TMP/bin/does-not-exist" run_hook)"
[ "$rc" = "0" ] && ok "runner missing: hook exits 0" || fail "runner missing: hook exit $rc"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
