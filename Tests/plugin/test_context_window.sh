#!/usr/bin/env bash
# test_context_window — the per-model context window resolver (plugin/lib/context_window.sh,
# issue #47). Resolution order: CONTEXTBUDDY_CONTEXT_WINDOW override (env or .env) >
# Claude Code's auto-compact window (env or settings.json) > model table keyed on the last
# non-synthetic assistant record of the transcript > 200000 default; then the evidence
# floor raises any limit below tokens_used to the next tier. Asserted with jq; no network.
# shellcheck disable=SC2015  # `A && ok || fail` is the intended assertion idiom here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

if ! command -v jq >/dev/null 2>&1; then
  printf 'test_context_window: jq is required to run these tests.\n' >&2
  exit 2
fi

# shellcheck source=../../plugin/lib/context_window.sh
. "$REPO/plugin/lib/context_window.sh" || { printf 'plugin/lib/context_window.sh missing\n' >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude" "$TMP/project"
unset CONTEXTBUDDY_CONTEXT_WINDOW CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_DISABLE_1M_CONTEXT CLAUDE_CONFIG_DIR

# transcript <path> <model...> — one user record then one assistant record per model, in order.
transcript() {
  local path="$1"; shift
  printf '{"type":"user","message":{"role":"user","content":"hello"}}\n' > "$path"
  local m
  for m in "$@"; do
    printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":2,"cache_read_input_tokens":100,"cache_creation_input_tokens":50}}}\n' "$m" >> "$path"
  done
}
FABLE="$TMP/fable.jsonl";   transcript "$FABLE" claude-fable-5-1
HAIKU="$TMP/haiku.jsonl";   transcript "$HAIKU" claude-haiku-4-5-20251001
MIXED="$TMP/mixed.jsonl";   transcript "$MIXED" claude-haiku-4-5-20251001 claude-fable-5-1 '<synthetic>'
UNKNOWN="$TMP/unknown.jsonl"; transcript "$UNKNOWN" claude-nova-9
NOASSIST="$TMP/noassist.jsonl"; printf '{"type":"user","message":{"content":"x"}}\n' > "$NOASSIST"

# resolve <transcript> <used> — runs the resolver from the throwaway project dir (dotenv reads $PWD/.env).
resolve() { ( cd "$TMP/project" && resolve_context_window "$1" "$2" ); }
# field <json> <key>
field() { printf '%s' "$1" | jq -r "$2"; }
# assert_ctx <label> <json> <model> <limit> <source>
assert_ctx() {
  local label="$1" json="$2" model="$3" limit="$4" source="$5"
  [ "$(field "$json" '.model // "null"')" = "$model" ] && ok "$label: model $model" || fail "$label: model $(field "$json" '.model') (want $model)"
  [ "$(field "$json" '.tokens_limit')" = "$limit" ] && ok "$label: tokens_limit $limit" || fail "$label: tokens_limit $(field "$json" '.tokens_limit') (want $limit)"
  [ "$(field "$json" '.limit_source')" = "$source" ] && ok "$label: limit_source $source" || fail "$label: limit_source $(field "$json" '.limit_source') (want $source)"
}

# --- 1. parse_token_count accepts the /autocompact spellings -------------------------------
[ "$(parse_token_count 500k)" = "500000" ] && ok "parse 500k" || fail "parse 500k -> $(parse_token_count 500k)"
[ "$(parse_token_count 500K)" = "500000" ] && ok "parse 500K" || fail "parse 500K"
[ "$(parse_token_count 1m)" = "1000000" ] && ok "parse 1m" || fail "parse 1m"
[ "$(parse_token_count 300000)" = "300000" ] && ok "parse 300000" || fail "parse 300000"
parse_token_count abc >/dev/null 2>&1 && fail "parse abc accepted" || ok "parse abc rejected"
parse_token_count 0 >/dev/null 2>&1 && fail "parse 0 accepted" || ok "parse 0 rejected"
parse_token_count "" >/dev/null 2>&1 && fail "parse empty accepted" || ok "parse empty rejected"

# --- 2. model table ----------------------------------------------------------------------
for m in claude-fable-5-1 claude-mythos-5-1 claude-sonnet-5 claude-opus-5 claude-opus-4-8 claude-opus-4-7-20260301; do
  [ "$(context_window_for_model "$m")" = "1000000" ] && ok "table: $m is 1M" || fail "table: $m -> $(context_window_for_model "$m")"
done
for m in claude-haiku-4-5-20251001 claude-sonnet-4-6 claude-opus-4-6 claude-sonnet-4-5-20250929 claude-opus-4-5 claude-nova-9 ""; do
  [ "$(context_window_for_model "$m")" = "200000" ] && ok "table: '$m' is 200K" || fail "table: '$m' -> $(context_window_for_model "$m")"
done
[ "$(CLAUDE_CODE_DISABLE_1M_CONTEXT=1 context_window_for_model claude-fable-5-1)" = "200000" ] \
  && ok "table: CLAUDE_CODE_DISABLE_1M_CONTEXT=1 forces 200K" || fail "table: DISABLE_1M ignored"

# --- 3. transcript model: last non-synthetic assistant record --------------------------------
assert_ctx "fable" "$(resolve "$FABLE" 176474)" claude-fable-5-1 1000000 model
assert_ctx "haiku" "$(resolve "$HAIKU" 176474)" claude-haiku-4-5-20251001 200000 model
assert_ctx "synthetic tail skipped" "$(resolve "$MIXED" 1000)" claude-fable-5-1 1000000 model
assert_ctx "unknown model is conservative" "$(resolve "$UNKNOWN" 1000)" claude-nova-9 200000 model
assert_ctx "no assistant record" "$(resolve "$NOASSIST" 0)" null 200000 default
assert_ctx "missing transcript" "$(resolve "$TMP/nope.jsonl" 0)" null 200000 default
assert_ctx "empty path" "$(resolve "" 0)" null 200000 default

# The last assistant record can sit far from the end (a long run of tool results after it).
DEEP="$TMP/deep.jsonl"; transcript "$DEEP" claude-fable-5-1
for _ in $(seq 1 600); do printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}\n' >> "$DEEP"; done
assert_ctx "assistant record deep in the file" "$(resolve "$DEEP" 1000)" claude-fable-5-1 1000000 model

# --- 4. override wins outright --------------------------------------------------------------
assert_ctx "env override" "$(CONTEXTBUDDY_CONTEXT_WINDOW=300000 resolve "$FABLE" 1000)" claude-fable-5-1 300000 override
printf 'CONTEXTBUDDY_CONTEXT_WINDOW="250k"\n' > "$TMP/project/.env"
assert_ctx "dotenv override" "$(resolve "$FABLE" 1000)" claude-fable-5-1 250000 override
rm -f "$TMP/project/.env"
assert_ctx "env override beats autocompact" "$(CONTEXTBUDDY_CONTEXT_WINDOW=300000 CLAUDE_CODE_AUTO_COMPACT_WINDOW=500k resolve "$FABLE" 1000)" claude-fable-5-1 300000 override
assert_ctx "unparseable override is ignored" "$(CONTEXTBUDDY_CONTEXT_WINDOW=lots resolve "$HAIKU" 1000)" claude-haiku-4-5-20251001 200000 model

# --- 5. auto-compact window ----------------------------------------------------------------
assert_ctx "autocompact env" "$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=500k resolve "$FABLE" 1000)" claude-fable-5-1 500000 autocompact
printf '{"autoCompactWindow":"500k"}\n' > "$HOME/.claude/settings.json"
assert_ctx "autocompact settings.json string" "$(resolve "$FABLE" 1000)" claude-fable-5-1 500000 autocompact
printf '{"autoCompactWindow":400000}\n' > "$HOME/.claude/settings.json"
assert_ctx "autocompact settings.json number" "$(resolve "$FABLE" 1000)" claude-fable-5-1 400000 autocompact
rm -f "$HOME/.claude/settings.json"
mkdir -p "$TMP/cfgdir"; printf '{"autoCompactWindow":"500k"}\n' > "$TMP/cfgdir/settings.json"
assert_ctx "autocompact under CLAUDE_CONFIG_DIR" "$(CLAUDE_CONFIG_DIR="$TMP/cfgdir" resolve "$FABLE" 1000)" claude-fable-5-1 500000 autocompact
assert_ctx "no autocompact key falls through to the model" "$(resolve "$FABLE" 1000)" claude-fable-5-1 1000000 model
printf 'not json\n' > "$HOME/.claude/settings.json"
assert_ctx "unreadable settings.json falls through" "$(resolve "$HAIKU" 1000)" claude-haiku-4-5-20251001 200000 model
rm -f "$HOME/.claude/settings.json"

# --- 6. evidence floor: never a limit below tokens_used ------------------------------------
assert_ctx "haiku at 250065 raised to 1M" "$(resolve "$HAIKU" 250065)" claude-haiku-4-5-20251001 1000000 observed
assert_ctx "override 300000 at 345106 raised to 1M" "$(CONTEXTBUDDY_CONTEXT_WINDOW=300000 resolve "$FABLE" 345106)" claude-fable-5-1 1000000 observed
assert_ctx "beyond the last tier the limit is tokens_used" "$(resolve "$FABLE" 1200000)" claude-fable-5-1 1200000 observed
assert_ctx "tokens_used == limit is not raised" "$(resolve "$HAIKU" 200000)" claude-haiku-4-5-20251001 200000 model
assert_ctx "no transcript at 250065 raised to 1M" "$(resolve "" 250065)" null 1000000 observed
[ "$(context_window_floor 250065 200000 model)" = "1000000 observed" ] && ok "context_window_floor raises" || fail "context_window_floor -> $(context_window_floor 250065 200000 model)"
[ "$(context_window_floor 1000 200000 model)" = "200000 model" ] && ok "context_window_floor keeps" || fail "context_window_floor -> $(context_window_floor 1000 200000 model)"

# --- 7. payload entry point used by the hooks -----------------------------------------------
payload="$(jq -n --arg t "$FABLE" '{session_id:"s",transcript_path:$t,prompt:"hi",tokens_used:176474}')"
ctx="$( cd "$TMP/project" && context_window_for_payload "$payload" )"
assert_ctx "payload" "$ctx" claude-fable-5-1 1000000 model
[ "$(field "$ctx" '.tokens_used')" = "176474" ] && ok "payload: tokens_used carried" || fail "payload: tokens_used $(field "$ctx" '.tokens_used')"
ctx="$( cd "$TMP/project" && context_window_for_payload '{}' )"
assert_ctx "empty payload" "$ctx" null 200000 default
[ "$(field "$ctx" '.tokens_used')" = "0" ] && ok "empty payload: tokens_used 0" || fail "empty payload: tokens_used $(field "$ctx" '.tokens_used')"
ctx="$( cd "$TMP/project" && context_window_for_payload 'not json' )"
assert_ctx "unparseable payload" "$ctx" null 200000 default

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
