#!/usr/bin/env bash
# fm-resource-sample.sh - one resource-sampling pass over this home's tasks.
#
# Usage: fm-resource-sample.sh [<id>...]     (no args = every task with a meta)
#
# Per pass it takes ONE process-table read and ONE machine-memory read, then for
# each task appends a line to state/<id>.resource:
#
#   <epoch>\t<iso>\tpid=<n>\trss_kb=<n>\tfree_mb=… compressor_mb=… swap_used_mb=… memstat_level=…
#
# That is the record that was missing when agents started dying with
# `signal: killed`: the agent's own RSS over its lifetime, and the machine's
# memory pressure at those same moments. Cost is one `ps` plus one `vm_stat` per
# pass regardless of fleet size (~40ms measured), so the watcher can call it on a
# fixed cadence forever; it is never on the spawn path.
#
# It is also the death detector. state/<id>.agentpid records the live agent pid;
# when a task that HAD an agent pid no longer has that process,
# bin/fm-agent-postmortem.sh runs once and writes state/<id>.postmortem - the
# evidence that says WHY it died. A relaunched agent (a new live pid) files the
# old postmortem aside as state/<id>.postmortem.prev, so the surfaced verdict
# always describes the agent that is actually gone.
#
# Tasks on a backend with no pane-pid query (everything but tmux) are skipped:
# no pid, no samples, no postmortem, and fm_res_pane_pid's header says why.
# Read-only against the system; exits 0 even when nothing could be sampled.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-resource-lib.sh
. "$SCRIPT_DIR/fm-resource-lib.sh"

SAMPLES_MAX=${FM_RESOURCE_SAMPLES_MAX:-$FM_RESOURCE_SAMPLES_MAX_DEFAULT}
case "$SAMPLES_MAX" in ''|*[!0-9]*) SAMPLES_MAX=$FM_RESOURCE_SAMPLES_MAX_DEFAULT ;; esac

[ -d "$STATE" ] || exit 0

metas=()
if [ "$#" -gt 0 ]; then
  for id in "$@"; do
    [ -f "$STATE/$id.meta" ] && metas+=("$STATE/$id.meta")
  done
else
  for m in "$STATE"/*.meta; do
    [ -e "$m" ] && metas+=("$m")
  done
fi
[ "${#metas[@]}" -gt 0 ] || exit 0

PS_SNAP=$(fm_res_ps_snapshot)
MEM=$(fm_res_mem_snapshot)
NOW=$(date +%s)
ISO=$(fm_res_now_iso)

for meta in "${metas[@]}"; do
  id=$(basename "$meta" .meta)
  harness=$(fm_res_meta_value "$meta" harness)
  pane_pid=$(fm_res_pane_pid "$meta" 2>/dev/null) || pane_pid=""
  agent_pid=""
  if [ -n "$pane_pid" ] && [ -n "$harness" ]; then
    agent_pid=$(fm_res_agent_pid "$pane_pid" "$harness" "$PS_SNAP" 2>/dev/null) || agent_pid=""
  fi

  pidfile="$STATE/$id.agentpid"
  postmortem="$STATE/$id.postmortem"

  if [ -n "$agent_pid" ]; then
    rss=$(fm_res_rss_kb "$agent_pid" "$PS_SNAP" 2>/dev/null) || rss=unknown
    printf '%s\t%s\tpid=%s\trss_kb=%s\t%s\n' "$NOW" "$ISO" "$agent_pid" "$rss" "$MEM" >> "$STATE/$id.resource"
    fm_res_trim "$STATE/$id.resource" "$SAMPLES_MAX"
    # A postmortem describing a DIFFERENT (dead) pid must not keep being surfaced
    # for the live agent that replaced it. Keep the evidence, stop claiming it.
    if [ -f "$postmortem" ] && [ "$(fm_res_meta_value "$postmortem" agent_pid)" != "$agent_pid" ]; then
      mv -f "$postmortem" "$postmortem.prev" 2>/dev/null || true
    fi
    {
      echo "pid=$agent_pid"
      echo "harness=$harness"
      echo "last_seen=$NOW"
      echo "last_seen_iso=$ISO"
      echo "last_rss_kb=$rss"
      echo "last_mem=$MEM"
    } > "$pidfile"
    continue
  fi

  # No agent process under this task's terminal. Only a task that HAD one is a
  # death: a task whose backend exposes no pane pid, or one sampled before its
  # agent came up, never had an agentpid file and is simply skipped.
  if [ -f "$pidfile" ] && [ ! -f "$postmortem" ]; then
    "$SCRIPT_DIR/fm-agent-postmortem.sh" "$id" >/dev/null 2>&1 || true
  fi
done

exit 0
