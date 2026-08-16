#!/usr/bin/env bash
# Detect whether the operational state filesystem can prove the private modes
# required by executable checks and authenticated polling artifacts.
#
# The probe is behavioral and uses a temporary directory inside the supplied
# state directory, so it works for any filesystem rather than one mount path.
# A failed, ambiguous, or non-owner-only mode observation selects data-only
# supervision and never weakens the existing secure artifact validators.

FM_STATE_MODE=
FM_STATE_MODE_PATH=
FM_STATE_MODE_REASON=

fm_state_capability_stat_mode() {
  local path=$1 value
  if [ "$(uname)" = Darwin ]; then
    value=$(stat -f %Lp "$path" 2>/dev/null) || return 1
  else
    value=$(stat -c %a "$path" 2>/dev/null) || return 1
  fi
  case "$value" in
    600|700|666|777) printf '%s\n' "$value" ;;
    *) return 1 ;;
  esac
}

fm_state_capability_link_count() {
  local path=$1 expected=${2:-1} value
  if [ "$(uname)" = Darwin ]; then
    value=$(stat -f %l "$path" 2>/dev/null) || return 1
  else
    value=$(stat -c %h "$path" 2>/dev/null) || return 1
  fi
  case "$value" in
    "$expected") printf '%s\n' "$value" ;;
    *) return 1 ;;
  esac
}

fm_state_mode_detect() {
  local state=$1 probe_dir probe_file dir_mode file_mode
  if [ "$FM_STATE_MODE_PATH" = "$state" ] && [ -n "$FM_STATE_MODE" ]; then
    return 0
  fi
  FM_STATE_MODE_PATH=$state
  FM_STATE_MODE=data-only
  FM_STATE_MODE_REASON='the state filesystem did not prove owner-only modes'

  [ -d "$state" ] && [ ! -L "$state" ] || {
    FM_STATE_MODE_REASON='the state directory is unavailable or unsafe'
    return 0
  }
  probe_dir=$(umask 000; mktemp -d "$state/.fm-state-capability.XXXXXX" 2>/dev/null) || {
    FM_STATE_MODE_REASON='the state filesystem could not create a capability probe'
    return 0
  }
  if [ ! -d "$probe_dir" ] || [ -L "$probe_dir" ]; then
    rmdir "$probe_dir" 2>/dev/null || true
    FM_STATE_MODE_REASON='the capability directory was not an ordinary directory'
    return 0
  fi
  if ! chmod 777 "$probe_dir" 2>/dev/null || ! chmod 700 "$probe_dir" 2>/dev/null; then
    rmdir "$probe_dir" 2>/dev/null || true
    FM_STATE_MODE_REASON='the state filesystem could not enforce directory mode 0700'
    return 0
  fi
  dir_mode=$(fm_state_capability_stat_mode "$probe_dir" 2>/dev/null || true)
  if [ "$dir_mode" != 700 ] || [ "$(fm_state_capability_link_count "$probe_dir" 2 2>/dev/null || true)" != 2 ]; then
    rmdir "$probe_dir" 2>/dev/null || true
    FM_STATE_MODE_REASON='the state filesystem could not report an unambiguous directory mode 0700'
    return 0
  fi

  probe_file="$probe_dir/probe"
  if ! (umask 000; : > "$probe_file") || [ -L "$probe_file" ] \
    || ! chmod 666 "$probe_file" 2>/dev/null \
    || ! chmod 600 "$probe_file" 2>/dev/null; then
    rm -f -- "$probe_file"
    rmdir "$probe_dir" 2>/dev/null || true
    FM_STATE_MODE_REASON='the state filesystem could not enforce file mode 0600'
    return 0
  fi
  file_mode=$(fm_state_capability_stat_mode "$probe_file" 2>/dev/null || true)
  if [ "$file_mode" != 600 ] || [ "$(fm_state_capability_link_count "$probe_file" 2>/dev/null || true)" != 1 ]; then
    rm -f -- "$probe_file"
    rmdir "$probe_dir" 2>/dev/null || true
    FM_STATE_MODE_REASON='the state filesystem could not report an unambiguous file mode 0600'
    return 0
  fi

  rm -f -- "$probe_file"
  rmdir "$probe_dir" 2>/dev/null || true
  if [ -e "$probe_dir" ] || [ -L "$probe_dir" ]; then
    FM_STATE_MODE_REASON='the capability probe could not be cleaned up safely'
    return 0
  fi
  FM_STATE_MODE=secure
  FM_STATE_MODE_REASON='the state filesystem proved owner-only modes by behavior'
}

fm_state_mode_secure() {
  fm_state_mode_detect "$1"
  [ "$FM_STATE_MODE" = secure ]
}

fm_state_mode_data_only() {
  fm_state_mode_detect "$1"
  [ "$FM_STATE_MODE" = data-only ]
}

fm_state_mode_refusal() {
  local state=$1 action=${2:-operation}
  fm_state_mode_detect "$state"
  printf '%s\n' "data-only supervision refuses $action: $FM_STATE_MODE_REASON; use manual PR inspection and explicit pre-merge revalidation"
}

fm_state_data_only_artifacts() {
  local state=$1 path
  for path in \
    "$state"/*.check.sh \
    "$state"/*.check-trust \
    "$state"/*.pr-poll \
    "$state"/*.pr-poll-registration \
    "$state"/*.pr-poll-retirement \
    "$state"/x-watch.check.sh \
    "$state"/.pr-check-quarantine \
    "$state"/.pr-check-migration.log \
    "$state"/.pr-check-migration-v1 \
    "$state"/.pr-check-migration-scan-v1; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      printf '%s\n' "$path"
    fi
  done
}
