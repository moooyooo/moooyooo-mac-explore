"""The verification gate must reject an exit-0 partial Swift Testing log."""
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/check-test-completion.py"
completed = runpy.run_path(str(SCRIPT))["completed"]


class CompletionGateTests(unittest.TestCase):
    def test_accepts_complete_singular_and_plural_totals(self):
        self.assertTrue(completed("✔ Test run with 1 test passed after 0.041 seconds.\n"))
        self.assertTrue(completed("✔ Test run with 86 tests in 4 suites passed after 7.966 seconds.\n"))

    def test_rejects_individual_success_without_final_total(self):
        self.assertFalse(completed("✔ Test one() passed after 0.3 seconds.\n◇ Test two() started.\n"))
        self.assertFalse(completed("✘ Test run with 2 tests failed after 1.0 seconds with 1 issue.\n"))

    def test_cli_fails_a_partial_log_and_accepts_a_completed_log(self):
        with tempfile.TemporaryDirectory(prefix="MacExplore-Test-Gate-") as directory:
            log = Path(directory) / "test.log"
            log.write_text("✔ Test one() passed after 0.3 seconds.\n")
            partial = subprocess.run([sys.executable, str(SCRIPT), str(log)], capture_output=True)
            self.assertNotEqual(partial.returncode, 0)
            self.assertIn(b"Incomplete Swift Testing run", partial.stderr)
            log.write_text("✔ Test run with 1 test passed after 0.3 seconds.\n")
            complete = subprocess.run([sys.executable, str(SCRIPT), str(log)], capture_output=True)
            self.assertEqual(complete.returncode, 0)
