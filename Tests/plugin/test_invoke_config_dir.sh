#!/usr/bin/env bash
# test_invoke_config_dir — grader/invoke.sh dispatches the Haiku grade through `claude -p`
# authenticated as the second Claude account (CLAUDE_CONFIG_DIR), never through
# ANTHROPIC_API_KEY, and marks the child so the plugin's own hooks do not re-fire.
#
# Runs the real invoke.sh with a stub `claude` on PATH that records its argv and the env
# it received, then prints a fixed §4.1 grade. No network, no keys.
# shellcheck disable=SC2015  # `A && ok || fail` is the intended assertion idiom here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
INVOKE="$REPO/plugin/grader/invoke.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/cfg" "$TMP/project"
export PATH="$TMP/bin:$PATH"

STUB="$TMP/bin/claude"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Records how it was called; prints a valid grade. Never echoes secrets.
{
  printf 'argv:%s\n' "$*"
  printf 'skip:%s\n' "${CONTEXTBUDDY_SKIP:-unset}"
  printf 'config_dir:%s\n' "${CLAUDE_CONFIG_DIR:-unset}"
  [ -n "${ANTHROPIC_API_KEY:-}" ] && printf 'api_key:present\n' || printf 'api_key:absent\n'
  printf 'cwd:%s\n' "$PWD"
} >> "$0.log"
printf '{"schema_version":1,"phase":"pre","turn":1,"timestamp":"2026-01-01T00:00:00Z","scores":{"confidence":{"value":7,"rationale":"r"},"atomicity":{"value":7,"rationale":"r"},"drift":{"value":2,"rationale":"r"},"pollution":{"value":2,"rationale":"r"}},"tokens_used":10,"tokens_limit":200000,"dominant_signal":null,"summary_update":"s"}\n'
STUBEOF
chmod +x "$STUB"

SYS="$TMP/system_prompt.md"; printf 'You are the grader.\n' > "$SYS"
IN="$TMP/input.md";          printf '## latest prompt\nhello\n' > "$IN"
MODEL="claude-haiku-4-5-20251001"
LEAK="parent-key-must-not-leak"

run_invoke() {
  ( cd "$TMP/project" && bash "$INVOKE" "$SYS" "$IN" "$MODEL" >"$TMP/out" 2>"$TMP/err" )
  echo $?
}
calls() { [ -f "$STUB.log" ] && grep -c '^argv:' "$STUB.log" || echo 0; }

# --- 1. config dir from env: grade emitted through `claude -p` on that account ----------
rm -f "$STUB.log"
rc="$(CONTEXTBUDDY_CLAUDE_CONFIG_DIR="$TMP/cfg" ANTHROPIC_API_KEY="$LEAK" run_invoke)"
[ "$rc" = "0" ] && ok "env: invoke exits 0" || fail "env: invoke exit $rc: $(cat "$TMP/err")"
jq -e '.schema_version == 1 and .scores.confidence.value == 7' "$TMP/out" >/dev/null 2>&1 \
  && ok "env: grade JSON passed through" || fail "env: stdout is not the grade: $(cat "$TMP/out")"
[ "$(calls)" = "1" ] && ok "env: claude called exactly once" || fail "env: claude called $(calls) times"
grep -q "^config_dir:$TMP/cfg\$" "$STUB.log" && ok "env: CLAUDE_CONFIG_DIR reached claude" \
  || fail "env: CLAUDE_CONFIG_DIR not set for claude: $(grep '^config_dir:' "$STUB.log")"
grep -q '^skip:1$' "$STUB.log" && ok "env: CONTEXTBUDDY_SKIP=1 reached claude" \
  || fail "env: CONTEXTBUDDY_SKIP missing: $(grep '^skip:' "$STUB.log")"
grep -q '^api_key:absent$' "$STUB.log" && ok "env: ANTHROPIC_API_KEY scrubbed from claude env" \
  || fail "env: ANTHROPIC_API_KEY leaked into claude env"
grep -qE '^argv:.*(^| )(-p|--print)( |$)' "$STUB.log" && ok "env: print mode (-p)" || fail "env: no -p in argv"
grep -qE -- "--model $MODEL" "$STUB.log" && ok "env: model forwarded" || fail "env: model missing in argv"
grep -qE -- '--bare' "$STUB.log" && fail "env: --bare still present (forbids OAuth)" || ok "env: no --bare"
grep -q "^cwd:$TMP/project\$" "$STUB.log" && fail "env: claude ran inside the project dir (would load its CLAUDE.md/settings)" \
  || ok "env: claude ran from a neutral cwd"
grep -q "$LEAK" "$TMP/out" "$TMP/err" "$STUB.log" && fail "env: key value leaked to output/log" || ok "env: no key value in output/log"

# --- 2. nothing configured: skip, no call, nothing on stdout --------------------------
rm -f "$STUB.log"
unset CONTEXTBUDDY_CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY
rc="$(run_invoke)"
[ "$rc" != "0" ] && ok "unset: invoke exits non-zero" || fail "unset: invoke exited 0"
[ ! -s "$TMP/out" ] && ok "unset: stdout empty" || fail "unset: stdout not empty"
grep -qi 'skip' "$TMP/err" && ok "unset: stderr explains the skip" || fail "unset: stderr silent: $(cat "$TMP/err")"
[ "$(calls)" = "0" ] && ok "unset: claude not called" || fail "unset: claude was called"

# --- 3. configured dir missing on disk: skip, no call ---------------------------------
rm -f "$STUB.log"
rc="$(CONTEXTBUDDY_CLAUDE_CONFIG_DIR="$TMP/does-not-exist" run_invoke)"
[ "$rc" != "0" ] && ok "missing dir: invoke exits non-zero" || fail "missing dir: invoke exited 0"
[ "$(calls)" = "0" ] && ok "missing dir: claude not called" || fail "missing dir: claude was called"
grep -q 'does-not-exist' "$TMP/err" && ok "missing dir: stderr names the path" || fail "missing dir: stderr: $(cat "$TMP/err")"

# --- 4. config dir from .env in the project cwd (same lookup as TYPESAFE_API_KEY) -------
rm -f "$STUB.log"
printf 'CONTEXTBUDDY_CLAUDE_CONFIG_DIR="%s"\n' "$TMP/cfg" > "$TMP/project/.env"
rc="$(run_invoke)"
rm -f "$TMP/project/.env"
[ "$rc" = "0" ] && ok "dotenv: invoke exits 0" || fail "dotenv: invoke exit $rc: $(cat "$TMP/err")"
[ -f "$STUB.log" ] && grep -q "^config_dir:$TMP/cfg\$" "$STUB.log" && ok "dotenv: config dir loaded from .env" \
  || fail "dotenv: config dir not loaded from .env"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
