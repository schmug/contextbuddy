#!/usr/bin/env bash
# invoke — call the grader model and emit strict JSON.
#
# Backends (issue #3): anthropic (default), ollama, openai_compatible. Selected via
# [grader].backend in ~/.claude/inspector/config.toml (4th argument). Local backends
# use curl plus the runtime's structured-output mode (Ollama format=json,
# OpenAI-compatible response_format=json_object) to keep small models
# schema-conformant.
#
# Anthropic credential (issue #13, Cory 2026-09-18): a SECOND Claude account, selected by
# pointing CLAUDE_CONFIG_DIR at its config directory. `claude -p` then reads that
# directory's own sign-in (.claude.json + a per-directory keychain entry), so the
# grader bills that account, not the session's, and never needs ANTHROPIC_API_KEY.
# `claude --bare` is NOT used: it refuses OAuth/keychain and would need the key.
#
# Config dir resolution, first hit wins; none found -> log and skip (exit 5, §13):
#   1. $CONTEXTBUDDY_CLAUDE_CONFIG_DIR in the environment
#   2. CONTEXTBUDDY_CLAUDE_CONFIG_DIR in a .env found by lib/dotenv.sh
#      (hooks fired from the desktop app do not see shell-exported vars)
# Not config.toml: Sources/ContextBuddyCore/Schemas.swift rejects unknown keys and
# drops the whole file to defaults.
#
# Child invariants (Tests/plugin/test_invoke_config_dir.sh):
#   - CONTEXTBUDDY_SKIP=1 so this plugin's hooks exit 0 inside the child (recursion
#     guard; -p mode still runs hooks).
#   - ANTHROPIC_API_KEY is removed from the child env. In -p mode the CLI always
#     prefers that key over the login, which would silently switch the account.
#   - cwd is a neutral directory, so the child does not load the graded project's
#     CLAUDE.md, .claude/settings.json hooks, or MCP servers.
#   - Nothing from the credential store is printed.
#   - HOME must be the real one: the CLI finds the login keychain through HOME, so a
#     test that overrides HOME gets "Not logged in" (use a stub `claude` instead).
#   - MAX_THINKING_TOKENS=0: extended thinking OFF in the child (issue #17). `claude -p`
#     otherwise thinks with Haiku (~3.5k thinking tokens/grade); the visible grade
#     JSON is ~330 tokens either way and the rubric is mechanical, so thinking only
#     adds latency. Measured 2026-09-18 through this script, same input (README
#     worked example 1): default 39 s wall / 3437 output tokens; MAX_THINKING_TOKENS=0
#     6 s / 417. UserPromptSubmit command hooks time out at 30 s (docs/en/hooks), so
#     a thinking grade never lands on the pre phase anyway.
#     MAX_THINKING_TOKENS=0 is the documented way to disable thinking on the
#     Anthropic API (docs/en/env-vars); CLAUDE_CODE_DISABLE_THINKING=1 only omits
#     the parameter, and `--effort` is rejected by Haiku 4.5. Change the budget
#     here only with a fresh wall-clock measurement.
#
# Usage:
#   plugin/grader/invoke.sh <system_prompt_path> <user_input_path> <model> [<config_path>] > out.json
#
# All backends share:
#   - retry-once-on-empty-output
#   - strip_fences cleanup (belt-and-suspenders for small models that
#     occasionally wrap output in ```json ... ``` despite JSON mode)
#   - jq -e validation; on parse failure, log and exit non-zero — caller
#     logs and skips per SPEC §13.

set -uo pipefail

SYSTEM_PROMPT_PATH="${1:?system prompt path required}"
USER_INPUT_PATH="${2:?user input path required}"
MODEL="${3:?model id required}"
CONFIG_PATH="${4:-}"

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/config.sh
. "$PLUGIN_ROOT/lib/config.sh"
# shellcheck source=../lib/dotenv.sh
. "$PLUGIN_ROOT/lib/dotenv.sh"

# Resolve backend from config (default = anthropic for full backward compat).
BACKEND="anthropic"
if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
  cfg_backend="$(toml_get_section_key "$CONFIG_PATH" "grader" "backend")"
  [ -n "$cfg_backend" ] && BACKEND="$cfg_backend"
fi

# Pre-flight: fail fast on missing tools / required env so the retry loop
# doesn't paper over a config error. These exits propagate to the caller
# because they happen before the OUTPUT="$(attempt)" subshell.
CONFIG_DIR=""
case "$BACKEND" in
  anthropic)
    if ! command -v claude >/dev/null 2>&1; then
      printf 'contextbuddy: `claude` CLI not found in PATH; cannot reach grader\n' >&2
      exit 2
    fi
    CONFIG_DIR="${CONTEXTBUDDY_CLAUDE_CONFIG_DIR:-}"
    [ -n "$CONFIG_DIR" ] || CONFIG_DIR="$(dotenv_value CONTEXTBUDDY_CLAUDE_CONFIG_DIR || true)"
    if [ -z "$CONFIG_DIR" ]; then
      printf 'contextbuddy: CONTEXTBUDDY_CLAUDE_CONFIG_DIR not set — grader skipped.\n' >&2
      printf 'contextbuddy: point it (env or .env) at a Claude config dir signed in as the grader account, or switch to a local backend via [grader].backend in ~/.claude/inspector/config.toml.\n' >&2
      exit 5
    fi
    if [ ! -d "$CONFIG_DIR" ]; then
      printf 'contextbuddy: CONTEXTBUDDY_CLAUDE_CONFIG_DIR=%s is not a directory — grader skipped.\n' "$CONFIG_DIR" >&2
      exit 5
    fi
    ;;
  ollama|openai_compatible)
    if ! command -v curl >/dev/null 2>&1; then
      printf 'contextbuddy: curl not found; required for %s backend\n' "$BACKEND" >&2
      exit 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
      printf 'contextbuddy: jq required for %s backend (install via brew install jq)\n' "$BACKEND" >&2
      exit 2
    fi
    ;;
  *)
    printf 'contextbuddy: unknown grader backend "%s" (expected anthropic|ollama|openai_compatible)\n' "$BACKEND" >&2
    exit 2
    ;;
esac

# Neutral cwd for the anthropic child (see header). Stable path so the account's
# .claude.json gains one project entry, not one per grade.
CHILD_CWD="${TMPDIR:-/tmp}/contextbuddy-grader"
mkdir -p "$CHILD_CWD" 2>/dev/null || CHILD_CWD="${TMPDIR:-/tmp}"

CHILD_ERR="$(mktemp "${TMPDIR:-/tmp}/contextbuddy-invoke.XXXXXX")"
trap 'rm -f "$CHILD_ERR"' EXIT

run_anthropic_once() {
  # --tools "" disables tool use so the grader cannot side-effect anything.
  # --system-prompt (not --append-) fully replaces the default so the
  # grader rubric is the only system context.
  # --strict-mcp-config with no --mcp-config: no MCP servers are started.
  # --no-session-persistence: nothing written under the account's projects/.
  local sys
  sys="$(cat "$SYSTEM_PROMPT_PATH")"
  (
    cd "$CHILD_CWD" || exit 1
    CLAUDE_CONFIG_DIR="$CONFIG_DIR" CONTEXTBUDDY_SKIP=1 MAX_THINKING_TOKENS=0 \
      env -u ANTHROPIC_API_KEY claude \
        --model "$MODEL" \
        --output-format text \
        --system-prompt "$sys" \
        --tools "" \
        --no-session-persistence \
        --strict-mcp-config \
        -p "$(cat "$USER_INPUT_PATH")" </dev/null 2>>"$CHILD_ERR"
  )
}

run_ollama_once() {
  local endpoint
  endpoint="$(toml_get_section_key "$CONFIG_PATH" "grader.ollama" "endpoint")"
  endpoint="${endpoint:-http://localhost:11434}"
  local body
  body="$(jq -n \
    --arg model "$MODEL" \
    --rawfile sys "$SYSTEM_PROMPT_PATH" \
    --rawfile user "$USER_INPUT_PATH" \
    '{model: $model, system: $sys, prompt: $user, format: "json", stream: false}')"
  local resp
  resp="$(curl -fs -m 120 -X POST "${endpoint%/}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "$body" 2>>"$CHILD_ERR")" || return 0
  printf '%s' "$resp" | jq -r '.response // empty'
}

run_openai_compatible_once() {
  local endpoint api_key_env api_key
  local -a auth_header=()
  endpoint="$(toml_get_section_key "$CONFIG_PATH" "grader.openai_compatible" "endpoint")"
  endpoint="${endpoint:-http://localhost:1234/v1}"
  api_key_env="$(toml_get_section_key "$CONFIG_PATH" "grader.openai_compatible" "api_key_env")"
  if [ -n "$api_key_env" ]; then
    api_key="${!api_key_env:-}"
    if [ -n "$api_key" ]; then
      auth_header=(-H "Authorization: Bearer $api_key")
    fi
  fi
  local body
  body="$(jq -n \
    --arg model "$MODEL" \
    --rawfile sys "$SYSTEM_PROMPT_PATH" \
    --rawfile user "$USER_INPUT_PATH" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $sys},
        {role: "user", content: $user}
      ],
      response_format: {type: "json_object"},
      stream: false
    }')"
  local resp
  # ${auth_header[@]+...}: bash 3.2 (macOS default) trips set -u on empty
  # array expansion without this guard.
  resp="$(curl -fs -m 120 -X POST "${endpoint%/}/chat/completions" \
    -H 'Content-Type: application/json' \
    ${auth_header[@]+"${auth_header[@]}"} \
    -d "$body" 2>>"$CHILD_ERR")" || return 0
  printf '%s' "$resp" | jq -r '.choices[0].message.content // empty'
}

run_once() {
  case "$BACKEND" in
    anthropic) run_anthropic_once ;;
    ollama) run_ollama_once ;;
    openai_compatible) run_openai_compatible_once ;;
  esac
}

strip_fences() {
  # Remove a leading ```json or ``` line and a trailing ``` line if present.
  sed -E '1{/^```(json)?[[:space:]]*$/d;}; ${/^```[[:space:]]*$/d;}'
}

attempt() {
  run_once | strip_fences
}

OUTPUT="$(attempt)"
if [ -z "$OUTPUT" ]; then
  sleep 1
  OUTPUT="$(attempt)"
fi

if [ -z "$OUTPUT" ]; then
  printf 'contextbuddy: grader returned empty output after retry (backend=%s)\n' "$BACKEND" >&2
  # Last line of the child's stderr (e.g. "Not logged in"); the CLI never prints tokens.
  [ -s "$CHILD_ERR" ] && printf 'contextbuddy: %s: %s\n' "$BACKEND" "$(tail -n 1 "$CHILD_ERR")" >&2
  exit 3
fi

# Validate JSON. If we have jq, use it; otherwise trust and emit.
if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$OUTPUT" | jq -e . >/dev/null 2>&1; then
    printf 'contextbuddy: grader output is not valid JSON (backend=%s)\n' "$BACKEND" >&2
    printf '%s\n' "$OUTPUT" >&2
    exit 4
  fi
fi

printf '%s\n' "$OUTPUT"
