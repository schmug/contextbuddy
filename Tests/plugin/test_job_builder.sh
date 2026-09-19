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
printf '{"type":"assistant","message":{"model":"claude-fable-5-1","usage":{"input_tokens":2,"cache_read_input_tokens":176000,"cache_creation_input_tokens":472}}}\n' > "$ws/t.jsonl"
payload="$(jq -c -n --arg t "$ws/t.jsonl" '{session_id:"s",transcript_path:$t,prompt:"fix it"}')"
unset CONTEXTBUDDY_CONTEXT_WINDOW CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_DISABLE_1M_CONTEXT
export HOME="$ws/home"; mkdir -p "$HOME"   # no real settings.json / autocompact window

job="$(build_job "pre" 14 "2026-09-17T12:00:00Z" "$payload" "$ws/session.md" "$ws/history.jsonl" "$ws/config.toml")"
check() { # check <label> <jq-expr>
  if printf '%s' "$job" | jq -e "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1: $2"; printf '%s\n' "$job" >&2; fi
}
check "job carries phase, turn, timestamp" '.phase=="pre" and .turn==14 and .timestamp=="2026-09-17T12:00:00Z"'
check "job embeds the raw hook payload" '.hook.prompt=="fix it" and (.hook.transcript_path | endswith("/t.jsonl"))'
check "job carries session.md frontmatter text" '.session_md | test("goal: Refactor auth to JWT")'
check "job carries prior pollution with its turn" '.prior_pollution.turn==13 and .prior_pollution.value==4'
check "job thresholds come from config with defaults for the rest" '.thresholds.atomicity_attention==5 and .thresholds.confidence_attention==4 and .thresholds.drift_attention==6 and .thresholds.pollution_attention==7'
check "job window and model come from config" '.window_turns==4 and .model=="jev-1.13.0"'
# Issue #47: the limit is resolved per session model (lib/context_window.sh), not hardcoded.
check "job tokens_limit comes from the transcript model" '.tokens_limit==1000000 and .session_model=="claude-fable-5-1" and .limit_source=="model"'
job="$(CONTEXTBUDDY_CONTEXT_WINDOW=300000 build_job "pre" 14 "t" "$payload" "$ws/session.md" "$ws/history.jsonl" "$ws/config.toml")"
check "job honours the CONTEXTBUDDY_CONTEXT_WINDOW override" '.tokens_limit==300000 and .limit_source=="override"'
job="$(build_job "pre" 14 "t" '{"session_id":"s","transcript_path":"/nonexistent.jsonl","prompt":"x"}' "$ws/session.md" "$ws/history.jsonl" "$ws/config.toml")"
check "job without a transcript falls back to the default window" '.tokens_limit==200000 and .session_model==null and .limit_source=="default"'
ctx='{"model":"claude-haiku-4-5-20251001","tokens_used":10,"tokens_limit":200000,"limit_source":"model"}'
job="$(build_job "pre" 14 "t" "$payload" "$ws/session.md" "$ws/history.jsonl" "$ws/config.toml" "$ctx")"
check "job takes a pre-resolved context from the hook instead of resolving again" '.tokens_limit==200000 and .session_model=="claude-haiku-4-5-20251001"'

# Issue #8: [grader.typesafe] gates and endpoint travel in the job; the key
# does not (invoke.sh hands it to the child env only).
check "job carries the typesafe gate defaults when the section is absent" '.task_gate==0.5 and .harm_action==0.7 and .endpoint=="https://api.typesafe.ai"'
printf '\n[grader.typesafe]\napi_key_env = "MY_JEV_KEY"\nendpoint = "http://127.0.0.1:8080"\ntask_gate = 0.6\nharm_action = 0.9\n' >> "$ws/config.toml"
job="$(MY_JEV_KEY=sk-never-in-job build_job "pre" 14 "t" "$payload" "$ws/session.md" "$ws/history.jsonl" "$ws/config.toml")"
check "job carries task_gate, harm_action and endpoint from [grader.typesafe]" '.task_gate==0.6 and .harm_action==0.9 and .endpoint=="http://127.0.0.1:8080"'
check "job never carries the API key or its env var name" '(tostring | test("sk-never-in-job") | not) and (has("api_key_env") | not)'
printf '[grader]\nbackend = "typesafe"\n\n[grader.typesafe]\ntask_gate = "half"\nharm_action = 0.9\n' > "$ws/config.toml"
job="$(build_job "pre" 14 "t" "$payload" "$ws/session.md" "$ws/history.jsonl" "$ws/config.toml")"
check "a non-numeric task_gate falls back to the default" '.task_gate==0.5 and .harm_action==0.9'
# Above 1 is treated like a malformed value (`task_gate = 50` is percent
# confusion, not a probability, and would gate every turn); 1.0 is the top
# of the range and stands.
printf '[grader]\nbackend = "typesafe"\n\n[grader.typesafe]\ntask_gate = 50\nharm_action = 1.0\n' > "$ws/config.toml"
job="$(build_job "pre" 14 "t" "$payload" "$ws/session.md" "$ws/history.jsonl" "$ws/config.toml")"
check "a task_gate above 1 falls back to the default; 1.0 stands" '.task_gate==0.5 and .harm_action==1'

job="$(build_job "post" 1 "t" "$payload" "$ws/nope.md" "$ws/nohistory.jsonl" "$ws/config.toml")"
check "missing session.md yields null anchor" '.session_md==null'
check "missing history yields null prior pollution" '.prior_pollution==null'

rm -rf "$ws"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
