# shellcheck shell=bash
# Durable Claude config-store selection for a task (the claude_config_dir= field).
#
# A Claude account is selected only by CLAUDE_CONFIG_DIR, and a pane created by
# a long-lived backend daemon does not inherit the spawning process's
# environment, so bin/fm-spawn.sh forwards the store onto every claude launch.
# The ambient value alone is not durable: on a machine whose shell exports a
# per-directory CLAUDE_CONFIG_DIR, whatever process later relaunches a task (the
# session-start secondmate liveness sweep, bin/fm-control.sh relaunch,
# fm-spawn.sh --relaunch, or a repeat fm-spawn.sh <id> --secondmate) carries ITS
# OWN store, not the one the task was launched on. This library is the single
# owner of which store a claude launch uses and what the task record says.
#
# Contract, evaluated for one claude launch of one task:
#   1. FM_CLAUDE_CONFIG_DIR, when set non-empty, is the deliberate override. It
#      must be an absolute path to an existing directory, or the literal
#      'default' to return the task to Claude's own default store. It launches
#      with that store and records it, replacing any earlier record.
#   2. Otherwise a non-empty claude_config_dir= in the task's existing
#      state/<id>.meta wins, and the ambient CLAUDE_CONFIG_DIR is ignored for
#      this task. A recorded directory that no longer exists refuses the launch
#      rather than silently falling back to another store. The recorded marker
#      value 'default' means Claude's own default store: the launch removes
#      CLAUDE_CONFIG_DIR from its environment instead of adopting the ambient one.
#   3. Otherwise (a first spawn, or a task recorded without a store) the ambient
#      CLAUDE_CONFIG_DIR is used and recorded exactly as it was forwarded before
#      this contract existed. An unset or empty ambient value records the
#      'default' marker.
# For a non-claude launch the store is not used: no override is applied and an
# existing record is carried forward unchanged, so switching a task back to
# claude later still lands on its recorded account.
# A store chosen by a Claude worker account pin is recorded with
# claude_config_pinned=1. That provenance travels with the record under rule 2
# (and through a non-claude launch), so a launch on it keeps shedding the
# ambient credentials and provider selectors Claude ranks above the store's
# login even after the pin is removed. An override or an ambient store carries
# no provenance and is launched with the environment it was given.
#
# Callers: bin/fm-spawn.sh resolves before any endpoint, worktree, or trust
# registration exists, exports the result as CLAUDE_CONFIG_DIR for the trust
# helper and the launch, and writes claude_config_dir= into the task record.
# bin/fm-control.sh relaunch resolves the same answer BEFORE stopping the old
# agent, so a refusal never leaves a task stopped with no replacement. Remote
# secondmates are placed by their own host-side leg and are not governed here.
#
# Usage: . bin/fm-claude-store-lib.sh
#   fm_claude_store_resolve <harness> [<existing-meta-file>]
#     On success returns 0 and sets FM_CLAUDE_STORE to the store to launch with
#     and record: a directory, the 'default' marker, or empty for a non-claude
#     launch with no record, and sets FM_CLAUDE_STORE_PINNED to 1 when that
#     store is a reused pin-derived record (empty otherwise). On refusal returns
#     1 and sets FM_CLAUDE_STORE_ERROR to a one-line reason.

FM_CLAUDE_STORE=
FM_CLAUDE_STORE_PINNED=
FM_CLAUDE_STORE_ERROR=

# Echoes the last claude_config_dir= value in <meta>, or nothing. Needs
# fm_meta_get from bin/fm-backend.sh, which every caller sources first.
fm_claude_store_recorded() {
  local meta=$1
  [ -n "$meta" ] || return 0
  fm_meta_get "$meta" claude_config_dir
}

# shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
fm_claude_store_resolve() {
  local harness=$1 meta=${2:-} recorded pinned="" override
  FM_CLAUDE_STORE=
  FM_CLAUDE_STORE_PINNED=
  FM_CLAUDE_STORE_ERROR=
  recorded=$(fm_claude_store_recorded "$meta")
  if [ -n "$recorded" ] && [ "$(fm_meta_get "$meta" claude_config_pinned)" = 1 ]; then
    pinned=1
  fi
  if [ "$harness" != claude ]; then
    FM_CLAUDE_STORE=$recorded
    FM_CLAUDE_STORE_PINNED=$pinned
    return 0
  fi
  override=${FM_CLAUDE_CONFIG_DIR:-}
  if [ -n "$override" ]; then
    case "$override" in
    default)
      FM_CLAUDE_STORE=default
      return 0
      ;;
    /*) ;;
    *)
      FM_CLAUDE_STORE_ERROR="FM_CLAUDE_CONFIG_DIR '$override' is not an absolute path; name the Claude config store directory absolutely, or use 'default' for Claude's own default store"
      return 1
      ;;
    esac
    [ -d "$override" ] || {
      FM_CLAUDE_STORE_ERROR="FM_CLAUDE_CONFIG_DIR '$override' is not an existing directory; refusing to launch on a Claude config store that does not exist"
      return 1
    }
    FM_CLAUDE_STORE=$override
    return 0
  fi
  if [ "$recorded" = default ]; then
    FM_CLAUDE_STORE=default
    FM_CLAUDE_STORE_PINNED=$pinned
    return 0
  fi
  if [ -n "$recorded" ]; then
    [ -d "$recorded" ] || {
      FM_CLAUDE_STORE_ERROR="the task's recorded Claude config store '$recorded' (claude_config_dir= in $meta) no longer exists; refusing rather than launching on a different account - restore that directory or relaunch with FM_CLAUDE_CONFIG_DIR=<store> (or 'default') to choose one deliberately"
      return 1
    }
    FM_CLAUDE_STORE=$recorded
    FM_CLAUDE_STORE_PINNED=$pinned
    return 0
  fi
  FM_CLAUDE_STORE=${CLAUDE_CONFIG_DIR:-default}
  return 0
}
