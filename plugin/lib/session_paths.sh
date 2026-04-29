#!/usr/bin/env bash
# session_paths — single source of truth for ContextBuddy session paths.
#
# Per SPEC.md §3 / §4 / §10. Every path under ~/.claude/inspector/sessions/
# resolves through here so the hooks, status line, and slash commands stay
# consistent.
#
# Usage:
#   source plugin/lib/project_hash.sh
#   source plugin/lib/session_paths.sh
#   PROJECT_HASH=$(project_hash "$PWD")
#   SESSION_DIR=$(session_dir "$PROJECT_HASH")

inspector_root() {
  printf '%s' "${HOME}/.claude/inspector"
}

config_path() {
  printf '%s/config.toml' "$(inspector_root)"
}

sessions_root() {
  printf '%s/sessions' "$(inspector_root)"
}

session_dir() {
  printf '%s/%s' "$(sessions_root)" "$1"
}

session_md_path() {
  printf '%s/session.md' "$(session_dir "$1")"
}

last_json_path() {
  printf '%s/last.json' "$(session_dir "$1")"
}

history_jsonl_path() {
  printf '%s/history.jsonl' "$(session_dir "$1")"
}

suggestions_md_path() {
  printf '%s/suggestions.md' "$(session_dir "$1")"
}

turns_dir() {
  printf '%s/turns' "$(session_dir "$1")"
}

turn_file_path() {
  # turn_file_path <hash> <turn> <phase>
  printf '%s/turns/%03d-%s.json' "$(session_dir "$1")" "$2" "$3"
}

edits_jsonl_path() {
  printf '%s/edits.jsonl' "$(session_dir "$1")"
}

inspect_md_path() {
  # /inspect deep-dive output (Q3 confirmed: lives in session dir).
  printf '%s/inspect_%03d.md' "$(session_dir "$1")" "$2"
}

ensure_session_dir() {
  local hash="$1"
  mkdir -p "$(turns_dir "$hash")"
}

# next_turn_number <hash>
# Reads zero-padded NNN-{pre,post}.json filenames in turns/ and returns max+1.
# Returns 1 if turns/ is empty.
next_turn_number() {
  local hash="$1"
  local dir
  dir="$(turns_dir "$hash")"
  if [ ! -d "$dir" ]; then
    printf '1'
    return
  fi
  local max
  max=$(ls -1 "$dir" 2>/dev/null \
    | grep -E '^[0-9]{3}-(pre|post)\.json$' \
    | cut -c1-3 \
    | sort -n \
    | tail -1)
  if [ -z "$max" ]; then
    printf '1'
  else
    printf '%d' "$((10#$max + 1))"
  fi
}

# acquire_lock <hash> <name>
# mkdir-based mutex. Q11 decision: macOS lacks GNU flock, mkdir is atomic on
# local filesystems and works on bash 3.2. Busy-wait up to 2s with 50ms
# sleeps. Caller MUST pair with release_lock or set a trap.
acquire_lock() {
  local hash="$1"
  local name="$2"
  local lock_dir
  lock_dir="$(session_dir "$hash")/.${name}.lock"
  local elapsed=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ "$elapsed" -ge 40 ]; then
      printf 'contextbuddy: lock timeout on %s\n' "$lock_dir" >&2
      return 1
    fi
    sleep 0.05
    elapsed=$((elapsed + 1))
  done
}

release_lock() {
  local hash="$1"
  local name="$2"
  rmdir "$(session_dir "$hash")/.${name}.lock" 2>/dev/null || true
}

# atomic_write <target_path>
# Reads stdin, writes to a temp file, then renames atomically. Per SPEC.md
# §4.3 every JSON write must be atomic so the buddy never sees a partial
# file under FSEvents.
atomic_write() {
  local target="$1"
  local dir
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  local tmp
  tmp="$(mktemp "${dir}/.write.XXXXXX")"
  cat > "$tmp"
  mv -f "$tmp" "$target"
}
