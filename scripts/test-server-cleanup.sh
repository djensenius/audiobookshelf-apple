#!/usr/bin/env bash
# Sourced by test-server.sh; no server is started here. Bash 3.2, no timeout dependency.
cleanup_command_timeout=5
cleanup_term_timeout=3
cleanup_kill_timeout=2
bounded_output=
: "${work:=}" "${container:=}" "${server_pid:=}"

# Consult this shell's child job table, including stopped jobs. Unlike an arbitrary kill -0,
# this cannot mistake a reused PID belonging to another process for our registered child.
owned_job_active() {
  local pid
  for pid in $(jobs -pr; jobs -ps); do
    if [[ "$pid" == "$1" ]]; then return 0; fi
  done
  return 1
}

wait_owned_job() {
  local pid=$1 deadline=$((SECONDS + $2))
  while owned_job_active "$pid"; do
    ((SECONDS < deadline)) || return 1
    sleep 0.1
  done
}

# Bound CLI execution AND output collection. A private, immediately unlinked FIFO avoids
# command-substitution pipes that can stay open forever when a command cannot be killed.
# Never wait on an active child. If even KILL cannot be verified, report its exact PID.
bounded_command() {
  local deadline=$((SECONDS + $1)) fifo="$work/.cleanup-pipe-$$" pid status=0 line
  shift
  bounded_output=
  mkfifo -m 600 "$fifo" || return 1
  if ! exec 9<>"$fifo"; then rm -f "$fifo"; return 1; fi
  if ! rm -f "$fifo"; then exec 9<&-; return 1; fi
  "$@" >&9 2>&9 &
  pid=$!
  while owned_job_active "$pid"; do
    if ((SECONDS >= deadline)); then
      status=124
      kill -KILL "$pid" 2>/dev/null || true
      if ! wait_owned_job "$pid" "$cleanup_kill_timeout"; then
        log "Cleanup command still unverified: PID=$pid command=$1; retain $work"
        exec 9<&-
        return 124
      fi
      break
    fi
    line=
    IFS= read -r -t 1 line <&9 || true
    if [[ -n "$line" ]]; then bounded_output+="$line"$'\n'; fi
  done
  # The job is no longer active; wait only retrieves its already available exit status.
  wait "$pid" || status=$?
  # Drain bounded output (Docker inventory is one line; diagnostic logs request only 40).
  deadline=$((SECONDS + 1))
  while ((SECONDS < deadline)); do
    line=
    IFS= read -r -t 1 line <&9 || true
    if [[ -n "$line" ]]; then bounded_output+="$line"$'\n'; else break; fi
  done
  exec 9<&-
  if ((status != 0)); then
    log "Cleanup command failed: PID=$pid command=$1 status=$status"
  fi
  return "$status"
}

stop_owned_docker() {
  # A name is not sufficient shutdown authorization. Docker writes this exact ID before start.
  [[ "$container" =~ ^[0-9a-f]{64}$ ]] || return 1
  if ! bounded_command "$cleanup_command_timeout" docker rm -f "$container"; then
    log "Could not remove owned container ID=$container: $bounded_output"
    return 1
  fi
  # A failed inspect cannot distinguish absence from an unavailable daemon. Only a successful
  # inventory query with no matching full ID proves removal.
  if ! bounded_command "$cleanup_command_timeout" docker container ls --all --no-trunc \
    --filter "id=$container" --format '{{.ID}}'; then
    log "Could not verify owned container ID=$container: $bounded_output"
    return 1
  fi
  if [[ -n "$bounded_output" ]]; then
    log "Owned container ID=$container remains or inventory is unexpected: $bounded_output"
    return 1
  fi
  log "Verified owned container removed: ID=$container"
}

stop_owned_node() {
  if owned_job_active "$server_pid"; then
    kill -TERM "$server_pid" 2>/dev/null || true
    if ! wait_owned_job "$server_pid" "$cleanup_term_timeout"; then
      log "Owned server PID=$server_pid did not stop after TERM; sending KILL"
      kill -KILL "$server_pid" 2>/dev/null || true
      if ! wait_owned_job "$server_pid" "$cleanup_kill_timeout"; then
        log "Owned server stop unverified: PID=$server_pid"
        return 1
      fi
    fi
  fi
  # Includes an already exited/reaped child. Its exit code is not the test body's exit code.
  wait "$server_pid" 2>/dev/null || true
  log "Verified owned server exited: PID=$server_pid"
}
