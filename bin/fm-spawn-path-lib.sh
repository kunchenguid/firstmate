#!/usr/bin/env bash
# Shell-side worktree-root discovery for spawn, before an agent is launched.
# fm_spawn_shell_worktree_path <target> sets SPAWN_PATH_PROBE_RESULT to the
# root reported by Git inside the endpoint and returns zero, or returns
# nonzero without a result. The caller supplies spawn_send_text_line and must
# still validate isolation and settling. The result is returned through a
# variable rather than stdout so the caller, itself inside a command
# substitution, can still read the probe's wait cost.
# A fresh private reply directory prevents echoed commands or old pane output
# from being mistaken for a reply. Windows shells need a native absolute path
# because Treehouse may enter the worktree through a nested cmd.exe shell.
# SPAWN_PATH_PROBE_WAIT_TENTHS reports how long the last probe spent waiting
# for the endpoint shell to answer, so callers can spend it out of their own
# wait budgets instead of letting a silent shell stretch a fixed iteration
# count past its deadline.
SPAWN_PATH_PROBE_WAIT_TENTHS=0
SPAWN_PATH_PROBE_RESULT=

fm_spawn_shell_worktree_path() { # <target>
  local target=$1 reply_dir reply_file shell_file path i
  SPAWN_PATH_PROBE_WAIT_TENTHS=0
  SPAWN_PATH_PROBE_RESULT=
  reply_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-path.XXXXXXXX") || return 1
  reply_file="$reply_dir/root"
  shell_file=$reply_file
  case "$OSTYPE" in
    msys*|cygwin*|win32*)
      shell_file=$(cygpath -m "$reply_file") || { rm -rf -- "$reply_dir"; return 1; }
      ;;
  esac
  # Double quotes work in both cmd.exe and POSIX shells. Refuse characters
  # either shell could expand inside them, rather than interpolating a path
  # whose meaning differs between the parent shell and the nested shell.
  case "$shell_file" in
    *'"'*|*'$'*|*'`'*|*'%'*|*'!'*|*$'\n'*|*$'\r'*) rm -rf -- "$reply_dir"; return 1 ;;
  esac
  if ! spawn_send_text_line "$target" "git rev-parse --show-toplevel > \"$shell_file\""; then
    rm -rf -- "$reply_dir"
    return 1
  fi
  for ((i=0; i<50; i++)); do
    # read requires a complete line: never publish a partially written path.
    if [ -f "$reply_file" ] && IFS= read -r path < "$reply_file" && [ -n "$path" ]; then
      path=${path%$'\r'}
      # PowerShell's `>` redirect (Windows PowerShell 5.1, herdr's default
      # endpoint shell on Windows) writes UTF-16 with a byte-order mark; bash's
      # read drops the interior NUL bytes, so the mark survives as a prefix and
      # would make cygpath emit an empty path. Strip any recognized BOM before
      # conversion; shells without one (cmd.exe, POSIX) are unaffected.
      case "$path" in
        $'\357\273\277'*) path=${path:3} ;;
        $'\376\377'*) path=${path:2} ;;
        $'\377\376'*) path=${path:2} ;;
      esac
      rm -rf -- "$reply_dir"
      [ -n "$path" ] || return 1
      case "$OSTYPE" in
        msys*|cygwin*|win32*) path=$(cygpath -u "$path") || return 1 ;;
      esac
      # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
      SPAWN_PATH_PROBE_RESULT=$path
      return 0
    fi
    SPAWN_PATH_PROBE_WAIT_TENTHS=$((SPAWN_PATH_PROBE_WAIT_TENTHS + 1))
    sleep 0.1
  done
  rm -rf -- "$reply_dir"
  return 1
}
