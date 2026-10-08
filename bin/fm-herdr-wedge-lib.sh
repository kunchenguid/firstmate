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

# fm_herdr_wedge_classify <state-dir> <id> <target> <window-secs> <baseline|judge>
#
# Sample this endpoint's progress and print one verdict:
#
#   progressing - working, but a counter moved since the recorded sample, or
#                 this is the first sample, so the window restarts now
#   wedged      - working with BOTH counters unchanged for at least
#                 <window-secs>
#   not-working - the agent is idle, done, or blocked: never a wedge candidate,
#                 and any recorded sample is dropped so the next working stretch
#                 starts clean
#   baseline    - <baseline> mode: the sample was recorded without judging it
#   unreadable  - the counters could not be read in the required shape
#
# <baseline> mode exists for the session-start sweep. A single sweep sample
# cannot establish no-progress over a window, and a record left over from before
# a shutdown or a laptop suspend says nothing about whether the agent was frozen
# or merely unobserved - so session start re-bases the window and the watcher
# tick, which samples continuously, is the only producer of a wedged verdict.
#
# An unreadable read deliberately leaves the recorded sample untouched: a
# transient API failure neither restarts the window nor advances it.
fm_herdr_wedge_classify() {  # <state-dir> <id> <target> <window-secs> <baseline|judge>
  local state_dir=$1 id=$2 target=$3 window=$4 mode=$5
  local record session pane counters status seq offset now since
  local prev_target prev_status prev_seq prev_offset prev_since
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
  now=$(date +%s)
  since=$now
  if [ "$mode" != baseline ] && [ -f "$record" ] && [ ! -L "$record" ]; then
    IFS=$'\t' read -r prev_target prev_status prev_seq prev_offset prev_since < "$record" 2>/dev/null || true
    if [ "${prev_target:-}" = "$target" ] && [ "${prev_status:-}" = working ] \
      && [ "${prev_seq:-}" = "$seq" ] && [ "${prev_offset:-}" = "$offset" ]; then
      case "${prev_since:-}" in
        ''|*[!0-9]*) ;;
        *) since=$prev_since ;;
      esac
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$target" "$status" "$seq" "$offset" "$since" > "$record" 2>/dev/null \
    || { printf 'unreadable\n'; return 0; }
  [ "$mode" != baseline ] || { printf 'baseline\n'; return 0; }
  if [ "$since" -ne "$now" ] && [ $((now - since)) -ge "$window" ]; then
    printf 'wedged\n'
    return 0
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
