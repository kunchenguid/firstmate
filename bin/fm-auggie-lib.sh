#!/usr/bin/env bash
# Auggie (Augment CLI) process identity.
# Sourced by bin/fm-session-lock-lib.sh and bin/fm-harness.sh. This file is
# sourced by scripts and has no side effects on source.
#
# Why one owner: auggie ships as a node bundle, so a live auggie session
# presents as an interpreter and nothing about its command NAME says auggie.
# Measured on auggie 1.2.0 with Node v26 on Linux, the primary process read:
#
#   comm : node-MainThread
#   args : node /home/<user>/.local/bin/auggie
#
# where ~/.local/bin/auggie is a symlink into the published package,
# <prefix>/lib/node_modules/@augmentcode/auggie/auggie-v2.mjs, and Node 24 can
# report comm as a bare MainThread instead. Only the script argument carries
# the identity, so the rule reads it and resolves its symlink chain, the same
# structural shape bin/fm-cursor-lib.sh and bin/fm-gemini-lib.sh use: no
# subprocess, because probing a stranger's binary during an ancestry walk or a
# liveness poll is exactly what must not happen.
#
# auggie is deliberately NOT a name in FM_HARNESS_RE (bin/fm-session-lock-lib.sh)
# and the interpreter rule is never loosened to "any node": a bare node or
# MainThread with no auggie script is rejected, so an unrelated node process
# cannot pass session-lock holder liveness.
#
# auggie publishes no harness-identity marker: zero AUGMENT_* variables reach
# the commands its bash tool runs (verified, auggie 1.2.0), so identity is this
# structural rule alone.

# fm_cursor_canonical_path owns the portable symlink walk; load it only when the
# caller has not already sourced its owner.
if ! declare -F fm_cursor_canonical_path >/dev/null 2>&1; then
  _FM_AUGGIE_LIB_DIR=${BASH_SOURCE[0]%/*}
  [ "$_FM_AUGGIE_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_AUGGIE_LIB_DIR=.
  # shellcheck source=bin/fm-cursor-lib.sh
  . "${_FM_AUGGIE_LIB_DIR:-/}/fm-cursor-lib.sh"
  unset _FM_AUGGIE_LIB_DIR
fi

# True when script path $1 carries auggie's own structural evidence after its
# symlink chain is resolved: the file is named exactly auggie, or it sits
# directly in the published @augmentcode/auggie package tree (any entrypoint
# name, so a renamed auggie-v<N>.mjs keeps matching). A vendored dependency
# under that package's node_modules, a directory merely named auggie-something,
# and a sibling such as auggie-mcp never match.
fm_auggie_path_is_auggie() {  # <path>
  local path=$1 canonical
  [ -n "$path" ] || return 1
  case "$path" in -*) return 1 ;; esac
  canonical=$(fm_cursor_canonical_path "$path") || return 1
  case "$canonical" in
    */@augmentcode/auggie/node_modules/*) return 1 ;;
    */@augmentcode/auggie/*) return 0 ;;
  esac
  case "${canonical##*/}" in auggie) return 0 ;; esac
  return 1
}

# Print Node's main script, skipping interpreter options and their operands.
# Read the live process's NUL-delimited argv when [pid] is readable under /proc
# (which keeps a script path containing spaces intact), otherwise use <args>.
# For flattened args, prefer the longest space-joined prefix after interpreter
# flags that names an existing file, preserving script paths containing spaces.
fm_auggie_script_arg() {  # <args> [pid]
  local args=$1 pid=${2:-} token index=1 candidate='' script=''
  local live_argv=0 options=1
  local -a words=()
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
    live_argv=1
    while IFS= read -r -d '' token; do
      words+=("$token")
    done < "/proc/$pid/cmdline"
  else
    read -r -a words <<<"$args" || [ "${#words[@]}" -gt 0 ] || return 1
  fi
  while [ "$index" -lt "${#words[@]}" ]; do
    token=${words[index]}
    index=$((index + 1))
    if [ -z "$candidate" ]; then
      if [ "$options" -eq 1 ]; then
        case "$token" in
          -e|--eval|-p|--print|--eval=*|--print=*|-e?*|-p?*) return 1 ;;
          --) options=0; continue ;;
          -*=*) continue ;;
          -r|--require|--import|--loader|--experimental-loader|--inspect-port|--env-file|--title|-C|--conditions|--input-type)
            index=$((index + 1))
            continue
            ;;
          -*) continue ;;
        esac
      fi
      if [ "$live_argv" -eq 1 ]; then
        printf '%s\n' "$token"
        return 0
      fi
      candidate=$token
      script=$token
    else
      candidate="$candidate $token"
    fi
    [ ! -f "$candidate" ] || script=$candidate
  done
  [ -n "$script" ] || return 1
  printf '%s\n' "$script"
}

# True when the process described by command name $1 and full argument string
# $2 is auggie. The single owner of auggie process identity for the session-lock
# ancestry walk (bin/fm-session-lock-lib.sh) and harness detection
# (bin/fm-harness.sh).
#
# Accepted: an exact auggie command name; a node, node-*, node<N>, or MainThread
# interpreter whose script argument resolves to auggie's own name or package.
#
# Rejected: a bare interpreter with no script, an interpreter running anything
# else, and any name or path that merely contains the auggie fragment.
fm_auggie_process_matches() {  # <comm> <args> [pid]
  local comm=$1 args=${2:-} pid=${3:-} base script
  [ -n "$comm" ] || return 1
  base=${comm##*/}
  base=${base#-}
  case "$base" in
    auggie) return 0 ;;
    node|node-*|node[0-9]*|MainThread)
      script=$(fm_auggie_script_arg "$args" "$pid") || return 1
      fm_auggie_path_is_auggie "$script"
      return $?
      ;;
  esac
  return 1
}
