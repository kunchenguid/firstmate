#!/usr/bin/env bash
# fm-pipeline.sh - the single writer for pipeline records and shadow probe events.
#
# The owner derives lifecycle steps from local machine artifacts and appends one
# schema=fm-pipeline.v2 event per declared wait.
# Usage:
#   fm-pipeline.sh reconcile <task-id>
#   fm-pipeline.sh retire <task-id>
#   fm-pipeline.sh board-json
#   fm-pipeline.sh steps <kind>
#   fm-pipeline.sh probe [--task <id>]
#   fm-pipeline.sh arm [--force]
#   fm-pipeline.sh disarm
#
# FM_PIPELINE_DEADLINE controls probe-all coverage: unset defaults to 20 seconds,
# zero disables the deadline, and another value must be non-negative decimal seconds.
#
# disarm writes state/pipeline-probe.disabled. arm refuses while a valid
# marker is present, unless --force clears it first; an absent marker never
# blocks arm, and an invalid one (symlink, directory, wrong mode) refuses the
# same as a valid one but --force never touches it.
#
# FM_HOME selects the operational home and FM_STATE_OVERRIDE selects its state
# directory for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG="${FM_PIPELINE_LOG:-$STATE/pipeline-events.log}"

CHECK_ID='pipeline-probe'
PIPELINE_SCHEMA='fm-pipeline.v3'
PIPELINE_REPAIR='repair: confirm the task is gone and run fm-pipeline.sh retire <id>, or move the file aside by hand'

# Results populated by pipeline_record_load for its callers.
PIPELINE_RECORD_STATE=
PIPELINE_RECORD_REASON=
PIPELINE_RECORD_KIND=
PIPELINE_RECORD_GEN=
PIPELINE_RECORD_STEP=
PIPELINE_RECORD_REV=0
PIPELINE_RECORD_TS=
PIPELINE_RECORD_HEAD=
PIPELINE_RECORD_EVIDENCE=
PIPELINE_RECORD_ATTEMPT=-
PIPELINE_RECORD_LINE=
PIPELINE_RECORD_HAS_LINE=0
PIPELINE_META_FILE=
PIPELINE_META_KIND=
PIPELINE_META_GEN=
PIPELINE_META_ATTEMPT=
PIPELINE_META_PR_HEAD=
PIPELINE_META_SCALAR_READY=0
PIPELINE_META_IDENTITY_READY=0
PIPELINE_META_PR_OK=0
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
CHECK_DISABLED="$STATE/$CHECK_ID.disabled"
PIPELINE_ARM_LOCK="$STATE/$CHECK_ID.lock"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

die() {
  printf 'fm-pipeline.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,22p' "$0" | sed 's/^# //' >&2
}

pipeline_state_unavailable_report() {
  local kind
  if [ -L "$STATE" ]; then
    kind=symlink
  elif [ -e "$STATE" ]; then
    kind=not-a-directory
  else
    kind=absent
  fi
  printf 'fm-pipeline.sh: state unavailable: %s (%s)\n' "$STATE" "$kind" >&2
}

command=${1:-}
case "$command" in
  arm|disarm|--help|-h|'') ;;
  probe)
    if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
      pipeline_state_unavailable_report
      exit 1
    fi
    ;;
  *) [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable" ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

pipeline_state_file_valid() {
  fm_pr_regular_destination_or_absent "$1"
}

pipeline_shim_content() {  # <home> <state>
  local home=$1 state=$2
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$state")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-pipeline.sh") probe"
}

PIPELINE_SHIM_WRITE_TMP=
PIPELINE_SHIM_WROTE=0

pipeline_shim_write() {  # <body>
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-pipeline-check.XXXXXX" 2>/dev/null) || return 1
  PIPELINE_SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    PIPELINE_SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    PIPELINE_SHIM_WRITE_TMP=
    return 1
  fi
  PIPELINE_SHIM_WRITE_TMP=
  PIPELINE_SHIM_WROTE=1
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

pipeline_shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-pipeline-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

pipeline_trust_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-pipeline-check.XXXXXX" 2>/dev/null) || return 1
  if ! cp "$CHECK_TRUST" "$tmp" 2>/dev/null \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

PIPELINE_ARM_BACKUP=
PIPELINE_ARM_TRUST_BACKUP=
PIPELINE_ARM_TRUST_WROTE=0
PIPELINE_DISABLED_MARKER_STATE=absent
PIPELINE_DISABLED_MARKER_WHAT=

pipeline_artifact_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

pipeline_arm_collision_free() {
  local want=$1 path
  if pipeline_artifact_present "$CHECK_SHIM"; then
    [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] \
      && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
      && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ] || return 1
  else
    pipeline_artifact_present "$CHECK_TRUST" && return 1
  fi
  for path in \
    "$STATE/$CHECK_ID.pr-poll" \
    "$STATE/$CHECK_ID.pr-poll-registration" \
    "$STATE/$CHECK_ID.pr-poll-retirement" \
    "$STATE/$CHECK_ID.pr-poll-merge-notified"; do
    pipeline_artifact_present "$path" && return 1
  done
  if pipeline_artifact_present "$CHECK_TRUST" \
    && ! fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    return 1
  fi
}

pipeline_arm_rollback() {
  [ -z "$PIPELINE_SHIM_WRITE_TMP" ] || rm -f -- "$PIPELINE_SHIM_WRITE_TMP"
  PIPELINE_SHIM_WRITE_TMP=
  if [ -n "$PIPELINE_ARM_TRUST_BACKUP" ]; then
    if mv -f -- "$PIPELINE_ARM_TRUST_BACKUP" "$CHECK_TRUST" 2>/dev/null; then
      PIPELINE_ARM_TRUST_BACKUP=
    else
      rm -f -- "$PIPELINE_ARM_TRUST_BACKUP"
      PIPELINE_ARM_TRUST_BACKUP=
    fi
  elif [ "$PIPELINE_ARM_TRUST_WROTE" -eq 1 ]; then
    rm -f -- "$CHECK_TRUST"
  fi
  if [ -n "$PIPELINE_ARM_BACKUP" ]; then
    if mv -f -- "$PIPELINE_ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null; then
      PIPELINE_ARM_BACKUP=
    else
      rm -f -- "$PIPELINE_ARM_BACKUP"
      PIPELINE_ARM_BACKUP=
    fi
  elif [ "$PIPELINE_SHIM_WROTE" -eq 1 ]; then
    rm -f -- "$CHECK_SHIM"
  fi
  PIPELINE_ARM_TRUST_WROTE=0
  PIPELINE_SHIM_WROTE=0
}

pipeline_arm_interrupted() {
  pipeline_arm_rollback
  printf 'fm-pipeline.sh: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

# One cheap serialization boundary for arm and disarm: without it, a marker
# check (or write) and the transaction it gates (arm's shim+trust write, or
# disarm's retire) are not atomic with respect to a concurrent disarm/arm, so
# an interleaving can leave the check armed under a disabled marker. Each
# process holds this lock for its whole call and the EXIT trap releases it
# exactly once, since arm/disarm each run once per fm-pipeline.sh invocation.
# fm_lock_try_acquire (already used by lock_log above) gives this a pid file
# and stale-owner reclaim for free: a plain mkdir here would instead leave a
# process killed between acquiring and its EXIT trap holding the lock
# forever, after which every future arm and disarm refuses with a "retry"
# that can never succeed.
pipeline_arm_lock_release() {
  fm_lock_release "$PIPELINE_ARM_LOCK" 2>/dev/null || true
}

pipeline_arm_lock_acquire() {
  if fm_lock_try_acquire "$PIPELINE_ARM_LOCK"; then
    trap pipeline_arm_lock_release EXIT
    return 0
  fi
  # A creation failure (no lock present) is not contention: naming it as
  # "another arm or disarm holds" the lock would be false. It also is not
  # necessarily an allocation/filesystem error: fm_lock_claim rejects a
  # fresh claim outright while a SEPARATE process's stale-lock reclaim is
  # between removing the old lock and re-creating it, which looks
  # identical (no lock present, creation failed) but clears on retry.
  if [ "${FM_LOCK_FAILURE:-}" = owner-create ]; then
    die "could not create state/$CHECK_ID.lock (owner directory): no lock present after the attempt (allocation or filesystem error, or a stale-lock reclaim in flight); retry, and inspect the state directory if it repeats"
  fi
  if [ -n "$FM_LOCK_HELD_PID" ]; then
    die "another arm or disarm holds state/$CHECK_ID.lock (pid $FM_LOCK_HELD_PID); retry"
  fi
  die "state/$CHECK_ID.lock is held or being reclaimed (holder unknown); retry"
}

# Classifies state/pipeline-probe.disabled into PIPELINE_DISABLED_MARKER_STATE:
# absent (arm proceeds), valid (a private regular file: arm refuses, --force
# clears it), or invalid (symlink, directory, or wrong mode/device/link count:
# arm refuses the same as valid, but --force must never touch it, since a
# foreign or damaged policy file is the same defect class as a foreign shim).
pipeline_disabled_marker_check() {
  local device
  PIPELINE_DISABLED_MARKER_STATE=absent
  PIPELINE_DISABLED_MARKER_WHAT=
  if [ -L "$CHECK_DISABLED" ]; then
    PIPELINE_DISABLED_MARKER_STATE=invalid
    PIPELINE_DISABLED_MARKER_WHAT=symlink
    return 0
  fi
  [ -e "$CHECK_DISABLED" ] || return 0
  if [ -d "$CHECK_DISABLED" ]; then
    PIPELINE_DISABLED_MARKER_STATE=invalid
    PIPELINE_DISABLED_MARKER_WHAT=directory
    return 0
  fi
  device=$(fm_pr_file_device "$STATE") || {
    PIPELINE_DISABLED_MARKER_STATE=invalid
    PIPELINE_DISABLED_MARKER_WHAT=unreadable
    return 0
  }
  if fm_pr_private_file_valid "$CHECK_DISABLED" 600 "$device"; then
    PIPELINE_DISABLED_MARKER_STATE=valid
  else
    PIPELINE_DISABLED_MARKER_STATE=invalid
    PIPELINE_DISABLED_MARKER_WHAT="not a private regular file"
  fi
}

pipeline_disabled_marker_write() {
  local device tmp
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-pipeline-disabled.XXXXXX" 2>/dev/null) || return 1
  if ! printf 'disabled\n' > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_DISABLED" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_DISABLED"; then
    rm -f -- "$tmp"
    return 1
  fi
}

pipeline_arm() {
  local force=${1:-0} want home state
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  pipeline_arm_lock_acquire
  pipeline_disabled_marker_check
  case "$PIPELINE_DISABLED_MARKER_STATE" in
    valid)
      if [ "$force" -eq 1 ]; then
        rm -f -- "$CHECK_DISABLED" || return 1
        printf 'cleared: state/%s.disabled\n' "$CHECK_ID"
      else
        die "pipeline-probe is disabled by state/$CHECK_ID.disabled; run arm --force to clear it"
      fi
      ;;
    invalid)
      die "state/$CHECK_ID.disabled marker is not a private regular file: $PIPELINE_DISABLED_MARKER_WHAT; inspect and remove or repair it by hand, then arm"
      ;;
  esac
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  case "$STATE" in
    /*) state=$STATE ;;
    *) state=$(CDPATH='' cd -- "$STATE" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  want=$(pipeline_shim_content "$home" "$state")
  pipeline_arm_collision_free "$want" || return 1
  PIPELINE_ARM_BACKUP=
  PIPELINE_ARM_TRUST_BACKUP=
  PIPELINE_ARM_TRUST_WROTE=0
  PIPELINE_SHIM_WROTE=0
  if pipeline_artifact_present "$CHECK_TRUST"; then
    PIPELINE_ARM_TRUST_BACKUP=$(pipeline_trust_backup) || return 1
  fi
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    PIPELINE_ARM_BACKUP=$(pipeline_shim_backup) || {
      [ -z "$PIPELINE_ARM_TRUST_BACKUP" ] || rm -f -- "$PIPELINE_ARM_TRUST_BACKUP"
      PIPELINE_ARM_TRUST_BACKUP=
      return 1
    }
  fi
  trap pipeline_arm_interrupted HUP INT TERM
  if ! pipeline_shim_write "$want"; then
    trap - HUP INT TERM
    pipeline_arm_rollback
    return 1
  fi
  PIPELINE_ARM_TRUST_WROTE=1
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    pipeline_arm_rollback
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$PIPELINE_ARM_BACKUP" ] || rm -f -- "$PIPELINE_ARM_BACKUP"
  [ -z "$PIPELINE_ARM_TRUST_BACKUP" ] || rm -f -- "$PIPELINE_ARM_TRUST_BACKUP"
  PIPELINE_ARM_BACKUP=
  PIPELINE_ARM_TRUST_BACKUP=
  PIPELINE_ARM_TRUST_WROTE=0
  PIPELINE_SHIM_WROTE=0
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

pipeline_disarm() {
  local retire_out
  mkdir -p "$STATE" || return 1
  pipeline_arm_lock_acquire
  # The marker is durable disable INTENT (an arm policy), not a receipt that
  # a running check stopped; write it first so a failed retire never loses
  # that intent (a retire-first order can retire successfully and then fail
  # to persist the disable, letting the next startup re-arm). A failed
  # retire still fails disarm, but names what happened and how to finish it.
  pipeline_disabled_marker_write || return 1
  retire_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$REGISTER_BIN" retire "$CHECK_ID" 2>&1) && {
    printf '%s\n' "$retire_out"
    return 0
  }
  die "disable policy recorded at state/$CHECK_ID.disabled; the registered check was NOT retired ($retire_out); retry disarm, or retire it by hand with fm-check-register.sh retire $CHECK_ID"
}

pipeline_meta_cache_load() {  # <meta-file> [force]
  local meta=$1 force=${2:-0} kind='' gen='' attempt='' pr_head='' line scalars
  if [ "$force" -ne 1 ] && [ "$PIPELINE_META_FILE" = "$meta" ] \
    && [ "$PIPELINE_META_SCALAR_READY" -eq 1 ]; then
    return 0
  fi
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  scalars=$(awk '
    index($0, "kind=") == 1 { kind=substr($0, 6) }
    index($0, "spawn_gen=") == 1 { gen=substr($0, 11) }
    index($0, "attempt=") == 1 { attempt=substr($0, 9) }
    index($0, "pr_head=") == 1 { pr_head=substr($0, 9) }
    END {
      printf "kind=%s\ngen=%s\nattempt=%s\npr_head=%s\n", kind, gen, attempt, pr_head
    }
  ' "$meta" 2>/dev/null) || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      kind=*) kind=${line#kind=} ;;
      gen=*) gen=${line#gen=} ;;
      attempt=*) attempt=${line#attempt=} ;;
      pr_head=*) pr_head=${line#pr_head=} ;;
    esac
  done <<EOF
$scalars
EOF
  case "$kind:$gen:$attempt:$pr_head" in
    *[[:space:]=]*) return 2 ;;
  esac
  PIPELINE_META_FILE=$meta
  PIPELINE_META_KIND=$kind
  PIPELINE_META_GEN=$gen
  PIPELINE_META_ATTEMPT=$attempt
  PIPELINE_META_PR_HEAD=$pr_head
  PIPELINE_META_SCALAR_READY=1
  PIPELINE_META_IDENTITY_READY=0
  PIPELINE_META_PR_OK=0
}

pipeline_meta_identity_load() {  # <meta-file>
  local meta=$1
  if [ "$PIPELINE_META_FILE" = "$meta" ] && [ "$PIPELINE_META_IDENTITY_READY" -eq 1 ]; then
    [ "$PIPELINE_META_PR_OK" -eq 1 ]
    return
  fi
  pipeline_meta_cache_load "$meta" || return 1
  PIPELINE_META_IDENTITY_READY=1
  if fm_pr_metadata_identity_parse "$meta"; then
    PIPELINE_META_PR_OK=1
    return 0
  fi
  PIPELINE_META_PR_OK=0
  return 1
}

pipeline_status_key() {  # <line> -> tagged key identity
  local line=$1 key prefix
  if _fm_key_before_colon "$line"; then
    prefix=${line%%:*}
    key=${prefix#*\[key=}
    key=${key%%\]*}
    _fm_decision_slug_ok "$key" || return 1
    printf 'key:%s\n' "$key"
    return 0
  fi
  if key=$(_fm_key_at_note_head "$line"); then
    _fm_decision_slug_ok "$key" || return 1
    printf 'key:%s\n' "$key"
  else
    printf '%s\n' unkeyed
  fi
}

wait_identity() {  # <tagged-key>
  case "$1" in
    unkeyed) printf '%s\n' 'ext:-' ;;
    key:-) printf '%s\n' 'ext:%2D' ;;
    key:default) printf '%s\n' 'ext:%64efault' ;;
    key:*) printf 'ext:%s\n' "${1#key:}" ;;
    *) return 1 ;;
  esac
}

active_paused() {  # <status-file> -> line-number<TAB>key<TAB>line per active pause
  local file=$1 activities active_key active_verb pause
  local line key number latest_number latest_key latest_line
  if ! activities=$(status_open_activities_with_key "$file" pipeline_status_key); then
    return 1
  fi
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS=$'\t' read -r active_key active_verb _; do
    [ "$active_verb" = "$pause" ] || continue
    number=0
    latest_number=0
    latest_key=
    latest_line=
    while IFS= read -r line || [ -n "$line" ]; do
      number=$((number + 1))
      if status_is_paused "$line"; then
        if key=$(pipeline_status_key "$line") && [ "$key" = "$active_key" ]; then
          latest_number=$number
          latest_key=$key
          latest_line=$line
        fi
      fi
    done < "$file"
    [ "$latest_number" -gt 0 ] || continue
    printf '%s\t%s\t%s\n' "$latest_number" "$latest_key" "$latest_line"
  done <<EOF
$activities
EOF
}

pipeline_seen_prepare() {  # <task-id>
  local id=$1 pipeline="$STATE/$1.pipeline" seen="$STATE/$1.pipeline-seen" first
  pipeline_state_file_valid "$seen" || return 1
  [ -e "$pipeline" ] || [ -L "$pipeline" ] || return 0
  pipeline_state_file_valid "$pipeline" || return 1
  first=$(awk 'NR == 1 { print; exit }' "$pipeline" 2>/dev/null || true)
  case "$first" in
    "schema=$PIPELINE_SCHEMA "*) return 0 ;;
    "schema=$PIPELINE_SCHEMA task="*) return 0 ;;
    *)
      if [ -e "$seen" ] || [ -L "$seen" ]; then
        return 2
      fi
      mv -- "$pipeline" "$seen" || return 1
      printf 'fm-pipeline.sh: migrated legacy observation cache %s to %s\n' \
        "$pipeline" "$seen" >&2
      ;;
  esac
}

observation_elapsed_since() {  # <task-id> <wait> <step> <generation> <evidence> <now>
  local id=$1 wait=$2 step=$3 gen=$4 evidence=$5 now=$6 pipeline="$STATE/$1.pipeline-seen"
  local observed
  pipeline_seen_prepare "$id" || return 1
  pipeline_state_file_valid "$pipeline" || return 1
  observed=$(awk -v wait="$wait" -v step="$step" -v gen="$gen" -v evidence="$evidence" '
    $1 == "wait=" wait && $2 == "step=" step && $3 == "gen=" gen && $4 == "evidence=" evidence {
      candidate=substr($5, length("observed_at=")+1)
      if (candidate ~ /^[0-9]+$/) observed=candidate
    }
    END { print observed }
  ' "$pipeline" 2>/dev/null || true)
  case "$observed" in
    ''|*[!0-9]*) observed= ;;
  esac
  if [ -n "$observed" ]; then
    if [ "$now" -ge "$observed" ]; then
      printf '%s\n' "$((now - observed))"
    else
      printf '%s\n' '0'
    fi
    return 0
  fi
  printf 'wait=%s step=%s gen=%s evidence=%s observed_at=%s\n' \
    "$wait" "$step" "$gen" "$evidence" "$now" >> "$pipeline" || return 1
  printf '%s\n' '0'
}

event_valid() {  # <event-line>
  local line=$1
  [ "$(printf '%s\n' "$line" | awk '{print NF}')" -eq 14 ] || {
    printf 'fm-pipeline.sh: event must have exactly 14 key=value fields\n' >&2
    return 1
  }
  printf '%s\n' "$line" | awk '
    BEGIN { OFS=""; ok=1 }
    {
      for (field=1; field<=14; field++) {
        if ($field !~ /^[^=[:space:]]+=[^=[:space:]]+$/) ok=0
      }
      split($1, a, "="); split($2, b, "="); split($3, c, "=");
      split($4, d, "="); split($5, e, "="); split($6, f, "=");
      split($7, g, "="); split($8, h, "="); split($9, i, "=");
      split($10, j, "="); split($11, k, "="); split($12, l, "=");
      split($13, m, "="); split($14, n, "=");
      if (a[1]!="ts" || b[1]!="task" || c[1]!="kind" || d[1]!="step" ||
          e[1]!="since" || f[1]!="probe" || g[1]!="rule" || h[1]!="action" ||
          i[1]!="mode" || j[1]!="evidence" || k[1]!="gen" || l[1]!="attempt" ||
          m[1]!="wait" || n[1]!="snap") ok=0;
      if (a[2] !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) ok=0;
      if (b[2] !~ /^[A-Za-z0-9._-]+$/ || b[2] ~ /^\./) ok=0;
      if (c[2] !~ /^(-|[^[:space:]=]+)$/) ok=0;
      if (d[2] !~ /^(-|[^[:space:]=]+)$/) ok=0;
      if (e[2] !~ /^[0-9]+$/) ok=0;
      if (f[2] !~ /^(ok|stall|fail|unknown)$/) ok=0;
      if (g[2] !~ /^(-|doorbell-then-relaunch|trust-accept|rotate-seat|recheck-external|refuse-duplicate|answer-owned-gate|verify-claimant|adopt-out-of-band-merge)$/) ok=0;
      if (h[2] !~ /^(would-heal|healed|discarded:stale|escalated|advanced|none)$/) ok=0;
      if (i[2] != "shadow") ok=0;
      if (j[2] == "-" && h[2] == "would-heal") ok=0;
      if (j[2] != "-" && j[2] !~ /^[^[:space:]]+:[^[:space:]]+$/) ok=0;
      if (k[2] !~ /^(-|[^[:space:]=]+)$/) ok=0;
      if (l[2] !~ /^(-|[^[:space:]=]+)$/) ok=0;
      if (m[2] !~ /^ext:(-|%2D|%64efault|[A-Za-z0-9._-]+)$/) ok=0;
      if (n[2] !~ /^(-|[^[:space:]=]+)$/) ok=0;
      if (h[2] == "would-heal" && (f[2] != "stall" || g[2] == "-")) ok=0;
      exit(ok ? 0 : 1)
    }
  ' || {
    if printf '%s\n' "$line" | rg -q '(^| )evidence=-( |$)' &&
      printf '%s\n' "$line" | rg -q '(^| )action=would-heal( |$)'; then
      printf 'fm-pipeline.sh: would-heal with evidence=- is inadmissible\n' >&2
    else
      printf 'fm-pipeline.sh: malformed shadow event\n' >&2
    fi
    return 1
  }
}

valid_event_lines() {
  local file=$1 line rejected=0
  while IFS= read -r line || [ -n "$line" ]; do
    if event_valid "$line" >/dev/null 2>&1; then
      printf '%s\n' "$line"
    else
      rejected=$((rejected + 1))
    fi
  done < "$file"
  printf '__fm_pipeline_rejected_rows=%s\n' "$rejected"
}

pipeline_lock_timeout_validate() {
  local seconds=${1-10}
  case "$seconds" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$seconds" -gt 0 ] 2>/dev/null || return 1
  printf '%s\n' "$seconds"
}

lock_log() {
  local lock="$LOG.lock" rc
  PIPELINE_LOCK_TIMEOUT=${FM_PIPELINE_LOCK_TIMEOUT-10}
  PIPELINE_LOCK_TIMEOUT=$(pipeline_lock_timeout_validate "$PIPELINE_LOCK_TIMEOUT") || \
    die "invalid FM_PIPELINE_LOCK_TIMEOUT: ${FM_PIPELINE_LOCK_TIMEOUT-} (positive integer seconds; unset defaults to 10)"
  mkdir -p "$(dirname "$LOG")" || die "cannot create log directory"
  rc=0
  fm_lock_acquire_wait_bounded "$lock" "$PIPELINE_LOCK_TIMEOUT" || rc=$?
  case "$rc" in
    0) ;;
    124)
      if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
        printf 'fm-pipeline.sh: refused:lock-held lock=%s holder=%s; rerun after the holder releases the lock\n' \
          "$lock" "$FM_LOCK_HELD_PID" >&2
      else
        printf 'fm-pipeline.sh: refused:lock-unavailable lock=%s holder=unknown; rerun after the lock clears\n' \
          "$lock" >&2
      fi
      exit 3
      ;;
    *)
      if [ "${FM_LOCK_FAILURE:-}" = owner-create ]; then
        printf 'fm-pipeline.sh: refused:lock-unavailable lock=%s holder=unknown; rerun after the lock clears\n' \
          "$lock" >&2
        exit 3
      fi
      die "cannot acquire event log lock"
      ;;
  esac
  PIPELINE_LOCK_DIR=$lock
  trap 'fm_lock_release "$PIPELINE_LOCK_DIR"' EXIT
}

append_event() {
  local line=$1
  event_valid "$line" || return 1
  lock_log
  append_event_locked "$line" || die "cannot append event log"
  fm_lock_release "$PIPELINE_LOCK_DIR" || die "cannot release event log lock"
  trap - EXIT
}

append_event_locked() {
  local line=$1 last
  event_valid "$line" || return 1
  pipeline_state_file_valid "$LOG" || return 1
  if [ -s "$LOG" ]; then
    last=$(set -o pipefail; tail -c 1 "$LOG" | od -An -tx1 | tr -d '[:space:]') || return 1
    if [ "$last" != 0a ]; then
      printf 'fm-pipeline.sh: malformed shadow event: %s:partial-tail\n' "$LOG" >&2
      printf '\n' >> "$LOG" || return 1
    fi
  fi
  printf '%s\n' "$line" >> "$LOG"
}

pipeline_step_known() {
  case "$1" in
    dispatched|pr-registered|merged) return 0 ;;
    *) return 1 ;;
  esac
}

pipeline_kind_steps() {  # <kind> -> nodes<TAB>edges
  case "$1" in
    ship|ship-nm|ship-direct|ship-local)
      printf '%s\t%s\n' \
        'dispatched ingress working validating pr-registered checks merge-wait merged' \
        'dispatched>ingress ingress>working working>validating validating>pr-registered pr-registered>checks checks>merge-wait merge-wait>merged'
      ;;
    scout|scout-reader|scout-writer)
      printf '%s\t%s\n' \
        'dispatched ingress working report-exists gate done' \
        'dispatched>ingress ingress>working working>report-exists report-exists>gate gate>done'
      ;;
    secondmate)
      printf '%s\t%s\n' \
        'session-live inbox-current queue-current reporting' \
        'session-live>inbox-current inbox-current>queue-current queue-current>reporting'
      ;;
    *)
      return 1
      ;;
  esac
}

pipeline_steps_json() {  # <kind>
  local nodes edges node_json edge_json node edge
  pipeline_kind_steps "$1" >/dev/null || return 1
  IFS=$'\t' read -r nodes edges <<EOF
$(pipeline_kind_steps "$1")
EOF
  node_json='[]'
  for node in $nodes; do
    node_json=$(jq -nc --argjson values "$node_json" --arg value "$node" '$values + [$value]') || return 1
  done
  edge_json='[]'
  for edge in $edges; do
    node=${edge%%>*}
    edge=${edge#*>}
    edge_json=$(jq -nc --argjson values "$edge_json" --arg from "$node" --arg to "$edge" \
      '$values + [{from:$from,to:$to}]') || return 1
  done
  jq -nc --argjson nodes "$node_json" --argjson edges "$edge_json" \
    '{nodes:$nodes,edges:$edges}'
}

pipeline_record_reset() {
  PIPELINE_RECORD_STATE=
  PIPELINE_RECORD_REASON=
  PIPELINE_RECORD_KIND=
  PIPELINE_RECORD_GEN=
  PIPELINE_RECORD_STEP=
  PIPELINE_RECORD_REV=0
  PIPELINE_RECORD_TS=
  PIPELINE_RECORD_HEAD=
  PIPELINE_RECORD_EVIDENCE=
  PIPELINE_RECORD_ATTEMPT=-
  PIPELINE_RECORD_LINE=
  PIPELINE_RECORD_HAS_LINE=0
}

pipeline_record_refuse() {  # <reason> [<line>]
  PIPELINE_RECORD_STATE=refused:$1
  PIPELINE_RECORD_REASON=$1
  PIPELINE_RECORD_LINE=${2:-}
  PIPELINE_RECORD_HAS_LINE=0
  return 1
}

pipeline_record_header_valid() {  # <file> <id> <kind> <gen>
  local file=$1 id=$2 kind=$3 gen=$4 line schema task header_kind header_gen
  line=$(awk 'NR == 1 { print; exit }' "$file" 2>/dev/null || true)
  [ "$(printf '%s\n' "$line" | awk '{print NF}')" -eq 4 ] || return 1
  IFS=' ' read -r schema task header_kind header_gen <<EOF
$line
EOF
  [ "$schema" = "schema=$PIPELINE_SCHEMA" ] || return 1
  [ "$task" = "task=$id" ] || return 1
  [ "$header_kind" = "kind=$kind" ] || return 1
  [ "$header_gen" = "gen=$gen" ] || return 2
}

pipeline_record_line_load() {  # <line> <file> <number> <expected-gen>
  local line=$1 file=$2 number=$3 expected_gen=$4 rev ts step evidence gen head attempt
  local field1 field2 field3 field4 field5 field6 field7
  [ "$(printf '%s\n' "$line" | awk '{print NF}')" -eq 7 ] || return 1
  IFS=' ' read -r field1 field2 field3 field4 field5 field6 field7 <<EOF
$line
EOF
  rev=${field1#rev=}; ts=${field2#ts=}; step=${field3#step=}; evidence=${field4#evidence=}
  gen=${field5#gen=}; head=${field6#head=}; attempt=${field7#attempt=}
  [ "$field1" = "rev=$rev" ] && [ "$field2" = "ts=$ts" ] && [ "$field3" = "step=$step" ] \
    && [ "$field4" = "evidence=$evidence" ] && [ "$field5" = "gen=$gen" ] \
    && [ "$field6" = "head=$head" ] && [ "$field7" = "attempt=$attempt" ] || return 1
  case "$rev" in ''|*[!0-9]*) return 1 ;; esac
  [ "$rev" -gt 0 ] 2>/dev/null || return 1
  case "$ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  pipeline_step_known "$step" || return 1
  case "$evidence" in ''|*[[:space:]]*|*:*:*) return 1 ;; esac
  [ -n "$gen" ] && [ "$gen" = "$expected_gen" ] || return 1
  case "$head" in
    unknown) ;;
    *) fm_pr_head_valid "$head" || return 1 ;;
  esac
  case "$attempt" in ''|*[[:space:]=]*) return 1 ;; esac
  PIPELINE_RECORD_LINE=$line
  PIPELINE_RECORD_REV=$rev
  PIPELINE_RECORD_TS=$ts
  PIPELINE_RECORD_STEP=$step
  PIPELINE_RECORD_GEN=$gen
  PIPELINE_RECORD_HEAD=$head
  PIPELINE_RECORD_EVIDENCE=$evidence
  PIPELINE_RECORD_ATTEMPT=$attempt
  PIPELINE_RECORD_HAS_LINE=1
}

pipeline_predicate_dispatched() {  # <meta>
  local meta=$1
  pipeline_meta_cache_load "$meta" || return 1
  [ -n "$PIPELINE_META_GEN" ]
}

pipeline_predicate_pr_registered() {  # <meta>
  pipeline_meta_identity_load "$1"
}

pipeline_predicate_merged() {  # <id> <meta>
  local id=$1 meta=$2
  pipeline_meta_identity_load "$meta" || return 1
  fm_pr_poll_merge_already_notified "$STATE" "$id" "$FM_PR_META_PROVIDER" \
    "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER"
}

pipeline_kind_has_step() {  # <kind> <step>
  local nodes edges
  IFS=$'\t' read -r nodes edges <<EOF
$(pipeline_kind_steps "$1" 2>/dev/null)
EOF
  case " $nodes " in
    *" $2 "*) return 0 ;;
    *) return 1 ;;
  esac
}

pipeline_step_proven() {  # <id> <meta> <kind> <step> <head>
  local id=$1 meta=$2 kind=$3 step=$4
  pipeline_kind_has_step "$kind" "$step" || return 1
  case "$step" in
    dispatched) pipeline_predicate_dispatched "$meta" ;;
    pr-registered)
      pipeline_predicate_pr_registered "$meta"
      ;;
    merged)
      pipeline_predicate_merged "$id" "$meta"
      ;;
    *) return 1 ;;
  esac
}

pipeline_record_prepare() {  # <id> <meta-kind> <meta-gen> [migrate]
  local id=$1 kind=$2 gen=$3 migrate=${4:-1} pipeline="$STATE/$1.pipeline" seen="$STATE/$1.pipeline-seen" first
  pipeline_state_file_valid "$pipeline" || return 3
  pipeline_state_file_valid "$seen" || return 3
  [ -e "$pipeline" ] || [ -L "$pipeline" ] || return 0
  first=$(awk 'NR == 1 { print; exit }' "$pipeline" 2>/dev/null || true)
  case "$first" in
    "schema=$PIPELINE_SCHEMA task=$id kind=$kind gen=$gen") return 0 ;;
    "schema=$PIPELINE_SCHEMA "*) return 0 ;;
    *)
      [ "$migrate" = 1 ] || return 4
      if [ -e "$seen" ] || [ -L "$seen" ]; then
        return 2
      fi
      mv -- "$pipeline" "$seen" || return 3
      printf 'fm-pipeline.sh: migrated legacy observation cache %s to %s\n' \
        "$pipeline" "$seen" >&2
      ;;
  esac
}

pipeline_record_load() {  # <id> <meta-file> <kind> <gen> [migrate] [cached]
  local id=$1 meta=$2 kind=$3 gen=$4 migrate=${5:-1} cached=${6:-0}
  local pipeline="$STATE/$1.pipeline" line number=0 prev_rev=0 expected_rev cache_rc
  pipeline_record_reset
  PIPELINE_RECORD_KIND=$kind
  PIPELINE_RECORD_GEN=$gen
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    PIPELINE_RECORD_STATE=refused:absent-meta-not-cleaned
    PIPELINE_RECORD_REASON=absent-meta-not-cleaned
    return 1
  }
  if [ "$cached" -ne 1 ]; then
    cache_rc=0
    pipeline_meta_cache_load "$meta" || cache_rc=$?
    case "$cache_rc" in
      0) ;;
      2)
        PIPELINE_RECORD_STATE=refused:malformed-meta-artifact
        PIPELINE_RECORD_REASON=malformed-meta-artifact
        return 1
        ;;
      *)
        PIPELINE_RECORD_STATE=refused:absent-meta-not-cleaned
        PIPELINE_RECORD_REASON=absent-meta-not-cleaned
        return 1
        ;;
    esac
  fi
  pipeline_record_prepare "$id" "$kind" "$gen" "$migrate"
  case "$?" in
    2) pipeline_record_refuse migration-collision; return 1 ;;
    3) pipeline_record_refuse unsafe-record-path; return 1 ;;
    4) pipeline_record_refuse legacy-cache "$pipeline:1"; return 1 ;;
  esac
  [ -e "$pipeline" ] || [ -L "$pipeline" ] || {
    PIPELINE_RECORD_STATE=uninitialized
    return 0
  }
  [ -f "$pipeline" ] && [ ! -L "$pipeline" ] || {
    pipeline_record_refuse malformed-record-line "$pipeline:1"
    return 1
  }
  pipeline_record_header_valid "$pipeline" "$id" "$kind" "$gen"
  case "$?" in
    1) pipeline_record_refuse malformed-record-line "$pipeline:1"; return 1 ;;
    2) pipeline_record_refuse foreign-gen "$pipeline:1"; return 1 ;;
  esac
  # shellcheck disable=SC2094
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    [ "$number" -gt 1 ] || continue
    # shellcheck disable=SC2094
    if ! pipeline_record_line_load "$line" "$pipeline" "$number" "$gen"; then
      pipeline_record_refuse malformed-record-line "$pipeline:$number"
      return 1
    fi
    expected_rev=$((prev_rev + 1))
    [ "$PIPELINE_RECORD_REV" -eq "$expected_rev" ] 2>/dev/null || {
      pipeline_record_refuse malformed-record-line "$pipeline:$number"
      return 1
    }
    prev_rev=$PIPELINE_RECORD_REV
    if ! pipeline_step_proven "$id" "$meta" "$kind" "$PIPELINE_RECORD_STEP" "$PIPELINE_RECORD_HEAD"; then
      pipeline_record_refuse unproven-step "$pipeline:$number"
      return 1
    fi
  done < "$pipeline"
  PIPELINE_RECORD_STATE=ok
  return 0
}

pipeline_record_append() {  # <id> <kind> <gen> <step> <evidence> <head> <attempt>
  local id=$1 kind=$2 gen=$3 step=$4 evidence=$5 head=$6 attempt=$7
  local pipeline="$STATE/$id.pipeline" tmp ts rev device
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  rev=$((PIPELINE_RECORD_REV + 1))
  pipeline_state_file_valid "$pipeline" || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-pipeline-record.XXXXXX") || return 1
  if [ "$PIPELINE_RECORD_HAS_LINE" -eq 0 ]; then
    printf 'schema=%s task=%s kind=%s gen=%s\n' "$PIPELINE_SCHEMA" "$id" "$kind" "$gen" > "$tmp" || {
      rm -f -- "$tmp"; return 1;
    }
  else
    cat "$pipeline" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  printf 'rev=%s ts=%s step=%s evidence=%s gen=%s head=%s attempt=%s\n' \
    "$rev" "$ts" "$step" "$evidence" "$gen" "$head" "$attempt" >> "$tmp" || {
    rm -f -- "$tmp"; return 1;
  }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_pr_private_file_valid "$tmp" 600 "$device" || { rm -f -- "$tmp"; return 1; }
  fm_pr_regular_destination_on_device_or_absent "$pipeline" "$device" || {
    rm -f -- "$tmp"; return 1;
  }
  mv -f -- "$tmp" "$pipeline" || { rm -f -- "$tmp"; return 1; }
  PIPELINE_RECORD_STATE=ok
  PIPELINE_RECORD_KIND=$kind
  PIPELINE_RECORD_GEN=$gen
  PIPELINE_RECORD_STEP=$step
  PIPELINE_RECORD_REV=$rev
  PIPELINE_RECORD_TS=$ts
  PIPELINE_RECORD_HEAD=$head
  PIPELINE_RECORD_EVIDENCE=$evidence
  PIPELINE_RECORD_ATTEMPT=$attempt
  PIPELINE_RECORD_HAS_LINE=1
}

pipeline_derived_step() {  # <id> <meta> <kind> -> step<TAB>evidence<TAB>head
  local id=$1 meta=$2 kind=$3 pr_head=${PIPELINE_META_PR_HEAD:-unknown}
  [ -n "$pr_head" ] || pr_head=unknown
  if pipeline_predicate_merged "$id" "$meta" && pipeline_kind_has_step "$kind" merged; then
    printf 'merged\tpr-poll:state/%s.pr-poll-merge-notified\t%s\n' "$id" "$pr_head"
    return 0
  fi
  if pipeline_predicate_pr_registered "$meta" && pipeline_kind_has_step "$kind" pr-registered; then
    pr_head=${PIPELINE_META_PR_HEAD:-unknown}
    [ -n "$pr_head" ] || pr_head=unknown
    printf 'pr-registered\tmeta:state/%s.meta\t%s\n' "$id" "$pr_head"
    return 0
  fi
  if pipeline_predicate_dispatched "$meta" && pipeline_kind_has_step "$kind" dispatched; then
    printf 'dispatched\tmeta:state/%s.meta\tunknown\n' "$id"
    return 0
  fi
  return 1
}

pipeline_reconcile_test_signal() {  # test-only competing-client handshake
  local ready=${FM_PIPELINE_TEST_RECONCILE_BEFORE_LOCK_READY:-}
  [ -z "$ready" ] || printf '%s\n' ready > "$ready"
}

pipeline_reconcile_test_gate() {  # <phase>, test-only interleaving seam
  local phase=$1 gate=${FM_PIPELINE_TEST_RECONCILE_GATE:-}
  [ -n "$gate" ] || return 0
  [ "${FM_PIPELINE_TEST_RECONCILE_GATE_PHASE:-after-load}" = "$phase" ] || return 0
  printf '%s\n' ready > "$gate.ready" || return 1
  while [ -e "$gate" ]; do
    sleep 0.01
  done
}

pipeline_reconcile_unlock() {
  fm_lock_release "$PIPELINE_LOCK_DIR" || true
  trap - EXIT
}

pipeline_reconcile_refuse_locked() {  # <reason> [<line>] [<repair>]
  local reason=$1 line=${2:-} repair=${3:-1}
  pipeline_reconcile_unlock
  printf 'refused:%s %s\n' "$reason" "$line" >&2
  [ "$repair" -eq 1 ] && printf '%s\n' "$PIPELINE_REPAIR" >&2
  return 1
}

pipeline_reconcile() {  # <id> [quiet]
  local id=$1 quiet=${2:-} meta kind gen attempt derived step evidence head
  local initial_kind initial_gen cache_rc
  fm_task_id_path_safe "$id" || { printf 'refused:invalid-task-id\n' >&2; return 1; }
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
    printf 'refused:state-directory-unavailable\n' >&2
    return 1
  }
  meta="$STATE/$id.meta"
  pipeline_state_file_valid "$meta" || {
    printf 'refused:unsafe-meta-path\n' >&2
    return 1
  }
  pipeline_reconcile_test_signal
  lock_log
  cache_rc=0
  pipeline_meta_cache_load "$meta" || cache_rc=$?
  case "$cache_rc" in
    0) ;;
    2)
      pipeline_reconcile_refuse_locked malformed-meta-artifact '' 0
      return 1
      ;;
    *)
      pipeline_reconcile_refuse_locked absent-meta-not-cleaned '' 0
      return 1
      ;;
  esac
  kind=$PIPELINE_META_KIND
  gen=$PIPELINE_META_GEN
  [ -n "$kind" ] && [ -n "$gen" ] || {
    pipeline_reconcile_refuse_locked missing-meta-artifact '' 0
    return 1
  }
  case "$kind:$gen" in
    *[[:space:]=]*)
      pipeline_reconcile_refuse_locked malformed-meta-artifact '' 0
      return 1
      ;;
  esac
  pipeline_kind_steps "$kind" >/dev/null || {
    pipeline_reconcile_refuse_locked unknown-pipeline-kind '' 0
    return 1
  }
  initial_kind=$kind
  initial_gen=$gen
  pipeline_reconcile_test_gate after-load
  cache_rc=0
  pipeline_meta_cache_load "$meta" 1 || cache_rc=$?
  case "$cache_rc" in
    0) ;;
    2)
      pipeline_reconcile_refuse_locked malformed-meta-artifact '' 0
      return 1
      ;;
    *)
      pipeline_reconcile_refuse_locked absent-meta-not-cleaned '' 0
      return 1
      ;;
  esac
  kind=$PIPELINE_META_KIND
  gen=$PIPELINE_META_GEN
  [ "$kind" = "$initial_kind" ] || {
    pipeline_reconcile_refuse_locked foreign-kind ''
    return 1
  }
  [ "$gen" = "$initial_gen" ] || {
    pipeline_reconcile_refuse_locked foreign-gen ''
    return 1
  }
  pipeline_record_load "$id" "$meta" "$kind" "$gen" 1 1
  if [ "$PIPELINE_RECORD_STATE" != uninitialized ] && [ "$PIPELINE_RECORD_STATE" != ok ]; then
    pipeline_reconcile_refuse_locked "$PIPELINE_RECORD_REASON" "${PIPELINE_RECORD_LINE:-}"
    return 1
  fi
  derived=$(pipeline_derived_step "$id" "$meta" "$kind") || {
    pipeline_reconcile_refuse_locked no-proven-artifact '' 0
    return 1
  }
  IFS=$'\t' read -r step evidence head <<EOF
$derived
EOF
  if [ "$PIPELINE_RECORD_HAS_LINE" -eq 1 ] && [ "$PIPELINE_RECORD_STEP" = "$step" ]; then
    pipeline_reconcile_unlock
    [ "$quiet" = probe ] || printf 'unchanged: %s step=%s rev=%s\n' "$id" "$step" "$PIPELINE_RECORD_REV"
    return 0
  fi
  attempt=${PIPELINE_META_ATTEMPT:--}
  case "$attempt" in
    *[[:space:]=]*)
      pipeline_reconcile_refuse_locked malformed-meta-artifact '' 0
      return 1
      ;;
  esac
  pipeline_record_append "$id" "$kind" "$gen" "$step" "$evidence" "$head" "$attempt" || {
    pipeline_reconcile_refuse_locked record-write '' 0
    return 1
  }
  pipeline_reconcile_unlock
  [ "$quiet" = probe ] || printf 'reconciled: %s step=%s rev=%s\n' "$id" "$step" "$PIPELINE_RECORD_REV"
}

pipeline_retire() {  # <id>
  local id=$1 meta pipeline="$STATE/$1.pipeline" seen="$STATE/$1.pipeline-seen" path
  fm_task_id_path_safe "$id" || { printf 'refused:invalid-task-id\n' >&2; return 1; }
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { printf 'refused:unsafe-record-path\n' >&2; return 1; }
  meta="$STATE/$id.meta"
  [ ! -e "$meta" ] && [ ! -L "$meta" ] || {
    printf 'refused:live-meta\n' >&2
    return 1
  }
  for path in "$pipeline" "$seen"; do
    pipeline_state_file_valid "$path" || {
      printf 'refused:unsafe-record-path\n' >&2
      return 1
    }
  done
  lock_log
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    fm_lock_release "$PIPELINE_LOCK_DIR" || true
    trap - EXIT
    printf 'refused:live-meta\n' >&2
    return 1
  fi
  rm -f -- "$pipeline" "$seen" || {
    fm_lock_release "$PIPELINE_LOCK_DIR" || true
    trap - EXIT
    printf 'refused:record-retire\n' >&2
    return 1
  }
  fm_lock_release "$PIPELINE_LOCK_DIR"
  trap - EXIT
  printf 'retired: %s\n' "$id"
}

pipeline_board_waits_json() {  # <task-id> <generation>
  local id=$1 gen=$2 key row ts probe evidence wait tmp keys_json
  tmp=$(umask 077; mktemp "$STATE/.fm-board-waits.XXXXXX") || return 1
  : > "$tmp"
  if [ -f "$LOG" ] && [ ! -L "$LOG" ]; then
    keys_json=$(awk -v task="task=$id" -v generation="gen=$gen" \
      '$2 == task && $11 == generation && NF == 14 { print $13 }' "$LOG" 2>/dev/null | sort -u)
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      row=$(awk -v task="task=$id" -v generation="gen=$gen" -v wait="$key" \
        '$2 == task && $11 == generation && $13 == wait && NF == 14 { line=$0 } END { print line }' "$LOG" 2>/dev/null)
      [ -n "$row" ] || continue
          local field1 field6 field10 field13
      IFS=' ' read -r field1 _ _ _ _ field6 _ _ _ field10 _ _ field13 _ <<EOF
$row
EOF
      ts=${field1#ts=}; probe=${field6#probe=}; evidence=${field10#evidence=}; wait=${field13#wait=}
      jq -nc --arg key "$wait" --arg target - --arg verdict "$probe" \
        --arg evidence "$evidence" --arg ts "$ts" \
        '{key:$key,target:$target,verdict:$verdict,evidence:$evidence,ts:$ts}' >> "$tmp" || {
        rm -f -- "$tmp"; return 1;
      }
    done <<EOF
$keys_json
EOF
  fi
  jq -sc . "$tmp"
  local rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

pipeline_board_probe_json() {  # <task-id> <generation>
  local id=$1 gen=$2 row ts probe evidence
  if [ -f "$LOG" ] && [ ! -L "$LOG" ]; then
    row=$(awk -v task="task=$id" -v generation="gen=$gen" \
      '$2 == task && $11 == generation && NF == 14 { line=$0 } END { print line }' "$LOG" 2>/dev/null)
  fi
  if [ -n "${row:-}" ]; then
    local field1 field6 field10
    IFS=' ' read -r field1 _ _ _ _ field6 _ _ _ field10 _ _ _ _ <<EOF
$row
EOF
    ts=${field1#ts=}; probe=${field6#probe=}; evidence=${field10#evidence=}
    jq -nc --arg verdict "$probe" --arg ts "$ts" --arg evidence "$evidence" \
      '{verdict:$verdict,ts:$ts,evidence:$evidence}'
  else
    printf 'null\n'
  fi
}

pipeline_board_record_header() {  # <file> -> task<TAB>kind<TAB>gen
  local file=$1 line schema task kind gen
  line=$(awk 'NR == 1 { print; exit }' "$file" 2>/dev/null || true)
  [ "$(printf '%s\n' "$line" | awk '{print NF}')" -eq 4 ] || return 1
  IFS=' ' read -r schema task kind gen <<EOF
$line
EOF
  [ "$schema" = "schema=$PIPELINE_SCHEMA" ] || return 1
  printf '%s\t%s\t%s\n' "${task#task=}" "${kind#kind=}" "${gen#gen=}"
}

pipeline_board_task_json() {  # <id> <output-file>
  local id=$1 output=$2 meta="$STATE/$1.meta" kind gen steps waits probe record_state initialized
  local record header header_kind header_gen cache_rc
  record="$STATE/$id.pipeline"
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    cache_rc=0
    pipeline_meta_cache_load "$meta" || cache_rc=$?
    if [ "$cache_rc" -eq 0 ]; then
      kind=${PIPELINE_META_KIND:-unknown}
      gen=${PIPELINE_META_GEN:-unknown}
    else
      kind=unknown
      gen=unknown
    fi
    if [ "$kind" = unknown ] || [ "$gen" = unknown ]; then
      pipeline_record_reset
      PIPELINE_RECORD_STATE=refused:malformed-meta-artifact
      PIPELINE_RECORD_REASON=malformed-meta-artifact
      record_state=$PIPELINE_RECORD_STATE
    elif ! pipeline_kind_steps "$kind" >/dev/null 2>&1; then
      pipeline_record_reset
      PIPELINE_RECORD_STATE=refused:unknown-pipeline-kind
      PIPELINE_RECORD_REASON=unknown-pipeline-kind
      record_state=$PIPELINE_RECORD_STATE
    elif pipeline_record_load "$id" "$meta" "$kind" "$gen" 0 1; then
      record_state=${PIPELINE_RECORD_STATE:-uninitialized}
    else
      record_state=${PIPELINE_RECORD_STATE:-refused:record}
    fi
  else
    header=$(pipeline_board_record_header "$record" 2>/dev/null || true)
    [ -n "$header" ] || return 0
    IFS=$'\t' read -r id header_kind header_gen <<EOF
$header
EOF
    kind=$header_kind
    gen=$header_gen
    pipeline_record_reset
    PIPELINE_RECORD_STATE=refused:absent-meta-not-cleaned
    PIPELINE_RECORD_REASON=absent-meta-not-cleaned
    record_state=$PIPELINE_RECORD_STATE
  fi
  if ! steps=$(pipeline_steps_json "$kind" 2>/dev/null); then
    steps='{"nodes":[],"edges":[]}'
    [ "$record_state" = uninitialized ] && record_state=refused:unknown-pipeline-kind
  fi
  waits=$(pipeline_board_waits_json "$id" "$gen") || return 1
  probe=$(pipeline_board_probe_json "$id" "$gen") || return 1
  initialized=false
  if [ "$record_state" = ok ] && [ "$PIPELINE_RECORD_HAS_LINE" -eq 1 ]; then
    initialized=true
  fi
  if [ "$initialized" = true ]; then
    jq -nc --arg id "$id" --arg kind "$kind" --arg gen "$gen" --argjson steps "$steps" \
      --arg step "$PIPELINE_RECORD_STEP" --argjson step_rev "$PIPELINE_RECORD_REV" \
      --arg step_ts "$PIPELINE_RECORD_TS" --arg step_evidence "$PIPELINE_RECORD_EVIDENCE" \
      --argjson waits "$waits" --argjson probe "$probe" --argjson initialized true \
      --argjson step_proven true --arg record_state "$record_state" \
      '{id:$id,kind:$kind,gen:$gen,steps:$steps,step:$step,step_rev:$step_rev,step_ts:$step_ts,step_evidence:$step_evidence,crew_state:{verb:"unavailable",source:"-",ts:"-"},waits:$waits,probe_last:$probe,initialized:$initialized,step_proven:$step_proven,record_state:$record_state}' >> "$output"
  else
    jq -nc --arg id "$id" --arg kind "$kind" --arg gen "$gen" --argjson steps "$steps" \
      --argjson waits "$waits" --argjson probe "$probe" --argjson initialized false \
      --argjson step_proven false --arg record_state "$record_state" \
      '{id:$id,kind:$kind,gen:$gen,steps:$steps,step:null,step_rev:null,step_ts:null,step_evidence:null,crew_state:{verb:"unavailable",source:"-",ts:"-"},waits:$waits,probe_last:$probe,initialized:$initialized,step_proven:$step_proven,record_state:$record_state}' >> "$output"
  fi
}

pipeline_board_json() {
  local inventory tasks_file task_file file id first generated_epoch check_interval
  local tmp rc
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die 'state directory is unavailable'
  inventory=$(umask 077; mktemp "$STATE/.fm-board-inventory.XXXXXX") || return 1
  tasks_file=$(umask 077; mktemp "$STATE/.fm-board-tasks.XXXXXX") || { rm -f -- "$inventory"; return 1; }
  task_file=$(umask 077; mktemp "$STATE/.fm-board-task-json.XXXXXX") || {
    rm -f -- "$inventory" "$tasks_file"; return 1;
  }
  : > "$inventory"; : > "$task_file"
  for file in "$STATE"/*.meta; do
    pipeline_state_file_valid "$file" || continue
    id=${file##*/}; id=${id%.meta}
    fm_task_id_path_safe "$id" && printf '%s\n' "$id" >> "$inventory"
  done
  for file in "$STATE"/*.pipeline; do
    pipeline_state_file_valid "$file" || continue
    first=$(pipeline_board_record_header "$file" 2>/dev/null || true)
    [ -n "$first" ] || continue
    id=${first%%$'\t'*}
    fm_task_id_path_safe "$id" && printf '%s\n' "$id" >> "$inventory"
  done
  sort -u "$inventory" > "$tasks_file"
  # shellcheck disable=SC2094
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    pipeline_board_task_json "$id" "$task_file" || {
      rm -f -- "$inventory" "$tasks_file" "$task_file"
      return 1
    }
  done < "$tasks_file"
  tasks=$(jq -sc . "$task_file") || {
    rm -f -- "$inventory" "$tasks_file" "$task_file"
    return 1
  }
  generated_epoch=$(date +%s)
  check_interval=${FM_CHECK_INTERVAL:-${CHECK_INTERVAL:-300}}
  case "$check_interval" in ''|*[!0-9]*) check_interval=300 ;; esac
  jq -nc --argjson generated_epoch "$generated_epoch" --argjson check_interval "$check_interval" \
    --argjson tasks "$tasks" \
    '{schema:"fm-pipeline-board.v1",generated_epoch:$generated_epoch,check_interval:$check_interval,tasks:$tasks}'
  rc=$?
  rm -f -- "$inventory" "$tasks_file" "$task_file"
  return "$rc"
}

pipeline_deadline_validate() {  # <seconds>
  local value=${1-20} normalized max=9223372036854775807
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  normalized=$value
  while [ "${normalized#0}" != "$normalized" ]; do
    normalized=${normalized#0}
  done
  [ -n "$normalized" ] || normalized=0
  if [ "${#normalized}" -ge 19 ]; then
    [ "${#normalized}" -eq 19 ] || return 1
    [ "$(printf '%s\n' "$normalized" "$max" | LC_ALL=C sort | tail -n 1)" = "$max" ] || return 1
  fi
  printf '%s\n' "$((10#$normalized))"
}

pipeline_deadline_decision() {  # <started> <now> <deadline>
  local started=$1 now=$2 deadline=$3 elapsed
  if [ "$deadline" -eq 0 ] || [ "$now" -le "$started" ]; then
    printf '%s\n' continue
    return
  fi
  elapsed=$((now - started))
  if [ "$elapsed" -lt "$deadline" ]; then
    printf '%s\n' continue
  else
    printf '%s\n' stop
  fi
}

pipeline_probe_row() {  # <ts> <task> <kind> <step> <since> <probe> <rule> <action> <evidence> <gen> <attempt> <wait>
  printf 'ts=%s task=%s kind=%s step=%s since=%s probe=%s rule=%s action=%s mode=shadow evidence=%s gen=%s attempt=%s wait=%s snap=-\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}"
}

pipeline_scan_unknown_row() {  # <task> <scan-reason>
  local id=$1 reason=$2 ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) || die 'could not read UTC time'
  lock_log
  append_event_locked "$(pipeline_probe_row "$ts" "$id" - - 0 unknown - none "scan:$reason" - - ext:-)" \
    || die 'cannot append event log'
  fm_lock_release "$PIPELINE_LOCK_DIR" || die 'cannot release event log lock'
  trap - EXIT
}

probe_task() {  # <id> [quiet]
  local id=$1 quiet=${2:-} status_file meta activity_read_failed=0
  local pauses line_no key line now ts since kind step gen attempt wait rule action probe evidence
  fm_task_id_path_safe "$id" || die "invalid task id: $id"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  status_file="$STATE/$id.status"
  meta="$STATE/$id.meta"
  pipeline_state_file_valid "$status_file" || die "status file is unavailable: $id"
  pipeline_state_file_valid "$meta" || die "meta file is unavailable: $id"
  pipeline_record_reset
  if [ -f "$meta" ]; then
    if [ "$quiet" = quiet ]; then
      pipeline_reconcile "$id" probe >/dev/null 2>/dev/null || return 1
    else
      pipeline_reconcile "$id" probe >/dev/null || return 1
    fi
  fi
  [ -f "$status_file" ] || return 0
  if ! pauses=$(active_paused "$status_file"); then
    activity_read_failed=1
  fi
  if [ "$activity_read_failed" -eq 1 ]; then
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    kind=${PIPELINE_RECORD_KIND:--}
    step=${PIPELINE_RECORD_STEP:--}
    gen=${PIPELINE_RECORD_GEN:--}
    attempt=${PIPELINE_RECORD_ATTEMPT:--}
    [ -n "$kind" ] || kind=-
    [ -n "$step" ] || step=-
    [ -n "$gen" ] || gen=-
    [ -n "$attempt" ] || attempt=-
    lock_log
    append_event_locked "$(pipeline_probe_row "$ts" "$id" "$kind" "$step" 0 unknown - none \
      scan:activity-read-failed "$gen" "$attempt" ext:-)" || die 'cannot append event log'
    fm_lock_release "$PIPELINE_LOCK_DIR" || die 'cannot release event log lock'
    trap - EXIT
    return 0
  fi
  [ -n "$pauses" ] || return 0
  now=$(date +%s)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  kind=${PIPELINE_RECORD_KIND:--}
  step=${PIPELINE_RECORD_STEP:--}
  gen=${PIPELINE_RECORD_GEN:--}
  attempt=${PIPELINE_RECORD_ATTEMPT:--}
  [ -n "$kind" ] || kind=-
  [ -n "$step" ] || step=-
  [ -n "$gen" ] || gen=-
  [ -n "$attempt" ] || attempt=-
  lock_log
  while IFS=$'\t' read -r line_no key line; do
    wait=$(wait_identity "$key")
    evidence="state/$id.status:$line_no"
    probe=unknown
    rule=-
    action=none
    since=$(observation_elapsed_since "$id" "$wait" "$step" "$gen" "$evidence" "$now") || die "cannot record pipeline observation"
    append_event_locked "$(pipeline_probe_row "$ts" "$id" "$kind" "$step" "$since" "$probe" "$rule" "$action" "$evidence" "$gen" "$attempt" "$wait")" || die "cannot append event log"
  done <<EOF
$pauses
EOF
  fm_lock_release "$PIPELINE_LOCK_DIR" || die "cannot release event log lock"
  trap - EXIT
}

probe_all() {
  local file id deadline started now task_list timed_out=0
  if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
    pipeline_state_unavailable_report
    return 1
  fi
  if ! deadline=$(pipeline_deadline_validate "${FM_PIPELINE_DEADLINE-20}"); then
    printf 'fm-pipeline.sh: invalid FM_PIPELINE_DEADLINE: %s (non-negative integer seconds; 0 disables)\n' \
      "${FM_PIPELINE_DEADLINE-}" >&2
    return 2
  fi
  task_list=$(for file in "$STATE"/*.meta "$STATE"/*.status; do
    pipeline_state_file_valid "$file" || continue
    id=${file##*/}
    id=${id%.*}
    fm_task_id_path_safe "$id" || continue
    printf '%s\n' "$id"
  done | sort -u) || return 1
  if [ "$deadline" -ne 0 ]; then
    started=$(date +%s) || return 1
  else
    started=0
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ "$timed_out" -eq 0 ] && [ "$deadline" -ne 0 ]; then
      now=$(date +%s) || return 1
      if [ "$(pipeline_deadline_decision "$started" "$now" "$deadline")" = stop ]; then
        timed_out=1
      fi
    fi
    if [ "$timed_out" -eq 1 ]; then
      pipeline_scan_unknown_row "$id" deadline || return 1
    else
      probe_task "$id" quiet || true
    fi
  done <<EOF
$task_list
EOF
  return "$timed_out"
}

if [ "${FM_PIPELINE_SOURCE_ONLY:-0}" = 1 ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi
shift || true
case "$command" in
  reconcile)
    [ "$#" -eq 1 ] || die 'reconcile requires a task id'
    pipeline_reconcile "$1"
    ;;
  retire)
    [ "$#" -eq 1 ] || die 'retire requires a task id'
    pipeline_retire "$1"
    ;;
  board-json)
    [ "$#" -eq 0 ] || die 'board-json takes no arguments'
    pipeline_board_json
    ;;
  steps)
    [ "$#" -eq 1 ] || die 'steps requires a kind'
    pipeline_kind_steps "$1" >/dev/null || die "unknown pipeline kind: $1"
    IFS=$'\t' read -r nodes edges <<EOF
$(pipeline_kind_steps "$1")
EOF
    printf 'kind=%s\nnodes=%s\nedges=%s\n' "$1" "$nodes" "$edges"
    ;;
  probe)
    task=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) [ "$#" -ge 2 ] || die '--task requires an id'; task=$2; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown probe option: $1" ;;
      esac
    done
    if [ -n "$task" ]; then probe_task "$task"; else probe_all; fi
    ;;
  append)
    [ "${FM_PIPELINE_ALLOW_APPEND:-0}" = 1 ] || die 'append is an internal test-only operation'
    [ "$#" -eq 1 ] || die 'append requires one event line'
    append_event "$1"
    ;;
  arm)
    force=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --force) force=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown arm option: $1" ;;
      esac
    done
    pipeline_arm "$force" || die 'could not arm pipeline watcher check'
    ;;
  disarm)
    pipeline_disarm || die 'could not disarm pipeline watcher check'
    ;;
  --help|-h)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
