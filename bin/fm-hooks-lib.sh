#!/usr/bin/env bash
# fm-hooks-lib.sh - sourced helpers through which Firstmate's lifecycle scripts
# call installed lifecycle hooks (bin/fm-hooks.sh runs them).
#
# Sourced, never executed, with no side effects on source. This file is the
# single owner of WHERE hooks live; bin/fm-hooks.sh owns how they run and what
# each event's exit status and output mean.
#
# Hook folders, in run order:
#   1. "$FM_HOME/hooks/<event>.d/"          installed per home, by hand or by an
#                                           add-on installer.
#   2. "$FM_HOOKS_EXTRA_DIR/<event>.d/"     only when FM_HOOKS_EXTRA_DIR is set.
# The checkout's own hooks/ folder is deliberately not searched implicitly: a
# primary home is often the checkout itself, and every other home and every
# test run from that checkout runs the checkout's bin/, so an implicit checkout
# folder would run one home's installed hooks for all of them. No hooks ship
# in this repository, so nothing is lost; the second folder is the explicit
# opt-in for a shared set.
#
#   fm_hooks_present <event>
#       0 when at least one hook folder for <event> exists. A pure file test
#       that forks nothing, so a call site that finds no folder costs one
#       directory test and behaves exactly as it did before hooks existed.
#       The caller's FM_HOME selects the home; an empty FM_HOME disables only
#       the home folder, not an explicit FM_HOOKS_EXTRA_DIR.
#
#   fm_hooks_dirs <event>
#       Prints each existing hook folder for <event>, one per line, in run
#       order. The same folder named twice is printed once.
#
#   fm_hooks_payload [key=value | key:=json]...
#       Prints one compact JSON object. key=value stores value as a JSON string
#       (escaped here, so any bytes are safe); key:=json stores a raw JSON
#       literal the caller vouches for (true, false, null, a number).
#
#   fm_hooks_emit <event> [key=value | key:=json]...
#       When fm_hooks_present is false: returns 0 at once, prints nothing and
#       reads nothing. Otherwise builds the payload with fm_hooks_payload,
#       runs `bin/fm-hooks.sh run <event>` with it on stdin and FM_HOME
#       exported, passes that runner's stdout and stderr through, and returns
#       its exit status (bin/fm-hooks.sh owns those codes).
#
#   fm_hooks_emit_json <event> <json>
#       fm_hooks_emit with a payload the caller already built as one JSON
#       object (for text a key=value argument cannot carry exactly, such as a
#       trailing newline).

FM_HOOKS_LIB_DIR=${FM_HOOKS_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

fm_hooks_present() {  # <event>
  [ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME/hooks/$1.d" ] && return 0
  [ -n "${FM_HOOKS_EXTRA_DIR:-}" ] && [ -d "$FM_HOOKS_EXTRA_DIR/$1.d" ] && return 0
  return 1
}

fm_hooks_dirs() {  # <event>
  local first=''
  if [ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME/hooks/$1.d" ]; then
    first=$(cd "$FM_HOME/hooks/$1.d" && pwd -P) || first=''
    [ -z "$first" ] || printf '%s\n' "$first"
  fi
  if [ -n "${FM_HOOKS_EXTRA_DIR:-}" ] && [ -d "$FM_HOOKS_EXTRA_DIR/$1.d" ]; then
    local second
    second=$(cd "$FM_HOOKS_EXTRA_DIR/$1.d" && pwd -P) || second=''
    [ -z "$second" ] || [ "$second" = "$first" ] || printf '%s\n' "$second"
  fi
  return 0
}

fm_hooks_json_string() {  # <text>: print it as one JSON string literal
  local s=$1 out='' c i
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  case $s in
    *[$'\001'-$'\037']*)
      for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case $c in
          [$'\001'-$'\037']) out+=$(printf '\\u%04x' "'$c") ;;
          *) out+=$c ;;
        esac
      done
      s=$out
      ;;
  esac
  printf '"%s"' "$s"
}

fm_hooks_payload() {  # [key=value | key:=json]...
  local field key sep='' body=''
  for field in "$@"; do
    case $field in *=*) ;; *) continue ;; esac
    key=${field%%=*}
    case $key in
      *:) body+="$sep$(fm_hooks_json_string "${key%:}"):${field#*=}" ;;
      *) body+="$sep$(fm_hooks_json_string "$key"):$(fm_hooks_json_string "${field#*=}")" ;;
    esac
    sep=,
  done
  printf '{%s}\n' "$body"
}

fm_hooks_emit() {  # <event> [key=value | key:=json]...
  local event=$1
  shift
  fm_hooks_present "$event" || return 0
  fm_hooks_payload "$@" | FM_HOME="$FM_HOME" "$FM_HOOKS_LIB_DIR/fm-hooks.sh" run "$event"
}

fm_hooks_emit_json() {  # <event> <json>
  fm_hooks_present "$1" || return 0
  printf '%s\n' "$2" | FM_HOME="$FM_HOME" "$FM_HOOKS_LIB_DIR/fm-hooks.sh" run "$1"
}
