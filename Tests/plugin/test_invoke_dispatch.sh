#!/usr/bin/env bash
# test_invoke_dispatch — fixture-style integration tests for invoke.sh's
# backend dispatcher (issue #3).
#
# Strategy: PATH-shadow `curl` (and `claude` for the anthropic case) with
# tiny fake binaries that emit fixture envelopes. Drive invoke.sh once per
# backend with a config.toml that selects that backend, and assert the
# emitted JSON deep-equals the canonical grade fixture.
#
# Also exercises the negative paths: unknown backend → exit 2; missing
# CONTEXTBUDDY_CLAUDE_CONFIG_DIR on anthropic → exit 5 (the anthropic path runs
# `claude -p` on a second account, see grader/invoke.sh; ANTHROPIC_API_KEY is
# never required).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INVOKE="$REPO_ROOT/plugin/grader/invoke.sh"
FIXTURES="$REPO_ROOT/Tests/plugin/fixtures"
EXPECTED_GRADE="$FIXTURES/grade_expected.json"

if ! command -v jq >/dev/null 2>&1; then
  printf 'test_invoke_dispatch: jq is required to run these tests.\n' >&2
  exit 2
fi

PASS=0
FAIL=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Per-test workspace; a clean tmpdir keeps the PATH-shadowed binaries and
# the throwaway config isolated from the host shell.
make_workspace() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cb_test_invoke.XXXXXX")"
  mkdir -p "$tmp/bin" "$tmp/cfg"
  printf '%s' "$tmp"
}

# Emit minimal sys/user prompt files. Their content doesn't matter — the
# fake backends ignore the request body and return canned responses.
stage_prompts() {
  local dir="$1"
  printf 'You are a test grader.\n' > "$dir/system.md"
  printf '## phase\npre\n' > "$dir/user.md"
}

write_curl_mock() {
  # Fake curl that recognizes the two endpoints used by invoke.sh and emits
  # the matching pre-staged response file from $RESP_DIR. Any other URL
  # exits non-zero so a misrouted backend would surface immediately.
  local bin="$1"
  cat > "$bin/curl" <<'MOCK'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "$arg" in
    http*) url="$arg" ;;
  esac
done
case "$url" in
  *"/api/generate") cat "$RESP_DIR/ollama_response.json" ;;
  *"/chat/completions") cat "$RESP_DIR/openai_response.json" ;;
  *) printf 'mock-curl: unexpected URL %s\n' "$url" >&2; exit 22 ;;
esac
MOCK
  chmod +x "$bin/curl"
}

write_claude_mock() {
  # Fake `claude` that ignores all flags and prints the canned grade. Used
  # for the anthropic backend regression case.
  local bin="$1"
  cat > "$bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat "$RESP_DIR/anthropic_response.txt"
MOCK
  chmod +x "$bin/claude"
}

build_envelopes() {
  local resp_dir="$1"
  # Ollama returns the grade JSON serialized as a string in `.response`.
  jq -nc --rawfile grade "$EXPECTED_GRADE" \
    '{model: "test", response: $grade, done: true}' \
    > "$resp_dir/ollama_response.json"
  # OpenAI-compatible chat returns it inside choices[0].message.content.
  jq -nc --rawfile grade "$EXPECTED_GRADE" \
    '{id: "x", choices: [{message: {role: "assistant", content: $grade}}]}' \
    > "$resp_dir/openai_response.json"
  # Anthropic via `claude -p` is plain text on stdout.
  cp "$EXPECTED_GRADE" "$resp_dir/anthropic_response.txt"
}

# assert_emits_expected <label> <actual_json>
# Compares actual against EXPECTED_GRADE using jq deep equality.
assert_emits_expected() {
  local label="$1" actual="$2"
  if [ -z "$actual" ]; then
    fail "$label: invoke.sh produced empty output"
    return
  fi
  if ! printf '%s' "$actual" | jq -e . >/dev/null 2>&1; then
    fail "$label: invoke.sh output is not valid JSON"
    printf '%s\n' "$actual" >&2
    return
  fi
  if printf '%s' "$actual" | jq --slurpfile e "$EXPECTED_GRADE" -e '. == $e[0]' >/dev/null; then
    pass "$label"
  else
    fail "$label: output != expected fixture"
    diff <(jq -S . "$EXPECTED_GRADE") <(printf '%s' "$actual" | jq -S .) >&2 || true
  fi
}

# --- Test cases ------------------------------------------------------------

test_ollama() {
  local ws; ws="$(make_workspace)"
  stage_prompts "$ws"
  build_envelopes "$ws"
  write_curl_mock "$ws/bin"
  cat > "$ws/cfg/config.toml" <<EOF
[grader]
backend = "ollama"
model = "qwen2.5:14b-instruct"

[grader.ollama]
endpoint = "http://localhost:11434"
EOF
  local actual
  actual="$(RESP_DIR="$ws" PATH="$ws/bin:$PATH" \
    "$INVOKE" "$ws/system.md" "$ws/user.md" "qwen2.5:14b-instruct" "$ws/cfg/config.toml" 2>/dev/null)"
  assert_emits_expected "ollama backend dispatch" "$actual"
  rm -rf "$ws"
}

test_openai_compatible() {
  local ws; ws="$(make_workspace)"
  stage_prompts "$ws"
  build_envelopes "$ws"
  write_curl_mock "$ws/bin"
  cat > "$ws/cfg/config.toml" <<EOF
[grader]
backend = "openai_compatible"
model = "local-model"

[grader.openai_compatible]
endpoint = "http://localhost:1234/v1"
api_key_env = ""
EOF
  local actual
  actual="$(RESP_DIR="$ws" PATH="$ws/bin:$PATH" \
    "$INVOKE" "$ws/system.md" "$ws/user.md" "local-model" "$ws/cfg/config.toml" 2>/dev/null)"
  assert_emits_expected "openai_compatible backend dispatch" "$actual"
  rm -rf "$ws"
}

test_anthropic_default() {
  local ws; ws="$(make_workspace)"
  stage_prompts "$ws"
  build_envelopes "$ws"
  write_claude_mock "$ws/bin"
  # Empty config — should default to anthropic.
  : > "$ws/cfg/config.toml"
  local actual
  actual="$(RESP_DIR="$ws" PATH="$ws/bin:$PATH" CONTEXTBUDDY_CLAUDE_CONFIG_DIR="$ws/cfg" \
    "$INVOKE" "$ws/system.md" "$ws/user.md" "claude-haiku-4-5-20251001" "$ws/cfg/config.toml" 2>/dev/null)"
  assert_emits_expected "anthropic default (empty config)" "$actual"
  rm -rf "$ws"
}

test_anthropic_explicit() {
  local ws; ws="$(make_workspace)"
  stage_prompts "$ws"
  build_envelopes "$ws"
  write_claude_mock "$ws/bin"
  cat > "$ws/cfg/config.toml" <<EOF
[grader]
backend = "anthropic"
model = "claude-haiku-4-5-20251001"
EOF
  local actual
  actual="$(RESP_DIR="$ws" PATH="$ws/bin:$PATH" CONTEXTBUDDY_CLAUDE_CONFIG_DIR="$ws/cfg" \
    "$INVOKE" "$ws/system.md" "$ws/user.md" "claude-haiku-4-5-20251001" "$ws/cfg/config.toml" 2>/dev/null)"
  assert_emits_expected "anthropic backend dispatch (explicit)" "$actual"
  rm -rf "$ws"
}

test_unknown_backend_exits_2() {
  local ws; ws="$(make_workspace)"
  stage_prompts "$ws"
  cat > "$ws/cfg/config.toml" <<EOF
[grader]
backend = "totally-fake"
EOF
  local rc=0
  PATH="$ws/bin:$PATH" \
    "$INVOKE" "$ws/system.md" "$ws/user.md" "x" "$ws/cfg/config.toml" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    pass "unknown backend exits 2"
  else
    fail "unknown backend: expected exit 2, got $rc"
  fi
  rm -rf "$ws"
}

test_anthropic_missing_config_dir_exits_5() {
  local ws; ws="$(make_workspace)"
  stage_prompts "$ws"
  build_envelopes "$ws"
  write_claude_mock "$ws/bin"
  cat > "$ws/cfg/config.toml" <<EOF
[grader]
backend = "anthropic"
EOF
  local rc=0
  # cd into the workspace (not a git repo, no .env) so lib/dotenv.sh cannot find
  # a config dir on the developer machine.
  ( unset CONTEXTBUDDY_CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY
    cd "$ws" && PATH="$ws/bin:$PATH" \
      "$INVOKE" "$ws/system.md" "$ws/user.md" "x" "$ws/cfg/config.toml" >/dev/null 2>&1 ) || rc=$?
  if [ "$rc" -eq 5 ]; then
    pass "anthropic without CONTEXTBUDDY_CLAUDE_CONFIG_DIR exits 5"
  else
    fail "anthropic without config dir: expected exit 5, got $rc"
  fi
  rm -rf "$ws"
}

# --- typesafe backend (Node grader, jev.mjs) --------------------------------

write_node_mock() {
  # Fake `node` standing in for the real runtime: asserts invoke.sh handed it
  # grader/jev.mjs and a JSON job on stdin, then prints the canned grade.
  # Any other invocation exits 9 so a misrouted dispatch surfaces immediately.
  local bin="$1"
  cat > "$bin/node" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *grader/jev.mjs*) ;;
  *) printf 'mock-node: unexpected argv %s\n' "$*" >&2; exit 9 ;;
esac
job="$(cat)"
printf '%s' "$job" | jq -e '.phase' >/dev/null 2>&1 || { printf 'mock-node: stdin is not a job\n' >&2; exit 9; }
if [ -n "${MOCK_NODE_GATED:-}" ]; then
  printf 'contextbuddy: task gate p=0.05 — not a prompt, grade skipped\n' >&2
  exit 0
fi
cat "$RESP_DIR/anthropic_response.txt"
MOCK
  chmod +x "$bin/node"
}

typesafe_config() {
  cat > "$1/cfg/config.toml" <<EOF
[grader]
backend = "typesafe"
model = "jev-1.13.0"
EOF
  printf '{"phase":"pre","turn":1,"hook":{"prompt":"p"}}' > "$1/job.json"
}

test_typesafe_dispatch() {
  local ws; ws="$(make_workspace)"
  stage_prompts "$ws"; build_envelopes "$ws"; write_node_mock "$ws/bin"; typesafe_config "$ws"
  local actual
  actual="$(RESP_DIR="$ws" PATH="$ws/bin:$PATH" TYPESAFE_API_KEY=k CONTEXTBUDDY_JOB="$ws/job.json" \
    "$INVOKE" "$ws/system.md" "$ws/user.md" "jev-1.13.0" "$ws/cfg/config.toml" 2>/dev/null)"
  assert_emits_expected "typesafe backend dispatch" "$actual"
  rm -rf "$ws"
}

test_typesafe_gated_exits_0_empty() {
  local ws; ws="$(make_workspace)"
  stage_prompts "$ws"; build_envelopes "$ws"; write_node_mock "$ws/bin"; typesafe_config "$ws"
  local rc=0 actual
  actual="$(RESP_DIR="$ws" PATH="$ws/bin:$PATH" TYPESAFE_API_KEY=k CONTEXTBUDDY_JOB="$ws/job.json" MOCK_NODE_GATED=1 \
    "$INVOKE" "$ws/system.md" "$ws/user.md" "jev-1.13.0" "$ws/cfg/config.toml" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$actual" ]; then
    pass "typesafe task gate exits 0 with empty output (no retry)"
  else
    fail "typesafe gated: expected exit 0 + empty, got exit $rc output '$actual'"
  fi
  rm -rf "$ws"
}

test_typesafe_missing_key_exits_5() {
  local ws; ws="$(make_workspace)"
  stage_prompts "$ws"; build_envelopes "$ws"; write_node_mock "$ws/bin"; typesafe_config "$ws"
  local rc=0
  ( unset TYPESAFE_API_KEY
    PATH="$ws/bin:$PATH" CONTEXTBUDDY_JOB="$ws/job.json" \
      "$INVOKE" "$ws/system.md" "$ws/user.md" "jev-1.13.0" "$ws/cfg/config.toml" >/dev/null 2>&1 ) || rc=$?
  if [ "$rc" -eq 5 ]; then pass "typesafe without TYPESAFE_API_KEY exits 5"; else fail "typesafe without key: expected exit 5, got $rc"; fi
  rm -rf "$ws"
}

test_typesafe_missing_job_exits_2() {
  local ws; ws="$(make_workspace)"
  stage_prompts "$ws"; build_envelopes "$ws"; write_node_mock "$ws/bin"; typesafe_config "$ws"
  local rc=0
  ( unset CONTEXTBUDDY_JOB
    PATH="$ws/bin:$PATH" TYPESAFE_API_KEY=k \
      "$INVOKE" "$ws/system.md" "$ws/user.md" "jev-1.13.0" "$ws/cfg/config.toml" >/dev/null 2>&1 ) || rc=$?
  if [ "$rc" -eq 2 ]; then pass "typesafe without CONTEXTBUDDY_JOB exits 2"; else fail "typesafe without job: expected exit 2, got $rc"; fi
  rm -rf "$ws"
}

# --- Run -------------------------------------------------------------------

printf 'Running invoke.sh dispatcher tests against %s\n' "$INVOKE"
test_ollama
test_openai_compatible
test_anthropic_default
test_anthropic_explicit
test_unknown_backend_exits_2
test_anthropic_missing_config_dir_exits_5
test_typesafe_dispatch
test_typesafe_gated_exits_0_empty
test_typesafe_missing_key_exits_5
test_typesafe_missing_job_exits_2

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
