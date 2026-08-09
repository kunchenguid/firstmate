#!/usr/bin/env bash
# fm-isolation-sweep.sh - re-assert task-worker isolation for a whole home,
# after a restart, restore, or resume.
#
# Spawn asserts isolation once, at launch. That assertion does not survive a
# restore: after the 2026-07-24 reboot a session provider restored every pane by
# resuming its recorded agent session but resolved each working directory back
# to the repository the worktree was derived from, collapsing 17 of 17 isolated
# worktrees onto their origin - four of them into the firstmate PRIMARY
# checkout. Isolation therefore has to be re-established from live evidence on
# every resume, not assumed from the launch that happened before the reboot.
#
# This sweep is READ-ONLY and exits nonzero when isolation is actionable or its
# required process evidence is unproven. It prints one `ISOLATION:` line per
# such task so bin/fm-bootstrap.sh can block mutation until the home is safe.
#
# Evidence discipline (bin/fm-agent-cwd-lib.sh owns the method of record): a
# collapse is reported only from an AUTHORITATIVE /proc reading of the agent
# process. A provider's pane cwd is never promoted to evidence here, because a
# pane field naming the wrong process is precisely what produced a false
# isolation violation on 2026-07-25. A task with no authoritative reading is
# an unproven isolation finding; verbose mode adds a BOOTSTRAP_INFO fact.
#
# The block is scoped to records whose endpoint could still be running a worker.
# An endpoint the provider reports as gone (missing pane/window) or agent-less
# (a bare shell) cannot have a worker acting on it at all, so such a stale
# record is reported as a BOOTSTRAP_INFO fact instead of halting every mutation
# in the home. An endpoint that cannot be read is not proof of absence and
# still blocks.
#
# docs/worker-isolation.md owns how this mechanism fits with the other three.
#
# Usage: fm-isolation-sweep.sh
#   FM_ISOLATION_VERBOSE=1  also print BOOTSTRAP_INFO facts for tasks whose
#                           isolation could not be proved either way.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-agent-cwd-lib.sh
. "$SCRIPT_DIR/fm-agent-cwd-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

case "${1:-}" in
  -h|--help)
    sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

[ -d "$STATE" ] || exit 0

HOME_REAL=$(fm_agent_canonical_dir "$FM_HOME") || HOME_REAL=$FM_HOME
ROOT_REAL=$(fm_agent_canonical_dir "$FM_ROOT") || ROOT_REAL=$FM_ROOT

# One /proc walk for the whole sweep, reused for every task below. Asking per
# task instead costs a full walk each time - O(tasks x processes) of forked
# environment reads on the session-start critical path, and the incident this
# sweep exists for had 17 concurrent tasks. An empty index is a real answer (no
# live process declares a task), not a missing one.
PID_INDEX=$(fm_agent_task_pid_index) || PID_INDEX=
sweep_status=0

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  recorded=$(fm_meta_get "$meta" worktree)
  [ -n "$recorded" ] || continue
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  kind=$(fm_meta_get "$meta" kind)
  expected_home=$HOME_REAL
  if [ "$kind" = secondmate ]; then
    expected_declared=$(fm_meta_get "$meta" home)
    [ -n "$expected_declared" ] || expected_declared=$recorded
    expected_home=$(fm_agent_canonical_dir "$expected_declared") || expected_home=$expected_declared
  fi

  owner_conflict=$(fm_agent_task_owner_conflict "$id" "$PID_INDEX" "$expected_home" || true)
  if [ -n "$owner_conflict" ]; then
    if [ "$owner_conflict" = '<missing>' ]; then
      echo "ISOLATION: task $id has a live process with incomplete owner-home proof; stop it before it acts on this home's records"
    elif [ "$owner_conflict" = '<unknown>' ]; then
      echo "ISOLATION: task $id has a live process with unverified process-identity proof; stop it before it acts on this home's records"
    else
      echo "ISOLATION: task $id has a live process declaring foreign owner home $owner_conflict; stop it before it acts on this home's records"
    fi
    sweep_status=1
    continue
  fi

  record=$(fm_agent_cwd_verdict "$id" "$backend" "$target" "$PID_INDEX" "$expected_home")
  source=$(fm_agent_verdict_field "$record" source)
  if [ "$source" != proc ]; then
    # Unproven isolation blocks the fleet, but only while the task's endpoint
    # could still be running something. A record whose endpoint is PROVABLY
    # gone - the window or pane no longer exists, or its foreground is a bare
    # shell - has no worker that could be writing anywhere, so it is reported
    # as a fact rather than dropping the whole session to read-only. Anything
    # else, including an endpoint that cannot be read, still fails closed.
    endpoint_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)
    case "$endpoint_state" in
      missing|dead|no-agent)
        if [ "${FM_ISOLATION_VERBOSE:-0}" = 1 ]; then
          echo "BOOTSTRAP_INFO: isolation for $id is unproven but its endpoint ${target:-<none>} is ${endpoint_state}, not live: no worker can be acting on this record; reconcile or tear it down"
        fi
        continue
        ;;
    esac
    echo "ISOLATION: task $id isolation is unproven: no live agent process could be identified, and a pane path is only a hint; block mutation until the endpoint and worker identity are re-established"
    if [ "${FM_ISOLATION_VERBOSE:-0}" = 1 ]; then
      echo "BOOTSTRAP_INFO: isolation for $id is unproven: no live agent process could be identified, and a pane path is only a hint"
    fi
    sweep_status=1
    continue
  fi
  pid=$(fm_agent_verdict_field "$record" pid)
  cwd=$(fm_agent_verdict_field "$record" cwd)
  cwd_real=$(fm_agent_canonical_dir "$cwd") || cwd_real=$cwd

  # A resumed agent that carries a declared owning home from another home is the
  # inheritance defect itself, not merely a misplaced cwd.
  #
  # The home a record EXPECTS is not always this one. A secondmate is
  # deliberately launched with FM_AGENT_OWNER_HOME set to its OWN home while its
  # record lives in the launching primary's state directory, because it is the
  # primary of that home and only there (bin/fm-worker-isolation-lib.sh).
  # Comparing it against this home would report every healthy secondmate in the
  # fleet as a foreign worker on every session start, so the expected owner is
  # taken from the record itself.
  declared_home=$(fm_agent_proc_env "$pid" FM_AGENT_OWNER_HOME 2>/dev/null || true)
  if [ -n "$declared_home" ]; then
    declared_real=$(fm_agent_canonical_dir "$declared_home") || declared_real=$declared_home
    if [ "$declared_real" != "$expected_home" ]; then
      echo "ISOLATION: task $id is running as a worker of home $declared_real, not the home that owns it ($expected_home); stop it before it acts on that home's records"
      sweep_status=1
      continue
    fi
  fi

  recorded_real=$(fm_agent_canonical_dir "$recorded") || recorded_real=$recorded
  if fm_agent_path_within "$recorded_real" "$cwd_real"; then
    if [ "${FM_ISOLATION_VERBOSE:-0}" = 1 ]; then
      echo "BOOTSTRAP_INFO: isolation for $id proved from agent process $pid in $cwd_real"
    fi
    continue
  fi

  if fm_agent_path_within "$ROOT_REAL" "$cwd_real" || fm_agent_path_within "$HOME_REAL" "$cwd_real"; then
    echo "ISOLATION: task $id collapsed onto the primary checkout - agent process $pid is running in $cwd_real instead of its worktree $recorded_real; stop that worker before it writes, then relaunch it in an isolated worktree"
    sweep_status=1
    continue
  fi
  echo "ISOLATION: task $id is not in its recorded worktree - agent process $pid is running in $cwd_real instead of $recorded_real; reconcile the record before any disposal or steer"
  sweep_status=1
done

exit "$sweep_status"
