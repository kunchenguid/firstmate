#!/usr/bin/env bash
# Shell-side worktree-root discovery for spawn, before an agent is launched.
# fm_spawn_shell_worktree_path <target> prints the root reported by Git inside
# the endpoint, or returns nonzero without a path. The caller supplies
# spawn_send_text_line and must still validate isolation and settling.
# A fresh private reply directory prevents echoed commands or old pane output
# from being mistaken for a reply. Windows shells need a native absolute path
# because Treehouse may enter the worktree through a nested cmd.exe shell.

fm_spawn_shell_worktree_path() { # <target>
  local target=$1 reply_dir reply_file shell_file path i
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
      rm -rf -- "$reply_dir"
      [ -n "$path" ] || return 1
      case "$OSTYPE" in
        msys*|cygwin*|win32*) path=$(cygpath -u "$path") || return 1 ;;
      esac
      printf '%s\n' "$path"
      return 0
    fi
    sleep 0.1
  done
  rm -rf -- "$reply_dir"
  return 1
}
