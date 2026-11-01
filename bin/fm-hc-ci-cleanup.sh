#!/usr/bin/env bash
# fm-hc-ci-cleanup.sh - bounded cleanup of CI-owned herdr-core (`hc`) lab
# sessions.
#
# Snapshot the lab session inventory before the real-hc suite, then at job
# end only stop/remove session directories that:
#   1. match the guarded fm-hclab-* name pattern under the lab root,
#   2. were not present in the pre-suite snapshot (job-proven ownership).
#
# bin/fm-hc-lab.sh owns the session directory and socket layout.
# Cleanup requests `hc server stop` under the session's own pinned env, then
# sweeps its session-marked processes before removing its directory and sockets.
# Unlike normal lab teardown, this job-end fallback does not verify the fleet
# tripwire, so it is not evidence that real-core state stayed unchanged.
#
# A missing binary skips only the stop request; process and file cleanup
# still run. Surviving session processes or directory-removal failures exit
# non-zero.
#
# Usage:
#   fm-hc-ci-cleanup.sh snapshot <path>
#   fm-hc-ci-cleanup.sh teardown <snapshot-path>
set -eu

die() {
  printf 'fm-hc-ci-cleanup.sh: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'fm-hc-ci-cleanup.sh: %s\n' "$*" >&2
}

LAB_DIR=${FM_HC_LAB_DIR:-${TMPDIR:-/tmp}/fm-hc-lab-${UID}}
SOCK_DIR=${FM_HC_LAB_SOCK_DIR:-/tmp/fm-hc-lab-${UID}}

cmd=${1:-}
path=${2:-}
[ -n "$cmd" ] && [ -n "$path" ] || die "usage: fm-hc-ci-cleanup.sh snapshot|teardown <path>"

is_lab_name() {
  local name=$1
  [[ "$name" =~ ^fm-hclab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]
}

# One basename per directory, computed in the shell so the inventory does not
# depend on multi-operand basename (BSD/GNU differ). A find failure is a real
# error, never an empty list.
list_lab_names() {
  local found d
  [ -d "$LAB_DIR" ] || return 0
  found=$(find "$LAB_DIR" -mindepth 1 -maxdepth 1 -type d -name 'fm-hclab-*' -print) || return 1
  [ -n "$found" ] || return 0
  printf '%s\n' "$found" | while IFS= read -r d; do
    printf '%s\n' "${d##*/}"
  done | LC_ALL=C sort
}

# hc_ci_stop: `hc server stop` under the lab session's own pinned env,
# resolving the binary exactly like bin/fm-hc-lab.sh (FM_HC_BIN, then
# herdr-core, then hc). A missing binary is a no-op.
hc_ci_stop() {  # <name> <dir> <sock>
  local name=$1 dir=$2 sock=$3 bin=''
  if [ -n "${FM_HC_BIN:-}" ] && [ -x "$FM_HC_BIN" ]; then
    bin=$FM_HC_BIN
  elif command -v herdr-core >/dev/null 2>&1; then
    bin=$(command -v herdr-core)
  elif command -v hc >/dev/null 2>&1; then
    bin=$(command -v hc)
  fi
  [ -n "$bin" ] || return 0
  ( unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SESSION HC_SOCKET
    XDG_STATE_HOME="$dir/env/xdg-state" \
    XDG_CONFIG_HOME="$dir/env/xdg-config" \
    XDG_DATA_HOME="$dir/env/xdg-data" \
    HC_SESSION="$name" HC_SOCKET="$sock" \
    "$bin" server stop --json </dev/null >/dev/null 2>&1 ) || true
}

# hc_ci_caller_pids: the sweeper's own pid, its ancestor chain, and its
# process group (as a `g<pid>` token). A caller that exported HC_SESSION
# spreads that env token across its whole process tree - including this
# sweep's own ps/grep/awk transients - which must never be signaled. Session
# daemons are setsid'd (reparented to init), so they can never share the
# caller's process group.
HC_CI_CALLER_PIDS=""
hc_ci_caller_pids() {
  [ -n "$HC_CI_CALLER_PIDS" ] && return 0
  local pid=$PPID pgid
  pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  HC_CI_CALLER_PIDS=" $$ g${pgid:-0}"
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    HC_CI_CALLER_PIDS="$HC_CI_CALLER_PIDS $pid"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
}

# hc_ci_session_pids: pids of processes carrying HC_SESSION=<name> in their
# environment (the session's serve/hold daemons and children). The match is
# anchored on env-token boundaries on both sides so "fm-hclab-a" can never
# match "fm-hclab-ab" or a longer assignment. Same-uid env scan works on macOS
# (BSD ps) and Linux (procps) alike; the caller's process tree is excluded.
hc_ci_session_pids() {  # <name>
  local name=$1
  hc_ci_caller_pids
  # shellcheck disable=SC2009 # the match is on the process ENVIRONMENT (HC_SESSION), which pgrep -f cannot read.
  ps ewwax -o pid=,ppid=,pgid=,command= 2>/dev/null \
    | grep -E "(^|[[:space:]])HC_SESSION=${name}([[:space:]]|$)" \
    | awk -v excl="$HC_CI_CALLER_PIDS" \
      'index(excl, " "$1" ") == 0 && index(excl, " "$2" ") == 0 && index(excl, " g"$3" ") == 0 { print $1 }'
}

case "$cmd" in
  snapshot)
    list_lab_names >"$path" || die "failed to write lab session snapshot to $path"
    log "wrote lab session snapshot to $path ($(wc -l <"$path" | tr -d ' ') names)"
    ;;
  teardown)
    [ -f "$path" ] || die "snapshot file not found: $path"
    names=$(list_lab_names) || die "could not inventory lab sessions"
    failed=0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      is_lab_name "$name" || {
        log "refusing non-lab name from candidate set: $name"
        failed=1
        continue
      }
      if grep -qxF "$name" "$path"; then
        continue
      fi
      dir=$LAB_DIR/$name
      sock=$SOCK_DIR/$name.sock
      [ -e "$dir" ] || continue
      log "stopping job-owned lab core session $name"
      hc_ci_stop "$name" "$dir" "$sock"
      sleep 0.3
      # `server stop` closes the listener but the session's serve/hold
      # daemons stay by design; sweep every process still carrying the
      # session's HC_SESSION env marker (same-uid env scan, macOS and Linux).
      for sig in TERM TERM TERM TERM KILL KILL KILL KILL; do
        pids=$(hc_ci_session_pids "$name")
        [ -z "$pids" ] && break
        printf '%s\n' "$pids" | while IFS= read -r p; do
          [ -n "$p" ] && kill -"$sig" "$p" 2>/dev/null || true
        done
        sleep 0.3
      done
      # Signaled daemons take a while to finish exiting - measured ~30-60s
      # while they drain terminal state. Keep polling well past that
      # envelope before counting them survivors.
      i=0
      while [ "$i" -lt 180 ]; do
        pids=$(hc_ci_session_pids "$name")
        [ -z "$pids" ] && break
        sleep 0.5
        i=$((i + 1))
      done
      pids=$(hc_ci_session_pids "$name")
      if [ -n "$pids" ]; then
        log "session processes for $name did not exit: $pids"
        failed=1
        continue
      fi
      if rm -rf "$dir"; then
        rm -f "$sock" "$SOCK_DIR/$name".holder.*.sock 2>/dev/null || true
        log "removed job-owned lab core session $name"
      else
        log "failed to remove lab session dir $dir"
        failed=1
      fi
    done <<< "$names"
    [ "$failed" -eq 0 ] || die "one or more job-owned lab sessions could not be cleaned"
    ;;
  *)
    die "unknown command: $cmd (use snapshot or teardown)"
    ;;
esac
