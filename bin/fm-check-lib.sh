#!/usr/bin/env bash

FM_CUSTOM_CHECK_HASH=
FM_CUSTOM_CHECK_SNAPSHOT=

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

# Trust records live in the home's operator-owned config/trust/, beside state/,
# so a writer confined to state/ cannot authorize its own check. Only
# fm-check-register.sh and fm-procevent-when.sh write there. The state path is
# resolved physically first, so spellings such as state/. or a symlink to state
# still name the real parent, and a trust directory that resolves inside state
# is refused. A state path that does not exist yet has nothing to protect.
fm_trust_dir() {  # <state-dir>
  local state=$1 real config
  real=$(cd -P -- "$state" 2>/dev/null && pwd -P) || {
    printf '%s/config/trust\n' "$(dirname -- "$state")"
    return 0
  }
  config="$(dirname -- "$real")/config"
  if [ -e "$config" ]; then
    config=$(cd -P -- "$config" 2>/dev/null && pwd -P) || return 1
  fi
  case "$config/trust/" in "$real"/*) return 1 ;; esac
  printf '%s/trust\n' "$config"
}

fm_custom_check_trust_path() {  # <state-dir> <id>
  local dir
  dir=$(fm_trust_dir "$1") || return 1
  printf '%s/%s.check-trust\n' "$dir" "$2"
}

fm_custom_check_trust_read() {
  local state=$1 id=$2 trust trust_dir trust_device version hash
  FM_CUSTOM_CHECK_HASH=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  trust_dir=$(fm_trust_dir "$state") || return 1
  [ -d "$trust_dir" ] && [ ! -L "$trust_dir" ] || return 1
  trust_device=$(fm_pr_file_device "$trust_dir") || return 1
  trust="$trust_dir/$id.check-trust"
  fm_pr_private_file_valid "$trust" 600 "$trust_device" || return 1
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
