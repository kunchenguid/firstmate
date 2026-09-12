#!/usr/bin/env bash
# Detached killswitch for a rented RunPod pod, able to stop the meter after the
# agent that rented it is gone.
#
# Usage:
#   fm-runpod-watchdog.sh arm --task <id> --pod <pod-id> --deadline <when>
#                             [--ceiling-usd <n> --rate-usd-hr <n>]
#   fm-runpod-watchdog.sh status [--task <id>]
#   fm-runpod-watchdog.sh disarm --task <id>
#   fm-runpod-watchdog.sh run --task <id>      # the loop; `arm` starts this detached
#
# WHY IT IS DETACHED, and why it is not bin/fm-watch-arm.sh's shape.
# The supervision watcher is deliberately a TRACKED CHILD: killing the arm tears
# the watcher down, because a watcher that outlived its supervisor would be a
# leak. This is the exact inverse. The failure it exists to close is the agent
# session ending while a rented GPU is still billing, so it must survive that
# session or it reproduces the gap. `arm` therefore starts `run` with setsid in
# its own session, detached from the harness's process group and controlling
# terminal, and returns.
#
# WHAT IT ENFORCES, and what it refuses to decide.
# A run declares its not-to-exceed ceiling and its hard deletion deadline before
# it starts, in its own run-state record. This watchdog is NOT a second source of
# truth for either: `arm` transcribes the deadline the run already declared into
# one small machine-readable record, and the loop enforces that. It never parses
# the run's prose run-state file and never edits the record it was given.
#
# WHAT IT KEYS ON.
# The wall clock only. Measured across three pods on 2026-09-11, RunPod's runtime
# GPU utilization read 0% on most samples while runs were demonstrably
# progressing, because these sweeps alternate short GPU bursts with long
# CPU-bound quantize and pack phases. Terminating on a utilization signal would
# kill healthy runs mid-pack.
#
# THE CEILING IS ANCHORED TO THE POD, NOT TO THIS PROCESS.
# A declared spend ceiling is a bound on what the POD costs, so the only honest
# anchor for it is when the pod started - which is billing from, not when someone
# got around to arming a watchdog. `arm` therefore converts the ceiling into a
# DURATION of uptime and the loop anchors that duration to the start instant the
# API reports for the pod, in the same request it already makes to check the pod
# is there. The anchor is then PERSISTED beside the pod id it belongs to and
# reused by any later process watching that same pod, because otherwise a pod
# whose runtime restarts reports fresh uptime and a re-arm would re-derive a
# later anchor - buying the ceiling all the spend that came before it. Arming
# late, or re-arming, therefore cannot extend the ceiling. A different pod does
# take a fresh anchor, which is the only thing it could take. When the start
# instant cannot be read the ceiling is not enforced at all and says so: the
# declared deadline still is, and an unreadable anchor alarms rather than being
# guessed from a local clock.
#
# FAIL TOWARD NOT KILLING.
# Terminating a healthy run destroys work and money already spent, so every
# uncertain state alarms and keeps polling instead of terminating: a missing,
# malformed, or unreadable record; an unreadable clock; an unreachable or
# erroring API; a pod id that has never been seen in the account. The single
# condition that authorizes termination is a deadline that has provably passed on
# the wall clock, which needs no inference.
#
# DELETION IS VERIFIED, NEVER ASSUMED, AND ONLY FOR A POD IT SAW ALIVE.
# A successful podTerminate response is not evidence, and neither is "pod not
# found to terminate", which cannot tell "already gone" from "never existed".
# The loop lists the account's pods afterwards and only reports the pod stopped
# once it is absent from that list; an unverified termination alarms and keeps
# retrying forever. Absence is proof of a stop ONLY for a pod this watch sighted
# alive first: for one it never saw, absence is the original symptom, so no
# deadline is evaluated for it at all and no stop is ever reported.
#
# THE KEY NEVER APPEARS ANYWHERE.
# RUNPOD_API_KEY is read from the gitignored .env and handed to curl through a
# config file on stdin, so it is absent from argv and therefore from ps(1).
# Nothing this script writes - log line, status append, error text - carries it.
#
# Alarms are appended to state/<task>.status, which is firstmate's wake channel,
# under a decision key of this watchdog's own per condition so they can never
# take over or clear a crewmate's decision on the same channel, and rate-limited
# per condition so an unattended alarm cannot flood it. What it opens it closes:
# a condition that clears is resolved under the same key, and a verified stop is
# reported as a `note:`, which the drain surfaces but which opens no decision -
# an alarm nothing can close would leave the task permanently stuck. The one
# exception is the never-sighted pod: retiring the watch does not make that
# warning untrue, so only an actual sighting OF THAT POD closes it - every
# ledger row records the pod it is about, so news of one pod can never answer
# for another. The full trail is state/<task>.runpod-watch.log.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

ENV_FILE="${FM_RUNPOD_ENV_FILE:-$FM_HOME/.env}"
API_URL="${FM_RUNPOD_API_URL:-https://api.runpod.io/graphql}"
POLL_SECONDS="${FM_RUNPOD_POLL_SECONDS:-60}"
HTTP_TIMEOUT="${FM_RUNPOD_HTTP_TIMEOUT:-30}"
ALARM_REPEAT_SECONDS="${FM_RUNPOD_ALARM_REPEAT_SECONDS:-900}"
VERIFY_ATTEMPTS="${FM_RUNPOD_VERIFY_ATTEMPTS:-5}"
VERIFY_INTERVAL="${FM_RUNPOD_VERIFY_INTERVAL:-10}"

RECORD_TAG=fm-runpod-watch-v1
OBSERVED_TAG=fm-runpod-watch-observed-v1

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

# A value-taking flag given as the last argument used to be swallowed by
# `shift 2 || true`, which does not shift and leaves $1 unchanged - an unattended
# spin. Every such flag checks for its value first.
need_value() {
  [ "$1" -gt 1 ] || die "$2 needs a value" 2
}

# A pid this script is willing to signal. `kill -0 0` succeeds because 0 names
# the CALLER's process group, so a corrupt pid file must never reach kill(1):
# `disarm` would tear down the harness that invoked it.
pid_live() {
  local pid=${1:-}
  is_safe_uint "$pid" || return 1
  [ "$pid" -gt 1 ] || return 1
  kill -0 "$pid" 2>/dev/null
}

task_id_valid() {
  case "$1" in
    '' | *[!A-Za-z0-9._-]* | .* | -*) return 1 ;;
    *) return 0 ;;
  esac
}

# RunPod pod ids are opaque; accept only characters that can never smuggle shell
# or JSON structure into the request body built below.
pod_id_valid() {
  case "$1" in
    '' | *[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_uint() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# A digit string this script is willing to do arithmetic on. `[ a -lt b ]` does
# not answer false for a digit string outside intmax - it aborts with "integer
# expected" and returns non-zero, which on a deadline comparison is the
# terminating side.
# Bounding the digits keeps such a value out of the arithmetic entirely, where it
# is reported as an untrustworthy record instead.
is_safe_uint() {
  is_uint "${1:-}" || return 1
  [ "${#1}" -le 11 ] || return 1
  return 0
}

is_number() {
  case "${1:-}" in
    '' | *[!0-9.]* | *.*.*) return 1 ;;
    .) return 1 ;;
    *) return 0 ;;
  esac
}

now_epoch() {
  local t
  t=$(date +%s 2>/dev/null) || return 1
  is_safe_uint "$t" || return 1
  printf '%s\n' "$t"
}

iso_utc() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$1"
}

# Accepts an epoch second or anything date(1) understands, notably the ISO-8601
# UTC instants run-state records already carry (2026-09-12T02:19:41Z).
parse_when() {
  local raw=$1 epoch
  if is_uint "$raw"; then
    is_safe_uint "$raw" || return 1
    printf '%s\n' "$raw"
    return 0
  fi
  epoch=$(date -u -d "$raw" +%s 2>/dev/null) || return 1
  is_safe_uint "$epoch" || return 1
  printf '%s\n' "$epoch"
}

# --- record -----------------------------------------------------------------
#
# One small key=value record per task, published by rename so the loop can never
# observe a half-written file and never has to coordinate with the agent that
# wrote it. The loop only ever reads it, and re-reads it fresh every poll, so
# re-arming with a later deadline is honoured on the next tick.

record_path() { printf '%s/%s.runpod-watch\n' "$STATE" "$1"; }
log_path() { printf '%s/%s.runpod-watch.log\n' "$STATE" "$1"; }
pid_path() { printf '%s/%s.runpod-watch.pid\n' "$STATE" "$1"; }
alarm_path() { printf '%s/%s.runpod-watch.alarms\n' "$STATE" "$1"; }
observed_path() { printf '%s/%s.runpod-watch.observed\n' "$STATE" "$1"; }
status_path() { printf '%s/%s.status\n' "$STATE" "$1"; }

REC_POD=
REC_DEADLINE=
REC_CEILING_SECONDS=
REC_CEILING_USD=
REC_RATE_USD_HR=

# Reads the record into REC_*. Returns 1 on anything it cannot trust: absent,
# wrong tag, unparseable, or missing a field the loop needs. Callers treat every
# failure as "alarm, do not terminate".
record_read() {
  local file=$1 line key value tag_seen=0
  REC_POD='' REC_DEADLINE='' REC_CEILING_SECONDS='' REC_CEILING_USD='' REC_RATE_USD_HR=''
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$tag_seen" -eq 0 ]; then
      [ "$line" = "$RECORD_TAG" ] || return 1
      tag_seen=1
      continue
    fi
    [ -n "$line" ] || continue
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || return 1
    case "$key" in
      pod) REC_POD=$value ;;
      deadline_epoch) REC_DEADLINE=$value ;;
      ceiling_seconds) REC_CEILING_SECONDS=$value ;;
      ceiling_usd) REC_CEILING_USD=$value ;;
      rate_usd_hr) REC_RATE_USD_HR=$value ;;
      *) ;;
    esac
  done < "$file"
  [ "$tag_seen" -eq 1 ] || return 1
  pod_id_valid "$REC_POD" || return 1
  is_safe_uint "$REC_DEADLINE" || return 1
  [ -z "$REC_CEILING_SECONDS" ] || is_safe_uint "$REC_CEILING_SECONDS" || return 1
  return 0
}

# --- the loop's derived state ------------------------------------------------
#
# The effective deletion instant is not in the record: it depends on when the
# POD started, which only the loop observes. The loop republishes what it is
# actually enforcing here, by rename, so `status` reports the instant in force
# and the anchor it came from instead of a figure nobody is enforcing.
#
# It also carries the POD the anchor belongs to, and it outlives the loop
# process. "First sighting wins" is a claim about the pod's own uptime, so it
# has to hold across a re-arm too: a pod whose runtime restarted reports fresh
# uptime, and re-deriving the anchor from that would buy the ceiling the whole
# spend that came before. A stored anchor is reused for the SAME pod and
# discarded for a different one.

observed_write() {
  local task=$1 pod=$2 start=$3 anchor=$4 effective=$5 source=$6 stamp=$7 tmp
  tmp=$(mktemp "$STATE/.fm-runpod-observed.XXXXXX" 2>/dev/null) || return 0
  {
    printf '%s\n' "$OBSERVED_TAG"
    printf 'pod=%s\n' "$pod"
    [ -z "$start" ] || printf 'pod_start_epoch=%s\n' "$start"
    printf 'anchor=%s\n' "$anchor"
    printf 'effective_deadline_epoch=%s\n' "$effective"
    printf 'effective_source=%s\n' "$source"
    printf 'updated_epoch=%s\n' "$stamp"
  } > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 0; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$(observed_path "$task")" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null || true
}

observed_anchor() {  # <task> <pod> -> the stored anchor for THIS pod, if any
  local task=$1 pod=$2 file stored start
  file=$(observed_path "$task")
  stored=$(observed_get "$file" pod) || return 1
  [ "$stored" = "$pod" ] || return 1
  start=$(observed_get "$file" pod_start_epoch) || return 1
  is_safe_uint "$start" || return 1
  printf '%s' "$start"
}

observed_get() {
  local file=$1 key=$2 line tag_seen=0
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$tag_seen" -eq 0 ]; then
      [ "$line" = "$OBSERVED_TAG" ] || return 1
      tag_seen=1
      continue
    fi
    case "$line" in
      "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done < "$file"
  return 1
}

# --- logging and alarms -----------------------------------------------------

KEY_SCRUB=

log_line() {
  local task=$1 text=$2 stamp
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown-time')
  if [ -n "$KEY_SCRUB" ]; then
    text=${text//"$KEY_SCRUB"/[redacted]}
  fi
  printf '%s %s\n' "$stamp" "$text" >> "$(log_path "$task")" 2>/dev/null || true
}

# Every line this watchdog writes to the status channel carries a key of its
# own, one per condition. An unkeyed `blocked:` line folds under the shared
# `default` key in bin/fm-classify-lib.sh, so it would drop a crewmate's open
# decision on the same status file - and a crewmate's unrelated `resolved:`
# would clear a still-true alarm about a pod that is still billing. Keying per
# condition, rather than per task, is what lets the condition that actually
# cleared close its own alarm without closing the others.
decision_key() { printf 'runpod-watch-%s-%s' "$1" "$2"; }

status_append() {
  local task=$1 line=$2
  printf '%s\n' "$line" >> "$(status_path "$task")" 2>/dev/null || true
}

# A completed action, not an open question: `note:` is surfaced by the wake
# drain's unread-status section and never folds into an open decision, so a
# verified stop cannot leave behind a blocker only a human could close.
notify() {
  local task=$1 text=$2
  log_line "$task" "note $text"
  if [ -n "$KEY_SCRUB" ]; then
    text=${text//"$KEY_SCRUB"/[redacted]}
  fi
  status_append "$task" "note: $text"
}

# The alarm ledger. One row per open condition, as
# "<condition>\t<epoch>\t<subject>", where the subject names the thing the alarm
# is ABOUT - the pod id, for a condition that is about a pod. Binding the row to
# its subject is what stops a later sighting of a DIFFERENT pod from answering
# for it: a warning raised about pod A must outlive any amount of news about
# pod B. Conditions that are about the task rather than a pod carry no subject.
ledger_last() {  # <ledger> <condition> <subject> -> newest matching epoch
  local ledger=$1 condition=$2 subject=$3 c t s last=''
  [ -f "$ledger" ] || return 1
  while IFS="$(printf '\t')" read -r c t s || [ -n "$c" ]; do
    if [ "$c" = "$condition" ] && [ "${s:-}" = "$subject" ]; then last=${t:-}; fi
  done < "$ledger"
  printf '%s' "$last"
}

# Alarms wake firstmate through the task's own status channel. One alarm per
# distinct condition per ALARM_REPEAT_SECONDS: an unattended watchdog that
# alarms every poll would bury the fleet, and one that alarms once would be
# missed if that wake was lost.
alarm() {
  local task=$1 condition=$2 text=$3 subject=${4:-} ledger last now
  ledger=$(alarm_path "$task")
  now=$(now_epoch) || now=
  last=$(ledger_last "$ledger" "$condition" "$subject") || last=
  log_line "$task" "alarm[$condition] $text"
  # A clock that cannot be read, or that stepped backwards, cannot establish
  # that this condition was reported recently. Going silent is the wrong way to
  # fail on the channel that says a pod may still be billing, so only a strictly
  # forward delta inside the window suppresses.
  if is_safe_uint "$now" && is_safe_uint "$last" && [ "$now" -gt "$last" ] \
    && [ "$((now - last))" -lt "$ALARM_REPEAT_SECONDS" ]; then
    return 0
  fi
  if [ -n "$KEY_SCRUB" ]; then
    text=${text//"$KEY_SCRUB"/[redacted]}
  fi
  status_append "$task" "blocked [key=$(decision_key "$task" "$condition")]: $text"
  printf '%s\t%s\t%s\n' "$condition" "$now" "$subject" >> "$ledger" 2>/dev/null || true
}

# An alarm this watchdog raised is an alarm this watchdog closes - but only the
# rows for the subject that actually cleared. One decision key covers the whole
# condition, so it closes when the LAST subject holding it open clears; while
# another still holds it, the row goes but the decision stays open.
clear_alarm() {
  local task=$1 condition=$2 text=$3 subject=${4:-} ledger tmp c t s dropped=0 remaining=0
  ledger=$(alarm_path "$task")
  [ -f "$ledger" ] || return 0
  tmp=$(mktemp "$STATE/.fm-runpod-alarms.XXXXXX" 2>/dev/null) || return 0
  while IFS="$(printf '\t')" read -r c t s || [ -n "$c" ]; do
    [ -n "$c" ] || continue
    if [ "$c" = "$condition" ]; then
      if [ "${s:-}" = "$subject" ]; then
        dropped=1
        continue
      fi
      remaining=1
    fi
    printf '%s\t%s\t%s\n' "$c" "${t:-}" "${s:-}" >> "$tmp" 2>/dev/null || true
  done < "$ledger"
  if [ "$dropped" -eq 0 ]; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 0
  fi
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$ledger" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null || true; return 0; }
  [ -s "$ledger" ] || rm -f -- "$ledger" 2>/dev/null || true
  [ "$remaining" -eq 0 ] || return 0
  log_line "$task" "cleared[$condition] $text"
  if [ -n "$KEY_SCRUB" ]; then
    text=${text//"$KEY_SCRUB"/[redacted]}
  fi
  status_append "$task" "resolved [key=$(decision_key "$task" "$condition")]: $text"
}

# Every way this watch ends - the pod leaving, a verified stop, a disarm, a
# re-arm - retires the watch, and a retired watch must not leave a blocker only
# a human could close. Closes whatever conditions are still open and drops the
# ledger with them.
retire_alarms() {
  local task=$1 text=$2 ledger tmp c t s seen=''
  ledger=$(alarm_path "$task")
  [ -f "$ledger" ] || return 0
  tmp=$(mktemp "$STATE/.fm-runpod-alarms.XXXXXX" 2>/dev/null) || return 0
  while IFS="$(printf '\t')" read -r c t s || [ -n "$c" ]; do
    [ -n "$c" ] || continue
    # The one alarm retiring never closes. It says a rented pod may be billing
    # under an id this watchdog was never given, and retiring the watch does not
    # make that untrue - only sighting THAT pod does.
    if [ "$c" = pod-never-seen ]; then
      printf '%s\t%s\t%s\n' "$c" "${t:-}" "${s:-}" >> "$tmp" 2>/dev/null || true
      continue
    fi
    case " $seen " in *" $c "*) continue ;; esac
    seen="$seen $c"
    log_line "$task" "cleared[$c] $text"
    status_append "$task" "resolved [key=$(decision_key "$task" "$c")]: $text"
  done < "$ledger"
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$ledger" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null || true; return 0; }
  [ -s "$ledger" ] || rm -f -- "$ledger" 2>/dev/null || true
}

# --- RunPod API -------------------------------------------------------------

# Reads one assignment out of a .env-style file WITHOUT executing it, on the
# same terms as fmx_env_get (bin/fm-x-lib.sh): last assignment wins, a leading
# `export ` and surrounding whitespace are tolerated, and one layer of matching
# quotes is stripped. .env is the home's shared multi-key operator file, so
# sourcing it would let an unrelated value's apostrophe or unquoted space empty
# this key - and because the loop re-reads it every poll, an edit made after
# arming would silently disarm a live killswitch.
env_value() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 1
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 1
  [ -n "$line" ] || return 1
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}
  val=${val%"${val##*[![:space:]]}"}
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

load_key() {
  local file=$1 value
  value=$(env_value RUNPOD_API_KEY "$file") || return 1
  [ -n "$value" ] || return 1
  RUNPOD_API_KEY=$value
  KEY_SCRUB=$value
  return 0
}

# graphql <json-body-file> -> response body on stdout, non-zero on transport
# failure. The key reaches curl through a config file on stdin, never argv.
graphql() {
  local body=$1
  printf 'header = "Authorization: Bearer %s"\n' "$RUNPOD_API_KEY" \
    | curl -sS --max-time "$HTTP_TIMEOUT" -X POST "$API_URL" \
        -H 'Content-Type: application/json' --data-binary @"$body" --config -
}

request_file() {
  local query=$1 tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/.fm-runpod-req.XXXXXX") || return 1
  chmod 0600 "$tmp" 2>/dev/null || true
  printf '{"query":"%s"}' "$query" > "$tmp" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$tmp"
}

# pod_present <pod-id>
#   0 = the account lists this pod (it is still there)
#   1 = the account was read successfully and this pod is absent
#   2 = could not establish either way; the caller must not conclude anything
# Sets POD_START_EPOCH to the instant the pod started when the same response
# carries it, and to empty when it does not. The start instant rides along with
# the presence check rather than costing a second request. `uptimeInSeconds` is
# the only source for it: it can only be read off a RUNNING pod, so it cannot
# anchor a spend ceiling to a moment the pod was not accruing uptime.
POD_START_EPOCH=
pod_present() {
  local pod=$1 req resp uptime now
  POD_START_EPOCH=
  req=$(request_file 'query { myself { pods { id runtime { uptimeInSeconds } } } }') || return 2
  resp=$(graphql "$req" 2>/dev/null) || { rm -f "$req"; return 2; }
  rm -f "$req"
  [ -n "$resp" ] || return 2
  printf '%s' "$resp" | jq -e '.data.myself.pods' >/dev/null 2>&1 || return 2
  printf '%s' "$resp" | jq -e --arg id "$pod" 'any(.data.myself.pods[]; .id == $id)' >/dev/null 2>&1 \
    || return 1
  uptime=$(printf '%s' "$resp" \
    | jq -r --arg id "$pod" '[.data.myself.pods[] | select(.id == $id) | .runtime.uptimeInSeconds][0] // empty' 2>/dev/null) \
    || uptime=
  if is_safe_uint "$uptime" && now=$(now_epoch) && [ "$now" -gt "$uptime" ]; then
    POD_START_EPOCH=$((now - uptime))
  fi
  return 0
}

# terminate_call <pod-id> -> 0 when the API accepted the mutation, 1 otherwise.
# Never treated as proof either way; pod_present is the proof. "pod not found to
# terminate" is NOT read as success: it cannot tell "already gone" from "never
# existed", and the latter is exactly the wrong id this watchdog must not report
# a stop for. A pod that really had gone still verifies absent on the read below.
TERMINATE_DETAIL=
terminate_call() {
  local pod=$1 req resp
  TERMINATE_DETAIL=
  req=$(request_file "mutation { podTerminate(input: {podId: \\\"$pod\\\"}) }") || return 1
  resp=$(graphql "$req" 2>/dev/null) || { rm -f "$req"; TERMINATE_DETAIL='transport failure'; return 1; }
  rm -f "$req"
  if printf '%s' "$resp" | jq -e '.errors' >/dev/null 2>&1; then
    TERMINATE_DETAIL=$(printf '%s' "$resp" | jq -r '[.errors[].message] | join("; ")' 2>/dev/null | tr -d '\n')
    return 1
  fi
  printf '%s' "$resp" | jq -e 'has("data")' >/dev/null 2>&1 || { TERMINATE_DETAIL='unparseable response'; return 1; }
  return 0
}

# --- subcommands ------------------------------------------------------------

cmd_arm() {
  local task='' pod='' deadline_raw='' ceiling='' rate='' \
    declared now record tmp seconds log_mark ceiling_note
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) need_value "$#" "$1"; task=$2; shift 2 ;;
      --pod) need_value "$#" "$1"; pod=$2; shift 2 ;;
      --deadline) need_value "$#" "$1"; deadline_raw=$2; shift 2 ;;
      --ceiling-usd) need_value "$#" "$1"; ceiling=$2; shift 2 ;;
      --rate-usd-hr) need_value "$#" "$1"; rate=$2; shift 2 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  task_id_valid "$task" || die 'arm: --task is required and must be a task id' 2
  pod_id_valid "$pod" || die 'arm: --pod is required and must be a RunPod pod id' 2
  [ -n "$deadline_raw" ] || die 'arm: --deadline is required; this watchdog enforces a deadline the run already declared, it does not invent one' 2
  declared=$(parse_when "$deadline_raw") || die "arm: could not read --deadline '$deadline_raw' as an instant" 2
  [ -d "$STATE" ] || die "arm: state directory is unavailable: $STATE"
  command -v jq >/dev/null 2>&1 || die 'arm: jq is required'
  command -v curl >/dev/null 2>&1 || die 'arm: curl is required'
  command -v setsid >/dev/null 2>&1 || die 'arm: setsid is required to detach the watchdog from this session'
  load_key "$ENV_FILE" || die "arm: RUNPOD_API_KEY is not readable from $ENV_FILE"

  now=$(now_epoch) || die 'arm: the clock is unreadable'
  [ "$declared" -gt "$now" ] || die 'arm: the declared deadline has already passed'

  seconds=
  if [ -n "$ceiling" ] || [ -n "$rate" ]; then
    if ! is_number "$ceiling" || ! is_number "$rate"; then
      die 'arm: --ceiling-usd and --rate-usd-hr must be given together as numbers' 2
    fi
    # The ceiling becomes a DURATION of uptime, never an instant: an instant
    # derived here would be anchored to whenever arming happened, so arming an
    # hour late - or re-arming - would silently raise the bound. The loop
    # anchors this duration to the pod's own start instant.
    seconds=$(awk -v c="$ceiling" -v r="$rate" 'BEGIN { if (r <= 0) exit 1; printf "%d", (c / r) * 3600 }') \
      || die 'arm: --rate-usd-hr must be greater than zero' 2
    is_safe_uint "$seconds" || die 'arm: could not derive a ceiling window' 2
  fi

  record=$(record_path "$task")
  umask 077
  tmp=$(mktemp "$STATE/.fm-runpod-watch.XXXXXX") || die 'arm: could not stage the record'
  {
    printf '%s\n' "$RECORD_TAG"
    printf 'task=%s\n' "$task"
    printf 'pod=%s\n' "$pod"
    printf 'deadline_epoch=%s\n' "$declared"
    [ -z "$seconds" ] || printf 'ceiling_seconds=%s\n' "$seconds"
    [ -z "$ceiling" ] || printf 'ceiling_usd=%s\n' "$ceiling"
    [ -z "$rate" ] || printf 'rate_usd_hr=%s\n' "$rate"
    printf 'armed_epoch=%s\n' "$now"
  } > "$tmp" || { rm -f "$tmp"; die 'arm: could not write the record'; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$record" || { rm -f "$tmp"; die 'arm: could not publish the record'; }

  record_read "$record" || die 'arm: the published record did not read back'

  stop_existing "$task"
  retire_alarms "$task" "the pod watchdog for $task was re-armed; its earlier alarms are superseded"
  # Re-arming the SAME pod must not hand it a fresh anchor, or a re-arm after a
  # runtime restart would silently buy more ceiling than the run declared.
  observed_anchor "$task" "$pod" >/dev/null \
    || rm -f -- "$(observed_path "$task")" 2>/dev/null || true
  log_line "$task" "armed pod=$pod deadline=$declared ceiling_seconds=${seconds:-none}"

  # Own session, no controlling terminal, no shared descriptors: this is what
  # lets it outlive the harness process group that started it.
  log_mark=$(wc -c < "$(log_path "$task")" 2>/dev/null | tr -d '[:space:]')
  is_uint "$log_mark" || log_mark=0
  setsid nohup "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" run --task "$task" \
    </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true

  wait_for_start "$task" "$log_mark" || die 'arm: the watchdog did not come up'
  ceiling_note=''
  [ -z "$seconds" ] || ceiling_note=", ceiling $ceiling USD at $rate USD/hr caps uptime at ${seconds}s measured from the pod's own start"
  printf 'armed: pod %s, declared deadline %s%s, pid %s\n' \
    "$pod" "$(iso_utc "$declared")" "$ceiling_note" \
    "$(cat "$(pid_path "$task")" 2>/dev/null)"
}

# A live pid proves it came up. So does a start line the loop appended after this
# arm's mark: a loop that finds the pod already gone finishes correctly within
# milliseconds, and that clean ending must not be misreported as a failed launch.
wait_for_start() {
  local task=$1 mark=$2 i=0 pid
  while [ "$i" -lt 100 ]; do
    pid=$(cat "$(pid_path "$task")" 2>/dev/null || true)
    if pid_live "$pid"; then
      return 0
    fi
    if tail -c "+$((mark + 1))" "$(log_path "$task")" 2>/dev/null \
      | grep -qF 'watchdog running pid='; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

stop_existing() {
  local task=$1 pid i=0
  pid=$(cat "$(pid_path "$task")" 2>/dev/null || true)
  pid_live "$pid" || return 0
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  # A watchdog that ignored its stop would keep holding a stale record and
  # could still terminate a pod after the operator retired it, so escalate
  # rather than leave an unaccountable process behind.
  kill -0 "$pid" 2>/dev/null || return 0
  kill -KILL "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
}

cmd_disarm() {
  local task=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) need_value "$#" "$1"; task=$2; shift 2 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  task_id_valid "$task" || die 'disarm: --task is required' 2
  stop_existing "$task"
  retire_alarms "$task" "the pod watchdog for $task was disarmed; its alarms no longer stand"
  # The observed anchor is a fact about the POD's uptime, not about this watch,
  # so retiring the watch does not invalidate it. Only arming a different pod
  # does, and that is where it is discarded.
  rm -f -- "$(record_path "$task")" "$(pid_path "$task")" 2>/dev/null || true
  log_line "$task" 'disarmed'
  printf 'disarmed: %s\n' "$task"
}

cmd_status() {
  local task='' pid found=0 f id live obs effective source anchor ceiling_note
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) need_value "$#" "$1"; task=$2; shift 2 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  for f in "$STATE"/*.runpod-watch; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .runpod-watch)
    [ -z "$task" ] || [ "$task" = "$id" ] || continue
    found=1
    if ! record_read "$f"; then
      printf '%s: RECORD UNREADABLE - this watchdog will alarm and will not terminate anything\n' "$id"
      continue
    fi
    pid=$(cat "$(pid_path "$id")" 2>/dev/null || true)
    live=stopped
    if pid_live "$pid"; then live=running; fi
    # Only the loop knows the pod's start instant, so only the loop can say
    # which instant is in force. Until it has, the declared deadline is the
    # only thing being enforced and this says exactly that rather than
    # printing a ceiling nothing is applying.
    obs=$(observed_path "$id")
    effective='' source='' anchor=''
    if [ "$(observed_get "$obs" pod 2>/dev/null || printf '')" = "$REC_POD" ]; then
      effective=$(observed_get "$obs" effective_deadline_epoch) || effective=
      source=$(observed_get "$obs" effective_source) || source=
      anchor=$(observed_get "$obs" anchor) || anchor=
    fi
    if ! is_safe_uint "$effective"; then
      effective=$REC_DEADLINE
      source=declared
      anchor=unresolved
    fi
    ceiling_note=''
    if [ -n "$REC_CEILING_SECONDS" ]; then
      ceiling_note=" ceiling=${REC_CEILING_USD:-none}usd@${REC_RATE_USD_HR:-none}/hr=${REC_CEILING_SECONDS}s-of-uptime"
    fi
    printf '%s: pod=%s deadline=%s source=%s anchor=%s declared-deadline=%s%s watchdog=%s pid=%s\n' \
      "$id" "$REC_POD" "$(iso_utc "$effective")" "${source:-declared}" "${anchor:-unresolved}" \
      "$(iso_utc "$REC_DEADLINE")" "$ceiling_note" "$live" "${pid:-none}"
  done
  [ "$found" -eq 1 ] || printf 'no armed pod watchdog\n'
}

# --- the loop ---------------------------------------------------------------

RUN_TASK=
SLEEP_PID=
run_cleanup() {
  [ -z "$SLEEP_PID" ] || kill -TERM "$SLEEP_PID" 2>/dev/null || true
  [ -z "$RUN_TASK" ] || rm -f -- "$(pid_path "$RUN_TASK")" 2>/dev/null || true
}

# bash defers a trapped signal until the current FOREGROUND command finishes, so
# a plain `sleep 60` between polls would swallow a stop for a whole poll
# interval. Sleeping in a child and waiting on it lets the signal land at once.
nap() {
  sleep "$1" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=
}

terminate_and_verify() {
  local task=$1 pod=$2 i=0 rc
  log_line "$task" "deadline passed; terminating pod=$pod"
  while :; do
    if terminate_call "$pod"; then
      log_line "$task" "podTerminate accepted pod=$pod${TERMINATE_DETAIL:+ ($TERMINATE_DETAIL)}"
    else
      log_line "$task" "podTerminate failed pod=$pod${TERMINATE_DETAIL:+ ($TERMINATE_DETAIL)}"
    fi
    i=0
    while [ "$i" -lt "$VERIFY_ATTEMPTS" ]; do
      pod_present "$pod"
      rc=$?
      [ "$rc" -eq 2 ] || clear_alarm "$task" api-unreachable \
        "the pod watchdog for $task can reach RunPod again"
      case "$rc" in
        1)
          log_line "$task" "verified absent from the pod list pod=$pod"
          return 0
          ;;
        0) log_line "$task" "still listed pod=$pod" ;;
        *) log_line "$task" "pod list unreadable while verifying pod=$pod" ;;
      esac
      i=$((i + 1))
      nap "$VERIFY_INTERVAL"
    done
    alarm "$task" terminate-unverified \
      "rented pod $pod passed its deletion deadline and its termination is NOT verified - it may still be billing; verify and stop it by hand"
  done
}

cmd_run() {
  local task='' record now present_rc effective source anchor ceiling_deadline \
    watched_pod='' pod_start='' ever_seen=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) need_value "$#" "$1"; task=$2; shift 2 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  task_id_valid "$task" || die 'run: --task is required' 2
  RUN_TASK=$task
  trap 'run_cleanup; exit 143' TERM
  trap 'run_cleanup; exit 129' HUP
  trap 'run_cleanup; exit 130' INT
  trap run_cleanup EXIT
  # SIGHUP is already ignored by the nohup in `arm`; the trap above keeps the
  # pid file honest if something signals the loop directly.

  record=$(record_path "$task")
  printf '%s\n' "$$" > "$(pid_path "$task")" 2>/dev/null || true
  log_line "$task" "watchdog running pid=$$"

  while :; do
    if ! load_key "$ENV_FILE"; then
      alarm "$task" key-unreadable \
        "the pod watchdog for $task cannot read its RunPod credential, so it cannot stop the meter; it will not terminate anything"
      nap "$POLL_SECONDS"
      continue
    fi
    clear_alarm "$task" key-unreadable \
      "the pod watchdog for $task can read its RunPod credential again"

    if ! record_read "$record"; then
      # The record is the only thing that says which pod may be stopped and
      # when. Without it there is nothing this watchdog is entitled to do.
      alarm "$task" record-unreadable \
        "the pod watchdog for $task cannot read the run's deadline record, so it will NOT terminate anything; check the rented pod by hand"
      nap "$POLL_SECONDS"
      continue
    fi
    clear_alarm "$task" record-unreadable \
      "the pod watchdog for $task can read the run's deadline record again"

    if ! now=$(now_epoch); then
      alarm "$task" clock-unreadable \
        "the pod watchdog for $task cannot read the clock, so it will NOT terminate anything; check the rented pod by hand"
      nap "$POLL_SECONDS"
      continue
    fi
    clear_alarm "$task" clock-unreadable \
      "the pod watchdog for $task can read the clock again"

    # Sightings and the anchor belong to one pod id. A record that names a
    # different pod is a different watch and starts from nothing observed.
    if [ "$REC_POD" != "$watched_pod" ]; then
      watched_pod=$REC_POD
      ever_seen=0
      pod_start=$(observed_anchor "$task" "$REC_POD") || pod_start=''
      [ -z "$pod_start" ] \
        || log_line "$task" "pod $REC_POD anchor carried over from $(iso_utc "$pod_start")"
    fi

    pod_present "$REC_POD"
    present_rc=$?
    # A list read that parsed is proof the API is reachable, whether or not this
    # pod was in it. Only the read failing leaves that alarm standing.
    [ "$present_rc" -eq 2 ] || clear_alarm "$task" api-unreachable \
      "the pod watchdog for $task can reach RunPod again"
    case "$present_rc" in
      0)
        [ "$ever_seen" -eq 1 ] || clear_alarm "$task" pod-never-seen \
          "the pod watchdog for $task has now seen pod $REC_POD in the account's pod list" \
          "$REC_POD"
        ever_seen=1
        # First sighting wins: a pod that restarts reports fresh uptime, and
        # re-anchoring on that would push the ceiling later than the spend it
        # is meant to bound.
        if [ -z "$pod_start" ] && [ -n "$POD_START_EPOCH" ]; then
          pod_start=$POD_START_EPOCH
          log_line "$task" "pod $REC_POD started at $(iso_utc "$pod_start"); ceiling anchored there"
        fi
        ;;
      1)
        # A pod that was there and is now gone is the NORMAL ending: the run
        # finished and cleaned up. A pod that was NEVER there is the opposite -
        # nothing is being guarded and a real rented pod may be billing under
        # an id this watchdog was never given.
        if [ "$ever_seen" -eq 0 ]; then
          alarm "$task" pod-never-seen \
            "the pod watchdog for $task has never seen pod $REC_POD in the account's pod list, so it is guarding nothing and will terminate nothing - the pod id may be wrong or stale while a rented pod keeps billing; check the account by hand" \
            "$REC_POD"
          nap "$POLL_SECONDS"
          continue
        fi
        retire_alarms "$task" \
          "the pod watchdog for $task has finished: pod $REC_POD has left the account's pod list and there is nothing left to guard"
        log_line "$task" "pod $REC_POD is no longer listed; nothing left to guard"
        rm -f -- "$record" "$(observed_path "$task")" 2>/dev/null || true
        return 0
        ;;
      *)
        alarm "$task" api-unreachable \
          "the pod watchdog for $task cannot reach RunPod to check pod $REC_POD; it keeps waiting and will not terminate anything on a failed read"
        ;;
    esac

    # A pod this watch has never sighted cannot be stopped, because there is
    # nothing here to stop: its absence is the original symptom, not proof of a
    # stop. No deadline is evaluated for it on ANY path, so a passed deadline
    # plus a transient read failure can never be read as a completed stop.
    if [ "$ever_seen" -eq 0 ]; then
      nap "$POLL_SECONDS"
      continue
    fi

    effective=$REC_DEADLINE
    source=declared
    anchor=none
    if [ -n "$REC_CEILING_SECONDS" ]; then
      if [ -n "$pod_start" ]; then
        anchor='pod-start'
        clear_alarm "$task" ceiling-anchor-unknown \
          "the pod watchdog for $task can read when pod $REC_POD started, so the ceiling is in force again"
        ceiling_deadline=$((pod_start + REC_CEILING_SECONDS))
        if [ "$ceiling_deadline" -lt "$effective" ]; then
          effective=$ceiling_deadline
          source=ceiling
        fi
      else
        anchor=unknown
        # Guessing the anchor from this process's own clock is what would let a
        # late arm quietly raise the bound, so the ceiling simply is not in
        # force until the pod says when it started.
        if [ "$present_rc" -eq 0 ]; then
          alarm "$task" ceiling-anchor-unknown \
            "the pod watchdog for $task cannot read when pod $REC_POD started, so the ${REC_CEILING_USD:-declared} USD ceiling is NOT being enforced; only the declared deadline is"
        fi
      fi
    fi
    observed_write "$task" "$REC_POD" "$pod_start" "$anchor" "$effective" "$source" "$now"

    # An evaluation that could not be made is not a deadline that passed: only
    # an affirmative comparison authorizes a termination.
    if [ "$now" -ge "$effective" ] 2>/dev/null; then
      terminate_and_verify "$task" "$REC_POD"
      retire_alarms "$task" \
        "the pod watchdog for $task has finished: pod $REC_POD is stopped and its absence is confirmed"
      # A completed stop is an event, not a blocker: reporting it as one would
      # leave an open decision on this task that only this watchdog could close,
      # and it exits here.
      notify "$task" \
        "rented pod $REC_POD passed the deletion deadline this run declared (in force: $source) and has been stopped; absence confirmed by listing the account's pods"
      rm -f -- "$record" "$(observed_path "$task")" 2>/dev/null || true
      log_line "$task" 'watchdog exiting after verified termination'
      return 0
    fi

    nap "$POLL_SECONDS"
  done
}

case "${1:-}" in
  arm) shift; cmd_arm "$@" ;;
  run) shift; cmd_run "$@" ;;
  status) shift; cmd_status "$@" ;;
  disarm) shift; cmd_disarm "$@" ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 2 ;;
esac
