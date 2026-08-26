#!/usr/bin/env bash
# fm-timing-lib.sh - the single owner of the deferred network stage's elapsed-time
# instrumentation, and of the shared fork-free millisecond clock (fm_timing_now_ms)
# that any caller needing a sub-second wall-clock deadline reads rather than
# reimplementing. bin/fm-turnend-guard.sh is the other caller: it bounds its
# cooperative auto-arm wait by elapsed time, which is the one thing a loop of
# fork-heavy passes cannot bound for itself.
#
# Sourced, never executed.
#
# WHY THIS EXISTS. The deferred stage (bin/fm-startup-network.sh) publishes one
# aggregate started/finished pair, so a run that took a minute could not be
# attributed to a phase, a host, or a clone without re-running it by hand under
# manual tracing. These helpers record per-step elapsed times as the run happens,
# so the next slow run is answerable from the durable record alone.
#
# OFF BY DEFAULT, AND INERT. Every helper is a no-op unless FM_TIMING_LOG names a
# file. Nothing here talks to the network, waits, locks, or changes control flow:
# a failed append is discarded rather than propagated, because losing a diagnostic
# line must never change what a sweep does or how it exits.
#
# ENVIRONMENT, both exported by the stage that owns a run:
#   FM_TIMING_LOG       append-only record file. Unset or empty disables recording.
#                       Exported across process boundaries on purpose: the phases
#                       being measured run in bin/fm-bootstrap.sh and
#                       bin/fm-fleet-sync.sh, which are children of the stage.
#   FM_TIMING_EPOCH_MS  the run's start instant, so every record carries an offset
#                       from ONE origin even though the records are written by
#                       several processes. Defaults to the first recording
#                       process's own start, which keeps a hand-run child readable.
#
# RECORD FORMAT, one tab-separated line per measured step:
#   v1 <TAB> scope <TAB> name <TAB> start-offset-ms <TAB> elapsed-ms <TAB> detail
# Appends are single short lines opened O_APPEND, so concurrent writers interleave
# whole lines rather than corrupting each other.
#
# NO SECRETS, BY CONSTRUCTION. `detail` names an identity - a secondmate id, a
# host, a clone directory name - and identities never contain whitespace, while
# the things that must never reach this file (a command line, an environment
# dump, a captured error) always do. So a detail carrying ANY whitespace is not a
# truncated identity, it is free text that arrived from somewhere it should not
# have, and it is dropped entirely rather than cleaned up: cleaning would leave
# the token in `KEY=secret` behind, because a credential is made of exactly the
# characters an identity is made of. What remains is then narrowed to
# [A-Za-z0-9._@:/+-] and truncated, which is what stops a detail from forging
# extra tab-separated records. Enforcing this here rather than at each call site
# is what makes "this file cannot carry a credential or an argv" checkable in one
# place.
set -u

FM_TIMING_DETAIL_MAX=${FM_TIMING_DETAIL_MAX:-80}

fm_timing_enabled() {
  [ -n "${FM_TIMING_LOG:-}" ]
}

# Milliseconds since the epoch. EPOCHREALTIME is a bash builtin (no fork) whose
# decimal separator follows the locale, so both forms are accepted. A shell
# without it - macOS's system bash 3.2, which `env bash` still resolves to on a
# host with no newer bash on PATH - degrades to whole-second granularity rather
# than losing the timing entirely. That is a coarser answer to "which host was
# slow", not a missing one, because the steps being measured are seconds-scale.
fm_timing_now_ms() {
  local raw sec frac
  raw=${EPOCHREALTIME:-}
  case "$raw" in
    *[0-9][.,][0-9]*)
      sec=${raw%%[.,]*}
      frac=${raw#*[.,]}
      frac="${frac}000"
      frac=${frac:0:3}
      case "$sec$frac" in
        ''|*[!0-9]*) ;;
        *) printf '%s\n' "$(( sec * 1000 + 10#$frac ))"; return 0 ;;
      esac
      ;;
  esac
  sec=$(date +%s 2>/dev/null || printf '0')
  case "$sec" in ''|*[!0-9]*) sec=0 ;; esac
  printf '%s\n' "$(( sec * 1000 ))"
}

# Ensure FM_TIMING_EPOCH_MS holds the origin every offset is measured from.
# Callers that own a run export it up front; a process that starts recording
# without one adopts its own first measurement so its records stay internally
# consistent instead of being silently dropped.
#
# This SETS the variable rather than printing it, because the caller must read it
# as "$FM_TIMING_EPOCH_MS" and not through a command substitution: a substitution
# runs in a subshell, so the lazily chosen origin would be discarded and every
# record would recompute it, flattening every start offset to zero.
fm_timing_epoch_ensure() {
  case "${FM_TIMING_EPOCH_MS:-}" in
    ''|*[!0-9]*)
      FM_TIMING_EPOCH_MS=$(fm_timing_now_ms)
      export FM_TIMING_EPOCH_MS
      ;;
  esac
}

# Start a run: point recording at <file> and stamp the shared origin. The file is
# created empty so a run that dies before its first record still publishes an
# empty-but-present artifact rather than looking like it was never instrumented.
fm_timing_start() {  # <file>
  local file=$1
  [ -n "$file" ] || return 0
  : > "$file" 2>/dev/null || return 0
  FM_TIMING_LOG=$file
  FM_TIMING_EPOCH_MS=$(fm_timing_now_ms)
  export FM_TIMING_LOG FM_TIMING_EPOCH_MS
}

fm_timing_sanitize() {  # <text>
  local text=${1:-}
  case "$text" in
    *[[:space:]]*) printf '%s\n' 'unrecordable'; return 0 ;;
  esac
  text=${text//[!A-Za-z0-9._@:\/+-]/_}
  printf '%s\n' "${text:0:$FM_TIMING_DETAIL_MAX}"
}

# Record one measured step. Never fails the caller: a missing log, an unwritable
# path, or a malformed start stamp all resolve to "no record", never an error.
fm_timing_record() {  # <scope> <name> <start-ms> [detail]
  local scope=$1 name=$2 start=$3 detail=${4:-} now offset elapsed
  fm_timing_enabled || return 0
  case "$start" in ''|*[!0-9]*) return 0 ;; esac
  now=$(fm_timing_now_ms)
  fm_timing_epoch_ensure
  offset=$(( start - FM_TIMING_EPOCH_MS ))
  [ "$offset" -ge 0 ] || offset=0
  elapsed=$(( now - start ))
  [ "$elapsed" -ge 0 ] || elapsed=0
  printf 'v1\t%s\t%s\t%s\t%s\t%s\n' \
    "$(fm_timing_sanitize "$scope")" "$(fm_timing_sanitize "$name")" \
    "$offset" "$elapsed" "$(fm_timing_sanitize "$detail")" \
    >> "$FM_TIMING_LOG" 2>/dev/null || true
  return 0
}

# Render a recorded run for a human. Prints nothing at all when the file is
# missing or holds no record, so an uninstrumented or empty run adds no output.
fm_timing_render() {  # <file>
  local file=$1
  [ -n "$file" ] && [ -s "$file" ] || return 0
  awk -F'\t' '
    $1 != "v1" || NF < 5 { next }
    {
      records++
      scope[records] = $2; name[records] = $3
      offset[records] = $4 + 0; elapsed[records] = $5 + 0
      detail[records] = $6
    }
    END {
      if (records == 0) exit 0
      print "TIMINGS - where the deferred network checks spent their time (ms):"
      for (i = 1; i <= records; i++) {
        label = name[i]
        if (detail[i] != "") label = label " " detail[i]
        printf "  %-11s %-42s start=+%-7d elapsed=%d\n", scope[i], label, offset[i], elapsed[i]
      }
      for (i = 1; i <= records; i++) {
        for (j = i + 1; j <= records; j++) {
          if (elapsed[j] > elapsed[i]) {
            t = scope[i]; scope[i] = scope[j]; scope[j] = t
            t = name[i]; name[i] = name[j]; name[j] = t
            t = offset[i]; offset[i] = offset[j]; offset[j] = t
            t = elapsed[i]; elapsed[i] = elapsed[j]; elapsed[j] = t
            t = detail[i]; detail[i] = detail[j]; detail[j] = t
          }
        }
      }
      top = records < 3 ? records : 3
      line = ""
      for (i = 1; i <= top; i++) {
        label = name[i]
        if (detail[i] != "") label = label " " detail[i]
        line = line (line == "" ? "" : ", ") scope[i] " " label " " elapsed[i] "ms"
      }
      print "  slowest: " line
    }
  ' "$file" 2>/dev/null || true
}
