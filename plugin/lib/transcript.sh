#!/usr/bin/env bash
# transcript — assemble the input bundle for the grader.
#
# Per SPEC.md §7.2 the grader receives:
#   1. session.md content (or "session.md not found" sentinel)
#   2. latest prompt (pre-phase) or latest turn including agent response (post)
#   3. last 3 turns verbatim (Q6 decision: from the Claude Code hook input
#      transcript, NOT from a stored raw-turn file)
#   4. prior rolling summary from history.jsonl tail
#   5. tokens_used / tokens_limit
#   6. files edited in last 5 turns (post-phase, for loop pre-detection)
#
# Q6 means we read the transcript from the hook payload (stdin) rather than
# maintaining our own raw-turn artifacts. We slice the trailing window from
# whatever JSON shape Claude Code passes us; the "transcript" key is
# inspected first and falls through to "messages" / "turns" if shape evolves.

# read_session_md <hash>
# Echoes the session.md frontmatter content (between --- fences) or a
# sentinel string when missing. Q1: frontmatter format uses --- delimiters.
read_session_md() {
  local hash="$1"
  local path
  path="$(session_md_path "$hash")"
  if [ ! -f "$path" ]; then
    printf 'session.md not found at %s\n' "$path"
    return
  fi
  awk '
    BEGIN { in_fm = 0 }
    /^---$/ { in_fm = !in_fm; if (in_fm == 0) exit; next }
    in_fm == 1 { print }
  ' "$path"
}

# prior_summary <hash>
# Returns the summary_update field from the last line of history.jsonl, or
# empty if no history yet.
prior_summary() {
  local hash="$1"
  local path
  path="$(history_jsonl_path "$hash")"
  if [ ! -f "$path" ]; then
    return
  fi
  tail -n 1 "$path" | sed 's/.*"summary_update":"\([^"]*\)".*/\1/' 2>/dev/null
}

# recent_turns_from_hook_payload <payload_json> <window>
# Extracts the trailing <window> entries from whatever transcript the
# Claude Code hook payload carries. Tries multiple keys for forward
# compatibility (Q12: manifest schema may have evolved).
recent_turns_from_hook_payload() {
  local payload="$1"
  local window="${2:-3}"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r --argjson n "$window" '
      ((.transcript // .messages // .turns // []) as $all
       | $all
       | (length - $n) as $start
       | .[(if $start < 0 then 0 else $start end):])'
  else
    # jq missing — emit a marker so the grader knows the slice is unavailable.
    printf '[]'
  fi
}

# files_edited_recent <hash> <window>
# Returns a JSON array of unique file paths edited across the last <window>
# entries of edits.jsonl.
files_edited_recent() {
  local hash="$1"
  local window="${2:-5}"
  local path
  path="$(edits_jsonl_path "$hash")"
  if [ ! -f "$path" ] || ! command -v jq >/dev/null 2>&1; then
    printf '[]'
    return
  fi
  tail -n "$window" "$path" | jq -s '[.[].files[]?] | unique'
}

# tokens_from_hook_payload <payload_json>
# Echoes "<used> <limit>" or empty if not present.
tokens_from_hook_payload() {
  local payload="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r '
      (.tokens_used // .usage.input_tokens // 0) as $used
      | (.tokens_limit // 200000) as $lim
      | "\($used) \($lim)"'
  else
    printf '0 200000'
  fi
}
