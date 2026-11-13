#!/usr/bin/env python3
"""Narrow iOS package gate.

Locally it borrows an existing iPhone simulator without creating, erasing, deleting
or shutting one down. In CI (`CI=true`) or with `ABS_EPHEMERAL_SIMULATOR=1`, and no
`IOS_SIMULATOR_ID`, it creates its own `abs-ci-*` simulator and always deletes it,
because concurrent runner instances share one CoreSimulator device set.

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
import threading
import time


ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Packages/AudiobookshelfKit"
METHODS = {
    "aDetectorStopsItsOwnUpdates()",
    "stoppingAnEarlierDetectorLeavesTheLaterOneRunning()",
    "releasingAnEarlierDetectorLeavesTheLaterOneRunning()",
    "releasingARunningDetectorStopsItsUpdates()",
}
UDID = r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"
HANDLED_SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
# CoreSimulator/XCTest failures that a fresh simulator can fix; a test failure never matches.
INFRASTRUCTURE_FAILURES = (
    "failed to bless service hub",
    "hung before establishing connection",
    "Unable to boot",
)


class InterruptedRunner(Exception):
    def __init__(self, signum):
        self.signum = signum


def interrupted(signum, _frame):
    raise InterruptedRunner(signum)


def command(args, *, capture=False, tee=False, timeout=60):
    """Run a bounded child; `tee` streams stdout and stderr to stdout and also returns them."""
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
            stdout=subprocess.PIPE if capture or tee else None,
            stderr=subprocess.STDOUT if tee else None,
        )
        lines = []
        if tee:
            reader = threading.Thread(target=echo, args=(process.stdout, lines), daemon=True)
            reader.start()
        try:
            deadline = time.monotonic() + timeout
            interval = min(timeout, 0.1)
            while True:
                if pending:
                    raise pending[0]
                try:
                    if tee:
                        process.wait(timeout=interval)
                        # A lingering grandchild may hold the pipe; don't wait on it forever.
                        reader.join(timeout=5)
                        output = "".join(lines)
                    else:
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
        raise subprocess.CalledProcessError(process.returncode, args, output=output if tee else None)
    return output


def echo(stream, lines):
    for line in stream:
        sys.stdout.write(line)
        sys.stdout.flush()
        lines.append(line)


def version(value):
    parts = tuple(int(part) for part in value.split("."))
    return (parts + (0, 0, 0))[:3]


def select_destination(devices, runtimes, minimum, explicit):
    return select_device(devices, runtimes, minimum, explicit)["udid"]


def select_device(devices, runtimes, minimum, explicit):
    """The selected simulator's UDID, device type and runtime identifiers."""
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
            if not re.fullmatch(UDID, udid):
                raise ValueError(f"Malformed simulator UDID: {udid!r}")
            # Newest available runtime, then already booted, then device type/UDID.
            key = (tuple(-part for part in version(runtime["version"])),
                   device["state"] != "Booted", device["deviceTypeIdentifier"], udid)
            candidates.append((key, {"udid": udid, "deviceTypeIdentifier": device["deviceTypeIdentifier"],
                                     "runtimeIdentifier": runtime["identifier"]}))
    if explicit is not None:
        for _, selected in candidates:
            if selected["udid"].lower() == explicit.lower():
                return selected
        raise ValueError("IOS_SIMULATOR_ID must identify an available, compatible iPhone; no fallback")
    if not candidates:
        raise ValueError("No available iPhone meets the package's iOS minimum; provision one in Xcode")
    return min(candidates, key=lambda candidate: candidate[0])[1]


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


def test_scheme(listing):
    """The scheme with the package's test action, from `xcodebuild -list -json` in the package.

    Xcode names it after the only product when the manifest has one; with more (the widget's
    AudiobookshelfWidgetKit), the per-product schemes can't test and it is `<package>-Package`.
    """
    schemes = listing["workspace"]["schemes"]
    for name in ("AudiobookshelfKit-Package", "AudiobookshelfKit"):
        if name in schemes:
            return name
    raise ValueError(f"No AudiobookshelfKit test scheme in: {schemes}")


def ephemeral_requested(environ):
    """CI, or an explicit opt-in, gets its own simulator unless IOS_SIMULATOR_ID picks one."""
    if "IOS_SIMULATOR_ID" in environ:
        return False
    flag = environ.get("ABS_EPHEMERAL_SIMULATOR")
    if flag in ("0", "1"):
        return flag == "1"
    return environ.get("CI") == "true"


def run_prefix(environ):
    """`abs-ci-<run>-<attempt>-`; the workflow's cleanup step deletes by this prefix."""
    parts = [environ.get("GITHUB_RUN_ID") or "local", environ.get("GITHUB_RUN_ATTEMPT") or "1"]
    return "abs-ci-" + "".join(re.sub(r"[^A-Za-z0-9-]", "-", part) + "-" for part in parts)


def ephemeral_name(environ, attempt):
    name = f"{run_prefix(environ)}{os.getpid()}-{attempt}"
    if not re.fullmatch(r"abs-ci-[A-Za-z0-9-]+", name) or len(name) > 100:
        raise ValueError(f"Invalid ephemeral simulator name: {name!r}")
    return name


class SimulatorInfrastructureError(Exception):
    """xcodebuild failed with a known CoreSimulator/XCTest signature, not a test failure."""

    def __init__(self, error):
        self.error = error


def protected(args, timeout=120):
    """Run simctl so a cancellation can't tear a create or delete in half.

    The child runs in its own session (no group SIGINT), and signals that reach this
    process are recorded and returned rather than raised.
    """
    pending = []
    previous = {}
    try:
        for sig in HANDLED_SIGNALS:
            previous[sig] = signal.getsignal(sig)
            signal.signal(sig, lambda signum, _frame: pending.append(signum))
        try:
            result = subprocess.run(args, cwd=PACKAGE, text=True, capture_output=True,
                                    timeout=timeout, start_new_session=True)
        except (OSError, subprocess.TimeoutExpired) as error:
            return None, str(error), pending
        if result.returncode:
            return None, result.stderr.strip() or f"exit {result.returncode}", pending
        return result.stdout, None, pending
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def delete_simulator(device):
    """Shut down and delete one owned simulator; returns success and signals received meanwhile."""
    _, _, pending = protected(["xcrun", "simctl", "shutdown", device])  # Fails if not booted.
    _, error, more = protected(["xcrun", "simctl", "delete", device])
    if error is None:
        print(f"Deleted ephemeral simulator {device}", flush=True)
    else:
        print(f"warning: couldn't delete ephemeral simulator {device}: {error}", file=sys.stderr, flush=True)
    return error is None, pending + more


def with_ephemeral_simulator(selected, name, run):
    """Create, boot and run on a new simulator like `selected`, then always delete it."""
    target = None
    completed = False
    try:
        target = name  # simctl create may succeed even if its output is lost.
        output, error, pending = protected([
            "xcrun", "simctl", "create", name,
            selected["deviceTypeIdentifier"], selected["runtimeIdentifier"],
        ])
        if output is not None and re.fullmatch(UDID, output.strip()):
            target = output.strip()
        if pending:
            raise InterruptedRunner(pending[0])
        if error is not None:
            target = None
            raise ValueError(f"simctl create {name} failed: {error}")
        if target == name:
            raise ValueError(f"simctl create returned a malformed UDID: {output!r}")
        print(f"Created ephemeral iPhone simulator {name} ({target}); it will be deleted after the run.",
              flush=True)
        command(["xcrun", "simctl", "bootstatus", target, "-b"], timeout=300)
        result = run(target, name)
        completed = True
        return result
    finally:
        if target is not None:
            _, pending = delete_simulator(target)
            if completed and pending:
                raise InterruptedRunner(pending[0])


def run_tests(scheme, udid, simulator_name=None):
    parent = ROOT / ".build/kit-ios"
    parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="run.", dir=parent))
    result = work / "Tests.xcresult"  # Must not exist before xcodebuild.
    if simulator_name is None:
        print(f"Borrowing iPhone simulator {udid}; it will not be erased, deleted or shut down.", flush=True)
    print(f"Retaining iOS package test evidence and owned derived data: {work}", flush=True)
    destination = {"udid": udid, "developerDir": os.environ["DEVELOPER_DIR"]}
    if simulator_name is not None:
        destination["ephemeralName"] = simulator_name
    (work / "destination.json").write_text(json.dumps(destination))
    try:
        command([
            "xcodebuild", "test", "-scheme", scheme,
            "-destination", f"platform=iOS Simulator,id={udid}", "-destination-timeout", "60",
            "-only-testing:ABSPlaybackTests/ShakeDetectorTests",
            "-derivedDataPath", str(work / "DerivedData"), "-resultBundlePath", str(result),
            "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
            "-jobs", "2", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "60",
            "CODE_SIGNING_ALLOWED=NO",
        ], tee=simulator_name is not None, timeout=1200)
    except subprocess.CalledProcessError as error:
        if error.output and any(signature in error.output for signature in INFRASTRUCTURE_FAILURES):
            raise SimulatorInfrastructureError(error) from error
        raise

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


def delete_run_simulators(environ):
    """Workflow safety net: delete this run attempt's `abs-ci-*` simulators, if any."""
    if not environ.get("GITHUB_RUN_ID") or not environ.get("GITHUB_RUN_ATTEMPT"):
        raise ValueError("--delete-run-simulators needs GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT")
    prefix = run_prefix(environ)
    devices = json.loads(command(["xcrun", "simctl", "list", "-j", "devices"], capture=True))
    owned = sorted(
        device["udid"] for group in devices["devices"].values() for device in group
        if device["name"].startswith(prefix) and re.fullmatch(UDID, device["udid"])
    )
    print(f"{len(owned)} simulator(s) named {prefix}*", flush=True)
    deleted = [delete_simulator(udid)[0] for udid in owned]
    if not all(deleted):
        raise ValueError(f"Couldn't delete every {prefix}* simulator")


def main():
    if sys.argv[1:] == ["--delete-run-simulators"]:
        delete_run_simulators(os.environ)
        return
    if sys.argv[1:]:
        raise ValueError(f"Unknown arguments: {sys.argv[1:]}")
    # Read the deployment minimum without invoking SwiftPM or resolving packages.
    minimums = re.findall(r"\.iOS\(\.v(\d+(?:_\d+)*)\)", (PACKAGE / "Package.swift").read_text())
    if len(minimums) != 1:
        raise ValueError("Cannot determine the package iOS minimum")
    devices = json.loads(command(["xcrun", "simctl", "list", "-j", "devices", "available"], capture=True))
    runtimes = json.loads(command(["xcrun", "simctl", "list", "-j", "runtimes"], capture=True))
    selected = select_device(devices, runtimes, version(minimums[0].replace("_", ".")),
                             os.environ.get("IOS_SIMULATOR_ID"))

    scheme = test_scheme(json.loads(command(["xcodebuild", "-list", "-json"], capture=True, timeout=300)))

    if not ephemeral_requested(os.environ):
        run_tests(scheme, selected["udid"])
        return
    # One retry, on a fresh simulator, only for a known infrastructure signature.
    for attempt in (1, 2):
        name = ephemeral_name(os.environ, attempt)
        try:
            with_ephemeral_simulator(selected, name, lambda udid, name: run_tests(scheme, udid, name))
            return
        except SimulatorInfrastructureError as failure:
            if attempt == 2:
                raise failure.error from None
            print("warning: simulator infrastructure failure; retrying once on a fresh simulator",
                  file=sys.stderr, flush=True)


if __name__ == "__main__":
    for sig in HANDLED_SIGNALS:
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
