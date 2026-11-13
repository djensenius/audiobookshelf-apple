#!/usr/bin/env python3
"""Bounded fake-CLI regressions; no Apple commands, installs or simulator actions.

Runs the real launcher/helper in an owned temporary repository. Fixtures use the
installed xcresulttool 0.5.0 schema; real Swift Testing output remains a separate
simulator validation gate. Included in mise lint:repo on Linux and macOS.
"""

import json
import os
from pathlib import Path
import re
import runpy
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
RUNNER = runpy.run_path(str(ROOT / "scripts/test-kit-ios.py"))
METHODS = [
    "aDetectorStopsItsOwnUpdates()",
    "stoppingAnEarlierDetectorLeavesTheLaterOneRunning()",
    "releasingAnEarlierDetectorLeavesTheLaterOneRunning()",
    "releasingARunningDetectorStopsItsUpdates()",
]
FIRST = "11111111-1111-1111-1111-111111111111"
SECOND = "22222222-2222-2222-2222-222222222222"
OLDER = "33333333-3333-3333-3333-333333333333"
TOO_OLD = "44444444-4444-4444-4444-444444444444"
UNAVAILABLE = "55555555-5555-5555-5555-555555555555"
IPAD = "66666666-6666-6666-6666-666666666666"
CREATED = ["AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"]
PHONE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
PAD_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro"

FAKE_CLI = r'''
import json, os, signal, sys, time
from pathlib import Path
root = Path(os.environ["CASE_ROOT"])
args = sys.argv[1:]
tool = Path(sys.argv[0]).name
with (root / "calls.jsonl").open("a") as out:
    out.write(json.dumps({"tool": tool, "args": args, "cwd": os.getcwd(),
                          "developerDir": os.environ.get("DEVELOPER_DIR")}) + "\n")
faults = json.loads((root / "faults.json").read_text())
if tool == "xcodebuild" and args == ["-list", "-json"]:
    if faults.get("list"):
        sys.exit(faults["list"])
    print((root / "listing.json").read_text())
    sys.exit(0)
if tool == "xcodebuild":
    result = Path(args[args.index("-resultBundlePath") + 1])
    assert not result.exists(), "stale result bundle"
    result.mkdir()
    marker = root / "xcode.pid.tmp"
    marker.write_text(str(os.getpid()))
    marker.replace(root / "xcode.pid")
    if faults.get("hang"):
        time.sleep(60)
    runs = sorted(root.glob("xcode-run.*"))
    (root / f"xcode-run.{len(runs)}").touch()
    scripted = faults.get("xcodeRuns", [])
    if len(runs) < len(scripted):
        # Infrastructure errors arrive on stderr; the runner must still see them.
        print(scripted[len(runs)]["output"], file=sys.stderr, flush=True)
        sys.exit(scripted[len(runs)]["code"])
    print("** TEST SUCCEEDED **")  # Never sufficient evidence.
    sys.exit(faults.get("xcode", 0))
assert tool == "xcrun"
created = root / "created.json"
owned = json.loads(created.read_text()) if created.exists() else []
if args[:2] == ["simctl", "create"]:
    assert len(args) == 5, args
    if faults.get("create"):
        sys.exit(faults["create"])
    udid = json.loads((root / "udids.json").read_text())[len(owned)]
    created.write_text(json.dumps(owned + [{"name": args[2], "udid": udid}]))
    print(faults.get("createOutput", udid))
    sys.exit(0)
if args[:2] in (["simctl", "bootstatus"], ["simctl", "shutdown"], ["simctl", "delete"]):
    # Only ever touch a simulator this run created.
    assert args[2] in [item["udid"] for item in owned] + [item["name"] for item in owned], args
    assert args[3:] == (["-b"] if args[1] == "bootstatus" else []), args
    if args[1] == "shutdown" and faults.get("cancelDuringShutdown"):
        os.kill(os.getppid(), signal.SIGTERM)  # The runner, as a cancelled job would see it.
    sys.exit(faults.get(args[1], 0))
if args == ["simctl", "list", "-j", "devices", "available"]:
    kind = "devices"
elif args == ["simctl", "list", "-j", "devices"]:
    kind = "allDevices"
elif args == ["simctl", "list", "-j", "runtimes"]:
    kind = "runtimes"
elif args[:3] == ["xcresulttool", "get", "test-results"]:
    kind = args[3]
    assert kind in ("summary", "tests")
    assert args[4:6] == ["--schema-version", "0.5.0"]
    assert args[6] == "--path" and Path(args[7]).is_dir()
    assert args[8:] == ["--compact"]
else:
    raise AssertionError(args)  # Reject any simulator mutation or unexpected CLI.
if faults.get(kind):
    sys.exit(faults[kind])
print((root / (kind + ".json")).read_text())
'''


def runtime(version):
    return {
        "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-"),
        "version": version, "isAvailable": True,
        "supportedDeviceTypes": [
            {"identifier": PHONE_TYPE, "productFamily": "iPhone"},
            {"identifier": PAD_TYPE, "productFamily": "iPad"},
        ],
    }


def device(udid, *, available=True, kind=PHONE_TYPE, state="Shutdown"):
    return {"udid": udid, "isAvailable": available, "deviceTypeIdentifier": kind,
            "state": state, "name": "Duplicate or renamed device"}


class RunnerTests(unittest.TestCase):
    def setUp(self):
        parent = ROOT / ".build/kit-ios-regressions"
        parent.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="case.", dir=parent)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("test-kit-ios.sh", "test-kit-ios.py"):
            shutil.copyfile(ROOT / "scripts" / name, scripts / name)
        self.package = self.root / "Packages/AudiobookshelfKit"
        self.package.mkdir(parents=True)
        shutil.copyfile(ROOT / "Packages/AudiobookshelfKit/Package.swift", self.package / "Package.swift")
        binaries = self.root / "bin"
        binaries.mkdir()
        for name in ("xcrun", "xcodebuild"):
            path = binaries / name
            path.write_text(f"#!{sys.executable}\n" + FAKE_CLI)
            path.chmod(0o700)
        self.env = dict(os.environ, CASE_ROOT=str(self.root))
        for key in ("IOS_SIMULATOR_ID", "DEVELOPER_DIR", "CI", "ABS_EPHEMERAL_SIMULATOR",
                    "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
            self.env.pop(key, None)
        self.env["PATH"] = str(binaries) + os.pathsep + self.env["PATH"]
        newest, older, too_old = runtime("27.2"), runtime("27.0"), runtime("26.5")
        self.runtimes = {"runtimes": [too_old, newest, older]}
        self.devices = {"devices": {
            newest["identifier"]: [
                device(SECOND), device(FIRST), device(UNAVAILABLE, available=False),
                device(IPAD, kind=PAD_TYPE),
            ],
            older["identifier"]: [device(OLDER, state="Booted")],
            too_old["identifier"]: [device(TOO_OLD)],
        }}
        self.summary = {
            "result": "Passed", "totalTestCount": 4, "passedTests": 4,
            "failedTests": 0, "skippedTests": 0, "expectedFailures": 0, "testFailures": [],
        }
        self.cases = [
            {"nodeType": "Test Case", "name": name, "result": "Passed"}
            for name in METHODS
        ]
        self.suite = {"nodeType": "Test Suite", "name": "ShakeDetectorTests", "children": self.cases}
        self.bundle = {"nodeType": "Unit test bundle", "name": "ABSPlaybackTests", "children": [self.suite]}
        self.tests = {"devices": [{"deviceId": FIRST}], "testNodes": [
            {"nodeType": "Test Plan", "name": "AudiobookshelfKit", "children": [self.bundle]},
        ]}
        self.listing = {"workspace": {"name": "AudiobookshelfKit", "schemes": [
            "AudiobookshelfKit", "AudiobookshelfKit-Package", "AudiobookshelfWidgetKit",
        ]}}
        self.faults = {}
        self.udids = CREATED
        self.allDevices = {"devices": {}}

    def prepare(self):
        for name in ("devices", "runtimes", "summary", "tests", "faults", "listing", "udids", "allDevices"):
            (self.root / f"{name}.json").write_text(json.dumps(getattr(self, name)))

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def simctl(self):
        return [call["args"][1:] for call in self.calls() if call["args"][:1] == ["simctl"]]

    def assert_no_simulator_mutation(self):
        self.assertEqual({tuple(args[:1]) for args in self.simctl()}, {("list",)})

    def run_case(self, expected=0, prepare=True, args=()):
        if prepare:
            self.prepare()
        result = subprocess.run(
            ["/bin/bash", str(self.root / "scripts/test-kit-ios.sh"), *args],
            env=self.env, cwd=self.root, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_default_command_and_four_method_evidence(self):
        result = self.run_case()
        self.assertIn("Verified 4/4", result.stdout)
        for name in METHODS:
            self.assertIn(f"Verified Passed: ABSPlaybackTests/ShakeDetectorTests/{name}", result.stdout)
        listing, call = [call for call in self.calls() if call["tool"] == "xcodebuild"]
        self.assertEqual(listing["args"], ["-list", "-json"])
        self.assertEqual(listing["cwd"], str(self.package))
        args = call["args"]
        self.assertEqual(call["cwd"], str(self.package))
        self.assertEqual(call["developerDir"], "/Applications/Xcode.app/Contents/Developer")
        work = next((self.root / ".build/kit-ios").iterdir())
        self.assertEqual(args, [
            "test", "-scheme", "AudiobookshelfKit-Package",
            "-destination", f"platform=iOS Simulator,id={FIRST}", "-destination-timeout", "60",
            "-only-testing:ABSPlaybackTests/ShakeDetectorTests",
            "-derivedDataPath", str(work / "DerivedData"), "-resultBundlePath", str(work / "Tests.xcresult"),
            "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
            "-jobs", "2", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "60",
            "CODE_SIGNING_ALLOWED=NO",
        ])
        self.assertEqual(json.loads((work / "tests.json").read_text()), self.tests)
        self.assertEqual(json.loads((work / "summary.json").read_text()), self.summary)
        self.run_case()  # A second invocation cannot reuse a stale result.
        self.assertEqual(len(list((self.root / ".build/kit-ios").iterdir())), 2)
        self.assert_no_simulator_mutation()
        # Outside CI the borrowed simulator is never created, shut down or deleted.
        self.env.update(CI="false", GITHUB_RUN_ID="1", GITHUB_RUN_ATTEMPT="1")
        self.run_case()
        self.env.update(CI="true", ABS_EPHEMERAL_SIMULATOR="0")
        self.run_case()
        self.assert_no_simulator_mutation()

    def test_scheme_follows_the_manifests_products(self):
        # One product: Xcode's scheme is named after it and has the test action.
        self.listing["workspace"]["schemes"] = ["AudiobookshelfKit"]
        self.run_case()
        test = [call for call in self.calls() if call["tool"] == "xcodebuild"][-1]
        self.assertEqual(test["args"][:3], ["test", "-scheme", "AudiobookshelfKit"])
        # Neither scheme listed: fail before testing anything.
        self.listing["workspace"]["schemes"] = ["AudiobookshelfWidgetKit"]
        self.assertIn("No AudiobookshelfKit test scheme", self.run_case(expected=1).stderr)
        self.assertEqual(self.calls()[-1]["args"], ["-list", "-json"])
        self.faults = {"list": 66}
        self.run_case(expected=66)
        self.faults = {}
        self.prepare()
        (self.root / "listing.json").write_text("not JSON")
        self.run_case(expected=1, prepare=False)
        self.assertEqual(self.calls()[-1]["args"], ["-list", "-json"])

    def test_explicit_destination_and_ci_toolchain(self):
        self.env.update(IOS_SIMULATOR_ID=OLDER, DEVELOPER_DIR="/Applications/Xcode_27.2.app/Contents/Developer")
        self.tests["devices"] = [{"deviceId": OLDER}]
        self.run_case()
        call = [call for call in self.calls() if call["tool"] == "xcodebuild"][-1]
        self.assertIn(f"platform=iOS Simulator,id={OLDER}", call["args"])
        self.assertEqual(call["developerDir"], self.env["DEVELOPER_DIR"])
        # An explicit simulator wins over CI's ephemeral one and is never deleted.
        for flags in ({"CI": "true"}, {"ABS_EPHEMERAL_SIMULATOR": "1"}):
            with self.subTest(flags=flags):
                self.env.update(flags, GITHUB_RUN_ID="7", GITHUB_RUN_ATTEMPT="1")
                self.run_case()
        self.assert_no_simulator_mutation()
        self.env["IOS_SIMULATOR_ID"] = "missing"
        self.assertIn("no fallback", self.run_case(expected=1).stderr)
        self.assert_no_simulator_mutation()

    def test_invalid_explicit_destinations_never_fall_back(self):
        for udid in ("", "missing", TOO_OLD, UNAVAILABLE, IPAD):
            with self.subTest(udid=udid):
                self.env["IOS_SIMULATOR_ID"] = udid
                self.assertIn("no fallback", self.run_case(expected=1).stderr)
        self.assertTrue(all(call["tool"] != "xcodebuild" for call in self.calls()))

    def ci(self, run_id="98/7 x", attempt="2"):
        self.env.update(CI="true", GITHUB_RUN_ID=run_id, GITHUB_RUN_ATTEMPT=attempt)
        self.tests["devices"] = [{"deviceId": CREATED[0]}]

    def assert_ephemeral_lifecycle(self, attempts, *, tested=None, prefix="abs-ci-98-7-x-2-"):
        """create, boot, [xcodebuild], shutdown, delete per attempt, nothing else mutated."""
        tested = attempts if tested is None else tested
        expected, names = [], []
        for index in range(attempts):
            udid = CREATED[index]
            name = json.loads((self.root / "created.json").read_text())[index]["name"]
            self.assertRegex(name, rf"^{re.escape(prefix)}[0-9]+-{index + 1}$")
            names.append(name)
            expected += [
                ["create", name, PHONE_TYPE, runtime("27.2")["identifier"]],
                ["bootstatus", udid, "-b"],
                ["shutdown", udid], ["delete", udid],
            ]
        self.assertEqual([args for args in self.simctl() if args[0] != "list"], expected)
        self.assertEqual(len({name.rsplit("-", 1)[0] for name in names}), min(attempts, 1))
        tests = [call["args"] for call in self.calls() if call["args"][:1] == ["test"]]
        self.assertEqual([args[args.index("-destination") + 1] for args in tests],
                         [f"platform=iOS Simulator,id={CREATED[index]}" for index in range(tested)])
        # Each mutation precedes the next attempt: test, then cleanup, then a fresh device.
        order = [call["args"][1] if call["tool"] == "xcrun" else call["args"][0] for call in self.calls()]
        lifecycle = [step for step in order if step in ("create", "bootstatus", "test", "shutdown", "delete")]
        per_attempt = ["create", "bootstatus", "test", "shutdown", "delete"]
        self.assertEqual(lifecycle, [step for index in range(attempts) for step in per_attempt
                                     if step != "test" or index < tested])

    def test_ci_creates_boots_tests_and_deletes_its_own_simulator(self):
        self.ci()
        result = self.run_case()
        self.assertIn("Verified 4/4", result.stdout)
        self.assertIn("** TEST SUCCEEDED **", result.stdout)  # Still streamed while captured.
        self.assertIn(f"Deleted ephemeral simulator {CREATED[0]}", result.stdout)
        self.assert_ephemeral_lifecycle(1)
        work = next((self.root / ".build/kit-ios").iterdir())
        destination = json.loads((work / "destination.json").read_text())
        self.assertEqual(destination["udid"], CREATED[0])
        self.assertRegex(destination["ephemeralName"], r"^abs-ci-98-7-x-2-[0-9]+-1$")

    def test_ephemeral_opt_in_outside_ci_and_name_defaults(self):
        self.tests["devices"] = [{"deviceId": CREATED[0]}]
        self.env["ABS_EPHEMERAL_SIMULATOR"] = "1"
        self.run_case()
        self.assert_ephemeral_lifecycle(1, prefix="abs-ci-local-1-")

    def test_ci_cleans_up_after_xcodebuild_or_verification_failure_without_retry(self):
        for output in ("** TEST FAILED **", "Testing failed: ShakeDetectorTests failed"):
            with self.subTest(output=output):
                self.setUp()
                self.ci()
                self.faults = {"xcodeRuns": [{"code": 65, "output": output}]}
                self.run_case(expected=65)
                self.assert_ephemeral_lifecycle(1)
        self.setUp()
        self.ci()
        self.summary["failedTests"] = 1
        self.assertIn("summary failedTests", self.run_case(expected=1).stderr)
        self.assert_ephemeral_lifecycle(1)

    def test_ci_retries_once_on_a_fresh_simulator_for_infrastructure_failures(self):
        for output in (
            "DTServiceHubClient failed to bless service hub for simulator iPhone 17 (4AD2086B)",
            "xctest (123) encountered an error (The test runner hung before establishing connection.)",
            "Unable to boot the Simulator.",
        ):
            with self.subTest(output=output):
                self.setUp()
                self.ci()
                self.tests["devices"] = [{"deviceId": CREATED[1]}]
                self.faults = {"xcodeRuns": [{"code": 65, "output": output}]}
                result = self.run_case()
                self.assertIn("retrying once on a fresh simulator", result.stderr)
                self.assertIn(output, result.stdout)
                self.assert_ephemeral_lifecycle(2)
                self.assertEqual(len(list((self.root / ".build/kit-ios").iterdir())), 2)
                # Never more than one retry.
                self.setUp()
                self.ci()
                self.faults = {"xcodeRuns": [{"code": 65, "output": output}] * 3}
                self.run_case(expected=65)
                self.assert_ephemeral_lifecycle(2)

    def test_ci_cancellation_during_cleanup_exits_without_retrying(self):
        for runs in ([{"code": 65, "output": "failed to bless service hub"}],
                     [{"code": 65, "output": "** TEST FAILED **"}], []):
            with self.subTest(runs=runs):
                self.setUp()
                self.ci()
                self.faults = {"xcodeRuns": runs, "cancelDuringShutdown": True}
                result = self.run_case(expected=143)
                self.assertIn("interrupted by signal 15", result.stderr)
                self.assertNotIn("retrying", result.stderr)
                self.assert_ephemeral_lifecycle(1)

    def test_ci_boot_or_create_failure_and_shutdown_failure(self):
        self.ci()
        self.faults = {"bootstatus": 149}
        self.run_case(expected=149)
        self.assert_ephemeral_lifecycle(1, tested=0)
        self.setUp()
        self.ci()
        self.faults = {"shutdown": 149}  # A device that never booted can't shut down.
        self.run_case()
        self.assert_ephemeral_lifecycle(1)
        self.setUp()
        self.ci()
        self.faults = {"create": 148}
        self.assertIn("simctl create", self.run_case(expected=1).stderr)
        self.assertEqual([args[0] for args in self.simctl()], ["list", "list", "create"])
        self.setUp()
        self.ci()
        self.faults = {"createOutput": "not a UDID"}  # Delete what was created, by name.
        self.assertIn("malformed UDID", self.run_case(expected=1).stderr)
        name = json.loads((self.root / "created.json").read_text())[0]["name"]
        self.assertEqual([args for args in self.simctl() if args[0] != "list"],
                         [["create", name, PHONE_TYPE, runtime("27.2")["identifier"]],
                          ["shutdown", name], ["delete", name]])

    def test_delete_run_simulators_matches_only_this_run_attempt(self):
        names = {
            CREATED[0]: "abs-ci-55-1-123-1", CREATED[1]: "abs-ci-55-1-123-2",
            FIRST: "abs-ci-55-12-1-1", SECOND: "abs-ci-551-1-1-1", OLDER: "iPhone 17",
        }
        self.allDevices = {"devices": {"r": [{"udid": udid, "name": name} for udid, name in names.items()]}}
        (self.root / "created.json").write_text(json.dumps([{"name": names[u], "udid": u} for u in CREATED]))
        self.env.update(GITHUB_RUN_ID="55", GITHUB_RUN_ATTEMPT="1")
        self.assertIn("2 simulator(s) named abs-ci-55-1-*",
                      self.run_case(args=["--delete-run-simulators"]).stdout)
        self.assertEqual([args for args in self.simctl() if args[0] != "list"],
                         [["shutdown", CREATED[0]], ["delete", CREATED[0]],
                          ["shutdown", CREATED[1]], ["delete", CREATED[1]]])
        self.faults = {"delete": 148}
        self.assertIn("Couldn't delete", self.run_case(expected=1, args=["--delete-run-simulators"]).stderr)
        self.allDevices = {"devices": {}}
        self.faults = {}
        self.assertIn("0 simulator(s)", self.run_case(args=["--delete-run-simulators"]).stdout)
        self.env.pop("GITHUB_RUN_ID")
        calls = len(self.calls())
        self.assertIn("GITHUB_RUN_ID", self.run_case(expected=1, args=["--delete-run-simulators"]).stderr)
        self.assertEqual(len(self.calls()), calls)

    def test_no_compatible_destination(self):
        self.runtimes["runtimes"] = [runtime("26.5")]
        self.assertIn("No available iPhone", self.run_case(expected=1).stderr)
        self.assertEqual(len(self.calls()), 2)

    def test_selection_is_order_independent_and_prefers_booted_on_same_runtime(self):
        select = RUNNER["select_destination"]
        for devices in self.devices["devices"].values():
            devices.reverse()
        self.runtimes["runtimes"].reverse()
        self.assertEqual(select(self.devices, self.runtimes, (27, 0, 0), None), FIRST)
        # Select a known device rather than depending on fixture array order.
        for item in self.devices["devices"][runtime("27.2")["identifier"]]:
            item["state"] = "Booted" if item["udid"] == SECOND else "Shutdown"
        self.assertEqual(select(self.devices, self.runtimes, (27, 0, 0), None), SECOND)
        self.runtimes["runtimes"][1]["isAvailable"] = False
        self.assertEqual(select(self.devices, self.runtimes, (27, 0, 0), None), OLDER)

    def test_empty_xctest_summary_is_not_success(self):
        self.summary.update(totalTestCount=0, passedTests=0)
        self.assertIn("summary totalTestCount", self.run_case(expected=1).stderr)

    def test_missing_empty_duplicate_or_wrong_methods_fail(self):
        for cases in ([], self.cases[:-1], [self.cases[0]] * 4,
                      [*self.cases[:3], {"nodeType": "Test Case", "name": "unrelated()", "result": "Passed"}]):
            with self.subTest(cases=cases):
                self.suite["children"] = cases
                self.run_case(expected=1)

    def test_skipped_failed_unknown_or_missing_case_result_fails(self):
        for status in ("Skipped", "Failed", "Expected Failure", "unknown", None):
            with self.subTest(status=status):
                self.cases[0]["result"] = status
                self.run_case(expected=1)
        self.cases[0].pop("result")
        self.run_case(expected=1)

    def test_summary_failures_fail_even_with_passing_tree(self):
        for field in ("failedTests", "skippedTests", "expectedFailures"):
            with self.subTest(field=field):
                self.summary[field] = 1
                self.run_case(expected=1)
                self.summary[field] = 0
        self.summary["result"] = "Failed"
        self.run_case(expected=1)

    def test_wrong_bundle_suite_or_device_fails(self):
        self.bundle["name"] = "OtherTests"
        self.run_case(expected=1)
        self.bundle["name"] = "ABSPlaybackTests.xctest"
        self.suite["name"] = "OtherSuite"
        self.run_case(expected=1)
        self.suite["name"] = "ShakeDetectorTests"
        self.tests["devices"] = [{"deviceId": SECOND}]
        self.run_case(expected=1)
        self.tests["devices"] = [{"deviceId": FIRST}]
        self.run_case()

    def test_empty_tree_and_failed_child_run_fail(self):
        self.cases[0]["children"] = [{"nodeType": "Test Case Run", "name": "Run 1", "result": "Failed"}]
        self.run_case(expected=1)
        self.tests["testNodes"] = []
        self.run_case(expected=1)

    def test_command_exit_codes_and_retained_failed_evidence(self):
        for kind, code in (("xcode", 65), ("summary", 37), ("tests", 38), ("devices", 39), ("runtimes", 40)):
            with self.subTest(kind=kind):
                self.faults = {kind: code}
                self.run_case(expected=code)
        self.assertEqual(len(list((self.root / ".build/kit-ios").glob("run.*/Tests.xcresult"))), 3)

    def test_malformed_json_fails_closed(self):
        for kind in ("devices", "runtimes", "summary", "tests"):
            with self.subTest(kind=kind):
                self.prepare()
                (self.root / f"{kind}.json").write_text("not JSON")
                self.run_case(expected=1, prepare=False)

    def test_allowlist_matches_the_guarded_swift_suite(self):
        source = (ROOT / "Packages/AudiobookshelfKit/Tests/ABSPlaybackTests/SleepTimer/ShakeDetectorTests.swift").read_text()
        self.assertEqual(set(re.findall(r"@Test func (\w+\(\))", source)), set(METHODS))
        self.assertEqual(RUNNER["METHODS"], set(METHODS))

    def assert_command_deadline(self, ignore_term):
        # Handshake after installing the disposition: no startup sleep races.
        # The alarm is only an outer safety net if the runner loses its deadline.
        args = [sys.executable, "-c", (
            "import signal\n"
            f"signal.signal(signal.SIGTERM, signal.{'SIG_IGN' if ignore_term else 'SIG_DFL'})\n"
            "signal.alarm(12)\n"
            "print('ready', flush=True)\n"
            "while True: signal.pause()\n"
        )]
        real_popen = subprocess.Popen
        children, deadline_errors, cleanup_errors = [], [], []

        def ready_child(*popen_args, **kwargs):
            process = real_popen(*popen_args, **kwargs)
            children.append(process)
            self.assertTrue(select.select([process.stdout], [], [], 5)[0], "child readiness timed out")
            self.assertEqual(process.stdout.readline(), "ready\n")
            real_communicate, real_wait = process.communicate, process.wait

            def communicate(*, timeout):
                try:
                    return real_communicate(timeout=timeout)
                except subprocess.TimeoutExpired as error:
                    deadline_errors.append(error)
                    raise

            def wait(*, timeout):
                try:
                    return real_wait(timeout=timeout)
                except subprocess.TimeoutExpired as error:
                    cleanup_errors.append(error)
                    raise

            # Spies delegate to real subprocess operations, including the
            # unchanged five-second cleanup grace period and real SIGKILL.
            process.communicate = mock.Mock(side_effect=communicate)
            process.wait = mock.Mock(side_effect=wait)
            process.terminate = mock.Mock(wraps=process.terminate)
            process.kill = mock.Mock(wraps=process.kill)
            return process

        started = time.monotonic()
        try:
            with mock.patch.object(subprocess, "Popen", side_effect=ready_child):
                with self.assertRaises(subprocess.TimeoutExpired) as failure:
                    RUNNER["command"](args, capture=True, timeout=0.1)
            elapsed = time.monotonic() - started
            self.assertLess(elapsed, 10, "runner cleanup exceeded the bounded completion window")
            self.assertEqual(len(children), 1)
            process = children[0]
            self.assertEqual(len(deadline_errors), 1)
            self.assertIs(failure.exception, deadline_errors[0], "cleanup replaced the original failure")
            self.assertEqual(failure.exception.cmd, args)
            self.assertEqual(failure.exception.timeout, 0.1)
            process.communicate.assert_called_once_with(timeout=0.1)
            process.terminate.assert_called_once_with()
            self.assertEqual([error.timeout for error in cleanup_errors], [5] if ignore_term else [])
            self.assertEqual(process.wait.call_args_list, [mock.call(timeout=5)] * (2 if ignore_term else 1))
            if ignore_term:
                process.kill.assert_called_once_with()
            else:
                process.kill.assert_not_called()
            self.assertEqual(process.returncode, -signal.SIGKILL if ignore_term else -signal.SIGTERM)
            # waitpid, unlike kill(pid, 0), proves our direct child was reaped.
            with self.assertRaises(ChildProcessError):
                os.waitpid(process.pid, os.WNOHANG)
            print(f"Deadline proof: pid={process.pid} timeout=0.1s propagated; "
                  f"terminate=1 cleanup-timeouts={len(cleanup_errors)} kill={process.kill.call_count} "
                  f"returncode={process.returncode} reaped=True elapsed={elapsed:.3f}s", flush=True)
        finally:
            # Exact owned Popen objects only; also bounds a broken-runner failure.
            for process in children:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=2)
                process.stdout.close()

    def test_command_deadline_terminates_and_reaps_owned_child(self):
        self.assert_command_deadline(ignore_term=False)

    def test_command_deadline_kills_and_reaps_sigterm_ignoring_child(self):
        self.assert_command_deadline(ignore_term=True)

    def assert_guarded_child_lifecycle(self, startup_signal=None):
        handled = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        previous = {sig: signal.getsignal(sig) for sig in handled}
        module = RUNNER["command"].__globals__
        interrupted_type = RUNNER["InterruptedRunner"]
        interrupts, timeouts, children = [], [], []
        real_popen = subprocess.Popen
        args = [sys.executable, "-c", (
            "import json, signal\n"
            "signal.alarm(12)\n"
            "print(json.dumps({'blocked': list(signal.pthread_sigmask(signal.SIG_BLOCK, [])), "
            "'termDefault': signal.getsignal(signal.SIGTERM) == signal.SIG_DFL}), flush=True)\n"
            + ("" if startup_signal else "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n")
            + "print('ready', flush=True)\n"
            "while True: signal.pause()\n"
        )]

        def interruption(sig):
            error = interrupted_type(sig)
            interrupts.append(error)
            return error

        def starting_child(*popen_args, **kwargs):
            process = real_popen(*popen_args, **kwargs)
            real_wait, real_kill = process.wait, process.kill
            children.append((process, real_wait, real_kill))
            self.assertTrue(select.select([process.stdout], [], [], 5)[0], "child readiness timed out")
            state = json.loads(process.stdout.readline())
            self.assertTrue(state["termDefault"])
            self.assertTrue(set(state["blocked"]).isdisjoint(handled), state)
            self.assertEqual(process.stdout.readline(), "ready\n")
            real_communicate, real_terminate = process.communicate, process.terminate

            def communicate(*, timeout):
                try:
                    return real_communicate(timeout=timeout)
                except subprocess.TimeoutExpired as error:
                    timeouts.append(error)
                    raise

            def terminate():
                # Real additional signals during cleanup must not replace the
                # first exception or prevent termination/reaping.
                os.kill(os.getpid(), signal.SIGINT)
                real_terminate()

            def wait(*, timeout):
                os.kill(os.getpid(), signal.SIGHUP)
                return real_wait(timeout=timeout)

            process.communicate = mock.Mock(side_effect=communicate)
            process.terminate = mock.Mock(side_effect=terminate)
            process.wait = mock.Mock(side_effect=wait)
            process.kill = mock.Mock(wraps=real_kill)
            print(f"Child startup: pid={process.pid} handled-signals-unblocked=True SIGTERM-default=True", flush=True)
            if startup_signal:
                # This is inside Popen's call boundary: command() has not yet
                # received the real, live child handle. No sleep-based race.
                os.kill(os.getpid(), startup_signal)
            return process

        try:
            for sig in handled:
                signal.signal(sig, RUNNER["interrupted"])
            expected = interrupted_type if startup_signal else subprocess.TimeoutExpired
            with mock.patch.dict(module, InterruptedRunner=interruption):
                with mock.patch.object(subprocess, "Popen", side_effect=starting_child):
                    with self.assertRaises(expected) as failure:
                        RUNNER["command"](args, capture=True, timeout=0.1)
            self.assertEqual(len(children), 1)
            process = children[0][0]
            self.assertIsNotNone(process.poll(), "owned child escaped startup interruption without cleanup")
            self.assertIs(failure.exception, interrupts[0] if startup_signal else timeouts[0])
            if startup_signal:
                self.assertEqual(failure.exception.signum, startup_signal)
                process.kill.assert_not_called()
            else:
                self.assertEqual(failure.exception.timeout, 0.1)
                process.kill.assert_called_once_with()
            process.terminate.assert_called_once_with()
            self.assertEqual(process.returncode, -signal.SIGTERM if startup_signal else -signal.SIGKILL)
            with self.assertRaises(ChildProcessError):
                os.waitpid(process.pid, os.WNOHANG)
            self.assertTrue(all(signal.getsignal(sig) is RUNNER["interrupted"] for sig in handled))
            print(f"Lifecycle proof: startup-signal={startup_signal} pid={process.pid} "
                  f"original-exception=True returncode={process.returncode} reaped=True handlers-restored=True",
                  flush=True)
        finally:
            # Bypass the injected cleanup signals for the test's own safety net.
            for process, real_wait, real_kill in children:
                if process.poll() is None:
                    real_kill()
                real_wait(timeout=2)
                process.stdout.close()
                with self.assertRaises(ChildProcessError):
                    os.waitpid(process.pid, os.WNOHANG)
                print(f"Fixture cleanup: owned PID {process.pid} reaped", flush=True)
            for sig, handler in previous.items():
                signal.signal(sig, handler)

    def test_startup_signals_are_deferred_until_owned_child_is_guarded(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig):
                self.assert_guarded_child_lifecycle(startup_signal=sig)

    def test_cleanup_signals_preserve_timeout_and_forced_kill(self):
        self.assert_guarded_child_lifecycle()

    def test_command_restores_handlers_on_success_and_spawn_failure(self):
        handled = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        previous = {sig: signal.getsignal(sig) for sig in handled}
        self.assertEqual(RUNNER["command"]([sys.executable, "-c", "print('done')"], capture=True), "done\n")
        self.assertEqual({sig: signal.getsignal(sig) for sig in handled}, previous)
        with self.assertRaises(FileNotFoundError):
            RUNNER["command"]([str(self.root / "missing-command")])
        self.assertEqual({sig: signal.getsignal(sig) for sig in handled}, previous)

    def test_pid_marker_is_published_after_contents_are_complete(self):
        self.prepare()
        # Execute the actual fake producer, gating its real file open after
        # creation but before write_text writes. The gate covers both the old
        # direct marker and the temporary sibling, without relying on sleeps.
        gate = r'''
import os, runpy, signal, sys
from pathlib import Path
signal.alarm(12)  # Outer safety net, not the synchronization mechanism.
real_open = Path.open
def gated_open(path, *args, **kwargs):
    handle = real_open(path, *args, **kwargs)
    mode = kwargs.get("mode", args[0] if args else "r")
    if "w" in mode and path.parent == Path(os.environ["CASE_ROOT"]) and path.name.startswith("xcode.pid"):
        print("marker-opened", flush=True)
        if sys.stdin.readline() != "publish\n":
            handle.close()
            raise RuntimeError("publication gate closed without release")
    return handle
Path.open = gated_open
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
'''
        process = subprocess.Popen(
            [sys.executable, "-c", gate, str(self.root / "bin/xcodebuild"),
             "test", "-resultBundlePath", str(self.root / "Tests.xcresult")],
            env=self.env, cwd=self.root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
        )
        try:
            self.assertTrue(select.select([process.stdout], [], [], 5)[0], "producer did not reach open gate")
            self.assertEqual(process.stdout.readline(), "marker-opened\n")
            marker = self.root / "xcode.pid"
            visible = marker.exists()
            contents = marker.read_text() if visible else None
            print(f"Publication gate: marker-visible={visible} contents={contents!r}", flush=True)
            self.assertFalse(visible, "PID readiness marker is visible before contents are written")
            stdout, stderr = process.communicate(input="publish\n", timeout=5)
            self.assertEqual(process.returncode, 0, stdout + stderr)
            # Use the owned Popen PID, never a PID parsed from an unready marker.
            self.assertEqual(marker.read_text(), str(process.pid))
            print(f"Publication complete: marker matches owned PID {process.pid}", flush=True)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=2)
            with self.assertRaises(ChildProcessError):
                os.waitpid(process.pid, os.WNOHANG)
            print(f"Publication producer reaped: owned PID {process.pid}", flush=True)

    def test_signal_stops_only_owned_cli_and_retains_result(self):
        self.faults["hang"] = True
        self.signal_during_xcodebuild()
        self.assert_no_simulator_mutation()

    def test_ci_signal_during_xcodebuild_still_deletes_the_simulator(self):
        self.ci()
        self.faults["hang"] = True
        self.signal_during_xcodebuild()
        self.assert_ephemeral_lifecycle(1)

    def signal_during_xcodebuild(self):
        self.prepare()
        process = subprocess.Popen(
            ["/bin/bash", str(self.root / "scripts/test-kit-ios.sh")],
            env=self.env, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        child = None
        try:
            deadline = time.monotonic() + 5
            marker = self.root / "xcode.pid"
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(marker.exists(), "fake xcodebuild did not start")
            child = int(marker.read_text())
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=8)
            self.assertEqual(process.returncode, 143, stdout + stderr)
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
            child = None
            self.assertEqual(len(list((self.root / ".build/kit-ios").glob("run.*/Tests.xcresult"))), 1)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=2)
            if child is not None:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    unittest.main()
