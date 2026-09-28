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

# fm_agent_process_worktree_scan: whether a verified harness process is still
# working in <worktree> anywhere on this host, read from the kernel's own
# per-process working directory rather than from any terminal endpoint. It
# answers the one question a lost endpoint leaves open - would launching a
# replacement join an agent that is still running on this task's local copy? -
# without trusting a runtime backend that could not see the endpoint.
#
# Only processes owned by the current user are read: a worker is always
# launched as that user, and another user's working directory is not readable
# anyway. Each process is classified by fm_agent_process_classify, so this
# answers from the same name vocabulary as every liveness probe.
#
# Prints "<verdict>\t<detail>", always exactly one TAB:
#   none        - every readable process was read and none is an agent there
#   agent       - "<pid> <name>" of an agent process working in <worktree>
#   unreadable  - the reason the process table could not be read; the caller
#                 must treat this as "an agent may be there"
# Linux reads /proc; any other platform needs lsof and ps. A process that exits
# mid-scan, and a zombie that holds no working directory, are skipped.
fm_agent_process_worktree_scan() {  # <worktree>
  local wt=${1-} wt_real dir pid cwd name argv0 args stat rest line cmd
  local lsof_out lsof_err lsof_diag lsof_status=0
  local -a pids=() names=()
  if [ -z "$wt" ] || ! wt_real=$(cd "$wt" 2>/dev/null && pwd -P); then
    printf 'unreadable\tthe worktree %s cannot be resolved' "'$wt'"
    return 0
  fi
  if [ -r /proc/self/cmdline ] && [ -L /proc/self/cwd ]; then
    for dir in /proc/[0-9]*; do
      [ -O "$dir" ] || continue
      pid=${dir#/proc/}
      if cwd=$(readlink "$dir/cwd" 2>/dev/null); then
        case "$cwd" in
          "$wt_real"|"$wt_real"/*) ;;
          *) continue ;;
        esac
      else
        # A process that exited mid-scan, or a zombie, has no working
        # directory left. A privileged or non-dumpable one (a per-session
        # sshd, ssh-agent) hides its link from its own user; that is only a
        # gap when the process is itself an agent, checked below.
        [ -d "$dir" ] || continue
        stat=$(cat "$dir/stat" 2>/dev/null) || continue
        rest=${stat##*) }
        case "${rest%% *}" in
          Z|X) continue ;;
        esac
        cwd=
      fi
      name=$(cat "$dir/comm" 2>/dev/null) || continue
      argv0=$(tr '\0' '\n' < "$dir/cmdline" 2>/dev/null | head -n 1) || argv0=
      args=$(tr '\0' ' ' < "$dir/cmdline" 2>/dev/null) || args=
      [ "$(fm_agent_process_classify "$name" "$argv0" "$args" "$pid")" = agent ] || continue
      if [ -z "$cwd" ]; then
        printf 'unreadable\tthe working directory of agent process %s (%s) could not be read' "$pid" "${name:-$argv0}"
        return 0
      fi
      printf 'agent\t%s %s' "$pid" "${name:-$argv0}"
      return 0
    done
    printf 'none\t'
    return 0
  fi
  if ! command -v lsof >/dev/null 2>&1 || ! command -v ps >/dev/null 2>&1; then
    printf 'unreadable\tthis platform has no /proc, and lsof or ps is not installed to read process working directories'
    return 0
  fi
  # Only a FAILED lsof refuses: a non-zero exit that also carries diagnostics.
  # lsof exits 1 for "no match" as well, and it warns on stderr about file
  # systems it cannot stat while still exiting 0 and reporting every process it
  # did read - macOS does that for its system volumes on every run - so reading
  # a warning as an incomplete table would refuse every reclaim on such a host.
  # Its diagnostics stay out of the parsed stream for the same reason: a
  # warning line read as a record would be a malformed one. `+c 0` asks for the
  # untruncated command name, so a long harness name still classifies by name.
  lsof_err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-agent-scan.XXXXXX") || {
    printf 'unreadable\tno scratch file could be created to read lsof diagnostics'
    return 0
  }
  lsof_out=$(lsof +c 0 -a -u "$(id -u)" -d cwd -Fpcn 2>"$lsof_err") || lsof_status=$?
  lsof_diag=$(head -n 1 -- "$lsof_err" 2>/dev/null) || lsof_diag=
  rm -f -- "$lsof_err"
  if [ "$lsof_status" -ne 0 ] && [ -n "$lsof_diag" ]; then
    printf 'unreadable\tlsof could not list process working directories: %s' "$lsof_diag"
    return 0
  fi
  pid=
  cmd=
  while IFS= read -r line; do
    case "$line" in
      p*) pid=${line#p}; cmd= ;;
      c*) cmd=${line#c} ;;
      n*)
        case "${line#n}" in
          "$wt_real"|"$wt_real"/*) pids+=("$pid"); names+=("$cmd") ;;
        esac
        ;;
      fcwd|'') ;;
      *) printf 'unreadable\tlsof printed an unexpected record'; return 0 ;;
    esac
  done <<EOF_LSOF
$lsof_out
EOF_LSOF
  local i
  if [ "${#pids[@]}" -gt 0 ]; then
    for i in "${!pids[@]}"; do
      args=$(LC_ALL=C ps -o args= -p "${pids[$i]}" 2>/dev/null) || continue
      args=${args#"${args%%[![:space:]]*}"}
      argv0=${args%%[[:space:]]*}
      if [ "$(fm_agent_process_classify "${names[$i]}" "$argv0" "$args" "${pids[$i]}")" = agent ]; then
        printf 'agent\t%s %s' "${pids[$i]}" "${names[$i]:-$argv0}"
        return 0
      fi
    done
  fi
  printf 'none\t'
}
