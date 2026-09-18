#!/usr/bin/env bash
# dotenv — read ONE variable's value out of a .env file without sourcing it.
#
# Used by hooks/user_prompt_submit.sh (TYPESAFE_API_KEY) and grader/invoke.sh
# (CONTEXTBUDDY_CLAUDE_CONFIG_DIR) for values that are not already
# in the environment Claude Code inherits. Candidates, first hit wins:
#   1. $PWD/.env                (the project the hook fired in; a worktree has its own)
#   2. <git toplevel>/.env      (the worktree root when $PWD is a subdirectory)
#   3. <main checkout>/.env     (parent of the shared .git dir, for worktree sessions)
# The value is printed to stdout for the caller to capture; it must never be logged.
# `.env` is never sourced: a stray line cannot execute anything.

# dotenv_value <NAME>
dotenv_value() {
  local name="$1"
  local candidates=("$PWD/.env")
  local top common
  top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] && candidates+=("$top/.env")
  common="$(git -C "$PWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$common" ] && candidates+=("$(dirname "$common")/.env")
  local f line value
  for f in "${candidates[@]}"; do
    [ -f "$f" ] || continue
    line="$(grep -E "^(export[[:space:]]+)?${name}=" "$f" 2>/dev/null | tail -n 1)"
    [ -n "$line" ] || continue
    value="${line#*=}"
    # strip one layer of matching quotes
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
  done
  return 1
}
