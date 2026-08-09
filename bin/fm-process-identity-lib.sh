#!/usr/bin/env bash
# Shared process-reuse identity for spawn and teardown.
# Sourced by bin/fm-spawn.sh and bin/fm-teardown.sh.
# This file is sourced by scripts and has no side effects on source.
#
# The identity recorded at spawn is re-checked at teardown so a recycled pid
# is never mistaken for the process that was recorded.
#
# Linux /proc/<pid>/stat is authoritative when readable. The parse must strip
# through the FINAL `)` before splitting, because field 2 is the parenthesized
# comm and a comm containing spaces (or parentheses) shifts every positional
# field after it - reading `$22` from the raw line records the wrong number and
# silently breaks the recycled-pid check. `starttime` is field 22 overall,
# which is index 19 of the remainder after the comm.
#
# `ps -o lstart=` is the portable fallback for platforms without /proc. Both
# forms are self-describing, so a recorded value always states which it is.
#
# Distinct from fm_pid_identity in bin/fm-wake-lib.sh, which uses a different
# wire format for watcher lock semantics.

# shellcheck shell=bash

fm_process_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value
  local -a stat_fields
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$value"
}

fm_process_identity_matches() {  # <pid> <identity>
  local current
  current=$(fm_process_identity "$1") || return 1
  [ "$current" = "$2" ]
}

# FM_PROCESS_RECORD_TERMINATE_REASON: refusal reason left by
# fm_process_record_terminate - malformed | identity-unreadable | survived.
# Empty on success. Callers own their diagnostics and read this to phrase them.
FM_PROCESS_RECORD_TERMINATE_REASON=

# fm_process_record_terminate: ONE exact PID+identity termination primitive for
# the shared "<pid> <identity>" ownership record (the cursor worker-server
# record, written by fm-spawn.sh and reaped by fm-spawn.sh relaunch/rollback
# and fm-teardown.sh). Parses the record, proves liveness (kill -0) and identity
# (fm_process_identity) independently, TERMs, waits up to --term-polls polls,
# KILLs, waits again, and only then confirms termination. Caller policy stays
# OUTSIDE the primitive: malformed-record handling (--malformed=refuse|remove),
# timings (--term-polls, --poll-interval), retention on confirmed termination
# (--keep-record), lifecycle diagnostics (--verbose), and refusal diagnostics
# (caller prints its own, reading FM_PROCESS_RECORD_TERMINATE_REASON). On ANY
# refusal the record is always preserved so a retry can still find the process;
# a record is removed only after the process is proven gone, its identity no
# longer matches (recycled pid), or the caller's malformed policy says remove.
# Returns 0 when nothing remains to terminate or termination is confirmed;
# returns 1 when termination could not be confirmed (record preserved).
fm_process_record_terminate() {  # <record-file> <label> [--malformed=refuse|remove] [--term-polls=N] [--poll-interval=<s>] [--keep-record] [--verbose]
  local ws_file=$1 label=$2 malformed=refuse term_polls=10 poll_interval=0.1 keep_record=0 verbose=0
  local pid identity current i
  FM_PROCESS_RECORD_TERMINATE_REASON=
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --malformed=refuse) malformed=refuse ;;
      --malformed=remove) malformed=remove ;;
      --term-polls=*) term_polls=${1#--term-polls=} ;;
      --poll-interval=*) poll_interval=${1#--poll-interval=} ;;
      --keep-record) keep_record=1 ;;
      --verbose) verbose=1 ;;
    esac
    shift
  done
  case "$term_polls" in ''|*[!0-9]*|0) term_polls=10 ;; esac
  case "$poll_interval" in ''|*[!0-9.]*) poll_interval=0.1 ;; esac

  [ -f "$ws_file" ] || return 0
  if ! read -r pid identity < "$ws_file" 2>/dev/null; then
    if [ "$malformed" = refuse ]; then
      # shellcheck disable=SC2034 # out-param read by fm-spawn.sh and fm-teardown.sh callers
      FM_PROCESS_RECORD_TERMINATE_REASON='malformed'
      return 1
    fi
    rm -f "$ws_file" 2>/dev/null || true
    return 0
  fi
  case "$pid" in ''|*[!0-9]*)
    if [ "$malformed" = refuse ]; then
      # shellcheck disable=SC2034 # out-param read by fm-spawn.sh and fm-teardown.sh callers
      FM_PROCESS_RECORD_TERMINATE_REASON='malformed'
      return 1
    fi
    rm -f "$ws_file" 2>/dev/null || true
    return 0
    ;;
  esac
  if [ -z "$identity" ]; then
    if [ "$malformed" = refuse ]; then
      # shellcheck disable=SC2034 # out-param read by fm-spawn.sh and fm-teardown.sh callers
      FM_PROCESS_RECORD_TERMINATE_REASON='malformed'
      return 1
    fi
    rm -f "$ws_file" 2>/dev/null || true
    return 0
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    # Gone or recycled: nothing to terminate. The record is stale evidence.
    [ "$keep_record" -eq 1 ] || rm -f "$ws_file" 2>/dev/null || true
    return 0
  fi
  if ! current=$(fm_process_identity "$pid"); then
    # Alive but unprovable: never treat a read failure as absence.
    FM_PROCESS_RECORD_TERMINATE_REASON='identity-unreadable'
    return 1
  fi
  if [ "$current" != "$identity" ]; then
    # Recycled pid: not our process anymore.
    [ "$keep_record" -eq 1 ] || rm -f "$ws_file" 2>/dev/null || true
    return 0
  fi

  if [ "$verbose" -eq 1 ]; then
    printf 'reaping recorded cursor worker-server for %s: %s\n' "$label" "$pid" >&2
  fi
  i=0
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt "$term_polls" ]; do
    i=$((i + 1))
    kill -0 "$pid" 2>/dev/null || break
    if ! current=$(fm_process_identity "$pid"); then
      # Exit race: a process dying from TERM can still answer kill -0 while
      # /proc/<pid> is already gone. The next iteration's liveness recheck
      # decides; only the final revalidation refuses on a persistent
      # alive-but-unreadable process.
      sleep "$poll_interval"
      continue
    fi
    [ "$current" != "$identity" ] && break
    sleep "$poll_interval"
  done

  if kill -0 "$pid" 2>/dev/null; then
    if ! current=$(fm_process_identity "$pid"); then
      # Same exit-race tolerance as the waits: a process dying from TERM can
      # still answer kill -0 while /proc/<pid> is already gone.
      sleep "$poll_interval"
      kill -0 "$pid" 2>/dev/null || {
        [ "$keep_record" -eq 1 ] || rm -f "$ws_file" 2>/dev/null || true
        return 0
      }
      current=$(fm_process_identity "$pid") || {
        # shellcheck disable=SC2034 # out-param read by fm-spawn.sh and fm-teardown.sh callers
        FM_PROCESS_RECORD_TERMINATE_REASON='identity-unreadable'
        return 1
      }
    fi
    if [ "$current" != "$identity" ]; then
      # Recycled pid: the TERM wait broke on mismatch and this pid now
      # belongs to an unrelated process. Never signal it; the record is
      # stale evidence.
      [ "$keep_record" -eq 1 ] || rm -f "$ws_file" 2>/dev/null || true
      return 0
    fi
    if [ "$verbose" -eq 1 ]; then
      printf 'force-killing recorded cursor worker-server for %s: %s\n' "$label" "$pid" >&2
    fi
    i=0
    kill -KILL "$pid" 2>/dev/null || true
    while [ "$i" -lt "$term_polls" ]; do
      i=$((i + 1))
      kill -0 "$pid" 2>/dev/null || break
      if ! current=$(fm_process_identity "$pid"); then
        sleep "$poll_interval"
        continue
      fi
      [ "$current" != "$identity" ] && break
      sleep "$poll_interval"
    done
  fi

  if kill -0 "$pid" 2>/dev/null; then
    if ! current=$(fm_process_identity "$pid"); then
      # Same exit-race tolerance at the final check: give a dying process one
      # grace interval before refusing.
      sleep "$poll_interval"
      kill -0 "$pid" 2>/dev/null || {
        [ "$keep_record" -eq 1 ] || rm -f "$ws_file" 2>/dev/null || true
        return 0
      }
      current=$(fm_process_identity "$pid") || {
        # shellcheck disable=SC2034 # out-param read by fm-spawn.sh and fm-teardown.sh callers
        FM_PROCESS_RECORD_TERMINATE_REASON='identity-unreadable'
        return 1
      }
    fi
    [ "$current" != "$identity" ] && {
      [ "$keep_record" -eq 1 ] || rm -f "$ws_file" 2>/dev/null || true
      return 0
    }
    # shellcheck disable=SC2034 # out-param read by fm-spawn.sh and fm-teardown.sh callers
    FM_PROCESS_RECORD_TERMINATE_REASON='survived'
    return 1
  fi
  [ "$keep_record" -eq 1 ] || rm -f "$ws_file" 2>/dev/null || true
  return 0
}
