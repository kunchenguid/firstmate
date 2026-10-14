#!/usr/bin/env bash
# fm-action-lib.sh - the ONE owner of the per-task action ledger: what the next
# action is, who may authorize it, and how far it actually got.
#
# Sourced, never executed. bin/fm-action.sh is the only writer CLI.
#
# WHY THIS EXISTS. A steering message that was queued, doorbelled and
# acknowledged is not an action that started, and an action that started is not
# one that was accepted. Observed repeatedly: green work whose separately
# authorized next step sat for hours, an acknowledged instruction nobody
# executed, and an agent-written "approval request" label standing in for a
# grant that already existed. The steering inbox (bin/fm-task-inbox-lib.sh)
# owns queued and acknowledged; this ledger adds only what it cannot know.
#
# LEDGER. state/<task>.actions, append-only, one tab-separated record per line:
#   v1 <TAB> <epoch> <TAB> <action-id> <TAB> <event> <TAB> key=value ...
# Events:
#   admit   class=authorized|human-decision|external-gate owner= operation=
#           [source=] [due=] [units=] [inbox=NNN.msg] [ready_with=ids|none]
#   ack     the worker acknowledged (an inbox record moved to handled/ also
#           counts, via inbox=)
#   start   the action's native execution began [units=N]
#   result  outcome=ok|refused|failed|answered [reason=]
#   accept  receipt=<native acceptance reference>
#   hold    kind=safe-boundary|resource-wait|running-job until=<epoch> reason=
#
# AUTHORITY CLASSES (recorded, never inferred). `authorized` names the exact
# grant in source= and the exact operation; a generic permission word cannot
# manufacture a grant. `human-decision` and `external-gate` name the pending
# question in operation=, the owner who must answer, and the independent ready
# work (ready_with=) that must proceed meanwhile. A gate never suppresses an
# incident for any other action.
#
# FOLD (fm_action_fold, read-only). One tab-separated line per action:
#   <id> <class> <phase> <incident> <age-secs> <owner> <due> <operation>
# phase: queued|acked|started|resulted|refused|failed|accepted|gated|answered
# incident (authorized actions unless noted):
#   unacked-unstarted  past due, never acknowledged, no start, no refusal
#   acked-unexecuted   past due, acknowledged, still no start or refusal
#   over-grant         started more units than the counted grant allowed
#   gate-overdue       a gate class past its due time and unanswered
#   none               everything else
# A started action with no result is executing and never an incident, and a
# live hold suppresses only until its finite deadline. The fold never writes,
# closes, answers, interrupts or restarts anything; routing an incident to its
# owner is the scheduler's job, not this library's.
set -u

FM_ACTION_START_SECS_DEFAULT=300

fm_action_start_secs() {
  local s=${FM_ACTION_START_SECS:-$FM_ACTION_START_SECS_DEFAULT}
  case "$s" in ''|*[!0-9]*) s=$FM_ACTION_START_SECS_DEFAULT ;; esac
  printf '%s' "$s"
}

fm_action_ledger() {  # <state-dir> <task-id>
  printf '%s/%s.actions' "$1" "$2"
}

# Words that name a permission mechanism rather than a specific grant.
fm_action_source_generic() {  # <source>
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$s" in
    ''|yolo|auto|automatic|standing|blanket|any|all|flag|true|yes|ok|approved|authorized|allowed|default|permission|permissions|granted|n/a|none|unknown) return 0 ;;
  esac
  return 1
}

fm_action_clean() {  # <text> -> single-line, tab-free, bounded
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-300
}

# Append one record. Values must already be cleaned.
fm_action_append() {  # <state-dir> <task-id> <epoch> <action-id> <event> [k=v ...]
  local state=$1 task=$2 at=$3 id=$4 event=$5 line
  shift 5
  line=$(printf 'v1\t%s\t%s\t%s' "$at" "$id" "$event")
  while [ $# -gt 0 ]; do
    line=$line$'\t'$1
    shift
  done
  mkdir -p "$state" || return 1
  printf '%s\n' "$line" >> "$(fm_action_ledger "$state" "$task")"
}

# 0 when the ledger already holds an admit for the id.
fm_action_exists() {  # <state-dir> <task-id> <action-id>
  local ledger
  ledger=$(fm_action_ledger "$1" "$2")
  [ -f "$ledger" ] || return 1
  awk -F'\t' -v id="$3" '$3 == id && $4 == "admit" { found = 1 } END { exit !found }' "$ledger"
}

fm_action_class_of() {  # <state-dir> <task-id> <action-id>
  local ledger
  ledger=$(fm_action_ledger "$1" "$2")
  [ -f "$ledger" ] || return 1
  awk -F'\t' -v id="$3" '$3 == id && $4 == "admit" {
    for (i = 5; i <= NF; i++) if (index($i, "class=") == 1) { print substr($i, 7); exit }
  }' "$ledger"
}

# Names of acknowledged steering records for the task, space-delimited.
fm_action_handled_names() {  # <state-dir> <task-id>
  local dir=$1/$2.inbox/handled f out=' '
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    out="$out${f##*/} "
  done
  printf '%s' "$out"
}

fm_action_fold() {  # <state-dir> <task-id> <now-epoch>
  local ledger handled
  ledger=$(fm_action_ledger "$1" "$2")
  [ -f "$ledger" ] || return 0
  handled=$(fm_action_handled_names "$1" "$2")
  awk -F'\t' -v now="$3" -v handled="$handled" '
    function kv(rec, key,    i, n) {
      n = split(rec, parts, "\t")
      for (i = 5; i <= n; i++)
        if (index(parts[i], key "=") == 1) return substr(parts[i], length(key) + 2)
      return ""
    }
    $1 != "v1" { next }
    {
      id = $3; ev = $4
      if (ev == "admit") {
        if (!(id in cls)) { order[++count] = id }
        cls[id] = kv($0, "class"); owner[id] = kv($0, "owner"); op[id] = kv($0, "operation")
        due[id] = kv($0, "due"); units[id] = kv($0, "units"); inbox[id] = kv($0, "inbox")
        at0[id] = $2
      } else if (id in cls) {
        if (ev == "ack") acked[id] = 1
        else if (ev == "start") { started[id] = 1; u = kv($0, "units"); spent[id] += (u == "" ? 1 : u) }
        else if (ev == "result") outcome[id] = kv($0, "outcome")
        else if (ev == "accept") accepted[id] = 1
        else if (ev == "hold") { hu = kv($0, "until"); if (hu + 0 > holduntil[id] + 0) holduntil[id] = hu }
      }
    }
    END {
      for (n = 1; n <= count; n++) {
        id = order[n]; c = cls[id]
        isgate = (c == "human-decision" || c == "external-gate")
        ack = (id in acked) || (inbox[id] != "" && index(handled, " " inbox[id] " ") > 0)
        if (isgate) phase = (outcome[id] != "" ? "answered" : "gated")
        else if (id in accepted) phase = "accepted"
        else if (outcome[id] == "refused") phase = "refused"
        else if (outcome[id] == "failed") phase = "failed"
        else if (outcome[id] != "") phase = "resulted"
        else if (id in started) phase = "started"
        else if (ack) phase = "acked"
        else phase = "queued"
        inc = "none"
        if (isgate) {
          if (phase == "gated" && due[id] + 0 > 0 && now + 0 > due[id] + 0) inc = "gate-overdue"
        } else {
          lim = (units[id] == "" ? 1 : units[id])
          if (spent[id] + 0 > lim + 0) inc = "over-grant"
          else if ((phase == "queued" || phase == "acked") && now + 0 > due[id] + 0 && !(holduntil[id] + 0 > now + 0))
            inc = (phase == "acked" ? "acked-unexecuted" : "unacked-unstarted")
        }
        printf "%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\n", id, c, phase, inc, now - at0[id], owner[id], due[id], op[id]
      }
    }
  ' "$ledger"
}

# Only the lines that are incidents.
fm_action_incidents() {  # <state-dir> <task-id> <now-epoch>
  fm_action_fold "$@" | awk -F'\t' '$4 != "none"'
}
