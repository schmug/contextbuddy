"""Tests for plugin/grader/jev_shadow.py — the Request A shadow grader.

No network. The Jev answer set comes from fixtures/jev_response_request_a.json (API
shape); the transcript from fixtures/transcript_request_a.jsonl. Run with:
    python3 -m unittest discover -s Tests/plugin -p 'test_*.py'
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "plugin", "grader"))

import jev_shadow as js  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")
SYSTEM_PROMPT = os.path.join(REPO, "plugin", "grader", "system_prompt.md")


def _read(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return f.read()


TRANSCRIPT = _read("transcript_request_a.jsonl")
RESPONSE = json.loads(_read("jev_response_request_a.json"))
LATEST = "Now add a login test for the expired-token path"

EXPECTED_PROMPTS = [
    "Refactor the auth module to use JWT instead of session cookies. Use jose. Done when tests/auth pass.",
    "Update the auth middleware to read the Authorization header",
    "Now migrate the login route",
    "Run the auth tests",
    "still failing. the expired-token test in tests/auth/jwt.test.ts is red again, fix it",
    "Fix the expired-token bug and while you're in there refactor the validator and add tests for the refresh path",
]


class TypedPromptsTest(unittest.TestCase):
    def test_skips_meta_sidechain_tool_results_commands_and_compaction(self):
        self.assertEqual(js.typed_prompts(TRANSCRIPT), EXPECTED_PROMPTS)

    def test_first_prompt_has_system_reminder_stripped(self):
        first = js.typed_prompts(TRANSCRIPT)[0]
        self.assertNotIn("<system-reminder>", first)
        self.assertTrue(first.startswith("Refactor the auth module"))


def _node(script, *args):
    """Run an ES-module snippet against plugin/grader/jev.mjs. The module path travels in
    JEV_MJS, never in argv[1]: jev.mjs runs its CLI (and blocks on stdin) when argv[1] is
    its own path."""
    env = dict(os.environ, JEV_MJS=os.path.join(REPO, "plugin", "grader", "jev.mjs"))
    return subprocess.run(
        ["node", "--input-type=module", "-e", script, "--", *args],
        capture_output=True, text=True, check=True, env=env, stdin=subprocess.DEVNULL, timeout=30,
    ).stdout


class TranscriptContextTest(unittest.TestCase):
    """Issue #47: the session model and context size come from the transcript's assistant
    records; "<synthetic>" records (API-error placeholders, zero usage) are skipped."""

    def test_model_and_tokens_from_last_real_assistant_record(self):
        self.assertEqual(js.transcript_context(TRANSCRIPT), {"model": "claude-fable-5-1", "tokens_used": 60200})

    def test_synthetic_records_are_skipped(self):
        synth = json.dumps({"type": "assistant", "message": {"model": "<synthetic>", "usage": {"input_tokens": 0}}})
        self.assertEqual(js.transcript_context(synth), {"model": None, "tokens_used": 0})
        haiku = json.dumps({"type": "assistant", "message": {"model": "claude-haiku-4-5-20251001", "usage": {"input_tokens": 5}}})
        self.assertEqual(js.transcript_context(haiku + "\n" + synth), {"model": "claude-haiku-4-5-20251001", "tokens_used": 5})

    def test_no_transcript(self):
        self.assertEqual(js.transcript_context(None), {"model": None, "tokens_used": 0})
        self.assertEqual(js.transcript_context("{not json}\n"), {"model": None, "tokens_used": 0})

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_parity_with_jev_mjs_parse_transcript(self):
        # Same fixture through both parsers (#31 parity): model and tokens_used must agree.
        script = (
            "import {readFileSync} from 'node:fs'; const g = await import(process.env.JEV_MJS);"
            " const w = g.parseTranscript(readFileSync(process.argv[1], 'utf8'));"
            " console.log(JSON.stringify({model: w.model, tokens_used: w.tokensUsed}))"
        )
        out = _node(script, os.path.join(FIXTURES, "transcript_request_a.jsonl"))
        self.assertEqual(json.loads(out), js.transcript_context(TRANSCRIPT))


class ContextWindowTest(unittest.TestCase):
    """Issue #47: plugin/lib/context_windows.json, read by the hooks, jev.mjs and this file."""

    def test_prefix_table(self):
        for m in ("claude-fable-5-1", "claude-mythos-5-1", "claude-sonnet-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7-20260301"):
            self.assertEqual(js.context_window_for_model(m, env={}), 1000000, m)
        for m in ("claude-haiku-4-5-20251001", "claude-sonnet-4-6", "claude-opus-4-6", "claude-sonnet-4-5-20250929", "claude-nova-9", "", None):
            self.assertEqual(js.context_window_for_model(m, env={}), 200000, str(m))

    def test_disable_1m_env_caps_native_1m_models(self):
        self.assertEqual(js.context_window_for_model("claude-fable-5-1", env={"CLAUDE_CODE_DISABLE_1M_CONTEXT": "1"}), 200000)

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_table_parity_with_jev_mjs(self):
        ids = ["claude-fable-5-1", "claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-4-6", "claude-nova-9"]
        script = (
            "const g = await import(process.env.JEV_MJS);"
            " console.log(JSON.stringify(process.argv.slice(1).map(m => g.contextWindowForModel(m, {}))))"
        )
        self.assertEqual(json.loads(_node(script, *ids)), [js.context_window_for_model(m, env={}) for m in ids])

    def test_parse_token_count(self):
        self.assertEqual(js.parse_token_count("500k"), 500000)
        self.assertEqual(js.parse_token_count("500K"), 500000)
        self.assertEqual(js.parse_token_count("1m"), 1000000)
        self.assertEqual(js.parse_token_count(400000), 400000)
        self.assertEqual(js.parse_token_count("300000"), 300000)
        for bad in ("lots", "", None, "0", 0):
            self.assertIsNone(js.parse_token_count(bad), repr(bad))

    def test_resolution_order_then_floor(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = os.path.join(d, "cfg")
            os.makedirs(cfg)
            with open(os.path.join(cfg, "settings.json"), "w", encoding="utf-8") as f:
                json.dump({"autoCompactWindow": "500k"}, f)
            r = lambda **kw: js.resolve_context_window(**{"model": "claude-fable-5-1", "tokens_used": 176474, "env": {}, "home": d, **kw})  # noqa: E731
            self.assertEqual(r(), {"tokens_limit": 1000000, "limit_source": "model"})
            self.assertEqual(r(model="claude-haiku-4-5-20251001"), {"tokens_limit": 200000, "limit_source": "model"})
            self.assertEqual(r(model=None), {"tokens_limit": 200000, "limit_source": "default"})
            self.assertEqual(r(env={"CONTEXTBUDDY_CONTEXT_WINDOW": "300000"}), {"tokens_limit": 300000, "limit_source": "override"})
            self.assertEqual(r(env={"CONTEXTBUDDY_CONTEXT_WINDOW": "300k", "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "500k"}), {"tokens_limit": 300000, "limit_source": "override"})
            self.assertEqual(r(env={"CLAUDE_CODE_AUTO_COMPACT_WINDOW": "500k"}), {"tokens_limit": 500000, "limit_source": "autocompact"})
            self.assertEqual(r(env={"CLAUDE_CONFIG_DIR": cfg}), {"tokens_limit": 500000, "limit_source": "autocompact"})
            self.assertEqual(r(env={"CONTEXTBUDDY_CONTEXT_WINDOW": "lots"}), {"tokens_limit": 1000000, "limit_source": "model"})
            # evidence floor: never a limit below tokens_used
            self.assertEqual(r(model="claude-haiku-4-5-20251001", tokens_used=250065), {"tokens_limit": 1000000, "limit_source": "observed"})
            self.assertEqual(r(tokens_used=1200000), {"tokens_limit": 1200000, "limit_source": "observed"})
            self.assertEqual(r(model="claude-haiku-4-5-20251001", tokens_used=200000), {"tokens_limit": 200000, "limit_source": "model"})


class StateBuilderTest(unittest.TestCase):
    def test_anchor_is_first_typed_prompt(self):
        state, _ = js.build_state(TRANSCRIPT, LATEST)
        self.assertEqual(state["anchor"], EXPECTED_PROMPTS[0])

    def test_recent_is_last_three_before_latest_oldest_first(self):
        state, meta = js.build_state(TRANSCRIPT, LATEST)
        self.assertEqual(state["recent_prompts"], EXPECTED_PROMPTS[3:6])
        self.assertEqual(meta["recent_count"], 3)

    def test_latest_comes_from_payload(self):
        state, _ = js.build_state(TRANSCRIPT, LATEST)
        self.assertEqual(state["prompt"], LATEST)

    def test_latest_deduped_when_transcript_already_has_it(self):
        lagged = TRANSCRIPT + json.dumps(
            {"type": "user", "isSidechain": False, "uuid": "u7", "message": {"role": "user", "content": LATEST}}
        ) + "\n"
        state, _ = js.build_state(lagged, LATEST)
        self.assertEqual(state["recent_prompts"], EXPECTED_PROMPTS[3:6])
        self.assertEqual(state["prompt"], LATEST)

    def test_turn_one_anchor_equals_latest(self):
        state, meta = js.build_state(None, LATEST)
        self.assertEqual(state["anchor"], LATEST)
        self.assertEqual(state["recent_prompts"], [])
        self.assertEqual(meta["recent_count"], 0)

    def test_state_has_no_tool_results_or_assistant_text(self):
        state, _ = js.build_state(TRANSCRIPT, LATEST)
        blob = json.dumps(state)
        self.assertNotIn("validateToken", blob)
        self.assertNotIn("Fixed the expiry check", blob)
        self.assertNotIn("FAIL tests/auth", blob)

    def test_anchor_capped_head_plus_tail_with_marker(self):
        big = "H" * 20000 + "M" * 20000 + "T" * 20000
        lines = json.dumps({"type": "user", "message": {"role": "user", "content": big}}) + "\n"
        state, meta = js.build_state(lines, LATEST)
        anchor = state["anchor"]
        self.assertTrue(meta["anchor_truncated"])
        self.assertIn("chars elided", anchor)
        self.assertTrue(anchor.startswith("HHHH"))
        self.assertTrue(anchor.endswith("TTTT"))
        head, tail = js.ANCHOR_CAP
        self.assertLessEqual(js.estimate_tokens(anchor), head + tail + js.MARKER_ALLOWANCE)

    def test_state_estimate_is_under_hard_cap_for_fixture(self):
        _, meta = js.build_state(TRANSCRIPT, LATEST)
        self.assertLess(meta["tokens_est"], js.STATE_TOKEN_HARD_CAP)

    def test_hard_cap_drops_recents_before_shrinking_latest(self):
        recents = [f"recent prompt {i} " + ("r" * 900) for i in range(3)]
        lines = "".join(
            json.dumps({"type": "user", "message": {"role": "user", "content": p}}) + "\n"
            for p in ["anchor " + "a" * 300] + recents
        )
        latest = "latest " + "l" * 1200
        state, meta = js.build_state(lines, latest, hard_cap=700)
        self.assertLessEqual(meta["tokens_est"], 700)
        self.assertEqual(meta["reductions"][0], "drop_recent")
        self.assertLess(len(state["recent_prompts"]), 3)

    def test_hard_cap_unreachable_raises(self):
        lines = json.dumps({"type": "user", "message": {"role": "user", "content": "a" * 3000}}) + "\n"
        with self.assertRaises(js.StateTooLarge):
            js.build_state(lines, "l" * 3000, hard_cap=5)


class TokenEstimateTest(unittest.TestCase):
    def test_estimate_overcounts_at_three_chars_per_token(self):
        self.assertEqual(js.estimate_tokens(""), 0)
        self.assertEqual(js.estimate_tokens("abc"), 1)
        self.assertEqual(js.estimate_tokens("abcd"), 2)


class RubricTest(unittest.TestCase):
    def test_criteria_are_the_locked_rubric_rows_verbatim(self):
        crit = js.load_rubric_criteria(SYSTEM_PROMPT)
        self.assertEqual(crit["specificity"], [
            "Goal itself is ambiguous. Multiple reasonable interpretations exist.",
            "Goal stated but acceptance criteria absent. \"Done\" is undefined.",
            "Goal + implicit acceptance, but scope and constraints unstated.",
            "Goal + acceptance + scope explicit. Constraints implied or partially stated.",
            "Goal + acceptance + scope + constraints all explicit. No reasonable misinterpretation possible.",
        ])
        self.assertEqual(crit["atomicity"], [
            "Multiple decisions AND multiple actions mixed together.",
            "Mixed: requires a decision THEN an action based on the decision.",
            "Two related actions or two related decisions bundled.",
            "One primary thing with one minor subordinate task.",
            "One decision OR one action, with a clear boundary.",
        ])
        self.assertEqual(crit["drift"], [
            "Tightly aligned with anchor goal. No scope creep.",
            "Aligned with goal, minor adjacent territory.",
            "Adjacent but defensible — same problem space, different facet.",
            "Clear scope expansion or partial out_of_scope encroachment.",
            "Working on something the anchor explicitly excludes, or unrelated to anchor goal.",
        ])

    def test_questions_have_three_scores_and_intent_choice(self):
        q = js.build_questions(js.load_rubric_criteria(SYSTEM_PROMPT))
        self.assertEqual(set(q), {"specificity", "atomicity", "drift", "intent"})
        for qid in ("specificity", "atomicity", "drift"):
            self.assertEqual(q[qid]["type"], "score")
            self.assertEqual(len(q[qid]["criteria"]), 5)
        self.assertEqual(q["intent"]["type"], "choice")
        self.assertEqual(list(q["intent"]["criteria"]), ["continuing", "pivoting", "debugging", "exploring", "wrapping_up"])

    def test_missing_rubric_section_raises(self):
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
            f.write("# nothing here\n")
        try:
            with self.assertRaises(js.RubricError):
                js.load_rubric_criteria(f.name)
        finally:
            os.unlink(f.name)


HAIKU_TURN = {
    "schema_version": 1, "phase": "pre", "turn": 14,
    "scores": {
        "confidence": {"value": 6, "rationale": "r"},
        "atomicity": {"value": 3, "rationale": "r"},
        "drift": {"value": 2, "rationale": "r"},
        "pollution": {"value": 4, "rationale": "r"},
    },
    "dominant_signal": "atomicity",
}


CONTEXT = {"model": "claude-fable-5-1", "tokens_used": 60200, "tokens_limit": 1000000, "limit_source": "model"}


def _row(haiku=None, context=CONTEXT):
    _, meta = js.build_state(TRANSCRIPT, LATEST)
    return js.build_row(
        turn=14, timestamp="2026-09-18T12:00:00Z", session_id="sess", prompt_id="pid",
        project_hash="abc123def456", model_requested=js.MODEL_ID,
        response=RESPONSE, latency_ms=412, state_meta=meta, haiku=haiku, context=context,
    )


class RowSchemaTest(unittest.TestCase):
    def test_row_carries_required_fields(self):
        row = _row()
        for key in ("schema_version", "kind", "request", "hook", "phase", "turn", "timestamp",
                    "session_id", "prompt_id", "project_hash", "model", "latency_ms", "state",
                    "questions", "haiku"):
            self.assertIn(key, row)
        self.assertEqual(row["kind"], "jev_shadow")
        self.assertEqual(row["request"], "A")
        self.assertEqual(row["hook"], "UserPromptSubmit")
        self.assertEqual(row["phase"], "pre")
        self.assertEqual(row["turn"], 14)
        self.assertEqual(row["model"], {"requested": "jev-1.13.0", "answered": "jev-1.13.0"})
        self.assertIsInstance(row["latency_ms"], int)
        self.assertGreaterEqual(row["latency_ms"], 0)

    def test_score_level_is_argmax_not_weighted_mean(self):
        q = _row()["questions"]
        self.assertEqual(q["specificity"]["level"], 2)
        self.assertEqual(q["atomicity"]["level"], 1)
        self.assertEqual(q["drift"]["level"], 0)
        self.assertEqual(q["specificity"]["probabilities"], RESPONSE["answers"]["specificity"]["probabilities"])
        self.assertEqual(q["specificity"]["confidence"], 0.58)
        self.assertEqual(q["specificity"]["weighted_mean"], 2.35)
        self.assertEqual(q["specificity"]["level_text"], "l2")

    def test_choice_carries_choice_confidence_probabilities(self):
        intent = _row()["questions"]["intent"]
        self.assertEqual(intent["type"], "choice")
        self.assertEqual(intent["choice"], "debugging")
        self.assertEqual(intent["confidence"], 0.62)
        self.assertEqual(set(intent["probabilities"]), {"continuing", "pivoting", "debugging", "exploring", "wrapping_up"})

    def test_state_block_carries_token_counts(self):
        st = _row()["state"]
        self.assertIsInstance(st["tokens_est"], int)
        self.assertEqual(st["input_tokens"], 1412)
        self.assertEqual(st["recent_count"], 3)
        self.assertIn("anchor_truncated", st)
        self.assertIn("latest_truncated", st)

    def test_haiku_null_when_absent(self):
        self.assertIsNone(_row(haiku=None)["haiku"])

    def test_row_carries_context_window(self):
        # Issue #47: the session model and the resolved window ride along for calibration.
        self.assertEqual(_row()["context_window"], CONTEXT)
        self.assertIsNone(_row(context=None)["context_window"])

    def test_haiku_scores_copied_when_present(self):
        row = _row(haiku=js.haiku_summary(HAIKU_TURN))
        self.assertEqual(row["haiku"], {
            "confidence": 6, "atomicity": 3, "drift": 2, "pollution": 4, "dominant_signal": "atomicity",
        })

    def test_row_is_json_serialisable_single_line(self):
        line = json.dumps(_row())
        self.assertNotIn("\n", line)


class HaikuWaitTest(unittest.TestCase):
    def test_wait_returns_none_on_timeout(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(js.wait_for_haiku(os.path.join(d, "014-pre.json"), timeout_s=0.2, poll_s=0.05))

    def test_wait_reads_file_once_present(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "014-pre.json")
            with open(p, "w", encoding="utf-8") as f:
                json.dump(HAIKU_TURN, f)
            self.assertEqual(js.wait_for_haiku(p, timeout_s=0.2, poll_s=0.05)["atomicity"], 3)


class WriteRowTest(unittest.TestCase):
    def test_writes_turn_file_and_appends_jsonl(self):
        with tempfile.TemporaryDirectory() as d:
            row = _row()
            js.write_row(d, 14, row)
            js.write_row(d, 15, dict(row, turn=15))
            with open(os.path.join(d, "turns", "014-pre.jev.json"), encoding="utf-8") as f:
                self.assertEqual(json.load(f)["turn"], 14)
            with open(os.path.join(d, "jev.jsonl"), encoding="utf-8") as f:
                lines = [json.loads(line) for line in f if line.strip()]
            self.assertEqual([r["turn"] for r in lines], [14, 15])
            self.assertFalse([n for n in os.listdir(os.path.join(d, "turns")) if n.startswith(".")])

    def test_turn_file_is_world_readable_like_haiku_files(self):
        with tempfile.TemporaryDirectory() as d:
            js.write_row(d, 14, _row())
            mode = os.stat(os.path.join(d, "turns", "014-pre.jev.json")).st_mode & 0o777
            self.assertEqual(mode & 0o644, 0o644)


if __name__ == "__main__":
    unittest.main()
