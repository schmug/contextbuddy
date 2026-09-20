---
description: Diff two ContextBuddy turns to surface which scores changed and why.
argument-hint: <turn1> <turn2>
---

You are diffing two ContextBuddy per-turn snapshots. Arguments: `<turn1> <turn2>` (e.g., `/inspect diff 14 15`).

## Steps

1. Resolve the session directory for the current `$PWD`, resolving symlinks first so the hash matches the hooks (same rule as `plugin/lib/project_hash.sh`):
   ```bash
   PROJECT_HASH=$(printf '%s' "$(cd -P -- "$PWD" 2>/dev/null && pwd -P || printf '%s' "$PWD")" | shasum -a 256 | cut -c1-12)
   SESSION_DIR="$HOME/.claude/inspector/sessions/$PROJECT_HASH"
   ```
   Turn files live in `$SESSION_DIR/turns/`.
2. Find both turn files. Each turn may have `NNN-pre.json` and/or `NNN-post.json`. Default to `post` if both exist; warn if only one phase is present.
3. For each of the four scored dimensions, emit:
   ```
   <dimension>: <oldValue> → <newValue>  Δ<delta>
     was:  <oldRationale>
     now:  <newRationale>
   ```
4. Show the dominant_signal change if any (`-` to denote null).
5. Show the summary_update transition (full text of new; truncate old to 150 chars + "…" if it differs).

Highlight increases in confidence/atomicity (good) in green, decreases in red. Inverse for drift/pollution (low is good per §6 rubric — Q13).
