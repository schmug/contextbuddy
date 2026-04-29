#!/usr/bin/env bash
# statusline — single-line status renderer for Claude Code's status line.
#
# Per SPEC.md §10.2: reads last.json and prints one ANSI-colored line.
# Must complete in <50 ms — no API calls, only `cat` / `jq`.
#
# Output format:
#   <colored-dot> conf:N atom:N drift:N pol:N ⚡USEDk/LIMITk

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$PLUGIN_ROOT/lib/project_hash.sh"
. "$PLUGIN_ROOT/lib/session_paths.sh"

PROJECT_HASH="$(project_hash "$PWD")"
LAST_PATH="$(last_json_path "$PROJECT_HASH")"

if [ ! -f "$LAST_PATH" ]; then
  printf '\033[90m●\033[0m no grade yet\n'
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '\033[90m●\033[0m (jq missing)\n'
  exit 0
fi

JSON="$(cat "$LAST_PATH")"
CONF="$(printf '%s' "$JSON" | jq -r '.scores.confidence.value // 0')"
ATOM="$(printf '%s' "$JSON" | jq -r '.scores.atomicity.value // 0')"
DRIFT="$(printf '%s' "$JSON" | jq -r '.scores.drift.value // 0')"
POL="$(printf '%s' "$JSON" | jq -r '.scores.pollution.value // 0')"
USED="$(printf '%s' "$JSON" | jq -r '.tokens_used // 0')"
LIMIT="$(printf '%s' "$JSON" | jq -r '.tokens_limit // 200000')"
DOMINANT="$(printf '%s' "$JSON" | jq -r '.dominant_signal // empty')"

# Derive color from same logic as StateMachine: loop/context_pressure → orange,
# any threshold cross → yellow, all-green → green, default → primary.
COLOR_RESET='\033[0m'
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_ORANGE='\033[38;5;208m'
COLOR_GRAY='\033[90m'
COLOR_BLUE='\033[34m'

CONFIDENCE_THRESHOLD=4
ATOMICITY_THRESHOLD=4
DRIFT_THRESHOLD=6
POLLUTION_THRESHOLD=7
CONFIG_PATH="$(config_path)"
if [ -f "$CONFIG_PATH" ]; then
  CONFIDENCE_THRESHOLD="$(grep -E '^confidence_attention[[:space:]]*=' "$CONFIG_PATH" | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' || echo 4)"
  ATOMICITY_THRESHOLD="$(grep -E '^atomicity_attention[[:space:]]*=' "$CONFIG_PATH" | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' || echo 4)"
  DRIFT_THRESHOLD="$(grep -E '^drift_attention[[:space:]]*=' "$CONFIG_PATH" | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' || echo 6)"
  POLLUTION_THRESHOLD="$(grep -E '^pollution_attention[[:space:]]*=' "$CONFIG_PATH" | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' || echo 7)"
fi

if [ "$DOMINANT" = "loop" ] || [ "$DOMINANT" = "context_pressure" ]; then
  COLOR="$COLOR_ORANGE"
elif [ "$CONF" -lt "$CONFIDENCE_THRESHOLD" ] \
  || [ "$ATOM" -lt "$ATOMICITY_THRESHOLD" ] \
  || [ "$DRIFT" -gt "$DRIFT_THRESHOLD" ] \
  || [ "$POL" -gt "$POLLUTION_THRESHOLD" ]; then
  COLOR="$COLOR_YELLOW"
else
  COLOR="$COLOR_GREEN"
fi

# Token formatting: e.g., 47k / 200k.
fmt_tokens() {
  local n="$1"
  if [ "$n" -ge 1000 ]; then
    printf '%dk' "$((n / 1000))"
  else
    printf '%d' "$n"
  fi
}

USED_FMT="$(fmt_tokens "$USED")"
LIMIT_FMT="$(fmt_tokens "$LIMIT")"

printf '%b●%b conf:%s atom:%s drift:%s pol:%s ⚡%s/%s\n' \
  "$COLOR" "$COLOR_RESET" \
  "$CONF" "$ATOM" "$DRIFT" "$POL" \
  "$USED_FMT" "$LIMIT_FMT"
