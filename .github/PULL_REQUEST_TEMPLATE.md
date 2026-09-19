## What

<!-- One or two sentences. What does this change do? -->

## Why

<!-- The bug, the gap, or the issue number. Link it: Fixes #123 -->

## How it was tested

<!-- Both suites, plus anything manual. Delete what does not apply. -->

```
bash scripts/test_plugin.sh
swift test
```

<!-- Manual: e.g. "ran `claude --plugin-dir ./plugin/`, sent 3 prompts,
     checked the popover showed a grade and history.jsonl grew by 3 lines" -->

## Checklist

- [ ] Both test suites pass locally
- [ ] `SPEC.md` updated if this changes behaviour it describes
- [ ] `README.md` updated if this changes something a user types or sees
- [ ] No `.env`, API key, or other secret in the diff
- [ ] No real prompt or transcript text in fixtures
- [ ] Hooks still return promptly — slow work is deferred to the background job
