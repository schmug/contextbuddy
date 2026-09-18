import unittest


class GateProbe(unittest.TestCase):
    def test_deliberate_failure(self):
        self.fail("scratch PR: deliberate failure to prove the main gate blocks")
