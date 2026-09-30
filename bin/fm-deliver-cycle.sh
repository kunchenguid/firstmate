#!/usr/bin/env bash
# Advance PR delivery for a home supervised without a general shell tool.
#
# The opt-in restricted Pi supervision (docs/pi-restricted-supervision.md) runs
# this pass from its extension on a timer and after each agent run, because a
# supervisor with no shell cannot run the commands below itself and its model
# must not be the thing that remembers to.
#
# One pass derives every target from this home's durable records and runs only
# this home's own engine commands. It takes no arguments, so no task id, URL,
# path, or command can come from a model.
#
#   arm      A ship task whose record has no pr= yet and no merge poll, and whose
#            current status (bin/fm-classify-lib.sh status_current_line) is the
#            ready report its delivery mode requires (bin/fm-dod-lib.sh
#            fm_dod_should_gate_ship_done) naming exactly one link, which parses
#            as a pull request, merge request, or change -> bin/fm-pr-check.sh
#            <id> <url>. That command's own gates decide eligibility: it refuses
#            a secondmate, a draft, and a named head that is not stored outside
#            the worker's disposable copy. A change that merged before it was
#            armed is still armed, because the merge poll's merged result is
#            this engine's only confirmation of a merge.
#   clean up A ship task whose recorded pr= the merge poll confirmed merged (the
#            merge-notification marker owned by bin/fm-pr-lib.sh) and whose
#            current status is the ready report its delivery mode requires
#            naming exactly that recorded change -> bin/fm-teardown.sh <id>,
#            never with --force, so its landed-work, lease, captain-hold, and
#            endpoint gates stay final. Cleanup requires positive evidence:
#            a missing, unreadable, unparseable, or non-ready current status,
#            or a ready report naming a different change, is reported as
#            "skipped <id>: ...; left for the supervisor" and nothing runs.
#
# Missing, malformed, or ambiguous records are skipped: nothing is armed or
# cleaned up on a guess. A refusal from either engine command is reported and
# left in place for the next pass; it is never retried with more authority.
# Every action is idempotent: arming records pr=, so an armed task is never
# armed again, and a cleaned-up task leaves no record to visit. Both engine
# commands take the task's own locks, so an overlapping pass converges instead
# of acting twice; the extension also serializes its own passes.
# Merging stays outside this pass: it never merges, approves, or pushes.
#
# Usage: fm-deliver-cycle.sh
#   Prints one line per action taken, refused, or skipped for a reason worth
#   reporting, followed by the engine command's own output indented beneath it,
#   or "deliver: nothing to do". Exits 0 when the pass completed, including
#   when an engine command refused; 1 when the home cannot be read; 2 on any
#   argument.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

if [ "$#" -ne 0 ]; then
  echo "usage: fm-deliver-cycle.sh (takes no arguments)" >&2
  exit 2
fi

# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
  echo "deliver: no readable state directory at $STATE; nothing was done" >&2
  exit 1
fi

# Engine command output shown beneath its action line, bounded so one noisy
# refusal cannot crowd out the rest of the pass.
indent_output() {  # <text>
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | head -n 40 | sed 's/^/  /'
}

# The single change URL the task's current status reports as ready, or nothing.
ready_change_url() {  # <status-file> <kind> <mode>
  local line note url links
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  line=$(status_current_line "$1" "$2")
  [ -n "$line" ] || return 1
  fm_dod_should_gate_ship_done "$2" "$3" "$line" || return 1
  note=$(status_line_note "$line")
  links=$(printf '%s\n' "$note" | grep -oE 'https?://[^[:space:]]+' | awk 'END { print NR }')
  [ "$links" = 1 ] || return 1
  url=$(fm_dod_pr_url_from_done_note "$note") || return 1
  fm_pr_url_parse "$url" || return 1
  printf '%s\n' "$FM_PR_URL"
}

reported=0
report() {  # <line>
  printf '%s\n' "$1"
  reported=1
}

shopt -s nullglob
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  if ! fm_pr_task_id_valid "$id"; then
    report "skipped a task record with an invalid id: $meta"
    continue
  fi
  kind=$(fm_dod_meta_value "$meta" kind)
  kind=${kind:-ship}
  # Scouts deliver a report and secondmates are persistent workers; neither
  # owns a change of its own to arm or land.
  [ "$kind" = ship ] || continue
  mode=$(fm_dod_meta_value "$meta" mode)
  recorded=$(fm_dod_meta_value "$meta" pr)
  ready=$(ready_change_url "$STATE/$id.status" "$kind" "$mode") || ready=

  if [ -n "$recorded" ]; then
    if ! fm_pr_url_parse "$recorded"; then
      report "skipped $id: its recorded change is not a recognized pull request, merge request, or change link"
      continue
    fi
    fm_pr_poll_merge_already_notified "$STATE" "$id" \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" || continue
    if [ -z "$ready" ]; then
      report "skipped $id: $FM_PR_URL merged but its current status is not the ready report for its mode naming that change; left for the supervisor"
      continue
    fi
    if [ "$ready" != "$FM_PR_URL" ]; then
      report "skipped $id: $FM_PR_URL merged but its latest ready report names $ready; left for the supervisor"
      continue
    fi
    if out=$("$SCRIPT_DIR/fm-teardown.sh" "$id" </dev/null 2>&1); then
      report "cleaned up $id after $FM_PR_URL merged"
    else
      report "cleanup of $id refused or failed after $FM_PR_URL merged; its work and records were left in place"
    fi
    indent_output "$out"
    continue
  fi

  [ -n "$ready" ] || continue
  if [ -e "$STATE/$id.pr-poll" ] || [ -L "$STATE/$id.pr-poll" ]; then
    report "skipped $id: a merge poll exists without a recorded change; left for the supervisor"
    continue
  fi
  if out=$("$SCRIPT_DIR/fm-pr-check.sh" "$id" "$ready" </dev/null 2>&1); then
    report "armed merge monitoring for $id on $ready"
  else
    report "could not arm merge monitoring for $id on $ready"
  fi
  indent_output "$out"
done

[ "$reported" = 1 ] || echo "deliver: nothing to do"
exit 0
