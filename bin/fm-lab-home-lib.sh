#!/usr/bin/env bash
# Disposable lab-home marker helpers shared by lab creation and trust validation.
FM_LAB_MARKER='.fm-lab-home'
FM_LAB_TOKEN='fm-lab-home v1'

# fm_lab_home <dir>: return 0 when <dir> is a marked disposable lab home.
fm_lab_home() {
  local home=${1:-}
  [ -n "$home" ] || return 1
  [ -f "$home/$FM_LAB_MARKER" ] || return 1
  [ "$(sed -n '1p' "$home/$FM_LAB_MARKER" 2>/dev/null || true)" = "$FM_LAB_TOKEN" ]
}

# fm_lab_mark <dir>: stamp <dir> as a disposable lab home. Fails closed on
# any dir that is not empty, so this can never mark a populated real home.
fm_lab_mark() {
  local home=${1:-} listing
  [ -n "$home" ] && [ -d "$home" ] || return 1
  listing=$(find "$home" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) || return 1
  [ -z "$listing" ] || return 1
  printf '%s\n' "$FM_LAB_TOKEN" > "$home/$FM_LAB_MARKER"
}
