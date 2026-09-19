#!/usr/bin/env bash
# fm-nm-findings-lib.sh - the single owner of the no-mistakes finding-retention
# ledger format and its fold logic.
#
# WHY THIS EXISTS: a no-mistakes worker drives review gates through the
# registered `axi respond --action fix --findings <ids>` interface, which
# selects only the named findings for that round. A finding left unselected is
# not re-surfaced by the tool's own status/response output on a later round,
# so nothing about the registered interface itself preserves an unresolved
# finding's identity, verbatim text, or provenance once a round moves past it
# (observed 2026-09-06, run 01M1TB9ZZQGN0JQ1RYV3WERD4S review round3: an
# earlier upgrade-condition finding had already vanished between rounds 2 and
# 3, and round3 then dropped two more independent findings the same way).
# This library never reads or writes any no-mistakes pipeline state - it owns
# a separate, durable, firstmate-side ledger that a no-mistakes worker
# hand-appends to at every gate (bin/fm-dod-lib.sh's no-mistakes Definition of
# done block is the one policy owner telling the worker what to append and
# when), so the ledger is the append-only record of record regardless of what
# the pipeline itself resurfaces on a later round.
#
# LEDGER FORMAT (this header is the one owner of the format).
#   Path: <data-dir>/<task-id>/nm-findings-ledger.jsonl
#   Append-only, one JSON object per line, one of two event shapes:
#     seen:        {"round":<n>,"step":"<step>","finding":{"id":"<id>", ...
#                    every other field exactly as the gate reported it}}
#     disposition: {"round":<n>,"step":"<step>","finding_id":"<id>",
#                    "disposition":"fixed"|"skipped-closed"|"deferred",
#                    "deferred_owner":"<owner>","deferred_id":"<external-id>"}
#   "deferred_owner" and "deferred_id" are required together and only for
#   disposition "deferred"; a disposition line missing one while claiming
#   the other, or carrying either for a non-deferred disposition, is a
#   malformed line and is excluded from the fold rather than trusted.
#   A `finding` object's only required field is a non-empty string `id`;
#   every other field is caller-defined and preserved verbatim.
#   A finding's identity is the pair (step, id): a disposition line closes
#   only the finding its own "step" and "finding_id" name, because two steps
#   may independently report the same id.
#   Lines are never rewritten, reordered, or deleted; an absent ledger file
#   is a valid empty ledger (a task with no no-mistakes findings yet, or a
#   task predating this contract), never an error.
#
# FOLD SEMANTICS.
#   Every distinct (step, finding id) pair folds to exactly one current
#   record carrying that `step` and `id`; "that id" below means that pair:
#     - `finding`: the verbatim finding object from that id's FIRST seen
#       event (the original text and fields the reviewer actually reported),
#       never a later round's rephrasing.
#     - `first_seen` / `last_seen`: {"round","step"} of the earliest and
#       latest seen event for that id, so provenance survives even when the
#       finding was not repeated verbatim on a later round's gate.
#     - `disposition`: "open" when no disposition event exists for the id,
#       or when that id's latest seen event follows its latest disposition
#       event in ledger order (a gate presented it again after it was
#       disposed of, so it is reopened until a newer disposition closes it);
#       otherwise the LATEST disposition event's value. A finding is never
#       silently dropped: the only way off "open" is an explicit disposition
#       line naming that exact step and id, appended after its latest seen
#       line.
#     - `deferred_owner` / `deferred_id`: from the latest disposition event
#       when the folded disposition is "deferred", otherwise null.
#   A disposition event for an id with no matching seen event is dropped from
#   the fold (it cannot prove what it is disposing of) rather than accepted
#   as a fabricated closure.
#
# USAGE.
#   fm-nm-findings-lib.sh fold <data-dir> <task-id>
#     Prints the current folded state as a JSON array (see FOLD SEMANTICS).
#     An absent or empty ledger prints [].
#
# Sourcing this file (rather than executing it) exposes the same behavior as
# fm_nm_findings_fold, taking <data-dir> <task-id>.

fm_nm_findings_ledger_path() {  # <data-dir> <task-id>
  printf '%s/%s/nm-findings-ledger.jsonl' "$1" "$2"
}

# Read the ledger (absent file => empty) one line at a time so a line that is
# not valid JSON at all (unlike a structurally invalid-but-parseable event,
# which the fold below rejects) never aborts the whole read; only lines that
# parse as a JSON object reach the fold.
_fm_nm_findings_valid_events() {  # <ledger-path>
  local path=$1
  if [ -f "$path" ]; then
    jq -R -c 'fromjson? | select(type=="object")' "$path" 2>/dev/null
  fi
}

fm_nm_findings_fold() {  # <data-dir> <task-id>
  local data=$1 id=$2 ledger
  ledger=$(fm_nm_findings_ledger_path "$data" "$id")
  _fm_nm_findings_valid_events "$ledger" | jq -s '
    # Keep only structurally valid seen/disposition events.
    def valid_seen: (.round != null) and (.step != null)
      and (.finding? | type == "object")
      and ((.finding.id? | type == "string") and (.finding.id | length > 0));
    def valid_disp: (.round != null) and (.step != null)
      and (.finding_id? | type == "string") and (.finding_id | length > 0)
      and (.disposition? as $d | ["fixed","skipped-closed","deferred"] | index($d) != null)
      and (
        if .disposition == "deferred" then
          (.deferred_owner? | type == "string") and (.deferred_owner | length > 0)
          and (.deferred_id? | type == "string") and (.deferred_id | length > 0)
        else
          (.deferred_owner == null) and (.deferred_id == null)
        end
      );
    to_entries | map(.value + {_pos: .key})
    | (map(select(valid_seen))) as $seens
    | (map(select(valid_disp))) as $disps
    | ($seens | group_by([.step, .finding.id]) | map(sort_by(._pos)) | map({
        step: .[0].step,
        id: .[0].finding.id,
        finding: .[0].finding,
        first_seen: {round: .[0].round, step: .[0].step},
        last_seen: {round: (.[-1].round), step: (.[-1].step)},
        _last_seen_pos: .[-1]._pos
      })) as $folded_seen
    | ($disps | group_by([.step, .finding_id]) | map(max_by(._pos))) as $latest_disp
    | $folded_seen | map(
        . as $f
        | ($latest_disp | map(select(.step == $f.step and .finding_id == $f.id and ._pos > $f._last_seen_pos)) | .[0]) as $d
        | ($f | del(._last_seen_pos)) + {
            disposition: ($d.disposition // "open"),
            deferred_owner: (if ($d.disposition // "") == "deferred" then $d.deferred_owner else null end),
            deferred_id: (if ($d.disposition // "") == "deferred" then $d.deferred_id else null end)
          }
      )
  '
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -eu
  case "${1:-}" in
    fold) fm_nm_findings_fold "$2" "$3" ;;
    *)
      echo "usage: fm-nm-findings-lib.sh fold <data-dir> <task-id>" >&2
      exit 2
      ;;
  esac
fi
