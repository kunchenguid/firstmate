# shellcheck shell=bash
# Read-only startup-result state shared by its producer and supervision.
# Usage: . bin/fm-startup-network-lib.sh
# Completion directories are immutable; status is written last, after report
# and optional timings. Publication and generation reservation share the
# startup publication lock. An inline or clean settlement is generation-bound.
# Queue receipts suppress producer replay, while queued rows remain handling
# obligations until their owning consumer removes them.

fm_startup_generation_valid() {
  case ${1:-} in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

fm_startup_field() { # <record> <key>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  sed -n "s/^$2=//p" "$1" | tail -1
}

fm_startup_result_path() { # <state> <generation>
  local state=$1 generation=$2 root result
  fm_startup_generation_valid "$generation" || return 1
  root="$state/.startup-network-results"
  result="$root/$generation"
  [ -d "$root" ] && [ ! -L "$root" ] \
    && [ -d "$result" ] && [ ! -L "$result" ] \
    && [ -f "$result/report" ] && [ ! -L "$result/report" ] \
    && [ "$(fm_startup_field "$result/status" generation)" = "$generation" ] || return 1
  printf '%s\n' "$result"
}

fm_startup_wake_receipted() { # <state> <generation>
  local root="$1/.startup-network-wake-receipts" receipt="$1/.startup-network-wake-receipts/$2"
  fm_startup_generation_valid "$2" || return 1
  [ -d "$root" ] && [ ! -L "$root" ] && [ -f "$receipt" ] && [ ! -L "$receipt" ] \
    && [ "$(cat "$receipt")" = "$2" ]
}

fm_startup_result_settled() { # <state> <generation>
  local state=$1 generation=$2 result settled
  result=$(fm_startup_result_path "$state" "$generation") || return 1
  if [ -f "$state/.startup-network.delivered" ] && [ ! -L "$state/.startup-network.delivered" ] \
    && [ "$(cat "$state/.startup-network.delivered")" = "$generation" ]; then
    return 0
  fi
  fm_startup_wake_receipted "$state" "$generation" && return 0
  [ -f "$result/settled" ] && [ ! -L "$result/settled" ] || return 1
  settled=$(cat "$result/settled") || return 1
  case "$settled" in
    "clean:$generation"|"inline:$generation") return 0 ;;
  esac
  return 1
}

# Bootstrap owns the explicit no-action transport record. Unknown nonempty
# output and failed runs require delivery; this layer does not classify causes.
fm_startup_report_requires_wake() { # <report> <state>
  [ "$2" = 'done' ] || return 0
  [ -s "$1" ] || return 1
  awk 'NF && $0 !~ /^BOOTSTRAP_INFO:/ { found=1; exit } END { exit !found }' "$1"
}

# The worker's existing aggregate age allowance also bounds running-only
# supervision. PID liveness alone can refer to an unrelated reused process.
fm_startup_stage_budget() {
  local budget=${FM_STARTUP_NETWORK_TIMEOUT:-120}
  case "$budget" in ''|*[!0-9]*|0) budget=120 ;; esac
  printf '%s' "$budget"
}

fm_startup_worker_alive() { # <state>
  local record="$1/.startup-network.status" pid started age
  pid=$(fm_startup_field "$record" pid) || return 1
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  started=$(fm_startup_field "$record" started) || return 1
  case "$started" in ''|*[!0-9]*) return 0 ;; esac
  age=$(( $(date +%s) - started ))
  case "$age" in ''|*[!0-9]*) return 0 ;; esac
  [ "$age" -le "$(( $(fm_startup_stage_budget) + 30 ))" ]
}

fm_startup_supervision_pending() { # <state>
  local state=$1 generation result
  if [ -f "$state/.wake-queue" ] && [ ! -L "$state/.wake-queue" ] \
    && awk -F '\t' 'NF == 5 && $2 ~ /^[0-9]+$/ && $3 == "check" \
      && $4 ~ /^startup-network(:[A-Za-z0-9._-]+)?$/ { found=1; exit } END { exit !found }' \
      "$state/.wake-queue"; then
    return 0
  fi
  generation=$(fm_startup_field "$state/.startup-network.status" generation) || return 1
  fm_startup_generation_valid "$generation" || return 1
  if result=$(fm_startup_result_path "$state" "$generation"); then
    ! fm_startup_result_settled "$state" "$generation"
    return $?
  fi
  [ "$(fm_startup_field "$state/.startup-network.status" state)" = running ] || return 1
  fm_startup_worker_alive "$state"
}
