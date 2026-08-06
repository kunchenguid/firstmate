#!/usr/bin/env bash

FM_CUSTOM_CHECK_HASH=
FM_CUSTOM_CHECK_SNAPSHOT=
FM_CUSTOM_CHECK_SLOT_LOCK=
FM_CUSTOM_CHECK_MIGRATION_LOCK=

fm_custom_check_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_custom_check_trust_read() {
  local state=$1 id=$2 trust state_device version hash
  FM_CUSTOM_CHECK_HASH=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  trust="$state/$id.check-trust"
  fm_pr_private_file_valid "$trust" 600 "$state_device" || return 1
  exec 9< "$trust" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-custom-check-v1 ] || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  FM_CUSTOM_CHECK_HASH=$hash
}

fm_custom_check_register_source() {
  local state=$1 id=$2 source=$3 trust state_device hash tmp
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$source" 700 "$state_device" || return 1
  trust="$state/$id.check-trust"
  fm_pr_regular_destination_on_device_or_absent "$trust" "$state_device" || return 1
  hash=$(fm_custom_check_sha256 "$source") || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-custom-check-trust.XXXXXX") || return 1
  if ! printf '%s\n%s\n' fm-custom-check-v1 "$hash" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$trust" "$state_device" \
    || ! mv -f -- "$tmp" "$trust"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_custom_check_trust_read "$state" "$id" || return 1
  [ "$FM_CUSTOM_CHECK_HASH" = "$hash" ]
}

fm_validation_check_slot_reserved() {
  local state=$1 id=$2 meta
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ "$(fm_pr_file_link_count "$meta")" = 1 ] || return 1
  grep -qx 'kind=ship' "$meta" || return 1
  grep -qx 'mode=no-mistakes' "$meta" || return 1
  ! grep -q '^pr=' "$meta"
}

fm_validation_check_source_emit() {
  local worktree=$1 nm_run_lib=$2 template=$3
  [ -n "$worktree" ] || return 1
  [ -f "$nm_run_lib" ] && [ ! -L "$nm_run_lib" ] || return 1
  [ -f "$template" ] && [ ! -L "$template" ] || return 1
  printf '%s\n' '#!/usr/bin/env bash' '# fm-validation-gate-check-v1'
  printf 'FM_VALIDATION_WORKTREE=%q\n' "$worktree"
  printf '%s\n' 'export FM_VALIDATION_WORKTREE'
  tail -n +2 "$nm_run_lib"
  tail -n +2 "$template"
}

fm_validation_check_source_matches() {
  local state=$1 id=$2 nm_run_lib=$3 template=$4 meta check state_device worktree
  fm_validation_check_slot_reserved "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  meta="$state/$id.meta"
  check="$state/$id.check.sh"
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  worktree=$(grep '^worktree=' "$meta" | tail -1 | cut -d= -f2- || true)
  [ -n "$worktree" ] || return 1
  cmp -s "$check" <(fm_validation_check_source_emit "$worktree" "$nm_run_lib" "$template")
}

fm_validation_check_registered() {
  local state=$1 id=$2 nm_run_lib=$3 template=$4
  fm_validation_check_source_matches "$state" "$id" "$nm_run_lib" "$template" \
    && fm_custom_check_registered "$state" "$id"
}

fm_custom_check_slot_acquire() {
  local state=$1 id=$2 max_attempts=${3:-100} lock attempt=0
  FM_CUSTOM_CHECK_SLOT_LOCK=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  [[ "$max_attempts" =~ ^[1-9][0-9]{0,3}$ ]] || return 1
  declare -F fm_lock_try_acquire >/dev/null 2>&1 || return 1
  lock="$state/.$id.check-slot.lock"
  while ! fm_lock_try_acquire "$lock"; do
    [ "$attempt" -lt "$max_attempts" ] || return 1
    sleep 0.05
    attempt=$((attempt + 1))
  done
  FM_CUSTOM_CHECK_SLOT_LOCK=$lock
}

fm_custom_check_slot_release() {
  local lock=${FM_CUSTOM_CHECK_SLOT_LOCK:-}
  [ -n "$lock" ] || return 0
  fm_lock_release "$lock" || return 1
  FM_CUSTOM_CHECK_SLOT_LOCK=
}

fm_custom_check_migration_acquire() {
  local state=$1 max_attempts=${2:-100} lock attempt=0
  FM_CUSTOM_CHECK_MIGRATION_LOCK=
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  [[ "$max_attempts" =~ ^[1-9][0-9]{0,3}$ ]] || return 1
  declare -F fm_lock_try_acquire >/dev/null 2>&1 || return 1
  lock="$state/.check-migration.lock"
  while ! fm_lock_try_acquire "$lock"; do
    [ "$attempt" -lt "$max_attempts" ] || return 1
    sleep 0.05
    attempt=$((attempt + 1))
  done
  FM_CUSTOM_CHECK_MIGRATION_LOCK=$lock
}

fm_custom_check_migration_release() {
  local lock=${FM_CUSTOM_CHECK_MIGRATION_LOCK:-}
  [ -n "$lock" ] || return 0
  fm_lock_release "$lock" || return 1
  FM_CUSTOM_CHECK_MIGRATION_LOCK=
}

fm_custom_check_slot_held() {
  local state=$1 id=$2 lock owner pid
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  declare -F fm_lock_link_owner >/dev/null 2>&1 || return 1
  declare -F fm_lock_points_to_owner >/dev/null 2>&1 || return 1
  declare -F fm_pid_alive >/dev/null 2>&1 || return 1
  lock="$state/.$id.check-slot.lock"
  [ -L "$lock" ] || return 1
  owner=$(fm_lock_link_owner "$lock") || return 1
  fm_lock_points_to_owner "$lock" "$owner" || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid"
}

fm_custom_check_any_slot_held() {
  local state=$1 lock name id
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  for lock in "$state"/.*.check-slot.lock; do
    [ -L "$lock" ] || continue
    name=${lock##*/}
    id=${name#.}
    id=${id%.check-slot.lock}
    [ ".$id.check-slot.lock" = "$name" ] || continue
    fm_pr_task_id_valid "$id" || continue
    fm_custom_check_slot_held "$state" "$id" && return 0
  done
  return 1
}

fm_custom_check_registered() {
  local state=$1 id=$2 check hash state_device
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  hash=$(fm_custom_check_sha256 "$check") || return 1
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ]
}

fm_custom_check_snapshot_prepare() {
  local state=$1 id=$2 check hash state_device
  fm_custom_check_snapshot_cleanup
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  FM_CUSTOM_CHECK_SNAPSHOT=$(mktemp "$state/.fm-custom-check.XXXXXX") || return 1
  cp "$check" "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  chmod 0600 "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  [ -f "$FM_CUSTOM_CHECK_SNAPSHOT" ] && [ ! -L "$FM_CUSTOM_CHECK_SNAPSHOT" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_mode "$FM_CUSTOM_CHECK_SNAPSHOT")" = 600 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_device "$FM_CUSTOM_CHECK_SNAPSHOT")" = "$state_device" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_link_count "$FM_CUSTOM_CHECK_SNAPSHOT")" = 1 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  hash=$(fm_custom_check_sha256 "$FM_CUSTOM_CHECK_SNAPSHOT") \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ] || { fm_custom_check_snapshot_cleanup; return 1; }
}

fm_custom_check_snapshot_cleanup() {
  [ -z "$FM_CUSTOM_CHECK_SNAPSHOT" ] || rm -f -- "$FM_CUSTOM_CHECK_SNAPSHOT"
  FM_CUSTOM_CHECK_SNAPSHOT=
}
