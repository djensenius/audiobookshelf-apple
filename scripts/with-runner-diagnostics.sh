#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
  echo "usage: $0 command [arguments ...]" >&2
  exit 2
fi

snapshot() {
  echo "::group::Runner resources ($(date -u +'%Y-%m-%dT%H:%M:%SZ'))"
  snapshot_group_open=true
  collect memory_pressure memory_pressure
  collect vm_stat vm_stat
  collect df df -h /
  echo "::endgroup::"
  snapshot_group_open=false
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
snapshot_group_open=false
command_pid=
monitor_pid=

# shellcheck disable=SC2329
stop_monitor() {
  if [[ -n "$monitor_child_pid" ]]; then
    kill "$monitor_child_pid" 2>/dev/null || true
    wait "$monitor_child_pid" 2>/dev/null || true
  fi
  if [[ "$snapshot_group_open" == true ]]; then
    echo "::endgroup::"
    snapshot_group_open=false
  fi
  exit 0
}

monitor() {
  trap stop_monitor TERM INT
  while true; do
    sleep 60 &
    monitor_child_pid=$!
    if wait "$monitor_child_pid"; then
      monitor_child_pid=
    else
      monitor_child_pid=
      echo "::warning title=Runner telemetry failed::sleep exited before the next snapshot"
      exit 0
    fi
    snapshot
  done
}

# shellcheck disable=SC2329
finish() {
  local status=$1
  trap - EXIT
  trap '' INT TERM
  if [[ -n "$command_pid" ]]; then
    kill -TERM "$command_pid" 2>/dev/null || true
    wait "$command_pid" 2>/dev/null || true
    command_pid=
  fi
  if [[ -n "$monitor_child_pid" ]]; then
    kill "$monitor_child_pid" 2>/dev/null || true
    wait "$monitor_child_pid" 2>/dev/null || true
    monitor_child_pid=
  fi
  if [[ -n "$monitor_pid" ]]; then
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    monitor_pid=
  fi
  if [[ "$snapshot_group_open" == true ]]; then
    echo "::endgroup::"
    snapshot_group_open=false
  fi
  snapshot
  exit "$status"
}
# shellcheck disable=SC2329
handle_signal() {
  local signal=$1
  local status=$2
  trap '' INT TERM
  if [[ -n "$command_pid" ]]; then
    kill -s "$signal" "$command_pid" 2>/dev/null || true
    wait "$command_pid" 2>/dev/null || true
    command_pid=
  fi
  exit "$status"
}
trap 'finish "$?"' EXIT
trap 'handle_signal TERM 143' TERM
trap 'handle_signal INT 130' INT

snapshot
monitor &
monitor_pid=$!

# Keep SIGINT deliverable to the asynchronous command.
set -m
"$@" &
command_pid=$!
if wait "$command_pid"; then
  command_status=0
else
  command_status=$?
fi
command_pid=
exit "$command_status"
