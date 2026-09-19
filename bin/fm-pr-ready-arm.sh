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
# executes a hash-verified snapshot of the shim from a temp file inside the
# same state directory (fm_custom_check_snapshot_prepare), so deriving
# FM_HOME from that snapshot's own path only happens to work when state is
# exactly FM_HOME/state; under FM_STATE_OVERRIDE it resolves the wrong
# installation and the exec below silently never runs. The id, FM_HOME, and
# the sidecar's arm-time path are therefore all baked into the shim literally
# rather than recomputed relative to the snapshot's own location.
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

# FM_HOME and SIDECAR are arbitrary paths (env- or override-supplied), so
# %q-escape them before embedding: interpolating them raw into this unquoted
# heredoc would let a $, backtick, backslash, or double quote in either path
# reparse as shell when the generated shim runs.
FM_HOME_Q=$(printf '%q' "$FM_HOME")
SIDECAR_Q=$(printf '%q' "$SIDECAR")

cat > "$SHIM" <<EOF
#!/usr/bin/env bash
# Per-task shim for the generic PR readiness check (bin/fm-pr-ready-check.sh).
# FM_HOME and the PR-list sidecar path are both baked in literally at arm
# time (like the id below), never re-derived from this file's own path: the
# watcher executes a hash-verified snapshot of this file from a temp copy
# inside the state directory, and under FM_STATE_OVERRIDE that state
# directory need not sit one level below FM_HOME, so a re-derived path can
# silently resolve to the wrong installation or miss the sidecar entirely.
# Change the PR list in the .prs sidecar only; changing this shim requires
# re-registering the trust binding.
set -u
ID=$ID
FM_HOME=$FM_HOME_Q
SIDECAR=$SIDECAR_Q
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
