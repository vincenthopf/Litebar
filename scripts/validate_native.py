import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys


def run_suite(executable: Path, output: Path, suite: str, timeout: float) -> dict:
    argument = "--self-test-ui" if suite == "ui" else "--self-test"
    environment = dict(os.environ, LITEBAR_VALIDATION_DIR=str(output))
    log = output / f"{suite}.log"
    with log.open("x") as stream:
        try:
            result = subprocess.run(
                [str(executable), argument],
                stdout=stream,
                stderr=subprocess.STDOUT,
                env=environment,
                timeout=timeout,
                check=False,
            )
            return_code = result.returncode
            timed_out = False
        except subprocess.TimeoutExpired:
            return_code = 124
            timed_out = True
    return {
        "suite": suite,
        "return_code": return_code,
        "timed_out": timed_out,
        "live_input_required": suite == "full",
        "log": str(log),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run isolated native suites with explicit coverage and deadlines.")
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--suite", choices=["all", "ui", "full"], default="all")
    parser.add_argument("--timeout", type=float, default=90)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 600:
        parser.error("--timeout must be between 1 and 600 seconds")
    app = args.app.resolve()
    executable = app / "Contents/MacOS/Litebar"
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "com.vincenthopf.Litebar.Validation":
        parser.error("build a dedicated app with LITEBAR_VALIDATION=1")
    if not executable.is_file():
        parser.error("the validation executable is missing")
    running = subprocess.run(["pgrep", "-x", "Ice|Litebar"], capture_output=True, text=True, check=False)
    if running.returncode == 0:
        parser.error("quit Ice and other Litebar processes before running menu-bar tests")
    if running.returncode != 1:
        raise RuntimeError("Could not check for competing menu-bar managers: " + running.stderr)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    suites = ["ui", "full"] if args.suite == "all" else [args.suite]
    results = [run_suite(executable, output, suite, args.timeout) for suite in suites]
    report = {
        "app": str(app),
        "results": results,
        "passed": all(result["return_code"] == 0 for result in results),
        "full_coverage_requested": "full" in suites,
    }
    encoded = json.dumps(report, indent=2) + "\n"
    (output / "results.json").write_text(encoded)
    print(encoded, end="")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
