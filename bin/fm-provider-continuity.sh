#!/usr/bin/env bash
# fm-provider-continuity.sh - deterministic provider-outage bookkeeping and the
# cross-provider handoff license.
#
# Why this exists: when a model provider is unavailable, firstmate must be able
# to route NEW work away from it and, separately, to move an ALREADY-RUNNING
# task onto another provider without ever creating a second owner for that task.
# Both decisions need a durable, inspectable, testable record instead of opaque
# mid-turn retries. This script owns that record and nothing else: it never
# calls a provider, never probes one for health, never maps a model or harness
# to a provider, and never selects a route. Firstmate establishes the
# model/provider relation itself (`harness-adapters`, `quota-array-dispatch`)
# and passes the resulting opaque provider token in.
#
# Usage:
#   fm-provider-continuity.sh record <provider> <class> [--detail <text>]
#       Append one classified failure observation for <provider>.
#   fm-provider-continuity.sh status [<provider>...]
#       Print one reconciled line per provider (all recorded providers when none
#       is named). Always exits 0.
#   fm-provider-continuity.sh eligible <provider>
#       Exit 0 when <provider> may take new work, 1 while it is unavailable.
#   fm-provider-continuity.sh filter [--exclude <provider>]... \
#                                    [--fallback <provider>]... <provider>...
#       Print one verdict line per candidate provider, preserving input order and
#       de-duplicating. Positional providers are the rule's own `use` tier;
#       --fallback providers are that rule's configured outage fallback and are
#       consulted ONLY when no primary candidate remains, so an outage fallback
#       can never act as a second quota choice. --exclude carries a review's
#       independence requirement: the named provider is refused in both tiers.
#       Exit 0 when at least one candidate remains eligible, 3 (with a `defer:`
#       line) when none does.
#   fm-provider-continuity.sh clear <provider>
#       Drop <provider>'s observations after firstmate has positive evidence it
#       recovered.
#   fm-provider-continuity.sh handoff-check <task-id>
#       Read-only cross-provider handoff license for one recorded task. It
#       composes the recorded endpoint's own state with the current-code-matched
#       run state and licenses a move only when BOTH are proven: the endpoint is
#       `dead` or `missing`, and the current-state read succeeded without showing
#       an active or parked validation run. A readable `unknown` verdict is a
#       real read and may license a move; a verdict that could not be read at all
#       refuses, because it proves nothing about validation ownership.
#   fm-provider-continuity.sh handoff-attempt <task-id>
#       Record one handoff attempt, then apply the same license plus the
#       repeated-failure cap.
#   fm-provider-continuity.sh handoff-clear <task-id>
#       Drop a task's attempt ledger after a completed handoff or teardown.
#   fm-provider-continuity.sh --help
#
# Evidence classes are a fixed enum and the caller must name one. Firstmate
# classifies the observation; this script never parses raw agent or provider
# output, so a single ambiguous error string can never be promoted into an
# outage by shell heuristics.
#   QUALIFYING (count toward an outage):
#     provider-5xx         retry-exhausted 5xx from the provider API
#     provider-connection  retry-exhausted connection/DNS/TLS failure
#     provider-stream      retry-exhausted streaming abort mid-response
#   NON-QUALIFYING (recorded for inspection, never qualify an outage):
#     auth                 authentication or authorization refusal
#     config               invalid local or account configuration
#     task                 task, tool, or ordinary local failure
#     quota                rate-limit or quota exhaustion - a DIFFERENT concern
#                          owned by quota-axi and the quota-array-dispatch skill
#     transient            one-off failure that recovered or was not retried out
#
# Qualification rule: walk a provider's qualifying observations newest-first and
# stop at the first gap longer than the window. That contiguous burst is the
# evidence set. The provider is unavailable while the burst holds at least
# THRESHOLD observations AND now is before newest + COOLDOWN. Cooldown expiry
# therefore restores eligibility with no extra state and no timer, and a later
# isolated failure starts a fresh burst instead of reusing expired evidence.
#
# Tunables (documented in docs/configuration.md "Provider outage continuity"):
#   FM_CONTINUITY_NOW                    epoch override; tests and replay only
#   FM_CONTINUITY_OUTAGE_THRESHOLD=3     qualifying observations that trip
#   FM_CONTINUITY_OUTAGE_WINDOW_SECS=900 max gap inside one qualifying burst
#   FM_CONTINUITY_COOLDOWN_SECS=1800     unavailability after the newest one
#   FM_CONTINUITY_RETENTION_SECS=604800  observation retention
#   FM_CONTINUITY_HANDOFF_MAX_ATTEMPTS=2 handoff attempts before refusing
#   FM_CREW_STATE_BIN                    current-state reader (shared seam)
#
# Records live under $FM_HOME/state/provider-continuity/ (mode 0700), private to
# one home exactly like every other state record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORDS="$STATE/provider-continuity"
HANDOFFS="$RECORDS/handoff"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

QUALIFYING_CLASSES='provider-5xx provider-connection provider-stream'
OTHER_CLASSES='auth config task quota transient'

class_is_qualifying() {  # <class>
  case " $QUALIFYING_CLASSES " in *" $1 "*) return 0 ;; esac
  return 1
}

class_is_known() {  # <class>
  class_is_qualifying "$1" && return 0
  case " $OTHER_CLASSES " in *" $1 "*) return 0 ;; esac
  return 1
}

# Provider tokens are opaque to this script: it validates only that the token is
# a safe, stable file-name component. It deliberately knows no vendor names, so
# no shell path can ever infer a provider from a model or harness name.
valid_provider() {  # <token>
  case "$1" in
    ''|*[!a-z0-9._-]*) return 1 ;;
    .*|-*) return 1 ;;
  esac
  [ "${#1}" -le 64 ] || return 1
  return 0
}

# Task ids reach the filesystem the same way, so apply the same shape guard the
# rest of firstmate's state layer relies on.
valid_task_id() {  # <token>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    .*|-*) return 1 ;;
  esac
  [ "${#1}" -le 128 ] || return 1
  return 0
}

positive_int() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) if [ "$1" -gt 0 ]; then printf '%s' "$1"; else printf '%s' "$2"; fi ;;
  esac
}

NOW=$(positive_int "${FM_CONTINUITY_NOW:-}" "$(date +%s)")
THRESHOLD=$(positive_int "${FM_CONTINUITY_OUTAGE_THRESHOLD:-}" 3)
WINDOW=$(positive_int "${FM_CONTINUITY_OUTAGE_WINDOW_SECS:-}" 900)
COOLDOWN=$(positive_int "${FM_CONTINUITY_COOLDOWN_SECS:-}" 1800)
RETENTION=$(positive_int "${FM_CONTINUITY_RETENTION_SECS:-}" 604800)
MAX_ATTEMPTS=$(positive_int "${FM_CONTINUITY_HANDOFF_MAX_ATTEMPTS:-}" 2)

ensure_records_dir() {
  mkdir -p "$RECORDS" 2>/dev/null || die "cannot create $RECORDS"
  chmod 700 "$RECORDS" 2>/dev/null || true
}

events_file() {  # <provider>
  printf '%s/%s.events' "$RECORDS" "$1"
}

# Refuse a record that is not a plain regular file so a symlinked or otherwise
# surprising path is reported rather than followed.
readable_events() {  # <path>
  [ -f "$1" ] && [ ! -L "$1" ]
}

# --- reconciliation ---------------------------------------------------------
#
# Prints: <state> <qualifying-count> <last-epoch> <until-epoch> <per-class counts>
# state is `eligible` or `unavailable`; absent evidence prints zeros.
reconcile() {  # <provider>
  local file
  file=$(events_file "$1")
  if ! readable_events "$file"; then
    printf 'eligible 0 0 0 \n'
    return 0
  fi
  awk -v now="$NOW" -v window="$WINDOW" -v cooldown="$COOLDOWN" \
      -v threshold="$THRESHOLD" -v qualifying="$QUALIFYING_CLASSES" '
    BEGIN {
      FS = "\t"
      n = split(qualifying, q, " ")
      for (i = 1; i <= n; i++) isq[q[i]] = 1
      count = 0
    }
    {
      epoch = $1 + 0
      cls = $2
      if (epoch <= 0 || cls == "") next
      if (isq[cls]) {
        count++
        qe[count] = epoch
      } else {
        other[cls]++
      }
    }
    END {
      # Sort qualifying epochs ascending; the files are append-only so this is
      # normally already sorted, but a replayed or hand-edited record must not
      # change the verdict.
      for (i = 2; i <= count; i++) {
        v = qe[i]
        j = i - 1
        while (j >= 1 && qe[j] > v) { qe[j + 1] = qe[j]; j-- }
        qe[j + 1] = v
      }
      burst = 0; last = 0
      if (count > 0) {
        last = qe[count]
        burst = 1
        for (i = count; i > 1; i--) {
          if (qe[i] - qe[i - 1] > window) break
          burst++
        }
      }
      until_ts = 0
      state = "eligible"
      if (burst >= threshold && last > 0 && now < last + cooldown) {
        state = "unavailable"
        until_ts = last + cooldown
      }
      detail = ""
      m = 0
      for (cls in other) { keys[++m] = cls }
      for (i = 2; i <= m; i++) {
        v = keys[i]; j = i - 1
        while (j >= 1 && keys[j] > v) { keys[j + 1] = keys[j]; j-- }
        keys[j + 1] = v
      }
      for (i = 1; i <= m; i++) {
        detail = detail (detail == "" ? "" : " ") keys[i] "=" other[keys[i]]
      }
      printf "%s %d %d %d %s\n", state, burst, last, until_ts, detail
    }
  ' "$file"
}

read_reconciled() {  # <provider>; sets R_STATE R_COUNT R_LAST R_UNTIL R_OTHER
  local line
  line=$(reconcile "$1")
  R_STATE=${line%% *}; line=${line#* }
  R_COUNT=${line%% *}; line=${line#* }
  R_LAST=${line%% *}; line=${line#* }
  R_UNTIL=${line%% *}; line=${line#* }
  R_OTHER=$line
}

status_line() {  # <provider>
  read_reconciled "$1"
  local last=$R_LAST until=$R_UNTIL other=$R_OTHER
  [ "$last" != 0 ] || last=none
  [ "$until" != 0 ] || until=none
  [ -n "$other" ] || other=none
  printf 'provider: %s · state: %s · qualifying: %s/%s · last: %s · until: %s · non-qualifying: %s\n' \
    "$1" "$R_STATE" "$R_COUNT" "$THRESHOLD" "$last" "$until" "$other"
}

known_providers() {
  local f base
  [ -d "$RECORDS" ] || return 0
  for f in "$RECORDS"/*.events; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    base=$(basename "$f" .events)
    valid_provider "$base" || continue
    printf '%s\n' "$base"
  done
}

# --- commands ---------------------------------------------------------------

cmd_record() {
  local provider=${1:-} class=${2:-} detail='' file tmp
  shift 2 2>/dev/null || true
  [ -n "$provider" ] && [ -n "$class" ] || die "usage: fm-provider-continuity.sh record <provider> <class> [--detail <text>]"
  valid_provider "$provider" || die "provider must be lowercase [a-z0-9._-] and start alphanumeric: $provider"
  class_is_known "$class" || die "unknown evidence class '$class'; expected one of: $QUALIFYING_CLASSES $OTHER_CLASSES"
  while [ $# -gt 0 ]; do
    case "$1" in
      --detail) shift; [ $# -gt 0 ] || die "--detail needs a value"; detail=$1 ;;
      *) die "unexpected argument: $1" ;;
    esac
    shift
  done
  # One physical line per observation: strip anything that would split a record.
  detail=$(printf '%s' "$detail" | tr '\t\n\r' '   ')
  ensure_records_dir
  file=$(events_file "$provider")
  if [ -e "$file" ] || [ -L "$file" ]; then
    readable_events "$file" || die "observation record is not a regular file: $file"
    # Prune expired observations in the same pass that appends, so the record
    # cannot grow without bound and a very old burst can never be reconsidered.
    tmp="$file.tmp.$$"
    if awk -v cutoff="$((NOW - RETENTION))" -F '\t' '($1 + 0) >= cutoff' "$file" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi
  printf '%s\t%s\t%s\n' "$NOW" "$class" "$detail" >> "$file" || die "cannot append to $file"
  chmod 600 "$file" 2>/dev/null || true
  status_line "$provider"
}

cmd_status() {
  local p had=0
  if [ $# -eq 0 ]; then
    while IFS= read -r p; do
      had=1
      status_line "$p"
    done < <(known_providers)
    [ "$had" = 1 ] || printf 'provider: none · state: eligible · qualifying: 0/%s · last: none · until: none · non-qualifying: none\n' "$THRESHOLD"
    return 0
  fi
  for p in "$@"; do
    valid_provider "$p" || die "provider must be lowercase [a-z0-9._-] and start alphanumeric: $p"
    status_line "$p"
  done
}

cmd_eligible() {
  local provider=${1:-}
  [ -n "$provider" ] || die "usage: fm-provider-continuity.sh eligible <provider>"
  valid_provider "$provider" || die "provider must be lowercase [a-z0-9._-] and start alphanumeric: $provider"
  read_reconciled "$provider"
  if [ "$R_STATE" = eligible ]; then
    printf 'eligible\n'
    return 0
  fi
  printf 'unavailable until %s\n' "$R_UNTIL"
  return 1
}

FILTER_ELIGIBLE=0
FILTER_EXCLUDED=()
FILTER_SEEN=()

# Print one verdict line per candidate in a tier, de-duplicated against every
# candidate already reported, and count how many survived.
filter_tier() {  # <tier-label> <provider>...
  local tier=$1 p e dup
  shift
  FILTER_ELIGIBLE=0
  for p in "$@"; do
    dup=0
    for e in ${FILTER_SEEN[@]+"${FILTER_SEEN[@]}"}; do
      [ "$e" = "$p" ] && dup=1 && break
    done
    [ "$dup" = 0 ] || continue
    FILTER_SEEN+=("$p")
    dup=0
    for e in ${FILTER_EXCLUDED[@]+"${FILTER_EXCLUDED[@]}"}; do
      [ "$e" = "$p" ] && dup=1 && break
    done
    if [ "$dup" = 1 ]; then
      printf '%s excluded independence (%s)\n' "$p" "$tier"
      continue
    fi
    read_reconciled "$p"
    if [ "$R_STATE" = eligible ]; then
      printf '%s eligible %s\n' "$p" "$tier"
      FILTER_ELIGIBLE=$((FILTER_ELIGIBLE + 1))
    else
      printf '%s excluded outage until %s (%s)\n' "$p" "$R_UNTIL" "$tier"
    fi
  done
}

cmd_filter() {
  local -a candidates=() fallbacks=()
  local arg p
  FILTER_EXCLUDED=()
  FILTER_SEEN=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --exclude) shift; [ $# -gt 0 ] || die "--exclude needs a provider"; FILTER_EXCLUDED+=("$1") ;;
      --fallback) shift; [ $# -gt 0 ] || die "--fallback needs a provider"; fallbacks+=("$1") ;;
      --) shift; break ;;
      -*) die "unexpected flag: $1" ;;
      *) candidates+=("$1") ;;
    esac
    shift
  done
  for arg in "$@"; do candidates+=("$arg"); done
  [ "${#candidates[@]}" -gt 0 ] || die "usage: fm-provider-continuity.sh filter [--exclude <provider>]... [--fallback <provider>]... <provider>..."
  for p in "${candidates[@]}" ${fallbacks[@]+"${fallbacks[@]}"} ${FILTER_EXCLUDED[@]+"${FILTER_EXCLUDED[@]}"}; do
    valid_provider "$p" || die "provider must be lowercase [a-z0-9._-] and start alphanumeric: $p"
  done
  filter_tier primary "${candidates[@]}"
  if [ "$FILTER_ELIGIBLE" -gt 0 ]; then
    # The configured fallback tier exists for an outage, not as a second quota
    # choice, so an available primary tier never consults it.
    [ "${#fallbacks[@]}" -eq 0 ] || printf 'fallback: not consulted (primary tier available)\n'
    return 0
  fi
  if [ "${#fallbacks[@]}" -gt 0 ]; then
    filter_tier fallback "${fallbacks[@]}"
    [ "$FILTER_ELIGIBLE" -eq 0 ] || return 0
  fi
  if [ "${#FILTER_EXCLUDED[@]}" -gt 0 ]; then
    printf 'defer: no candidate provider is both available and independent of %s\n' "$(printf '%s ' "${FILTER_EXCLUDED[@]}" | sed 's/ $//')"
  else
    printf 'defer: every candidate provider is currently unavailable\n'
  fi
  return 3
}

cmd_clear() {
  local provider=${1:-} file
  [ -n "$provider" ] || die "usage: fm-provider-continuity.sh clear <provider>"
  valid_provider "$provider" || die "provider must be lowercase [a-z0-9._-] and start alphanumeric: $provider"
  file=$(events_file "$provider")
  if [ -e "$file" ] || [ -L "$file" ]; then
    rm -f "$file" 2>/dev/null || die "cannot clear $file"
  fi
  printf 'cleared %s\n' "$provider"
}

# --- handoff license --------------------------------------------------------
#
# A cross-provider handoff may only proceed once the recorded worker provably no
# longer owns or is changing the task. Both proofs come from existing owners:
# fm_backend_agent_state (only `dead`/`missing` license recovery) and
# bin/fm-crew-state.sh (an active or parked no-mistakes run still owns the
# branch). Nothing here searches a backend namespace: it reads only this task's
# own recorded endpoint identity.
handoff_attempts_file() {  # <task-id>
  printf '%s/%s.attempts' "$HANDOFFS" "$1"
}

handoff_attempt_count() {  # <task-id>
  local file
  file=$(handoff_attempts_file "$1")
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    awk 'END { print NR + 0 }' "$file"
  else
    printf '0'
  fi
}

handoff_decide() {  # <task-id> <attempts>
  local id=$1 attempts=$2 meta backend target endpoint crew crew_state
  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    printf 'handoff: refuse · endpoint: unreadable · crew: unknown · attempts: %s/%s · reason: no readable task record for %s\n' \
      "$attempts" "$MAX_ATTEMPTS" "$id"
    return 1
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  if [ -z "$target" ]; then
    printf 'handoff: refuse · endpoint: unreadable · crew: unknown · attempts: %s/%s · reason: the task record names no endpoint to prove ownership against\n' \
      "$attempts" "$MAX_ATTEMPTS"
    return 1
  fi
  endpoint=$(fm_backend_agent_state "$backend" "$target")
  crew=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$crew" in
    state:*) crew_state=${crew#state: }; crew_state=${crew_state%% *} ;;
    *) crew_state=unreadable ;;
  esac
  if [ "$attempts" -gt "$MAX_ATTEMPTS" ]; then
    printf 'handoff: refuse · endpoint: %s · crew: %s · attempts: %s/%s · reason: repeated handoff attempts exhausted; report the concrete blocker instead of retrying\n' \
      "$endpoint" "$crew_state" "$attempts" "$MAX_ATTEMPTS"
    return 1
  fi
  case "$crew_state" in
    working|parked)
      printf 'handoff: refuse · endpoint: %s · crew: %s · attempts: %s/%s · reason: an active validation run still owns this task and its branch\n' \
        "$endpoint" "$crew_state" "$attempts" "$MAX_ATTEMPTS"
      return 1
      ;;
    unreadable)
      # A verdict of `unknown` is a real read and may license a handoff; a
      # verdict that could not be read at all proves nothing about ownership.
      printf 'handoff: refuse · endpoint: %s · crew: %s · attempts: %s/%s · reason: current task state could not be read, so validation ownership is unproven\n' \
        "$endpoint" "$crew_state" "$attempts" "$MAX_ATTEMPTS"
      return 1
      ;;
  esac
  case "$endpoint" in
    dead|missing) ;;
    *)
      printf 'handoff: refuse · endpoint: %s · crew: %s · attempts: %s/%s · reason: the recorded worker cannot be proved gone\n' \
        "$endpoint" "$crew_state" "$attempts" "$MAX_ATTEMPTS"
      return 1
      ;;
  esac
  printf 'handoff: allow · endpoint: %s · crew: %s · attempts: %s/%s · worktree: %s\n' \
    "$endpoint" "$crew_state" "$attempts" "$MAX_ATTEMPTS" "$(fm_meta_field "$meta" worktree)"
  return 0
}

load_backend_lib() {
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
}

fm_meta_field() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-
}

cmd_handoff_check() {
  local id=${1:-}
  [ -n "$id" ] || die "usage: fm-provider-continuity.sh handoff-check <task-id>"
  valid_task_id "$id" || die "task id must be [A-Za-z0-9._-] and start alphanumeric: $id"
  load_backend_lib
  handoff_decide "$id" "$(handoff_attempt_count "$id")"
}

cmd_handoff_attempt() {
  local id=${1:-} file
  [ -n "$id" ] || die "usage: fm-provider-continuity.sh handoff-attempt <task-id>"
  valid_task_id "$id" || die "task id must be [A-Za-z0-9._-] and start alphanumeric: $id"
  ensure_records_dir
  mkdir -p "$HANDOFFS" 2>/dev/null || die "cannot create $HANDOFFS"
  chmod 700 "$HANDOFFS" 2>/dev/null || true
  file=$(handoff_attempts_file "$id")
  if [ -e "$file" ] && { [ ! -f "$file" ] || [ -L "$file" ]; }; then
    die "handoff attempt ledger is not a regular file: $file"
  fi
  printf '%s\n' "$NOW" >> "$file" || die "cannot append to $file"
  chmod 600 "$file" 2>/dev/null || true
  load_backend_lib
  handoff_decide "$id" "$(handoff_attempt_count "$id")"
}

cmd_handoff_clear() {
  local id=${1:-} file
  [ -n "$id" ] || die "usage: fm-provider-continuity.sh handoff-clear <task-id>"
  valid_task_id "$id" || die "task id must be [A-Za-z0-9._-] and start alphanumeric: $id"
  file=$(handoff_attempts_file "$id")
  if [ -e "$file" ] || [ -L "$file" ]; then
    rm -f "$file" 2>/dev/null || die "cannot clear $file"
  fi
  printf 'cleared handoff %s\n' "$id"
}

case "${1:--h}" in
  -h|--help) usage; exit 0 ;;
esac
CMD=$1
shift
case "$CMD" in
  record) cmd_record "$@" ;;
  status) cmd_status "$@" ;;
  eligible) cmd_eligible "$@" ;;
  filter) cmd_filter "$@" ;;
  clear) cmd_clear "$@" ;;
  handoff-check) cmd_handoff_check "$@" ;;
  handoff-attempt) cmd_handoff_attempt "$@" ;;
  handoff-clear) cmd_handoff_clear "$@" ;;
  *) die "unknown command: $CMD (run --help)" ;;
esac
