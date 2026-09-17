#!/usr/bin/env bash
# test_job_builder — the JSON job the hooks hand to the typesafe backend
# (plugin/lib/job.sh: build_job). Asserted with jq; no network, no model.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# shellcheck source=../../plugin/lib/config.sh
. "$REPO_ROOT/plugin/lib/config.sh"
# shellcheck source=../../plugin/lib/job.sh
. "$REPO_ROOT/plugin/lib/job.sh" || { printf 'plugin/lib/job.sh missing\n' >&2; exit 1; }

ws="$(mktemp -d "${TMPDIR:-/tmp}/cb_test_job.XXXXXX")"
printf '[thresholds]\natomicity_attention = 5\n\n[grader]\nbackend = "typesafe"\nmodel = "jev-1.13.0"\nsliding_window_turns = 4\n' > "$ws/config.toml"
printf -- '---\ngoal: Refactor auth to JWT\n---\n' > "$ws/session.md"
printf '{"schema_version":1,"phase":"post","turn":13,"scores":{"pollution":{"value":4,"rationale":"three superseded plans"}}}\n' > "$ws/history.jsonl"
payload='{"session_id":"s","transcript_path":"/t.jsonl","prompt":"fix it"}'

job="$(build_job "pre" 14 "2026-09-17T12:00:00Z" "$payload" "$ws/session.md" "$ws/history.jsonl" "$ws/config.toml")"
check() { # check <label> <jq-expr>
  if printf '%s' "$job" | jq -e "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1: $2"; printf '%s\n' "$job" >&2; fi
}
check "job carries phase, turn, timestamp" '.phase=="pre" and .turn==14 and .timestamp=="2026-09-17T12:00:00Z"'
check "job embeds the raw hook payload" '.hook.prompt=="fix it" and .hook.transcript_path=="/t.jsonl"'
check "job carries session.md frontmatter text" '.session_md | test("goal: Refactor auth to JWT")'
check "job carries prior pollution with its turn" '.prior_pollution.turn==13 and .prior_pollution.value==4'
check "job thresholds come from config with defaults for the rest" '.thresholds.atomicity_attention==5 and .thresholds.confidence_attention==4 and .thresholds.drift_attention==6 and .thresholds.pollution_attention==7'
check "job window and model come from config" '.window_turns==4 and .model=="jev-1.13.0" and .tokens_limit==200000'

job="$(build_job "post" 1 "t" "$payload" "$ws/nope.md" "$ws/nohistory.jsonl" "$ws/config.toml")"
check "missing session.md yields null anchor" '.session_md==null'
check "missing history yields null prior pollution" '.prior_pollution==null'

rm -rf "$ws"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
