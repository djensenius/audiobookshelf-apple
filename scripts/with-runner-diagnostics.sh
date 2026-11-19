#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
  echo "usage: $0 command [arguments ...]" >&2
  exit 2
fi

snapshot() {
  echo "::group::Runner resources ($(date -u +'%Y-%m-%dT%H:%M:%SZ'))"
  collect memory_pressure memory_pressure
  collect vm_stat vm_stat
  collect df df -h /
  echo "::endgroup::"
}

collect() {
  local name=$1
  shift
  if "$@"; then
    return 0
  else
    local status=$?
    echo "::warning title=Runner telemetry failed::$name exited with status $status"
  fi
}

(
  while true; do
    snapshot
    sleep 60
  done
) &
monitor_pid=$!

cleanup() {
  status=$?
  trap - EXIT
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  snapshot
  exit "$status"
}
trap cleanup EXIT

"$@"
