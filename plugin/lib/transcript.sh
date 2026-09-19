#!/usr/bin/env bash
# transcript — assemble the input bundle for the grader.
#
# Per SPEC.md §7 the grader receives:
#   1. session.md content (or "session.md not found" sentinel)
#   2. latest prompt (pre-phase) or latest turn including agent response (post)
#   3. last N typed prompts (N = [grader] sliding_window_turns, default 3)
#   4. prior rolling summary from history.jsonl tail
#   5. tokens_used (from the transcript) / tokens_limit (per session model, issue #47,
#      lib/context_window.sh, floored so used <= limit)
#   6. files edited in last 5 turns (post-phase, for loop pre-detection)
#
# Items 3 and 5, and the files stop.sh appends to edits.jsonl, come from the JSONL
# transcript at hook.transcript_path (issue #9). The hook payload carries none of
# them: UserPromptSubmit sends session_id, prompt_id, transcript_path, cwd,
# permission_mode, prompt; Stop sends last_assistant_message, stop_reason. The
# earlier reads of .transcript/.messages/.turns, .tokens_used/.usage and
# .tool_calls always saw nothing, so every LLM-backend grade had an empty window,
# tokens_used 0, and edits.jsonl never named a file (no loop detection).
#
# transcript_window applies the same record filters as grader/jev.mjs
# parseTranscript (and grader/jev_shadow.py), and the hooks size it with the
# [grader] sliding_window_turns key lib/job.sh hands the typesafe job (default 3),
# so the anthropic, ollama and openai_compatible backends grade the window the
# typesafe backend grades.
# Tests/plugin/test_jev_grader.mjs pins the node side and
# Tests/plugin/test_transcript_window.sh the bash side, on the same fixture
# (Tests/plugin/fixtures/transcript_window.jsonl). Change the filters in both
# places or in neither.
#
# Security note — transcript_path is untrusted hook input:
#   - It is a file name and nothing else: quoted everywhere, never eval'd, never
#     run, never written to.
#   - It reaches jq only by stdin redirection (`< "$path"`), never as an argument,
#     so a value such as "--slurp" or "-f" cannot become a jq option.
#   - Its content is parsed as JSON records only; lines that do not parse are
#     dropped. Nothing read from the file is executed.
#   - Only typed prompt text, edited file paths and usage integers leave this
#     file. tool_result content never enters the grader input (state size and
#     privacy).
#   - A missing, unreadable or unparseable file degrades to the empty window with
#     a `contextbuddy:` warning on stderr and return status 0, so the hook still
#     grades and never blocks the session (SPEC.md §13).

# shellcheck source=context_window.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/context_window.sh"

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

# transcript_path_from_hook_payload <payload_json>
# Echoes hook.transcript_path when it is a string; nothing when it is absent or
# not a string, the payload does not parse, or jq is missing.
transcript_path_from_hook_payload() {
  local payload="$1"
  command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "$payload" | jq -r '.transcript_path | select(type == "string")' 2>/dev/null || true
}

# transcript_window <transcript_path> <window> [<current_prompt>]
# Prints one compact JSON object and always returns 0:
#   {"prompts": [...], "tokens_used": N, "edited_files": [...]}
#
# prompts       The last <window> typed prompts, oldest first, as text. A typed
#               prompt is a type:"user" record that is not isSidechain (subagent
#               turn), isMeta (skill/command expansion injected as a user turn) or
#               isCompactSummary, and carries at least one text block — tool
#               results are user records with only tool_result blocks, so the
#               text requirement drops them. <system-reminder> blocks the harness
#               prepends are stripped; slash-command records (<command-name>,
#               <local-command-stdout>, <local-command-caveat>) are skipped. Same
#               rules as jev.mjs typedPromptText. With <current_prompt>, a last
#               prompt equal to it is dropped, as jev.mjs buildState does: the pre
#               hook may fire after the harness appended the prompt, and
#               "## latest prompt" already carries it.
# tokens_used   input_tokens + cache_read_input_tokens + cache_creation_input_tokens
#               of the last assistant record carrying usage; no overhead estimate.
#               0 when there is none yet. Records whose message.model is "<synthetic>"
#               are harness placeholders (API errors, zero usage), not a reply: they
#               contribute neither usage nor edits, as jev.mjs parseTranscript skips
#               them. The model itself is read by lib/context_window.sh, not here.
# edited_files  Unique file paths of Edit/Write/MultiEdit tool_use blocks in the
#               assistant records after the last typed prompt: this turn's edits,
#               which stop.sh appends to edits.jsonl for §5.4 loop detection.
#               Paths only, never tool input or output.
transcript_window() {
  local path="$1"
  local window="${2:-3}"
  local current="${3:-}"
  local empty='{"prompts":[],"tokens_used":0,"edited_files":[]}'
  case "$window" in
    ''|*[!0-9]*) window=3 ;;
  esac
  if ! command -v jq >/dev/null 2>&1; then
    printf 'contextbuddy: jq not found; grading with an empty turn window\n' >&2
    printf '%s' "$empty"
    return 0
  fi
  if [ -z "$path" ] || [ ! -f "$path" ] || [ ! -r "$path" ]; then
    printf 'contextbuddy: transcript not readable at "%s"; grading with an empty turn window\n' "$path" >&2
    printf '%s' "$empty"
    return 0
  fi
  local out
  out="$(jq -R -n -c --argjson n "$window" --arg current "$current" '
    def trimws: gsub("^\\s+"; "") | gsub("\\s+$"; "");
    def typed_prompt_text:
      if type != "object" or .type != "user"
         or .isSidechain == true or .isMeta == true or .isCompactSummary == true then null
      else
        (.message.content
          | if type == "string" then .
            elif type == "array" then
              ([.[] | select(type == "object" and .type == "text") | (.text // "")] | join("\n"))
            else "" end)
        | gsub("<system-reminder>[\\s\\S]*?</system-reminder>"; "")
        | trimws
        | if . == "" or startswith("<command-name>")
             or startswith("<local-command-stdout>") or startswith("<local-command-caveat>")
          then null else . end
      end;
    def edit_paths:
      [ (.message.content // [])
        | if type == "array" then .[] else empty end
        | select(type == "object" and .type == "tool_use"
                 and ((.name // "") | test("(Edit|Write|MultiEdit)"; "i")))
        | (.input.file_path // .input.path // empty)
        | select(type == "string") ];
    def usage_total:
      (.message.usage // null)
      | if type == "object"
        then (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)
        else null end;
    [inputs | fromjson?]
    | reduce .[] as $r ({prompts: [], tokens_used: 0, edited_files: []};
        ($r | typed_prompt_text) as $p
        | if $p != null then .prompts += [$p] | .edited_files = []
          elif ($r | type == "object" and .type == "assistant"
                and (($r.message.model // "") != "<synthetic>")) then
            .edited_files += ($r | edit_paths)
            | (($r | usage_total) as $u | if $u != null then .tokens_used = $u else . end)
          else . end)
    | (if $n < 1 then 1 else $n end) as $k
    | .prompts = (.prompts | if length > $k then .[length - $k:] else . end)
    | ($current | trimws) as $c
    | if $c != "" and (.prompts | length) > 0 and .prompts[-1] == $c
      then .prompts = .prompts[:-1] else . end
    | .edited_files |= unique
  ' < "$path" 2>/dev/null)"
  if [ -z "$out" ]; then
    printf 'contextbuddy: could not parse transcript at "%s"; grading with an empty turn window\n' "$path" >&2
    printf '%s' "$empty"
    return 0
  fi
  printf '%s' "$out"
}

# Accessors over a transcript_window result, for the hooks' input bundle.
# prompts_from_window <window_json>       -> JSON array (the "last N turns" section)
# tokens_used_from_window <window_json>   -> decimal integer, 0 when absent or malformed
# edited_files_from_window <window_json>  -> JSON array
# tokens_line_from_context <context_json> -> "<tokens_used> <tokens_limit>"
# The hooks hand tokens_used_from_window and the transcript path to lib/context_window.sh
# resolve_context_window (issue #47); its {tokens_used, tokens_limit, model, limit_source}
# is the one pair the "## tokens" line, the typesafe job and the written grade carry, and
# its evidence floor guarantees tokens_used <= tokens_limit, so a count above a model's
# nominal window raises the limit instead of tripping context_pressure on every turn.
prompts_from_window() {
  printf '%s' "$1" | jq -c '.prompts // []' 2>/dev/null || printf '[]'
}

tokens_used_from_window() {
  local used
  used="$(printf '%s' "$1" | jq -r '.tokens_used // 0' 2>/dev/null)" || used=0
  # Digits-only guard: the value is a string from jq over untrusted input, never handed
  # to [ -gt ] or --argjson unchecked.
  case "$used" in ''|*[!0-9]*) used=0 ;; esac
  printf '%s' "$used"
}

edited_files_from_window() {
  printf '%s' "$1" | jq -c '.edited_files // []' 2>/dev/null || printf '[]'
}

tokens_line_from_context() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r '"\(.tokens_used // 0) \(.tokens_limit // 200000)"' 2>/dev/null && return 0
  fi
  printf '0 %s' "$CONTEXT_WINDOW_DEFAULT"
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
