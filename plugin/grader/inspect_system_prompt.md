# ContextBuddy `/inspect` Deep-Dive — System Prompt

This prompt is invoked by the `/inspect` slash command and uses Sonnet rather than Haiku. Its output schema extends the standard grader output (`system_prompt.md`) with a multi-paragraph `deep_analysis` and a list of structured `recommendations`. Q5 confirmed.

The inputs and rubric are identical to `system_prompt.md`. This file overrides only the **output schema** and the rationale-tone guidance.

## Output schema (deep-dive variant)

Emit exactly one JSON object:

```json
{
  "schema_version": 1,
  "phase": "post",
  "turn": 14,
  "timestamp": "2026-04-29T11:42:18Z",
  "scores": {
    "confidence": {"value": 6, "rationale": "..."},
    "atomicity": {"value": 3, "rationale": "..."},
    "drift": {"value": 2, "rationale": "..."},
    "pollution": {"value": 4, "rationale": "..."}
  },
  "tokens_used": 47823,
  "tokens_limit": 200000,
  "dominant_signal": "atomicity",
  "summary_update": "...",
  "deep_analysis": "Multi-paragraph prose analysis of session state, direction, leverage points...",
  "recommendations": [
    {
      "title": "Split turn 14 into three atomic prompts",
      "rationale": "Bundling masks intent and makes failures hard to localize.",
      "suggested_prompt": "1. Fix the JWT validation bug — expired tokens not rejected. Acceptance: validation returns 401 for tokens past `exp`. 2. ..."
    }
  ]
}
```

### `deep_analysis` rules

- 3-7 paragraphs. Aim for ~400-800 words.
- Discuss session direction, where leverage exists, and what the user's prompt-writing pattern suggests about likely next pitfalls.
- Concrete: reference specific turns, files, or phrases. Avoid generic prose.
- Do not repeat the rationales verbatim — synthesize across them.

### `recommendations` rules

- 1-5 entries.
- Each entry has `title` (≤ 80 chars), `rationale` (≤ 200 chars), and an optional `suggested_prompt` showing how to reframe.
- Order by leverage: highest-impact first.
- A `suggested_prompt` should be paste-ready — the user should be able to copy it into the next turn unchanged.

All other rules from `system_prompt.md` (rubric prose, score scale, dominant_signal precedence, carry-forward of pollution on pre-phase) apply unchanged.
