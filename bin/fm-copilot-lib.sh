#!/usr/bin/env bash
# Copilot process identity.
# Sourced by bin/fm-agent-process-lib.sh (and through it the tmux and Herdr
# backends) and by bin/fm-harness.sh's ancestry fallback. This file is sourced
# by scripts and has no side effects on source.
#
# Why one owner: the Copilot CLI ships as a node loader, so a live copilot
# pane presents as an interpreter and nothing about its command NAME says
# copilot. Measured on copilot 1.0.88 with Node v24 on macOS, one worker's
# pane held two processes:
#
#   comm  : node            args: node /Users/<user>/.npm-global/bin/copilot -i ...
#   comm  : /Users/<user>   args: /Users/<user>/.npm-global/lib/node_modules/@github/copilot/node_modules/@github/copilot-darwin-arm64/copilot -i ...
#
# `comm` is node for the loader shim (macOS truncates the native child's comm
# to its 16-byte path prefix), and argv[0] is the interpreter. Only argv[1] -
# the script path - carries the identity, so the liveness classifier has to
# read the arguments rather than the name. This is the same hazard
# bin/fm-gemini-lib.sh exists to close for the Gemini CLI, and the rule here
# is deliberately the same shape: structural only, no subprocess, because
# probing a stranger's binary during a liveness poll is exactly what must not
# happen.
#
# Detection of firstmate's OWN harness uses these structural rules for the
# ancestry fallback. The COPILOT_CLI=1 environment marker in bin/fm-harness.sh
# remains the load-bearing path for the installed loader shape on modern Node.

# True when path $1 carries Copilot's own structural evidence: the file is
# named copilot, or it sits inside the published @github/copilot package
# tree. A directory component merely named `copilot` is never enough on its
# own, and a bare interpreter is always rejected.
fm_copilot_path_is_copilot() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  case "$path" in
    -*) return 1 ;;
  esac
  case "${path##*/}" in
    copilot) return 0 ;;
  esac
  case "$path" in
    */@github/copilot/*) return 0 ;;
  esac
  return 1
}

# True when process $1 has Copilot's structural argv evidence. Linux exposes
# argv as NUL-delimited fields, which preserves a script path containing
# spaces that `ps -o args=` necessarily flattens into an ambiguous string.
fm_copilot_pid_is_copilot() {  # <pid>
  local pid=$1 token argv0='' index=0
  [ -r "/proc/$pid/cmdline" ] || return 1
  while IFS= read -r -d '' token; do
    if [ "$index" -eq 0 ]; then
      argv0=$token
      fm_copilot_path_is_copilot "$argv0" && return 0
      case "${argv0##*/}" in
        node|node-*|node[0-9]*|MainThread) ;;
        *) return 1 ;;
      esac
    else
      case "$token" in
        -*) ;;
        *) fm_copilot_path_is_copilot "$token" && return 0; return 1 ;;
      esac
    fi
    index=$((index + 1))
  done < "/proc/$pid/cmdline"
  return 1
}

# True when the whitespace-separated command line $1 is a Copilot process.
#
# Accepted: a command whose own argv[0] is copilot (a future natively-named
# binary, and the darwin-arm64 native child whose basename is copilot), and
# an interpreter whose first non-flag argument is Copilot's script or package
# path.
#
# Rejected: a bare interpreter with no copilot argument, and any command line
# whose only mention of copilot is a later flag value, a working directory, or
# a prompt string - only argv[0] and the script argument are ever consulted,
# so an unrelated command that merely TALKS about copilot never matches.
fm_copilot_args_are_copilot() {  # <args>
  local args=$1 argv0 rest token
  [ -n "$args" ] || return 1
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  fm_copilot_path_is_copilot "$argv0" && return 0
  case "${argv0##*/}" in
    node|node-*|node[0-9]*|MainThread) ;;
    *) return 1 ;;
  esac
  rest=${args#"$argv0"}
  # The first non-flag token after the interpreter is the script it runs.
  # Node's own options are skipped so `node --max-old-space-size=10000 <script>`
  # still resolves.
  while [ -n "$rest" ]; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    token=${rest%%[[:space:]]*}
    rest=${rest#"$token"}
    case "$token" in
      -*) continue ;;
    esac
    fm_copilot_path_is_copilot "$token" && return 0
    return 1
  done
  return 1
}
