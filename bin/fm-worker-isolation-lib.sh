#!/usr/bin/env bash
# bin/fm-worker-isolation-lib.sh - the ONE owner of the launched-agent home
# declaration contract.
#
# A firstmate script resolves its operational home from ambient environment
# (FM_HOME, then the FM_*_OVERRIDE family, then its own FM_ROOT). That
# resolution is correct for a firstmate primary and catastrophic for a task
# child: a crewmate, scout, or audit agent launched from a primary's pane
# inherits that primary's exported FM_HOME, so every firstmate script it runs -
# including bin/fm-lock.sh - resolves the PRIMARY's state directory. A worker
# that then runs session start acquires the primary's session-owner record and
# the real primary is locked out of its own home (incident 2026-07-24).
#
# The fix is a DECLARATION, not a guess: every task child is launched with an
# explicit home environment, and declares which home owns it and in what role.
# Nothing downstream has to infer ownership from cwd, pane, or process tree.
#
#   FM_AGENT_ROLE        crewmate | secondmate  (the declared role)
#   FM_AGENT_TASK        the owning task or secondmate id
#   FM_AGENT_OWNER_HOME  absolute path of the home that launched this agent
#
# `crewmate` covers every ship/scout/audit task child. Such an agent is never a
# firstmate primary anywhere, so it must never own a home, acquire a session
# lock, or fire a primary-home hook - see fm_worker_refuse_primary_operation and
# bin/fm-primary-scope-lib.sh.
#
# `secondmate` is a primary IN ITS OWN HOME and only there, so it keeps a
# concrete FM_HOME while every inheritable override is cleared. Its own
# crewmates are launched by its own bin/fm-spawn.sh and get the crewmate
# treatment against the secondmate's home, which is what keeps a secondmate
# child from ever reaching the primary's home.
#
# The markers are also the backend-independent identity key that
# bin/fm-agent-cwd-lib.sh uses to find the real agent process, so a launch that
# omits them costs authoritative cwd proof as well as home isolation.
#
# docs/worker-isolation.md owns how this mechanism fits with the other three.
#
# This file is sourced by scripts and hook entrypoints and has no side effects
# on source.

# Every operational-home variable a firstmate script reads. Extend here, not at
# a call site, when a new home override is introduced.
FM_WORKER_ISOLATION_HOME_VARS="FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE"

fm_worker_shell_quote() {  # <text>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# fm_worker_launch_env_prefix <role> <task-id> <owner-home>
# Print the exact env-assignment prefix a launch command must carry, with one
# trailing space, so a caller composes `<prefix><launch command>`. Refuses an
# unknown role, an empty id, or a non-absolute home rather than emitting a
# partial prefix that would leave the child inheriting a home.
fm_worker_launch_env_prefix() {
  local role=$1 id=$2 home=$3 var
  case "$role" in
    crewmate|secondmate) ;;
    *) echo "error: unknown agent role '$role'; expected crewmate or secondmate" >&2; return 1 ;;
  esac
  [ -n "$id" ] || { echo "error: agent role $role requires a task id" >&2; return 1; }
  case "$home" in
    /*) ;;
    *) echo "error: agent role $role requires an absolute owning home, got '${home:-<empty>}'" >&2; return 1 ;;
  esac
  for var in $FM_WORKER_ISOLATION_HOME_VARS; do
    if [ "$var" = FM_HOME ] && [ "$role" = secondmate ]; then
      printf 'FM_HOME=%s ' "$(fm_worker_shell_quote "$home")"
    else
      printf '%s= ' "$var"
    fi
  done
  printf 'FM_AGENT_ROLE=%s ' "$role"
  printf 'FM_AGENT_TASK=%s ' "$(fm_worker_shell_quote "$id")"
  printf 'FM_AGENT_OWNER_HOME=%s ' "$(fm_worker_shell_quote "$home")"
}

# fm_worker_declared_role: the current process's declared role, or empty when
# it declares none (a primary firstmate, or a pre-declaration legacy agent).
fm_worker_declared_role() {
  case "${FM_AGENT_ROLE:-}" in
    crewmate|secondmate) printf '%s' "$FM_AGENT_ROLE" ;;
  esac
}

# fm_worker_is_task_worker: 0 when this process is a declared task child that
# must never act as a firstmate primary in any home.
fm_worker_is_task_worker() {
  [ "${FM_AGENT_ROLE:-}" = crewmate ]
}

# fm_worker_owning_home: the home that declared this agent, or empty.
fm_worker_owning_home() {
  printf '%s' "${FM_AGENT_OWNER_HOME:-}"
}

# fm_worker_refuse_primary_operation <operation>
# Fail closed with one actionable line when a declared task worker attempts an
# operation only a home's primary may perform. Silent and successful for every
# other process, so a call site can guard unconditionally.
fm_worker_refuse_primary_operation() {
  local operation=$1
  fm_worker_is_task_worker || return 0
  echo "error: $operation refused: this process is task worker '${FM_AGENT_TASK:-unnamed}' launched by ${FM_AGENT_OWNER_HOME:-an unrecorded home}; a task worker never owns a firstmate operational home" >&2
  return 1
}
