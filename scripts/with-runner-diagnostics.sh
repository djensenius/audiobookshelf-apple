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
  "$@" &
  monitor_child_pid=$!
  if wait "$monitor_child_pid"; then
    monitor_child_pid=
  else
    local status=$?
    monitor_child_pid=
    echo "::warning title=Runner telemetry failed::$name exited with status $status"
  fi
}

monitor_child_pid=
stop_monitor() {
  if [[ -n "$monitor_child_pid" ]]; then
    kill "$monitor_child_pid" 2>/dev/null || true
    wait "$monitor_child_pid" 2>/dev/null || true
  fi
  exit 0
}

monitor() {
  trap stop_monitor TERM INT
  while true; do
    snapshot
    sleep 60 &
    monitor_child_pid=$!
    if wait "$monitor_child_pid"; then
      monitor_child_pid=
    else
      monitor_child_pid=
      echo "::warning title=Runner telemetry failed::sleep exited before the next snapshot"
      exit 0
    fi
  done
}
monitor &
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
