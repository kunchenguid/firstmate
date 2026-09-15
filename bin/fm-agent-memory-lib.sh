# shellcheck shell=bash
# fm-agent-memory-lib.sh - per-worker memory throttling primitives (systemd
# --user scopes on Linux). Sourced by bin/fm-spawn.sh (compose + configure +
# record), bin/fm-crew-state.sh (read the scope's live usage and, for a dead
# endpoint, its kill cause), and bin/fm-watch.sh (report a confirmed
# OOM-killed worker into its own status log).
#
# Why this exists (captain order 2026-09-02, after a busy fleet froze a
# host): worker processes have no ceiling of their own, so the kernel - not
# discipline - is the only thing standing between a runaway agent and a
# frozen host. The shape is throttle-then-protect, not a tight per-worker
# cap: MemoryHigh lets the kernel reclaim aggressively above the soft line
# without killing anything; only MemoryMax past that is fatal, and it is set
# high enough that a legitimately hungry agent is never the common case
# killed. Every non-systemd or non-Linux host (and Linux with no working
# `systemd --user` session, e.g. some CI runners) keeps the prior unwrapped
# launch untouched - fm_agent_memory_systemd_user_available is the single
# gate every caller checks first.
#
# config/agent-memory (optional, gitignored, docs/configuration.md
# "Agent memory limits") holds the five tunable numbers as plain
# `key=value` lines, first non-comment match per key wins, same convention as
# state/<id>.meta (fm_meta_get in bin/fm-backend.sh). An absent file, or an
# absent key within it, falls back to the compiled-in default below. Keys:
#   worker_memory_high       MemoryHigh for one crew's scope (soft, throttled)
#   worker_memory_max        MemoryMax for one crew's scope (hard, killed)
#   worker_memory_swap_max   MemorySwapMax for one crew's scope
#   slice_memory_high_pct    firstmate-agents.slice MemoryHigh, percent of MemTotal
#   slice_memory_max_pct     firstmate-agents.slice MemoryMax, percent of MemTotal
set -u

FM_AGENT_MEMORY_SLICE="firstmate-agents.slice"
FM_AGENT_MEMORY_CONFIG_FILE="agent-memory"
FM_AGENT_MEMORY_WORKER_HIGH_DEFAULT="3G"
FM_AGENT_MEMORY_WORKER_MAX_DEFAULT="6G"
FM_AGENT_MEMORY_WORKER_SWAP_MAX_DEFAULT="2G"
FM_AGENT_MEMORY_SLICE_HIGH_PCT_DEFAULT=55
FM_AGENT_MEMORY_SLICE_MAX_PCT_DEFAULT=70

# --- config -------------------------------------------------------------

# One key from config/agent-memory, or <default> when the file or the key is
# absent. Same first-match-wins convention as fm_meta_get; deliberately does
# not validate the value here - a malformed override reaches systemd, which
# refuses it loudly, rather than this library silently discarding it.
fm_agent_memory_config_value() {  # <config-dir> <key> <default>
  local config_dir=$1 key=$2 default=$3 path value
  path="$config_dir/$FM_AGENT_MEMORY_CONFIG_FILE"
  if [ -f "$path" ]; then
    value=$(grep "^$key=" "$path" 2>/dev/null | tail -1 | cut -d= -f2-) || value=
    [ -n "$value" ] && { printf '%s' "$value"; return; }
  fi
  printf '%s' "$default"
}

fm_agent_memory_worker_high() {  # <config-dir>
  fm_agent_memory_config_value "$1" worker_memory_high "$FM_AGENT_MEMORY_WORKER_HIGH_DEFAULT"
}
fm_agent_memory_worker_max() {  # <config-dir>
  fm_agent_memory_config_value "$1" worker_memory_max "$FM_AGENT_MEMORY_WORKER_MAX_DEFAULT"
}
fm_agent_memory_worker_swap_max() {  # <config-dir>
  fm_agent_memory_config_value "$1" worker_memory_swap_max "$FM_AGENT_MEMORY_WORKER_SWAP_MAX_DEFAULT"
}
fm_agent_memory_slice_high_pct() {  # <config-dir>
  fm_agent_memory_config_value "$1" slice_memory_high_pct "$FM_AGENT_MEMORY_SLICE_HIGH_PCT_DEFAULT"
}
fm_agent_memory_slice_max_pct() {  # <config-dir>
  fm_agent_memory_config_value "$1" slice_memory_max_pct "$FM_AGENT_MEMORY_SLICE_MAX_PCT_DEFAULT"
}

# --- availability ---------------------------------------------------------

# 0 only on Linux with systemd-run on PATH and a reachable `--user` manager.
# `systemctl --user show-environment` is a pure read with no side effect, so
# this is safe to call on every spawn: it never creates or touches a unit.
# FM_AGENT_MEMORY_DISABLE=1 forces this false regardless of real availability
# - firstmate's own test suite (tests/lib.sh) sets it globally so a spawn
# fixture's captured launch text stays deterministic on a host that happens
# to have a real systemd --user session (this feature's own tests explicitly
# clear it to exercise the real wrapper).
fm_agent_memory_systemd_user_available() {
  local os
  [ "${FM_AGENT_MEMORY_DISABLE:-0}" = 1 ] && return 1
  os=$(uname -s 2>/dev/null) || return 1
  [ "$os" = Linux ] || return 1
  command -v systemd-run >/dev/null 2>&1 || return 1
  systemctl --user show-environment >/dev/null 2>&1
}

# --- unit naming + argv composition (pure) --------------------------------

# fm-<task-id>-<gen>.scope, with every character outside the systemd
# unit-name-safe set (letters, digits, ":-_.\@") folded to "-". <gen> is
# meant to be the spawn's own SPAWN_GEN (bin/fm-spawn.sh), which already
# makes every launch of a given task id distinct, so a relaunch never
# collides with a still-draining prior scope's unit name.
fm_agent_memory_unit_name() {  # <task-id> <gen>
  local id=$1 gen=$2 raw safe
  raw="fm-${id}-${gen}"
  safe=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9:_.@-' '-')
  printf '%s.scope' "$safe"
}

# POSIX single-quote escaping, self-contained so this library never depends
# on a caller's own shell_quote (bin/fm-spawn.sh defines one locally).
fm_agent_memory_shell_quote() {  # <string>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# The full systemd-run invocation, as one shell command line ready to be
# typed literally into a crewmate pane exactly where the bare launch command
# used to go. Wraps the ENTIRE composed launch (env prefixes included) in a
# single `bash -c '<launch>'` argument so it runs as one process tree under
# the scope. `--scope` (not a transient service) runs the given command as a
# normal child of systemd-run itself - it does not re-exec through the
# service manager's own default environment the way a transient *service*
# unit would - so the pane's already-exported vars (GOTMPDIR, TRACEPARENT)
# reach the wrapped agent by ordinary process inheritance with no extra
# --setenv plumbing needed. Pure string composition: no systemd-run call.
fm_agent_memory_compose_launch() {  # <launch> <unit> <high> <max> <swap-max> [<slice>]
  local launch=$1 unit=$2 high=$3 max=$4 swap=$5 slice=${6:-$FM_AGENT_MEMORY_SLICE}
  printf 'systemd-run --user --scope --slice=%s --unit=%s -p MemoryHigh=%s -p MemoryMax=%s -p MemorySwapMax=%s -- bash -c %s' \
    "$(fm_agent_memory_shell_quote "$slice")" \
    "$(fm_agent_memory_shell_quote "$unit")" \
    "$(fm_agent_memory_shell_quote "$high")" \
    "$(fm_agent_memory_shell_quote "$max")" \
    "$(fm_agent_memory_shell_quote "$swap")" \
    "$(fm_agent_memory_shell_quote "$launch")"
}

# --- meminfo percentage math (pure) ---------------------------------------

# MemTotal in kB from /proc/meminfo (or an override path in tests). Empty/1
# on any read or parse failure - callers must check the exit status, never
# treat empty output as zero.
fm_agent_memory_meminfo_total_kb() {  # [<meminfo-path>]
  local path=${1:-/proc/meminfo} line kb
  [ -r "$path" ] || return 1
  line=$(grep -m1 '^MemTotal:' "$path" 2>/dev/null) || return 1
  kb=$(printf '%s' "$line" | grep -oE '[0-9]+' | head -1) || return 1
  case "$kb" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$kb"
}

# floor(total_kb * 1024 * pct / 100), plain integer bytes. Bash arithmetic is
# 64-bit, so this never overflows for any real host's MemTotal.
fm_agent_memory_pct_bytes() {  # <total-kb> <pct>
  local total_kb=$1 pct=$2
  case "$total_kb" in ''|*[!0-9]*) return 1 ;; esac
  case "$pct" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' $(( total_kb * 1024 * pct / 100 ))
}

# --- slice configuration (side-effecting, best-effort) ---------------------

# Sets firstmate-agents.slice's own MemoryHigh/MemoryMax from the configured
# percentages of MemTotal, applying to every worker's scope TOGETHER (the
# per-worker MemoryHigh/MemoryMax above bound one crew; this bounds the
# fleet). `systemctl --user set-property` on a slice that does not exist yet
# persists the setting for when a scope's --slice= first creates it, so this
# is safe to call before any worker has spawned. Idempotent: the same
# MemTotal always recomputes the same bytes. Best-effort by design - a
# caller that cannot configure the slice still spawns the worker unwrapped
# rather than blocking on host-level protection it cannot set up.
fm_agent_memory_slice_configure() {  # <config-dir> [<meminfo-path>]
  local config_dir=$1 meminfo=${2:-/proc/meminfo} total_kb high_pct max_pct high_bytes max_bytes
  total_kb=$(fm_agent_memory_meminfo_total_kb "$meminfo") || return 1
  high_pct=$(fm_agent_memory_slice_high_pct "$config_dir")
  max_pct=$(fm_agent_memory_slice_max_pct "$config_dir")
  high_bytes=$(fm_agent_memory_pct_bytes "$total_kb" "$high_pct") || return 1
  max_bytes=$(fm_agent_memory_pct_bytes "$total_kb" "$max_pct") || return 1
  systemctl --user set-property "$FM_AGENT_MEMORY_SLICE" \
    "MemoryHigh=$high_bytes" "MemoryMax=$max_bytes" >/dev/null 2>&1
}

# --- live reads (side-effect free) -----------------------------------------

fm_agent_memory_show_prop() {  # <unit> <property>
  systemctl --user show -p "$2" --value "$1" 2>/dev/null
}

# Raw MemoryCurrent bytes for a scope unit, or empty when the scope is gone
# (already garbage-collected) or unreadable. Never fails loudly: an absent
# scope is the expected steady state once a crew's turn ends.
fm_agent_memory_current() {  # <unit>
  local v
  v=$(fm_agent_memory_show_prop "$1" MemoryCurrent)
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$v"
}

# Raw Result value ("success", "oom-kill", ...) for a scope unit, or empty
# when unreadable/already collected.
fm_agent_memory_result() {  # <unit>
  fm_agent_memory_show_prop "$1" Result
}

fm_agent_memory_is_oom() {  # <result-value>
  [ "${1:-}" = oom-kill ]
}

# Bytes -> a short human-readable size (G/M/K/B), one decimal place. Falls
# back to the raw byte count on any non-numeric input.
fm_agent_memory_human_bytes() {  # <bytes>
  local bytes=$1
  case "$bytes" in ''|*[!0-9]*) printf '%s' "$bytes"; return ;; esac
  awk -v b="$bytes" 'BEGIN {
    if (b >= 1073741824) { printf "%.1fG", b/1073741824; exit }
    if (b >= 1048576)    { printf "%.1fM", b/1048576; exit }
    if (b >= 1024)       { printf "%.1fK", b/1024; exit }
    printf "%dB", b
  }'
}

# --- dead-worker diagnosis (side-effecting, best-effort, idempotent) -------

fm_agent_memory_meta_get() {  # <meta-file> <key>
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# When task <id>'s recorded memory scope shows it was killed by its own
# MemoryMax, append exactly one `failed: killed by the per-worker memory
# limit (MemoryMax=...)` line to its status log, so a silently-dead crew is
# diagnosed instead of surfacing as a generic stale/possible-wedge wake.
# Idempotent via state/<id>.oom-reported (bin/fm-teardown.sh removes it).
# No-op - never escalates on a guess - when: no meta, no recorded scope
# (non-systemd host, or a task spawned before this feature), the scope has
# already been garbage-collected (Result unreadable), Result is anything but
# oom-kill, or this task already reported. Call this ONLY once a caller has
# independently confirmed the endpoint is actually dead (bin/fm-watch.sh's
# stale/dead classification path); it does not itself check pane liveness.
fm_agent_memory_report_oom_kill() {  # <state-dir> <task-id>
  local state_dir=$1 id=$2 meta unit result marker max
  [ -n "$state_dir" ] && [ -n "$id" ] || return 1
  meta="$state_dir/$id.meta"
  [ -f "$meta" ] || return 0
  unit=$(fm_agent_memory_meta_get "$meta" memory_scope)
  [ -n "$unit" ] || return 0
  marker="$state_dir/$id.oom-reported"
  [ -e "$marker" ] && return 0
  result=$(fm_agent_memory_result "$unit") || result=
  fm_agent_memory_is_oom "$result" || return 0
  max=$(fm_agent_memory_meta_get "$meta" memory_max)
  [ -n "$max" ] || max="$unit"
  printf 'failed: killed by the per-worker memory limit (MemoryMax=%s)\n' "$max" >> "$state_dir/$id.status"
  : > "$marker"
}
