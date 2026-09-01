#!/usr/bin/env bash
# fm-fleet-publish.sh - publish this home's fleet snapshot to a stable path on a
# cadence, for a consumer that WATCHES A FILE rather than running a command.
#
# WHY THIS EXISTS. bin/fm-fleet-snapshot.sh is invoked on demand only, by
# bin/fm-fleet-view.sh, bin/fm-bearings-snapshot.sh, and
# bin/fm-home-summary-refresh.sh. That is correct for a command and wrong for a
# reader that cannot run one: a surface that reads bytes and watches directories
# renders whatever the last manual run left behind, and can only badge its own
# age. This script is that missing publisher. It adds nothing to the snapshot and
# changes nothing about it: the published artifact is the exact
# `fm-fleet-snapshot.sh --json` document, schema `fm-fleet-snapshot.v1`
# unchanged, so a consumer that pins the schema id keeps rendering.
#
# WHY NOT AN EXISTING MECHANISM. This repository already supervises recurring
# background work four ways, and none of them fits:
#   - Watcher check shims (state/<id>.check.sh, armed the way
#     bin/fm-tool-update-check.sh arms its own) run on the watcher's poll. The
#     watcher is armed BY an agent and its cycle ends with the agent, so a home
#     with no live session publishes nothing. That is also the coupling the
#     captain rejected on 2026-09-01 when this work was scoped: a stopped
#     supervision cycle would silently freeze the surface, which is the exact
#     state the finding observed.
#   - Process-to-event sources (bin/fm-procevent.sh) are wake transport. They
#     capture a result so firstmate can read it on its next turn, and they are
#     polled by the same watcher, so they inherit the same lifetime.
#   - The away-mode sub-supervisor (bin/fm-supervise-daemon.sh) is gated on
#     state/.afk by contract and owns supervision only while the captain is away.
#   - There is no launchd, cron, or systemd unit anywhere in bin/. Firstmate does
#     not install host-level timers, and adding one for a snapshot would put a
#     unit outside the operational home that no `fm-` command owns.
# What DOES fit is the detach pattern bin/fm-startup-network.sh already proved
# for work that must outlive the shell that launched it: nohup, its own process
# group, stdio detached. This script reuses that shape and adds only the loop.
# Its write path is bin/fm-home-summary-refresh.sh's publication contract
# (serialize, validate, rename), applied to the canonical snapshot.
#
# CONFIGURATION. config/fleet-snapshot-cadence, one positive decimal integer of
# seconds followed by exactly one newline, in a regular single-linked file under
# a non-symlinked config/. ABSENT MEANS DISABLED: no daemon, no artifact, no
# cost. Malformed is refused as malformed and never silently treated as a
# default, because a home that believes it is publishing and is not is the
# failure this whole mechanism exists to remove. `status` always says which of
# the three states this home is in. docs/configuration.md owns the operator-facing
# schema; this header owns the mechanics.
#
# WHAT A CADENCE COSTS. A snapshot read is real work: it forks per task for
# bin/fm-crew-state.sh, reads every state/<id>.meta and status tail, does one
# endpoint presence check per task, and samples every registered secondmate home.
# It makes no network call. Cost therefore scales with tasks plus secondmate
# homes, not with fleet activity. Measured 2026-09-01 on a primary home with 6
# task records and no secondmates: 2.9s wall, 0.4s CPU, 49KB of JSON. A 300s
# cadence is that home's default and spends about 1% of one core; 60s would
# spend 5% continuously to shave four minutes off a staleness badge, which is
# not a trade worth defaulting to. Below FM_FLEET_PUBLISH_MIN_CADENCE (30s) the
# duty cycle stops being background on any fleet large enough to want this, so a
# smaller configured value is refused rather than accepted and degraded.
#
# ATOMICITY AND FAILURE. A publish writes a dot-prefixed temporary file in the
# state directory, validates it, then renames it over the artifact. A consumer
# that watches the directory never sees a partial document and never sees the
# temporary name, because the rename is the only appearance. A snapshot that
# fails, times out, or returns a document that does not validate leaves the
# previous artifact byte-identical: degrading to stale is correct, and the
# consumer can still say how old the picture is from the artifact's own
# `generated` field. Failures append to a bounded state/.fleet-publish.log.
#
# Usage:
#   fm-fleet-publish.sh status
#          Print this home's publication state and exit 0. Names which of
#          disabled / misconfigured / enabled applies, whether the daemon is
#          running, and the published artifact's own age.
#   fm-fleet-publish.sh publish
#          Publish once, now, in the foreground. This is an explicit operator
#          action and works whether or not a cadence is configured; a cadence is
#          what a home pays for automatically, a hand-run publish is not.
#          Exits non-zero with the reason when the publish failed.
#   fm-fleet-publish.sh start
#          Idempotently start this home's detached publisher. Refuses when no
#          valid cadence is configured. An already-running daemon is left alone.
#          Verifies before reporting: it prints started/attached only after the
#          daemon holds this home's singleton lock with a fresh beacon.
#   fm-fleet-publish.sh stop
#          Stop exactly this home's daemon, by the pid recorded in this home's
#          own record. It never matches on a command name, so it can never touch
#          another home's publisher.
#   fm-fleet-publish.sh run
#          The cadence loop itself, in the foreground. This is what `start`
#          detaches; run it directly to watch the loop or to host it under a
#          supervisor of your own.
#
# The loop re-reads the configuration on every tick, so removing the file stops
# the daemon within one tick and a changed cadence takes effect without a
# restart. That is what makes "absent configuration means absent behaviour" true
# continuously rather than only at start time.
#
# Environment:
#   FM_FLEET_PUBLISH_TIMEOUT       seconds bounding one snapshot read (default 120)
#   FM_FLEET_PUBLISH_MIN_CADENCE   smallest accepted cadence (default 30)
#   FM_FLEET_PUBLISH_TICK_SECS     loop slice, bounds how fast the daemon notices
#                                  a configuration change (default 5)
#   FM_FLEET_PUBLISH_GRACE         beacon freshness allowance for the liveness
#                                  check (default FM_FLEET_PUBLISH_TIMEOUT + 60)
#   FM_FLEET_PUBLISH_START_WAIT    seconds `start` waits to verify (default 15)
#   FM_FLEET_PUBLISH_LOG_MAX_BYTES bounded failure log size (default 65536)
#   FM_FLEET_PUBLISH_SNAPSHOT_CMD  test seam: the snapshot producer to run
#                                  (default bin/fm-fleet-snapshot.sh)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

CADENCE_FILE="$CONFIG/fleet-snapshot-cadence"
ARTIFACT="$STATE/fleet-snapshot.json"
PUBLISH_LOCK="$STATE/.fleet-publish.lock"
DAEMON_LOCK="$STATE/.fleet-publish-daemon.lock"
DAEMON_RECORD="$STATE/.fleet-publish-daemon"
BEACON="$STATE/.fleet-publish-beat"
ERROR_LOG="$STATE/.fleet-publish.log"

PUBLISH_TIMEOUT=${FM_FLEET_PUBLISH_TIMEOUT:-120}
MIN_CADENCE=${FM_FLEET_PUBLISH_MIN_CADENCE:-30}
TICK_SECS=${FM_FLEET_PUBLISH_TICK_SECS:-5}
START_WAIT=${FM_FLEET_PUBLISH_START_WAIT:-15}
LOG_MAX_BYTES=${FM_FLEET_PUBLISH_LOG_MAX_BYTES:-65536}
SNAPSHOT_CMD=${FM_FLEET_PUBLISH_SNAPSHOT_CMD:-$SCRIPT_DIR/fm-fleet-snapshot.sh}

case "$PUBLISH_TIMEOUT" in ''|*[!0-9]*|0) PUBLISH_TIMEOUT=120 ;; esac
case "$MIN_CADENCE" in ''|*[!0-9]*|0) MIN_CADENCE=30 ;; esac
case "$TICK_SECS" in ''|*[!0-9]*|0) TICK_SECS=5 ;; esac
case "$START_WAIT" in ''|*[!0-9]*|0) START_WAIT=15 ;; esac
case "$LOG_MAX_BYTES" in ''|*[!0-9]*|0) LOG_MAX_BYTES=65536 ;; esac
GRACE=${FM_FLEET_PUBLISH_GRACE:-$(( PUBLISH_TIMEOUT + 60 ))}
case "$GRACE" in ''|*[!0-9]*|0) GRACE=$(( PUBLISH_TIMEOUT + 60 )) ;; esac

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

FLEET_PUBLISH_ERROR=
FLEET_PUBLISH_CADENCE=
FLEET_PUBLISH_TMP=
FLEET_PUBLISH_ERR_TMP=
FLEET_PUBLISH_LOCK_HELD=0
FLEET_PUBLISH_DAEMON_LOCK_HELD=0

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  FLEET_PUBLISH_ERROR=$1
  return 1
}

now_epoch() {
  date +%s 2>/dev/null
}

path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

# read_cadence: sets FLEET_PUBLISH_CADENCE to the validated cadence.
# Exit 0 configured and valid; 1 absent (disabled); 2 present but unusable, with
# the reason in FLEET_PUBLISH_ERROR. Absent and invalid are deliberately
# different exits: a home that configured a cadence and typed it wrong must not
# be reported as a home that chose not to publish. It reports through globals
# rather than stdout so a caller can never lose the reason to a subshell and
# report an unusable configuration as an unexplained one.
read_cadence() {
  local value links
  FLEET_PUBLISH_ERROR=
  FLEET_PUBLISH_CADENCE=
  if [ -L "$CONFIG" ]; then
    fail "config directory is symlinked: $CONFIG"
    return 2
  fi
  if [ ! -e "$CADENCE_FILE" ] && [ ! -L "$CADENCE_FILE" ]; then
    return 1
  fi
  if [ -L "$CADENCE_FILE" ]; then
    fail "config/fleet-snapshot-cadence is symlinked"
    return 2
  fi
  if [ ! -f "$CADENCE_FILE" ]; then
    fail "config/fleet-snapshot-cadence is not a regular file"
    return 2
  fi
  links=$(link_count "$CADENCE_FILE") || {
    fail "could not inspect config/fleet-snapshot-cadence"
    return 2
  }
  if [ "$links" != 1 ]; then
    fail "config/fleet-snapshot-cadence is hardlinked"
    return 2
  fi
  value=$(<"$CADENCE_FILE") || {
    fail "could not read config/fleet-snapshot-cadence"
    return 2
  }
  case "$value" in
    ''|0|*[!0-9]*|0*)
      fail "config/fleet-snapshot-cadence must be one positive whole number of seconds"
      return 2
      ;;
  esac
  if ! printf '%s\n' "$value" | cmp -s "$CADENCE_FILE" -; then
    fail "config/fleet-snapshot-cadence must contain exactly one value followed by one newline"
    return 2
  fi
  if [ "$value" -lt "$MIN_CADENCE" ]; then
    fail "config/fleet-snapshot-cadence is ${value}s, below the ${MIN_CADENCE}s floor a snapshot read can sustain"
    return 2
  fi
  FLEET_PUBLISH_CADENCE=$value
  return 0
}

log_failure() {
  local message=$1 stamp size tmp
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || stamp=unknown
  if ! printf '[%s] %s\n' "$stamp" "$message" >> "$ERROR_LOG" 2>/dev/null; then
    printf 'fm-fleet-publish: %s\n' "$message" >&2
    return 0
  fi
  size=$(wc -c < "$ERROR_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
    tmp="$ERROR_LOG.tmp.${BASHPID:-$$}"
    tail -n 200 "$ERROR_LOG" > "$tmp" 2>/dev/null \
      && mv -f -- "$tmp" "$ERROR_LOG" 2>/dev/null
    rm -f -- "$tmp" 2>/dev/null || true
  fi
}

# shellcheck disable=SC2329 # Invoked by the signal and EXIT traps below.
publish_cleanup() {
  [ -z "$FLEET_PUBLISH_TMP" ] || rm -f -- "$FLEET_PUBLISH_TMP" 2>/dev/null || true
  [ -z "$FLEET_PUBLISH_ERR_TMP" ] || rm -f -- "$FLEET_PUBLISH_ERR_TMP" 2>/dev/null || true
  FLEET_PUBLISH_TMP=
  FLEET_PUBLISH_ERR_TMP=
  if [ "$FLEET_PUBLISH_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$PUBLISH_LOCK" || true
    FLEET_PUBLISH_LOCK_HELD=0
  fi
}

# publish_once: one complete atomic publication.
# Every failure path returns non-zero with FLEET_PUBLISH_ERROR set and leaves the
# existing artifact untouched. The temporary file is dot-prefixed and lives in
# the state directory so the rename is atomic on that filesystem and a consumer
# watching the directory never observes a name it could try to read.
publish_once() {
  local producer_rc producer_error
  if ! mkdir -p "$STATE" 2>/dev/null; then
    fail "state directory is unavailable: $STATE"
    return 1
  fi
  fm_lock_acquire_wait "$PUBLISH_LOCK"
  FLEET_PUBLISH_LOCK_HELD=1
  FLEET_PUBLISH_TMP=$(umask 077; mktemp "$STATE/.fleet-snapshot.json.XXXXXX") || {
    fail "could not create an atomic publication file in $STATE"
    publish_cleanup
    return 1
  }
  FLEET_PUBLISH_ERR_TMP=$(umask 077; mktemp "$STATE/.fleet-snapshot-error.XXXXXX") || {
    fail "could not create a producer diagnostic file in $STATE"
    publish_cleanup
    return 1
  }

  if fm_run_timed "$PUBLISH_TIMEOUT" env \
    FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$PROJECTS" \
    "$SNAPSHOT_CMD" --json \
      > "$FLEET_PUBLISH_TMP" 2> "$FLEET_PUBLISH_ERR_TMP"; then
    producer_rc=0
  else
    producer_rc=$?
  fi
  if [ "$producer_rc" -ne 0 ]; then
    producer_error=$(tail -n 1 "$FLEET_PUBLISH_ERR_TMP" 2>/dev/null \
      | tr '\t\r\n' '   ' | cut -c1-500)
    if [ "$producer_rc" -eq 124 ]; then
      fail "snapshot read exceeded its ${PUBLISH_TIMEOUT}-second deadline; the published snapshot is unchanged"
    elif [ -n "$producer_error" ]; then
      fail "snapshot read failed with exit $producer_rc: $producer_error; the published snapshot is unchanged"
    else
      fail "snapshot read failed with exit $producer_rc; the published snapshot is unchanged"
    fi
    publish_cleanup
    return 1
  fi
  rm -f -- "$FLEET_PUBLISH_ERR_TMP" 2>/dev/null || true
  FLEET_PUBLISH_ERR_TMP=

  if ! jq -e --arg home "$FM_HOME" '
    .schema == "fm-fleet-snapshot.v1"
    and .fm_home == $home
    and (.generated | type) == "string"
    and (.generated | length) > 0
    and (.roots | type) == "object"
    and (.backlog | type) == "object"
    and (.tasks | type) == "array"
  ' "$FLEET_PUBLISH_TMP" >/dev/null 2>&1; then
    fail "snapshot read returned a document that is not a usable fm-fleet-snapshot.v1 for this home; the published snapshot is unchanged"
    publish_cleanup
    return 1
  fi
  if ! chmod 600 "$FLEET_PUBLISH_TMP" 2>/dev/null; then
    fail "could not set the publication file mode"
    publish_cleanup
    return 1
  fi
  if ! mv -f -- "$FLEET_PUBLISH_TMP" "$ARTIFACT" 2>/dev/null; then
    fail "atomic replacement of the published snapshot failed: $ARTIFACT"
    publish_cleanup
    return 1
  fi
  FLEET_PUBLISH_TMP=
  publish_cleanup
  return 0
}

artifact_generated() {
  [ -f "$ARTIFACT" ] && [ -r "$ARTIFACT" ] && [ ! -L "$ARTIFACT" ] || return 1
  LC_ALL=C sed -n 's/.*"generated"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$ARTIFACT" 2>/dev/null | head -1
}

record_pid() {
  [ -f "$DAEMON_RECORD" ] && [ ! -L "$DAEMON_RECORD" ] || return 1
  LC_ALL=C sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "$DAEMON_RECORD" 2>/dev/null | head -1
}

# daemon_alive: 0 when this home's publisher is genuinely running.
# Two independent facts must agree: the recorded pid is alive, and the beacon it
# touches every tick is fresh. The pid alone is not enough - a reused pid would
# report a stopped publisher as healthy, and a surface that silently stops
# updating is the failure this script exists to remove.
daemon_alive() {
  local pid mtime now age
  pid=$(record_pid) || return 1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  mtime=$(path_mtime "$BEACON") || return 1
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(now_epoch) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( now - mtime ))
  [ "$age" -le "$GRACE" ] || return 1
  printf '%s\t%s\n' "$pid" "$age"
  return 0
}

cmd_status() {
  local cadence rc alive pid age generated now stamp artifact_age
  read_cadence; rc=$?
  cadence=$FLEET_PUBLISH_CADENCE
  case "$rc" in
    0) ;;
    1) echo "publisher: disabled (config/fleet-snapshot-cadence is absent, so this home publishes nothing on its own)" ;;
    *) echo "publisher: misconfigured ($FLEET_PUBLISH_ERROR)" ;;
  esac
  if [ "$rc" -eq 0 ]; then
    if alive=$(daemon_alive); then
      pid=${alive%%$'\t'*}
      age=${alive#*$'\t'}
      echo "publisher: enabled cadence=${cadence}s daemon=running pid=$pid beacon=${age}s"
    else
      echo "publisher: enabled cadence=${cadence}s daemon=stopped (run: bin/fm-fleet-publish.sh start)"
    fi
  fi
  if generated=$(artifact_generated) && [ -n "$generated" ]; then
    artifact_age=unknown
    stamp=$(path_mtime "$ARTIFACT") || stamp=
    now=$(now_epoch) || now=
    if [ -n "$stamp" ] && [ -n "$now" ]; then
      artifact_age="$(( now - stamp ))s"
    fi
    echo "snapshot: $ARTIFACT generated=$generated published=${artifact_age} ago"
  else
    echo "snapshot: $ARTIFACT has not been published"
  fi
  return 0
}

cmd_publish() {
  trap publish_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if publish_once; then
    echo "publisher: published $ARTIFACT"
    return 0
  fi
  log_failure "$FLEET_PUBLISH_ERROR"
  printf 'fm-fleet-publish: %s\n' "$FLEET_PUBLISH_ERROR" >&2
  return 1
}

# shellcheck disable=SC2329 # Invoked by the signal and EXIT traps in cmd_run.
daemon_cleanup() {
  publish_cleanup
  if [ "$FLEET_PUBLISH_DAEMON_LOCK_HELD" -eq 1 ]; then
    rm -f -- "$DAEMON_RECORD" 2>/dev/null || true
    fm_lock_release "$DAEMON_LOCK" || true
    FLEET_PUBLISH_DAEMON_LOCK_HELD=0
  fi
}

beat() {
  : > "$BEACON" 2>/dev/null || true
}

cmd_run() {
  local cadence rc slept slice
  if ! mkdir -p "$STATE" 2>/dev/null; then
    printf 'fm-fleet-publish: state directory is unavailable: %s\n' "$STATE" >&2
    return 1
  fi
  read_cadence; rc=$?
  cadence=$FLEET_PUBLISH_CADENCE
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 1 ]; then
      printf 'fm-fleet-publish: no cadence is configured, so there is nothing to publish\n' >&2
    else
      printf 'fm-fleet-publish: %s\n' "$FLEET_PUBLISH_ERROR" >&2
    fi
    return 1
  fi
  if ! fm_lock_try_acquire "$DAEMON_LOCK"; then
    printf 'fm-fleet-publish: this home already has a publisher running\n' >&2
    return 3
  fi
  FLEET_PUBLISH_DAEMON_LOCK_HELD=1
  trap daemon_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  beat
  printf 'pid=%s\nstarted=%s\ncadence=%s\n' \
    "${BASHPID:-$$}" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$cadence" \
    > "$DAEMON_RECORD" 2>/dev/null || true

  while :; do
    beat
    if ! publish_once; then
      log_failure "$FLEET_PUBLISH_ERROR"
    fi
    beat
    # Sleep the cadence in slices so a removed or edited configuration is
    # honoured within one tick instead of one cadence. Re-reading here, not only
    # at startup, is what keeps "absent configuration means absent behaviour"
    # true for a daemon that is already running.
    slept=0
    while [ "$slept" -lt "$cadence" ]; do
      slice=$TICK_SECS
      [ $(( cadence - slept )) -ge "$slice" ] || slice=$(( cadence - slept ))
      sleep "$slice"
      slept=$(( slept + slice ))
      beat
      read_cadence; rc=$?
      cadence=$FLEET_PUBLISH_CADENCE
      if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ]; then
          log_failure "cadence configuration was removed; the publisher stopped and left the last published snapshot in place"
        else
          log_failure "cadence configuration became unusable ($FLEET_PUBLISH_ERROR); the publisher stopped and left the last published snapshot in place"
        fi
        return 0
      fi
    done
  done
}

cmd_start() {
  local cadence rc alive pid waited monitor_was_on
  read_cadence; rc=$?
  cadence=$FLEET_PUBLISH_CADENCE
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 1 ]; then
      printf 'fm-fleet-publish: no cadence is configured for this home; write one to %s first\n' \
        "$CADENCE_FILE" >&2
    else
      printf 'fm-fleet-publish: %s\n' "$FLEET_PUBLISH_ERROR" >&2
    fi
    return 1
  fi
  if ! mkdir -p "$STATE" 2>/dev/null; then
    printf 'fm-fleet-publish: state directory is unavailable: %s\n' "$STATE" >&2
    return 1
  fi
  if alive=$(daemon_alive); then
    pid=${alive%%$'\t'*}
    echo "publisher: already running pid=$pid cadence=${cadence}s"
    return 0
  fi

  # Detached the same three ways bin/fm-startup-network.sh detaches its worker:
  # stdio to /dev/null so no caller's pipe is held open, nohup so the publisher
  # outlives the shell that launched it, and its own process group so a bounded
  # caller's group teardown cannot take the publisher down with it. Together
  # those are what let the artifact keep advancing after the agent that armed it
  # is gone.
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  nohup env \
    FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$PROJECTS" \
    FM_FLEET_PUBLISH_SNAPSHOT_CMD="$SNAPSHOT_CMD" \
    FM_FLEET_PUBLISH_TIMEOUT="$PUBLISH_TIMEOUT" \
    FM_FLEET_PUBLISH_MIN_CADENCE="$MIN_CADENCE" \
    FM_FLEET_PUBLISH_TICK_SECS="$TICK_SECS" \
    FM_FLEET_PUBLISH_GRACE="$GRACE" \
    FM_FLEET_PUBLISH_LOG_MAX_BYTES="$LOG_MAX_BYTES" \
    "$SCRIPT_DIR/fm-fleet-publish.sh" run \
    >/dev/null 2>&1 </dev/null &
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  waited=0
  while [ "$waited" -lt "$START_WAIT" ]; do
    if alive=$(daemon_alive); then
      pid=${alive%%$'\t'*}
      echo "publisher: started pid=$pid cadence=${cadence}s"
      return 0
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  printf 'fm-fleet-publish: could not confirm a running publisher within %ss\n' "$START_WAIT" >&2
  return 1
}

cmd_stop() {
  local pid waited alive
  pid=$(record_pid) || pid=
  if [ -z "$pid" ]; then
    echo "publisher: no publisher is recorded for this home"
    return 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f -- "$DAEMON_RECORD" 2>/dev/null || true
    echo "publisher: recorded publisher pid=$pid is already gone"
    return 0
  fi
  # Signal only on the same evidence `status` reports a publisher on: a live pid
  # AND a fresh beacon. A recorded pid alone is not proof after a reboot, and a
  # reused pid would make this stop something that is not a publisher.
  if ! alive=$(daemon_alive); then
    printf 'fm-fleet-publish: recorded publisher pid=%s is not beating, so it was not signalled; inspect it and remove %s if it is not a publisher\n' \
      "$pid" "$DAEMON_RECORD" >&2
    return 1
  fi
  pid=${alive%%$'\t'*}
  kill -TERM "$pid" 2>/dev/null || true
  waited=0
  while [ "$waited" -lt 10 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
    waited=$(( waited + 1 ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    printf 'fm-fleet-publish: publisher pid=%s did not stop within 10s\n' "$pid" >&2
    return 1
  fi
  echo "publisher: stopped pid=$pid"
  return 0
}

case "${1:-}" in
  status) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_status ;;
  publish) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_publish ;;
  run) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_run ;;
  start) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_start ;;
  stop) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_stop ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
