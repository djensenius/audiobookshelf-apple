#!/usr/bin/env bash
# The package scheme, not the app scheme, contains ShakeDetectorTests.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec python3 "$(dirname "$0")/test-kit-ios.py"
