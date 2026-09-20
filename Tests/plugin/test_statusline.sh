#!/usr/bin/env bash
# test_statusline — plugin/statusline.sh renders the token pair from last.json; a 1M window
# prints as 1M, not 1000k (issue #47). Runs the real script under a throwaway HOME.
# shellcheck disable=SC2015  # `A && ok || fail` is the intended assertion idiom here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STATUSLINE="$REPO/plugin/statusline.sh"
# shellcheck source=../../plugin/lib/project_hash.sh
. "$REPO/plugin/lib/project_hash.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

if ! command -v jq >/dev/null 2>&1; then
  printf 'test_statusline: jq is required to run these tests.\n' >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$TMP/project"
SESSION_DIR="$HOME/.claude/inspector/sessions/$(project_hash "$TMP/project")"
mkdir -p "$SESSION_DIR"

# stage <used> <limit> [dominant]
stage() {
  jq -c -n --argjson used "$1" --argjson lim "$2" --arg dom "${3:-}" '{
    schema_version: 1, phase: "pre", turn: 1, timestamp: "2026-09-19T00:00:00Z",
    scores: {confidence: {value: 8, rationale: "r"}, atomicity: {value: 7, rationale: "r"},
             drift: {value: 2, rationale: "r"}, pollution: {value: 3, rationale: "r"}},
    tokens_used: $used, tokens_limit: $lim, dominant_signal: (if $dom == "" then null else $dom end),
    summary_update: "s"
  }' > "$SESSION_DIR/last.json"
}
render() { ( cd "$TMP/project" && bash "$STATUSLINE" 2>/dev/null ) | sed 's/\x1b\[[0-9;]*m//g'; }
render_raw() { ( cd "$TMP/project" && bash "$STATUSLINE" 2>/dev/null ); }

stage 176474 1000000
out="$(render)"
case "$out" in *"⚡176k/1M"*) ok "1M window renders as 1M: $out" ;; *) fail "1M window: got '$out' (want ⚡176k/1M)" ;; esac

stage 47823 200000
out="$(render)"
case "$out" in *"⚡47k/200k"*) ok "200K window renders as 200k: $out" ;; *) fail "200K window: got '$out'" ;; esac

stage 1500000 1500000
out="$(render)"
case "$out" in *"⚡1.5M/1.5M"*) ok "fractional millions keep one decimal: $out" ;; *) fail "1.5M: got '$out'" ;; esac

stage 900 200000
out="$(render)"
case "$out" in *"⚡900/200k"*) ok "sub-thousand counts print in full: $out" ;; *) fail "900: got '$out'" ;; esac

stage 176474 1000000 context_pressure
out="$(render)"
case "$out" in *"conf:8 atom:7 drift:2 pol:3"*) ok "scores still rendered" ;; *) fail "scores: got '$out'" ;; esac

# harm maps to attention (yellow), not dizzy (orange) or green, even with clean scores
# (issue #7 hardening: StateMachine treats harm as attention, SPEC §5.2/§10.2).
stage 47823 200000 harm
raw="$(render_raw)"
case "$raw" in *$'\033[33m'*) ok "harm renders yellow despite clean scores" ;; *) fail "harm color: got '$raw'" ;; esac
case "$raw" in *$'\033[38;5;208m'*) fail "harm rendered orange (dizzy), not attention" ;; *) ok "harm not rendered orange" ;; esac
case "$raw" in *$'\033[32m'*) fail "harm rendered green" ;; *) ok "harm not rendered green" ;; esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
