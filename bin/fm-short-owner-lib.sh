#!/usr/bin/env bash
# Guarded scripts call enter before any effects, check again at each effect,
# and receipt only after their own authoritative postcondition readback.
# This is a model-tool/owner boundary, not isolation from arbitrary same-uid code.
# Main/branch honor pending operation barriers; only a bound child descendant
# of the current immutable task can act as short. No actor-string-only grant.
FM_SHORT_OWNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_SHORT_OWNER_ACTION=
FM_SHORT_OWNER_ARGS=()
FM_SHORT_OWNER_LOCK=
FM_SHORT_OWNER_MARKER=
FM_SHORT_OWNER_MARKERS=()
FM_SHORT_OWNER_LOCKS=()
fm_short_owner_release() {
  local lock
  for lock in "${FM_SHORT_OWNER_LOCKS[@]+"${FM_SHORT_OWNER_LOCKS[@]}"}"; do
    fm_lock_release "$lock"
  done
  FM_SHORT_OWNER_LOCKS=()
  FM_SHORT_OWNER_LOCK=
}
fm_short_owner_check() {
  if [ "${FM_SUPERVISION_ACTOR:-}" = short ]; then
    node "$FM_SHORT_OWNER_LIB_DIR/fm-short-operations.mjs" verify "$FM_SHORT_OWNER_ACTION" "${FM_SHORT_OWNER_ARGS[@]}"
  else
    local marker
    for marker in "${FM_SHORT_OWNER_MARKERS[@]}"; do
      if [ -e "$marker" ]; then
        echo "error: resource reserved by a short operation; reconcile its receipt first" >&2
        return 1
      fi
    done
  fi
}
fm_short_owner_enter() {
  FM_SHORT_OWNER_ACTION=$1
  shift
  FM_SHORT_OWNER_ARGS=("$@")
  local directory common
  case "$FM_SHORT_OWNER_ACTION" in
    sync)
      common=$(git -C "$1" rev-parse --git-common-dir) || return 1
      case "$common" in /*) directory=$common ;; *) directory="$1/$common" ;; esac
      directory=$(cd "$directory" && pwd -P) || return 1
      FM_SHORT_OWNER_MARKER="$directory/fm-short-operation.json"
      ;;
    install-shellcheck)
      directory=$(cd "$1" && pwd -P) || return 1
      FM_SHORT_OWNER_MARKER="$directory/.fm-short-shellcheck.json"
      ;;
    merge|cleanup)
      directory=$(cd "${STATE:-$FM_HOME/state}" && pwd -P) || return 1
      FM_SHORT_OWNER_MARKER="$directory/.short-operation-$1.json"
      ;;
    *) return 1 ;;
  esac
  FM_SHORT_OWNER_MARKERS=("$FM_SHORT_OWNER_MARKER")
  if [ "$FM_SHORT_OWNER_ACTION" = merge ]; then
    local hash
    if command -v sha256sum >/dev/null 2>&1; then
      hash=$(printf '%s' "$2" | sha256sum | awk '{print $1}')
    else
      hash=$(printf '%s' "$2" | shasum -a 256 | awk '{print $1}')
    fi
    FM_SHORT_OWNER_MARKERS=("$directory/.short-merge-$hash.json" "$FM_SHORT_OWNER_MARKER")
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_SHORT_OWNER_LIB_DIR/fm-wake-lib.sh"
  fm_short_owner_release
  local marker
  for marker in "${FM_SHORT_OWNER_MARKERS[@]}"; do
    [ -d "${marker%/*}" ] || return 1
    FM_SHORT_OWNER_LOCK="$marker.lock"
    fm_lock_acquire_wait_bounded "$FM_SHORT_OWNER_LOCK" 5 || return 1
    FM_SHORT_OWNER_LOCKS+=("$FM_SHORT_OWNER_LOCK")
  done
  fm_short_owner_check
}
fm_short_owner_receipt() {
  [ "${FM_SUPERVISION_ACTOR:-}" = short ] || return 0
  node "$FM_SHORT_OWNER_LIB_DIR/fm-short-operations.mjs" receipt "$FM_SHORT_OWNER_ACTION" "${FM_SHORT_OWNER_ARGS[@]}" "$1"
}

fm_short_owner_effect() {
  fm_short_owner_check || return 1
  [ "${FM_SUPERVISION_ACTOR:-}" = short ] || return 0
  node "$FM_SHORT_OWNER_LIB_DIR/fm-short-operations.mjs" effect "$FM_SHORT_OWNER_ACTION" "${FM_SHORT_OWNER_ARGS[@]}"
}
