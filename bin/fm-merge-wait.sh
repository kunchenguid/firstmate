#!/usr/bin/env bash
# Declare, inspect, or withdraw a task's merge wait: firstmate's durable record
# that this task's green pull request is waiting on a merge nobody in this fleet
# can perform, so the watcher must stop aging its idle pane into a possible wedge.
#
# It exists because that wait is otherwise indistinguishable from a wedge. A ship
# task whose checks are green keeps its worker, its branch, and its merge poll
# alive by design (the work is committed and NOT landed, so teardown is refused and
# would remove the very poll that will notice the merge), and its idle pane
# re-wedges on every new pane hash - measured at one alarm every 90 to 150 seconds
# on 2026-08-20, each costing firstmate a handling turn. A `paused:` status line
# cannot express it either: the authoritative run step outranks the status log, so
# the declared wait loses to the still-open run. The declaration therefore lives
# beside the run, at the classifier, and changes only what the classifier concludes.
#
# What it deliberately does NOT do:
#   - it never touches the merge poll, which keeps running and is still what wakes
#     firstmate when the merge lands (bin/fm-pr-check.sh owns that poll);
#   - it never silences a task on its own. bin/fm-classify-lib.sh admits the
#     declaration ONLY while authoritative crew state reports the terminal
#     checks-green outcome from the run step, so a run that fails, is closed, gets
#     a review comment, or loses its recorded head resumes ordinary wedge aging;
#   - it never ends, exits, or tears down anything.
#
# Usage: fm-merge-wait.sh declare <id> [note]
#        fm-merge-wait.sh show <id>
#        fm-merge-wait.sh clear <id>
#
# declare refuses unless the task records a pull request AND its merge poll is
# armed, because a declaration without the poll would suppress the alarm with
# nothing left to report the merge - strictly worse than the noise it removes.
# Re-declaring an already-declared task rewrites the record against the currently
# recorded pull request, so a re-armed watch is picked up rather than inherited.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-merge-wait.sh declare <id> [note]
       fm-merge-wait.sh show <id>
       fm-merge-wait.sh clear <id>
EOF
  exit 2
}

[ "$#" -ge 2 ] || usage
ACTION=$1
ID=$2
shift 2
NOTE=${1-}
[ "$#" -le 1 ] || usage
fm_pr_task_id_valid "$ID" || usage

RECORD="$STATE/$ID.merge-wait"

case "$ACTION" in
  show)
    [ -f "$RECORD" ] || { echo "error: no merge wait is declared for $ID" >&2; exit 1; }
    cat "$RECORD"
    ;;
  clear)
    rm -f -- "$RECORD" || exit 1
    printf 'cleared: state/%s.merge-wait\n' "$ID"
    ;;
  declare)
    [ -d "$STATE" ] && [ ! -L "$STATE" ] \
      || { echo "error: state directory is unavailable" >&2; exit 1; }
    META="$STATE/$ID.meta"
    [ -f "$META" ] && [ ! -L "$META" ] \
      || { echo "error: task metadata is unavailable" >&2; exit 1; }
    PR=$(grep '^pr=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$PR" ] \
      || { echo "error: $ID records no pull request to wait on" >&2; exit 1; }
    # The poll is what will report the merge. Without it the declaration would
    # remove the alarm and leave nothing watching, so its absence refuses here.
    [ -f "$STATE/$ID.check.sh" ] && [ ! -L "$STATE/$ID.check.sh" ] \
      || { echo "error: $ID has no armed merge poll (run bin/fm-pr-check.sh first)" >&2; exit 1; }
    umask 077
    TMP=$(mktemp "$STATE/.fm-merge-wait.XXXXXX") || exit 1
    trap '[ -z "${TMP:-}" ] || rm -f -- "$TMP"' EXIT HUP INT TERM
    {
      printf 'pr=%s\n' "$PR"
      printf 'declared=%s\n' "$(date +%s)"
      [ -z "$NOTE" ] || printf 'note=%s\n' "$(printf '%s' "$NOTE" | tr -d '\n')"
    } > "$TMP" || exit 1
    chmod 0600 "$TMP" || exit 1
    mv -f -- "$TMP" "$RECORD" || exit 1
    TMP=
    # Prove the record the classifier will read actually admits the wait, rather
    # than reporting success on a record it would silently reject.
    merge_wait_declared "$ID" "$STATE" \
      || { rm -f -- "$RECORD"; echo "error: merge wait record was not accepted" >&2; exit 1; }
    printf 'declared: state/%s.merge-wait (%s)\n' "$ID" "$PR"
    ;;
  *)
    usage
    ;;
esac
