#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

BRANCH_ROWS="$STATE/.branch-eligible-rows"
BRANCH_OWNER="$STATE/.branch-eligible-owner"
MAIN_ROWS="$STATE/.main-eligible-rows"
TMP=
LOCK_HELD=false

# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  [ "$LOCK_HELD" = false ] || fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

rows_valid() {
  [ -s "$1" ] && awk 'BEGIN { ok=1 } !/^[0-9]+$/ || seen[$0]++ { ok=0 } END { exit !ok }' "$1"
}

owner_matches() {
  local expected_pid=${1:-} expected_generation=${2:-} version pid identity generation current
  [ -f "$BRANCH_OWNER" ] && [ ! -L "$BRANCH_OWNER" ] || return 1
  exec 8< "$BRANCH_OWNER" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r pid <&8 || { exec 8<&-; return 1; }
  IFS= read -r identity <&8 || { exec 8<&-; return 1; }
  IFS= read -r generation <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then exec 8<&-; return 1; fi
  exec 8<&-
  [ "$version" = fm-branch-eligible-owner-v1 ] || return 1
  case "$pid" in ''|*[!0-9]*|1) return 1 ;; esac
  case "$generation" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -z "$expected_pid" ] || [ "$pid" = "$expected_pid" ] || return 1
  [ -z "$expected_generation" ] || [ "$generation" = "$expected_generation" ] || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$current" ] && [ "$current" = "$identity" ]
}

case "${1:-}" in
  activate)
    pid=${2:-}
    generation=${3:-}
    [ "$#" -eq 3 ] || exit 2
    case "$pid" in ''|*[!0-9]*|1) exit 2 ;; esac
    case "$generation" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
    identity=$(fm_pid_identity "$pid" 2>/dev/null) || exit 1
    [ -n "$identity" ] || exit 1
    TMP=$(mktemp "$STATE/.branch-eligible-owner.tmp.XXXXXX") || exit 1
    printf '%s\n%s\n%s\n%s\n' fm-branch-eligible-owner-v1 "$pid" "$identity" "$generation" > "$TMP" || exit 1
    chmod 0600 "$TMP" || exit 1
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    LOCK_HELD=true
    [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "$identity" ] || exit 1
    rm -f -- "$BRANCH_ROWS" || exit 1
    _fm_atomic_replace "$TMP" "$BRANCH_OWNER" || exit 1
    TMP=
    ;;
  publish)
    generation=${2:-}
    [ "$#" -gt 2 ] || exit 2
    case "$generation" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
    shift 2
    TMP=$(mktemp "$STATE/.branch-eligible-rows.tmp.XXXXXX") || exit 1
    printf '%s\n' "$@" > "$TMP" || exit 1
    chmod 0600 "$TMP" || exit 1
    rows_valid "$TMP" || exit 2
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    LOCK_HELD=true
    owner_matches '' "$generation" || exit 1
    replace=1
    if [ -e "$BRANCH_ROWS" ] || [ -L "$BRANCH_ROWS" ]; then
      rows_valid "$BRANCH_ROWS" && cmp -s "$TMP" "$BRANCH_ROWS" || exit 1
      replace=0
    fi
    awk -F '\t' -v requested="$TMP" -v main="$MAIN_ROWS" '
      BEGIN {
        while ((getline line < requested) > 0) wanted[line]=1
        while ((getline line < main) > 0) owned[line]=1
      }
      NF >= 5 && $2 ~ /^[0-9]+$/ && $2 in wanted { present[$2]=1 }
      END {
        for (seq in wanted) if (seq in owned) exit 3
        for (seq in wanted) if (!(seq in present)) exit 1
      }
    ' "$FM_WAKE_QUEUE"
    rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
    if [ "$replace" -eq 1 ]; then
      _fm_atomic_replace "$TMP" "$BRANCH_ROWS" || exit 1
      TMP=
    fi
    ;;
  release)
    generation=${2:-}
    [ "$#" -eq 2 ] || exit 2
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    LOCK_HELD=true
    owner_matches '' "$generation" || exit 1
    rm -f -- "$BRANCH_ROWS" || exit 1
    ;;
  deactivate)
    pid=${2:-}
    generation=${3:-}
    [ "$#" -eq 3 ] || exit 2
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    LOCK_HELD=true
    owner_matches "$pid" "$generation" || exit 1
    rm -f -- "$BRANCH_ROWS" "$BRANCH_OWNER" || exit 1
    ;;
  *)
    echo "usage: fm-wake-grant.sh activate PID GENERATION | publish GENERATION SEQUENCE... | release GENERATION | deactivate PID GENERATION" >&2
    exit 2
    ;;
esac

fm_lock_release "$FM_WAKE_QUEUE_LOCK"
LOCK_HELD=false
exit 0
