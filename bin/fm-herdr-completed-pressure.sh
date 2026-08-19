#!/usr/bin/env bash
# Report a completed-worker resource-pressure episode from durable Herdr task records.
#
# Usage: fm-herdr-completed-pressure.sh
#
# This is the single owner of the completed-worker resource thresholds:
# - less than 2 GiB of measurable available system memory, or
# - more than 10 GiB summed RSS beneath retained completed worker shells.
#
# It prints exactly one captain-facing warning when either measured threshold is
# crossed, prints nothing when pressure is absent or cannot be measured, and
# never cleans up, stops, or otherwise mutates a retained worker.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
AVAILABLE_LIMIT_KIB=$((2 * 1024 * 1024))
WORKER_LIMIT_KIB=$((10 * 1024 * 1024))

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

meta_exact() {  # <meta> <key>
  local meta=$1 key=$2 count
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$meta" | cut -d= -f2-
}

available_memory_kib() {
  local kib page_size pages proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/meminfo" ]; then
    kib=$(awk '/^MemAvailable:/ { print $2; exit }' "$proc_root/meminfo" 2>/dev/null)
    case "$kib" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$kib"
    return 0
  fi
  command -v vm_stat >/dev/null 2>&1 || return 1
  page_size=$(vm_stat 2>/dev/null | awk '/page size of/ { gsub(/[^0-9]/, ""); print; exit }')
  pages=$(vm_stat 2>/dev/null | awk '
    /Pages free/ || /Pages inactive/ || /Pages speculative/ { gsub(/[^0-9]/, "", $NF); sum += $NF }
    END { if (sum > 0) print sum }
  ')
  case "$page_size:$pages" in *[!0-9:]*|:) return 1 ;; esac
  printf '%s' $(( page_size * pages / 1024 ))
}

# Sum the root process and every live descendant reported by ps in one snapshot.
# A completed pane's exact root pid is read from Herdr immediately before this
# snapshot, so no global process-name scan can attribute another worker's RSS.
rss_tree_kib() {  # <root-pid>
  local root=$1 rows
  case "$root" in ''|*[!0-9]*) return 1 ;; esac
  rows=$(ps -axo pid=,ppid=,rss= 2>/dev/null) || return 1
  printf '%s\n' "$rows" | awk -v root="$root" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
      parent[$1] = $2
      rss[$1] = $3
    }
    END {
      for (pid in parent) {
        current = pid
        while (current in parent && current != root) current = parent[current]
        if (current == root) total += rss[pid]
      }
      if (!(root in rss)) exit 1
      print total
    }
  '
}

retained_completed_worker_present() {
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(fm_backend_of_meta "$meta")" = herdr ] || continue
    [ "$(meta_exact "$meta" herdr_presentation 2>/dev/null || true)" = tabs ] || continue
    [ "$(meta_exact "$meta" herdr_tab_completed 2>/dev/null || true)" = 1 ] || continue
    return 0
  done
  return 1
}

completed_worker_rss_kib() {
  local meta session pane info pid rss total=0 found=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(fm_backend_of_meta "$meta")" = herdr ] || continue
    [ "$(meta_exact "$meta" herdr_presentation 2>/dev/null || true)" = tabs ] || continue
    [ "$(meta_exact "$meta" herdr_tab_completed 2>/dev/null || true)" = 1 ] || continue
    session=$(meta_exact "$meta" herdr_session) || continue
    pane=$(meta_exact "$meta" herdr_pane_id) || continue
    info=$(fm_backend_herdr_cli "$session" pane process-info "$pane" 2>/dev/null) || continue
    pid=$(printf '%s' "$info" | jq -r '.result.process_info.shell_pid // empty' 2>/dev/null) || continue
    rss=$(rss_tree_kib "$pid") || continue
    case "$rss" in ''|*[!0-9]*) continue ;; esac
    total=$((total + rss))
    found=1
  done
  [ "$found" = 1 ] || return 1
  printf '%s' "$total"
}

fm_backend_source herdr || exit 1
retained_completed_worker_present || exit 0
available=$(available_memory_kib 2>/dev/null || true)
rss=$(completed_worker_rss_kib 2>/dev/null || true)
if { [ -n "$available" ] && [ "$available" -lt "$AVAILABLE_LIMIT_KIB" ]; } \
   || { [ -n "$rss" ] && [ "$rss" -gt "$WORKER_LIMIT_KIB" ]; }; then
  printf 'Captain, completed workers - resource pressure.\n'
fi
