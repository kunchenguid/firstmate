#!/usr/bin/env bash
# Gemini process identity.
# Sourced by bin/backends/tmux.sh. This file is sourced by scripts and has no
# side effects on source.
#
# Why one owner: the Gemini CLI ships as a node bundle, so a live gemini pane
# presents as an interpreter and nothing about its command NAME says gemini.
# Measured on gemini-cli 0.58.0 with Node v24.20.0 on Linux, one worker's
# foreground process group read:
#
#   comm  : MainThread
#   argv0 : /home/<user>/.local/node/bin/node
#   args  : node /home/<user>/.local/bin/gemini -y
#
# `comm` is MainThread because modern Node renames its main thread, and argv[0]
# is the interpreter. Only argv[1] - the script path - carries the identity, so
# the liveness classifier has to read the arguments rather than the name. This
# is the same hazard bin/fm-cursor-lib.sh exists to close for cursor-agent, and
# the rule here is deliberately the same shape: structural only, no subprocess,
# because probing a stranger's binary during a liveness poll is exactly what
# must not happen.
#
# Detection of firstmate's OWN harness does not come through here. That uses
# the GEMINI_CLI=1 environment marker in bin/fm-harness.sh, which is a separate
# and independent signal, so no single source is load-bearing on its own.

# True when path $1 carries Gemini's own structural evidence: the file is named
# gemini, or it sits inside the published @google/gemini-cli package tree. A
# directory component merely named `gemini` is never enough on its own, and a
# bare interpreter is always rejected.
fm_gemini_path_is_gemini() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  case "$path" in
    -*) return 1 ;;
  esac
  case "${path##*/}" in
    gemini) return 0 ;;
  esac
  case "$path" in
    */@google/gemini-cli/*) return 0 ;;
  esac
  return 1
}

# True when the whitespace-separated command line $1 is a Gemini process.
#
# Accepted: a command whose own argv[0] is gemini (a future natively-named
# binary), and an interpreter whose first non-flag argument is Gemini's script
# or package path.
#
# Rejected: a bare interpreter with no gemini argument, and any command line
# whose only mention of gemini is a later flag value, a working directory, or a
# prompt string - only argv[0] and the script argument are ever consulted, so
# an unrelated command that merely TALKS about gemini never matches.
fm_gemini_args_are_gemini() {  # <args>
  local args=$1 argv0 rest token
  [ -n "$args" ] || return 1
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  fm_gemini_path_is_gemini "$argv0" && return 0
  case "${argv0##*/}" in
    node|node-*|node[0-9]*|MainThread) ;;
    *) return 1 ;;
  esac
  rest=${args#"$argv0"}
  # The first non-flag token after the interpreter is the script it runs.
  # Node's own options are skipped so `node --max-old-space-size=10000 <script>`
  # - the exact shape the installed launcher execs - still resolves.
  while [ -n "$rest" ]; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    token=${rest%%[[:space:]]*}
    rest=${rest#"$token"}
    case "$token" in
      -*) continue ;;
    esac
    fm_gemini_path_is_gemini "$token" && return 0
    return 1
  done
  return 1
}
