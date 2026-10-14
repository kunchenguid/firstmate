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
#   consume a returned validation call was consumed or reported [reason=]
#   ack     the worker acknowledged (an inbox record moved to handled/ also
#           counts, via inbox=)
#   start   the action's native execution began [units=N]
#   result  outcome=ok|refused|failed|answered [reason=] [native=1]
#   accept  receipt=<native acceptance path>
# Native receipts: state/<task>.action-receipts/<action>, one TSV record:
#   v2 task action head admitted_run attempt outcome epoch resulting_run
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
#   result-unconsumed returned validation call not consumed within the start bound
#   gate-overdue       a gate class past its due time and unanswered
#   none               everything else
# A started action with no result is executing and never an incident, and a
# live hold suppresses only until its finite deadline. The fold never writes,
# closes, answers, interrupts or restarts anything; routing an incident to its
# owner is bin/fm-watch.sh's job, through its existing durable check queue.
#
# OBSERVED START. An ordinary steer has no native execution owner, so the
# watcher poll calls fm_action_observe, the ONLY writer of a start it did not
# witness itself: it records `start` with source=observed:<kind> when
# model-independent worker-originated evidence postdates the admit - a status
# line the worker stamped later, or a worktree head that moved. An inbox
# acknowledgement is never such evidence. Native lifecycle operations
# (exit|relaunch|interrupt) are never observed; only their owner records them.
#
# REGISTER. fm_action_register answers, for one live task and from files alone:
# owner, last observed progress with its source, next checkpoint and verdict.
# The last progress is the newest of ledger start/result/consume events, the
# worker's own stamped status line, the worktree head commit time, an observed
# note (state/<task>.progress, written by the watcher from a provably running
# pipeline), and the task record itself. A task the worker owns that passes its
# checkpoint without progress is the `checkpoint-missed` incident; a task
# waiting on firstmate or a declared wait is listed with its owner and never an
# incident here, because the existing decision and wait paths own those.
#
# LADDER. A reported incident advances through bounded stages in the watcher,
# each emitted once: 0 report, 1 triage (a ledger action `triage-<id>` owned by
# the triage owner, ACKed by the wake acknowledgement and closed only by a
# verified result), 2 authority escalation. See fm_action_stage.
set -u

# shellcheck source=bin/fm-operational-input.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-operational-input.sh"

FM_ACTION_START_SECS_DEFAULT=300
FM_ACTION_CHECKPOINT_SECS_DEFAULT=3600
FM_ACTION_TRIAGE_SECS_DEFAULT=600
FM_ACTION_ESCALATE_SECS_DEFAULT=1800

fm_action_start_secs() {
  local s=${FM_ACTION_START_SECS:-$FM_ACTION_START_SECS_DEFAULT}
  case "$s" in ''|*[!0-9]*) s=$FM_ACTION_START_SECS_DEFAULT ;; esac
  printf '%s' "$s"
}

fm_action_bound() {  # <env-name> <default> -> positive integer seconds
  local v=${!1:-}
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  [ "$v" -gt 0 ] 2>/dev/null || v=$2
  printf '%s' "$v"
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
  local ledger handled consume_secs
  consume_secs=$(fm_action_start_secs)
  ledger=$(fm_action_ledger "$1" "$2")
  [ -f "$ledger" ] || return 0
  handled=$(fm_action_handled_names "$1" "$2")
  awk -F'\t' -v now="$3" -v handled="$handled" -v consume_secs="$consume_secs" '
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
        else if (ev == "result") { outcome[id] = kv($0, "outcome"); returned[id] = $2; consumed[id] = 0 }
        else if (ev == "consume") consumed[id] = 1
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
          else if (op[id] ~ /^no-mistakes axi (respond|run)( |$)/ && returned[id] > 0 && !consumed[id] && now > returned[id] + consume_secs)
            inc = "result-unconsumed"
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
  local state=$1 task=$2 rec=$3 text=$4 delivery_mode=${5:-} id head run wt at
  [ "$delivery_mode" != fire-and-forget ] || return 0
  id="steer-${rec##*/}"; id=${id%.msg}
  fm_action_exists "$state" "$task" "$id" && return 0
  # The inbox keeps the transport envelope; native control binds the request.
  if fm_message_from_firstmate "$text"; then
    text=${text#"$FM_FROMFIRST_MARK"}
    if [[ $text =~ ^corr=[a-fA-F0-9]{16}[[:blank:]]+ ]]; then
      text=${text#"${BASH_REMATCH[0]}"}
    fi
  fi
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
  local state=$1 task=$2 id=$3 head=$4 run=$5 attempt=$6 outcome=$7 result_run=${8:-$5} at dir tmp
  at=$(date +%s)
  [ "$(fm_action_field "$state" "$task" "$id" head)" = "$head" ] && \
    [ "$(fm_action_field "$state" "$task" "$id" run)" = "$run" ] && \
    [ "$(fm_action_field "$state" "$task" "$id" attempt)" = "$attempt" ] || return 1
  if [ "$result_run" != "$run" ]; then
    [ "$(fm_action_field "$state" "$task" "$id" operation)" = relaunch ] && [ -n "$result_run" ] || return 1
  fi
  dir="$state/$task.action-receipts"
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.receipt.XXXXXX") || return 1
  if ! { printf 'v2\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$task" "$id" "$head" "$run" "$attempt" "$outcome" "$at" "$result_run" > "$tmp" && \
    mv "$tmp" "$dir/$id"; }; then
    rm -f "$tmp"
    return 1
  fi
  fm_action_append "$state" "$task" "$at" "$id" result "outcome=$outcome" "reason=native:$outcome" native=1 "result_run=$result_run"
}

fm_action_verify_receipt() {
  local state=$1 task=$2 id=$3 path=$4 expected head run attempt receipt_at result_at phase wt current_run current_head result_run native_run
  expected="$state/$task.action-receipts/$id"
  [ "$path" = "$expected" ] && [ -f "$path" ] && [ ! -L "$path" ] || return 1
  head=$(fm_action_field "$state" "$task" "$id" head) || return 1
  run=$(fm_action_field "$state" "$task" "$id" run) || return 1
  attempt=$(fm_action_field "$state" "$task" "$id" attempt) || return 1
  [ -n "$head" ] && [ -n "$run" ] && [ -n "$attempt" ] || return 1
  wt=$(awk -F= '$1=="worktree" {print substr($0,10); exit}' "$state/$task.meta") || return 1
  current_run=$(awk -F= '$1=="spawn_gen" {print substr($0,11); exit}' "$state/$task.meta") || return 1
  current_head=$(git -C "${wt:-/dev/null}" rev-parse HEAD 2>/dev/null) || return 1
  result_run=$(awk -F'\t' 'NR==1 {print $9}' "$path") || return 1
  [ -n "$result_run" ] && [ "$current_run" = "$result_run" ] && [ "$current_head" = "$head" ] || return 1
  if [ "$result_run" != "$run" ]; then
    [ "$(fm_action_field "$state" "$task" "$id" operation)" = relaunch ] || return 1
  fi
  native_run=$(awk -F'\t' -v id="$id" '$3==id && $4=="result" {run=""; for(i=5;i<=NF;i++) if(index($i,"result_run=")==1) run=substr($i,12)} END {print run}' "$(fm_action_ledger "$state" "$task")") || return 1
  [ "$native_run" = "$result_run" ] || return 1
  receipt_at=$(awk -F'\t' 'NR==1 {print $8}' "$path") || return 1
  result_at=$(awk -F'\t' -v id="$id" '$3==id && $4=="admit" {admitted=$2}
    $3==id && $4=="result" {at=""; ok=0; native=0; for(i=5;i<=NF;i++) {if($i=="outcome=ok") ok=1; if($i=="native=1") native=1} if(ok && native && $2>=admitted) at=$2}
    END {print at}' "$(fm_action_ledger "$state" "$task")") || return 1
  [ -n "$result_at" ] && [ "$receipt_at" = "$result_at" ] || return 1
  phase=$(fm_action_fold "$state" "$task" "$(date +%s)" | awk -F'\t' -v id="$id" '$1==id {print $3 ":" $4}') || return 1
  case "$phase" in resulted:none|accepted:none) ;; *) return 1 ;; esac
  awk -F'\t' -v task="$task" -v id="$id" -v head="$head" -v run="$run" -v attempt="$attempt" -v result_run="$result_run" \
    'NF==9 && $1=="v2" && $2==task && $3==id && $4==head && $5==run && $6==attempt && $7=="ok" && $8 ~ /^[0-9]+$/ && $9==result_run {valid++}
     END {exit !(NR==1 && valid==1)}' "$path"
}

fm_action_meta() {  # <state-dir> <task-id> <key>
  awk -F= -v key="$3" '$1 == key { print substr($0, length(key) + 2); exit }' "$1/$2.meta" 2>/dev/null || true
}

# Newest worker-stamped `[at=<epoch>]` in the task's status log, else empty.
fm_action_status_epoch() {  # <state-dir> <task-id>
  awk 'match($0, /\[at=[0-9]+\]/) { e = substr($0, RSTART + 4, RLENGTH - 5) + 0; if (e > m) m = e }
       END { if (m) print m }' "$1/$2.status" 2>/dev/null || true
}

fm_action_status_verb() {  # <state-dir> <task-id>
  awk 'NF { v = $1 } END { sub(/:$/, "", v); print v }' "$1/$2.status" 2>/dev/null || true
}

# Commit time of the worktree head, else empty.
fm_action_head_epoch() {  # <state-dir> <task-id>
  local wt
  wt=$(fm_action_meta "$1" "$2" worktree)
  [ -n "$wt" ] || return 0
  git -C "$wt" log -1 --format=%ct 2>/dev/null || true
}

fm_action_lifecycle_operation() {  # <operation>
  case "$1" in exit|relaunch|interrupt) return 0 ;; esac
  return 1
}

# Record a start for queued/acked steered actions that model-independent
# worker-originated evidence postdates. The one writer of an observed start.
fm_action_observe() {  # <state-dir> <task-id> <now-epoch>
  local state=$1 task=$2 now=$3 id class phase incident age owner due operation at0 source head status_at wt_head kind
  [ -f "$(fm_action_ledger "$state" "$task")" ] || return 0
  status_at=$(fm_action_status_epoch "$state" "$task")
  wt_head=$(git -C "$(fm_action_meta "$state" "$task" worktree)" rev-parse HEAD 2>/dev/null) || wt_head=
  while IFS=$'\t' read -r id class phase incident age owner due operation; do
    [ "$class" = authorized ] || continue
    case "$phase" in queued|acked) ;; *) continue ;; esac
    source=$(fm_action_field "$state" "$task" "$id" source)
    case "$source" in firstmate-steer:*) ;; *) continue ;; esac
    ! fm_action_lifecycle_operation "$operation" || continue
    at0=$((now - age))
    head=$(fm_action_field "$state" "$task" "$id" head)
    kind=
    if [ -n "$status_at" ] && [ "$status_at" -gt "$at0" ]; then kind=status
    elif [ -n "$head" ] && [ -n "$wt_head" ] && [ "$head" != "$wt_head" ]; then kind='head'
    fi
    [ -n "$kind" ] || continue
    fm_action_append "$state" "$task" "$now" "$id" start "source=observed:$kind"
  done < <(fm_action_fold "$state" "$task" "$now")
}

# Watcher-observed progress that no file in the task's own record shows, such as
# a provably running pipeline. One line: <epoch> <source>.
fm_action_note_progress() {  # <state-dir> <task-id> <epoch> <source>
  local f=$1/$2.progress tmp
  tmp=$(mktemp "$1/.progress.XXXXXX") || return 1
  if ! { printf '%s\t%s\n' "$3" "$(fm_action_clean "$4")" > "$tmp" && mv "$tmp" "$f"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# Newest progress evidence for a task: "<epoch>\t<source>". Always prints a line;
# the task record itself is the floor so a fresh task is not instantly missed.
fm_action_task_progress() {  # <state-dir> <task-id>
  local state=$1 task=$2 best=0 src=none e ledger
  _fm_action_progress_pick() {  # <epoch> <source>
    case "$1" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$1" -gt "$best" ]; then best=$1; src=$2; fi
  }
  if declare -F fm_path_mtime >/dev/null 2>&1 && [ -f "$state/$task.meta" ]; then
    _fm_action_progress_pick "$(fm_path_mtime "$state/$task.meta")" task-record
  fi
  _fm_action_progress_pick "$(fm_action_status_epoch "$state" "$task")" status
  _fm_action_progress_pick "$(fm_action_head_epoch "$state" "$task")" head-commit
  e=$(awk -F'\t' 'NF >= 2 { print $1 }' "$state/$task.progress" 2>/dev/null | tail -1 || true)
  _fm_action_progress_pick "$e" "$(awk -F'\t' 'NR==1 { print $2 }' "$state/$task.progress" 2>/dev/null || true)"
  ledger=$(fm_action_ledger "$state" "$task")
  if [ -f "$ledger" ]; then
    e=$(awk -F'\t' '$1 == "v1" && ($4 == "start" || $4 == "result" || $4 == "consume") && $3 !~ /^triage-/ { if ($2 + 0 > m) m = $2 + 0 } END { if (m) print m }' "$ledger")
    _fm_action_progress_pick "$e" ledger
  fi
  printf '%s\t%s\n' "$best" "$src"
}

# One register line for a live non-secondmate task:
#   <task> <owner> <state> <last-progress> <source> <next-checkpoint> <verdict> <evidence>
# state: executing | waiting-firstmate | declared-wait. Only an executing task
# can be MISSED; the others are listed so every active item shows an owner.
fm_action_register() {  # <state-dir> <task-id> <now-epoch>
  local state=$1 task=$2 now=$3 verb last src owner st next verdict=ok kind open
  [ -f "$state/$task.meta" ] || return 0
  kind=$(fm_action_meta "$state" "$task" kind)
  [ "$kind" != secondmate ] || return 0
  [ -z "$(fm_action_meta "$state" "$task" remote_host)" ] || return 0
  IFS=$'\t' read -r last src < <(fm_action_task_progress "$state" "$task")
  verb=$(fm_action_status_verb "$state" "$task")
  case "$verb" in
    done|blocked|needs-decision|failed) owner=firstmate; st=waiting-firstmate ;;
    paused|captain-held) owner=declared-wait; st=declared-wait ;;
    *) owner=$task; st=executing ;;
  esac
  next=$((last + $(fm_action_bound FM_ACTION_CHECKPOINT_SECS "$FM_ACTION_CHECKPOINT_SECS_DEFAULT")))
  if [ "$st" = executing ] && [ "$now" -gt "$next" ]; then verdict=MISSED; fi
  # A decision the log still holds open outranks later events in fm-crew-state,
  # so show it beside the latest verb instead of silently choosing between them.
  open=
  if declare -F status_open_decisions >/dev/null 2>&1; then
    open=$(status_open_decisions "$state/$task.status" "$kind" 2>/dev/null | awk -F'\t' 'NR == 1 && $2 != "" { print " open-decision=" $2 ":" $1 }' || true)
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$task" "$owner" "$st" "$last" "$src" "$next" "$verdict" "status=${verb:-none} source=$src$open"
}

# Fold-shaped incident line for a MISSED register verdict, else nothing.
fm_action_checkpoint_incident() {  # <state-dir> <task-id> <now-epoch>
  local t owner st last src next verdict evidence
  IFS=$'\t' read -r t owner st last src next verdict evidence < <(fm_action_register "$@")
  [ "${verdict:-}" = MISSED ] || return 0
  printf 'checkpoint\tcheckpoint\t%s\tcheckpoint-missed\t%d\t%s\t%s\t%s\n' \
    "$st" "$(( $3 - last ))" "$owner" "$next" "no progress since $last ($evidence)"
}

# Ladder stage for an incident first reported at <first-epoch>:
# 0 report, 1 triage, 2 authority escalation.
fm_action_stage() {  # <first-epoch> <now-epoch>
  local age=$(( $2 - $1 ))
  if [ "$age" -ge "$(fm_action_bound FM_ACTION_ESCALATE_SECS "$FM_ACTION_ESCALATE_SECS_DEFAULT")" ]; then echo 2
  elif [ "$age" -ge "$(fm_action_bound FM_ACTION_TRIAGE_SECS "$FM_ACTION_TRIAGE_SECS_DEFAULT")" ]; then echo 1
  else echo 0; fi
}

# Admit the triage action for one incident episode (idempotent). The triage
# owner starts it and closes it with a result; `fm-action.sh result` verifies an ok.
fm_action_admit_triage() {  # <state-dir> <task-id> <triage-id> <target-id> <incident> <owner> <now> <operation-text>
  local state=$1 task=$2 id=$3 target=$4 incident=$5 owner=$6 now=$7 text=$8
  fm_action_exists "$state" "$task" "$id" && return 0
  fm_action_append "$state" "$task" "$now" "$id" admit class=authorized "owner=$owner" \
    "operation=$(fm_action_clean "$text")" "source=native:triage:$target:$incident" \
    "target=$target" "incident=$incident" "due=$((now + $(fm_action_start_secs)))" units=1 \
    head= run= attempt=
}

# Verdict of a triage action: resolved | refused | open.
fm_action_triage_state() {  # <state-dir> <task-id> <triage-id>
  local ledger
  ledger=$(fm_action_ledger "$1" "$2")
  [ -f "$ledger" ] || { echo open; return 0; }
  awk -F'\t' -v id="$3" '$3 == id && $4 == "result" {
      o = ""; for (i = 5; i <= NF; i++) if (index($i, "outcome=") == 1) o = substr($i, 9)
      r = (o == "ok" ? "resolved" : (o == "refused" || o == "failed" ? "refused" : r)) }
    END { print (r == "" ? "open" : r) }' "$ledger"
}

# True when the target of a triage action no longer shows its incident now.
fm_action_triage_verified() {  # <state-dir> <task-id> <triage-id> <now-epoch>
  local target incident
  target=$(fm_action_field "$1" "$2" "$3" target) || return 1
  [ -n "$target" ] || return 1
  incident=$(fm_action_field "$1" "$2" "$3" incident)
  if [ "$target" = checkpoint ]; then
    [ -z "$(fm_action_checkpoint_incident "$1" "$2" "$4")" ]
  else
    ! fm_action_incidents "$1" "$2" "$4" | awk -F'\t' -v id="$target" -v inc="$incident" '$1 == id && $4 == inc { f = 1 } END { exit !f }'
  fi
}

fm_action_retire() {
  local state=$1 task=$2 target=${3:-} queue_state=$1 lock status=0
  [ -d "$state" ] || return 0
  case "$state" in */parent-route) queue_state=${state%/parent-route} ;; esac
  lock="$queue_state/.wake-queue.lock"
  fm_lock_acquire_wait "$lock" || return 1
  rm -f "$state/$task.actions" "$state/$task.progress" "$state/.$task.checkpoint-checked" "$state/.$task.action-incident-"* || status=1
  rm -rf "$state/$task.action-receipts" || status=1
  if [ "$status" -eq 0 ]; then
    fm_wake_queue_prune_task_locked "$queue_state" "$task" "$target" "$state" || status=1
  fi
  fm_lock_release "$lock"
  return "$status"
}
