#!/usr/bin/env bash
# fm-runner-health-check.sh - report a GitHub Actions runner label that has no
# online runner.
#
# Usage:
#   fm-runner-health-check.sh check <owner/repo> <runner-label>
#   fm-runner-health-check.sh arm <owner/repo> <runner-label>
#   fm-runner-health-check.sh disarm
#   fm-runner-health-check.sh --help
#
# `check` asks the repository actions/runners API for the named label.
# It prints exactly one line when no matching runner is online and nothing when
# a matching runner is online, including while that runner is busy.
# A missing registration and an offline registration are distinct findings.
#
# Network, authentication, timeout, and malformed-response failures are silent.
# They do not clear the report record, because no answer is not evidence that a
# runner recovered or failed.
#
# state/.runner-health records the target and last reported finding.
# The same outage is therefore reported once, a recovery clears it silently,
# and a later outage is news again.
#
# `arm` writes state/runner-health.check.sh with the target embedded and binds
# its bytes through fm-check-register.sh.
# The existing watcher then runs it within FM_CHECK_TIMEOUT on the ordinary
# check cadence and turns its one line into a `check:` wake.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID='runner-health'
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.runner-health"
RECORD_SCHEMA=fm-runner-health-v1
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-runner-health-check.sh check <owner/repo> <runner-label>  check once (silent when online or unavailable)
  fm-runner-health-check.sh arm <owner/repo> <runner-label>    arm the existing watcher check
  fm-runner-health-check.sh disarm                             remove the check and report record
  fm-runner-health-check.sh --help                             print this help

The runner label may use letters, digits, dot, underscore, and dash.
The check reports an offline or missing runner once until it recovers or changes state.
EOF
}

die_usage() {
  printf 'fm-runner-health-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

repository_valid() {
  local repository=$1 owner name
  case "$repository" in
    */*)
      owner=${repository%%/*}
      name=${repository#*/}
      [ -n "$owner" ] && [ -n "$name" ] && [ "$name" != "$repository" ] || return 1
      case "$name" in */*) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  case "$owner$name" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

label_valid() {
  [ -n "$1" ] || return 1
  case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

target_valid() {
  repository_valid "$1" && label_valid "$2"
}

PROBE_SECS=${FM_RUNNER_HEALTH_PROBE_SECS:-8}
case "$PROBE_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-runner-health-check: FM_RUNNER_HEALTH_PROBE_SECS must be a whole number from 1 to 20\n' >&2
    exit 2
    ;;
esac
if [ "$PROBE_SECS" -gt 20 ]; then
  printf 'fm-runner-health-check: FM_RUNNER_HEALTH_PROBE_SECS must be a whole number from 1 to 20\n' >&2
  exit 2
fi

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac

RECORD_TARGET=
RECORD_REPORTED=

record_read() {
  local line first=1
  RECORD_TARGET=
  RECORD_REPORTED=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" -eq 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      target=*) RECORD_TARGET=${line#target=} ;;
      reported=*) RECORD_REPORTED=${line#reported=} ;;
    esac
  done < "$RECORD"
}

record_write() {
  local target=$1 reported=$2 tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'target=%s\n' "$target"
    printf 'reported=%s\n' "$reported"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
}

api_state() {
  local repository=$1 label=$2 query output status page state pages
  local has_online=0 has_offline=0
  local max_probe=$((CHECK_TIMEOUT - 3))

  # Leave room for whole-second rounding, process cleanup, and record handling
  # inside the watcher's own bound.
  [ "$max_probe" -ge 1 ] || return 1
  if [ "$PROBE_SECS" -le "$max_probe" ]; then
    max_probe=$PROBE_SECS
  fi

  command -v gh-axi >/dev/null 2>&1 || return 1
  query="[.runners[] | select(any(.labels[]; .name == \"$label\"))] as \$matching | if (\$matching | length) == 0 then \"missing\" elif ([\$matching[] | select(.status == \"online\")] | length) > 0 then \"online\" else \"offline\" end"
  output=$(fm_run_timed "$max_probe" gh-axi api "/repos/$repository/actions/runners" --paginate --jq "$query" --full 2>/dev/null)
  status=$?
  [ "$status" -eq 0 ] || return 1

  pages=$(api_response_states "$output") || return 1
  while IFS= read -r page; do
    case "$page" in
      online) has_online=1 ;;
      offline) has_offline=1 ;;
      missing) ;;
      *) return 1 ;;
    esac
  done <<< "$pages"

  if [ "$has_online" -eq 1 ]; then
    state=online
  elif [ "$has_offline" -eq 1 ]; then
    state=offline
  else
    state=missing
  fi
  printf '%s\n' "$state"
}

api_response_states() {
  local output=$1 body separator segment
  local -a lines
  lines=()
  while IFS= read -r line; do
    lines+=("$line")
  done <<< "$output"
  [ "${#lines[@]}" -eq 3 ] || return 1
  [ "${lines[0]}" = 'api_response:' ] || return 1
  case "${lines[1]}" in
    '  body: '*) body=${lines[1]#  body: } ;;
    *) return 1 ;;
  esac
  [ "${lines[2]}" = '  truncated: false' ] || return 1
  [ -n "$body" ] || return 1

  case "$body" in
    \"*\")
      [ "${#body}" -ge 2 ] || return 1
      body=${body:1:${#body}-2}
      ;;
  esac

  separator='\n'
  while :; do
    case "$body" in
      *"$separator"*)
        segment=${body%%"$separator"*}
        body=${body#*"$separator"}
        ;;
      *)
        segment=$body
        body=
        ;;
    esac
    case "$segment" in
      online|offline|missing) printf '%s\n' "$segment" ;;
      *) return 1 ;;
    esac
    [ -n "$body" ] || break
  done
}

action_check() {
  local repository=$1 label=$2 target state finding=
  target="$repository@$label"

  state=$(api_state "$repository" "$label") || return 0
  case "$state" in
    online) finding= ;;
    offline) finding=offline ;;
    missing) finding=missing ;;
    *) return 0 ;;
  esac

  record_read
  if [ "$RECORD_TARGET" != "$target" ]; then
    RECORD_REPORTED=
  fi

  if [ -n "$finding" ] && [ "$finding" != "$RECORD_REPORTED" ]; then
    case "$finding" in
      offline) printf 'runner health: %s runner label %s is offline\n' "$repository" "$label" ;;
      missing) printf 'runner health: %s has no registered runner with label %s\n' "$repository" "$label" ;;
    esac
  fi
  record_write "$target" "$finding" || true
  return 0
}

shim_content() {
  local home=$1 repository=$2 label=$3
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-runner-health-check.sh - GitHub Actions runner health poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-runner-health-check.sh") check $(printf '%q' "$repository") $(printf '%q' "$label")"
}

SHIM_WRITE_TMP=

state_private_valid() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  local device
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ]
}

safe_remove_state_file() {
  local path=$1 device
  state_private_valid || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$path" "$device" || return 1
  rm -f -- "$path"
}

safe_restore_state_file() {
  local backup=$1 destination=$2 device
  state_private_valid || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$backup" "$device" || return 1
  fm_pr_regular_destination_on_device_or_absent "$destination" "$device" || return 1
  mv -f -- "$backup" "$destination"
}

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
  tmp=$(umask 077; mktemp "$STATE/.fm-runner-health-check.XXXXXX" 2>/dev/null) || return 1
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

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-runner-health-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || safe_remove_state_file "$SHIM_WRITE_TMP" || true
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    if safe_restore_state_file "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null; then
      ARM_BACKUP=
      if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
        return 0
      fi
    else
      return 1
    fi
  fi
  safe_remove_state_file "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-runner-health-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local repository=$1 label=$2 want home
  command -v gh-axi >/dev/null 2>&1 || {
    printf 'fm-runner-health-check: gh-axi is required\n' >&2
    return 1
  }
  mkdir -p "$STATE" || return 1
  state_private_valid || {
    printf 'fm-runner-health-check: state directory is unavailable\n' >&2
    return 1
  }
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-runner-health-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home" "$repository" "$label")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-runner-health-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-runner-health-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-runner-health-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh for %s label %s\n' "$CHECK_ID" "$repository" "$label"
}

action_disarm() {
  local device path
  state_private_valid || {
    printf 'fm-runner-health-check: state directory is unavailable\n' >&2
    return 1
  }
  device=$(fm_pr_file_device "$STATE") || return 1
  for path in "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"; do
    fm_pr_regular_destination_on_device_or_absent "$path" "$device" || {
      printf 'fm-runner-health-check: state artifact is unavailable\n' >&2
      return 1
    }
  done
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD" || return 1
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-}" in
  check)
    [ "$#" -eq 3 ] || die_usage 'check needs owner/repo and runner-label'
    target_valid "$2" "$3" || die_usage 'owner/repo or runner-label is invalid'
    action_check "$2" "$3"
    ;;
  arm)
    [ "$#" -eq 3 ] || die_usage 'arm needs owner/repo and runner-label'
    target_valid "$2" "$3" || die_usage 'owner/repo or runner-label is invalid'
    action_arm "$2" "$3"
    ;;
  disarm)
    [ "$#" -eq 1 ] || die_usage 'disarm takes no target'
    action_disarm
    ;;
  -h|--help) usage ;;
  *) die_usage 'unknown or missing action' ;;
esac
