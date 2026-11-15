#!/usr/bin/env bash
# ak47/lib/common.sh - shared paths, sampling and logging for the ak47 hygiene system.
#
# Sourced, never executed. Every ak47 script sources this first so the state
# directory, the budget table and the log formats have exactly one owner.
#
# Layout (all overridable for tests; the units set none of them):
#   AK47_STATE   default ~/.local/state/ak47
#   AK47_CACHE   default ~/.cache/ak47
#   AK47_CONFIG  default ~/.config/ak47
#   AK47_ROOT    default the ak47/ directory this file lives in
#   FM_HOME      default ~/Projects/firstmate (for state/<id>.meta and bin/)
#
# Files owned here:
#   $AK47_STATE/status.md      the one-screen budget board (status.sh)
#   $AK47_STATE/devops.log     one line per tick, always (tick.sh)
#   $AK47_STATE/reap.log       one line per action, with its revert (tick.sh)
#   $AK47_STATE/findings.log   one line per finding the table cannot settle
#   $AK47_STATE/sample.cache   cached slow samples (du of /tmp) with a TTL
#   $AK47_STATE/inuse.set      the tick's one /proc pass; trust it only when
#                              its last line is `ak47-inuse-complete`
#   $AK47_STATE/quarantine/    moved-not-deleted scratch, dated by move day
#   $AK47_CONFIG/devops.conf   operator arming switches (absent = safe defaults)
set -u

AK47_ROOT=${AK47_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
AK47_STATE=${AK47_STATE:-$HOME/.local/state/ak47}
AK47_CACHE=${AK47_CACHE:-$HOME/.cache/ak47}
AK47_CONFIG=${AK47_CONFIG:-$HOME/.config/ak47}
FM_HOME=${FM_HOME:-$HOME/Projects/firstmate}
AK47_BUDGET=${AK47_BUDGET:-$AK47_ROOT/budget.conf}
AK47_PRODUCERS=${AK47_PRODUCERS:-$AK47_ROOT/census-producers.conf}
AK47_SWAPOFF_BUDGET=${AK47_SWAPOFF_BUDGET:-1800}

mkdir -p "$AK47_STATE" "$AK47_CACHE" "$AK47_CONFIG" 2>/dev/null || true

# ak47_now - one timestamp format everywhere, UTC, sortable.
ak47_now() { date -u +%FT%TZ; }

# ak47_epoch - seconds since the epoch.
ak47_epoch() { date -u +%s; }

# ak47_log <file> <line> - append one line, never fail the caller.
ak47_log() {
  local f=$1; shift
  printf '%s %s\n' "$(ak47_now)" "$*" >>"$f" 2>/dev/null || true
}

# ak47_conf <key> <default> - read one key from $AK47_CONFIG/devops.conf.
# The file is parsed, never sourced: a config file must not be able to run code.
ak47_conf() {
  local key=$1 def=${2:-} v
  [ -r "$AK47_CONFIG/devops.conf" ] || { printf '%s' "$def"; return 0; }
  v=$(awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$AK47_CONFIG/devops.conf" 2>/dev/null)
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$def"
}

# ak47_conf_bool <key> <default 0|1> - 1 only for an explicit truthy value.
ak47_conf_bool() {
  local v; v=$(ak47_conf "$1" "")
  case "$v" in
    1|yes|true|on) printf '1' ;;
    0|no|false|off) printf '0' ;;
    '') printf '%s' "${2:-0}" ;;
    *) printf '%s' "${2:-0}" ;;
  esac
}

# ak47_cache_get <key> <ttl-seconds> - print a cached value if fresh, else nothing.
ak47_cache_get() {
  local key=$1 ttl=$2 f="$AK47_STATE/sample.cache" ts val
  [ -r "$f" ] || return 1
  ts=$(awk -F'\t' -v k="$key" '$1==k{print $2;exit}' "$f" 2>/dev/null)
  val=$(awk -F'\t' -v k="$key" '$1==k{print $3;exit}' "$f" 2>/dev/null)
  [ -n "${ts:-}" ] || return 1
  [ $(( $(ak47_epoch) - ts )) -le "$ttl" ] || return 1
  printf '%s' "$val"
}

# ak47_cache_put <key> <value> - replace this key's row, keep the others.
ak47_cache_put() {
  local key=$1 val=$2 f="$AK47_STATE/sample.cache" tmp
  tmp=$(mktemp "${f}.XXXXXX") || return 0
  { [ -r "$f" ] && awk -F'\t' -v k="$key" '$1!=k' "$f"
    printf '%s\t%s\t%s\n' "$key" "$(ak47_epoch)" "$val"
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
}

# ak47_tmp_entries - top-level entry count in /tmp. One readdir, ~0.2 s.
ak47_tmp_entries() {
  local root=${AK47_TMP_ROOT:-/tmp}
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys;print(len(os.listdir(sys.argv[1])))' "$root" 2>/dev/null && return 0
  fi
  find "$root" -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c
}

# ak47_cache_age <key> - how many seconds old this key's cached value is, or
# nothing when the key has never been written. Read by the callers that have to
# say out loud that a value is old.
ak47_cache_age() {
  local key=$1 f="$AK47_STATE/sample.cache" ts
  [ -r "$f" ] || return 1
  ts=$(awk -F'\t' -v k="$key" '$1==k{print $2;exit}' "$f" 2>/dev/null)
  [ -n "${ts:-}" ] || return 1
  printf '%s' $(( $(ak47_epoch) - ts ))
}

# ak47_tmp_gb - /tmp size in whole GB. `du` over 950k entries takes ~30 s, so the
# value is cached for AK47_DU_TTL seconds (default 1800) and refreshed by the tick.
#
# 2026-11-14: on 698 GB of /tmp `du` stopped finishing at all, and every tick was
# killed by the unit's start timeout before it wrote its line - the loop went
# silent for hours and nothing else noticed, because the tick IS the sampler. A
# bounded tick may not call an unbounded sampler, so the walk is given its own
# budget (AK47_DU_BUDGET, default 300 s) and a walk that overruns falls back to the
# last known value. The age of that value is what tells a reader whether the
# fallback is fine or the tree is now permanently too big to measure.
#
# 2026-11-15: one `du` over the whole tree is all-or-nothing, so a tree that takes
# longer than the budget yields nothing at all and the number never refreshes.
# The walk now measures the top-level entries in batches and stops when the
# budget is spent, so a partial answer with its coverage recorded beats no
# answer. `tmp_gb_partial` holds "<entries measured>/<entries present>".
ak47_tmp_gb() {
  local ttl=${AK47_DU_TTL:-1800} budget=${AK47_DU_BUDGET:-300} v
  local retry=${AK47_DU_RETRY:-900} marker="$AK47_STATE/.tmp-gb-walk-failed" retrying=0
  # A failed walk is remembered for a while. Retrying a 90 s timeout on every
  # call is how the tick spent its whole interval failing to measure: the retry
  # interval is deliberate, not a sigh of relief.
  if [ -r "$marker" ]; then
    local failed_at
    failed_at=$(tr -dc 0-9 <"$marker" 2>/dev/null)
    if [ -n "$failed_at" ] && [ $(( $(ak47_epoch) - failed_at )) -lt "$retry" ]; then
      if v=$(ak47_cache_get tmp_gb 345600); then printf '%s' "$v"; else printf '0'; fi
      return 0
    fi
    retrying=1
  fi
  # The retry window owns the failed walk: once it has elapsed the walk is due
  # even though the fallback value is still cached.
  if [ "$retrying" -eq 0 ] && v=$(ak47_cache_get tmp_gb "$ttl"); then printf '%s' "$v"; return 0; fi
  # One walk over the whole tree is the cheap case and the accurate one: on the
  # 2026-11-15 box (108 GB, 129k entries) it takes 3m34s, inside the 300 s budget.
  v=$(timeout "$budget" du -sx --block-size=1G "${AK47_TMP_ROOT:-/tmp}" 2>/dev/null | cut -f1)
  case "${v:-}" in
    ''|*[!0-9]*) v="" ;;
  esac
  if [ -n "$v" ]; then
    rm -f "$marker" 2>/dev/null || true
    ak47_cache_put tmp_gb "$v"
    ak47_cache_put tmp_gb_ok "$(ak47_epoch)"
    printf '%s' "$v"
    return 0
  fi
  # The whole-tree walk did not finish. Measure what fits in half the budget and
  # report the coverage, so the number is a real lower bound instead of nothing.
  v=$(ak47_tmp_gb_walk $(( budget / 2 )))
  case "${v:-}" in
    ''|*[!0-9]*)
      # The walk produced nothing at all. Keep the last real measurement rather
      # than inventing one, and re-stamp it so the next run does not pay the same
      # timeout again: at 698 GB the walk costs its whole budget every time.
      # `tmp_gb_ok` records when the tree was last measured for real, which is
      # the number that tells a reader whether the value is merely old or the
      # tree has grown past measuring.
      mkdir -p "$AK47_STATE" 2>/dev/null || true
      ak47_epoch >"$marker" 2>/dev/null || true
      if v=$(ak47_cache_get tmp_gb 345600); then
        ak47_cache_put tmp_gb "$v"
        printf '%s' "$v"
      else
        printf '0'
      fi
      return 0 ;;
  esac
  # A partial walk: the number is a real lower bound over the entries it reached,
  # so it is worth caching, but it is NOT a measurement of the tree. Leaving
  # `tmp_gb_ok` alone is what keeps the staleness finding honest, and the marker
  # keeps the next run from paying the same budget again immediately.
  mkdir -p "$AK47_STATE" 2>/dev/null || true
  ak47_epoch >"$marker" 2>/dev/null || true
  ak47_cache_put tmp_gb "$v"
  printf '%s' "$v"
}

# ak47_tmp_gb_walk <budget-seconds> - measure the tree in batches, stop at the
# budget, and say how much of the tree the number covers.
#
# One `du` per batch of top-level entries, not one per entry: a per-entry fork
# over 130k entries is the 38-minute loop the captain hit on 2026-11-10. The
# batch size is small enough that a single huge directory cannot eat the whole
# budget before anything is counted, and the elapsed check runs between batches
# so the walk always returns.
#
# Returns 0 when every entry was measured, 1 when the budget ran out first. In
# both cases the partial total is printed and AK47_TMP_GB_COVERED /
# AK47_TMP_GB_ENTRIES describe the coverage.
ak47_tmp_gb_walk() {
  local budget=${1:-300} root=${AK47_TMP_ROOT:-/tmp} start elapsed
  local list total=0 covered=0 entries=0 kb batch=()
  start=$(ak47_epoch)
  list=$(mktemp) || return 1
  find "$root" -mindepth 1 -maxdepth 1 -print0 >"$list" 2>/dev/null || true
  entries=$(tr -cd '\0' <"$list" | wc -c)
  entries=${entries:-0}
  while IFS= read -r -d '' p; do
    batch+=("$p")
    if [ "${#batch[@]}" -ge 25 ]; then
      elapsed=$(( $(ak47_epoch) - start ))
      kb=$(timeout $(( budget - elapsed + 5 )) du -sx --block-size=1K "${batch[@]}" 2>/dev/null \
             | awk '{s+=$1} END{print s+0}')
      # A batch that failed or was cut off measured nothing: counting it as
      # covered would let a walk that never finished claim the whole tree.
      [ -n "${kb:-}" ] && [ "${kb:-0}" -gt 0 ] || { batch=(); break; }
      total=$(( total + kb ))
      covered=$(( covered + ${#batch[@]} ))
      batch=()
      [ $(( $(ak47_epoch) - start )) -ge "$budget" ] && break
    fi
  done <"$list"
  if [ "${#batch[@]}" -gt 0 ]; then
    elapsed=$(( $(ak47_epoch) - start ))
    kb=$(timeout $(( budget - elapsed + 5 )) du -sx --block-size=1K "${batch[@]}" 2>/dev/null \
           | awk '{s+=$1} END{print s+0}')
    if [ -n "${kb:-}" ] && [ "${kb:-0}" -gt 0 ]; then
      total=$(( total + kb ))
      covered=$(( covered + ${#batch[@]} ))
    fi
  fi
  rm -f "$list" 2>/dev/null || true
  # shellcheck disable=SC2034  # read by the tick's stale-size finding
  AK47_TMP_GB_COVERED=$covered
  # shellcheck disable=SC2034  # read by the tick's stale-size finding
  AK47_TMP_GB_ENTRIES=$entries
  ak47_cache_put tmp_gb_partial "$covered/$entries"
  printf '%s' $(( total / 1048576 ))
  [ "$covered" -ge "$entries" ]
}

# ak47_swap_pct - swap used as a whole percentage.
ak47_swap_pct() {
  awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{printf "%d", (t>0)?((t-f)*100/t):0}' "${AK47_MEMINFO:-/proc/meminfo}"
}

# ak47_mem_avail_gb - MemAvailable in whole GB.
ak47_mem_avail_gb() {
  awk '/^MemAvailable:/{printf "%d", $2/1048576}' "${AK47_MEMINFO:-/proc/meminfo}"
}

# ak47_load15 - the 15-minute load average.
ak47_load15() { awk '{print $3}' /proc/loadavg; }

# ak47_root_disk_pct - root filesystem used percentage, digits only.
ak47_root_disk_pct() { df --output=pcent / 2>/dev/null | tail -1 | tr -dc 0-9; }

# ak47_agent_count - resident pi agents.
# pgrep -c prints 0 AND exits 1 when nothing matches, so `|| echo 0` would emit
# two lines and split the sample line the weekly review parses. Capture, then
# default, so the caller always gets exactly one number.
ak47_agent_count() {
  local n
  n=$(pgrep -c -x pi 2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}

# ak47_tmux_core_pct - the tmux server's share of one core, as a percentage.
# The server is the fleet's spine: this is measured, never signalled.
ak47_tmux_core_pct() {
  local pid
  pid=$(pgrep -x tmux 2>/dev/null | head -1)
  [ -n "${pid:-}" ] || { printf '0'; return 0; }
  ps -o pcpu= -p "$pid" 2>/dev/null | awk '{printf "%d", $1+0}'
}

# ak47_user_slice - the cgroup directory for this uid's systemd manager.
# Overridable so a test can point at a fixture instead of the live cgroup: the
# task-cap arithmetic is the part that stopped the box, and it must be provable
# without editing the running system.
ak47_user_slice() {
  printf '%s' "${AK47_USER_SLICE:-/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service}"
}

# ak47_pids_cur - tasks (processes + threads) charged to this user's systemd
# manager, i.e. pids.current on user@<uid>.service.
# This is the number that stopped the box on 2026-11-14: it sat at its 12000 cap
# and every fork in the uid returned EAGAIN, so the fleet's own watcher, worker
# shells and checks all failed to start for five hours.
ak47_pids_cur() {
  local f; f=$(ak47_user_slice)/pids.current
  [ -r "$f" ] || return 1
  tr -dc 0-9 <"$f"
}

# ak47_pids_max - the same cgroup's pids.max, or 1 when it is the literal
# "max" (no cap). A caller that divides by this must handle 1.
ak47_pids_max() {
  local f v; f=$(ak47_user_slice)/pids.max
  [ -r "$f" ] || return 1
  v=$(tr -d ' \n' <"$f")
  case "$v" in ''|max) printf '1' ;; *[!0-9]*) return 1 ;; *) printf '%s' "$v" ;; esac
}

# ak47_pids_pct - tasks as a percentage of the cap. An uncapped manager reports
# 0 rather than a fiction: there is nothing to be a percentage of.
# An unreadable cgroup reports nothing at all, so the row is skipped instead of
# scored, because a made-up 0 would look like headroom that is not there.
ak47_pids_pct() {
  local cur max
  cur=$(ak47_pids_cur) || return 1
  max=$(ak47_pids_max) || return 1
  [ "$max" -gt 1 ] || { printf '0'; return 0; }
  printf '%s' $(( cur * 100 / max ))
}

# ak47_metric <key> - print the live value for one budget key.
ak47_metric() {
  case "$1" in
    load15)        ak47_load15 ;;
    swap_pct)      ak47_swap_pct ;;
    mem_avail_gb)  ak47_mem_avail_gb ;;
    tmp_entries)   ak47_tmp_entries ;;
    tmp_gb)        ak47_tmp_gb ;;
    root_disk_pct) ak47_root_disk_pct ;;
    tmux_core_pct) ak47_tmux_core_pct ;;
    agent_count)   ak47_agent_count ;;
    pids_pct)      ak47_pids_pct ;;
    *) return 1 ;;
  esac
}

# ak47_budget_rows - the budget table, one row per line:
#   key<TAB>ceiling<TAB>direction<TAB>unit<TAB>reason
# Blank lines and #-comments are skipped. A malformed row is a hard error: a
# budget with a silently dropped ceiling is worse than no budget.
ak47_budget_rows() {
  local n=0 line key ceil dir unit reason
  [ -r "$AK47_BUDGET" ] || { echo "ak47: budget table missing: $AK47_BUDGET" >&2; return 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    IFS='|' read -r key ceil dir unit reason <<<"$line"
    if [ -z "${key:-}" ] || [ -z "${ceil:-}" ] || [ -z "${dir:-}" ] || [ -z "${reason:-}" ]; then
      echo "ak47: budget.conf line $n is malformed (need key|ceiling|max-or-min|unit|reason): $line" >&2
      return 2
    fi
    case "$dir" in max|min) ;; *) echo "ak47: budget.conf line $n direction must be max or min, got '$dir'" >&2; return 2 ;; esac
    # A ceiling that is not a number cannot be compared against a sample, and a
    # board that silently skips it is a board with a hole in it.
    case "$ceil" in ''|*[!0-9]*) echo "ak47: budget.conf line $n ceiling must be a whole number, got '$ceil'" >&2; return 2 ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$ceil" "$dir" "$unit" "$reason"
  done <"$AK47_BUDGET"
}

# ak47_busy_tmp_names - the top-level /tmp names any live process holds.
# One /proc scan of every process's cwd, root, exe and open fds (~50 ms on a
# 5,000-process box), so a candidate can be checked in O(1) instead of running
# lsof +D per path. A name printed here is NEVER touched by the tick.
ak47_busy_tmp_names() {
  python3 - "${AK47_TMP_ROOT:-/tmp}" <<'PY'
import os, sys
root = sys.argv[1].rstrip('/') + '/'
seen = set()
for pid in os.listdir('/proc'):
    if not pid.isdigit():
        continue
    for link in ('cwd', 'root', 'exe'):
        try:
            p = os.readlink(f'/proc/{pid}/{link}')
        except OSError:
            continue
        if p.startswith(root):
            seen.add(p[len(root):].split('/')[0])
    try:
        fds = os.listdir(f'/proc/{pid}/fd')
    except OSError:
        continue
    for fd in fds:
        try:
            p = os.readlink(f'/proc/{pid}/fd/{fd}')
        except OSError:
            continue
        if p.startswith(root):
            seen.add(p[len(root):].split('/')[0])
for name in sorted(seen):
    print(name)
PY
}

# ak47_breach <value> <ceiling> <max|min> - 0 when the value is outside the ceiling.
ak47_breach() {
  awk -v v="$1" -v c="$2" -v d="$3" 'BEGIN{
    if (v == "" || c == "") exit 2
    if (d == "max") exit (v > c) ? 0 : 1
    exit (v < c) ? 0 : 1
  }'
}

# swap_run <budget|-> <command> [args...] - run a root-only swap command.
# Root runs it directly; everyone else goes through the one sudoers grant the
# README installs for these exact absolute commands.
swap_run() {
  local budget=$1; shift
  local -a cmd
  if [ "$(id -u)" -eq 0 ]; then
    cmd=("$@")
  else
    cmd=(sudo -n "$@")
  fi
  if [ "$budget" = - ]; then
    "${cmd[@]}"
  else
    timeout "$budget" "${cmd[@]}"
  fi
}

# swap_reclaim - stop swapping, let the pages come back, then start swapping again.
#
# The `swapoff -a && swapon -a` form has two defects that only show up when it
# fails: a unit killed between the two calls leaves the box with no swap, and the
# next run's `swapoff -a` then fails instantly because nothing is on - so the
# `&&` chain can never turn swap back on again. Swap is restored here whatever
# happened above, and the reclaim itself is given a budget so a slow swapoff
# cannot outlast the unit's start timeout. A failed restore is reported, not
# swallowed, because that leaves the box with less swap than it had.
swap_reclaim() {
  local before after rc=0 restore=0
  before=$(awk '/^SwapFree:/{printf "%d", ($2)/1048576}' /proc/meminfo 2>/dev/null || echo 0)
  swap_run "$AK47_SWAPOFF_BUDGET" "${AK47_SWAPOFF:-/sbin/swapoff}" -a 2>/dev/null || rc=$?
  swap_run - "${AK47_SWAPON:-/sbin/swapon}" -a >/dev/null 2>&1 || restore=1
  [ "$restore" -eq 1 ] && rc=1
  after=$(awk '/^SwapFree:/{printf "%d", ($2)/1048576}' /proc/meminfo 2>/dev/null || echo 0)
  # shellcheck disable=SC2034  # read by the tick after this call
  AK47_SWAP_RECLAIMED=$(( ${after:-0} - ${before:-0} ))
  return "$rc"
}

# ak47_unit_start - ring a user unit without waiting for it.
#
# The long actions cannot live inside the tick: systemd would kill them at the
# tick's start timeout, and a kill halfway through is exactly the state the
# always-restore rule exists to avoid. The unit is rung with --no-block and the
# tick records that it rang, not that it finished. AK47_SYSTEMCTL overrides the
# binary so a test can watch what was rung.
ak47_unit_start() {
  local systemctl=${AK47_SYSTEMCTL:-systemctl}
  "$systemctl" --user start --no-block "$1"
}

# ak47_unit_active - 0 when the named user unit is running right now.
ak47_unit_active() {
  local systemctl=${AK47_SYSTEMCTL:-systemctl}
  "$systemctl" --user is-active --quiet "$1" 2>/dev/null
}

# swap_privileged - 0 when this process may actually stop and start swap.
#
# swapoff and swapon are root-only, and the tick runs as a user unit. Arming the
# reclaim without checking would WARN and count a failure every tick while swap
# stayed full, so the tick proves the capability first and files the one line
# that grants it. The probe is one of the two granted commands: `sudo -n true`
# is outside the documented sudoers rule and would always be denied.
# AK47_SWAP_PRIVILEGE overrides the probe: yes/no/auto.
swap_privileged() {
  case "${AK47_SWAP_PRIVILEGE:-auto}" in
    yes) return 0 ;;
    no)  return 1 ;;
  esac
  [ "$(id -u)" -eq 0 ] && return 0
  swap_run - "${AK47_SWAPON:-/sbin/swapon}" -a >/dev/null 2>&1
}
