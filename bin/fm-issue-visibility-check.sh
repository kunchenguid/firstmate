#!/usr/bin/env bash
# fm-issue-visibility-check.sh - opt-in report-only daily issue visibility check.
#
# Usage: fm-issue-visibility-check.sh [check|arm|disarm|--help]
# arm writes state/issue-visibility.check.sh and registers its bytes through
# fm-check-register.sh. Nothing arms this check automatically. disarm calls
# fm-check-unregister.sh and removes state/.issue-visibility-check: it is complete
# removal, and a fresh arm clears any record a check that straddled the disarm
# wrote back, so a later arm starts with empty alert history.
#
# check consumes only fm-bearings-snapshot.sh --json --include-issues. It prints
# one pointer to Bearings when an uncertain repo-qualified issue identity or an
# unmeasured source/reason is new. Counts describe the current projection, not
# history, and are lower bounds on incomplete runs. Labels never authorize work.
# No backlog, task, issue, or report is modified. Bearings remains a fresh report
# of every unresolved item, including items whose alert has already been sent.
#
# state/.issue-visibility-check is private JSON: schema, epoch, uncertain (issue
# identities), and unmeasured (source/reason pairs). Complete reads replace these
# sets; incomplete reads retain absent identities without treating them as accounted
# for. A newly observed reason replaces the previous reason for that source.
# A condition that disappears on a complete read and returns is new again.
# The line is printed before recording so a failed write causes a repeat rather
# than losing the alert. History is not a stored verdict or execution queue.
#
# FM_ISSUE_VISIBILITY_INTERVAL defaults to 86400 seconds (0 disables the gate;
# otherwise 60..86400). FM_ISSUE_VISIBILITY_NOW overrides the cadence clock for
# tests only. The whole snapshot uses FM_CHECK_TIMEOUT minus 3 seconds to leave time for kill
# grace and reporting. An unusably small watcher timeout reports unmeasured
# without launching a snapshot. Snapshot errors, invalid output and timeouts
# become unmeasured alerts, never an all-clear. Snapshot issue bounds still apply.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.issue-visibility-check"
CHECK_ID=issue-visibility
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
SNAPSHOT_BIN="$SCRIPT_DIR/fm-bearings-snapshot.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-issue-visibility-check.sh [check|arm|disarm|--help]
  check    report new uncertain issues or unmeasured coverage; otherwise silent
  arm      write and register state/issue-visibility.check.sh (explicit opt-in)
  disarm   remove the shim, trust binding and alert history completely

Uses only Bearings --include-issues; never admits or dispatches work.
FM_ISSUE_VISIBILITY_INTERVAL: 86400 seconds; 0 or 60..86400.
Snapshot timeout fits FM_CHECK_TIMEOUT; projection issue bounds are unchanged.
Covered means linked to tracked work or an open closing PR, not completed work.
Complete/proven_clear describe coverage accounted for, never all work done.
History suppresses alerts only; unresolved issues remain in fresh Bearings reports.
EOF
}

die_usage() { printf 'fm-issue-visibility-check: %s\n' "$1" >&2; exit 2; }

record_epoch_now() {
  case "${FM_ISSUE_VISIBILITY_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_ISSUE_VISIBILITY_NOW" ;;
  esac
}

action_check() (
  local interval budget bound now previous tmp rc=0 problem='' device
  interval=${FM_ISSUE_VISIBILITY_INTERVAL:-86400}
  case "$interval" in ''|*[!0-9]*) die_usage 'interval must be 0 or 60..86400' ;; esac
  # shellcheck disable=SC2015 # Every failed bound is a usage error.
  [ "${#interval}" -le 5 ] && { [ "$interval" -eq 0 ] || { [ "$interval" -ge 60 ] && [ "$interval" -le 86400 ]; }; } \
    || die_usage 'interval must be 0 or 60..86400'
  bound=${FM_CHECK_TIMEOUT:-30}
  case "$bound" in ''|*[!0-9]*|0) bound=30 ;; esac
  [ "${#bound}" -le 6 ] || bound=30
  budget=$((bound - 3))
  if [ "$budget" -le 0 ]; then problem='watcher timeout leaves no snapshot budget'; fi

  mkdir -p "$STATE" || return 1
  [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$RECORD" "$device" || return 1
  tmp=$(umask 077; mktemp -d "$STATE/.fm-issue-visibility.XXXXXX") || return 1
  trap 'rm -rf -- "$tmp"' EXIT
  now=$(record_epoch_now)
  if ! jq -e '
    .schema=="fm-issue-visibility-check.v1" and (.epoch|type)=="number" and .epoch>=0 and .epoch<100000000000
    and (.epoch|floor)==.epoch
    and (.uncertain|type)=="array" and all(.uncertain[];type=="string")
    and (.unmeasured|type)=="array"
    and all(.unmeasured[]; (.source|type)=="string" and (.reason|type)=="string")
  ' "$RECORD" >/dev/null 2>&1; then
    printf '{"epoch":0,"uncertain":[],"unmeasured":[]}\n' > "$tmp/previous"
  else cp "$RECORD" "$tmp/previous"; fi
  previous=$(jq -r '.epoch' "$tmp/previous")
  if [ "$interval" -ne 0 ] && [ "$previous" -gt 0 ] && [ "$now" -ge "$previous" ] \
    && [ "$((now - previous))" -lt "$interval" ]; then return 0; fi

  if [ -z "$problem" ]; then
    fm_run_timed "$budget" "$SNAPSHOT_BIN" --json --include-issues > "$tmp/snapshot" 2> "$tmp/error" || rc=$?
    if [ "$rc" -eq 124 ]; then problem='snapshot timeout'
    elif [ "$rc" -ne 0 ]; then problem="snapshot failed (exit $rc)"
    elif ! jq -e '
      .issue_visibility | .schema=="fm-issue-visibility.v1"
      and (.complete|type)=="boolean" and (.rows|type)=="array" and (.rows_omitted|type)=="number"
      and all(.rows[]; (.id|type)=="string" and (.tasks_omitted|type)=="number" and (.completed_tasks_omitted|type)=="number"
        and (.classification=="uncertain" or .classification=="covered" or .classification=="parked" or .classification=="unmeasured"))
      and (.repos|type)=="array" and (.homes|type)=="array" and (.omitted|type)=="array"
      and all(.repos[]; (.repo|type)=="string" and (.measured|type)=="boolean" and (.reason==null or (.reason|type)=="string"))
      and all(.homes[]; (.owner|type)=="string" and (.measured|type)=="boolean")
      and (.counts.uncertain|type)=="number" and (.counts.unmeasured|type)=="number"
    ' "$tmp/snapshot" >/dev/null 2>&1; then problem='snapshot projection unavailable or invalid'; fi
  fi
  if [ -n "$problem" ]; then
    jq -nc --arg reason "$problem" '{complete:false,uncertain:[],uncertain_count:0,unmeasured_rows:0,
      unmeasured:[{source:"snapshot",reason:$reason}]}' > "$tmp/current"
  else
    jq '.issue_visibility | {
      complete, uncertain:([.rows[]|select(.classification=="uncertain")|.id|ascii_downcase]|unique),
      uncertain_count:.counts.uncertain,unmeasured_rows:.counts.unmeasured,
      unmeasured:(([
        .repos[]|select(.measured|not)|{source:(.repo|ascii_downcase),reason:(.reason // "local coverage incomplete")}
      ] + [.homes[]|select(.measured|not)|{source:("home:"+.owner),reason:"local project/task coverage incomplete"}]
        + [if .rows_omitted>0 then {source:"projection",reason:"issue row bound"} else empty end]
        + [.rows[]|select(.tasks_omitted>0 or .completed_tasks_omitted>0)|{source:.id,reason:"task evidence bound"}]
        | unique) as $unmeasured
        | if (.complete|not) and ($unmeasured|length)==0
          then [{source:"snapshot",reason:"incomplete coverage"}] else $unmeasured end)
    }' "$tmp/snapshot" > "$tmp/current" || return 1
  fi
  jq -n --slurpfile old "$tmp/previous" --slurpfile current "$tmp/current" --argjson now "$now" '
    $old[0] as $old | $current[0] as $c
    | {new_issues:($c.uncertain-$old.uncertain|length),new_unmeasured:($c.unmeasured-$old.unmeasured|length),
       current:$c,record:{schema:"fm-issue-visibility-check.v1",epoch:$now,
         uncertain:((if $c.complete then [] else $old.uncertain end)+$c.uncertain|unique),
         unmeasured:((if $c.complete then [] else
           [$old.unmeasured[] | .source as $source | select(all($c.unmeasured[];.source!=$source))]
           end)+$c.unmeasured|unique)}}
  ' > "$tmp/result" || return 1
  jq -r 'select(.new_issues+.new_unmeasured>0)
    | "issue visibility: \(.current.uncertain_count) uncertain issues (\(.new_issues) new), \(.current.unmeasured_rows) unmeasured issues, \(.current.unmeasured|length) unmeasured sources/reasons (\(.new_unmeasured) new)\(if .current.complete then "" else "; incomplete, counts are lower bounds" end); see Bearings --include-issues"' "$tmp/result"
  # Report first; a failed history write must never suppress an unseen alert.
  (umask 077; jq '.record' "$tmp/result" > "$tmp/record") \
    && mv -f -- "$tmp/record" "$RECORD"
  return 0
)
# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-issue-visibility-check.sh - issue visibility check shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-issue-visibility-check.sh") check"
}

# Write the shim the way this repo writes its other trusted check shim: the
# guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-issue-visibility-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# Keep a byte copy of a shim that is already in place, so a failed arm can put
# back the shim a working home was already using rather than an equivalent
# rewrite. The trust binding is over the bytes, so a rewrite would satisfy it
# too, but a home that was armed stays armed with what it had.
shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-issue-visibility-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So the one rule after a
# failed or interrupted arm is that the home never holds a shim without a
# matching trust binding. The shim a working home had is put back and kept only
# when it is still bound; otherwise the shim goes, so the home is plainly not
# armed and the failure is the only thing the operator has to act on.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-issue-visibility-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if [ ! -x "$SNAPSHOT_BIN" ]; then
    printf 'fm-issue-visibility-check: the Bearings snapshot is missing at %s; cannot arm\n' "$SNAPSHOT_BIN" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-issue-visibility-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-issue-visibility-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  else
    # A fresh arm from the disarmed state starts with empty alert history even
    # when a check that straddled the disarm rewrote the record disarm removed.
    # Re-arming a home that still holds its shim keeps history untouched.
    rm -f -- "$RECORD" || return 1
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-issue-visibility-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-issue-visibility-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  [ -d "$STATE" ] || { printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"; return 0; }
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || return 1
  rm -f -- "$RECORD" || return 1
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
