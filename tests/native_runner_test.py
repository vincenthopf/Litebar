import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "validate_native.py"
SPEC = importlib.util.spec_from_file_location("validate_native", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class NativeRunnerTests(unittest.TestCase):
    def run_suite(self, suite, result=None, error=None):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(RUNNER.subprocess, "run", return_value=result, side_effect=error) as run:
                report = RUNNER.run_suite(Path("/fixture/Litebar"), Path(directory), suite, 3)
                call = run.call_args
            return report, call

    def test_full_suite_requires_live_input_and_preserves_failure(self):
        report, call = self.run_suite("full", subprocess.CompletedProcess([], 1))
        self.assertEqual(call.args[0], ["/fixture/Litebar", "--self-test"])
        self.assertEqual(call.kwargs["timeout"], 3)
        self.assertTrue(report["live_input_required"])
        self.assertEqual(report["return_code"], 1)
        self.assertFalse(report["timed_out"])

    def test_ui_suite_is_explicitly_limited(self):
        report, call = self.run_suite("ui", subprocess.CompletedProcess([], 0))
        self.assertEqual(call.args[0], ["/fixture/Litebar", "--self-test-ui"])
        self.assertFalse(report["live_input_required"])
        self.assertEqual(report["return_code"], 0)

    def test_hung_suite_is_a_failure(self):
        report, _ = self.run_suite("full", error=subprocess.TimeoutExpired("Litebar", 3))
        self.assertEqual(report["return_code"], 124)
        self.assertTrue(report["timed_out"])


if __name__ == "__main__":
    unittest.main()
