#!/usr/bin/env bash
# CI's UI-test run (#666): `mise run test:ui` (ABS_UI_PLATFORM picks the platform), then one more
# run of only the tests that failed, if there are at most three.
#
# The first run retries a failed test once in the same test runner (-retry-tests-on-failure
# -test-iterations 2) and fails a test still running after 600 s (#661). XCTest stops that test
# by ending the runner, as a crash does, and an in-runner retry can't repeat it, so it fails
# there. -test-repetition-relaunch-enabled would retry it, but also reran the whole suite after
# one flaky failure (#666).
#
# So if the first run fails, every test it selected has a result, and its only failures are one
# to three tests, those tests run once more without building, and that run decides: it passes
# only if each of them ran and passed. Any other failure (a build error, a crash outside a test,
# tests that never ran, more failures, results this can't read) fails without another run.
#
# Arguments go to the first run, for example -only-testing:<id> to try this on part of the
# suite. Result bundles and the lists of tests are left in .build/ui-tests/.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Never start another run after a cancellation.
trap 'exit 130' INT
trap 'exit 143' TERM

max_retried=3
out=.build/ui-tests
limits=(-test-timeouts-enabled YES -default-test-execution-time-allowance 600 -maximum-test-execution-time-allowance 600)

# xcodebuild won't write a result bundle over an existing one.
rm -rf "$out"
mkdir -p "$out"

status=0
mise run test:ui -- -resultBundlePath "$out/first.xcresult" -retry-tests-on-failure -test-iterations 2 \
  "${limits[@]}" "$@" || status=$?
if ((status == 0)); then
  exit 0
fi

no_retry() {
  echo "error: UI tests failed (exit $status), and aren't run again: $1" >&2
  exit "$status"
}

echo "UI tests failed (exit $status); checking whether at most $max_retried tests failed, to run them again"
results() {
  xcrun xcresulttool get test-results tests --schema-version 0.5.0 --path "$1" --compact
}
results "$out/first.xcresult" >"$out/first.json" || no_retry "couldn't read $out/first.xcresult"
ABS_UI_ACTION=test-without-building mise run test:ui -- -enumerate-tests -test-enumeration-format json \
  -test-enumeration-style flat -test-enumeration-output-path "$out/selected.json" "$@" ||
  no_retry "couldn't list the tests the first run selected"
python3 scripts/ui-test-results.py failed --max "$max_retried" "$out/first.json" "$out/selected.json" \
  >"$out/retried.txt" || no_retry "see the error above"

only=()
names=
while IFS= read -r test; do
  only+=("-only-testing:$test")
  names+=" $test"
done <"$out/retried.txt"
if ((${#only[@]} == 0)); then
  no_retry "no failed tests listed"
fi

echo "Running the ${#only[@]} failed test(s) once more, without building:"
cat "$out/retried.txt"
ABS_UI_ACTION=test-without-building mise run test:ui -- -resultBundlePath "$out/retried.xcresult" \
  "${limits[@]}" "${only[@]}"
results "$out/retried.xcresult" >"$out/retried.json"
python3 scripts/ui-test-results.py passed "$out/retried.json" "$out/retried.txt"
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  echo "::warning title=UI tests passed when run again::Failed, then passed when run again:$names"
fi
