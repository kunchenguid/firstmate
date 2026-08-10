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

# The first line bin/fm-await-artifact.sh writes into every check it generates.
# It is the identity two owners agree on: the generator refuses to clobber a
# check that lacks it, and bin/fm-pr-check.sh reports when it replaces one.
FM_AWAIT_ARTIFACT_MARKER='# fm-await-artifact-v1'

fm_await_artifact_check_owned() {
  local state=$1 id=$2 check
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  check="$state/$id.check.sh"
  [ -f "$check" ] && [ ! -L "$check" ] || return 1
  head -n 1 "$check" 2>/dev/null | grep -Fqx -- "$FM_AWAIT_ARTIFACT_MARKER"
}

# An armed artifact wake that has not yet announced its artifact. A record that
# is absent or unreadable counts as pending: the wake is reported as lost rather
# than silently discarded.
fm_await_artifact_wake_pending() {
  local state=$1 id=$2 record version status
  fm_await_artifact_check_owned "$state" "$id" || return 1
  record="$state/.$id.await-artifact"
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  version=
  status=
  { IFS= read -r version && IFS= read -r status; } < "$record" || true
  [ "$version" = fm-await-artifact-v1 ] || return 0
  if [ "$status" = fired ]; then
    return 1
  fi
  return 0
}
