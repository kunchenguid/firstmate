#!/usr/bin/env bash
# Detached killswitch for a rented RunPod pod, able to stop the meter after the
# agent that rented it is gone.
#
# Usage:
#   fm-runpod-watchdog.sh arm --task <id> --pod <pod-id> --deadline <when>
#                             [--ceiling-usd <n> --rate-usd-hr <n>]
#                             [--progress-file <path> --progress-grace <seconds>]
#   fm-runpod-watchdog.sh status [--task <id>]
#   fm-runpod-watchdog.sh disarm --task <id>
#   fm-runpod-watchdog.sh probe
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
# kill healthy runs mid-pack. An optional progress artifact the run itself
# touches is read too, but a stalled artifact only ALARMS - it never terminates,
# because "stalled" is an inference and a long pack phase looks identical.
#
# FAIL TOWARD NOT KILLING.
# Terminating a healthy run destroys work and money already spent, so every
# uncertain state alarms and keeps polling instead of terminating: a missing,
# malformed, or unreadable record; an unreadable clock; an unreachable or
# erroring API. The single condition that authorizes termination is a deadline
# that has provably passed on the wall clock, which needs no inference.
#
# DELETION IS VERIFIED, NEVER ASSUMED.
# A successful podTerminate response is not evidence. The loop lists the
# account's pods afterwards and only reports the pod stopped once it is absent
# from that list; an unverified termination alarms and keeps retrying forever.
#
# THE KEY NEVER APPEARS ANYWHERE.
# RUNPOD_API_KEY is read from the gitignored .env and handed to curl through a
# config file on stdin, so it is absent from argv and therefore from ps(1).
# Nothing this script writes - log line, status append, error text - carries it.
#
# Alarms are appended to state/<task>.status, which is firstmate's wake channel,
# rate-limited per condition so an unattended alarm cannot flood it. The full
# trail is state/<task>.runpod-watch.log.
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

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
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
  is_uint "$t" || return 1
  printf '%s\n' "$t"
}

# Accepts an epoch second or anything date(1) understands, notably the ISO-8601
# UTC instants run-state records already carry (2026-09-12T02:19:41Z).
parse_when() {
  local raw=$1 epoch
  if is_uint "$raw"; then
    printf '%s\n' "$raw"
    return 0
  fi
  epoch=$(date -u -d "$raw" +%s 2>/dev/null) || return 1
  is_uint "$epoch" || return 1
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
status_path() { printf '%s/%s.status\n' "$STATE" "$1"; }

REC_POD=
REC_DEADLINE=
REC_DEADLINE_SOURCE=
REC_PROGRESS_FILE=
REC_PROGRESS_GRACE=
REC_CEILING_USD=
REC_RATE_USD_HR=

# Reads the record into REC_*. Returns 1 on anything it cannot trust: absent,
# wrong tag, unparseable, or missing a field the loop needs. Callers treat every
# failure as "alarm, do not terminate".
record_read() {
  local file=$1 line key value tag_seen=0
  REC_POD='' REC_DEADLINE='' REC_DEADLINE_SOURCE=''
  REC_PROGRESS_FILE='' REC_PROGRESS_GRACE='' REC_CEILING_USD='' REC_RATE_USD_HR=''
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
      deadline_source) REC_DEADLINE_SOURCE=$value ;;
      progress_file) REC_PROGRESS_FILE=$value ;;
      progress_grace_seconds) REC_PROGRESS_GRACE=$value ;;
      ceiling_usd) REC_CEILING_USD=$value ;;
      rate_usd_hr) REC_RATE_USD_HR=$value ;;
      *) ;;
    esac
  done < "$file"
  [ "$tag_seen" -eq 1 ] || return 1
  pod_id_valid "$REC_POD" || return 1
  is_uint "$REC_DEADLINE" || return 1
  [ -z "$REC_PROGRESS_GRACE" ] || is_uint "$REC_PROGRESS_GRACE" || return 1
  return 0
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

# Alarms wake firstmate through the task's own status channel. One alarm per
# distinct condition per ALARM_REPEAT_SECONDS: an unattended watchdog that
# alarms every poll would bury the fleet, and one that alarms once would be
# missed if that wake was lost.
alarm() {
  local task=$1 condition=$2 text=$3 ledger last now
  ledger=$(alarm_path "$task")
  now=$(now_epoch) || now=0
  last=$(grep -F -- "$condition	" "$ledger" 2>/dev/null | tail -1 | cut -f2) || last=
  log_line "$task" "alarm[$condition] $text"
  if is_uint "$last" && is_uint "$now" && [ "$((now - last))" -lt "$ALARM_REPEAT_SECONDS" ]; then
    return 0
  fi
  if [ -n "$KEY_SCRUB" ]; then
    text=${text//"$KEY_SCRUB"/[redacted]}
  fi
  printf 'blocked: %s\n' "$text" >> "$(status_path "$task")" 2>/dev/null || true
  printf '%s\t%s\n' "$condition" "$now" >> "$ledger" 2>/dev/null || true
}

# --- RunPod API -------------------------------------------------------------

load_key() {
  local file=$1
  [ -f "$file" ] || return 1
  # shellcheck disable=SC1090 # operator-provided gitignored .env
  RUNPOD_API_KEY=$(set -a; . "$file" >/dev/null 2>&1; set +a; printf '%s' "${RUNPOD_API_KEY:-}") || return 1
  [ -n "$RUNPOD_API_KEY" ] || return 1
  KEY_SCRUB=$RUNPOD_API_KEY
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
pod_present() {
  local pod=$1 req resp
  req=$(request_file 'query { myself { pods { id } } }') || return 2
  resp=$(graphql "$req" 2>/dev/null) || { rm -f "$req"; return 2; }
  rm -f "$req"
  [ -n "$resp" ] || return 2
  printf '%s' "$resp" | jq -e '.data.myself.pods' >/dev/null 2>&1 || return 2
  if printf '%s' "$resp" | jq -e --arg id "$pod" 'any(.data.myself.pods[]; .id == $id)' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# terminate_call <pod-id> -> 0 when the API accepted it or already had no such
# pod, 1 otherwise. Never treated as proof; pod_present is the proof.
TERMINATE_DETAIL=
terminate_call() {
  local pod=$1 req resp
  TERMINATE_DETAIL=
  req=$(request_file "mutation { podTerminate(input: {podId: \\\"$pod\\\"}) }") || return 1
  resp=$(graphql "$req" 2>/dev/null) || { rm -f "$req"; TERMINATE_DETAIL='transport failure'; return 1; }
  rm -f "$req"
  if printf '%s' "$resp" | jq -e '.errors' >/dev/null 2>&1; then
    TERMINATE_DETAIL=$(printf '%s' "$resp" | jq -r '[.errors[].message] | join("; ")' 2>/dev/null | tr -d '\n')
    case "$TERMINATE_DETAIL" in
      *'not found to terminate'*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  printf '%s' "$resp" | jq -e 'has("data")' >/dev/null 2>&1 || { TERMINATE_DETAIL='unparseable response'; return 1; }
  return 0
}

# --- subcommands ------------------------------------------------------------

cmd_probe() {
  local req resp
  load_key "$ENV_FILE" || die "RUNPOD_API_KEY is not readable from $ENV_FILE"
  command -v jq >/dev/null 2>&1 || die 'jq is required'
  req=$(request_file 'mutation { podTerminate(input: {podId: \"fm-watchdog-probe-does-not-exist\"}) }') \
    || die 'could not build probe request'
  resp=$(graphql "$req" 2>/dev/null) || { rm -f "$req"; die 'RunPod API is unreachable'; }
  rm -f "$req"
  case "$resp" in
    *'not found to terminate'*)
      echo 'probe: write path granted (podTerminate rejected a bogus pod id as not found, not as unauthorized)'
      return 0
      ;;
    *)
      # Never echo the response: it is the one place an auth surface could quote
      # back something derived from the credential.
      die 'probe: write path NOT proven - podTerminate did not answer POD_NOT_FOUND'
      ;;
  esac
}

cmd_arm() {
  local task='' pod='' deadline_raw='' ceiling='' rate='' progress='' grace='' \
    declared ceiling_deadline effective source now record tmp seconds log_mark
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 || true ;;
      --pod) pod=${2:-}; shift 2 || true ;;
      --deadline) deadline_raw=${2:-}; shift 2 || true ;;
      --ceiling-usd) ceiling=${2:-}; shift 2 || true ;;
      --rate-usd-hr) rate=${2:-}; shift 2 || true ;;
      --progress-file) progress=${2:-}; shift 2 || true ;;
      --progress-grace) grace=${2:-}; shift 2 || true ;;
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

  effective=$declared
  source=declared
  ceiling_deadline=
  if [ -n "$ceiling" ] || [ -n "$rate" ]; then
    if ! is_number "$ceiling" || ! is_number "$rate"; then
      die 'arm: --ceiling-usd and --rate-usd-hr must be given together as numbers' 2
    fi
    # The ceiling the run declared, converted ONCE here into a wall-clock
    # instant, so the loop still only ever compares clocks. Uptime times the
    # declared hourly rate is exactly how these runs state their own spend.
    seconds=$(awk -v c="$ceiling" -v r="$rate" 'BEGIN { if (r <= 0) exit 1; printf "%d", (c / r) * 3600 }') \
      || die 'arm: --rate-usd-hr must be greater than zero' 2
    is_uint "$seconds" || die 'arm: could not derive a ceiling deadline' 2
    ceiling_deadline=$((now + seconds))
    if [ "$ceiling_deadline" -lt "$effective" ]; then
      effective=$ceiling_deadline
      source=ceiling
    fi
  fi

  if [ -n "$progress" ]; then
    is_uint "$grace" || die 'arm: --progress-file requires --progress-grace <seconds>' 2
  elif [ -n "$grace" ]; then
    die 'arm: --progress-grace requires --progress-file' 2
  fi

  record=$(record_path "$task")
  umask 077
  tmp=$(mktemp "$STATE/.fm-runpod-watch.XXXXXX") || die 'arm: could not stage the record'
  {
    printf '%s\n' "$RECORD_TAG"
    printf 'task=%s\n' "$task"
    printf 'pod=%s\n' "$pod"
    printf 'deadline_epoch=%s\n' "$effective"
    printf 'deadline_source=%s\n' "$source"
    printf 'declared_deadline_epoch=%s\n' "$declared"
    [ -z "$ceiling_deadline" ] || printf 'ceiling_deadline_epoch=%s\n' "$ceiling_deadline"
    [ -z "$ceiling" ] || printf 'ceiling_usd=%s\n' "$ceiling"
    [ -z "$rate" ] || printf 'rate_usd_hr=%s\n' "$rate"
    [ -z "$progress" ] || printf 'progress_file=%s\n' "$progress"
    [ -z "$grace" ] || printf 'progress_grace_seconds=%s\n' "$grace"
    printf 'armed_epoch=%s\n' "$now"
  } > "$tmp" || { rm -f "$tmp"; die 'arm: could not write the record'; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$record" || { rm -f "$tmp"; die 'arm: could not publish the record'; }

  record_read "$record" || die 'arm: the published record did not read back'

  stop_existing "$task"
  rm -f -- "$(alarm_path "$task")" 2>/dev/null || true
  log_line "$task" "armed pod=$pod deadline=$effective source=$source"

  # Own session, no controlling terminal, no shared descriptors: this is what
  # lets it outlive the harness process group that started it.
  log_mark=$(wc -c < "$(log_path "$task")" 2>/dev/null | tr -d '[:space:]')
  is_uint "$log_mark" || log_mark=0
  setsid nohup "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" run --task "$task" \
    </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true

  wait_for_start "$task" "$log_mark" || die 'arm: the watchdog did not come up'
  printf 'armed: pod %s, deadline %s (%s), pid %s\n' \
    "$pod" "$(date -u -d "@$effective" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$effective")" \
    "$source" "$(cat "$(pid_path "$task")" 2>/dev/null)"
}

# A live pid proves it came up. So does a start line the loop appended after this
# arm's mark: a loop that finds the pod already gone finishes correctly within
# milliseconds, and that clean ending must not be misreported as a failed launch.
wait_for_start() {
  local task=$1 mark=$2 i=0 pid
  while [ "$i" -lt 100 ]; do
    pid=$(cat "$(pid_path "$task")" 2>/dev/null || true)
    if is_uint "$pid" && kill -0 "$pid" 2>/dev/null; then
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
  is_uint "$pid" || return 0
  kill -0 "$pid" 2>/dev/null || return 0
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
      --task) task=${2:-}; shift 2 || true ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  task_id_valid "$task" || die 'disarm: --task is required' 2
  stop_existing "$task"
  rm -f -- "$(record_path "$task")" "$(pid_path "$task")" "$(alarm_path "$task")" 2>/dev/null || true
  log_line "$task" 'disarmed'
  printf 'disarmed: %s\n' "$task"
}

cmd_status() {
  local task='' record pid found=0 f
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 || true ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  for f in "$STATE"/*.runpod-watch; do
    [ -f "$f" ] || continue
    local id
    id=$(basename "$f" .runpod-watch)
    [ -z "$task" ] || [ "$task" = "$id" ] || continue
    found=1
    if record_read "$f"; then
      pid=$(cat "$(pid_path "$id")" 2>/dev/null || true)
      local live=stopped
      if is_uint "$pid" && kill -0 "$pid" 2>/dev/null; then live=running; fi
      printf '%s: pod=%s deadline=%s source=%s ceiling=%s rate=%s watchdog=%s pid=%s\n' \
        "$id" "$REC_POD" \
        "$(date -u -d "@$REC_DEADLINE" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$REC_DEADLINE")" \
        "$REC_DEADLINE_SOURCE" "${REC_CEILING_USD:-none}" "${REC_RATE_USD_HR:-none}" \
        "$live" "${pid:-none}"
    else
      printf '%s: RECORD UNREADABLE - this watchdog will alarm and will not terminate anything\n' "$id"
    fi
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
  local task='' record now deadline_reached=0 progress_age mtime
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 || true ;;
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

    if ! record_read "$record"; then
      # The record is the only thing that says which pod may be stopped and
      # when. Without it there is nothing this watchdog is entitled to do.
      alarm "$task" record-unreadable \
        "the pod watchdog for $task cannot read the run's deadline record, so it will NOT terminate anything; check the rented pod by hand"
      nap "$POLL_SECONDS"
      continue
    fi

    if ! now=$(now_epoch); then
      alarm "$task" clock-unreadable \
        "the pod watchdog for $task cannot read the clock, so it will NOT terminate anything; check the rented pod by hand"
      nap "$POLL_SECONDS"
      continue
    fi

    deadline_reached=0
    [ "$now" -lt "$REC_DEADLINE" ] || deadline_reached=1

    if [ "$deadline_reached" -eq 1 ]; then
      # A pod that is already absent at its deadline was stopped by the run
      # itself. Reporting that as a watchdog termination would credit this
      # process with a stop it did not make.
      pod_present "$REC_POD"
      if [ $? -eq 1 ]; then
        log_line "$task" "deadline passed but pod $REC_POD is already absent; nothing to stop"
        rm -f -- "$record" 2>/dev/null || true
        return 0
      fi
      terminate_and_verify "$task" "$REC_POD"
      alarm "$task" terminated \
        "rented pod $REC_POD passed the deletion deadline this run declared and has been stopped; absence confirmed by listing the account's pods"
      rm -f -- "$record" 2>/dev/null || true
      log_line "$task" 'watchdog exiting after verified termination'
      return 0
    fi

    # Below the deadline the pod disappearing is the NORMAL ending: the run
    # finished and cleaned up after itself. Only a read that succeeded counts.
    pod_present "$REC_POD"
    case $? in
      1)
        log_line "$task" "pod $REC_POD is no longer listed before its deadline; nothing left to guard"
        rm -f -- "$record" 2>/dev/null || true
        return 0
        ;;
      2)
        alarm "$task" api-unreachable \
          "the pod watchdog for $task cannot reach RunPod to check pod $REC_POD; it keeps waiting and will not terminate anything on a failed read"
        ;;
      *) ;;
    esac

    # A stalled progress artifact ALARMS and never terminates: a long CPU-bound
    # pack phase is indistinguishable from a wedge from out here.
    if [ -n "$REC_PROGRESS_FILE" ] && [ -n "$REC_PROGRESS_GRACE" ]; then
      if mtime=$(date -r "$REC_PROGRESS_FILE" +%s 2>/dev/null) && is_uint "$mtime"; then
        progress_age=$((now - mtime))
        if [ "$progress_age" -gt "$REC_PROGRESS_GRACE" ]; then
          alarm "$task" progress-stalled \
            "the run on pod $REC_POD has not touched its progress file for ${progress_age}s (allowed ${REC_PROGRESS_GRACE}s); it may be wedged, and the watchdog will not stop it before its deadline"
        fi
      else
        alarm "$task" progress-missing \
          "the run on pod $REC_POD has no readable progress file; the watchdog is running on its deadline alone"
      fi
    fi

    nap "$POLL_SECONDS"
  done
}

case "${1:-}" in
  arm) shift; cmd_arm "$@" ;;
  run) shift; cmd_run "$@" ;;
  status) shift; cmd_status "$@" ;;
  disarm) shift; cmd_disarm "$@" ;;
  probe) shift; cmd_probe "$@" ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 2 ;;
esac
