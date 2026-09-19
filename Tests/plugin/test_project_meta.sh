#!/usr/bin/env bash
# test_project_meta — the hooks record the absolute project path into the session
# dir so the buddy's popover project footer row can name the project (issue #38).
#
# The project hash is one-way (sha256(path)[:12]), so nothing can recover the path
# unless a hook writes it down. The load-bearing assertion here is the round trip:
# project_hash(recorded path) must equal the directory name the file was written
# into, or the footer row would name a different project than the scores belong to.
#
# Runs the real hooks under a throwaway HOME with a stub `claude` on PATH;
# CONTEXTBUDDY_CLAUDE_CONFIG_DIR points at a temp dir so the anthropic backend
# proceeds. No network, no keys.
# shellcheck disable=SC2015  # `A && ok || fail` is the intended assertion idiom here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PRE_HOOK="$REPO/plugin/hooks/user_prompt_submit.sh"
POST_HOOK="$REPO/plugin/hooks/stop.sh"
# shellcheck source=../../plugin/lib/project_hash.sh
. "$REPO/plugin/lib/project_hash.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

if ! command -v jq >/dev/null 2>&1; then
  printf 'test_project_meta: jq is required to run these tests.\n' >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/cfg"
export PATH="$TMP/bin:$PATH"
export CONTEXTBUDDY_CLAUDE_CONFIG_DIR="$TMP/cfg"
unset TYPESAFE_API_KEY ANTHROPIC_API_KEY  # no Jev shadow, no key leak

GRADE_FILE="$TMP/grade.json"
cat > "$TMP/bin/claude" <<STUBEOF
#!/usr/bin/env bash
cat "$GRADE_FILE"
STUBEOF
chmod +x "$TMP/bin/claude"
jq -c -n '{
  schema_version: 1, phase: "pre", turn: 1, timestamp: "2026-09-18T00:00:00Z",
  scores: {
    confidence: {value: 7, rationale: "r"}, atomicity: {value: 7, rationale: "r"},
    drift: {value: 2, rationale: "r"}, pollution: {value: 4, rationale: "r"}
  },
  tokens_used: 1000, tokens_limit: 200000, dominant_signal: null,
  summary_update: "s"
}' > "$GRADE_FILE"

PRE_PAYLOAD='{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"UserPromptSubmit","prompt":"hello there"}'
POST_PAYLOAD='{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp/p","hook_event_name":"Stop"}'

run_hook() {
  # run_hook <hook> <project_dir> <payload>
  ( cd "$2" && printf '%s' "$3" | bash "$1" >"$TMP/hook.out" 2>"$TMP/hook.err" )
  echo $?
}

# assert_meta <label> <hook> <payload> <project_dir>
# Runs the hook from <project_dir> and checks the four things the footer row needs:
# the hook survives, meta.json exists, it parses, and its path round-trips to the
# directory name. <project_dir> is the "$PWD" the hook runs under; what gets
# recorded is its canonical form (issue #4). mktemp hands out /var/folders/...
# paths, which resolve to /private/var/..., so this also covers a symlinked cwd
# through the real hook.
assert_meta() {
  local label="$1" hook="$2" payload="$3" project="$4"
  local hash session_dir meta recorded canonical rc
  hash="$(project_hash "$project")"
  session_dir="$HOME/.claude/inspector/sessions/$hash"
  meta="$session_dir/meta.json"
  rm -f "$meta"

  rc="$(run_hook "$hook" "$project" "$payload")"
  [ "$rc" = "0" ] && ok "$label: hook exits 0" \
    || fail "$label: hook exit $rc ($(cat "$TMP/hook.err"))"
  [ -f "$meta" ] && ok "$label: meta.json written" \
    || { fail "$label: no meta.json at $meta ($(cat "$TMP/hook.err"))"; return; }
  jq -e . "$meta" >/dev/null 2>&1 && ok "$label: meta.json is valid JSON" \
    || { fail "$label: meta.json is not valid JSON: $(cat "$meta")"; return; }

  recorded="$(jq -r '.project_path // empty' "$meta")"
  canonical="$(canonical_project_path "$project")"
  [ "$recorded" = "$canonical" ] \
    && ok "$label: project_path is the canonical hooked \$PWD" \
    || fail "$label: project_path is '$recorded', expected '$canonical'"
  [ "$(project_hash "$recorded")" = "$hash" ] \
    && ok "$label: recorded path hashes back to its own directory name" \
    || fail "$label: project_hash('$recorded') != $hash (path and hash disagree)"
}

# --- 1. pre hook on a plain path ------------------------------------------------------
mkdir -p "$TMP/plain"
assert_meta "pre" "$PRE_HOOK" "$PRE_PAYLOAD" "$TMP/plain"

# --- 2. stop hook can create the session dir the prompt hook never saw ----------------
mkdir -p "$TMP/postonly"
assert_meta "post" "$POST_HOOK" "$POST_PAYLOAD" "$TMP/postonly"

# --- 3. a path needing JSON escaping (quote + backslash + space) ----------------------
# macOS allows these in directory names; an unescaped one would emit invalid JSON and
# the buddy would silently fall back to the hash forever.
ODD="$TMP/od\"d \\ name"
mkdir -p "$ODD"
assert_meta "escaped path" "$PRE_HOOK" "$PRE_PAYLOAD" "$ODD"

# --- 4. rewritten every turn, so dirs predating the change self-heal ------------------
mkdir -p "$TMP/heal"
HEAL_HASH="$(project_hash "$TMP/heal")"
HEAL_META="$HOME/.claude/inspector/sessions/$HEAL_HASH/meta.json"
run_hook "$PRE_HOOK" "$TMP/heal" "$PRE_PAYLOAD" >/dev/null
rm -f "$HEAL_META"
run_hook "$PRE_HOOK" "$TMP/heal" "$PRE_PAYLOAD" >/dev/null
[ -f "$HEAL_META" ] && ok "self-heal: a later turn rewrites a deleted meta.json" \
  || fail "self-heal: meta.json not rewritten on a later turn"

# --- 5. a meta.json write failure never aborts the user's session (§13) ---------------
# Make the session dir read-only so atomic_write's mktemp fails, then confirm the
# hook still exits 0 and still grades the turn.
mkdir -p "$TMP/readonly"
RO_HASH="$(project_hash "$TMP/readonly")"
RO_DIR="$HOME/.claude/inspector/sessions/$RO_HASH"
mkdir -p "$RO_DIR/turns"
chmod 500 "$RO_DIR"
rc="$(run_hook "$PRE_HOOK" "$TMP/readonly" "$PRE_PAYLOAD")"
chmod 700 "$RO_DIR"
[ "$rc" = "0" ] && ok "unwritable session dir: hook still exits 0" \
  || fail "unwritable session dir: hook exit $rc ($(cat "$TMP/hook.err"))"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
