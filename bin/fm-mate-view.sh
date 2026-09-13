#!/usr/bin/env bash
# Observe registered second mates across local and remote hosts.
#
# Usage:
#   fm-mate-view.sh [<secondmate-id>...]
#
# By default, inspects every registered second mate from data/secondmates.md.
# Remote records execute bin/fm-host-report.sh on the target host via fm-on.sh.
# Local records execute bin/fm-host-report.sh against FM_HOME=<that home>.
#
# Runs mates in parallel with a bounded per-mate timeout.
# An unreachable host prints one clear line with the ssh exit and does not fail
# the others.
# If the remote copy lacks fm-host-report.sh, prints
# 'remote copy lacks fm-host-report.sh; update that host' instead of a raw error.
# If an existing read-only path captures the second mate's terminal screen
# (fm-remote-secondmate-control.sh capture for remote, backend capture for local),
# includes its last ~20 lines; otherwise omits the screen.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"

FM_ON_BIN="${FM_ON_OVERRIDE:-$SCRIPT_DIR/fm-on.sh}"
MATE_TIMEOUT=${FM_MATE_VIEW_TIMEOUT:-20}
CAPTURE_TIMEOUT=${FM_MATE_VIEW_CAPTURE_TIMEOUT:-5}

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

case "${1:-}" in
  -h|--help) usage ;;
esac

[ -f "$REG" ] || { echo "no secondmate registry at $REG"; exit 0; }

# Parse all records from data/secondmates.md
declare -a ALL_IDS=()
declare -a ALL_REMOTES=()
declare -a ALL_HOSTS=()
declare -a ALL_HOMES=()

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '- '*) ;; *) continue ;; esac
  secondmate_registry_parse_line "$line" || continue
  ALL_IDS+=("$SECONDMATE_REGISTRY_ID")
  ALL_REMOTES+=("$SECONDMATE_REGISTRY_REMOTE")
  ALL_HOSTS+=("$SECONDMATE_REGISTRY_HOST")
  ALL_HOMES+=("$SECONDMATE_REGISTRY_HOME")
done < "$REG"

if [ "${#ALL_IDS[@]}" -eq 0 ]; then
  echo "no registered secondmates in $REG"
  exit 0
fi

# Filter by positional arguments if provided
declare -a TARGET_IDS=()
declare -a TARGET_REMOTES=()
declare -a TARGET_HOSTS=()
declare -a TARGET_HOMES=()

if [ "$#" -gt 0 ]; then
  for arg in "$@"; do
    found=0
    for i in "${!ALL_IDS[@]}"; do
      if [ "${ALL_IDS[$i]}" = "$arg" ]; then
        TARGET_IDS+=("${ALL_IDS[$i]}")
        TARGET_REMOTES+=("${ALL_REMOTES[$i]}")
        TARGET_HOSTS+=("${ALL_HOSTS[$i]}")
        TARGET_HOMES+=("${ALL_HOMES[$i]}")
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      echo "error: no registered secondmate matches '$arg'" >&2
      exit 1
    fi
  done
else
  TARGET_IDS=("${ALL_IDS[@]}")
  TARGET_REMOTES=("${ALL_REMOTES[@]}")
  TARGET_HOSTS=("${ALL_HOSTS[@]}")
  TARGET_HOMES=("${ALL_HOMES[@]}")
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-mate-view.XXXXXX")
# shellcheck disable=SC2329 # Invoked through the EXIT trap below.
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

# Worker function to inspect one secondmate
inspect_secondmate() {
  local id=$1 remote=$2 host=$3 home=$4
  local out_file="$TMP/$id.out"
  local err_file="$TMP/$id.err"
  local rc=0

  {
    if [ "$remote" -eq 1 ]; then
      printf '=== Secondmate: %s (remote: %s) ===\n' "$id" "$host"
    else
      printf '=== Secondmate: %s (local: %s) ===\n' "$id" "$home"
    fi

    # 1. Fetch host report
    if [ "$remote" -eq 1 ]; then
      if fm_run_timed "$MATE_TIMEOUT" "$FM_ON_BIN" "$id" fm-host-report.sh > "$out_file" 2> "$err_file"; then
        cat "$out_file"
      else
        rc=$?
        local err_text
        err_text=$(cat "$err_file" 2>/dev/null || true)
        if [ "$rc" -eq 124 ]; then
          printf '%s: unreachable (timed out after %ss)\n' "$host" "$MATE_TIMEOUT"
        elif printf '%s\n' "$err_text" | grep -qE "not a genuine executable in the configured remote root: fm-host-report\.sh|not tracked by the configured remote root: fm-host-report\.sh|command not found: fm-host-report\.sh|fm-host-report\.sh: No such file"; then
          printf 'remote copy lacks fm-host-report.sh; update that host\n'
        elif [ "$rc" -eq 255 ]; then
          printf '%s: unreachable (ssh exit 255)\n' "$host"
        else
          local first_err
          first_err=$(printf '%s\n' "$err_text" | head -1)
          if [ -n "$first_err" ]; then
            printf '%s: error (exit %s): %s\n' "$host" "$rc" "$first_err"
          else
            printf '%s: unreachable (ssh exit %s)\n' "$host" "$rc"
          fi
        fi
      fi
    else
      if FM_HOME="$home" fm_run_timed "$MATE_TIMEOUT" "$SCRIPT_DIR/fm-host-report.sh" > "$out_file" 2> "$err_file"; then
        cat "$out_file"
      else
        rc=$?
        printf 'local home %s: report failed (exit %s)\n' "$home" "$rc"
      fi
    fi

    # 2. Terminal screen capture (last 20 lines) if read-only capture exists
    local screen=""
    if [ "$remote" -eq 1 ]; then
      screen=$(fm_run_timed "$CAPTURE_TIMEOUT" "$FM_ON_BIN" "$id" fm-remote-secondmate-control.sh capture "$id" 20 2>/dev/null || true)
    else
      local target backend expected_label
      target=$(fm_backend_resolve_selector "$id" "$STATE" 2>/dev/null || true)
      if [ -n "$target" ]; then
        backend=$(fm_backend_of_selector "$id" "$target" "$STATE" 2>/dev/null || true)
        expected_label=$(fm_backend_expected_label_of_selector "$id" "$STATE" 2>/dev/null || true)
        if [ -n "$backend" ]; then
          screen=$(fm_backend_capture "$backend" "$target" 20 "$expected_label" 2>/dev/null || true)
        fi
      fi
    fi

    if [ -n "$screen" ]; then
      printf '\n## Terminal Screen (last 20 lines)\n%s\n' "$screen"
    fi
    printf '\n'
  } > "$TMP/$id.final"
}

# Run all mates concurrently in parallel
for i in "${!TARGET_IDS[@]}"; do
  inspect_secondmate "${TARGET_IDS[$i]}" "${TARGET_REMOTES[$i]}" "${TARGET_HOSTS[$i]}" "${TARGET_HOMES[$i]}" &
done
wait

# Output results in deterministic target order
for id in "${TARGET_IDS[@]}"; do
  if [ -f "$TMP/$id.final" ]; then
    cat "$TMP/$id.final"
  fi
done
exit 0
