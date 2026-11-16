#!/usr/bin/env python3
"""Reads UI-test results for scripts/ui-test-ci.sh's targeted retry (#666).

  ui-test-results.py failed --max N TESTS SELECTED  prints the failed tests to run again, one
                                                    -only-testing identifier per line
  ui-test-results.py passed TESTS RETRIED           checks the run of those tests passed

TESTS is `xcrun xcresulttool get test-results tests --schema-version 0.5.0` output (Xcode 27.2),
SELECTED is `xcodebuild -enumerate-tests -test-enumeration-format json -test-enumeration-style
flat` output, and RETRIED is what `failed` printed. Either fails (exit 1, with the reason) for
anything it doesn't expect, so a misread report never turns into a retry or a pass.
"""

import json
import re
import sys


BUNDLES = ("UI test bundle", "Unit test bundle")
# A test case's final result. A test that failed and then passed in-process retry
# (-retry-tests-on-failure) is "Passed", with a failed "Repetition" child.
RESULTS = ("Passed", "Failed", "Skipped", "Expected Failure")
NAME = r"[A-Za-z_][A-Za-z0-9_]*"


def test_cases(report):
    """{"<bundle>/<class>/<method>()": result} for every test case, as -enumerate-tests names them.

    Raises ValueError for a failure that isn't a test case's (a failure message, or a failed
    bundle or class with no failed test case), an unknown result, or a tree this doesn't expect.
    """
    if len(report["devices"]) != 1:
        raise ValueError(f"Expected results from one device, got {len(report['devices'])}")
    cases = {}

    def visit(node, path):
        kind, name = node["nodeType"], node["name"]
        if kind == "Test Case":
            result = node.get("result")
            if len(path) != 2 or not re.fullmatch(NAME + r"\(\)", name):
                raise ValueError(f"Unexpected test case {name!r} in {'/'.join(path) or 'no class'}")
            if result not in RESULTS:
                raise ValueError(f"{'/'.join(path)}/{name} has result {result!r}")
            identifier = "/".join([*path, name])
            if identifier in cases:
                raise ValueError(f"{identifier} appears twice")
            cases[identifier] = result
            return result == "Failed"
        if kind == "Test Plan" and path == []:
            inner = path
        elif (kind in BUNDLES and path == []) or (kind == "Test Suite" and len(path) == 1):
            if not re.fullmatch(NAME, name):
                raise ValueError(f"Unexpected {kind} name {name!r}")
            inner = [*path, name]
        else:
            # For example a "Failure Message" on a class or bundle: a failure outside a test.
            raise ValueError(f"Unexpected {kind} {name!r} in {'/'.join(path) or 'the test plan'}")
        failed = False
        for child in node.get("children", []):
            failed = visit(child, inner) or failed
        if node.get("result") == "Failed" and not failed:
            raise ValueError(f"{kind} {name!r} failed, but none of its tests did")
        return failed

    for node in report["testNodes"]:
        visit(node, [])
    return cases


def selected_tests(enumeration):
    """The identifiers of the tests a run selected, from xcodebuild -enumerate-tests."""
    if enumeration["errors"] != []:
        raise ValueError(f"Test enumeration reported errors: {enumeration['errors']}")
    tests = [test["identifier"] for value in enumeration["values"] for test in value["enabledTests"]]
    if not tests or len(set(tests)) != len(tests):
        raise ValueError("Test enumeration listed no tests, or a test twice")
    return set(tests)


def failed_tests(report, enumeration, limit):
    """The -only-testing identifiers of the failed tests, if the run's only failures are 1 to `limit` tests.

    Every selected test must have a result, so a run that stopped early isn't retried as if the
    tests that never ran had passed.
    """
    cases = test_cases(report)
    selected = selected_tests(enumeration)
    missing, unknown = sorted(selected - set(cases)), sorted(set(cases) - selected)
    if missing or unknown:
        raise ValueError(f"The results don't match the selected tests: {len(missing)} without a result "
                         f"{missing[:3]}, {len(unknown)} not selected {unknown[:3]}")
    failed = [identifier for identifier, result in cases.items() if result == "Failed"]
    if not failed:
        raise ValueError("No test failed, so the run failed for another reason")
    if len(failed) > limit:
        raise ValueError(f"{len(failed)} tests failed, more than the {limit} that are run again")
    return [identifier[:-2] for identifier in failed]


def verify_passed(report, retried):
    """Raises ValueError unless the run ran exactly the `retried` tests and each passed."""
    cases = test_cases(report)
    expected = {identifier + "()" for identifier in retried}
    if not retried or set(cases) != expected:
        raise ValueError(f"Expected results for {sorted(expected)}, got {sorted(cases)}")
    others = [f"{identifier}: {result}" for identifier, result in sorted(cases.items()) if result != "Passed"]
    if others:
        raise ValueError(f"Not passed when run again: {others}")
    for identifier in sorted(cases):
        print(f"Passed when run again: {identifier}")


def read_json(path):
    with open(path) as file:
        return json.load(file)


def main(args):
    if len(args) == 5 and args[:2] == ["failed", "--max"] and re.fullmatch(r"[1-9][0-9]*", args[2]):
        for identifier in failed_tests(read_json(args[3]), read_json(args[4]), int(args[2])):
            print(identifier)
    elif len(args) == 3 and args[0] == "passed":
        with open(args[2]) as file:
            retried = file.read().splitlines()
        verify_passed(read_json(args[1]), retried)
    else:
        raise ValueError(f"Usage: failed --max N TESTS SELECTED | passed TESTS RETRIED; got {args}")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, KeyError, TypeError, AttributeError, OSError) as error:
        print(f"error: UI test results: {error}", file=sys.stderr)
        sys.exit(1)
