"""Parity test across the two transcript parsers (issue #31).

plugin/grader/jev.mjs parseTranscript (the typesafe grader; the reference) and
plugin/grader/jev_shadow.py typed_prompts (the Jev shadow grader) each read the hook's
transcript with their own code. Every gap between them has shipped as a bug (#25, #27,
#29), so this file feeds fixtures/transcript_window.jsonl to both and asserts the full
ordered typed-prompt list and the first prompt are identical. When they disagree, align
the Python side to Node. Issue #9 collapses the parsers into one; this is the guard until
then.

No network, no keys. Node is required for the comparison; the class skips without it, as
the node-backed tests in test_jev_shadow.py do. Run with:
    python3 -m unittest discover -s Tests/plugin -p 'test_*.py'
"""

import json
import os
import shutil
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "plugin", "grader"))

import jev_shadow as js  # noqa: E402

FIXTURE = os.path.join(HERE, "fixtures", "transcript_window.jsonl")
JEV_MJS = os.path.join(REPO, "plugin", "grader", "jev.mjs")

# parseTranscript keeps only the last `windowTurns` prompts (default 3). typed_prompts
# keeps every prompt, so the Node side is asked for far more than the fixture holds.
WINDOW_TURNS = 1000

# The module path travels in JEV_MJS, never in argv[1]: jev.mjs runs its CLI (and blocks
# on stdin) when argv[1] is its own path.
NODE_SCRIPT = (
    "import {readFileSync} from 'node:fs'; const g = await import(process.env.JEV_MJS);"
    " const w = g.parseTranscript(readFileSync(process.argv[1], 'utf8'), {windowTurns: Number(process.argv[2])});"
    " console.log(JSON.stringify({prompts: w.prompts, firstPrompt: w.firstPrompt}))"
)


def _node_parse(fixture_path, window_turns):
    """parseTranscript(fixture, {windowTurns}) -> {"prompts", "firstPrompt"} through node."""
    env = dict(os.environ, JEV_MJS=JEV_MJS)
    out = subprocess.run(
        ["node", "--input-type=module", "-e", NODE_SCRIPT, "--", fixture_path, str(window_turns)],
        capture_output=True, text=True, check=True, env=env, stdin=subprocess.DEVNULL, timeout=30,
    ).stdout
    return json.loads(out)


def _python_parse(fixture_path):
    """typed_prompts(fixture) -> {"prompts", "firstPrompt"}, shaped like the Node result.
    firstPrompt is prompts[0] or "" in both graders."""
    with open(fixture_path, encoding="utf-8") as f:
        prompts = js.typed_prompts(f.read())
    return {"prompts": prompts, "firstPrompt": prompts[0] if prompts else ""}


@unittest.skipUnless(shutil.which("node"), "node not installed")
class ParserParityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.node = _node_parse(FIXTURE, WINDOW_TURNS)
        cls.python = _python_parse(FIXTURE)

    def test_typed_prompt_lists_are_identical(self):
        # The full ordered list, not a count: a record that one parser skips and the other
        # keeps (a slash command, a reminder-only record, a tool result) shows up here.
        self.assertTrue(self.node["prompts"], "fixture produced no typed prompts; parity would be vacuous")
        self.assertEqual(self.python["prompts"], self.node["prompts"])

    def test_first_prompts_are_identical(self):
        # The anchor fallback (#27) in both graders: the first typed prompt after stripping
        # <system-reminder> blocks and skipping slash-command records.
        self.assertEqual(self.python["firstPrompt"], self.node["firstPrompt"])


if __name__ == "__main__":
    unittest.main()
