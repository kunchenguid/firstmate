#!/usr/bin/env bash
# fm-resource-lib.sh - shared primitives for agent resource sampling and
# kill evidence. Sourced by bin/fm-resource-sample.sh and
# bin/fm-agent-postmortem.sh; no side effects on source.
#
# Why: when an agent process dies with `signal: killed` the fleet could say the
# kill happened but never why - the memory picture at the moment of death was
# never recorded anywhere, so an OOM kill and an external `kill -9` looked
# identical after the fact. These primitives capture the picture continuously
# (cheap enough to leave on) so the next kill explains itself.
# The evidence sources macOS actually exposes on an SIP-enabled machine, and the
# ones it does NOT, are recorded in docs/agent-kill-evidence.md.
#
# Everything here is read-only against the system, bounded, and degrades to
# `unknown` fields rather than failing: a sampling gap must never break
# supervision.

# Read by the sampler and the watcher, not by this lib.
# shellcheck disable=SC2034
FM_RESOURCE_SAMPLE_INTERVAL_DEFAULT=30   # seconds between sampling passes
# shellcheck disable=SC2034
FM_RESOURCE_SAMPLES_MAX_DEFAULT=2000     # lines kept per state/<id>.resource

# tmux reads go through fm_tmux so they name the fleet socket explicitly rather
# than inheriting a server from the environment (bin/fm-tmux-lib.sh).
# shellcheck source=bin/fm-tmux-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-tmux-lib.sh"

FM_RES_UNAME=$(uname 2>/dev/null || echo unknown)

# fm_res_now_iso: local timestamp for human-readable evidence records.
fm_res_now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# fm_res_bounded <secs> <cmd...>: run a command with a wall-clock bound, using
# whatever the machine has. macOS ships no `timeout`, so perl is the fallback
# (the same three-way pattern bin/fm-crew-state.sh uses). With none of the three,
# the command is skipped rather than run unbounded - an evidence collector must
# never hang a supervision poll.
fm_res_bounded() {  # <secs> <cmd> [args...]
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # single quotes are deliberate: perl expands its own vars
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$secs" "$@"
  else
    return 127
  fi
}

# fm_res_mem_snapshot: one line describing the MACHINE's memory pressure right
# now, in the terms the kernel's own killer uses.
#
#   free_mb        free + speculative pages (Darwin) / MemAvailable (Linux)
#   compressor_mb  pages held by the VM compressor - the number that grows while
#                  macOS is compressing instead of killing
#   swap_used_mb   vm.swapusage used (Darwin) / SwapTotal-SwapFree (Linux)
#   memstat_level  kern.memorystatus_level: the kernel's own free-memory
#                  percentage, the value jetsam thresholds are expressed against
#                  (Darwin only; the single most useful field for "was this an
#                  OOM kill")
#
# Every field degrades to `unknown` on its own; the line's shape never changes.
fm_res_mem_snapshot() {
  local free_mb=unknown compressor_mb=unknown swap_used_mb=unknown level=unknown
  case "$FM_RES_UNAME" in
    Darwin)
      local vs
      vs=$(vm_stat 2>/dev/null || true)
      if [ -n "$vs" ]; then
        free_mb=$(printf '%s\n' "$vs" | awk '
          /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") { ps = $(i+1); break } }
          /^Pages free/ { gsub(/[^0-9]/, "", $NF); f = $NF }
          /^Pages speculative/ { gsub(/[^0-9]/, "", $NF); s = $NF }
          END { if (ps > 0) printf "%d", (f + s) * ps / 1048576; else print "unknown" }')
        compressor_mb=$(printf '%s\n' "$vs" | awk '
          /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") { ps = $(i+1); break } }
          /^Pages occupied by compressor/ { gsub(/[^0-9]/, "", $NF); c = $NF }
          END { if (ps > 0) printf "%d", c * ps / 1048576; else print "unknown" }')
      fi
      swap_used_mb=$(sysctl -n vm.swapusage 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "used") { v = $(i+2); gsub(/[^0-9.]/, "", v); printf "%d", v; exit } }')
      level=$(sysctl -n kern.memorystatus_level 2>/dev/null || true)
      ;;
    Linux)
      if [ -r /proc/meminfo ]; then
        free_mb=$(awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' /proc/meminfo)
        swap_used_mb=$(awk '/^SwapTotal:/ { t = $2 } /^SwapFree:/ { f = $2 } END { printf "%d", (t - f) / 1024 }' /proc/meminfo)
      fi
      ;;
  esac
  [ -n "$free_mb" ] || free_mb=unknown
  [ -n "$compressor_mb" ] || compressor_mb=unknown
  [ -n "$swap_used_mb" ] || swap_used_mb=unknown
  [ -n "$level" ] || level=unknown
  printf 'free_mb=%s compressor_mb=%s swap_used_mb=%s memstat_level=%s' \
    "$free_mb" "$compressor_mb" "$swap_used_mb" "$level"
}

# fm_res_ps_snapshot: ONE process-table read per sampling pass (~30ms), shared by
# every task in the pass. Never call `ps` per task: the whole point of the shared
# snapshot is that sampling a fleet costs the same as sampling one crew.
# Format: "<pid> <ppid> <rss_kb> <comm>" per line.
fm_res_ps_snapshot() {
  ps -eo pid=,ppid=,rss=,comm= 2>/dev/null || true
}

fm_res_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# fm_res_pane_pid: the shell pid of a task's terminal, the root of the process
# tree the agent lives in.
#
# tmux only, deliberately. tmux is the verified reference backend and the only
# one that exposes a pane's shell pid through a documented, cheap query
# (#{pane_pid}); the experimental backends expose no equivalent. A task on
# another backend therefore records no agent pid and gets no samples, and the
# postmortem SAYS SO rather than pretending it saw nothing suspicious.
fm_res_pane_pid() {  # <meta>
  local meta=$1 backend window pid
  backend=$(fm_res_meta_value "$meta" backend)
  [ -n "$backend" ] || backend=tmux
  [ "$backend" = tmux ] || return 1
  window=$(fm_res_meta_value "$meta" window)
  [ -n "$window" ] || return 1
  fm_tmux_bind_meta "$meta"
  pid=$(fm_tmux display-message -p -t "$window" '#{pane_pid}' 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$pid"
}

# fm_res_agent_pid: the harness process under a task's terminal.
#
# It is NOT a direct child of the pane shell: a treehouse-pooled crew's tree is
# tmux -> zsh (pane) -> treehouse -> zsh -> claude (verified live on this fleet),
# so the agent sits several levels down. Walk the descendant tree from the pane
# shell (breadth-first, bounded depth) and return the first process whose command
# basename matches the task's recorded harness. Empty when the harness process is
# not in the tree - which is exactly the "the agent is gone" signal the sampler
# acts on.
fm_res_agent_pid() {  # <pane-pid> <harness> <ps-snapshot>
  local root=$1 harness=$2 snap=$3 depth=0 next pid ppid comm base
  local frontier=$root
  [ -n "$harness" ] || return 1
  while [ -n "$frontier" ] && [ "$depth" -lt 12 ]; do
    next=""
    while read -r pid ppid _ comm; do
      [ -n "$pid" ] || continue
      case " $frontier " in *" $ppid "*) ;; *) continue ;; esac
      base=${comm##*/}
      if [ "$base" = "$harness" ]; then
        printf '%s' "$pid"
        return 0
      fi
      next="$next $pid"
    done <<EOF
$snap
EOF
    frontier=$next
    depth=$((depth + 1))
  done
  return 1
}

fm_res_rss_kb() {  # <pid> <ps-snapshot>
  local want=$1 snap=$2 pid rss
  while read -r pid _ rss _; do
    if [ "$pid" = "$want" ]; then
      printf '%s' "$rss"
      return 0
    fi
  done <<EOF
$snap
EOF
  return 1
}

# fm_res_trim: keep a sample log bounded. Called after every append, so a
# permanently-on sampler cannot grow state/ without bound.
fm_res_trim() {  # <file> <max-lines>
  local f=$1 max=$2 n
  n=$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]')
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -le "$max" ] && return 0
  tail -n "$max" "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null
  rm -f "$f.tmp" 2>/dev/null || true
}
