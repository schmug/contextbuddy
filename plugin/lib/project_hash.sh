#!/usr/bin/env bash
# project_hash — derive ContextBuddy's per-project session hash.
#
# Per SPEC.md §2: sha256(absolute_project_path) truncated to first 12 hex
# chars. Uses macOS-native `shasum` (no GNU `sha256sum` dep).
#
# Usage:
#   source plugin/lib/project_hash.sh
#   PROJECT_HASH=$(project_hash "$PWD")

project_hash() {
  local path="${1:-$PWD}"
  printf '%s' "$path" | shasum -a 256 | cut -c1-12
}
