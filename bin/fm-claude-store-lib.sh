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
#      must be an absolute path to an existing directory. It launches with that
#      store and records it, replacing any earlier record.
#   2. Otherwise a non-empty claude_config_dir= in the task's existing
#      state/<id>.meta wins, and the ambient CLAUDE_CONFIG_DIR is ignored for
#      this task. A recorded directory that no longer exists refuses the launch
#      rather than silently falling back to another store.
#   3. Otherwise (a first spawn, or a task recorded without a store) the ambient
#      CLAUDE_CONFIG_DIR is used and recorded exactly as it was forwarded before
#      this contract existed. An unset or empty ambient value records nothing
#      and launches on Claude's own default store.
# For a non-claude launch the store is not used: no override is applied and an
# existing record is carried forward unchanged, so switching a task back to
# claude later still lands on its recorded account.
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
#     and record (possibly empty). On refusal returns 1 and sets
#     FM_CLAUDE_STORE_ERROR to a one-line reason.

FM_CLAUDE_STORE=
FM_CLAUDE_STORE_ERROR=

# Echoes the last claude_config_dir= value in <meta>, or nothing.
fm_claude_store_recorded() {
  local meta=$1 line value=''
  [ -n "$meta" ] && [ -f "$meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    claude_config_dir=*) value=${line#*=} ;;
    esac
  done <"$meta" 2>/dev/null || true
  printf '%s' "$value"
}

# shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
fm_claude_store_resolve() {
  local harness=$1 meta=${2:-} recorded override
  FM_CLAUDE_STORE=
  FM_CLAUDE_STORE_ERROR=
  recorded=$(fm_claude_store_recorded "$meta")
  if [ "$harness" != claude ]; then
    FM_CLAUDE_STORE=$recorded
    return 0
  fi
  override=${FM_CLAUDE_CONFIG_DIR:-}
  if [ -n "$override" ]; then
    case "$override" in
    /*) ;;
    *)
      FM_CLAUDE_STORE_ERROR="FM_CLAUDE_CONFIG_DIR '$override' is not an absolute path; name the Claude config store directory absolutely"
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
  if [ -n "$recorded" ]; then
    [ -d "$recorded" ] || {
      FM_CLAUDE_STORE_ERROR="the task's recorded Claude config store '$recorded' (claude_config_dir= in $meta) no longer exists; refusing rather than launching on a different account - restore that directory or relaunch with FM_CLAUDE_CONFIG_DIR=<store> to choose one deliberately"
      return 1
    }
    FM_CLAUDE_STORE=$recorded
    return 0
  fi
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    FM_CLAUDE_STORE=$CLAUDE_CONFIG_DIR
  fi
  return 0
}
