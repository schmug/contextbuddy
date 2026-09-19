#!/usr/bin/env bash
# context_window — resolve the session's context window (tokens_limit) per model (issue #47).
#
# Claude Code hook payloads carry no model or context-window field, so the plugin used to
# hardcode 200000. That is right for Haiku 4.5 and wrong for every native-1M model (Fable,
# Mythos, Sonnet 5, Opus 5, Opus 4.7+), which showed 88% pressure and went dizzy at 176k.
#
# Resolution order, first hit wins (mirrored by grader/jev.mjs resolveContextWindow and
# grader/jev_shadow.py resolve_context_window; the prefix table is lib/context_windows.json,
# read by all three):
#   1. override    CONTEXTBUDDY_CONTEXT_WINDOW in the environment or a .env (lib/dotenv.sh;
#                  not config.toml — Sources/ContextBuddyCore/Schemas.swift drops the whole
#                  file on an unknown key). Accepts 300000 / 300k / 1m.
#   2. autocompact CLAUDE_CODE_AUTO_COMPACT_WINDOW, else autoCompactWindow in
#                  ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json (what /autocompact writes).
#   3. model       message.model of the last type:"assistant" record in the transcript that
#                  is not "<synthetic>", looked up by prefix in context_windows.json. Unknown
#                  ids are 200000 (conservative). CLAUDE_CODE_DISABLE_1M_CONTEXT=1 forces
#                  200000 on the 1M rows.
#   4. default     no transcript or no model: 200000.
# Then the evidence floor: a limit below tokens_used is provably wrong, so it is raised to
# the next tier (200000 -> 1000000; past the last tier, to tokens_used itself) and
# limit_source becomes "observed". No grade is ever written with tokens_used > tokens_limit.
#
# Budget: two jq passes over `tail -n 400` of the transcript plus one over settings.json.
# No API calls, no `claude` invocation. Without jq everything resolves to the default.
# Bash 3.2; every failure degrades to the default rather than erroring (SPEC.md §13).
#
# Usage:
#   . plugin/lib/context_window.sh
#   resolve_context_window <transcript_path> <tokens_used>
#     -> {"model":"claude-fable-5-1","tokens_used":176474,"tokens_limit":1000000,"limit_source":"model"}
#   context_window_for_payload <hook_payload_json>   # reads transcript_path + tokens_used from it
#   context_window_for_model <model_id>              # table lookup only
#   context_window_floor <tokens_used> <limit> <source>  -> "<limit> <source>"
#   parse_token_count "500k"                          -> 500000 (exit 1 when unparseable)

CONTEXT_WINDOW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dotenv.sh
. "$CONTEXT_WINDOW_LIB_DIR/dotenv.sh"
CONTEXT_WINDOWS_JSON="$CONTEXT_WINDOW_LIB_DIR/context_windows.json"
CONTEXT_WINDOW_DEFAULT=200000
CONTEXT_WINDOW_TAIL_LINES=400

# parse_token_count <text> — 300000, 300k, 1m (case-insensitive; spaces, commas and
# underscores ignored). Prints the integer; exit 1 for anything else, including 0.
parse_token_count() {
  local v n mult=1
  v="$(printf '%s' "${1:-}" | tr -d ' _,' | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    *k) n="${v%k}"; mult=1000 ;;
    *m) n="${v%m}"; mult=1000000 ;;
    *) n="$v" ;;
  esac
  printf '%s' "$n" | grep -qE '^[0-9]+$' || return 1
  n=$((10#$n * mult))
  [ "$n" -gt 0 ] || return 1
  printf '%s' "$n"
}

# transcript_model <transcript_path> — message.model of the last non-synthetic assistant
# record; empty when the file is missing, unreadable, or has none. Reads the tail first
# and falls back to the whole file only when the tail holds no assistant record (a long
# run of tool results can follow the last reply).
transcript_model() {
  local path="${1:-}"
  [ -n "$path" ] && [ -f "$path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local filter='fromjson? | select(type == "object" and .type == "assistant") | .message.model? // empty | strings | select(. != "<synthetic>")'
  local m
  m="$(tail -n "$CONTEXT_WINDOW_TAIL_LINES" "$path" 2>/dev/null | jq -R -r "$filter" 2>/dev/null | tail -n 1)"
  if [ -z "$m" ]; then
    m="$(jq -R -r "$filter" "$path" 2>/dev/null | tail -n 1)"
  fi
  printf '%s' "$m"
}

# context_window_for_model <model_id> — first matching prefix in context_windows.json,
# else the default. CLAUDE_CODE_DISABLE_1M_CONTEXT=1 caps the 1M rows at the default.
context_window_for_model() {
  local model="${1:-}" w=""
  if [ -n "$model" ] && [ -f "$CONTEXT_WINDOWS_JSON" ] && command -v jq >/dev/null 2>&1; then
    w="$(jq -r --arg m "$model" '([.prefixes[] | .prefix as $p | select($m | startswith($p)) | .window][0]) // .default' "$CONTEXT_WINDOWS_JSON" 2>/dev/null)"
  fi
  printf '%s' "$w" | grep -qE '^[0-9]+$' || w="$CONTEXT_WINDOW_DEFAULT"
  case "${CLAUDE_CODE_DISABLE_1M_CONTEXT:-}" in
    1|true) [ "$w" -gt "$CONTEXT_WINDOW_DEFAULT" ] && w="$CONTEXT_WINDOW_DEFAULT" ;;
  esac
  printf '%s' "$w"
}

# autocompact_window — Claude Code's auto-compact window in tokens, or exit 1 when none is set.
autocompact_window() {
  local v="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}"
  if [ -z "$v" ]; then
    local settings="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/settings.json"
    if [ -f "$settings" ] && command -v jq >/dev/null 2>&1; then
      v="$(jq -r '.autoCompactWindow // empty | tostring' "$settings" 2>/dev/null)"
    fi
  fi
  [ -n "$v" ] || return 1
  parse_token_count "$v"
}

# context_window_floor <tokens_used> <limit> <source> — prints "<limit> <source>", raising
# a limit below tokens_used to the smallest tier that fits (or tokens_used past the last).
context_window_floor() {
  local used limit source="${3:-default}"
  used="$(printf '%s' "${1:-0}" | tr -cd '0-9')"; used="${used:-0}"
  limit="$(printf '%s' "${2:-0}" | tr -cd '0-9')"; limit="${limit:-0}"
  [ "$limit" -gt 0 ] || { limit="$CONTEXT_WINDOW_DEFAULT"; source="default"; }
  if [ "$used" -gt "$limit" ]; then
    local tiers t next=""
    tiers="$(jq -r '.tiers[]' "$CONTEXT_WINDOWS_JSON" 2>/dev/null || true)"
    [ -n "$tiers" ] || tiers="$CONTEXT_WINDOW_DEFAULT"
    for t in $tiers; do
      if [ "$t" -ge "$used" ]; then next="$t"; break; fi
    done
    limit="${next:-$used}"
    source="observed"
  fi
  printf '%s %s' "$limit" "$source"
}

# resolve_context_window <transcript_path> <tokens_used> — the resolver. Prints one JSON
# object: {"model": string|null, "tokens_used": int, "tokens_limit": int, "limit_source":
# "override"|"autocompact"|"model"|"observed"|"default"}.
resolve_context_window() {
  local tp="${1:-}" used model limit="" source v
  used="$(printf '%s' "${2:-0}" | tr -cd '0-9')"; used="${used:-0}"
  model="$(transcript_model "$tp" | tr -d '"\\')"
  v="${CONTEXTBUDDY_CONTEXT_WINDOW:-}"
  [ -n "$v" ] || v="$(dotenv_value CONTEXTBUDDY_CONTEXT_WINDOW 2>/dev/null || true)"
  if [ -n "$v" ] && limit="$(parse_token_count "$v")"; then
    source="override"
  elif limit="$(autocompact_window)" && [ -n "$limit" ]; then
    source="autocompact"
  elif [ -n "$model" ]; then
    limit="$(context_window_for_model "$model")"
    source="model"
  else
    limit="$CONTEXT_WINDOW_DEFAULT"
    source="default"
  fi
  # shellcheck disable=SC2046  # two space-separated words by construction
  set -- $(context_window_floor "$used" "$limit" "$source")
  limit="$1"; source="$2"
  if [ -n "$model" ]; then
    printf '{"model":"%s","tokens_used":%s,"tokens_limit":%s,"limit_source":"%s"}' "$model" "$used" "$limit" "$source"
  else
    printf '{"model":null,"tokens_used":%s,"tokens_limit":%s,"limit_source":"%s"}' "$used" "$limit" "$source"
  fi
}

# context_window_for_payload <hook_payload_json> — resolve from what the hook received:
# transcript_path for the model, tokens_used (or usage.input_tokens) for the floor. A
# payload that is not a JSON object resolves as no transcript, 0 tokens.
context_window_for_payload() {
  local payload="${1:-}" tp="" used=0
  if command -v jq >/dev/null 2>&1 && printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
    tp="$(printf '%s' "$payload" | jq -r '.transcript_path // empty | strings' 2>/dev/null)"
    used="$(printf '%s' "$payload" | jq -r '(.tokens_used // .usage.input_tokens // 0) as $u | if ($u | type) == "number" then ($u | floor) else 0 end' 2>/dev/null)"
    used="${used:-0}"
  fi
  resolve_context_window "$tp" "$used"
}
