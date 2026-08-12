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

fm_backend_checked_send_text_submit() {
  local backend=$1 target=$2 text=$3 retries=$4 enter_sleep=$5 settle=$6 expected_label=${7:-}
  local identity sum size namespace lock composer verdict rc=0
  identity="$backend"$'\t'"$target"
  read -r sum size _ <<EOF
$(printf '%s' "$identity" | cksum)
EOF
  namespace=$(fm_checked_submit_namespace) || return 2
  lock="$namespace/endpoint-$sum-$size.lock"
  fm_lock_acquire_wait "$lock" || return 2
  if ! composer=$(fm_backend_composer_state "$backend" "$target" "$expected_label"); then
    composer=unknown
  fi
  if [ "$composer" != empty ]; then
    printf '%s' "composer-$composer"
    fm_lock_release "$lock"
    return 0
  fi
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$text" "$retries" "$enter_sleep" "$settle" "$expected_label") || rc=$?
  printf '%s' "${verdict:-send-failed}"
  fm_lock_release "$lock"
  return "$rc"
}
