#!/usr/bin/env bash
# test_marketplace_manifest — the repo root is a Claude Code plugin marketplace
# (.claude-plugin/marketplace.json) so `claude plugin marketplace add <repo>` and
# `claude plugin install contextbuddy@contextbuddy` work. `claude plugin validate`
# is the authoritative check but the CLI is not on CI; this covers the shape.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$REPO_ROOT/.claude-plugin/marketplace.json"
PASS=0; FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [ -f "$MANIFEST" ] && jq -e . "$MANIFEST" >/dev/null 2>&1; then
  pass "marketplace.json exists and is valid JSON"
else
  fail "marketplace.json missing or invalid at $MANIFEST"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi

if [ "$(jq -r '.name' "$MANIFEST")" = "contextbuddy" ]; then
  pass "marketplace name is contextbuddy"
else
  fail "marketplace name != contextbuddy"
fi

src="$(jq -r '.plugins[] | select(.name == "contextbuddy") | .source' "$MANIFEST")"
if [ -n "$src" ] && [ -f "$REPO_ROOT/$src/.claude-plugin/plugin.json" ]; then
  pass "plugin entry 'contextbuddy' points at a directory with plugin.json ($src)"
else
  fail "plugin entry 'contextbuddy' missing or source '$src' has no .claude-plugin/plugin.json"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
