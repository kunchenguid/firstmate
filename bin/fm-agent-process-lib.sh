#!/usr/bin/env bash
# Backend-neutral harness-process identity.
# Sourced by bin/backends/tmux.sh and bin/backends/herdr.sh. This file is
# sourced by scripts and has no side effects on source.
#
# Why one owner: every runtime backend that proves an agent is alive does it by
# attributing operating-system processes - the pane's foreground process group
# on tmux, Herdr's `pane process-info` view plus the pane shell's descendants
# on Herdr - and the two must agree on what a given process name means, or a
# harness one backend recognizes silently reads as a dead pane on the other.
# The classifier moved here verbatim from the tmux adapter, where it was born;
# docs/tmux-backend.md "Agent liveness probe" owns the empirical basis for the
# names below, and tests/fm-tmux-agent-liveness.test.sh plus
# tests/fm-harness-liveness-drift-live-e2e.test.sh keep them honest.

_FM_AGENT_PROCESS_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_AGENT_PROCESS_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_AGENT_PROCESS_LIB_DIR=.
# shellcheck source=bin/fm-session-lock-lib.sh
. "${_FM_AGENT_PROCESS_LIB_DIR:-/}/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-gemini-lib.sh
. "${_FM_AGENT_PROCESS_LIB_DIR:-/}/fm-gemini-lib.sh"
unset _FM_AGENT_PROCESS_LIB_DIR

# fm_agent_process_classify_name: the single owner of the process-name
# vocabulary shared by every liveness signal - `agent` for a verified harness,
# `shell` for an idle login/interactive shell, `other` for anything else.
# Keeping one classifier means independent name sources (a kernel process
# name, an argv[0], a rendered pane title) can never drift into disagreeing
# about what a given name means.
fm_agent_process_classify_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    # muse is anchored rather than globbed like its neighbours: its installed
    # binary is muse-bin-<version> (the launcher execs it, so the version is the
    # live process name and changes on every auto-update), and unlike `claude` or
    # `codex` the substring `muse` is a common English fragment - a *muse* glob
    # would classify musescore or amuse as a live agent pane. The install path
    # cannot carry it either: ~/.local/bin/muse-bin-<version> has no `muse` path
    # COMPONENT, so the fm_harness_path_name fallback below never fires for it.
    muse|muse-bin-*) printf 'agent' ;;
    # omp (Oh My Pi) is anchored for the same reason as muse: its live process
    # name is the bare word `omp` (verified, omp 18.1.11) and a glob would claim
    # unrelated commands such as ompd or comp.
    *claude*|*codex*|*opencode*|*grok*|*kimi*|*rovo*|pi|pi-signed|pi-launcher|Pi|omp) printf 'agent' ;;
    # agy (Antigravity CLI) is anchored for the same reason as muse and omp: its
    # live process name is the bare word `agy` (verified, agy 1.2.0: a Go-compiled
    # single binary, comm=agy with argv[0]=agy), and a glob would claim
    # unrelated commands containing that fragment. devin is anchored the same
    # way (verified, devin 3000.11.1: comm=devin), so a `*devin*` glob never
    # claims an unrelated command.
    agy|devin) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      # cursor-agent runs as a bundled node script, so tmux reports the pane
      # command as a bare `node` that no name pattern above can own, and its
      # other installed name is the far-too-generic `agent` (verified live on
      # cursor-agent 2026.08.11-e8db854: #{pane_current_command} is `node` while
      # `ps -o comm=` carries the cursor-agent install path). Identity therefore
      # comes from the narrowed structural rule in bin/fm-cursor-lib.sh, which
      # demands Cursor's own name or install tree in the path or argv[0]. An
      # unrelated `node` or `agent` matches nothing here and stays `other`,
      # which the callers fold into `ambiguous` rather than `dead`, so a
      # stranger's node pane is never reported as an agent-free pane.
      elif fm_cursor_process_matches "${path:-$argv0}" '' "$argv0"; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}

# fm_agent_process_classify: one process, from every identity surface a
# backend can hand over, as agent|shell|other. Any single surface naming a
# verified harness carries `agent`, because a false negative is the one outcome
# that launches a duplicate agent onto a live worktree; `shell` needs every
# readable surface to agree the process is a shell; anything else is `other`.
#
#   <name>   the kernel process name (ps comm, or Herdr's process-info .name):
#            on Linux the exec name, on macOS argv[0] truncated to 16 bytes.
#   <argv0>  argv[0] as the process reports it - a bare name or an install
#            path, whichever the launcher used (empty when unknown).
#   <args>   the flattened command line, read only for the node-bundle
#            harnesses whose identity sits in argv[1] (bin/fm-gemini-lib.sh).
#   [pid]    when given, lets the Gemini rule read argv boundaries from the
#            live process instead of the flattened line.
fm_agent_process_classify() {  # <name> <argv0> <args> [pid] -> agent|shell|other
  local name=${1:-} argv0=${2:-} args=${3:-} pid=${4:-} by_name by_argv0
  by_name=$(fm_agent_process_classify_name "$name" "$argv0")
  [ "$by_name" != agent ] || { printf 'agent'; return 0; }
  if [ -n "$argv0" ]; then
    # argv[0] is classified as a path in its own right, so a bare `pi` or a
    # `-zsh` login name reads by basename and an install path by component.
    by_argv0=$(fm_agent_process_classify_name "$argv0" "$argv0")
    [ "$by_argv0" != agent ] || { printf 'agent'; return 0; }
  else
    by_argv0=$by_name
  fi
  if [ -n "$pid" ] && fm_gemini_pid_is_gemini "$pid"; then
    printf 'agent'
    return 0
  fi
  if [ -n "$args" ] && fm_gemini_args_are_gemini "$args"; then
    printf 'agent'
    return 0
  fi
  if [ "$by_name" = shell ] && [ "$by_argv0" = shell ]; then
    printf 'shell'
  else
    printf 'other'
  fi
}

# fm_agent_process_table: the raw process table every pane-scoped liveness and
# recovery decision is attributed against, as "pid ppid comm" rows. One owner so
# the `ps` selection and the FM_HERDR_PS_BIN test seam cannot drift between the
# probe that proves a pane agent-free and the recovery that kills its agent.
# Fails (nonzero, no output) when `ps` is absent or unreadable.
fm_agent_process_table() {
  local ps_bin=${FM_HERDR_PS_BIN:-ps}
  command -v "$ps_bin" >/dev/null 2>&1 || return 1
  LC_ALL=C "$ps_bin" -axo pid=,ppid=,comm= 2>/dev/null
}

# fm_agent_process_table_has_pid <rows> <pid>: whether the table positively
# contains <pid>. A table that does not contain the pane's own shell is not
# evidence about its descendants - it is an unreadable table - so callers gate
# on this before drawing any conclusion from an empty descendant set.
fm_agent_process_table_has_pid() {  # <rows> <pid>
  printf '%s\n' "$1" | awk -v want="$2" '$1 == want { found = 1 } END { exit(found ? 0 : 1) }'
}

# fm_agent_process_descendant_rows <rows> <pid>: every transitive descendant of
# <pid> in <rows>, as "<pid>\t<comm>" lines, excluding <pid> itself. The walk is
# transitive because the crew and secondmate pane shapes nest shells (a
# `treehouse get` shell under the pane's top shell), so a harness can sit several
# levels below the pane shell; and it is bounded to that subtree, which is what
# makes a kill derived from it incapable of reaching the session server, a
# sibling pane, or another task's worker.
fm_agent_process_descendant_rows() {  # <rows> <pid>
  printf '%s\n' "$1" | awk -v shell="$2" '
  {
    pid[NR] = $1; ppid[NR] = $2
    line = $0
    sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", line)
    comm[NR] = line
  }
  END {
    want[shell] = 1
    changed = 1
    while (changed) {
      changed = 0
      for (n = 1; n <= NR; n++) {
        if ((ppid[n] in want) && !(pid[n] in want)) { want[pid[n]] = 1; changed = 1 }
      }
    }
    for (n = 1; n <= NR; n++) {
      if ((pid[n] in want) && pid[n] != shell) printf "%s\t%s\n", pid[n], comm[n]
    }
  }'
}

# fm_agent_process_pid_classify <pid> <comm>: classify one live pid from the
# process table, reading its full argv for the identity surfaces
# fm_agent_process_classify needs. Prints agent|shell|other, or nothing
# (nonzero) when the process is already gone.
fm_agent_process_pid_classify() {  # <pid> <comm>
  local pid=$1 comm=$2 ps_bin=${FM_HERDR_PS_BIN:-ps} args argv0
  args=$(LC_ALL=C "$ps_bin" -p "$pid" -o args= 2>/dev/null) || return 1
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  fm_agent_process_classify "$comm" "$argv0" "$args" "$pid"
}
