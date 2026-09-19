---
description: Render a compact ContextBuddy timeline of grades with highlighted state transitions.
---

You are rendering a compact timeline of ContextBuddy grades from `history.jsonl`.

## Steps

1. Resolve the session directory for the current `$PWD`, resolving symlinks first so the hash matches the hooks (same rule as `plugin/lib/project_hash.sh`):
   ```bash
   PROJECT_HASH=$(printf '%s' "$(cd -P -- "$PWD" 2>/dev/null && pwd -P || printf '%s' "$PWD")" | shasum -a 256 | cut -c1-12)
   SESSION_DIR="$HOME/.claude/inspector/sessions/$PROJECT_HASH"
   ```
   The timeline is `$SESSION_DIR/history.jsonl`.
2. If the file doesn't exist, print "no grades recorded for this project yet" and stop.
3. Read each line and emit one row per grade, formatted:
   ```
   T## phase  conf:N atom:N drift:N pol:N  signal:<dom or ->  YYYY-MM-DD HH:MM
   ```
4. **Highlight state transitions**: between adjacent rows, emit a horizontal divider when the would-be state changes (per the same logic the buddy applies — score thresholds from `config.toml`, dominant_signal sentinels, etc.). For visual scanning, prefix transition lines with `→ <state>`.
5. Total counts at the bottom: `N grades | M attention | K dizzy | C celebrate`.

Use a monospaced rendering. No API calls — this is a pure local read.
