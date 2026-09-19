#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["typesafe-sdk==0.7.0"]
# ///
"""jev_shadow — Request A shadow grader (UserPromptSubmit) backed by TypeSafe's Jev.

Spawned detached by plugin/hooks/user_prompt_submit.sh. Advisory only: it writes one row
per turn beside the Haiku grade and acts on nothing. It never writes the hook's stdout and
always exits 0, so a failure here cannot reach the prompt path.

Files written (session dir = ~/.claude/inspector/sessions/<hash>):
    turns/NNN-pre.jev.json   one row, atomic write
    jev.jsonl                the same row appended
Never touched: turns/NNN-pre.json, last.json, history.jsonl, suggestions.md (Haiku path).
The menubar app watches only last.json (Sources/ContextBuddyCore/Watcher.swift).

State (docs.typesafe.ai/concepts/state): {"anchor", "recent_prompts", "prompt"}.
  anchor          first typed user prompt of the session, head+tail capped (ANCHOR_CAP)
  recent_prompts  last RECENT_N typed prompts before the latest, each capped (RECENT_CAP)
  prompt          the prompt being submitted, from the hook payload, capped (LATEST_CAP)
No tool results, no assistant prose. STATE_TOKEN_HARD_CAP is enforced in build_state.

The row also records context_window (issue #47): the session model from the transcript's last
assistant record and the resolved tokens_limit / limit_source (see resolve_context_window).

Questions: specificity / atomicity / drift as Score, criteria parsed verbatim from the
rubric tables in system_prompt.md at runtime (load_rubric_criteria); intent as Choice.
Model pinned to MODEL_ID; never an alias (docs.typesafe.ai/models: pin for stable
thresholds). Jev jaggedness (docs.typesafe.ai/model-jaggedness/jev-1.13): switch on the
argmax level, not the weighted mean; keep every count in code; keep state small.

Only stdlib is imported at module load so the tests run without the SDK; typesafe_sdk is
imported inside call_jev. Run standalone via `uv run --script` (PEP 723 header above).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import tempfile
import time

MODEL_ID = "jev-1.13.0"
STATE_TOKEN_HARD_CAP = 24000  # 32k state+question limit, minus questions, minus margin
CHARS_PER_TOKEN = 3  # deliberate over-count; usage.input_tokens is logged for calibration
ANCHOR_CAP = (1000, 500)  # (head, tail) estimated tokens
LATEST_CAP = (2000, 1000)
RECENT_CAP = (300, 100)
RECENT_N = 3
MARKER_ALLOWANCE = 16  # tokens the elision marker may add on top of a cap
MIN_CAP_TOKENS = 32  # halving stops here; below it the prompt is no longer judgeable
HAIKU_WAIT_S = 90.0
REQUEST_TIMEOUT_S = 20.0

QUESTION_IDS = ("specificity", "atomicity", "drift", "intent")
RUBRIC_SECTIONS = (("Confidence", "specificity"), ("Atomicity", "atomicity"), ("Drift", "drift"))

INSTRUCTIONS = {
    "specificity": (
        "How clear is `prompt` itself? Judge the specification quality of `prompt` as written, "
        "against the session anchor in `anchor`: whether the goal, the acceptance criteria (how "
        "done is recognised), the scope, and the constraints are explicit enough that a competent "
        "coding agent could not reasonably misinterpret it. Do not judge whether the agent will succeed."
    ),
    "atomicity": (
        "Is `prompt` one thing? One thing means a single decision OR a single action, not both and "
        "not multiple of either. Count decisions and actions that are bundled in `prompt`, including "
        "ones disguised as a single ask (a fix that also requires deciding how, implementing, and "
        "updating tests)."
    ),
    "drift": (
        "Are we still doing what we said? Judge the distance of `prompt` from the session goal stated "
        "in `anchor`, plus any encroachment into things `anchor` explicitly marks out of scope. Judge "
        "against `anchor`, not against `recent_prompts`."
    ),
    "intent": "What is the developer doing with `prompt`, read after `anchor` and `recent_prompts`?",
}

INTENT_OPTIONS = {
    "continuing": "Carrying on the same task as `anchor` and `recent_prompts`: the next step of the same work.",
    "pivoting": "Starting a different task or goal from `anchor`: a change of direction.",
    "debugging": "Reporting that something is failing, wrong, or unexpected, and asking to diagnose or fix it.",
    "exploring": "Asking a question, reading, or investigating to understand something; no change is requested.",
    "wrapping_up": "Finishing the work: committing, opening a pull request, summarising, cleaning up, or ending the session.",
}


class StateTooLarge(Exception):
    """The state cannot be brought under the hard cap without destroying the prompt."""


class RubricError(Exception):
    """system_prompt.md no longer carries a rubric table this grader can parse."""


# --- text ------------------------------------------------------------------------------

_REMINDER_RE = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
_SKIP_PREFIXES = ("<command-name>", "<local-command-stdout>", "<local-command-caveat>")


def estimate_tokens(text: str) -> int:
    return math.ceil(len(text) / CHARS_PER_TOKEN)


def normalize_prompt(text: str) -> str:
    return _REMINDER_RE.sub("", text).strip()


def cap_text(text: str, cap: tuple[int, int]) -> tuple[str, bool]:
    head_t, tail_t = cap
    if estimate_tokens(text) <= head_t + tail_t:
        return text, False
    head_c = head_t * CHARS_PER_TOKEN
    tail_c = tail_t * CHARS_PER_TOKEN
    elided = len(text) - head_c - tail_c
    tail = text[len(text) - tail_c:] if tail_c else ""
    return f"{text[:head_c]}\n[... {elided} chars elided ...]\n{tail}", True


# --- transcript ------------------------------------------------------------------------


def _record_text(rec: dict) -> str | None:
    if rec.get("type") != "user":
        return None
    if rec.get("isMeta") or rec.get("isSidechain") or rec.get("isCompactSummary"):
        return None
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        blocks = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
        if not blocks:
            return None  # tool_result-only record
        text = "\n".join(blocks)
    else:
        return None
    text = normalize_prompt(text)
    if not text or text.startswith(_SKIP_PREFIXES):
        return None
    return text


def typed_prompts(transcript_text: str) -> list[str]:
    """Typed user prompts, in order. Skips meta, sidechain, compaction, tool-result-only
    and slash-command records; strips <system-reminder> blocks."""
    out: list[str] = []
    for line in transcript_text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue  # partial or foreign line
        if not isinstance(rec, dict):
            continue
        text = _record_text(rec)
        if text is not None:
            out.append(text)
    return out


_SYNTHETIC_MODEL = "<synthetic>"


def transcript_context(transcript_text: str | None) -> dict:
    """{"model", "tokens_used"} from the last assistant record (issue #47). tokens_used is
    input + cache read + cache creation of the last call, as jev.mjs parseTranscript
    computes it. "<synthetic>" records (API-error placeholders, zero usage) are skipped for
    both fields. Mirrors jev.mjs parseTranscript; test_jev_shadow.py pins the parity."""
    model: str | None = None
    tokens_used = 0
    for line in (transcript_text or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not isinstance(rec, dict) or rec.get("type") != "assistant":
            continue
        message = rec.get("message") or {}
        if not isinstance(message, dict):
            continue
        m = message.get("model")
        if m == _SYNTHETIC_MODEL:
            continue
        if isinstance(m, str) and m:
            model = m
        usage = message.get("usage")
        if isinstance(usage, dict):
            tokens_used = sum(
                int(usage.get(k) or 0)
                for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")
            )
    return {"model": model, "tokens_used": tokens_used}


# --- context window (issue #47) ----------------------------------------------------------
#
# Same resolution as plugin/lib/context_window.sh and jev.mjs resolveContextWindow, over the
# shared prefix table plugin/lib/context_windows.json: CONTEXTBUDDY_CONTEXT_WINDOW override >
# Claude Code's auto-compact window (CLAUDE_CODE_AUTO_COMPACT_WINDOW, else autoCompactWindow
# in ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json) > model table > 200000; then the evidence
# floor raises a limit below tokens_used to the next tier (past the last, to tokens_used).

_CONTEXT_WINDOWS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "context_windows.json")
_CONTEXT_WINDOWS_FALLBACK = {"default": 200000, "tiers": [200000, 1000000], "prefixes": []}


def _context_windows() -> dict:
    try:
        with open(_CONTEXT_WINDOWS_PATH, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return dict(_CONTEXT_WINDOWS_FALLBACK)


def parse_token_count(value) -> int | None:
    """500k / 500000 / 1m -> int; None when unparseable or zero."""
    if value is None:
        return None
    text = re.sub(r"[\s_,]", "", str(value)).lower()
    m = re.fullmatch(r"(\d+)([km]?)", text)
    if not m:
        return None
    n = int(m.group(1)) * {"k": 1000, "m": 1000000, "": 1}[m.group(2)]
    return n if n > 0 else None


def context_window_for_model(model: str | None, env: dict | None = None) -> int:
    table = _context_windows()
    env = os.environ if env is None else env
    window = int(table.get("default", 200000))
    if isinstance(model, str) and model:
        for row in table.get("prefixes", []):
            if model.startswith(row.get("prefix", "\0")):
                window = int(row.get("window", window))
                break
    if env.get(table.get("disable_1m_env", "CLAUDE_CODE_DISABLE_1M_CONTEXT")) in ("1", "true") and window > int(table.get("default", 200000)):
        window = int(table.get("default", 200000))
    return window


def _autocompact_window(env: dict, home: str) -> int | None:
    value = env.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW")
    if not value:
        path = os.path.join(env.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude"), "settings.json")
        try:
            with open(path, encoding="utf-8") as f:
                value = (json.load(f) or {}).get("autoCompactWindow")
        except (OSError, ValueError, AttributeError):
            value = None
    return parse_token_count(value)


def resolve_context_window(model: str | None, tokens_used: int, env: dict | None = None,
                           home: str | None = None) -> dict:
    """{"tokens_limit", "limit_source"}; limit_source is override | autocompact | model |
    observed | default."""
    env = os.environ if env is None else env
    home = os.path.expanduser("~") if home is None else home
    table = _context_windows()
    default = int(table.get("default", 200000))
    override = parse_token_count(env.get("CONTEXTBUDDY_CONTEXT_WINDOW"))
    compact = None if override else _autocompact_window(env, home)
    if override:
        limit, source = override, "override"
    elif compact:
        limit, source = compact, "autocompact"
    elif isinstance(model, str) and model:
        limit, source = context_window_for_model(model, env), "model"
    else:
        limit, source = default, "default"
    used = int(tokens_used or 0)
    if used > limit:
        limit = next((int(t) for t in table.get("tiers", []) if int(t) >= used), used)
        source = "observed"
    return {"tokens_limit": limit, "limit_source": source}


# --- state -----------------------------------------------------------------------------


def _halve(cap: tuple[int, int]) -> tuple[int, int] | None:
    head, tail = cap
    if head + tail <= MIN_CAP_TOKENS:
        return None
    return (max(head // 2, 1), tail // 2)


def build_state(
    transcript_text: str | None,
    latest_prompt: str,
    *,
    recent_n: int = RECENT_N,
    anchor_cap: tuple[int, int] = ANCHOR_CAP,
    latest_cap: tuple[int, int] = LATEST_CAP,
    recent_cap: tuple[int, int] = RECENT_CAP,
    hard_cap: int = STATE_TOKEN_HARD_CAP,
) -> tuple[dict, dict]:
    """Returns (state, meta). Raises StateTooLarge if the hard cap is unreachable."""
    latest = normalize_prompt(latest_prompt)
    prompts = typed_prompts(transcript_text) if transcript_text else []
    if prompts and prompts[-1] == latest:
        prompts = prompts[:-1]  # transcript already caught up with this prompt
    anchor_raw = prompts[0] if prompts else latest
    recents_raw = prompts[1:][-recent_n:] if len(prompts) > 1 else []

    reductions: list[str] = []
    recents = [cap_text(p, recent_cap) for p in recents_raw]
    while True:
        anchor, anchor_trunc = cap_text(anchor_raw, anchor_cap)
        prompt, latest_trunc = cap_text(latest, latest_cap)
        state = {"anchor": anchor, "recent_prompts": [t for t, _ in recents], "prompt": prompt}
        blob = json.dumps(state, ensure_ascii=False)
        tokens = estimate_tokens(blob)
        if tokens <= hard_cap:
            break
        if recents:
            recents.pop(0)
            reductions.append("drop_recent")
            continue
        smaller = _halve(latest_cap)
        if smaller is not None and smaller != latest_cap and latest_trunc or (smaller and estimate_tokens(latest) > sum(smaller)):
            latest_cap = smaller
            reductions.append("halve_latest")
            continue
        smaller = _halve(anchor_cap)
        if smaller is not None and estimate_tokens(anchor_raw) > sum(smaller):
            anchor_cap = smaller
            reductions.append("halve_anchor")
            continue
        raise StateTooLarge(f"state is {tokens} est. tokens, hard cap {hard_cap}")

    meta = {
        "tokens_est": tokens,
        "chars": len(blob),
        "anchor_truncated": anchor_trunc,
        "latest_truncated": latest_trunc,
        "recent_count": len(recents),
        "recent_truncated": sum(1 for _, t in recents if t),
        "reductions": reductions,
    }
    return state, meta


# --- questions -------------------------------------------------------------------------

_HEADING_RE = re.compile(r"^###\s+(\w+)\b")
_ROW_RE = re.compile(r"^\|\s*\d+-\d+\s*\|\s*(.*?)\s*\|\s*$")


def load_rubric_criteria(system_prompt_path: str) -> dict[str, list[str]]:
    """The Meaning column of each locked rubric table, verbatim, keyed by question id."""
    with open(system_prompt_path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    wanted = dict(RUBRIC_SECTIONS)
    out: dict[str, list[str]] = {}
    current: str | None = None
    for line in lines:
        m = _HEADING_RE.match(line)
        if m:
            current = wanted.get(m.group(1))
            if current is not None:
                out[current] = []
            continue
        if current is None:
            continue
        m = _ROW_RE.match(line)
        if m:
            out[current].append(m.group(1))
    for _, qid in RUBRIC_SECTIONS:
        if len(out.get(qid, [])) != 5:
            raise RubricError(f"rubric table for {qid} not found or not 5 rows in {system_prompt_path}")
    return out


def build_questions(criteria: dict[str, list[str]]) -> dict[str, dict]:
    """Plain-dict questions in the HTTP API shape; the SDK accepts these directly."""
    q: dict[str, dict] = {}
    for qid in ("specificity", "atomicity", "drift"):
        q[qid] = {"type": "score", "instructions": INSTRUCTIONS[qid], "criteria": list(criteria[qid])}
    q["intent"] = {"type": "choice", "instructions": INSTRUCTIONS["intent"], "criteria": dict(INTENT_OPTIONS)}
    return q


# --- Jev -------------------------------------------------------------------------------


def call_jev(state: dict, questions: dict, *, api_key: str, model: str = MODEL_ID,
             timeout_s: float = REQUEST_TIMEOUT_S) -> tuple[dict, int]:
    """One System One request. Returns (response in HTTP API shape, latency_ms).

    typesafe-sdk 0.7.0 exposes answers both as `r.answers[id]` (a typed union) and as the
    per-type views `r.scores[id]` / `r.choices[id]` / `r.nouls[id]`. ScoreAnswer keys
    `probabilities` and `legend` by int; this converts back to the wire's string keys.
    """
    from typesafe_sdk import RetryPolicy, TypeSafeClient  # lazy: tests need no SDK

    t0 = time.monotonic()
    with TypeSafeClient(api_key=api_key, model=model, timeout=timeout_s,
                        retry=RetryPolicy(max_retries=1)) as client:
        r = client.system_one(state, questions, model=model)
    latency_ms = int(round((time.monotonic() - t0) * 1000))

    answers: dict[str, dict] = {}
    for qid, a in r.answers.items():
        if a.type == "score":
            answers[qid] = {
                "type": "score",
                "score": a.score,
                "confidence": a.confidence,
                "probabilities": {str(k): v for k, v in a.probabilities.items()},
                "legend": {str(k): v for k, v in a.legend.items()},
            }
        elif a.type == "choice":
            answers[qid] = {
                "type": "choice",
                "choice": a.choice,
                "confidence": a.confidence,
                "probabilities": dict(a.probabilities),
            }
    usage = {"input_tokens": r.usage.input_tokens, "output_tokens": r.usage.output_tokens}
    return {"model": r.model, "answers": answers, "usage": usage}, latency_ms


# --- row -------------------------------------------------------------------------------


def _argmax(probs: dict[str, float]) -> str:
    # ties resolve to the lowest level / first option, deterministically
    return max(probs, key=lambda k: (probs[k], -list(probs).index(k)))


def haiku_summary(grade: dict) -> dict:
    scores = grade.get("scores") or {}
    out = {dim: (scores.get(dim) or {}).get("value") for dim in ("confidence", "atomicity", "drift", "pollution")}
    out["dominant_signal"] = grade.get("dominant_signal")
    return out


def wait_for_haiku(turn_file: str, *, timeout_s: float = HAIKU_WAIT_S, poll_s: float = 0.5) -> dict | None:
    """Poll for the Haiku turn file (written atomically by the hook); None on timeout."""
    deadline = time.monotonic() + timeout_s
    while True:
        if os.path.isfile(turn_file):
            try:
                with open(turn_file, encoding="utf-8") as f:
                    return haiku_summary(json.load(f))
            except (OSError, ValueError):
                pass  # not readable yet; keep polling until the deadline
        if time.monotonic() >= deadline:
            return None
        time.sleep(poll_s)


def build_row(*, turn: int, timestamp: str, session_id: str | None, prompt_id: str | None,
              project_hash: str, model_requested: str, response: dict, latency_ms: int,
              state_meta: dict, haiku: dict | None, context: dict | None = None) -> dict:
    questions: dict[str, dict] = {}
    for qid, a in response.get("answers", {}).items():
        if a.get("type") == "score":
            probs = {str(k): float(v) for k, v in a["probabilities"].items()}
            level_key = _argmax(probs)
            legend = a.get("legend") or {}
            questions[qid] = {
                "type": "score",
                "level": int(level_key),
                "level_text": legend.get(level_key),
                "confidence": a.get("confidence"),
                "probabilities": probs,
                "weighted_mean": a.get("score"),  # secondary; do not switch on it
            }
        elif a.get("type") == "choice":
            probs = {str(k): float(v) for k, v in a["probabilities"].items()}
            questions[qid] = {
                "type": "choice",
                "choice": a.get("choice") or _argmax(probs),
                "confidence": a.get("confidence"),
                "probabilities": probs,
            }
    usage = response.get("usage") or {}
    return {
        "schema_version": 1,
        "kind": "jev_shadow",
        "request": "A",
        "hook": "UserPromptSubmit",
        "phase": "pre",
        "turn": int(turn),
        "timestamp": timestamp,
        "session_id": session_id,
        "prompt_id": prompt_id,
        "project_hash": project_hash,
        "model": {"requested": model_requested, "answered": response.get("model")},
        "latency_ms": int(latency_ms),
        "state": {
            "tokens_est": state_meta["tokens_est"],
            "chars": state_meta["chars"],
            "input_tokens": usage.get("input_tokens"),
            "anchor_truncated": state_meta["anchor_truncated"],
            "latest_truncated": state_meta["latest_truncated"],
            "recent_count": state_meta["recent_count"],
            "reductions": list(state_meta.get("reductions", [])),
        },
        "questions": questions,
        "haiku": haiku,
        # Issue #47: session model and resolved window, for calibration against the Haiku grade.
        "context_window": context,
    }


def write_row(session_dir: str, turn: int, row: dict) -> None:
    turns_dir = os.path.join(session_dir, "turns")
    os.makedirs(turns_dir, exist_ok=True)
    line = json.dumps(row, ensure_ascii=False)
    target = os.path.join(turns_dir, f"{int(turn):03d}-pre.jev.json")
    fd, tmp = tempfile.mkstemp(prefix=".jev.", dir=turns_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(line + "\n")
        os.chmod(tmp, 0o644)  # mkstemp gives 0600; match the Haiku files
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    with open(os.path.join(session_dir, "jev.jsonl"), "a", encoding="utf-8") as f:
        f.write(line + "\n")


# --- entry point -----------------------------------------------------------------------


def _log(msg: str) -> None:
    sys.stderr.write(f"contextbuddy jev: {msg}\n")
    sys.stderr.flush()


def _parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="ContextBuddy Jev shadow grader (Request A)")
    p.add_argument("--payload", required=True, help="file holding the UserPromptSubmit hook JSON")
    p.add_argument("--turn", required=True, type=int)
    p.add_argument("--timestamp", required=True)
    p.add_argument("--project-hash", required=True)
    p.add_argument("--session-dir", required=True)
    p.add_argument("--system-prompt", required=True)
    p.add_argument("--model", default=MODEL_ID)
    p.add_argument("--haiku-wait", type=float, default=HAIKU_WAIT_S)
    p.add_argument("--keep-payload", action="store_true", help="do not delete the payload file")
    return p.parse_args(argv)


def run(args: argparse.Namespace) -> int:
    api_key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if not api_key:
        _log(f"turn {args.turn}: skipped, TYPESAFE_API_KEY unset")
        return 0
    with open(args.payload, encoding="utf-8") as f:
        payload = json.load(f)
    prompt = payload.get("prompt") or ""
    if not normalize_prompt(prompt):
        _log(f"turn {args.turn}: skipped, empty prompt")
        return 0
    transcript_text = None
    tp = payload.get("transcript_path")
    if tp and os.path.isfile(tp):
        with open(tp, encoding="utf-8", errors="replace") as f:
            transcript_text = f.read()

    state, meta = build_state(transcript_text, prompt)
    ctx = transcript_context(transcript_text)
    ctx.update(resolve_context_window(ctx["model"], ctx["tokens_used"]))
    questions = build_questions(load_rubric_criteria(args.system_prompt))
    response, latency_ms = call_jev(state, questions, api_key=api_key, model=args.model)

    haiku_path = os.path.join(args.session_dir, "turns", f"{args.turn:03d}-pre.json")
    haiku = wait_for_haiku(haiku_path, timeout_s=args.haiku_wait)
    row = build_row(
        turn=args.turn, timestamp=args.timestamp, session_id=payload.get("session_id"),
        prompt_id=payload.get("prompt_id"), project_hash=args.project_hash,
        model_requested=args.model, response=response, latency_ms=latency_ms,
        state_meta=meta, haiku=haiku, context=ctx,
    )
    write_row(args.session_dir, args.turn, row)
    _log(
        f"turn {args.turn}: ok latency_ms={latency_ms} tokens_est={meta['tokens_est']} "
        f"input_tokens={response.get('usage', {}).get('input_tokens')} haiku={'yes' if haiku else 'no'}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        return run(args)
    except Exception as e:  # never propagate: this process is fire-and-forget
        _log(f"turn {args.turn}: skipped, {type(e).__name__}: {e}")
        return 0
    finally:
        if not args.keep_payload:
            try:
                os.unlink(args.payload)
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
