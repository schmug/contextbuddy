---
description: ContextBuddy deep-dive grade using Sonnet — multi-paragraph analysis + recommendations.
---

You are running a ContextBuddy deep-dive grade. This is a Sonnet-class call (slower, more thorough than the per-turn Haiku grade) and produces a multi-paragraph analysis plus structured recommendations.

## Steps

1. Resolve project hash and current turn:
   ```bash
   PROJECT_HASH=$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12)
   SESSION_DIR="$HOME/.claude/inspector/sessions/$PROJECT_HASH"
   TURN=$(ls -1 "$SESSION_DIR/turns" 2>/dev/null | grep -E '^[0-9]{3}-(pre|post)\.json$' | cut -c1-3 | sort -n | tail -1 || printf '0')
   TURN=$((10#${TURN:-0}))
   ```
2. Read `inspect_model` from `~/.claude/inspector/config.toml` (default `claude-sonnet-4-6`).
3. Assemble the same input bundle the regular grader receives (session.md, last 3 turns from this session's transcript, prior summary from `history.jsonl` tail, tokens, files edited in last 5 turns).
4. Invoke the deep-dive grader with the system prompt at `<plugin-root>/grader/inspect_system_prompt.md`.
5. Validate JSON, then write to `$SESSION_DIR/inspect_${TURN}.md`. The output IS markdown despite the `.md` extension carrying a JSON body — wrap it in a fenced code block with the JSON inside, plus a human-readable rendering above.

## Output to user (terminal)

Print:
- The `deep_analysis` paragraphs (rendered as markdown).
- The numbered list of `recommendations` with their `suggested_prompt` blocks.
- A note that the full JSON is at `$SESSION_DIR/inspect_${TURN}.md`.
