#!/usr/bin/env bash
# Stop one explicitly named, pre-existing, empty Herdr session that this
# helper did not create and does not own.
#
# Usage:
#   fm-herdr-session-retire.sh <session>
#
# Retirement means stop-only: this helper never deletes a session, starts a
# server, restarts anything, or touches project clones. It is a narrow guarded
# owner for one-off operational retirement of a session Firstmate did not
# provision, distinct from bin/fm-herdr-lab.sh, whose generated `fm-lab-*`
# sessions it structurally cannot adopt.
#
# The target must be the exact argument given: no ambient-only HERDR_SESSION
# selection. It refuses the literal `default`, the literal `fm-remote`, and
# every `fm-lab-*` name. It requires exactly one session with that name, with
# default:false and running:true, and requires that session's own workspace
# list to be empty; an empty workspace list rules out every tab, pane, and
# agent too, since each lives only inside a workspace this API can enumerate.
# It canonically snapshots every OTHER session (this is what protects
# `default`, `fm-remote`, and anything else, with no separate preserve-list
# interface) and re-runs every one of the checks above immediately before the
# single destructive call, refusing on any drift or unreadable state. Herdr has
# no conditional stop, so these checks are best-effort: callers must rule out a
# concurrent writer that could repopulate the target after the final check.
# After stopping, it requires the target to remain present with running:false and
# every other session to still match the pre-stop snapshot before reporting
# success. Any failed precondition or postcondition is a nonzero exit; there
# is no fallback, force, delete, or restart path.
set -u

fm_herdr_retire_error() {
  echo "fm-herdr-session-retire: $*" >&2
}

fm_herdr_retire_validate_name() { # <session>
  local name=${1:-}
  case "$name" in
    '')
      fm_herdr_retire_error "refusing an empty session name"
      return 1
      ;;
    default)
      fm_herdr_retire_error "refusing session name 'default'"
      return 1
      ;;
    fm-remote)
      fm_herdr_retire_error "refusing session name 'fm-remote'"
      return 1
      ;;
    fm-lab-*)
      fm_herdr_retire_error "refusing a generated lab session name; use bin/fm-herdr-lab.sh teardown instead: $name"
      return 1
      ;;
  esac
  return 0
}

fm_herdr_retire_raw() { # <session> <herdr arguments...>
  local name=$1
  shift
  HERDR_SESSION="$name" herdr "$@" --session "$name"
}

fm_herdr_retire_session_list() { # <session>
  fm_herdr_retire_raw "$1" session list --json
}

# Zero workspaces in the target's own session structurally means zero tabs,
# panes, and agents too: each of those lives only inside a workspace this API
# can enumerate, so a workspace list of length zero already rules out every
# one of them without a separate call per axis.
fm_herdr_retire_target_is_empty() { # <session>
  local name=$1 list
  list=$(fm_herdr_retire_raw "$name" workspace list 2>/dev/null) || return 1
  printf '%s' "$list" | jq -e '
    (.result.workspaces | type) == "array" and ((.result.workspaces | length) == 0)
  ' >/dev/null 2>&1
}

# Canonical snapshot of every session except <session>: name, default,
# running, socket_path, sorted by name. Fails closed (nonzero, no output) when
# <sessions-json> does not carry a readable `.sessions` array.
fm_herdr_retire_snapshot_others() { # <session> <sessions-json>
  local name=$1 sessions=$2
  printf '%s' "$sessions" | jq -cS --arg name "$name" '
    if (.sessions | type) != "array" then error("sessions field missing or malformed") else . end
    | [.sessions[] | select(.name != $name) | {name, default, running, socket_path}]
    | sort_by(.name)
  ' 2>/dev/null
}

# One full precondition pass: exactly one target row, default:false,
# running:true, an empty target, and a canonical snapshot of every other
# session. Prints that snapshot on success. Called twice by
# fm_herdr_retire_stop with fully fresh reads so a caller can compare them and
# refuse on any drift between the two passes.
fm_herdr_retire_precheck() { # <session>
  local name=$1 sessions count default running others
  sessions=$(fm_herdr_retire_session_list "$name" 2>/dev/null) || {
    fm_herdr_retire_error "cannot list Herdr sessions for '$name'"
    return 1
  }
  count=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
    '[.sessions[]? | select(.name == $name)] | length' 2>/dev/null)
  [ "$count" = 1 ] || {
    fm_herdr_retire_error "refusing '$name': expected exactly one matching session in the Herdr session list, found ${count:-<unreadable>}"
    return 1
  }
  default=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
    '.sessions[]? | select(.name == $name) | .default' 2>/dev/null)
  running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
    '.sessions[]? | select(.name == $name) | .running' 2>/dev/null)
  [ "$default" = false ] || {
    fm_herdr_retire_error "refusing '$name': session reports default=${default:-<unreadable>}"
    return 1
  }
  [ "$running" = true ] || {
    fm_herdr_retire_error "refusing '$name': session reports running=${running:-<unreadable>}"
    return 1
  }
  fm_herdr_retire_target_is_empty "$name" || {
    fm_herdr_retire_error "refusing '$name': the target session is not empty"
    return 1
  }
  others=$(fm_herdr_retire_snapshot_others "$name" "$sessions") || {
    fm_herdr_retire_error "cannot snapshot the other Herdr sessions"
    return 1
  }
  printf '%s\n' "$others"
}

fm_herdr_retire_stop() { # <session>
  local name=$1 before after sessions running
  fm_herdr_retire_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_retire_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_retire_error "jq is required"; return 1; }

  before=$(fm_herdr_retire_precheck "$name") || return 1

  # Immediately before the destructive call: fully fresh reads, refuse on any
  # drift in either the target or every other session.
  after=$(fm_herdr_retire_precheck "$name") || return 1
  [ "$before" = "$after" ] || {
    fm_herdr_retire_error "refusing to stop '$name': another Herdr session changed between checks"
    return 1
  }

  fm_herdr_retire_raw "$name" session stop "$name" --json >/dev/null || {
    fm_herdr_retire_error "herdr session stop failed for '$name'"
    return 1
  }

  sessions=$(fm_herdr_retire_session_list "$name" 2>/dev/null) || {
    fm_herdr_retire_error "cannot confirm the outcome of stopping '$name'"
    return 1
  }
  running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
    '[.sessions[]? | select(.name == $name) | .running] | if length == 1 then .[0] else "absent" end' 2>/dev/null) || running=
  [ "$running" = false ] || {
    fm_herdr_retire_error "'$name' did not report stopped after the stop call (running=${running:-<unreadable>})"
    return 1
  }
  after=$(fm_herdr_retire_snapshot_others "$name" "$sessions") || {
    fm_herdr_retire_error "cannot confirm every other Herdr session after stopping '$name'"
    return 1
  }
  [ "$before" = "$after" ] || {
    fm_herdr_retire_error "another Herdr session changed while stopping '$name'; refusing to report success"
    return 1
  }
  printf 'stopped %s\n' "$name"
}

fm_herdr_retire_usage() {
  sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_herdr_retire_main() {
  case "${1:-}" in
    --help)
      fm_herdr_retire_usage
      return 0
      ;;
  esac
  [ "$#" -eq 1 ] || { fm_herdr_retire_usage >&2; return 2; }
  fm_herdr_retire_stop "$1"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  fm_herdr_retire_main "$@"
fi
