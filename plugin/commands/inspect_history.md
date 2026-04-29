---
description: Render a compact ContextBuddy timeline of grades with highlighted state transitions.
---

You are rendering a compact timeline of ContextBuddy grades from `history.jsonl`.

## Steps

1. Resolve `$HOME/.claude/inspector/sessions/<project-hash>/history.jsonl` for the current `$PWD`.
2. If the file doesn't exist, print "no grades recorded for this project yet" and stop.
3. Read each line and emit one row per grade, formatted:
   ```
   T## phase  conf:N atom:N drift:N pol:N  signal:<dom or ->  YYYY-MM-DD HH:MM
   ```
4. **Highlight state transitions**: between adjacent rows, emit a horizontal divider when the would-be state changes (per the same logic the buddy applies — score thresholds from `config.toml`, dominant_signal sentinels, etc.). For visual scanning, prefix transition lines with `→ <state>`.
5. Total counts at the bottom: `N grades | M attention | K dizzy | C celebrate`.

Use a monospaced rendering. No API calls — this is a pure local read.
