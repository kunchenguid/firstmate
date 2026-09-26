#!/usr/bin/env bash
# Hermes Agent process identity.
# Sourced by bin/fm-harness.sh, bin/fm-session-lock-lib.sh, and
# bin/fm-agent-process-lib.sh. This file is sourced by scripts and has no side
# effects on source.
#
# Why one owner: Hermes Agent (Nous Research) is a Python program, and nothing
# about its live command NAME says hermes. Measured on hermes-agent v0.21.5 on
# macOS with the git installer, the installed `~/.local/bin/hermes` is a POSIX
# shell wrapper that execs `<install>/.hermes/bin/hermes`, which in turn execs
# the bundled interpreter with an inline bootstrap:
#
#   comm : /Users/<user>/.hermes/tools/python-3.14.7+.../bin/python3
#   args : python3 -I -c import os, re, sys\012...from hermes_cli.main import main\012... chat -q ...
#
# Both wrappers exec, so the live process is the interpreter and only the
# inline program text carries the identity. A pip or uv install instead runs a
# console-script whose argv[1] is a file literally named `hermes`. The Ink TUI
# runs the agent itself, and so every tool subprocess and the Firstmate plugin,
# in a separate `python -m tui_gateway.entry` child of its node renderer
# (ui-tui/src/gatewayClient.ts). The rule below accepts exactly those three
# structural shapes and nothing looser.
#
# Deliberately NOT a substring match on "hermes": this repository is commonly
# cloned into directories such as ~/code/firstmate-hermes, so every firstmate
# helper (bin/fm-mail.py, a node MCP server, a python test) would otherwise
# carry "hermes" in its arguments and be misread as a live Hermes harness.
# The inline-bootstrap needle `hermes_cli.main import main` is the program
# itself, not a path, so a directory name can never produce it.
#
# Detection of firstmate's OWN harness uses these rules for the ancestry
# fallback; the HERMES_AGENT=true marker in bin/fm-harness.sh is the fast path.

FM_HERMES_BOOTSTRAP_NEEDLE='hermes_cli.main import main'
FM_HERMES_TUI_GATEWAY_MODULE='tui_gateway.entry'

# True when path $1 names the Hermes launcher itself: a file whose basename is
# exactly `hermes` (the pip/uv console script, or a future native binary). A
# directory component merely named hermes is never enough, and a bare
# interpreter is always rejected.
fm_hermes_path_is_hermes() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  case "$path" in -*) return 1 ;; esac
  [ "${path##*/}" = hermes ]
}

# True when basename $1 is a Python interpreter name.
# macOS framework builds run as `.../Python.app/Contents/MacOS/Python`, so the
# capitalized spelling counts too.
fm_hermes_is_python_name() {  # <name>
  case "${1##*/}" in
    python|python[0-9]*|Python|Python[0-9]*|pypy|pypy[0-9]*) return 0 ;;
  esac
  return 1
}

# True when the whitespace-separated command line $1 is a Hermes process.
#
# Accepted:
#   - argv[0] is the hermes launcher (fm_hermes_path_is_hermes);
#   - a Python interpreter whose first non-flag argument is the hermes launcher
#     (pip/uv console script);
#   - a Python interpreter run with -c whose inline program imports
#     hermes_cli.main (the git installer's bootstrap). macOS `ps -o args=`
#     renders the program's newlines as the literal four characters \012, Linux
#     flattens them to spaces; the needle survives both.
#
# Rejected: a bare interpreter with no hermes argument, and any command line
# whose only mention of hermes is a later flag value, a working directory, a
# script path under a hermes-named directory, or a prompt string.
fm_hermes_args_are_hermes() {  # <args>
  local args=$1 argv0 rest token
  [ -n "$args" ] || return 1
  argv0=${args%% *}
  fm_hermes_path_is_hermes "$argv0" && return 0
  fm_hermes_is_python_name "$argv0" || return 1
  rest=${args#"$argv0"}
  # Inline bootstrap: the interpreter must have been handed -c (possibly after
  # -I, -E, -s, -S, -u, -B, -O) and the program text must import the Hermes CLI.
  case " $rest " in
    *" -c "*|*" -"[IEsSuBO]"c "*)
      case "$rest" in
        *"$FM_HERMES_BOOTSTRAP_NEEDLE"*) return 0 ;;
      esac
      return 1
      ;;
  esac
  # Ink TUI gateway: `-m tui_gateway.entry` as the interpreter's module.
  case " $rest " in
    *" -m $FM_HERMES_TUI_GATEWAY_MODULE "*) return 0 ;;
  esac
  # Console script: the first non-flag argument after the interpreter.
  for token in $rest; do
    case "$token" in
      -*) continue ;;
      *) fm_hermes_path_is_hermes "$token"; return ;;
    esac
  done
  return 1
}

# True when process $1 has Hermes's structural argv evidence. Linux exposes
# argv as NUL-delimited fields, which preserves boundaries that `ps -o args=`
# flattens; elsewhere the flattened line is the only surface.
fm_hermes_pid_is_hermes() {  # <pid>
  local pid=$1 token argv0='' index=0 saw_c=0 saw_m=0
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/cmdline" ]; then
    while IFS= read -r -d '' token; do
      if [ "$index" -eq 0 ]; then
        argv0=$token
        fm_hermes_path_is_hermes "$argv0" && return 0
        fm_hermes_is_python_name "$argv0" || return 1
      elif [ "$saw_c" -eq 1 ]; then
        case "$token" in *"$FM_HERMES_BOOTSTRAP_NEEDLE"*) return 0 ;; esac
        return 1
      elif [ "$saw_m" -eq 1 ]; then
        [ "$token" = "$FM_HERMES_TUI_GATEWAY_MODULE" ]
        return
      else
        case "$token" in
          -c|-[IEsSuBO]*c) saw_c=1 ;;
          -m) saw_m=1 ;;
          -*) ;;
          *) fm_hermes_path_is_hermes "$token" && return 0; return 1 ;;
        esac
      fi
      index=$((index + 1))
    done < "/proc/$pid/cmdline"
    return 1
  fi
  fm_hermes_args_are_hermes "$(ps -o args= -p "$pid" 2>/dev/null)"
}
