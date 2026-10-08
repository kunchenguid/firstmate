#!/usr/bin/env bash
# fm-herdr-wedge-lib.sh - the wedged-agent classifier, evidence capture, and
# agent-only kill for a Herdr pane. Sourced, never executed.
#
# The gap this closes. bin/fm-secondmate-liveness-lib.sh already probes every
# registered secondmate endpoint on each watcher tick and relaunches a dead one
# through the guarded spawn path under a per-mate lock and a bounded relaunch
# ledger. Its classifier cannot see one real failure mode: a harness process
# that is alive and registered but has stopped making progress - an upstream
# Claude Code deadlock observed three times on a remote secondmate (the TUI
# stopped mid-turn, the process sat at 0% CPU with no children, and SIGTERM was
# ignored, so each recovery needed a human SIGKILL). To
# fm_backend_herdr_agent_state that pane is `alive`, correctly: a harness
# process really is running in it. Only `dead` and `missing` authorize recovery,
# so a wedged mate fell through every existing path.
#
# `wedged` is therefore a SEPARATE verdict computed here, not a widening of
# `dead`. fm_backend_herdr_agent_state and the husk classifier under it stay
# exactly as strict as before, so teardown, duplicate prevention, and rollback -
# the paths that can destroy things - keep refusing on the reads they refused on
# before. Only the secondmate liveness path consults this library.
#
# The signal. Herdr exposes two independent monotonic progress counters for a
# pane, both read-only:
#
#   state_change_seq           `agent get <pane>`  .result.agent.state_change_seq
#   scroll.max_offset_from_bottom
#                              `pane list`         the pane's own scroll record
#
# A live agent advances them; a frozen one advances neither while
# `agent_status` stays `working` forever. That pair is the machine-readable form
# of the stopped TUI timer a human recognizes.
#
# Why BOTH counters and a generous window. `agent_status` legitimately sits at
# `working` with no terminal output for a long time during a slow model response
# or a long Bash command, and a false positive here SIGKILLs real work. So a
# wedged verdict requires that neither counter moved across the whole
# configurable window (default 15 minutes, floor 10), and the caller's existing
# relaunch bound stays in force on top of it, so even a systematically
# mis-detecting probe cannot kill-loop a healthy mate.
#
# Fail-safe direction. Every unreadable or unexpected read yields `unreadable`,
# never `wedged`: losing a counter to a vendor rename disables recovery rather
# than authorizing a kill. That failure must not be silent either, so the
# verdict word is reported to the caller, which logs it.
#
# Kill scope. The kill targets only pids that classify as a harness inside the
# pane's own process subtree - the pane's foreground group plus the transitive
# descendants of its shell, attributed through bin/fm-agent-process-lib.sh. The
# pane shell itself is never signalled. By construction that set cannot contain
# the Herdr session server, a sibling pane's agent, or another task's worker,
# because none of those is a descendant of this pane's shell.
#
# Placement. Everything here runs on the host the pane lives on. For a remote
# secondmate the parent never signals across hosts or guesses a pid: it calls
# bin/fm-remote-secondmate-control.sh's `wedge-state` and `wedge-recover` verbs
# over the existing transport, and those run this same library host-locally.

set -u

FM_HERDR_WEDGE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_HERDR_WEDGE_LIB_DIR/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_HERDR_WEDGE_LIB_DIR/fm-timeout-lib.sh"

# The default no-progress window. 15 minutes is deliberately well past any
# plausible silent-but-working stretch; the recommendation this implements asked
# for 10 minutes or more.
FM_HERDR_WEDGE_WINDOW_SECS_DEFAULT=900
# The smallest window a configured value may select. Below this the detector
# starts competing with ordinary long model responses and long Bash commands,
# and the cost of being wrong is a SIGKILL of live work, so a smaller value is
# refused rather than honored.
FM_HERDR_WEDGE_WINDOW_SECS_FLOOR=600
# How long the non-destructive evidence capture may take before it is abandoned.
# The capture runs inside a watcher tick, so it must be bounded; an abandoned
# capture never blocks the recovery.
FM_HERDR_WEDGE_CAPTURE_TIMEOUT_SECS=${FM_HERDR_WEDGE_CAPTURE_TIMEOUT_SECS:-45}
# How long `sample` profiles a wedged process for. Short enough to stay inside
# the capture bound, long enough to show a stack that is not moving.
FM_HERDR_WEDGE_SAMPLE_SECS=10
# The largest gap between two consecutive samples that still counts as observed
# time. Past it the window restarts rather than being judged, because the
# detector cannot vouch for a stretch it did not watch - a suspended machine or
# a jumped clock freezes the agent's counters without the agent being wedged.
# Five minutes is several watcher ticks at the default 60-second cadence, so an
# ordinary slow or skipped tick never restarts the window, while a sleep does.
# fm_herdr_wedge_max_sample_gap widens it for a slower watcher cadence.
FM_HERDR_WEDGE_MAX_SAMPLE_GAP_SECS=${FM_HERDR_WEDGE_MAX_SAMPLE_GAP_SECS:-300}
# How many watcher ticks a sample gap may span before it stops counting as
# observed time, whatever the cadence.
FM_HERDR_WEDGE_GAP_TICKS=5

# Every Herdr read here goes through the adapter's own CLI wrapper and target
# parser (client selection, session routing, protocol-mismatch retry), rather
# than a second herdr invocation path. A caller that already sourced the adapter
# costs nothing; one that only sourced bin/fm-backend.sh gets it loaded on
# first use.
fm_herdr_wedge_require_adapter() {
  command -v fm_backend_herdr_cli >/dev/null 2>&1 && return 0
  command -v fm_backend_source >/dev/null 2>&1 || return 1
  fm_backend_source herdr 2>/dev/null || return 1
  command -v fm_backend_herdr_cli >/dev/null 2>&1
}

# fm_herdr_wedge_window <config-dir>: the configured no-progress window in
# seconds, or `off`.
#
# config/secondmate-wedge-window is read with the whole-file
# whitespace-stripped, case-folded convention the other scalar config items use
# (config/backlog-backend, config/crew-harness). An absent file means the
# default. `off` disables wedge detection entirely for this home, which is the
# supported way to opt out of the automatic kill while keeping every other
# liveness behavior. A value below the floor, or an unparseable one, warns and
# falls back to the default: a typo must not quietly arm a hair-trigger kill.
fm_herdr_wedge_window() {  # <config-dir>
  local config_dir=${1:-} file value
  [ -n "$config_dir" ] || { printf '%s\n' "$FM_HERDR_WEDGE_WINDOW_SECS_DEFAULT"; return 0; }
  file="$config_dir/secondmate-wedge-window"
  [ -f "$file" ] || { printf '%s\n' "$FM_HERDR_WEDGE_WINDOW_SECS_DEFAULT"; return 0; }
  value=$(tr -d '[:space:]' < "$file" 2>/dev/null | tr '[:upper:]' '[:lower:]') || value=""
  case "$value" in
    off) printf 'off\n'; return 0 ;;
    '') printf '%s\n' "$FM_HERDR_WEDGE_WINDOW_SECS_DEFAULT"; return 0 ;;
    *[!0-9]*)
      echo "warning: $file: unrecognized value \"$value\"; using the ${FM_HERDR_WEDGE_WINDOW_SECS_DEFAULT}s default no-progress window (write a whole number of seconds of at least $FM_HERDR_WEDGE_WINDOW_SECS_FLOOR, or \"off\" to disable wedge recovery)" >&2
      printf '%s\n' "$FM_HERDR_WEDGE_WINDOW_SECS_DEFAULT"
      return 0
      ;;
  esac
  if [ "$value" -lt "$FM_HERDR_WEDGE_WINDOW_SECS_FLOOR" ]; then
    echo "warning: $file: ${value}s is below the ${FM_HERDR_WEDGE_WINDOW_SECS_FLOOR}s floor a wedge verdict needs to stay clear of ordinary long model responses; using the ${FM_HERDR_WEDGE_WINDOW_SECS_DEFAULT}s default instead" >&2
    printf '%s\n' "$FM_HERDR_WEDGE_WINDOW_SECS_DEFAULT"
    return 0
  fi
  printf '%s\n' "$value"
}

# fm_herdr_wedge_max_sample_gap: the effective largest observed-sample gap in
# seconds - the larger of FM_HERDR_WEDGE_MAX_SAMPLE_GAP_SECS and
# FM_HERDR_WEDGE_GAP_TICKS ticks of FM_SECONDMATE_LIVENESS_SECS when that cadence
# is set. A fixed limit at or below the tick interval would restart every window
# and silently disable wedge recovery for a home with a slow cadence.
fm_herdr_wedge_max_sample_gap() {
  local gap=$FM_HERDR_WEDGE_MAX_SAMPLE_GAP_SECS tick=${FM_SECONDMATE_LIVENESS_SECS:-}
  case "$gap" in ''|*[!0-9]*|0) gap=300 ;; esac
  case "$tick" in
    ''|*[!0-9]*|0) ;;
    *) [ $((tick * FM_HERDR_WEDGE_GAP_TICKS)) -le "$gap" ] || gap=$((tick * FM_HERDR_WEDGE_GAP_TICKS)) ;;
  esac
  printf '%s\n' "$gap"
}

# fm_herdr_wedge_counters <session> <pane>: the one read of this pane's agent
# status and both progress counters, printed as
# "<agent_status>\t<state_change_seq>\t<max_offset_from_bottom>".
#
# Fails (nonzero, no output) unless BOTH counters are present and numeric and
# the status is one Herdr documents, which is what keeps a vendor shape change
# out of the wedged verdict. The pane is located in `pane list` by its own
# echoed pane_id rather than by position, so a reordered or re-paginated listing
# cannot be read as another pane's progress.
fm_herdr_wedge_counters() {  # <session> <pane>
  local session=$1 pane=$2 agent_out panes_out status seq offset
  [ -n "$session" ] && [ -n "$pane" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  fm_herdr_wedge_require_adapter || return 1
  agent_out=$(fm_backend_herdr_cli "$session" agent get "$pane" 2>/dev/null) || return 1
  status=$(printf '%s' "$agent_out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null) || return 1
  case "$status" in
    working|idle|done|blocked) ;;
    *) return 1 ;;
  esac
  seq=$(printf '%s' "$agent_out" | jq -er \
    '.result.agent.state_change_seq | select(type == "number") | floor' 2>/dev/null) || return 1
  panes_out=$(fm_backend_herdr_cli "$session" pane list 2>/dev/null) || return 1
  # The pane's own record is found by pane_id anywhere in the response rather
  # than at a pinned path, so a workspace/tab nesting change does not break the
  # read; the scroll counter itself is still required to be numeric.
  offset=$(printf '%s' "$panes_out" | jq -er --arg pane "$pane" '
    [.. | objects | select(.pane_id? == $pane) | .scroll?.max_offset_from_bottom?
     | select(type == "number") | floor] | first | select(type == "number")' 2>/dev/null) || return 1
  printf '%s\t%s\t%s\n' "$status" "$seq" "$offset"
}

fm_herdr_wedge_record_path() {  # <state-dir> <id>
  printf '%s/.secondmate-wedge-%s\n' "$1" "$2"
}

# fm_herdr_wedge_cpu_centiseconds <pid...>: the agent's total consumed CPU time
# in centiseconds, summed over its pids.
#
# A frozen agent consumes no CPU - the incident's process sat at 0% with the
# timer stopped - while an agent waiting on a long model response or driving a
# long tool call keeps accumulating it. So CPU time is a progress signal the
# rendered counters cannot fake, and it is the one that separates a deadlock
# from a legitimately quiet turn.
#
# Both supported platforms name the accumulated-CPU column `cputime`, but they
# FORMAT it differently: BSD/macOS prints `[HH:]MM:SS.CC` (for example `0:12.34`)
# and Linux procps prints `[DD-]HH:MM:SS`. Both are parsed, to centiseconds
# rather than whole seconds, so an agent accumulating under a second of CPU
# between samples on macOS still reads as moving. Fails (nonzero, no output)
# when any pid's column cannot be read or parsed, which callers must treat as
# "cannot judge", never as zero.
fm_herdr_wedge_cpu_centiseconds() {  # <pid...>
  local ps_bin=${FM_HERDR_PS_BIN:-ps} pid raw total=0 cs
  [ "$#" -gt 0 ] || return 1
  command -v "$ps_bin" >/dev/null 2>&1 || return 1
  for pid in "$@"; do
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    raw=$(LC_ALL=C "$ps_bin" -p "$pid" -o cputime= 2>/dev/null) || return 1
    raw=${raw//[[:space:]]/}
    [ -n "$raw" ] || return 1
    cs=$(printf '%s\n' "$raw" | awk '
      {
        v = $0; days = 0; frac = 0
        if (v ~ /^[0-9]+-/) { days = substr(v, 1, index(v, "-") - 1); v = substr(v, index(v, "-") + 1) }
        if (v ~ /\.[0-9][0-9]$/) { frac = substr(v, length(v) - 1); v = substr(v, 1, length(v) - 3) }
        n = split(v, f, ":")
        if (n < 2 || n > 3) exit 1
        s = 0
        for (i = 1; i <= n; i++) {
          if (f[i] !~ /^[0-9]+$/) exit 1
          s = s * 60 + f[i]
        }
        # A leading day field multiplies by 24 hours, not by 60.
        printf "%d\n", ((days * 86400) + s) * 100 + frac
      }') || return 1
    case "$cs" in ''|*[!0-9]*) return 1 ;; esac
    total=$((total + cs))
  done
  printf '%s\n' "$total"
}

# fm_herdr_wedge_process_is_mcp <comm> <args>: whether this child process is one
# of the harness's own MCP servers rather than work it is doing right now.
#
# MCP servers are long-lived children that exist for the whole session, so their
# presence says nothing about whether the agent is making progress; a tool
# process does. The match is on the MCP wire-protocol vocabulary that appears in
# a server's own command line, and it is deliberately narrow: anything this
# cannot positively identify as an MCP server counts as live work, which refuses
# the kill rather than authorizing it.
fm_herdr_wedge_process_is_mcp() {  # <comm> <args>
  local comm=${1:-} args=${2:-} probe
  probe=$(printf '%s %s' "$comm" "$args" | tr '[:upper:]' '[:lower:]')
  case "$probe" in
    *mcp-server*|*mcp_server*|*mcp-remote*|*modelcontextprotocol*|*model-context-protocol*) return 0 ;;
    *' mcp '*|*' --mcp'*|*' mcp-'*|*'/mcp'*|mcp*) return 0 ;;
  esac
  return 1
}

# fm_herdr_wedge_live_work <pane-shell-agent-pid...>: whether the agent is
# currently running work of its own, as `busy` or `idle`.
#
# `busy` means at least one live descendant of an agent pid is not an MCP
# server - a Bash tool command, a subagent, a build. A genuinely frozen agent
# has none: the incident's process had no children at all. Fails (nonzero) when
# the process table cannot be read, so an unreadable answer can never be
# mistaken for `idle`.
fm_herdr_wedge_live_work() {  # <pid...>
  local rows pid child comm
  [ "$#" -gt 0 ] || return 1
  rows=$(fm_agent_process_table) || return 1
  for pid in "$@"; do
    fm_agent_process_table_has_pid "$rows" "$pid" || return 1
  done
  for pid in "$@"; do
    while IFS=$'\t' read -r child comm; do
      [ -n "$child" ] || continue
      # An agent pid nested under another agent pid is the harness itself, not
      # work it is doing.
      case " $* " in *" $child "*) continue ;; esac
      if ! fm_herdr_wedge_process_is_mcp "$comm" \
        "$(LC_ALL=C "${FM_HERDR_PS_BIN:-ps}" -p "$child" -o args= 2>/dev/null)"; then
        printf 'busy\n'
        return 0
      fi
    done <<EOF
$(fm_agent_process_descendant_rows "$rows" "$pid")
EOF
  done
  printf 'idle\n'
}

# fm_herdr_wedge_classify <state-dir> <id> <target> <window-secs> <baseline|judge>
#
# Sample this endpoint's progress and print one verdict:
#
#   progressing - working, but something moved since the recorded sample, or the
#                 window could not be measured as continuously observed time, so
#                 the window restarts now
#   wedged      - working, with both counters AND consumed CPU time unchanged for
#                 at least <window-secs> of observed time, and no live work of
#                 the agent's own
#   not-working - the agent is idle, done, or blocked: never a wedge candidate,
#                 and any recorded sample is dropped so the next working stretch
#                 starts clean
#   baseline    - <baseline> mode: the sample was recorded without judging it
#   unreadable  - a required signal could not be read in the required shape
#
# Three independent things must all say "frozen" before the verdict is `wedged`,
# because each one alone has a legitimate quiet case:
#
#   both herdr progress counters unchanged   a long model response produces no
#                                            new scrollback either
#   consumed CPU time unchanged              a frozen process burns none; an
#                                            agent waiting on a response or
#                                            driving a tool keeps accumulating it
#   no live non-MCP child process            a long Bash command or subagent is
#                                            a live child; a frozen agent had
#                                            none at all
#
# <baseline> mode exists for the session-start sweep. A single sweep sample
# cannot establish no-progress over a window, so session start re-bases the
# window and the watcher tick, which samples continuously, is the only producer
# of a wedged verdict.
#
# The window must be OBSERVED time, not wall-clock age. The session-start
# re-base alone does not give that: a long-running watcher that was suspended
# with the machine, or whose clock jumped, wakes up holding a sample from before
# the gap, and the agent's counters cannot have moved while it was frozen by the
# OS either. Judging `now - since` there would SIGKILL live work. So the record
# also carries the previous sample's own epoch, and a gap between consecutive
# samples larger than fm_herdr_wedge_max_sample_gap restarts the window instead
# of being counted as time this detector actually watched.
#
# Every unreadable signal leaves the recorded sample untouched and yields
# `unreadable`: a transient failure neither restarts the window nor advances it,
# and never authorizes a kill.
fm_herdr_wedge_classify() {  # <state-dir> <id> <target> <window-secs> <baseline|judge>
  local state_dir=$1 id=$2 target=$3 window=$4 mode=$5
  local record session pane counters status seq offset now since restart=0
  local pids cpu work max_gap
  local prev_target prev_status prev_seq prev_offset prev_cpu prev_since prev_seen
  case "$window" in ''|*[!0-9]*|0) return 1 ;; esac
  fm_herdr_wedge_require_adapter || { printf 'unreadable\n'; return 0; }
  fm_backend_herdr_parse_target "$target" || { printf 'unreadable\n'; return 0; }
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  record=$(fm_herdr_wedge_record_path "$state_dir" "$id")
  if ! counters=$(fm_herdr_wedge_counters "$session" "$pane"); then
    printf 'unreadable\n'
    return 0
  fi
  IFS=$'\t' read -r status seq offset <<< "$counters"
  if [ "$status" != working ]; then
    rm -f -- "$record" 2>/dev/null || true
    printf 'not-working\n'
    return 0
  fi
  # CPU time is sampled on this same tick cadence, at the window start and at
  # every tick after it, so the comparison below spans the whole window.
  if ! pids=$(fm_herdr_wedge_agent_pids "$session" "$pane"); then
    printf 'unreadable\n'
    return 0
  fi
  # shellcheck disable=SC2086 # The pid list is newline-separated digits by construction.
  if ! cpu=$(fm_herdr_wedge_cpu_centiseconds $pids); then
    printf 'unreadable\n'
    return 0
  fi
  # The unit rides in the stored value, so a record written in any other unit
  # never compares equal and restarts the window instead.
  cpu="${cpu}cs"
  max_gap=$(fm_herdr_wedge_max_sample_gap)
  now=$(date +%s)
  since=$now
  if [ "$mode" != baseline ] && [ -f "$record" ] && [ ! -L "$record" ]; then
    IFS=$'\t' read -r prev_target prev_status prev_seq prev_offset prev_cpu prev_since prev_seen \
      < "$record" 2>/dev/null || true
    if [ "${prev_target:-}" = "$target" ] && [ "${prev_status:-}" = working ] \
      && [ "${prev_seq:-}" = "$seq" ] && [ "${prev_offset:-}" = "$offset" ] \
      && [ "${prev_cpu:-}" = "$cpu" ]; then
      case "${prev_seen:-}" in
        ''|*[!0-9]*) restart=1 ;;
        *) [ $((now - prev_seen)) -le "$max_gap" ] || restart=1 ;;
      esac
      if [ "$restart" -eq 0 ]; then
        case "${prev_since:-}" in
          ''|*[!0-9]*) ;;
          *) since=$prev_since ;;
        esac
      fi
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$target" "$status" "$seq" "$offset" "$cpu" "$since" "$now" > "$record" 2>/dev/null \
    || { printf 'unreadable\n'; return 0; }
  [ "$mode" != baseline ] || { printf 'baseline\n'; return 0; }
  if [ "$since" -ne "$now" ] && [ $((now - since)) -ge "$window" ]; then
    # Last gate before authorizing a kill: a long, quiet tool call looks exactly
    # like a freeze on every signal above, and is told apart only by the live
    # child process doing that work.
    # shellcheck disable=SC2086 # Same: deliberate word splitting of the pid list.
    if ! work=$(fm_herdr_wedge_live_work $pids); then
      printf 'unreadable\n'
      return 0
    fi
    if [ "$work" = idle ]; then
      printf 'wedged\n'
      return 0
    fi
  fi
  printf 'progressing\n'
}

# fm_herdr_wedge_clear <state-dir> <id>: drop the recorded sample, so a
# recovered or relaunched mate starts its next working stretch with a full
# window instead of inheriting the frozen one's counters.
fm_herdr_wedge_clear() {  # <state-dir> <id>
  rm -f -- "$(fm_herdr_wedge_record_path "$1" "$2")" 2>/dev/null || true
}

# fm_herdr_wedge_agent_pids <session> <pane>: every pid inside this pane's own
# process subtree that classifies as a harness, one per line.
#
# The subtree is the pane's foreground process group plus the transitive
# descendants of the pane shell, both attributed by bin/fm-agent-process-lib.sh
# - the same identity rule the liveness probe proves a pane agent-free with, so
# the kill can only ever reach a process that probe would have counted as the
# live agent. The pane shell is excluded, so killing never closes the pane.
#
# Fails (nonzero, no output) when `pane process-info` is unreadable, describes
# another pane, names no shell pid, the process table cannot be read, or no
# harness pid is found. A caller must treat that as "do not kill".
fm_herdr_wedge_agent_pids() {  # <session> <pane>
  local session=$1 pane=$2 info shell_pid count i pid name argv0 args rows descendants out=''
  command -v jq >/dev/null 2>&1 || return 1
  fm_herdr_wedge_require_adapter || return 1
  info=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || return 1
  printf '%s' "$info" | jq -e --arg pane "$pane" '
    .result.type == "pane_process_info"
    and .result.process_info.pane_id == $pane
  ' >/dev/null 2>&1 || return 1
  shell_pid=$(printf '%s' "$info" | jq -er \
    '.result.process_info.shell_pid | select(type == "number" and . > 1) | floor' 2>/dev/null) || return 1
  count=$(printf '%s' "$info" | jq -er \
    '.result.process_info.foreground_processes | select(type == "array") | length' 2>/dev/null) || return 1
  rows=$(fm_agent_process_table) || return 1
  fm_agent_process_table_has_pid "$rows" "$shell_pid" || return 1
  descendants=$(fm_agent_process_descendant_rows "$rows" "$shell_pid")
  i=0
  while [ "$i" -lt "$count" ]; do
    pid=$(printf '%s' "$info" | jq -r --argjson i "$i" \
      '.result.process_info.foreground_processes[$i].pid | select(type == "number") | floor' 2>/dev/null)
    name=$(printf '%s' "$info" | jq -r --argjson i "$i" \
      '.result.process_info.foreground_processes[$i].name // empty' 2>/dev/null)
    argv0=$(printf '%s' "$info" | jq -r --argjson i "$i" '
      .result.process_info.foreground_processes[$i] as $p
      | (($p.argv // [])[0]) // $p.argv0 // empty' 2>/dev/null)
    args=$(printf '%s' "$info" | jq -r --argjson i "$i" '
      .result.process_info.foreground_processes[$i] as $p
      | $p.cmdline // (($p.argv // []) | join(" ")) // empty' 2>/dev/null)
    i=$((i + 1))
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" != "$shell_pid" ] || continue
    # A foreground pid is only accepted when the process table still carries it
    # AND it is inside this pane shell's subtree, so a stale or mislabeled
    # process-info entry can never aim the kill outside the pane.
    printf '%s\n' "$descendants" \
      | awk -F '\t' -v want="$pid" '$1 == want { found = 1 } END { exit(found ? 0 : 1) }' || continue
    if [ "$(fm_agent_process_classify "$name" "$argv0" "$args" "$pid")" = agent ]; then
      out="$out$pid"$'\n'
    fi
  done
  while IFS=$'\t' read -r pid name; do
    [ -n "$pid" ] || continue
    case "$pid" in *[!0-9]*) continue ;; esac
    [ "$pid" != "$shell_pid" ] || continue
    if [ "$(fm_agent_process_pid_classify "$pid" "$name" 2>/dev/null)" = agent ]; then
      out="$out$pid"$'\n'
    fi
  done <<EOF
$descendants
EOF
  # A foreground harness is usually also a descendant of the pane shell, so the
  # two passes overlap; dedupe so a caller counts one process once.
  [ -n "$out" ] || return 1
  printf '%s' "$out" | sort -un
}

# fm_herdr_wedge_capture <state-dir> <id> <pid...>: collect non-destructive
# evidence about a wedged process into one file under the home's state dir and
# print its path.
#
# This step exists because three freezes produced no sample at all, which is the
# single reason the mechanism behind them is still only a hypothesis: a stack
# captured here is what distinguishes a deadlock in the tool path from a hook
# batch whose promise never settled. Nothing it runs modifies, stops, or
# signals the target - `sample` and `lsof` only observe, and the Linux leg only
# reads /proc - so the capture is safe to take before the kill and worth taking
# even if the kill is later disabled.
#
# Best-effort and bounded: a missing tool or an abandoned bound is recorded in
# the file rather than failing the recovery. Fails only when the file itself
# cannot be created, because then there is no path to record.
fm_herdr_wedge_capture() {  # <state-dir> <id> <pid...>
  local state_dir=$1 id=$2 path pid rc task
  shift 2
  path="$state_dir/.wedge-sample-$id-$(date +%s).txt"
  : > "$path" 2>/dev/null || return 1
  {
    printf 'wedged secondmate %s\n' "$id"
    printf 'captured: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'uname: %s\n' "$(uname -a 2>/dev/null)"
    printf 'pids: %s\n' "$*"
  } >> "$path" 2>/dev/null || true
  for pid in "$@"; do
    printf '\n===== pid %s =====\n' "$pid" >> "$path" 2>/dev/null || true
    if [ "$(uname)" = Darwin ]; then
      # `sample` is the macOS stack profiler the recommendation names: it
      # attaches read-only for the given number of seconds and reports where
      # every thread is parked, which is exactly the frozen-stack question.
      if command -v sample >/dev/null 2>&1; then
        rc=0
        fm_run_timed "$FM_HERDR_WEDGE_CAPTURE_TIMEOUT_SECS" \
          sample "$pid" "$FM_HERDR_WEDGE_SAMPLE_SECS" >> "$path" 2>&1 || rc=$?
        [ "$rc" -eq 0 ] || printf '(sample exited %s)\n' "$rc" >> "$path" 2>/dev/null || true
      else
        printf '(sample not found)\n' >> "$path" 2>/dev/null || true
      fi
    else
      # The Linux equivalent, without requiring a debugger or ptrace
      # permission: the kernel's own view of what each thread is blocked in.
      printf -- '--- /proc/%s/status ---\n' "$pid" >> "$path" 2>/dev/null || true
      cat "/proc/$pid/status" >> "$path" 2>/dev/null \
        || printf '(unreadable)\n' >> "$path" 2>/dev/null || true
      printf -- '--- per-thread wchan/stat ---\n' >> "$path" 2>/dev/null || true
      for task in "/proc/$pid/task/"*; do
        [ -d "$task" ] || continue
        printf '%s wchan=%s stat=%s\n' "${task##*/}" \
          "$(cat "$task/wchan" 2>/dev/null)" \
          "$(cut -d' ' -f3 "$task/stat" 2>/dev/null)" >> "$path" 2>/dev/null || true
      done
      if command -v eu-stack >/dev/null 2>&1; then
        printf -- '--- eu-stack ---\n' >> "$path" 2>/dev/null || true
        fm_run_timed "$FM_HERDR_WEDGE_CAPTURE_TIMEOUT_SECS" eu-stack -p "$pid" >> "$path" 2>&1 || true
      fi
    fi
    # The open-file view the recommendation pairs with the stack: which socket
    # or pipe a frozen process is holding is often what names the deadlock.
    printf -- '--- open files ---\n' >> "$path" 2>/dev/null || true
    if command -v lsof >/dev/null 2>&1; then
      rc=0
      fm_run_timed "$FM_HERDR_WEDGE_CAPTURE_TIMEOUT_SECS" lsof -p "$pid" >> "$path" 2>&1 || rc=$?
      [ "$rc" -eq 0 ] || printf '(lsof exited %s)\n' "$rc" >> "$path" 2>/dev/null || true
    elif [ -d "/proc/$pid/fd" ]; then
      ls -l "/proc/$pid/fd" >> "$path" 2>&1 || true
    else
      printf '(lsof not found)\n' >> "$path" 2>/dev/null || true
    fi
  done
  printf '%s\n' "$path"
}

# fm_herdr_wedge_kill_agent <session> <pane> <pid...>: SIGKILL exactly the pids
# the caller captured evidence for, after re-confirming each one is still a
# harness in this pane's subtree.
#
# SIGKILL rather than SIGTERM because a wedged Claude demonstrably ignores
# SIGTERM - that is why every one of the three freezes needed a manual kill -9.
# The re-confirmation is what makes an unconditional SIGKILL safe: between the
# capture and the kill the process could have exited and its pid been reused, so
# the pid is re-attributed instead of trusted. Prints each killed pid; fails
# (nonzero) when nothing was killed.
fm_herdr_wedge_kill_agent() {  # <session> <pane> <pid...>
  local session=$1 pane=$2 pid current killed=0
  shift 2
  current=$(fm_herdr_wedge_agent_pids "$session" "$pane" 2>/dev/null) || return 1
  for pid in "$@"; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$current" | grep -Fxq "$pid" || continue
    kill -KILL "$pid" 2>/dev/null || continue
    printf '%s\n' "$pid"
    killed=1
  done
  [ "$killed" -eq 1 ] || return 1
}
