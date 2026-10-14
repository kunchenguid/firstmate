#!/usr/bin/env bash
# fm-action-lib.sh - the ONE owner of the per-task action ledger: what the next
# action is, who may authorize it, and how far it actually got.
#
# Sourced, never executed. Native intake and lifecycle owners use this library.
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
#           [head=] [run=spawn_gen] [attempt=]
#   ack     the worker acknowledged (an inbox record moved to handled/ also
#           counts, via inbox=)
#   start   the action's native execution began [units=N]
#   result  outcome=ok|refused|failed|answered [reason=] [native=1]
#   accept  receipt=<native acceptance path>
# Native receipts: state/<task>.action-receipts/<action>, one TSV record:
#   v1 task action head run attempt outcome epoch
# Only an exact current identity and a matching successful native result
# certify acceptance; unavailable, unbound or stale evidence is unknown.
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
# owner is bin/fm-watch.sh's job, through its existing durable check queue.
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
        if (isgate) phase = (outcome[id] == "answered" ? "answered" : "gated")
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

# Probe one evidence path without letting an access failure read as absence.
# Prints exactly one line:
#   present
#   absent
#   unknown reason=permission-denied blocked=<dir> fallback=<read-only route>
# Absent is claimed only when every ancestor is searchable, so the missing entry
# was actually looked for. An inaccessible path is unknown, never absence and
# never success; the fallback names a read-only way to settle it.
fm_action_probe_evidence() {  # <path>
  local path=$1 dir
  case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ -r "$path" ]; then printf 'present\n'; return 0; fi
    printf 'unknown reason=permission-denied blocked=%s fallback=ask the path owner to run: stat %s\n' "$path" "$path"
    return 0
  fi
  dir=${path%/*}
  [ -n "$dir" ] || dir=/
  while [ "$dir" != / ] && [ -n "$dir" ]; do
    if [ ! -d "$dir" ]; then
      dir=${dir%/*}
      continue
    fi
    if [ ! -x "$dir" ]; then
      printf 'unknown reason=permission-denied blocked=%s fallback=ask the directory owner to run: stat %s\n' "$dir" "$path"
      return 0
    fi
    dir=${dir%/*}
    [ -n "$dir" ] || dir=/
  done
  if [ ! -x / ]; then
    printf 'unknown reason=permission-denied blocked=/ fallback=ask the directory owner to inspect the path\n'
    return 0
  fi
  printf 'absent\n'
}

fm_action_field() {
  local ledger
  ledger=$(fm_action_ledger "$1" "$2")
  [ -r "$ledger" ] || return 1
  awk -F'\t' -v id="$3" -v key="$4" '$3 == id && $4 == "admit" {
    for (i=5; i<=NF; i++) if (index($i,key "=")==1) { print substr($i,length(key)+2); exit }
  }' "$ledger"
}

fm_action_admit_steer() {
  local state=$1 task=$2 rec=$3 text=$4 id head run wt at
  id="steer-${rec##*/}"; id=${id%.msg}
  fm_action_exists "$state" "$task" "$id" && return 0
  wt=$(awk -F= '$1=="worktree" {print substr($0,10); exit}' "$state/$task.meta" 2>/dev/null) || wt=
  head=$(git -C "${wt:-/dev/null}" rev-parse HEAD 2>/dev/null) || head=
  run=$(awk -F= '$1=="spawn_gen" {print substr($0,11); exit}' "$state/$task.meta" 2>/dev/null) || run=
  at=$(date +%s)
  fm_action_append "$state" "$task" "$at" "$id" admit class=authorized "owner=$task" \
    "operation=$(fm_action_clean "$text")" "source=firstmate-steer:${rec##*/}" \
    "inbox=${rec##*/}" "due=$((at + $(fm_action_start_secs)))" units=1 \
    "head=$head" "run=$run" "attempt=${rec##*/}"
}

fm_action_native_begin() {
  local state=$1 task=$2 id=$3 operation=$4 head=$5 run=$6 attempt=$7 at key actual
  at=$(date +%s)
  if fm_action_exists "$state" "$task" "$id"; then
    [ "$(fm_action_field "$state" "$task" "$id" class)" = authorized ] && \
      [ "$(fm_action_field "$state" "$task" "$id" operation)" = "$operation" ] || return 1
    for key in head run attempt; do
      case "$key" in head) actual=$head ;; run) actual=$run ;; attempt) actual=$attempt ;; esac
      [ -n "$actual" ] && [ "$(fm_action_field "$state" "$task" "$id" "$key")" = "$actual" ] || return 1
    done
  else
    fm_action_append "$state" "$task" "$at" "$id" admit class=authorized "owner=$task" \
      "operation=$operation" "source=native:$operation:$id" "head=$head" "run=$run" \
      "attempt=$attempt" "due=$((at + $(fm_action_start_secs)))" units=1 || return 1
  fi
  fm_action_append "$state" "$task" "$at" "$id" start units=1
}

fm_action_native_result() {
  local state=$1 task=$2 id=$3 head=$4 run=$5 attempt=$6 outcome=$7 at dir tmp
  at=$(date +%s)
  [ "$(fm_action_field "$state" "$task" "$id" head)" = "$head" ] && \
    [ "$(fm_action_field "$state" "$task" "$id" run)" = "$run" ] && \
    [ "$(fm_action_field "$state" "$task" "$id" attempt)" = "$attempt" ] || return 1
  dir="$state/$task.action-receipts"
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.receipt.XXXXXX") || return 1
  printf 'v1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$task" "$id" "$head" "$run" "$attempt" "$outcome" "$at" > "$tmp" && \
    mv "$tmp" "$dir/$id" || { rm -f "$tmp"; return 1; }
  fm_action_append "$state" "$task" "$at" "$id" result "outcome=$outcome" "reason=native:$outcome" native=1
}

fm_action_verify_receipt() {
  local state=$1 task=$2 id=$3 path=$4 expected head run attempt receipt_at result_at phase wt current_run current_head
  expected="$state/$task.action-receipts/$id"
  [ "$path" = "$expected" ] && [ -f "$path" ] && [ ! -L "$path" ] || return 1
  head=$(fm_action_field "$state" "$task" "$id" head) || return 1
  run=$(fm_action_field "$state" "$task" "$id" run) || return 1
  attempt=$(fm_action_field "$state" "$task" "$id" attempt) || return 1
  [ -n "$head" ] && [ -n "$run" ] && [ -n "$attempt" ] || return 1
  wt=$(awk -F= '$1=="worktree" {print substr($0,10); exit}' "$state/$task.meta") || return 1
  current_run=$(awk -F= '$1=="spawn_gen" {print substr($0,11); exit}' "$state/$task.meta") || return 1
  current_head=$(git -C "${wt:-/dev/null}" rev-parse HEAD 2>/dev/null) || return 1
  [ "$current_run" = "$run" ] && [ "$current_head" = "$head" ] || return 1
  receipt_at=$(awk -F'\t' 'NR==1 {print $8}' "$path") || return 1
  result_at=$(awk -F'\t' -v id="$id" '$3==id && $4=="admit" {admitted=$2}
    $3==id && $4=="result" {at=""; ok=0; native=0; for(i=5;i<=NF;i++) {if($i=="outcome=ok") ok=1; if($i=="native=1") native=1} if(ok && native && $2>=admitted) at=$2}
    END {print at}' "$(fm_action_ledger "$state" "$task")") || return 1
  [ -n "$result_at" ] && [ "$receipt_at" = "$result_at" ] || return 1
  phase=$(fm_action_fold "$state" "$task" "$(date +%s)" | awk -F'\t' -v id="$id" '$1==id {print $3 ":" $4}') || return 1
  case "$phase" in resulted:none|accepted:none) ;; *) return 1 ;; esac
  awk -F'\t' -v task="$task" -v id="$id" -v head="$head" -v run="$run" -v attempt="$attempt" \
    'NF==8 && $1=="v1" && $2==task && $3==id && $4==head && $5==run && $6==attempt && $7=="ok" && $8 ~ /^[0-9]+$/ {valid++}
     END {exit !(NR==1 && valid==1)}' "$path"
}
