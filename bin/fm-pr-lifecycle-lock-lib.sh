#!/usr/bin/env bash
# Shared bounded typed ownership for one task's PR check, poll, watch, and merge lifecycle.

# shellcheck source=bin/fm-session-lock-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-wake-lib.sh"

FM_PR_LIFECYCLE_LOCK_OWNER=
FM_PR_LIFECYCLE_RECORD_ROLE=
FM_PR_LIFECYCLE_RECORD_PID=
FM_PR_LIFECYCLE_RECORD_IDENTITY=
FM_PR_LIFECYCLE_OBSERVED_OWNER=
FM_PR_LIFECYCLE_OBSERVED_STATUS=
FM_PR_LIFECYCLE_RECOVERY_HELD_PID=
FM_PR_LIFECYCLE_WAIT_ATTEMPTS=
FM_PR_LIFECYCLE_WAIT_INTERVAL=

fm_pr_lifecycle_wait_config() {
  local attempts interval
  attempts=${FM_PR_LIFECYCLE_LOCK_ATTEMPTS:-50}
  interval=${FM_PR_LIFECYCLE_LOCK_INTERVAL:-0.1}
  case "$attempts" in ''|*[!0-9]*|0) return 1 ;; esac
  [ "$attempts" -le 600 ] || return 1
  [[ "$interval" =~ ^(0([.][0-9]+)?|1([.]0+)?)$ ]] || return 1
  FM_PR_LIFECYCLE_WAIT_ATTEMPTS=$attempts
  FM_PR_LIFECYCLE_WAIT_INTERVAL=$interval
}

fm_pr_lifecycle_lock_path() {
  local state=$1 id=$2
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  fm_pr_task_id_valid "$id" || return 1
  printf '%s/.pr-check-%s.lock\n' "$state" "$id"
}

fm_pr_lifecycle_role_command() {
  case "$1" in
    check) printf 'fm-pr-check.sh\n' ;;
    merge) printf 'fm-pr-merge.sh\n' ;;
    watch) printf 'fm-watch.sh\n' ;;
    *) return 1 ;;
  esac
}

fm_pr_lifecycle_record_parse() {
  local record=$1 version role pid identity extra expected
  FM_PR_LIFECYCLE_RECORD_ROLE=
  FM_PR_LIFECYCLE_RECORD_PID=
  FM_PR_LIFECYCLE_RECORD_IDENTITY=
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  exec 7< "$record" || return 1
  IFS= read -r version <&7 || { exec 7<&-; return 1; }
  IFS= read -r role <&7 || { exec 7<&-; return 1; }
  IFS= read -r pid <&7 || { exec 7<&-; return 1; }
  IFS= read -r identity <&7 || { exec 7<&-; return 1; }
  if IFS= read -r extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$version" = fm-pr-lifecycle-v1 ] || return 1
  expected=$(fm_pr_lifecycle_role_command "$role") || return 1
  [ -n "$expected" ] || return 1
  case "$pid" in ''|*[!0-9]*|0|1|0*) return 1 ;; esac
  [[ "$identity" =~ ^[0-9a-f]{64}$ ]] || return 1
  FM_PR_LIFECYCLE_RECORD_ROLE=$role
  FM_PR_LIFECYCLE_RECORD_PID=$pid
  FM_PR_LIFECYCLE_RECORD_IDENTITY=$identity
}

fm_pr_lifecycle_link_owner() {
  local lock=$1 owner
  owner=$(readlink "$lock" 2>/dev/null) || return 1
  case "$owner" in
    "$lock".owner.*) [ -d "$owner" ] && [ ! -L "$owner" ] || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$owner"
}

fm_pr_lifecycle_points_to_owner() {
  local lock=$1 expected=$2 actual
  actual=$(readlink "$lock" 2>/dev/null) || return 1
  [ "$actual" = "$expected" ]
}

fm_pr_lifecycle_discard_owner() {
  local owner=$1
  [ -n "$owner" ] && [ -d "$owner" ] && [ ! -L "$owner" ] || return 0
  rm -f -- "$owner/record" "$owner/pid" 2>/dev/null || true
  rmdir -- "$owner" 2>/dev/null || true
}

fm_pr_lifecycle_try_create() {
  local lock=$1 role=$2 expected current identity owner
  expected=$(fm_pr_lifecycle_role_command "$role") || return 1
  current=${BASHPID:-$$}
  identity=$(fm_process_command_identity "$current" "$expected") || return 1
  owner=$(mktemp -d "${lock}.owner.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n' fm-pr-lifecycle-v1 "$role" "$current" "$identity" \
      > "$owner/record" \
    || ! printf '%s\n' "$current" > "$owner/pid" \
    || ! chmod 0600 "$owner/record" "$owner/pid"; then
    fm_pr_lifecycle_discard_owner "$owner"
    return 1
  fi
  if ln -s "$owner" "$lock" 2>/dev/null \
    && fm_pr_lifecycle_points_to_owner "$lock" "$owner"; then
    FM_PR_LIFECYCLE_LOCK_OWNER=$owner
    return 0
  fi
  fm_pr_lifecycle_discard_owner "$owner"
  return 1
}

fm_pr_lifecycle_owner_observe() {
  local lock=$1 owner expected observed args legacy_pid
  FM_PR_LIFECYCLE_OBSERVED_OWNER=
  FM_PR_LIFECYCLE_OBSERVED_STATUS=invalid
  owner=$(fm_pr_lifecycle_link_owner "$lock") || return 1
  FM_PR_LIFECYCLE_OBSERVED_OWNER=$owner
  if fm_pr_lifecycle_record_parse "$owner/record"; then
    expected=$(fm_pr_lifecycle_role_command "$FM_PR_LIFECYCLE_RECORD_ROLE") || return 1
    if ! fm_pid_exists_for_signal "$FM_PR_LIFECYCLE_RECORD_PID"; then
      FM_PR_LIFECYCLE_OBSERVED_STATUS=stale
      return 0
    fi
    observed=$(fm_process_command_identity "$FM_PR_LIFECYCLE_RECORD_PID" "$expected" 2>/dev/null || true)
    if [ -n "$observed" ]; then
      if [ "$observed" = "$FM_PR_LIFECYCLE_RECORD_IDENTITY" ]; then
        FM_PR_LIFECYCLE_OBSERVED_STATUS=live
      else
        FM_PR_LIFECYCLE_OBSERVED_STATUS=stale
      fi
      return 0
    fi
    args=$(ps -ww -o args= -p "$FM_PR_LIFECYCLE_RECORD_PID" 2>/dev/null || true)
    [ -n "$args" ] || return 0
    case "$args" in
      *"$expected"*) ;;
      *) FM_PR_LIFECYCLE_OBSERVED_STATUS=stale ;;
    esac
    return 0
  fi
  legacy_pid=$(cat "$owner/pid" 2>/dev/null || true)
  case "$legacy_pid" in ''|*[!0-9]*|0|1|0*) return 0 ;; esac
  if ! fm_pid_exists_for_signal "$legacy_pid"; then
    FM_PR_LIFECYCLE_OBSERVED_STATUS=stale
  fi
  return 0
}

fm_pr_lifecycle_try_recover() {
  local lock=$1 role=$2 recovery expected expected_owner
  FM_PR_LIFECYCLE_RECOVERY_HELD_PID=
  fm_pr_lifecycle_owner_observe "$lock" || return 1
  [ "$FM_PR_LIFECYCLE_OBSERVED_STATUS" = stale ] || return 1
  expected_owner=$FM_PR_LIFECYCLE_OBSERVED_OWNER
  recovery="$lock.recovery"
  expected=$(fm_pr_lifecycle_role_command "$role") || return 1
  if ! fm_lock_try_acquire "$recovery" "$expected"; then
    FM_PR_LIFECYCLE_RECOVERY_HELD_PID=${FM_LOCK_HELD_PID:-unknown}
    return 1
  fi
  if ! fm_pr_lifecycle_owner_observe "$lock" \
    || [ "$FM_PR_LIFECYCLE_OBSERVED_OWNER" != "$expected_owner" ] \
    || [ "$FM_PR_LIFECYCLE_OBSERVED_STATUS" != stale ] \
    || ! fm_pr_lifecycle_points_to_owner "$lock" "$expected_owner"; then
    fm_lock_release "$recovery"
    return 1
  fi
  rm -f -- "$lock" 2>/dev/null || {
    fm_lock_release "$recovery"
    return 1
  }
  fm_pr_lifecycle_discard_owner "$expected_owner"
  fm_lock_release "$recovery"
  return 0
}

fm_pr_lifecycle_lock_acquire() {
  local state=$1 id=$2 role=$3 lock attempts interval attempt=1 owner_role=unknown owner_pid=unknown
  [ -z "${FM_PR_LIFECYCLE_LOCK_OWNER:-}" ] || return 2
  fm_pr_lifecycle_wait_config || return 2
  attempts=$FM_PR_LIFECYCLE_WAIT_ATTEMPTS
  interval=$FM_PR_LIFECYCLE_WAIT_INTERVAL
  lock=$(fm_pr_lifecycle_lock_path "$state" "$id") || return 2
  fm_pr_lifecycle_role_command "$role" >/dev/null || return 2
  while [ "$attempt" -le "$attempts" ]; do
    if fm_pr_lifecycle_try_create "$lock" "$role"; then
      return 0
    fi
    if fm_pr_lifecycle_try_recover "$lock" "$role" \
      && fm_pr_lifecycle_try_create "$lock" "$role"; then
      return 0
    fi
    [ "$attempt" -ge "$attempts" ] || [ "$interval" = 0 ] || sleep "$interval"
    attempt=$((attempt + 1))
  done
  if fm_pr_lifecycle_owner_observe "$lock"; then
    owner_role=${FM_PR_LIFECYCLE_RECORD_ROLE:-unknown}
    owner_pid=${FM_PR_LIFECYCLE_RECORD_PID:-unknown}
  fi
  if [ -n "$FM_PR_LIFECYCLE_RECOVERY_HELD_PID" ]; then
    printf 'error: PR lifecycle recovery for task %s remained owned by process %s after %s bounded attempt(s)\n' \
      "$id" "$FM_PR_LIFECYCLE_RECOVERY_HELD_PID" "$attempts" >&2
  else
    printf 'error: PR lifecycle for task %s remained owned by %s process %s after %s bounded attempt(s)\n' \
      "$id" "$owner_role" "$owner_pid" "$attempts" >&2
  fi
  return 1
}

fm_pr_lifecycle_metadata_lock_acquire() {
  local meta=$1 lock attempts interval attempt=1 owner_pid=unknown
  fm_pr_lifecycle_wait_config || return 2
  attempts=$FM_PR_LIFECYCLE_WAIT_ATTEMPTS
  interval=$FM_PR_LIFECYCLE_WAIT_INTERVAL
  lock=$(fm_meta_lock_path "$meta") || return 2
  while [ "$attempt" -le "$attempts" ]; do
    if fm_lock_try_acquire "$lock"; then
      return 0
    fi
    owner_pid=${FM_LOCK_HELD_PID:-unknown}
    [ "$attempt" -ge "$attempts" ] || [ "$interval" = 0 ] || sleep "$interval"
    attempt=$((attempt + 1))
  done
  printf 'error: task metadata %s remained owned by process %s after %s bounded attempt(s)\n' \
    "$meta" "$owner_pid" "$attempts" >&2
  return 1
}

fm_pr_lifecycle_parent_owns() {
  local state=$1 id=$2 expected_role=$3 lock owner expected observed
  lock=$(fm_pr_lifecycle_lock_path "$state" "$id") || return 1
  owner=$(fm_pr_lifecycle_link_owner "$lock") || return 1
  fm_pr_lifecycle_record_parse "$owner/record" || return 1
  [ "$FM_PR_LIFECYCLE_RECORD_ROLE" = "$expected_role" ] \
    && [ "$FM_PR_LIFECYCLE_RECORD_PID" = "$PPID" ] || return 1
  expected=$(fm_pr_lifecycle_role_command "$expected_role") || return 1
  observed=$(fm_process_command_identity "$FM_PR_LIFECYCLE_RECORD_PID" "$expected") || return 1
  [ "$observed" = "$FM_PR_LIFECYCLE_RECORD_IDENTITY" ] \
    && fm_pr_lifecycle_points_to_owner "$lock" "$owner"
}

fm_pr_lifecycle_lock_release() {
  local state=$1 id=$2 role=$3 lock owner current
  lock=$(fm_pr_lifecycle_lock_path "$state" "$id") || return 1
  owner=${FM_PR_LIFECYCLE_LOCK_OWNER:-}
  [ -n "$owner" ] && fm_pr_lifecycle_points_to_owner "$lock" "$owner" || return 1
  fm_pr_lifecycle_record_parse "$owner/record" || return 1
  current=${BASHPID:-$$}
  [ "$FM_PR_LIFECYCLE_RECORD_ROLE" = "$role" ] \
    && [ "$FM_PR_LIFECYCLE_RECORD_PID" = "$current" ] || return 1
  rm -f -- "$lock" || return 1
  fm_pr_lifecycle_discard_owner "$owner"
  FM_PR_LIFECYCLE_LOCK_OWNER=
}
