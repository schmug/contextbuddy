#!/usr/bin/env bash
# job — assemble the JSON job the typesafe backend (grader/jev.mjs) reads on stdin.
#
# The hooks call build_job on every grade and hand the file to invoke.sh via
# CONTEXTBUDDY_JOB. Other backends ignore it. The grader reads the transcript
# itself from hook.transcript_path; this file carries only what the transcript
# does not: phase, turn, timestamp, the raw hook payload, session.md text,
# the prior grade's pollution (pre-phase carries it forward), thresholds,
# window size, and model.
#
# Usage:
#   source plugin/lib/config.sh
#   source plugin/lib/job.sh
#   build_job <phase> <turn> <timestamp> <hook_payload_json> <session_md_path> \
#             <history_jsonl_path> <config_path> > job.json
#
# Never errors on missing inputs: absent session.md → null, absent history →
# null, unparseable payload → {} (the grader then exits 2 and the hook skips).

build_job() {
  local phase="$1" turn="$2" ts="$3" payload="$4" session_md="$5" history="$6" cfg="$7"
  local model window ca aa da pa prior
  model="$(toml_get_section_key "$cfg" "grader" "model")"
  model="${model:-jev-1.13.0}"
  window="$(toml_get_section_int "$cfg" "grader" "sliding_window_turns" 3)"
  ca="$(toml_get_section_int "$cfg" "thresholds" "confidence_attention" 4)"
  aa="$(toml_get_section_int "$cfg" "thresholds" "atomicity_attention" 4)"
  da="$(toml_get_section_int "$cfg" "thresholds" "drift_attention" 6)"
  pa="$(toml_get_section_int "$cfg" "thresholds" "pollution_attention" 7)"

  if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
    payload='{}'
  fi

  prior='null'
  if [ -f "$history" ]; then
    prior="$(tail -n 1 "$history" \
      | jq -c 'select(.scores.pollution.value != null) | {turn: .turn, value: .scores.pollution.value, rationale: (.scores.pollution.rationale // "")}' 2>/dev/null)"
    prior="${prior:-null}"
  fi

  local -a sm_arg
  if [ -f "$session_md" ]; then
    sm_arg=(--rawfile session_md "$session_md")
  else
    sm_arg=(--argjson session_md null)
  fi

  jq -n \
    --arg phase "$phase" \
    --argjson turn "$turn" \
    --arg ts "$ts" \
    --argjson hook "$payload" \
    --argjson prior "$prior" \
    --argjson window "$window" \
    --arg model "$model" \
    --argjson ca "$ca" --argjson aa "$aa" --argjson da "$da" --argjson pa "$pa" \
    "${sm_arg[@]}" \
    '{
      phase: $phase,
      turn: $turn,
      timestamp: $ts,
      hook: $hook,
      session_md: $session_md,
      prior_pollution: $prior,
      tokens_limit: 200000,
      window_turns: $window,
      model: $model,
      thresholds: {confidence_attention: $ca, atomicity_attention: $aa, drift_attention: $da, pollution_attention: $pa}
    }'
}
