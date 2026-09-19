#!/usr/bin/env bash
# test_project_hash_canonical — project_hash resolves symlinks before hashing
# (issue #4) and agrees byte-for-byte with SessionDiscovery.projectHash(for:).
#
# On macOS /tmp is a symlink to /private/tmp, and Claude Code's hooks see the
# project cwd in either form depending on entry point. Hashing the string
# verbatim gave the two forms different hashes and split one project's session
# across two directories under ~/.claude/inspector/sessions/.
#
# EXPECTED_PRIVATE_TMP is sha256("/private/tmp")[:12]. The Swift side pins the
# same constant (Tests/ContextBuddyCoreTests/SessionDiscoveryTests.swift,
# testProjectHashResolvesSymlinksBeforeHashing), so the two implementations
# cannot drift apart without failing one of the two tests. Change both or neither.
# shellcheck disable=SC2015  # `A && ok || fail` is the intended assertion idiom here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../../plugin/lib/project_hash.sh
. "$REPO/plugin/lib/project_hash.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

EXPECTED_PRIVATE_TMP="11fe14a563f7"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. /tmp <-> /private/tmp: the issue #4 reproducer --------------------------------
[ "$(project_hash /private/tmp)" = "$EXPECTED_PRIVATE_TMP" ] \
  && ok "/private/tmp hashes to the pinned constant" \
  || fail "project_hash(/private/tmp) = $(project_hash /private/tmp), expected $EXPECTED_PRIVATE_TMP"
[ "$(project_hash /tmp)" = "$EXPECTED_PRIVATE_TMP" ] \
  && ok "/tmp resolves to /private/tmp before hashing" \
  || fail "project_hash(/tmp) = $(project_hash /tmp), expected $EXPECTED_PRIVATE_TMP"

# --- 2. a user-made symlink resolves too (Homebrew prefixes, dev-volume mounts) --------
mkdir -p "$TMP/real"
ln -s "$TMP/real" "$TMP/link"
[ "$(project_hash "$TMP/link")" = "$(project_hash "$TMP/real")" ] \
  && ok "symlinked project dir hashes like its target" \
  || fail "project_hash(link) = $(project_hash "$TMP/link"), project_hash(real) = $(project_hash "$TMP/real")"
[ "$(canonical_project_path "$TMP/link")" = "$(canonical_project_path "$TMP/real")" ] \
  && ok "canonical_project_path agrees for link and target" \
  || fail "canonical_project_path(link) = $(canonical_project_path "$TMP/link"), (real) = $(canonical_project_path "$TMP/real")"

# --- 3. an unresolvable path is hashed verbatim, same as the Swift side ----------------
# Nothing to resolve, so no normalization either. Keeps the fallback honest on both
# sides: a path that does not exist never gets "helpfully" rewritten before hashing.
VERBATIM="$(printf '%s' "$TMP/does-not-exist" | shasum -a 256 | cut -c1-12)"
[ "$(project_hash "$TMP/does-not-exist")" = "$VERBATIM" ] \
  && ok "nonexistent path hashes verbatim" \
  || fail "project_hash(nonexistent) = $(project_hash "$TMP/does-not-exist"), expected verbatim $VERBATIM"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
