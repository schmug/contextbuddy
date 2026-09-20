#!/usr/bin/env bash
# grader_status — record the outcome of one grader attempt (SPEC.md §4.10, issue #92).
#
# Before this file existed, a grader that could not run left nothing on disk: the
# hooks created the session dir, wrote meta.json and turns/.counter, logged one
# line to stderr and exited 0. Hook stderr is surfaced nowhere a user looks, so
# "the grader has no key" and "nobody typed anything" were the same picture — 22
# of 37 session dirs on the reporter's disk had no grade and no explanation.
#
# Both hooks call write_grader_status exactly once per turn, after grader/invoke.sh
# returns and after the §4.1 schema check, whatever the outcome. The record is
# last-attempt-wins: the condition being reported is persistent, and overwriting on
# every attempt is what lets a key that starts working clear the warning on the next
# turn (and a key that DIES mid-session raise one, which is the failure that looks
# healthy because last.json still holds a good grade).
#
# Two rules the record depends on:
#
#   1. `reason` is derived from invoke.sh's EXIT CODE, never from its stderr. The
#      codes are fixed and shared with grader/jev.mjs: 2 not-configured, 3 transport
#      or empty response, 4 unparseable response, 5 missing credential.
#   2. `detail` is a fixed string this file owns, one per reason class. Nothing the
#      backend printed is copied into it. Backend stderr can carry an echoed
#      Authorization header, an `sk-…` in an error body, or response text, and this
#      file is written in the clear next to the grades. The backend's own lines still
#      go to stderr exactly as before; they are just not persisted.
#      Tests/plugin/test_grader_status.sh pins both rules.
#
# Never fails the caller: every path returns 0, so a status write cannot abort the
# user's turn (SPEC §13). A write into an unwritable session dir is simply lost.
#
# Usage:
#   source plugin/lib/session_paths.sh
#   source plugin/lib/grader_status.sh
#   write_grader_status <hash> <phase> <turn> <timestamp> <backend> <rc> <had_grade>
#
# <rc> is invoke.sh's exit status. <had_grade> is "true" when a validated grade was
# written for this turn and "false" otherwise; it is what separates exit 0 with a
# grade (ok) from exit 0 with no output (the typesafe task gate declined the turn).

# grader_status_reason <rc> <had_grade>
# Prints "<status> <reason>" for one attempt. reason is "null" when status is ok.
grader_status_reason() {
  local rc="$1" had_grade="$2"
  case "$rc" in
    0)
      if [ "$had_grade" = "true" ]; then
        printf 'ok null'
      else
        # jev.mjs exits 0 with no output when its is_task gate decides the turn was
        # not a prompt. The grader ran and answered, so this is a skip, not a fault.
        printf 'skipped not_a_task'
      fi
      ;;
    2) printf 'error not_configured' ;;
    3) printf 'error transport_failure' ;;
    4) printf 'error invalid_response' ;;
    5) printf 'error missing_key' ;;
    *) printf 'error unknown' ;;
  esac
}

# grader_status_detail <reason> <backend>
# One fixed sentence per reason class. Authored here, never taken from the backend.
grader_status_detail() {
  local reason="$1" backend="$2"
  case "$reason" in
    null)
      printf 'Graded by the %s backend.' "$backend"
      ;;
    not_a_task)
      printf 'The %s backend declined to grade this turn (below [grader.typesafe].task_gate).' "$backend"
      ;;
    missing_key)
      printf 'The %s backend has no credential. Export it in the environment Claude Code inherits, or put it in a .env in this project, its worktree root, or the main checkout (plugin/lib/dotenv.sh). See the hook stderr for which variable.' "$backend"
      ;;
    not_configured)
      printf 'The %s backend is not runnable here: a required tool, job file, or [grader] setting is missing. See the hook stderr.' "$backend"
      ;;
    transport_failure)
      printf 'The %s backend could not be reached, or returned nothing after a retry.' "$backend"
      ;;
    invalid_response)
      printf 'The %s backend answered with something that is not a valid grade.' "$backend"
      ;;
    *)
      printf 'The %s backend failed for an unrecognized reason. See the hook stderr.' "$backend"
      ;;
  esac
}

# write_grader_status <hash> <phase> <turn> <timestamp> <backend> <rc> <had_grade>
write_grader_status() {
  local hash="$1" phase="$2" turn="$3" ts="$4" backend="$5" rc="$6" had_grade="$7"
  local status reason detail path
  # shellcheck disable=SC2046  # two words by construction (see grader_status_reason)
  set -- $(grader_status_reason "$rc" "$had_grade")
  status="$1"; reason="$2"
  detail="$(grader_status_detail "$reason" "$backend")"
  path="$(grader_status_path "$hash")"

  # jq when it is there, hand-rolled when it is not: the hooks all guard on jq, and
  # the trace for "this install cannot grade" must not itself need a tool to exist.
  # Every value here is either a literal from this file or an integer, so
  # json_escape_string (lib/session_paths.sh) covers the fallback completely.
  if command -v jq >/dev/null 2>&1; then
    jq -c -n \
      --argjson v 1 \
      --arg ts "$ts" \
      --arg phase "$phase" \
      --argjson turn "$turn" \
      --arg backend "$backend" \
      --arg status "$status" \
      --arg reason "$reason" \
      --arg detail "$detail" \
      '{schema_version: $v, timestamp: $ts, phase: $phase, turn: $turn,
        backend: $backend, status: $status,
        reason: (if $reason == "null" then null else $reason end),
        detail: $detail}' 2>/dev/null | atomic_write "$path" 2>/dev/null
  else
    local reason_json='null'
    [ "$reason" = "null" ] || reason_json="\"$(json_escape_string "$reason")\""
    printf '{"schema_version":1,"timestamp":"%s","phase":"%s","turn":%d,"backend":"%s","status":"%s","reason":%s,"detail":"%s"}\n' \
      "$(json_escape_string "$ts")" \
      "$(json_escape_string "$phase")" \
      "$turn" \
      "$(json_escape_string "$backend")" \
      "$(json_escape_string "$status")" \
      "$reason_json" \
      "$(json_escape_string "$detail")" \
      | atomic_write "$path" 2>/dev/null
  fi
  return 0
}
