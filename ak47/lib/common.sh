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

# ak47_tmp_gb - /tmp size in whole GB. `du` over 950k entries takes ~30 s, so the
# value is cached for AK47_DU_TTL seconds (default 1800) and refreshed by the tick.
ak47_tmp_gb() {
  local ttl=${AK47_DU_TTL:-1800} v
  if v=$(ak47_cache_get tmp_gb "$ttl"); then printf '%s' "$v"; return 0; fi
  v=$(du -sx --block-size=1G "${AK47_TMP_ROOT:-/tmp}" 2>/dev/null | cut -f1)
  [ -n "${v:-}" ] || v=0
  ak47_cache_put tmp_gb "$v"
  printf '%s' "$v"
}

# ak47_swap_pct - swap used as a whole percentage.
ak47_swap_pct() {
  awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{printf "%d", (t>0)?((t-f)*100/t):0}' /proc/meminfo
}

# ak47_mem_avail_gb - MemAvailable in whole GB.
ak47_mem_avail_gb() {
  awk '/^MemAvailable:/{printf "%d", $2/1048576}' /proc/meminfo
}

# ak47_load15 - the 15-minute load average.
ak47_load15() { awk '{print $3}' /proc/loadavg; }

# ak47_root_disk_pct - root filesystem used percentage, digits only.
ak47_root_disk_pct() { df --output=pcent / 2>/dev/null | tail -1 | tr -dc 0-9; }

# ak47_agent_count - resident pi agents.
ak47_agent_count() { pgrep -c -x pi 2>/dev/null || echo 0; }

# ak47_tmux_core_pct - the tmux server's share of one core, as a percentage.
# The server is the fleet's spine: this is measured, never signalled.
ak47_tmux_core_pct() {
  local pid
  pid=$(pgrep -x tmux 2>/dev/null | head -1)
  [ -n "${pid:-}" ] || { printf '0'; return 0; }
  ps -o pcpu= -p "$pid" 2>/dev/null | awk '{printf "%d", $1+0}'
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
      echo "ak47: budget.conf line $n is malformed (need key|ceiling|max|min|unit|reason): $line" >&2
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
