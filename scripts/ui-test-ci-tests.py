#!/usr/bin/env python3
"""Regressions for CI's UI-test run: python3 scripts/ui-test-ci-tests.py (mise run test:ui:runner).

Runs scripts/ui-test-ci.sh with fake `mise` and `xcrun` commands, scripts/ui-test-results.py on
result trees shaped like xcresulttool 0.5.0's (Xcode 27.2), and test:ui's script from mise.toml
with a fake `xcodebuild`, in owned temporary directories. No Xcode, simulator or build is needed;
included in mise lint:repo on Linux and macOS.
"""

import contextlib
import io
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
RESULTS = runpy.run_path(str(ROOT / "scripts/ui-test-results.py"))
BUNDLE = "AudiobookshelfUITests"
LIMITS = ["-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "600",
          "-maximum-test-execution-time-allowance", "600"]
OUT = ".build/ui-tests"

# `mise run test:ui -- <args>`: records the call, then follows the case's script.json, one step
# per call: its exit status, the result bundle's tests.json and the enumerated tests.
FAKE_MISE = r'''
import json, os, sys
from pathlib import Path
root = Path(os.environ["CASE_ROOT"])
assert sys.argv[1:4] == ["run", "test:ui", "--"], sys.argv
args = sys.argv[4:]
with (root / "calls.jsonl").open("a") as out:
    out.write(json.dumps({"action": os.environ.get("ABS_UI_ACTION", "test"), "args": args}) + "\n")
calls = len((root / "calls.jsonl").read_text().splitlines())
steps = json.loads((root / "steps.json").read_text())
assert calls <= len(steps), f"unexpected call {calls}: {args}"
step = steps[calls - 1]
if "-resultBundlePath" in args:
    bundle = Path(args[args.index("-resultBundlePath") + 1])
    assert not bundle.exists(), "stale result bundle"
    if "tests" in step:
        bundle.mkdir(parents=True)
        (bundle / "tests.json").write_text(step["tests"])
if "-test-enumeration-output-path" in args and "selected" in step:
    Path(args[args.index("-test-enumeration-output-path") + 1]).write_text(step["selected"])
sys.exit(step["exit"])
'''

# `xcrun xcresulttool get test-results tests ... --path <bundle> --compact`: prints tests.json.
FAKE_XCRUN = r'''
import os, sys
from pathlib import Path
args = sys.argv[1:]
assert args[:4] == ["xcresulttool", "get", "test-results", "tests"], args
assert args[4:6] == ["--schema-version", "0.5.0"] and args[-1] == "--compact", args
with (Path(os.environ["CASE_ROOT"]) / "xcrun.log").open("a") as out:
    out.write(args[7] + "\n")
try:
    sys.stdout.write((Path(args[7]) / "tests.json").read_text())
except FileNotFoundError:
    sys.exit("error: no result bundle")
'''

# `xcodebuild <args>` for test:ui: records its arguments.
FAKE_XCODEBUILD = r'''
import json, os, sys
from pathlib import Path
with (Path(os.environ["CASE_ROOT"]) / "xcodebuild.jsonl").open("a") as out:
    out.write(json.dumps(sys.argv[1:]) + "\n")
'''


def case(name, result="Passed", children=None, details=None):
    node = {"nodeType": "Test Case", "name": name, "nodeIdentifier": f"X/{name}", "result": result}
    if children is not None:
        node["children"] = children
    if details is not None:
        node["details"] = details
    return node


def repetition(name, result, message=None):
    node = {"nodeType": "Repetition", "name": name, "result": result}
    if message is not None:
        node["children"] = [{"nodeType": "Failure Message", "name": message}]
    return node


def failed_twice(name):
    return case(name, "Failed", [repetition("First Run", "Failed", "failed"),
                                 repetition("Retry 1", "Failed", "failed")], "Failed after 2 retries")


def passed_on_retry(name):
    return case(name, "Passed", [repetition("First Run", "Failed", "Timed out while evaluating UI query"),
                                 repetition("Retry 1", "Passed")], "⚠️ Passed after 1 retry")


def timed_out(name):
    # Stopped by the time allowance: no repetition, as the runner ended.
    return case(name, "Failed", [{"nodeType": "Failure Message",
                                  "name": "Test exceeded execution time allowance of 10 minutes"}])


def suite(name, *cases, result=None):
    failed = any(child.get("result") == "Failed" for child in cases)
    return {"nodeType": "Test Suite", "name": name, "result": result or ("Failed" if failed else "Passed"),
            "children": list(cases)}


def report(*suites, devices=1, bundle=BUNDLE):
    failed = any(child.get("result") == "Failed" for child in suites)
    result = "Failed" if failed else "Passed"
    return {
        "devices": [{"deviceId": f"DEVICE-{index}", "deviceName": "iPhone Duo"} for index in range(devices)],
        "testPlanConfigurations": [{"configurationId": "1", "configurationName": "Test Scheme Action"}],
        "testNodes": [{"nodeType": "Test Plan", "name": "Audiobookshelf", "result": result, "children": [
            {"nodeType": "UI test bundle", "name": bundle, "result": result, "children": list(suites)},
        ]}],
    }


def selection(*identifiers):
    return {"errors": [], "values": [{"testPlan": "Audiobookshelf", "disabledTests": [],
                                      "enabledTests": [{"identifier": item} for item in identifiers]}]}


def selected(tree):
    """Every test case in `tree`, as -enumerate-tests lists them."""
    return selection(*[f"{BUNDLE}/{child['name']}/{test['name']}"
                       for plan in tree["testNodes"] for bundle in plan["children"]
                       for child in bundle["children"] for test in child["children"]])


def first_run(*failed):
    """A full run: the flaky audit passes on its in-runner retry, and `failed` fail."""
    return report(
        suite("AccessibilityAuditTests", passed_on_retry("testScreensAtAccessibilitySize()"),
              case("testScreens()")),
        suite("TabBarTests", case("testTabBarHasEveryTabAndNoMore()"),
              case("testSeriesSectionOpensBarsoom()", "Skipped")),
        suite("FailingTests", *failed),
    )


class ResultTests(unittest.TestCase):
    failed_tests = staticmethod(RESULTS["failed_tests"])
    verify_passed = staticmethod(RESULTS["verify_passed"])

    def assert_not_retried(self, tree, message, enumeration=None, limit=3):
        with self.assertRaisesRegex(ValueError, message):
            self.failed_tests(tree, enumeration or selected(tree), limit)

    def test_a_test_that_failed_twice_or_timed_out_runs_again_and_one_that_passed_on_retry_doesnt(self):
        tree = first_run(failed_twice("testOne()"), timed_out("testTwo()"))
        self.assertEqual(self.failed_tests(tree, selected(tree), 3), [
            f"{BUNDLE}/FailingTests/testOne", f"{BUNDLE}/FailingTests/testTwo",
        ])

    def test_up_to_the_limit_runs_again_and_more_dont(self):
        tree = first_run(*[failed_twice(f"test{index}()") for index in range(3)])
        self.assertEqual(len(self.failed_tests(tree, selected(tree), 3)), 3)
        tree = first_run(*[failed_twice(f"test{index}()") for index in range(4)])
        self.assert_not_retried(tree, "4 tests failed, more than the 3")

    def test_a_run_without_a_failed_test_doesnt_run_again(self):
        tree = first_run(case("testExpected()", "Expected Failure"), case("testSkipped()", "Skipped"))
        self.assert_not_retried(tree, "No test failed")
        empty = report()
        empty["testNodes"][0]["result"] = "unknown"
        self.assert_not_retried(empty, "Test enumeration listed no tests", selection())

    def test_a_failure_outside_a_test_doesnt_run_again(self):
        tree = first_run(failed_twice("testOne()"))
        tree["testNodes"][0]["children"][0]["children"][0]["children"].append(
            {"nodeType": "Failure Message", "name": "Crash outside a test"})
        self.assert_not_retried(tree, "Unexpected Failure Message")
        tree = first_run(case("testOne()"))
        tree["testNodes"][0]["children"][0]["children"][2]["result"] = "Failed"
        self.assert_not_retried(tree, "Test Suite 'FailingTests' failed, but none of its tests did")
        tree = report(suite("Passing", case("testOne()")))
        tree["testNodes"][0]["children"][0]["result"] = "Failed"
        self.assert_not_retried(tree, "UI test bundle 'AudiobookshelfUITests' failed")

    def test_tests_without_a_result_dont_run_again(self):
        tree = first_run(failed_twice("testOne()"))
        enumeration = selected(tree)
        enumeration["values"][0]["enabledTests"].append({"identifier": f"{BUNDLE}/LaterTests/testNeverRan()"})
        self.assert_not_retried(tree, "1 without a result", enumeration)
        enumeration = selected(first_run())
        self.assert_not_retried(tree, "1 not selected", enumeration)
        # A build failure: the result bundle has the device, but no tests.
        self.assert_not_retried(dict(tree, testNodes=[]), "5 without a result", selected(tree))

    def test_unknown_shapes_and_results_fail_closed(self):
        unknown = first_run(case("testOne()", "unknown"))
        missing = first_run(case("testOne()"))
        del missing["testNodes"][0]["children"][0]["children"][2]["children"][0]["result"]
        objc = first_run(case("testOne", "Failed"))
        nested = first_run(suite("Inner", failed_twice("testOne()")))
        duplicate = first_run(failed_twice("testOne()"), failed_twice("testOne()"))
        device = first_run(failed_twice("testOne()"))
        device["testNodes"][0]["children"][0]["children"][2]["children"] = [
            {"nodeType": "Device", "name": "iPhone Duo", "result": "Failed",
             "children": [failed_twice("testOne()")]}]
        for tree, message in [
            (unknown, "has result 'unknown'"), (missing, "has result None"),
            (objc, "Unexpected test case 'testOne'"), (nested, "Unexpected Test Suite 'Inner'"),
            (duplicate, "appears twice"), (device, "Unexpected Device"),
            (first_run(failed_twice("testOne()")) | {"devices": []}, "one device, got 0"),
            (report(suite("Tests", failed_twice("testOne()")), devices=2), "one device, got 2"),
            (report(suite("Tests", failed_twice("testOne()")), bundle="Bundle.xctest"), "UI test bundle name"),
        ]:
            with self.subTest(message):
                with self.assertRaisesRegex(ValueError, re.escape(message)):
                    self.failed_tests(tree, selection(), 3)

    def test_enumeration_errors_fail_closed(self):
        tree = first_run(failed_twice("testOne()"))
        for enumeration, message in [
            (dict(selected(tree), errors=["Couldn't load the test bundle"]), "reported errors"),
            (selection(), "no tests"),
            (selection(f"{BUNDLE}/A/testA()", f"{BUNDLE}/A/testA()"), "a test twice"),
        ]:
            with self.subTest(message):
                with self.assertRaisesRegex(ValueError, message):
                    self.failed_tests(tree, enumeration, 3)

    def test_the_run_again_passes_only_if_each_test_ran_and_passed(self):
        retried = [f"{BUNDLE}/FailingTests/testOne", f"{BUNDLE}/FailingTests/testTwo"]
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.verify_passed(report(suite("FailingTests", case("testOne()"), case("testTwo()"))), retried)
        self.assertEqual(output.getvalue().splitlines(), [f"Passed when run again: {name}()" for name in retried])
        empty = report()
        empty["testNodes"][0]["result"] = "unknown"
        for tree, retried_now, message in [
            (report(suite("FailingTests", case("testOne()"), failed_twice("testTwo()"))), retried, "testTwo(): Failed"),
            (report(suite("FailingTests", case("testOne()"), case("testTwo()", "Skipped"))), retried, "Skipped"),
            (report(suite("FailingTests", case("testOne()"))), retried, "Expected results"),
            (report(suite("FailingTests", case("testOne()"), case("testTwo()"), case("testThree()"))), retried,
             "Expected results"),
            (empty, retried, "Expected results"),
            (empty, [], "Expected results"),
        ]:
            with self.subTest(message):
                with self.assertRaisesRegex(ValueError, re.escape(message)):
                    self.verify_passed(tree, retried_now)


class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ui-test-ci.")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        for name in ("ui-test-ci.sh", "ui-test-results.py"):
            shutil.copyfile(ROOT / "scripts" / name, self.root / "scripts" / name)
        binaries = self.root / "bin"
        binaries.mkdir()
        for name, source in (("mise", FAKE_MISE), ("xcrun", FAKE_XCRUN), ("xcodebuild", FAKE_XCODEBUILD)):
            (binaries / name).write_text(f"#!{sys.executable}\n" + source)
            (binaries / name).chmod(0o700)
        self.env = dict(os.environ, CASE_ROOT=str(self.root), PATH=str(binaries) + os.pathsep + os.environ["PATH"])
        for key in ("GITHUB_ACTIONS", "ABS_UI_ACTION", "ABS_UI_PLATFORM", "IOS_SIMULATOR_ID"):
            self.env.pop(key, None)

    def run_script(self, steps, expected, args=()):
        (self.root / "steps.json").write_text(json.dumps([
            {key: value if key == "exit" or isinstance(value, str) else json.dumps(value)
             for key, value in step.items()}
            for step in steps
        ]))
        result = subprocess.run(["/bin/bash", str(self.root / "scripts/ui-test-ci.sh"), *args],
                                env=self.env, cwd=self.root, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertEqual(len(self.calls()), len(steps), result.stdout + result.stderr)
        return result

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_first_run(self, call, extra=()):
        self.assertEqual(call, {"action": "test", "args": [
            "-resultBundlePath", f"{OUT}/first.xcresult", "-retry-tests-on-failure", "-test-iterations", "2",
            *LIMITS, *extra,
        ]})

    def assert_selection(self, call, extra=()):
        self.assertEqual(call, {"action": "test-without-building", "args": [
            "-enumerate-tests", "-test-enumeration-format", "json", "-test-enumeration-style", "flat",
            "-test-enumeration-output-path", f"{OUT}/selected.json", *extra,
        ]})

    def test_a_passing_run_is_the_only_run(self):
        self.run_script([{"exit": 0}], 0)
        self.assert_first_run(self.calls()[0])
        self.assertFalse((self.root / "xcrun.log").exists())

    def test_only_the_failed_tests_run_again_without_building_and_decide(self):
        tree = first_run(failed_twice("testOne()"), timed_out("testTwo()"), case("testThree()"))
        again = report(suite("FailingTests", case("testOne()"), case("testTwo()")))
        self.env["GITHUB_ACTIONS"] = "true"
        result = self.run_script([
            {"exit": 65, "tests": tree}, {"exit": 0, "selected": selected(tree)}, {"exit": 0, "tests": again},
        ], 0)
        first, selection_call, retry = self.calls()
        self.assert_first_run(first)
        self.assert_selection(selection_call)
        self.assertEqual(retry, {"action": "test-without-building", "args": [
            "-resultBundlePath", f"{OUT}/retried.xcresult", *LIMITS,
            f"-only-testing:{BUNDLE}/FailingTests/testOne", f"-only-testing:{BUNDLE}/FailingTests/testTwo",
        ]})
        self.assertIn(f"Passed when run again: {BUNDLE}/FailingTests/testTwo()", result.stdout)
        self.assertIn(f"::warning title=UI tests passed when run again::Failed, then passed when run again: "
                      f"{BUNDLE}/FailingTests/testOne {BUNDLE}/FailingTests/testTwo\n", result.stdout)

    def test_a_test_that_fails_again_fails_the_step(self):
        tree = first_run(failed_twice("testOne()"))
        self.run_script([
            {"exit": 65, "tests": tree}, {"exit": 0, "selected": selected(tree)},
            {"exit": 65, "tests": report(suite("FailingTests", timed_out("testOne()")))},
        ], 65)

    def test_a_run_again_that_exits_0_without_passing_each_test_fails_the_step(self):
        tree = first_run(failed_twice("testOne()"), failed_twice("testTwo()"))
        empty = report()
        empty["testNodes"][0]["result"] = "unknown"
        for again in (empty, report(suite("FailingTests", case("testOne()"))),
                      report(suite("FailingTests", case("testOne()"), case("testTwo()", "Skipped")))):
            with self.subTest(again=again):
                (self.root / "calls.jsonl").unlink(missing_ok=True)
                result = self.run_script([
                    {"exit": 65, "tests": tree}, {"exit": 0, "selected": selected(tree)},
                    {"exit": 0, "tests": again},
                ], 1)
                self.assertIn("error: UI test results:", result.stderr)

    def test_other_failures_keep_the_first_runs_status_without_running_again(self):
        tree = first_run(failed_twice("testOne()"))
        four = first_run(*[failed_twice(f"test{index}()") for index in range(4)])
        none = first_run(case("testOne()", "Expected Failure"))
        missing = selected(tree)
        missing["values"][0]["enabledTests"].append({"identifier": f"{BUNDLE}/LaterTests/testNeverRan()"})
        for name, steps in [
            ("no result bundle", [{"exit": 65}]),
            ("unreadable results", [{"exit": 65, "tests": "{not json"}, {"exit": 0, "selected": selected(tree)}]),
            ("more than three", [{"exit": 65, "tests": four}, {"exit": 0, "selected": selected(four)}]),
            ("no failed test", [{"exit": 65, "tests": none}, {"exit": 0, "selected": selected(none)}]),
            ("a test never ran", [{"exit": 65, "tests": tree}, {"exit": 0, "selected": missing}]),
            ("enumeration failed", [{"exit": 65, "tests": tree}, {"exit": 70}]),
            ("enumeration unreadable", [{"exit": 65, "tests": tree}, {"exit": 0, "selected": "[]"}]),
        ]:
            with self.subTest(name):
                (self.root / "calls.jsonl").unlink(missing_ok=True)
                result = self.run_script(steps, 65)
                self.assertIn("error: UI tests failed (exit 65), and aren't run again", result.stderr)

    def test_a_first_run_stopped_by_a_signal_doesnt_run_again(self):
        tree = first_run(failed_twice("testOne()"))
        for status in (137, 143):
            with self.subTest(status=status):
                (self.root / "calls.jsonl").unlink(missing_ok=True)
                result = self.run_script([{"exit": status, "tests": tree}], status)
                self.assertIn(f"error: UI tests failed (exit {status}), and aren't run again: the first run was "
                              "stopped by a signal", result.stderr)
                self.assertFalse((self.root / "xcrun.log").exists())

    def test_the_caller_cant_pick_the_result_bundle(self):
        for args in (["-resultBundlePath", "/tmp/ui.xcresult"], ["-jobs", "2", "-resultBundlePath=/tmp/ui.xcresult"]):
            with self.subTest(args=args):
                result = self.run_script([], 2, args)
                self.assertIn("error: don't pass -resultBundlePath", result.stderr)

    def test_arguments_go_to_the_first_run_and_its_selection_only(self):
        only = f"-only-testing:{BUNDLE}/FailingTests"
        tree = report(suite("FailingTests", failed_twice("testOne()"), case("testTwo()")))
        self.run_script([
            {"exit": 65, "tests": tree}, {"exit": 0, "selected": selected(tree)},
            {"exit": 0, "tests": report(suite("FailingTests", case("testOne()")))},
        ], 0, [only, "-jobs", "2"])
        first, selection_call, retry = self.calls()
        self.assert_first_run(first, [only, "-jobs", "2"])
        self.assert_selection(selection_call, [only, "-jobs", "2"])
        self.assertEqual(retry["args"][-1:], [f"-only-testing:{BUNDLE}/FailingTests/testOne"])
        self.assertNotIn(only, retry["args"])

    def test_old_results_are_removed_first(self):
        for name in ("first.xcresult", "retried.xcresult"):
            (self.root / OUT / name).mkdir(parents=True)
        tree = first_run(failed_twice("testOne()"))
        self.run_script([
            {"exit": 65, "tests": tree}, {"exit": 0, "selected": selected(tree)},
            {"exit": 0, "tests": report(suite("FailingTests", case("testOne()")))},
        ], 0)


class RunnerDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="runner-diagnostics.")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        binaries = self.root / "bin"
        binaries.mkdir()
        collector = """#!/usr/bin/env bash
printf '%s\\n' "${0##*/}" >> "$DIAGNOSTICS_LOG"
if [[ "${0##*/}" == "$FAIL_COLLECTOR" ]]; then exit 7; fi
"""
        for name in ("memory_pressure", "vm_stat", "df"):
            path = binaries / name
            path.write_text(collector)
            path.chmod(0o700)
        command = binaries / "test-command"
        command.write_text("""#!/usr/bin/env bash
for _ in {1..500}; do
  if [[ -f "$SLEEP_PID_FILE" ]]; then exit "$COMMAND_STATUS"; fi
  /bin/sleep 0.01
done
exit 66
""")
        command.chmod(0o700)
        signal_command = binaries / "signal-command"
        signal_command.write_text("""#!/usr/bin/env bash
trap 'printf terminated > "$SIGNAL_FILE"; exit 42' INT TERM
printf '%s\\n' "$$" > "$COMMAND_PID_FILE"
while true; do /bin/sleep 1; done
""")
        signal_command.chmod(0o700)
        sleeper = binaries / "sleep"
        sleeper.write_text("""#!/usr/bin/env bash
printf '%s\\n' "$$" > "$SLEEP_PID_FILE"
exec /bin/sleep "$@"
""")
        sleeper.chmod(0o700)
        self.sleep_pid_file = self.root / "sleep.pid"
        self.command_pid_file = self.root / "command.pid"
        self.env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                        DIAGNOSTICS_LOG=str(self.root / "collectors.log"), FAIL_COLLECTOR="memory_pressure",
                        SLEEP_PID_FILE=str(self.sleep_pid_file), COMMAND_PID_FILE=str(self.command_pid_file),
                        SIGNAL_FILE=str(self.root / "signal"))

    def test_a_failed_collector_doesnt_replace_the_wrapped_command_status(self):
        script = ROOT / "scripts/with-runner-diagnostics.sh"
        for status in (0, 65):
            with self.subTest(status=status):
                (self.root / "collectors.log").unlink(missing_ok=True)
                self.sleep_pid_file.unlink(missing_ok=True)
                try:
                    result = subprocess.run([str(script), "test-command"], env=dict(self.env, COMMAND_STATUS=str(status)),
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                    self.assertIn("memory_pressure exited with status 7", result.stdout)
                    collectors = (self.root / "collectors.log").read_text().splitlines()
                    self.assertIn("vm_stat", collectors)
                    self.assertIn("df", collectors)
                    sleeper_pid = int(self.sleep_pid_file.read_text())
                    with self.assertRaises(ProcessLookupError):
                        os.kill(sleeper_pid, 0)
                finally:
                    if self.sleep_pid_file.exists():
                        try:
                            sleeper_pid = int(self.sleep_pid_file.read_text())
                            os.kill(sleeper_pid, 0)
                        except ProcessLookupError:
                            pass
                        else:
                            os.kill(sleeper_pid, 15)

    def test_signals_are_forwarded_to_the_command_and_the_monitor_is_reaped(self):
        script = ROOT / "scripts/with-runner-diagnostics.sh"
        for interrupt, status in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
            with self.subTest(signal=interrupt):
                (self.root / "signal").unlink(missing_ok=True)
                self.command_pid_file.unlink(missing_ok=True)
                self.sleep_pid_file.unlink(missing_ok=True)
                process = subprocess.Popen([str(script), "signal-command"], env=self.env, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True)
                try:
                    deadline = time.monotonic() + 5
                    while not (self.command_pid_file.exists() and self.sleep_pid_file.exists()):
                        if process.poll() is not None or time.monotonic() >= deadline:
                            self.fail("command or sampler did not start")
                        time.sleep(0.01)
                    process.send_signal(interrupt)
                    stdout, stderr = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, status, stdout + stderr)
                    self.assertEqual((self.root / "signal").read_text(), "terminated")
                    for pid_file in (self.command_pid_file, self.sleep_pid_file):
                        pid = int(pid_file.read_text())
                        with self.assertRaises(ProcessLookupError):
                            os.kill(pid, 0)
                finally:
                    for pid_file in (self.command_pid_file, self.sleep_pid_file):
                        if pid_file.exists():
                            pid = int(pid_file.read_text())
                            try:
                                os.kill(pid, 0)
                            except ProcessLookupError:
                                pass
                            else:
                                os.kill(pid, signal.SIGTERM)
                    if process.poll() is None:
                        process.send_signal(signal.SIGTERM)
                        try:
                            process.communicate(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.communicate()


class TestUITaskTests(unittest.TestCase):
    """test:ui's run script from mise.toml, with a fake xcodebuild."""

    SCRIPT = re.search(r'\[tasks\."test:ui"\]\n.*?\nrun = """\n(.*?)"""', (ROOT / "mise.toml").read_text(),
                       re.S).group(1)

    def setUp(self):
        self.assertNotIn("\\", self.SCRIPT)  # So the TOML string needs no unescaping.
        self.temporary = tempfile.TemporaryDirectory(prefix="test-ui.")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "test-ui.sh").write_text(self.SCRIPT)
        (self.root / "xcodebuild").write_text(f"#!{sys.executable}\n" + FAKE_XCODEBUILD)
        (self.root / "xcodebuild").chmod(0o700)
        self.env = dict(os.environ, CASE_ROOT=str(self.root), PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                        ABS_UI_PLATFORM="ios", IOS_SIMULATOR_ID="UDID")
        self.env.pop("ABS_UI_ACTION", None)

    def run_task(self, *args, expected=0):
        result = subprocess.run(["/bin/bash", str(self.root / "test-ui.sh"), *args], env=self.env,
                                cwd=self.root, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        path = self.root / "xcodebuild.jsonl"
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        path.unlink(missing_ok=True)
        return calls, result

    def test_runs_the_ui_test_bundle_unless_the_caller_picks_tests(self):
        common = ["-project", "Audiobookshelf.xcodeproj", "-scheme", "Audiobookshelf",
                  "-derivedDataPath", ".build/DerivedData"]
        destination = ["-destination", "platform=iOS Simulator,id=UDID", "CODE_SIGNING_ALLOWED=NO"]
        calls, _ = self.run_task("-jobs", "2")
        self.assertEqual(calls, [["test", *common, "-only-testing:AudiobookshelfUITests", *destination,
                                  "-jobs", "2"]])
        for picked in (["-only-testing:AudiobookshelfUITests/TabBarTests"], ["-only-testing", "@tests.txt"]):
            with self.subTest(picked=picked):
                calls, _ = self.run_task(*picked)
                self.assertEqual(calls, [["test", *common, *destination, *picked]])

    def test_abs_ui_action_runs_without_building_and_rejects_others(self):
        self.env["ABS_UI_ACTION"] = "test-without-building"
        calls, _ = self.run_task()
        self.assertEqual(calls[0][0], "test-without-building")
        self.env["ABS_UI_ACTION"] = "build"
        calls, result = self.run_task(expected=1)
        self.assertEqual(calls, [])
        self.assertIn("ABS_UI_ACTION must be test or test-without-building", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
