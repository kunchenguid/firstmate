#!/usr/bin/env bash
# Ownership of the per-task cloud state a cloud-placed spawn leaves in the
# control home.
#
# A cloud crewmate cannot read the operator's provider account directly, so
# bin/fm-spawn.sh copies the account credential into
# $FM_HOME/state/<id>.cloud-account/ for the worker lifecycle to stage. Nothing
# owned its removal, so every completed cloud task left a plaintext auth.json
# in the control home indefinitely, contradicting the invariant in
# docs/azure-workers.md that provider-account credentials never enter it.
# This library is that owner; teardown calls it.

# Remove one task's cloud state. Args: state_dir task_id
fm_cloud_state_remove() {
  local state=${1:?cloud state directory is required} id=${2:?task id is required}
  # The credential by name FIRST: rm -rf on the directory would follow neither
  # a symlinked cloud-account nor leave the file if the directory removal
  # fails, so naming it is what actually guarantees it goes.
  rm -f "$state/$id.cloud-account/auth.json" "$state/$id.cloud-account/settings.json" || true
  rm -rf "$state/$id.cloud-account" "$state/$id.cloud-payload" || true
  rm -f "$state/$id.cloud-entrypoint" "$state/$id.cloud-env" \
    "$state/$id.cloud-execute-dispatched" \
    "$state/$id.worker-result.json" "$state/$id.worker-execute.log" \
    "$state/$id.worker-reconcile.json" || true
  # Callers run under `set -e` and finish removing task metadata AFTER this.
  # Aborting there would leave a half-torn-down task AND the credential, so a
  # failure is reported loudly and teardown continues.
  if [ -e "$state/$id.cloud-account/auth.json" ]; then
    echo "error: $id could not remove its staged provider credential at $state/$id.cloud-account/auth.json" >&2
    return 0
  fi
  return 0
}
