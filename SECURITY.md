# Security Policy

## Reporting a vulnerability

Report security issues privately through GitHub's **Report a vulnerability**
button on the [Security tab](https://github.com/schmug/contextbuddy/security)
of this repository. That opens a private advisory visible only to the
maintainers.

Please do not open a public issue for a security report.

Include what you would want to receive: the version or commit, the platform,
what an attacker can do, and the smallest reproduction you can manage. If the
report involves a prompt or transcript, redact it — see below.

Expect an acknowledgement within a week. This is a personal project, not a
staffed product, so please size your disclosure timeline accordingly; if the
fix will take longer than the window you have in mind, say so and we can agree
on a date.

## Supported versions

The tip of `main` is the only supported version. Fixes land there; there are no
backported release branches.

## What ContextBuddy touches

Worth understanding before you assess a finding, and before you attach
anything to a report:

- **It reads your Claude Code transcripts.** The plugin hooks read the session
  transcript to build the window it grades. Your prompts are the input to this
  tool by design.
- **It writes grades to local disk.** Grades, history, and session state are
  written under the plugin's local state directory. `history.jsonl` accumulates
  one grade per line and is not rotated or encrypted.
- **Some grader backends send prompt text off the machine.** The `claude -p`
  and `typesafe` backends send the graded window to their respective APIs. The
  local backends do not. Which backend is active is configuration
  (see the Backends section of the README), so treat backend selection as a
  data-egress decision.
- **Credentials live in `.env`.** `TYPESAFE_API_KEY` and friends are read from
  `.env` at the repo root, which is gitignored. Nothing else should be.

## Redacting a report

When a reproduction involves a real session, replace the prompt and response
bodies with placeholder text before attaching anything. The structure of a
`history.jsonl` line or a transcript window is almost always what matters; the
content of your prompts is almost never what matters, and it is often the most
sensitive thing on the machine.
