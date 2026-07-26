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
# This sweep is READ-ONLY and always exits 0. It prints one actionable
# `ISOLATION:` line per task whose live agent process is provably not where its
# record says it is, so bin/fm-bootstrap.sh can surface it in the session-start
# digest exactly like TANGLE.
#
# Evidence discipline (bin/fm-agent-cwd-lib.sh owns the method of record): a
# collapse is reported only from an AUTHORITATIVE /proc reading of the agent
# process. A provider's pane cwd is never promoted to evidence here, because a
# pane field naming the wrong process is precisely what produced a false
# isolation violation on 2026-07-25. A task with no authoritative reading is
# reported only under FM_ISOLATION_VERBOSE=1, as a BOOTSTRAP_INFO fact.
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

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  recorded=$(fm_meta_get "$meta" worktree)
  [ -n "$recorded" ] || continue
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")

  record=$(fm_agent_cwd_verdict "$id" "$backend" "$target" "$PID_INDEX")
  source=$(fm_agent_verdict_field "$record" source)
  if [ "$source" != proc ]; then
    if [ "${FM_ISOLATION_VERBOSE:-0}" = 1 ]; then
      echo "BOOTSTRAP_INFO: isolation for $id is unproven: no live agent process could be identified, and a pane path is only a hint"
    fi
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
  kind=$(fm_meta_get "$meta" kind)
  expected_home=$HOME_REAL
  if [ "$kind" = secondmate ]; then
    expected_declared=$(fm_meta_get "$meta" home)
    [ -n "$expected_declared" ] || expected_declared=$recorded
    expected_home=$(fm_agent_canonical_dir "$expected_declared") || expected_home=$expected_declared
  fi
  declared_home=$(fm_agent_proc_env "$pid" FM_AGENT_OWNER_HOME 2>/dev/null || true)
  if [ -n "$declared_home" ]; then
    declared_real=$(fm_agent_canonical_dir "$declared_home") || declared_real=$declared_home
    if [ "$declared_real" != "$expected_home" ]; then
      echo "ISOLATION: task $id is running as a worker of home $declared_real, not the home that owns it ($expected_home); stop it before it acts on that home's records"
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
    continue
  fi
  echo "ISOLATION: task $id is not in its recorded worktree - agent process $pid is running in $cwd_real instead of $recorded_real; reconcile the record before any disposal or steer"
done

exit 0
