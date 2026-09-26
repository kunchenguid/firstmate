#!/usr/bin/env bash
# fm-jev-decisions.sh - the Jev DecisionEnvelope log: append, outcome, report.
#
# docs/configuration.md "Jev decision log" owns the operator contract. This
# header owns the record format and the writer mechanics.
#
# File: $FM_HOME/state/jev-decisions.jsonl, append-only JSON Lines, one record
# per line, every write under state/.jev-decisions.lock (waited on for at most
# five seconds, then the write fails). Two record kinds share
# the file and join on decision_id; a DecisionEnvelope is one decision record
# plus the newest outcome record naming its decision_id.
#
#   decision (one per resolver call, written by bin/fm-dispatch-resolve.sh):
#     schema_version 1, kind "decision", decision_id, at (epoch seconds),
#     surface "dispatch-resolve", question_id "dispatch.rule",
#     question_digest (sha256 of the options offered, so a rules edit is a new
#     question), state_digest (sha256 of the exact state sent, null when no
#     model call was made), task (the <id> of a data/<id>/brief.md brief, else
#     null), project, brief_kind (ship | scout | whole), model_requested, model
#     (the version the API reported), latency_ms, tokens (as reported; never a
#     spend measure), choice, choice_when (the picked option's full text), confidence, probabilities, resolved (the rule after any
#     fallback), status (clear | ambiguous | escalate | error), reason, and
#     profile (the resolver's profile on clear, else null).
#   outcome (what the supervisor actually took):
#     schema_version 1, kind "outcome", decision_id, at, source (spawn |
#     supervisor), took (dispatched | held | declined), profile (the launched
#     harness/model/effort, or null), followed (true when it equals the
#     decision's profile, false when it differs, null when the decision had
#     none), and note.
#
# Usage:
#   fm-jev-decisions.sh append                   one decision record on stdin
#   fm-jev-decisions.sh spawned <task> <harness> <model> <effort>
#   fm-jev-decisions.sh outcome <decision-id> --took <dispatched|held|declined>
#                       [--harness <h>] [--model <m>] [--effort <e>] [--note <text>]
#   fm-jev-decisions.sh report
#
# append validates the record's schema_version, kind, and decision_id and
# appends it. spawned is bin/fm-spawn.sh's best-effort hook after a fresh ship
# or scout launch: it records a dispatched outcome for the newest decision whose
# task is <task> and has no outcome yet, and writes nothing otherwise. outcome is the
# supervisor's manual record for any other fate, such as holding the decision
# for the captain or dispatching by hand. report prints, per class (the option
# actually resolved), the clear/ambiguous/escalate/error rates and how often the
# supervisor's recorded outcome followed the resolver's profile; it prints no
# token or cost figure, because token counts alone support no spend claim.
#
# Authority: this log is measurement evidence and a replay corpus only. Nothing
# reads it to grant permission, choose effort, wake or suppress a wake, mark
# work done, or decide state; the watcher never reads it.
#
# Environment: FM_HOME and FM_STATE_OVERRIDE resolve the home as elsewhere.
# Exit status: 0 on success or nothing to record, 2 on a usage error, 1 when a
# record could not be written. Producers ignore a failure so it never changes
# theirs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG="$STATE/jev-decisions.jsonl"
LOCK="$STATE/.jev-decisions.lock"
NOTE_MAX_CHARS=500
LOCK_TRIES=50

usage() {
  echo "usage: fm-jev-decisions.sh append | spawned <task> <harness> <model> <effort> | outcome <decision-id> --took <dispatched|held|declined> [--harness <h>] [--model <m>] [--effort <e>] [--note <text>] | report" >&2
  exit 2
}

task_ok() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 1; }

locked_append() { # <json line>
  [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ -w "$STATE" ] || return 1
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh" || return 1
  # Bounded: a producer such as the resolver must never hang on this log.
  local rc=0 tries=0
  until fm_lock_try_acquire "$LOCK"; do
    tries=$((tries + 1))
    [ "$tries" -lt "$LOCK_TRIES" ] || return 1
    sleep 0.1
  done
  if [ ! -e "$LOG" ]; then
    (umask 077; : > "$LOG") || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$1" >> "$LOG" || rc=1
  fi
  fm_lock_release "$LOCK"
  return "$rc"
}

# Print the newest decision record matching the jq filter's selection, or
# nothing. Malformed lines are skipped rather than failing the whole read.
newest_decision() { # <jq select expression> [--arg name value]...
  local expr=$1
  shift
  [ -f "$LOG" ] || return 0
  jq -cR "$@" "fromjson? | select(.kind == \"decision\") | select($expr)" "$LOG" 2>/dev/null | tail -n 1
}

write_outcome() { # <decision json> <source> <took> <harness> <model> <effort> <note>
  local line
  line=$(jq -c -n --argjson d "$1" --arg source "$2" --arg took "$3" \
    --arg h "$4" --arg m "$5" --arg e "$6" --arg note "${7:0:$NOTE_MAX_CHARS}" '
    (if $h == "" then null else {harness: $h, model: (if $m == "" then null else $m end), effort: (if $e == "" then null else $e end)} end) as $p |
    {schema_version: 1, kind: "outcome", decision_id: $d.decision_id, at: now | floor,
     source: $source, took: $took, profile: $p,
     followed: (if $d.profile == null or $p == null then null
                else ($d.profile.harness == $p.harness and ($d.profile.model // null) == $p.model and ($d.profile.effort // null) == $p.effort) end),
     note: (if $note == "" then null else $note end)}') || return 1
  locked_append "$line"
}

cmd=${1:-}
case "$cmd" in
  append)
    [ "$#" -eq 1 ] || usage
    line=$(jq -c 'select(.schema_version == 1 and .kind == "decision" and (.decision_id | type) == "string" and (.decision_id | length) > 0)') || exit 1
    [ -n "$line" ] || { echo "error: not a decision record" >&2; exit 1; }
    locked_append "$line" || exit 1
    ;;
  spawned)
    [ "$#" -eq 5 ] && task_ok "$2" && [ -n "$3" ] || usage
    # shellcheck disable=SC2016 # $t and $id are jq variables, not shell ones.
    decision=$(newest_decision '.task == $t' --arg t "$2")
    [ -n "$decision" ] || exit 0
    # Any recorded fate closes this decision to later spawns.
    if jq -e -R --arg id "$(jq -r .decision_id <<<"$decision")" \
      'fromjson? | select(.kind == "outcome" and .decision_id == $id)' "$LOG" >/dev/null 2>&1; then
      exit 0
    fi
    write_outcome "$decision" spawn dispatched "$3" "${4#-}" "${5#-}" "" || exit 1
    ;;
  outcome)
    [ "$#" -ge 2 ] && [ -n "$2" ] || usage
    id=$2
    shift 2
    took='' h='' m='' e='' note=''
    while [ $# -gt 0 ]; do
      [ $# -ge 2 ] || usage
      case "$1" in
        --took) took=$2 ;;
        --harness) h=$2 ;;
        --model) m=$2 ;;
        --effort) e=$2 ;;
        --note) note=$2 ;;
        *) usage ;;
      esac
      shift 2
    done
    case "$took" in dispatched|held|declined) ;; *) usage ;; esac
    if [ "$took" = dispatched ] && [ -z "$h" ]; then
      echo "error: --took dispatched needs --harness" >&2
      exit 2
    fi
    if [ "$took" != dispatched ] && [ -n "$h$m$e" ]; then
      echo "error: only --took dispatched carries a profile" >&2
      exit 2
    fi
    # shellcheck disable=SC2016 # $t and $id are jq variables, not shell ones.
    decision=$(newest_decision '.decision_id == $id' --arg id "$id")
    [ -n "$decision" ] || { echo "error: no decision $id in $LOG" >&2; exit 1; }
    write_outcome "$decision" supervisor "$took" "$h" "$m" "$e" "$note" || exit 1
    ;;
  report)
    [ "$#" -eq 1 ] || usage
    if [ ! -f "$LOG" ]; then
      printf 'jev-decisions:\n  decisions: 0\n  note: no log at %s\n' "$LOG"
      exit 0
    fi
    jq -rsR '
      def pct($n; $d): if $d == 0 then "-" else "\(($n * 1000 / $d | round) / 10)%" end;
      def flat: tostring | gsub("[\t\r\n]"; " ");
      [split("\n")[] | fromjson? | select(type == "object" and .schema_version == 1)] as $all |
      [$all[] | select(.kind == "decision")] as $d |
      (reduce ($all[] | select(.kind == "outcome")) as $o ({}; .[$o.decision_id] = $o)) as $last |
      "jev-decisions:",
      "  decisions: \($d | length)   with outcome: \([$d[] | select($last[.decision_id] != null)] | length)",
      ($d | group_by(.resolved_when // .choice_when // "(no model answer)")[] |
        length as $n | (.[0].resolved_when // .[0].choice_when // "(no model answer)") as $class |
        [.[] | $last[.decision_id] | select(. != null)] as $outs |
        "  class: \($class | flat)   n=\($n)"
        + "   clear=\(pct([.[] | select(.status == "clear")] | length; $n))"
        + " ambiguous=\(pct([.[] | select(.status == "ambiguous")] | length; $n))"
        + " escalate=\(pct([.[] | select(.status == "escalate")] | length; $n))"
        + " error=\(pct([.[] | select(.status == "error")] | length; $n))"
        + "   outcomes=\($outs | length) followed=\([$outs[] | select(.followed == true)] | length)"
        + " overridden=\([$outs[] | select(.followed == false)] | length)"
        + " held=\([$outs[] | select(.took == "held")] | length)"
        + " declined=\([$outs[] | select(.took == "declined")] | length)"),
      "  note: token counts are recorded per call but are not a spend measure"
    ' "$LOG" || exit 1
    ;;
  *) usage ;;
esac
exit 0
