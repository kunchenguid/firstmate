#!/usr/bin/env bash
# Arm a watcher check that wakes firstmate when a set of PRs becomes
# bors-ready. Writes a thin per-task shim (state/<id>.check.sh), a data
# sidecar listing the PRs (state/<id>.prs), and binds the shim's bytes with
# fm-check-register.sh so the watcher may execute it.
#
# Usage: fm-pr-ready-arm.sh <id> <pr>...
#   <id>   task id for this watch (state/<id>.check.sh); reuse to re-arm
#   <pr>   bare PR number (repo from FM_PR_READY_REPO) or owner/repo#number
#
# The PR list lives in the .prs sidecar, so editing it later needs no
# re-registration; editing the shim itself (this template) does. The watcher
# executes a hash-verified snapshot of the shim, possibly from a different
# location than where it was armed, so the id and the sidecar's arm-time path
# are both baked into the shim literally rather than recomputed relative to
# the snapshot's own location.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: usage: fm-pr-ready-arm.sh <id> <pr>..." >&2
  exit 2
fi
ID=$1
shift
fm_task_id_creation_valid "$ID" || { echo "error: invalid id: $ID" >&2; exit 2; }
[ "$#" -ge 1 ] || { echo "error: no PRs given" >&2; exit 2; }

mkdir -p "$STATE" 2>/dev/null || { echo "error: state dir unavailable" >&2; exit 1; }

SHIM="$STATE/$ID.check.sh"
SIDECAR="$STATE/$ID.prs"

cat > "$SHIM" <<EOF
#!/usr/bin/env bash
# Per-task shim for the generic PR readiness check (bin/fm-pr-ready-check.sh).
# Reads the PR list from $SIDECAR, its arm-time path baked in literally (like
# the id below) so an FM_STATE_OVERRIDE used at arm time is not lost: the
# watcher executes a hash-verified snapshot of this file, possibly from a
# different location, so a path recomputed from the snapshot's own location
# would silently miss a sidecar that was written outside FM_HOME/state.
# Change the PR list in the .prs sidecar only; changing this shim requires
# re-registering the trust binding.
set -u
ID=$ID
FM_HOME="\$(cd "\$(dirname "\$0")/.." && pwd)"
SIDECAR="$SIDECAR"
[ -f "\$SIDECAR" ] && [ ! -L "\$SIDECAR" ] || exit 0
mapfile -t prs < "\$SIDECAR"
[ "\${#prs[@]}" -ge 1 ] || exit 0
exec "\$FM_HOME/bin/fm-pr-ready-check.sh" "\${prs[@]}"
EOF

chmod 700 "$SHIM" || { echo "error: cannot chmod shim" >&2; exit 1; }

: > "$SIDECAR" || { echo "error: cannot write sidecar" >&2; exit 1; }
printf '%s\n' "$@" >> "$SIDECAR" || { echo "error: cannot write sidecar" >&2; exit 1; }

"$SCRIPT_DIR/fm-check-register.sh" "$ID" || exit 1

echo "armed: state/$ID.check.sh watching: $*"
