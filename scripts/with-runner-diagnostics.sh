#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
  echo "usage: $0 command [arguments ...]" >&2
  exit 2
fi

snapshot() {
  echo "::group::Runner resources ($(date -u +'%Y-%m-%dT%H:%M:%SZ'))"
  memory_pressure
  vm_stat
  df -h /
  echo "::endgroup::"
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
