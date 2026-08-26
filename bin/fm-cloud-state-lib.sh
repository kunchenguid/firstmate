#!/usr/bin/env bash
# Ownership of the per-task cloud state a cloud-placed spawn leaves in the home
# the task lives in.
#
# A cloud crewmate cannot read the operator's provider account directly, so
# bin/fm-spawn.sh copies the account credential into
# <task home>/state/<id>.cloud-account/ for the worker lifecycle to stage.
# Nothing owned its removal, so every completed cloud task left a plaintext
# auth.json behind indefinitely, contradicting the invariant in
# docs/azure-workers.md that provider-account credentials never enter the
# control home. This library is that owner; teardown, withdraw, surrender, the
# spawn's rollback and the re-spawn sweep all call it.
#
# ONE ENUMERATION. The per-task file set used to be spelled out in three
# places (here, the re-spawn sweep, and the spawn rollback), so a name added to
# one was invisible to the others. Every name now appears exactly once, below,
# and callers select whole groups. Adding a per-task cloud file means adding it
# to one group here and nowhere else.
#
# WHICH home. Since the compartment-child task-home split, the home a task
# lives in is NOT always the home that owns the elastic-worker controller
# document: a secondmate compartment's child stages its credential in the
# COMPARTMENT's home while every lifecycle command for it runs with FM_HOME on
# the primary. So the caller must pass the state directory of the home the TASK
# lives in, and the removers deliberately do not guess:
#   - bin/fm-spawn.sh passes $STATE, the directory it just staged into.
#   - bin/fm-teardown.sh passes the state directory of the home whose task it
#     is ($STATE for its own task, $sub_state for a secondmate home's child).
#   - bin/fm-worker-lifecycle.sh runs on the primary and cannot know, so the
#     controller tells it: the authorized task home is durable on the queue
#     item and the worker record, and withdraw/surrender echo it back on their
#     receipts. That is the same value the spawn passed to --task-home and the
#     controller authorized under its lock, so stager and remover cannot
#     disagree, and nothing keyed on task id alone can redirect a removal into
#     a home that merely reuses that id.

# --- the one enumeration -----------------------------------------------------
#
# The provider credential BY NAME, first. rm -rf on the directory would follow
# neither a symlinked cloud-account nor leave the file if the directory removal
# failed, so naming it is what actually guarantees it goes.
fm_cloud_state_credential_paths() {  # <state_dir> <task_id>
  printf '%s\n' "$1/$2.cloud-account/auth.json" "$1/$2.cloud-account/settings.json"
}

# The staged transport directories.
fm_cloud_state_transport_dirs() {  # <state_dir> <task_id>
  printf '%s\n' "$1/$2.cloud-account" "$1/$2.cloud-payload"
}

# The persisted convergence handles a later dispatch would otherwise inherit.
fm_cloud_state_dispatch_paths() {  # <state_dir> <task_id>
  printf '%s\n' "$1/$2.cloud-entrypoint" "$1/$2.cloud-env" "$1/$2.cloud-execute-dispatched"
}

# The reports the lifecycle wrote for this task: the captured request stdout
# (which names the leased provider-account home) and the bounded execution's
# returned artifacts.
fm_cloud_state_result_paths() {  # <state_dir> <task_id>
  printf '%s\n' "$1/$2.worker-request.out" "$1/$2.worker-result.json" \
    "$1/$2.worker-execute.log" "$1/$2.worker-reconcile.json" \
    "$1/$2.worker-release.json"
}

# The leased local worktree pointer. It used to be excluded from the task-end
# set on the grounds that teardown removed it with the rest of the task's
# metadata; teardown never mentions the name at all, so it was created by the
# spawn lane and removed by no task-end lane - the exact class of leak this
# owner exists to close, asserted otherwise in a comment. It is in the one set
# now, so every remover covers it.
#
# Consequence worth naming: withdraw and surrender now remove it too, and
# bin/fm-spawn-cloud-monitor.sh reads it when landing an outcome bundle. Both
# commands end the task, and the monitor treats an unreadable pointer as "the
# leased worktree is gone" and keeps the bundle for manual landing rather than
# discarding it, so the loss is a reported landing, never lost commits.
fm_cloud_state_lease_paths() {  # <state_dir> <task_id>
  printf '%s\n' "$1/$2.cloud-worktree"
}
# -----------------------------------------------------------------------------

# Remove one task's cloud state at the end of its life. Args: state_dir task_id
fm_cloud_state_remove() {
  local state=${1:?cloud state directory is required} id=${2:?task id is required}
  local path
  while IFS= read -r path; do
    rm -f "$path" || true
  done <<EOF
$(fm_cloud_state_credential_paths "$state" "$id")
EOF
  while IFS= read -r path; do
    rm -rf "$path" || true
  done <<EOF
$(fm_cloud_state_transport_dirs "$state" "$id")
EOF
  while IFS= read -r path; do
    rm -f "$path" || true
  done <<EOF
$(fm_cloud_state_dispatch_paths "$state" "$id")
$(fm_cloud_state_result_paths "$state" "$id")
$(fm_cloud_state_lease_paths "$state" "$id")
EOF
  # Callers run under `set -e` and finish removing task metadata AFTER this.
  # Aborting there would leave a half-torn-down task AND the credential, so a
  # failure is reported loudly and teardown continues.
  if [ -e "$state/$id.cloud-account/auth.json" ]; then
    echo "error: $id could not remove its staged provider credential at $state/$id.cloud-account/auth.json" >&2
    return 0
  fi
  return 0
}

# The spawn lanes' door onto the same set: the re-spawn sweep (a new generation
# must inherit no part of the previous one) and the rollback of a spawn whose
# worker request was refused after staging. It is a pure delegate: it removes
# exactly what the task-end remover removes, and exists as a distinct name only
# so those two call sites say which lane they are. If it ever stops delegating,
# the enumeration has forked again and that is the bug this owner exists to
# prevent.
#
# The outcome directory is deliberately absent from every group: it is not
# transport, it can hold the only local copy of a crewmate's returned commits,
# and its callers preserve it under a superseded name instead.
fm_cloud_state_remove_generation() {  # <state_dir> <task_id>
  fm_cloud_state_remove "${1:?cloud state directory is required}" "${2:?task id is required}"
}
