"""Tests for plugin/grader/jev_shadow.py — the Request A shadow grader.

No network. The Jev answer set comes from fixtures/jev_response_request_a.json (API
shape); the transcript from fixtures/transcript_request_a.jsonl. Run with:
    python3 -m unittest discover -s Tests/plugin -p 'test_*.py'
"""

import json
import os
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


def _row(haiku=None):
    _, meta = js.build_state(TRANSCRIPT, LATEST)
    return js.build_row(
        turn=14, timestamp="2026-09-18T12:00:00Z", session_id="sess", prompt_id="pid",
        project_hash="abc123def456", model_requested=js.MODEL_ID,
        response=RESPONSE, latency_ms=412, state_meta=meta, haiku=haiku,
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
