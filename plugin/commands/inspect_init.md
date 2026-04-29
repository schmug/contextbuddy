---
description: Bootstrap a ContextBuddy session.md anchor for the current project.
---

You are bootstrapping a ContextBuddy `session.md` anchor file at `~/.claude/inspector/sessions/<project-hash>/session.md`. Project hash is `sha256(absolute_path($PWD))[:12]`.

## Steps

1. Compute the project hash and target path. Run:
   ```bash
   PROJECT_HASH=$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12)
   SESSION_DIR="$HOME/.claude/inspector/sessions/$PROJECT_HASH"
   mkdir -p "$SESSION_DIR"
   TARGET="$SESSION_DIR/session.md"
   ```
2. If `$TARGET` already exists, print its contents and stop. Do not overwrite.
3. If a `CLAUDE.md` exists at the project root, propose a draft anchor based on it. Otherwise, ask the user inline for: goal (one sentence), 1-3 acceptance criteria, in-scope path globs, out-of-scope path globs, and any constraints.
4. Write the anchor as YAML frontmatter (with `---` fences) per SPEC.md §4.4 + Decision Q1:
   ```yaml
   ---
   goal: <one sentence>
   acceptance:
     - <criterion 1>
     - <criterion 2>
   in_scope:
     - <path/glob>
   out_of_scope:
     - <path/glob>
   constraints:
     - <constraint>
   created_at: <ISO 8601 UTC, fill with current time>
   ---
   ```
5. Write to `$TARGET` and confirm to the user.

The anchor is the source of truth for confidence (specification quality) and drift (alignment) grading. Encourage the user to keep it updated as the session evolves rather than letting it go stale.
