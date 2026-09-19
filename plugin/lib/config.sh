#!/usr/bin/env bash
# config — TOML-lite reader for ~/.claude/inspector/config.toml.
#
# Section-aware. Replaces the duplicated grep|sed snippets in the hooks.
# Limitations: string values must be on a single line; only `=` separator;
# only top-level [section] and [section.subsection] headers; no arrays of
# tables, no inline tables, no multi-line strings. Sufficient for the v1
# config schema (SPEC.md §9.1).
#
# Usage:
#   source plugin/lib/config.sh
#   model="$(toml_get_section_key "$config" "grader" "model")"

# toml_get_section_key <file> <section> <key>
# Reads `key = value` only inside [section]. Strips surrounding double quotes
# from string values and trailing comments. Returns empty string (exit 0)
# when the file, section, or key is absent — never errors.
toml_get_section_key() {
  local file="$1" section="$2" key="$3"
  [ -f "$file" ] || return 0
  awk -v want="[$section]" -v key="$key" '
    BEGIN { in_section = 0 }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ {
      hdr = $0
      sub(/^[[:space:]]*/, "", hdr)
      sub(/[[:space:]]*#.*$/, "", hdr)
      sub(/[[:space:]]*$/, "", hdr)
      in_section = (hdr == want)
      next
    }
    in_section {
      pat = "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*"
      if ($0 ~ pat) {
        line = $0
        sub(pat, "", line)
        sub(/[[:space:]]*#.*$/, "", line)
        sub(/[[:space:]]*$/, "", line)
        sub(/^"/, "", line)
        sub(/"$/, "", line)
        print line
        exit
      }
    }
  ' "$file"
}

# toml_get_section_int <file> <section> <key> <default>
# Convenience: parses an integer; falls back to <default> if missing or
# non-numeric. Useful for the threshold integers the hooks read.
toml_get_section_int() {
  local file="$1" section="$2" key="$3" default="$4"
  local raw
  raw="$(toml_get_section_key "$file" "$section" "$key")"
  if [ -z "$raw" ] || ! printf '%s' "$raw" | grep -qE '^[0-9]+$'; then
    printf '%s' "$default"
  else
    printf '%s' "$raw"
  fi
}

# toml_get_section_float <file> <section> <key> <default>
# Like toml_get_section_int for an unsigned TOML float or integer literal
# ("0.5", "1"); falls back to <default> if missing or not of that shape. The
# result is safe to splice into jq with --argjson. Used for the
# [grader.typesafe] gates (issue #8).
toml_get_section_float() {
  local file="$1" section="$2" key="$3" default="$4"
  local raw
  raw="$(toml_get_section_key "$file" "$section" "$key")"
  if [ -z "$raw" ] || ! printf '%s' "$raw" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
    printf '%s' "$default"
  else
    printf '%s' "$raw"
  fi
}
