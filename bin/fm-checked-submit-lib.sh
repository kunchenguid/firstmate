#!/usr/bin/env bash

fm_checked_submit_namespace_mode() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

fm_checked_submit_namespace_uid() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%u' "$1" 2>/dev/null
  else
    stat -c '%u' "$1" 2>/dev/null
  fi
}

fm_checked_submit_namespace() {
  local uid dir owner mode
  uid=$(id -u 2>/dev/null) || return 1
  dir="/tmp/firstmate-send-$uid"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    mkdir -m 700 "$dir" 2>/dev/null || true
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  owner=$(fm_checked_submit_namespace_uid "$dir") || return 1
  mode=$(fm_checked_submit_namespace_mode "$dir") || return 1
  [ "$owner" = "$uid" ] && [ "$mode" = 700 ] || return 1
  printf '%s' "$dir"
}

fm_checked_submit_identity_lock_path() {
  local identity=$1 sum size namespace
  read -r sum size _ <<EOF
$(printf '%s' "$identity" | cksum)
EOF
  namespace=$(fm_checked_submit_namespace) || return 1
  printf '%s/endpoint-%s-%s.lock' "$namespace" "$sum" "$size"
}

fm_checked_submit_lock_path() {
  local identity
  identity=$(fm_backend_endpoint_identity "$1" "$2" "${3:-}") || return 1
  fm_checked_submit_identity_lock_path "$identity"
}

fm_backend_endpoint_lock_acquire() {
  local backend=$1 target=$2 expected_label=${3:-} identity confirmed attempt=0
  while [ "$attempt" -lt 10 ]; do
    identity=$(fm_backend_endpoint_identity "$backend" "$target" "$expected_label") || return 2
    FM_BACKEND_ENDPOINT_LOCK=$(fm_checked_submit_identity_lock_path "$identity") || return 2
    fm_lock_acquire_wait "$FM_BACKEND_ENDPOINT_LOCK" || return 2
    confirmed=$(fm_backend_endpoint_identity "$backend" "$target" "$expected_label") || {
      fm_backend_endpoint_lock_release
      return 2
    }
    if [ "$confirmed" = "$identity" ]; then
      FM_BACKEND_ENDPOINT_TARGET=$target
      return 0
    fi
    fm_backend_endpoint_lock_release
    attempt=$((attempt + 1))
  done
  return 2
}

fm_backend_endpoint_lock_release() {
  fm_lock_release "$FM_BACKEND_ENDPOINT_LOCK"
  FM_BACKEND_ENDPOINT_LOCK=
  FM_BACKEND_ENDPOINT_TARGET=
}

fm_backend_serialized_send_key() {
  local backend=$1 target=$2 expected_label=${4:-} rc=0
  fm_backend_endpoint_lock_acquire "$backend" "$target" "$expected_label" || return 2
  fm_backend_send_key_unlocked "$backend" "$FM_BACKEND_ENDPOINT_TARGET" "$3" "$expected_label" || rc=$?
  fm_backend_endpoint_lock_release
  return "$rc"
}

fm_backend_serialized_send_text_submit() {
  local backend=$1 target=$2 expected_label=${7:-} verdict rc=0
  fm_backend_endpoint_lock_acquire "$backend" "$target" "$expected_label" || return 2
  verdict=$(fm_backend_send_text_submit_unlocked "$backend" "$FM_BACKEND_ENDPOINT_TARGET" "$3" "$4" "$5" "$6" "$expected_label") || rc=$?
  printf '%s' "${verdict:-send-failed}"
  fm_backend_endpoint_lock_release
  return "$rc"
}

fm_backend_checked_send_text_submit() {
  local backend=$1 target=$2 text=$3 retries=$4 enter_sleep=$5 settle=$6 expected_label=${7:-}
  local composer verdict rc=0
  fm_backend_endpoint_lock_acquire "$backend" "$target" "$expected_label" || return 2
  target=$FM_BACKEND_ENDPOINT_TARGET
  if ! composer=$(fm_backend_composer_state "$backend" "$target" "$expected_label"); then
    composer=unknown
  fi
  if [ "$composer" != empty ]; then
    printf '%s' "composer-$composer"
    fm_backend_endpoint_lock_release
    return 0
  fi
  verdict=$(fm_backend_send_text_submit_unlocked "$backend" "$target" "$text" "$retries" "$enter_sleep" "$settle" "$expected_label") || rc=$?
  printf '%s' "${verdict:-send-failed}"
  fm_backend_endpoint_lock_release
  return "$rc"
}
