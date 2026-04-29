#!/usr/bin/env bash
# invoke — call the grader model and emit strict JSON.
#
# Q4 decision: use Claude Code's managed credential. We invoke the `claude`
# CLI in print mode (`claude -p`) which inherits the user's authenticated
# session. No separate ANTHROPIC_API_KEY required.
#
# Phase H caveat: the exact `claude -p` flag set evolved with the CLI; this
# script targets the modern form (`claude --model <id> --output-format text
# -p`). Adjust if the CLI surface has shifted at install time.
#
# Usage:
#   plugin/grader/invoke.sh <system_prompt_path> <user_input_path> <model> > out.json
#
# Behavior:
#   - Strips a leading ```json / trailing ``` if the model wrapped output.
#   - Validates the result is parseable JSON. On parse failure, prints
#     diagnostic to stderr and exits non-zero — the caller logs and skips
#     per §13.
#   - Retries once on transient (non-auth, non-4xx) error.

set -uo pipefail

SYSTEM_PROMPT_PATH="${1:?system prompt path required}"
USER_INPUT_PATH="${2:?user input path required}"
MODEL="${3:?model id required}"

if ! command -v claude >/dev/null 2>&1; then
  printf 'contextbuddy: `claude` CLI not found in PATH; cannot reach grader\n' >&2
  exit 2
fi

# Q4 deviation surfaced during Phase H verification: the Claude Code managed
# credential (OAuth/keychain) is intentionally NOT accessible to subprocess
# hooks. The only way to invoke the model in an isolated, non-recursive
# context is `claude --bare`, which strictly requires ANTHROPIC_API_KEY.
# We require it here and skip grading with a clear error if absent — per
# §13's "log and skip" failure mode.
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  printf 'contextbuddy: ANTHROPIC_API_KEY not set — grader skipped.\n' >&2
  printf 'contextbuddy: set the env var (e.g., in ~/.zshrc) to enable grading.\n' >&2
  exit 5
fi

run_once() {
  # --bare strips: hooks (no recursion), LSP, plugin sync, attribution,
  # auto-memory, keychain reads, CLAUDE.md auto-discovery. This is exactly
  # the surface we want for a one-shot grader inference.
  # --tools "" disables tool use so the grader cannot side-effect anything.
  # --system-prompt (not --append-) fully replaces the default so the
  # grader rubric is the only system context.
  local sys
  sys="$(cat "$SYSTEM_PROMPT_PATH")"
  claude \
    --bare \
    --model "$MODEL" \
    --output-format text \
    --system-prompt "$sys" \
    --tools "" \
    --no-session-persistence \
    -p "$(cat "$USER_INPUT_PATH")" 2>/dev/null
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
  printf 'contextbuddy: grader returned empty output after retry\n' >&2
  exit 3
fi

# Validate JSON. If we have jq, use it; otherwise trust and emit.
if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$OUTPUT" | jq -e . >/dev/null 2>&1; then
    printf 'contextbuddy: grader output is not valid JSON\n' >&2
    printf '%s\n' "$OUTPUT" >&2
    exit 4
  fi
fi

printf '%s\n' "$OUTPUT"
