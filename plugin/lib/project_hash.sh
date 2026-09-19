#!/usr/bin/env bash
# project_hash — derive ContextBuddy's per-project session hash.
#
# Per SPEC.md §2: sha256(canonical_project_path) truncated to first 12 hex
# chars. Uses macOS-native `shasum` (no GNU `sha256sum` dep).
#
# The path is canonicalized first (issue #4): on macOS /tmp is a symlink to
# /private/tmp and the hooks see the project cwd in either form depending on
# entry point, so hashing the string verbatim split one project's session
# across two directories. Must agree byte-for-byte with
# SessionDiscovery.projectHash(for:) in Sources/ContextBuddyCore — both test
# suites pin the same constant for /private/tmp.
#
# Usage:
#   source plugin/lib/project_hash.sh
#   PROJECT_HASH=$(project_hash "$PWD")

# canonical_project_path <path>
# realpath(3) semantics for a directory: symlinks, `.` and `..` resolved and the
# trailing slash dropped, via `cd -P && pwd -P` so it runs on bash 3.2 without
# depending on a `realpath` binary. A path that cannot be entered (does not
# exist) is returned verbatim, matching the Swift side's fallback.
# CDPATH is cleared so `cd` can neither redirect nor print.
canonical_project_path() {
  local path="${1:-$PWD}"
  local resolved
  if resolved="$(CDPATH= cd -P -- "$path" 2>/dev/null && pwd -P)"; then
    printf '%s' "$resolved"
  else
    printf '%s' "$path"
  fi
}

project_hash() {
  local path="${1:-$PWD}"
  printf '%s' "$(canonical_project_path "$path")" | shasum -a 256 | cut -c1-12
}
