#!/usr/bin/env bash
# fm-batten-down.sh - batten down the hatches before the night watch: can this
# machine survive an unattended away window? The /afk entry
# (bin/fm-afk-launch.sh enter) runs it before writing an away record and
# refuses entry when any check fails, unless the captain asks to enter anyway
# (--skip-batten-down; docs/configuration.md "Batten down before away mode").
#
# Checks, each one line, each naming the fix when it fails:
#   disk     free space on the volume holding FM_HOME, at least 10% of the
#            volume and never under 20 GB, or min_free_gb when set
#   load     the 1-minute load average, at most max_load
#   swap     swap in use, at most max_swap_gb
#   midway   opt-in (midway=on): the Midway session cookie outlives
#            min_midway_hours, read from the cookie file's expiry and never by
#            running mwinit
#   watcher  a fresh watcher beacon (state/.last-watcher-beat) while the home
#            needs supervision (bin/fm-supervision-lib.sh owns that predicate);
#            the grace is fm_poll_derived_grace unless FM_GUARD_GRACE is set
#
# It then lists the largest reclaimable build caches it finds and deletes
# nothing: /private/tmp (or /tmp) *-dd and bzl-* directories idle 3h+ and Bazel
# output bases idle 2 days+. Sizing runs one du over every candidate under a
# time budget, so the whole check stays a few seconds even under heavy load and
# never forks per file; a du that overruns is stopped and the candidates are
# listed unsized.
#
# Config: config/batten-down, one key=value per line, # comments allowed.
#   min_free_gb=<GB, replaces the relative default>
#   max_load=<8 x logical CPUs>  max_swap_gb=40
#   midway=off|on  min_midway_hours=10  midway_cookie=~/.midway/cookie
# Each key has an FM_BATTEN_DOWN_<KEY> environment override, and
# FM_BATTEN_DOWN=off skips the whole check for one run. An invalid value
# fails its check rather than being guessed.
#
# Usage: fm-batten-down.sh
#   Prints the report on stdout. Exit 0 when every check passes, 1 when any
#   fails, 2 on a usage error.
#
# Test seams (only with FM_TEST_SEAM=1): FM_BATTEN_DOWN_TEST_FREE_KB,
# FM_BATTEN_DOWN_TEST_TOTAL_KB, FM_BATTEN_DOWN_TEST_LOAD, FM_BATTEN_DOWN_TEST_SWAP_MB, and
# FM_BATTEN_DOWN_TMP_ROOT replace the machine readings and the temp root.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^# Test seams/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

if [ "${FM_BATTEN_DOWN:-}" = off ]; then
  printf 'batten-down check: skipped (FM_BATTEN_DOWN=off)\n'
  exit 0
fi

seam() {  # <name> -> value of a test seam, only under FM_TEST_SEAM=1
  [ "${FM_TEST_SEAM:-}" = 1 ] || return 1
  eval "[ -n \"\${$1:-}\" ] && printf '%s' \"\${$1}\""
}

# Config file values, overridden by FM_BATTEN_DOWN_<KEY>.
CFG_FILE="$CONFIG/batten-down"
cfg() {  # <key> <default>
  local key=$1 def=$2 env line k v
  env=FM_BATTEN_DOWN_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
  if eval "[ -n \"\${$env:-}\" ]"; then
    eval "printf '%s' \"\${$env}\""
    return
  fi
  v=$def
  if [ -f "$CFG_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      k=${line%%=*}
      [ "$k" = "$key" ] || continue
      v=${line#*=}
    done < "$CFG_FILE"
  fi
  printf '%s' "$v"
}

is_number() { case "$1" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; *) return 0 ;; esac; }

FAILED=0
REPORT=
ok() { REPORT="$REPORT  ok    $1"$'\n'; }
bad() { REPORT="$REPORT  FAIL  $1"$'\n'; FAILED=1; }

# --- disk ---------------------------------------------------------------------
check_disk() {
  local min free_kb total_kb mount line
  min=$(cfg min_free_gb '')
  [ -z "$min" ] || is_number "$min" || { bad "disk: min_free_gb '$min' is not a number; fix $CFG_FILE"; return; }
  mount=$FM_HOME
  if free_kb=$(seam FM_BATTEN_DOWN_TEST_FREE_KB); then
    total_kb=$(seam FM_BATTEN_DOWN_TEST_TOTAL_KB) || total_kb=$((1000 * 1048576))
  else
    line=$(df -Pk "$FM_HOME" 2>/dev/null | tail -n 1)
    # shellcheck disable=SC2086 # field split of df's one data row
    set -- $line
    total_kb=${2:-}
    free_kb=${4:-}
    mount=${6:-$FM_HOME}
  fi
  case "$free_kb" in ''|*[!0-9]*) bad "disk: could not read free space for $FM_HOME"; return ;; esac
  if [ -z "$min" ]; then
    case "$total_kb" in ''|*[!0-9]*) bad "disk: could not read the size of $mount"; return ;; esac
    min=$(awk -v t="$total_kb" 'BEGIN { m = t / 1048576 / 10; if (m < 20) m = 20; printf "%.1f", m }')
  fi
  if awk -v f="$free_kb" -v m="$min" 'BEGIN { exit !(f / 1048576 >= m) }'; then
    ok "disk: $(awk -v f="$free_kb" 'BEGIN { printf "%.1f", f / 1048576 }') GB free on $mount (minimum $min GB)"
  else
    bad "disk: $(awk -v f="$free_kb" 'BEGIN { printf "%.1f", f / 1048576 }') GB free on $mount (minimum $min GB); free space from the caches listed below"
  fi
}

# --- load ---------------------------------------------------------------------
check_load() {
  local max ncpu load raw
  ncpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
  case "$ncpu" in ''|*[!0-9]*) ncpu=1 ;; esac
  max=$(cfg max_load $((ncpu * 8)))
  is_number "$max" || { bad "load: max_load '$max' is not a number; fix $CFG_FILE"; return; }
  if load=$(seam FM_BATTEN_DOWN_TEST_LOAD); then
    :
  elif [ -r /proc/loadavg ]; then
    read -r load _ < /proc/loadavg
  else
    raw=$(sysctl -n vm.loadavg 2>/dev/null)
    # shellcheck disable=SC2086 # "{ 1.23 4.56 7.89 }"
    set -- $raw
    load=${2:-}
  fi
  is_number "$load" || { bad "load: could not read the 1-minute load average"; return; }
  if awk -v l="$load" -v m="$max" 'BEGIN { exit !(l <= m) }'; then
    ok "load: 1-minute load $load (maximum $max)"
  else
    bad "load: 1-minute load $load (maximum $max); let running builds finish or stop lanes before leaving"
  fi
}

# --- swap ---------------------------------------------------------------------
check_swap() {
  local max used_mb raw key val total=0 free=0
  max=$(cfg max_swap_gb 40)
  is_number "$max" || { bad "swap: max_swap_gb '$max' is not a number; fix $CFG_FILE"; return; }
  if used_mb=$(seam FM_BATTEN_DOWN_TEST_SWAP_MB); then
    :
  elif [ -r /proc/meminfo ]; then
    while read -r key val _; do
      case "$key" in
        SwapTotal:) total=$val ;;
        SwapFree:) free=$val ;;
      esac
    done < /proc/meminfo
    used_mb=$(( (total - free) / 1024 ))
  else
    # "total = 21504.00M  used = 19796.38M  free = 1707.62M  (encrypted)"
    raw=$(sysctl -n vm.swapusage 2>/dev/null)
    used_mb=$(printf '%s' "$raw" | awk '{
      for (i = 1; i < NF; i++) if ($i == "used") { v = $(i + 2); break }
      u = substr(v, length(v)); n = v + 0
      if (u == "G") n *= 1024; else if (u == "K") n /= 1024
      printf "%d", n }')
  fi
  is_number "$used_mb" || { bad "swap: could not read swap usage"; return; }
  if awk -v u="$used_mb" -v m="$max" 'BEGIN { exit !(u / 1024 <= m) }'; then
    ok "swap: $(awk -v u="$used_mb" 'BEGIN { printf "%.1f", u / 1024 }') GB in use (maximum $max GB)"
  else
    bad "swap: $(awk -v u="$used_mb" 'BEGIN { printf "%.1f", u / 1024 }') GB in use (maximum $max GB); only a reboot reclaims swap"
  fi
}

# --- midway -------------------------------------------------------------------
check_midway() {
  local mode min cookie expiry now left
  mode=$(cfg midway off)
  [ "$mode" = on ] || return 0
  min=$(cfg min_midway_hours 10)
  is_number "$min" || { bad "midway: min_midway_hours '$min' is not a number; fix $CFG_FILE"; return; }
  cookie=$(cfg midway_cookie "$HOME/.midway/cookie")
  case $cookie in \~/*) cookie=$HOME/${cookie#??} ;; esac
  if [ ! -f "$cookie" ]; then
    bad "midway: no session cookie at $cookie; run mwinit, then /afk again"
    return
  fi
  expiry=$(awk -F '\t' '$6 == "session" && $1 ~ /midway-auth\.amazon\.com$/ && $5 + 0 > m { m = $5 + 0 } END { printf "%d", m }' "$cookie" 2>/dev/null)
  case "$expiry" in ''|0|*[!0-9]*) bad "midway: no session in $cookie; run mwinit, then /afk again"; return ;; esac
  fm_epoch_seconds_to now
  left=$((expiry - now))
  if [ "$left" -le 0 ]; then
    bad "midway: the session expired at $(date -u -r "$expiry" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$expiry" +%Y-%m-%dT%H:%MZ); run mwinit, then /afk again"
  elif awk -v l="$left" -v m="$min" 'BEGIN { exit !(l / 3600 >= m) }'; then
    ok "midway: session lasts $(awk -v l="$left" 'BEGIN { printf "%.1f", l / 3600 }') h (minimum $min h)"
  else
    bad "midway: session lasts only $(awk -v l="$left" 'BEGIN { printf "%.1f", l / 3600 }') h (minimum $min h); run mwinit, then /afk again"
  fi
}

# --- watcher ------------------------------------------------------------------
check_watcher() {
  local grace
  grace=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
  fm_supervision_status "$STATE" "$grace"
  if [ "$FM_SUP_NEEDED" != true ]; then
    ok "watcher: not needed (no work under way)"
  elif [ "$FM_SUP_WATCHER_FRESH" = true ]; then
    ok "watcher: beacon $FM_SUP_BEACON_DESC (grace ${grace}s)"
  else
    bad "watcher: beacon $FM_SUP_BEACON_DESC (grace ${grace}s) while work is under way; restore supervision before leaving"
  fi
}

# --- reclaimable caches -------------------------------------------------------
CANDIDATES=()
HINTS=()
add_candidate() {  # <path> <hint>
  CANDIDATES+=("$1")
  HINTS+=("$2")
}

collect_caches() {
  local tmp d hash idle bazel base
  tmp=$(seam FM_BATTEN_DOWN_TMP_ROOT) || { tmp=/private/tmp; [ -d "$tmp" ] || tmp=/tmp; }
  idle=()
  for d in "$tmp"/*-dd "$tmp"/bzl-*; do
    [ -d "$d" ] && idle+=("$d")
  done
  if [ "${#idle[@]}" -gt 0 ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && add_candidate "$d" "build dir idle 3h+; delete it"
    done < <(find "${idle[@]}" -maxdepth 0 -type d -mmin +180 -print 2>/dev/null)
  fi
  for base in "$HOME/Library/Caches/bazel/_bazel_${USER:-$(id -un)}" "$HOME/.cache/bazel/_bazel_${USER:-$(id -un)}"; do
    [ -d "$base" ] || continue
    bazel=()
    for d in "$base"/*; do
      hash=${d##*/}
      [ "${#hash}" -eq 32 ] && [ -d "$d" ] && bazel+=("$d")
    done
    [ "${#bazel[@]}" -gt 0 ] || continue
    while IFS= read -r d; do
      [ -n "$d" ] && add_candidate "$d" "Bazel output base idle 2 days+; chmod -R u+w, then delete"
    done < <(find "${bazel[@]}" -maxdepth 0 -type d -mtime +1 -print 2>/dev/null)
  done
}

# One du over every candidate, bounded by fm_run_timed at
# FM_BATTEN_DOWN_SIZE_SECS (default 2) so a huge tree cannot stall the check.
# Prints "<kb>\t<path>" lines, or fails on overrun.
size_candidates() {
  local budget
  budget=${FM_BATTEN_DOWN_SIZE_SECS:-2}
  case "$budget" in ''|0|*[!0-9]*) budget=2 ;; esac
  fm_run_timed "$budget" du -sk "${CANDIDATES[@]}" 2>/dev/null
  ! fm_timed_out $?
}

report_caches() {
  local sizes i line kb path hint
  collect_caches
  if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    printf 'reclaimable build caches: none found\n'
    return
  fi
  printf 'reclaimable build caches (largest first; nothing was deleted):\n'
  if sizes=$(size_candidates); then
    printf '%s\n' "$sizes" | sort -rn | head -n 8 | while IFS=$'\t' read -r kb path; do
      [ -n "$path" ] || continue
      hint=
      for i in "${!CANDIDATES[@]}"; do
        [ "${CANDIDATES[$i]}" = "$path" ] && hint=${HINTS[$i]}
      done
      printf '  %6s GB  %s  (%s)\n' "$(awk -v k="$kb" 'BEGIN { printf "%.1f", k / 1048576 }')" "$path" "$hint"
    done
  else
    printf '  sizing took too long; candidates unsized:\n'
    for i in "${!CANDIDATES[@]}"; do
      line="${CANDIDATES[$i]}  (${HINTS[$i]})"
      printf '    %s\n' "$line"
    done
  fi
}

check_disk
check_load
check_swap
check_midway
check_watcher

if [ "$FAILED" -eq 0 ]; then
  printf 'batten-down check: shipshape for the night\n'
else
  printf 'batten-down check: FAILED - this machine may not survive the away window\n'
fi
printf '%s' "$REPORT"
report_caches
if [ "$FAILED" -ne 0 ]; then
  printf 'Fix the failed checks and run /afk again, or enter anyway with bin/fm-afk-launch.sh enter --skip-batten-down.\n'
fi
exit "$FAILED"
