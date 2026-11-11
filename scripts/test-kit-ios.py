#!/usr/bin/env python3
"""Narrow iOS package gate; no simulator creation or destructive cleanup.

Result fields/enums come from Xcode 27.2's installed xcresulttool
`get test-results {summary,tests} --schema` (schema version 0.5.0).
Keep the four-method allowlist strict: this is not all iOS package coverage.
"""

import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Packages/AudiobookshelfKit"
METHODS = {
    "aDetectorStopsItsOwnUpdates()",
    "stoppingAnEarlierDetectorLeavesTheLaterOneRunning()",
    "releasingAnEarlierDetectorLeavesTheLaterOneRunning()",
    "releasingARunningDetectorStopsItsUpdates()",
}


class InterruptedRunner(Exception):
    def __init__(self, signum):
        self.signum = signum


def interrupted(signum, _frame):
    raise InterruptedRunner(signum)


def command(args, *, capture=False, timeout=60):
    pending = []
    previous = {}

    def defer(signum, _frame):
        if not pending:
            pending.append(InterruptedRunner(signum))

    # Never raise asynchronously while acquiring or cleaning up the child.
    # Recording (rather than masking) signals leaves the child's signal mask
    # untouched. Bounded communicate slices make cancellation responsive.
    try:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[sig] = signal.getsignal(sig)
            signal.signal(sig, defer)
        process = subprocess.Popen(
            args, cwd=PACKAGE, text=True,
            stdout=subprocess.PIPE if capture else None,
        )
        try:
            deadline = time.monotonic() + timeout
            interval = min(timeout, 0.1)
            while True:
                if pending:
                    raise pending[0]
                try:
                    output, _ = process.communicate(timeout=interval)
                    break
                except subprocess.TimeoutExpired as error:
                    if pending:
                        raise pending[0]
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        error.timeout = timeout
                        raise
                    interval = min(remaining, 0.1)
        except BaseException:
            # Further handled signals cannot interrupt this exact-child cleanup
            # or replace the original signal/deadline exception.
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            raise
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    if pending:
        raise pending[0]
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, args)
    return output


def version(value):
    parts = tuple(int(part) for part in value.split("."))
    return (parts + (0, 0, 0))[:3]


def select_destination(devices, runtimes, minimum, explicit):
    candidates = []
    for runtime in runtimes["runtimes"]:
        if not (runtime["isAvailable"] is True
                and runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
                and version(runtime["version"]) >= minimum):
            continue
        iphone_types = {
            device_type["identifier"]
            for device_type in runtime["supportedDeviceTypes"]
            if device_type["productFamily"] == "iPhone"
        }
        for device in devices["devices"].get(runtime["identifier"], []):
            if device["isAvailable"] is not True or device["deviceTypeIdentifier"] not in iphone_types:
                continue
            udid = device["udid"]
            if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", udid):
                raise ValueError(f"Malformed simulator UDID: {udid!r}")
            # Newest available runtime, then already booted, then device type/UDID.
            key = (tuple(-part for part in version(runtime["version"])),
                   device["state"] != "Booted", device["deviceTypeIdentifier"], udid)
            candidates.append((key, udid))
    if explicit is not None:
        for _, udid in candidates:
            if udid.lower() == explicit.lower():
                return udid
        raise ValueError("IOS_SIMULATOR_ID must identify an available, compatible iPhone; no fallback")
    if not candidates:
        raise ValueError("No available iPhone meets the package's iOS minimum; provision one in Xcode")
    return min(candidates)[1]


def verify_results(summary, tests, udid):
    for field, expected in {
        "result": "Passed", "totalTestCount": 4, "passedTests": 4,
        "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
    }.items():
        if summary.get(field) != expected:
            raise ValueError(f"Result summary {field}: expected {expected!r}, got {summary.get(field)!r}")
    if summary.get("testFailures") != []:
        raise ValueError("Result summary has failures or missing failure evidence")
    if [device["deviceId"] for device in tests["devices"]] != [udid]:
        raise ValueError("Test evidence does not match the selected simulator")

    seen = []

    def visit(node, bundle=False, suite=False):
        if "result" in node and node["result"] != "Passed":
            raise ValueError(f"Non-passing test node: {node['name']}: {node['result']}")
        if node["nodeType"] == "Unit test bundle":
            bundle = node["name"] in ("ABSPlaybackTests", "ABSPlaybackTests.xctest")
        if node["nodeType"] == "Test Suite":
            suite = node["name"] == "ShakeDetectorTests"
        if node["nodeType"] == "Test Case":
            if not (bundle and suite and node["name"] in METHODS and node.get("result") == "Passed"):
                raise ValueError(f"Unexpected or non-passing test case: {node['name']}")
            seen.append(node["name"])
        for child in node.get("children", []):
            visit(child, bundle, suite)

    for node in tests["testNodes"]:
        visit(node)
    if len(seen) != 4 or set(seen) != METHODS:
        raise ValueError(f"Expected all four ShakeDetector methods exactly once, got: {seen}")
    for name in sorted(seen):
        print(f"Verified Passed: ABSPlaybackTests/ShakeDetectorTests/{name}")


def main():
    # Read the deployment minimum without invoking SwiftPM or resolving packages.
    minimums = re.findall(r"\.iOS\(\.v(\d+(?:_\d+)*)\)", (PACKAGE / "Package.swift").read_text())
    if len(minimums) != 1:
        raise ValueError("Cannot determine the package iOS minimum")
    devices = json.loads(command(["xcrun", "simctl", "list", "-j", "devices", "available"], capture=True))
    runtimes = json.loads(command(["xcrun", "simctl", "list", "-j", "runtimes"], capture=True))
    udid = select_destination(devices, runtimes, version(minimums[0].replace("_", ".")),
                              os.environ.get("IOS_SIMULATOR_ID"))

    parent = ROOT / ".build/kit-ios"
    parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="run.", dir=parent))
    result = work / "Tests.xcresult"  # Must not exist before xcodebuild.
    print(f"Borrowing iPhone simulator {udid}; it will not be erased, deleted or shut down.", flush=True)
    print(f"Retaining iOS package test evidence and owned derived data: {work}", flush=True)
    (work / "destination.json").write_text(json.dumps({"udid": udid, "developerDir": os.environ["DEVELOPER_DIR"]}))
    command([
        "xcodebuild", "test", "-scheme", "AudiobookshelfKit",
        "-destination", f"platform=iOS Simulator,id={udid}", "-destination-timeout", "60",
        "-only-testing:ABSPlaybackTests/ShakeDetectorTests",
        "-derivedDataPath", str(work / "DerivedData"), "-resultBundlePath", str(result),
        "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
        "-jobs", "2", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "60",
        "CODE_SIGNING_ALLOWED=NO",
    ], timeout=1200)

    reports = {}
    for kind in ("summary", "tests"):
        raw = command([
            "xcrun", "xcresulttool", "get", "test-results", kind,
            "--schema-version", "0.5.0", "--path", str(result), "--compact",
        ], capture=True)
        (work / f"{kind}.json").write_text(raw)
        reports[kind] = json.loads(raw)
    verify_results(reports["summary"], reports["tests"], udid)
    print("Verified 4/4 iOS ShakeDetector tests passed (not all iOS package tests).")


if __name__ == "__main__":
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        main()
    except InterruptedRunner as error:
        print(f"error: iOS package runner interrupted by signal {error.signum}", file=sys.stderr)
        sys.exit(128 + error.signum)
    except subprocess.CalledProcessError as error:
        print(f"error: command failed ({error.returncode}): {error.cmd}", file=sys.stderr)
        sys.exit(error.returncode if error.returncode > 0 else 128 - error.returncode)
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"error: iOS package tests: {error}", file=sys.stderr)
        sys.exit(1)
