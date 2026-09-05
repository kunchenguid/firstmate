#!/usr/bin/env bash
# Deterministic pipeline-state condition for bin/fm-procevent-when.sh.
#
# Usage: fm-nm-state-condition.sh <worktree> <snapshot-file>
#        fm-nm-state-condition.sh --projection <worktree>
#
# Exit 0 = true (the pipeline state changed since the snapshot, ring the
# worker), 1 = clean false, 2 = error (the when runner counts it against its
# error budget and never treats it as a true).
#
# WHY A PROJECTION AND NOT THE WHOLE OUTPUT: `axi status` carries elapsed
# times that churn on every poll, so digesting the whole thing would fire
# immediately and forever. The projection keeps only the scalars that change
# when the RUN's state changes. Missing keys contribute an empty field, so a
# no-mistakes version that adds or drops a key degrades to a coarser watch
# rather than to a wrong one.
#
# The first call with no snapshot writes the snapshot and returns false, so
# arming can never fire on its own baseline.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

# The scalars that mean "the state changed". status and outcome are proven to
# exist (fm_nm_run_is_active reads them); step and round are best-effort.
PROJECTION_KEYS="status outcome step round"
PROBE_TIMEOUT="${FM_NM_STATE_PROBE_TIMEOUT:-45}"

projection() {  # <worktree>
    local wt=$1 out key value line=''
    out=$(fm_nm_run_bounded "$wt" "$PROBE_TIMEOUT" axi status 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    for key in $PROJECTION_KEYS; do
        value=$(fm_nm_strip_quotes "$(fm_nm_field "$out" "$key")")
        line="$line$key=$value;"
    done
    printf '%s\n' "$line"
}

if [ "${1:-}" = "--projection" ]; then
    [ $# -eq 2 ] || { echo "usage: $0 --projection <worktree>" >&2; exit 2; }
    projection "$2" || exit 2
    exit 0
fi

[ $# -eq 2 ] || { echo "usage: $0 <worktree> <snapshot-file>" >&2; exit 2; }
WORKTREE=$1
SNAPSHOT=$2

[ -d "$WORKTREE" ] || exit 2

CURRENT=$(projection "$WORKTREE") || exit 2

if [ ! -f "$SNAPSHOT" ]; then
    printf '%s\n' "$CURRENT" > "$SNAPSHOT" 2>/dev/null || exit 2
    exit 1
fi

PREVIOUS=$(cat "$SNAPSHOT" 2>/dev/null) || exit 2
if [ "$CURRENT" = "$PREVIOUS" ]; then
    exit 1
fi

printf '%s\n' "$CURRENT" > "$SNAPSHOT" 2>/dev/null || exit 2
exit 0
