#!/usr/bin/env bash
# Wake-outcome ledger: the durable record of what every supervision wake cost
# the coordinator, and how every task ended.
#
# This file is the single owner of the ledger's record format, its closed
# outcome vocabulary, and its append semantics.
#
# WHERE: data/wake-ledger.tsv in the firstmate home (FM_WAKE_LEDGER overrides
# the full path). It lives under data/, not state/, because it is durable
# evidence spanning weeks and teardown clears state/<id>.* for every task that
# finishes.
#
# FORMAT: one record per line, tab-separated, three fixed positional fields
# followed by a key=value tail:
#
#   <schema>\t<record>\t<epoch>\t<key>=<value>\t<key>=<value>...
#
# Position 1 is the schema token (v1), position 2 the record kind, position 3
# the epoch seconds this record was written. Per-line versioning rather than a
# file header keeps an append-only file readable across a format change; a
# key=value tail lets the three record kinds carry different fields and lets a
# consumer add fields without invalidating existing lines or parsers.
#
# THREE RECORD KINDS:
#
#   wake     one per deduped drained wake-queue row, written by
#            bin/fm-wake-drain.sh. Deterministic - no judgment involved.
#            Fields: seq (the wake-queue sequence), kind, key, task, queued
#            (epoch the watcher enqueued), latency (seconds the wake waited
#            for the coordinator).
#
#   outcome  one per handled wake, written by the coordinator through this
#            script's `outcome` subcommand and joined to its wake record on
#            the (seq, queued) pair. Fields: seq, queued (copied from the
#            matching wake record, or unknown when none is resolvable),
#            outcome, task, after (seconds since the wake record), and
#            optional defect and note.
#
# The durable join identity is the (seq, queued) pair, not seq alone: seq
# comes from state/.wake-queue.seq, which restarts when state/ is wiped or a
# home is rebuilt while this file survives, so queued disambiguates a reused
# sequence.
#
#   task     one terminal line per task, written by bin/fm-teardown.sh
#            immediately before the task metadata is deleted - the last moment
#            the harness/model/effort join exists. Fields: task, harness,
#            model, effort, mode, kind, project, backend, outcome, route,
#            escalated, findings, pr.
#
# The wake half is written deterministically and the outcome half by the
# coordinator ON PURPOSE. A single coordinator-written line would make measured
# attention cost fall whenever the coordinator skipped the recording step, so
# the metric would move without the underlying quantity moving. The split gives
# a denominator that is stable under no change and makes missing coverage a
# reported number instead of a silent undercount.
#
# The wake count per task is deliberately NOT stored on the task record: it is
# computed from that task's wake records, so the same fact is never serialized
# twice and cannot drift.
#
# CLOSED OUTCOME VOCABULARY, in coordinator terms:
#   absorbed        reached me and needed nothing
#   inspected       I read deeper state
#   steered         I sent the worker an instruction
#   decided         I answered a gate or decision
#   escalated       I took it to the captain
#   repaired        I recovered a stuck or broken worker
#   false-positive  the wake should not have fired
# An unrecognized token is refused with exit 2 and nothing is written.
#
# APPEND SEMANTICS: every record is one printf appended with >> and no lock at
# all. Each line is capped at 1024 characters, well under the 4096-byte
# PIPE_BUF bound, so concurrent appends from the drain, a coordinator
# invocation, and teardown interleave as whole lines on a local POSIX
# filesystem. Every value is sanitized (tab, CR and LF collapse to a space,
# control characters are stripped) and truncated to its field cap. Nothing ever
# rewrites, rotates, or truncates the file.
#
# THE LEDGER MUST NEVER BLOCK OR DELAY A WAKE. Callers uphold that: the drain
# invokes this script only after its authoritative boundary (raw rows printed,
# drain temp deleted, queue lock released), with stdout discarded and the
# failure ignored, so a ledger problem can change neither the drain's exit
# status nor the raw rows the coordinator reads as its work queue. This script
# takes no lock, so it cannot contend with fm_wake_append.
#
# Usage:
#   fm-wake-ledger.sh drain-record
#       Read deduped drained queue rows (epoch/seq/kind/key/payload TSV) on
#       stdin and append one wake record each. Invalid rows are skipped.
#   fm-wake-ledger.sh outcome <token> <seq> [<seq>...]
#                     [--task <id>] [--defect <class>] [--note <text>]
#       Append one outcome record per seq. task and after are resolved from the
#       matching wake record when --task is not given.
#   fm-wake-ledger.sh task <id> [--outcome landed|failed|abandoned]
#                     [--harness H] [--model M] [--effort E] [--mode M]
#                     [--kind K] [--project P] [--backend B] [--pr URL]
#                     [--route R] [--escalated yes|no] [--findings N]
#       Append one terminal task record. Absent facts record as unknown rather
#       than being guessed. Called by teardown, which supplies them from the
#       task metadata it is about to delete.
#   fm-wake-ledger.sh report [--since-days <n>]
#       Summarize the ledger: wake volume and coverage, response latency,
#       outcome mix, terminal task outcomes, and the per-profile model join.
#       The ledger file itself remains the machine interface.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fm-wake-lib.sh owns FM_ROOT/FM_HOME/STATE resolution and the validated
# status-key mapping this script reuses for task attribution.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# fm-pr-lib.sh owns fm_task_id_path_safe, the task-id path-safety predicate.
# Reused rather than re-stated so there is one owner of that rule.
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="${FM_WAKE_LEDGER:-$DATA/wake-ledger.tsv}"
LEDGER_SCHEMA=v1
LEDGER_LINE_MAX=1024
LEDGER_KEY_MAX=200
LEDGER_NOTE_MAX=200
LEDGER_ID_MAX=64
LEDGER_SHORT_MAX=64
# Bounded backward read for resolving an outcome's wake record. A coordinator
# records an outcome within a turn or two of the drain, so the matching wake
# record is always near the tail; the cap keeps the lookup constant-time.
LEDGER_LOOKUP_TAIL=${FM_WAKE_LEDGER_LOOKUP_TAIL:-500}
# Busiest-task rows the report prints before summarizing the remainder. The
# report always states how many rows it left out - a silent cap would read as
# "this is all of it".
LEDGER_REPORT_TOP=${FM_WAKE_LEDGER_REPORT_TOP:-10}

TAB=$(printf '\t')

usage() {
  LC_ALL=C awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SCRIPT_DIR/fm-wake-ledger.sh"
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

# --- serialization ----------------------------------------------------------

ledger_sanitize() {  # <value> <cap>
  local v=${1-} cap=$2
  v=$(printf '%s' "$v" | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -d '[:cntrl:]')
  [ "${#v}" -le "$cap" ] || v=${v:0:$cap}
  printf '%s' "$v"
}

# One record: a single printf append, no lock, capped so the write stays within
# the atomic-append bound. Returns nonzero on failure; every caller treats that
# as best effort.
ledger_append() {  # <epoch> <record> <field>...
  local epoch=$1 record=$2 line field dir
  shift 2
  line="$LEDGER_SCHEMA$TAB$record$TAB$epoch"
  for field in "$@"; do
    line="$line$TAB$field"
  done
  [ "${#line}" -le "$LEDGER_LINE_MAX" ] || line=${line:0:$LEDGER_LINE_MAX}
  dir=$(dirname "$LEDGER")
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s\n' "$line" >> "$LEDGER" 2>/dev/null || return 1
}

# --- task attribution -------------------------------------------------------

# Resolve a live task endpoint (a tmux window, an Orca terminal) to its task id
# through the recorded metadata, which is the only authority for that mapping.
ledger_task_for_endpoint() {  # <endpoint>
  local key=$1 meta id
  [ -n "$key" ] || return 1
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    if grep -qxF -e "window=$key" -e "terminal=$key" "$meta" 2>/dev/null; then
      id=$(basename "$meta" .meta)
      fm_task_id_path_safe "$id" || return 1
      printf '%s' "$id"
      return 0
    fi
  done
  # The tmux window convention is fm-<id>, applied only when that task's
  # metadata actually exists so the convention can never invent an id.
  case "$key" in
    fm-*)
      id=${key#fm-}
      if fm_task_id_path_safe "$id" && [ -f "$STATE/$id.meta" ]; then
        printf '%s' "$id"
        return 0
      fi
      ;;
  esac
  return 1
}

# A task id wherever one is honestly derivable, "-" otherwise. Heartbeats are
# fleet-wide and never carry one.
ledger_task_for_key() {  # <kind> <key>
  local kind=$1 key=$2 id
  case "$kind" in
    signal)
      if fm_wake_status_key_map "$key"; then
        id=${FM_WAKE_STATUS_KEY%.status}
        printf '%s' "$id"
        return 0
      fi
      ;;
    check)
      id=$(basename "$key")
      case "$id" in
        *.check.sh)
          id=${id%.check.sh}
          if fm_task_id_path_safe "$id"; then
            printf '%s' "$id"
            return 0
          fi
          ;;
      esac
      ;;
    stale)
      if id=$(ledger_task_for_endpoint "$key"); then
        printf '%s' "$id"
        return 0
      fi
      ;;
  esac
  printf '%s' -
}

# --- subcommands ------------------------------------------------------------

cmd_drain_record() {
  local now epoch seq kind key task latency
  now=$(date +%s)
  # Test-only latency seam, mirroring the drain's own enrichment seam: it proves
  # that a slow ledger phase cannot delay or block a concurrent wake append.
  case "${FM_WAKE_LEDGER_TEST_DELAY:-0}" in
    0) ;;
    ''|*[!0-9]*) ;;
    *) sleep "$FM_WAKE_LEDGER_TEST_DELAY" ;;
  esac
  while IFS="$TAB" read -r epoch seq kind key _; do
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    case "$kind" in
      signal|stale|check|heartbeat) ;;
      *) continue ;;
    esac
    task=$(ledger_task_for_key "$kind" "$key")
    # A check key is an absolute script path. Only its basename identifies the
    # check, and the home path has no business in durable evidence.
    case "$key" in
      /*) key=$(basename "$key") ;;
    esac
    latency=$((now - epoch))
    [ "$latency" -ge 0 ] || latency=0
    ledger_append "$now" wake \
      "seq=$seq" \
      "kind=$kind" \
      "key=$(ledger_sanitize "$key" "$LEDGER_KEY_MAX")" \
      "task=$task" \
      "queued=$epoch" \
      "latency=$latency" || return 0
  done
  return 0
}

# The wake record for <seq>, as "<epoch><TAB><task><TAB><queued>", from a
# bounded tail read.
ledger_lookup_wake() {  # <seq>
  local seq=$1 found
  [ -f "$LEDGER" ] || return 1
  found=$(tail -n "$LEDGER_LOOKUP_TAIL" "$LEDGER" 2>/dev/null | LC_ALL=C awk -F '\t' \
    -v want="seq=$seq" -v schema="$LEDGER_SCHEMA" '
    $1 == schema && $2 == "wake" {
      match_seq = 0
      row_task = "-"
      row_queued = ""
      for (i = 4; i <= NF; i++) {
        if ($i == want) match_seq = 1
        else if (substr($i, 1, 5) == "task=") row_task = substr($i, 6)
        else if (substr($i, 1, 7) == "queued=") row_queued = substr($i, 8)
      }
      if (match_seq) { ts = $3; task = row_task; queued = row_queued; hit = 1 }
    }
    END { if (hit) printf "%s\t%s\t%s", ts, task, queued }
  ') || return 1
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

cmd_outcome() {
  local token='' task='' defect='' note='' now seq wake_row wake_rest wake_ts wake_task wake_queued after
  local -a seqs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || die "--task needs a value"; task=$2; shift 2 ;;
      --defect) [ "$#" -ge 2 ] || die "--defect needs a value"; defect=$2; shift 2 ;;
      --note) [ "$#" -ge 2 ] || die "--note needs a value"; note=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown flag for outcome: $1" ;;
      *)
        if [ -z "$token" ]; then
          token=$1
        else
          seqs+=("$1")
        fi
        shift
        ;;
    esac
  done

  [ -n "$token" ] || die "outcome needs a token and at least one wake sequence"
  case "$token" in
    absorbed|inspected|steered|decided|escalated|repaired|false-positive) ;;
    *) die "unknown outcome token: $token (absorbed inspected steered decided escalated repaired false-positive)" ;;
  esac
  [ "${#seqs[@]}" -gt 0 ] || die "outcome needs at least one wake sequence"
  for seq in "${seqs[@]}"; do
    case "$seq" in
      ''|*[!0-9]*) die "wake sequence must be a number: $seq" ;;
    esac
  done
  if [ -n "$task" ] && ! fm_task_id_path_safe "$task"; then
    die "unsafe task id: $task"
  fi
  case "$defect" in
    '') ;;
    *[!A-Za-z0-9._-]*) die "defect class must be [A-Za-z0-9._-]: $defect" ;;
  esac

  now=$(date +%s)
  for seq in "${seqs[@]}"; do
    wake_task=$task
    wake_queued=unknown
    after=unknown
    if wake_row=$(ledger_lookup_wake "$seq"); then
      wake_ts=${wake_row%%"$TAB"*}
      case "$wake_ts" in
        ''|*[!0-9]*) wake_ts= ;;
      esac
      wake_rest=${wake_row#*"$TAB"}
      if [ -z "$wake_task" ]; then
        wake_task=${wake_rest%%"$TAB"*}
      fi
      wake_queued=${wake_rest#*"$TAB"}
      case "$wake_queued" in
        ''|*[!0-9]*) wake_queued=unknown ;;
      esac
      if [ -n "$wake_ts" ]; then
        after=$((now - wake_ts))
        [ "$after" -ge 0 ] || after=0
      fi
    fi
    [ -n "$wake_task" ] || wake_task=-
    set -- \
      "seq=$seq" \
      "queued=$wake_queued" \
      "outcome=$token" \
      "task=$(ledger_sanitize "$wake_task" "$LEDGER_ID_MAX")" \
      "after=$after"
    [ -z "$defect" ] || set -- "$@" "defect=$(ledger_sanitize "$defect" "$LEDGER_SHORT_MAX")"
    [ -z "$note" ] || set -- "$@" "note=$(ledger_sanitize "$note" "$LEDGER_NOTE_MAX")"
    ledger_append "$now" outcome "$@" || {
      printf 'error: could not append outcome record for wake %s to %s\n' "$seq" "$LEDGER" >&2
      return 1
    }
  done
  return 0
}

cmd_task() {
  local id='' outcome=landed route=unknown escalated=unknown findings=unknown
  local harness=unknown model=unknown effort=unknown mode=unknown kind=unknown
  local project=unknown backend=unknown pr='' now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --outcome) [ "$#" -ge 2 ] || die "--outcome needs a value"; outcome=$2; shift 2 ;;
      --harness) [ "$#" -ge 2 ] || die "--harness needs a value"; harness=$2; shift 2 ;;
      --model) [ "$#" -ge 2 ] || die "--model needs a value"; model=$2; shift 2 ;;
      --effort) [ "$#" -ge 2 ] || die "--effort needs a value"; effort=$2; shift 2 ;;
      --mode) [ "$#" -ge 2 ] || die "--mode needs a value"; mode=$2; shift 2 ;;
      --kind) [ "$#" -ge 2 ] || die "--kind needs a value"; kind=$2; shift 2 ;;
      --project) [ "$#" -ge 2 ] || die "--project needs a value"; project=$2; shift 2 ;;
      --backend) [ "$#" -ge 2 ] || die "--backend needs a value"; backend=$2; shift 2 ;;
      --pr) [ "$#" -ge 2 ] || die "--pr needs a value"; pr=$2; shift 2 ;;
      --route) [ "$#" -ge 2 ] || die "--route needs a value"; route=$2; shift 2 ;;
      --escalated) [ "$#" -ge 2 ] || die "--escalated needs a value"; escalated=$2; shift 2 ;;
      --findings) [ "$#" -ge 2 ] || die "--findings needs a value"; findings=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown flag for task: $1" ;;
      *) [ -z "$id" ] || die "task takes one task id"; id=$1; shift ;;
    esac
  done

  [ -n "$id" ] || die "task needs a task id"
  fm_task_id_path_safe "$id" || die "unsafe task id: $id"
  case "$outcome" in
    landed|failed|abandoned) ;;
    *) die "unknown terminal outcome: $outcome (landed failed abandoned)" ;;
  esac
  case "$escalated" in
    yes|no|unknown) ;;
    *) die "--escalated must be yes, no, or unknown: $escalated" ;;
  esac
  case "$findings" in
    unknown|'') findings=unknown ;;
    *[!0-9]*) die "--findings must be a count or unknown: $findings" ;;
  esac

  # A project path never enters the ledger; only its basename identifies it.
  project=$(basename "$project")

  now=$(date +%s)
  set -- \
    "task=$(ledger_sanitize "$id" "$LEDGER_ID_MAX")" \
    "harness=$(ledger_sanitize "${harness:-unknown}" "$LEDGER_SHORT_MAX")" \
    "model=$(ledger_sanitize "${model:-unknown}" "$LEDGER_KEY_MAX")" \
    "effort=$(ledger_sanitize "${effort:-unknown}" "$LEDGER_SHORT_MAX")" \
    "mode=$(ledger_sanitize "${mode:-unknown}" "$LEDGER_SHORT_MAX")" \
    "kind=$(ledger_sanitize "${kind:-unknown}" "$LEDGER_SHORT_MAX")" \
    "project=$(ledger_sanitize "${project:-unknown}" "$LEDGER_SHORT_MAX")" \
    "backend=$(ledger_sanitize "${backend:-unknown}" "$LEDGER_SHORT_MAX")" \
    "outcome=$outcome" \
    "route=$(ledger_sanitize "${route:-unknown}" "$LEDGER_SHORT_MAX")" \
    "escalated=$escalated" \
    "findings=$findings"
  [ -z "$pr" ] || set -- "$@" "pr=$(ledger_sanitize "$pr" "$LEDGER_KEY_MAX")"
  ledger_append "$now" task "$@" || {
    printf 'error: could not append terminal record for task %s to %s\n' "$id" "$LEDGER" >&2
    return 1
  }
  return 0
}

cmd_report() {
  local since_days='' cutoff=0 tmp now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --since-days) [ "$#" -ge 2 ] || die "--since-days needs a value"; since_days=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag for report: $1" ;;
    esac
  done
  case "$since_days" in
    '') ;;
    *[!0-9]*) die "--since-days must be a number: $since_days" ;;
    *)
      now=$(date +%s)
      cutoff=$((now - since_days * 86400))
      ;;
  esac

  if [ ! -f "$LEDGER" ]; then
    printf 'wake ledger: %s (absent - nothing recorded yet)\n' "$LEDGER"
    return 0
  fi

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-wake-ledger-report.XXXXXX") || die "cannot create a work directory"
  trap 'rm -rf "$tmp"' EXIT

  printf 'wake ledger: %s\n' "$LEDGER"
  if [ -n "$since_days" ]; then
    printf 'window: last %s day(s)\n' "$since_days"
  else
    printf 'window: all records\n'
  fi
  printf '\n'

  LC_ALL=C awk -F '\t' \
    -v schema="$LEDGER_SCHEMA" \
    -v cutoff="$cutoff" \
    -v top="$LEDGER_REPORT_TOP" \
    -v latfile="$tmp/lat" '
    function fieldset(   i, p) {
      split("", f)
      for (i = 4; i <= NF; i++) {
        p = index($i, "=")
        if (p > 0) f[substr($i, 1, p - 1)] = substr($i, p + 1)
      }
    }
    $1 != schema { next }
    $3 + 0 < cutoff { next }
    {
      fieldset()
    }
    $2 == "wake" {
      seq = f["seq"]
      q = f["queued"]
      if (q == "") q = "unknown"
      # A drain crash inside its at-least-once micro-gap can replay a wake, so
      # count distinct (seq, queued) pairs rather than lines. seq alone is not
      # identity: state/.wake-queue.seq restarts across a state wipe while this
      # file survives, so a reused seq needs queued to disambiguate. An unknown
      # queued cannot identify a record, so it never dedups - silently merging
      # unidentifiable records is exactly the undercount this guards against.
      if (q != "unknown") {
        if ((seq, q) in wake_seen) next
        wake_seen[seq, q] = 1
      }
      wakes++
      by_kind[f["kind"]]++
      t = f["task"]
      if (t != "" && t != "-") { wakes_by_task[t]++; }
      if (f["latency"] ~ /^[0-9]+$/) print f["latency"] > latfile
      next
    }
    $2 == "outcome" {
      seq = f["seq"]
      q = f["queued"]
      if (q == "") q = "unknown"
      # Same pair identity and same unknown rule as the wake records above.
      if (q != "unknown") {
        if ((seq, q) in outcome_seen) next
        outcome_seen[seq, q] = 1
      }
      outcomes++
      by_outcome[f["outcome"]]++
      t = f["task"]
      if (t == "" || t == "-") { unattributed++; next }
      outcome_by_task[t, f["outcome"]]++
      next
    }
    $2 == "task" {
      t = f["task"]
      # The most recent terminal line wins if a task id was ever reused.
      profile[t] = f["harness"] "/" f["model"] "/" f["effort"]
      terminal[t] = f["outcome"]
      next
    }
    END {
      printf "wakes: %d total", wakes + 0
      if (wakes > 0) {
        covered = 0
        for (s in wake_seen) if (s in outcome_seen) covered++
        printf ", %d with a recorded outcome, %d unrecorded (%d%% coverage)",
          covered, wakes - covered, int((covered * 100.0 / wakes) + 0.5)
      }
      printf "\n"
      if (wakes > 0) {
        printf "  by kind:"
        split("signal stale check heartbeat", order, " ")
        for (i = 1; i <= 4; i++) if (order[i] in by_kind) printf "  %s %d", order[i], by_kind[order[i]]
        printf "\n"
      }

      printf "\noutcomes: %d recorded", outcomes + 0
      if (unattributed > 0) printf " (%d not attributable to a task)", unattributed
      printf "\n"
      if (outcomes > 0) {
        printf "  by token:"
        split("absorbed inspected steered decided escalated repaired false-positive", ov, " ")
        for (i = 1; i <= 7; i++) if (ov[i] in by_outcome) printf "  %s %d", ov[i], by_outcome[ov[i]]
        printf "\n"
      }

      tasks = 0
      for (t in terminal) { tasks++; term_count[terminal[t]]++ }
      printf "\ntasks: %d terminal", tasks
      if (tasks > 0) {
        printf " ("
        split("landed failed abandoned", tv, " ")
        first = 1
        for (i = 1; i <= 3; i++) if (tv[i] in term_count) {
          printf "%s%s %d", (first ? "" : "  "), tv[i], term_count[tv[i]]
          first = 0
        }
        printf ")"
      }
      printf "\n"

      if (tasks > 0) {
        printf "\nper profile (harness/model/effort):\n"
        split("absorbed inspected steered decided escalated repaired false-positive", ov, " ")
        for (t in terminal) {
          p = profile[t]
          p_tasks[p]++
          p_wakes[p] += wakes_by_task[t] + 0
          for (i = 1; i <= 7; i++) {
            if ((t, ov[i]) in outcome_by_task) p_out[p, ov[i]] += outcome_by_task[t, ov[i]]
          }
        }
        for (p in p_tasks) {
          printf "  %-44s tasks %-4d wakes/task %-6.1f steered %-4d repaired %-4d escalated %-4d false-positive %d\n",
            p, p_tasks[p], p_wakes[p] / p_tasks[p],
            p_out[p, "steered"] + 0, p_out[p, "repaired"] + 0,
            p_out[p, "escalated"] + 0, p_out[p, "false-positive"] + 0
        }
      }

      shown = 0
      omitted = 0
      n = 0
      for (t in wakes_by_task) { n++; keys[n] = t }
      # Simple selection of the busiest tasks; n is small (tasks per window).
      if (n > 0) {
        printf "\nbusiest tasks by wake count:\n"
        for (i = 1; i <= n; i++) {
          for (j = i + 1; j <= n; j++) {
            if (wakes_by_task[keys[j]] > wakes_by_task[keys[i]]) {
              swap = keys[i]; keys[i] = keys[j]; keys[j] = swap
            }
          }
        }
        for (i = 1; i <= n; i++) {
          if (shown >= top) { omitted++; continue }
          printf "  %-36s %d\n", keys[i], wakes_by_task[keys[i]]
          shown++
        }
        if (omitted > 0) printf "  (%d more task(s) not shown)\n", omitted
      }
    }
  ' "$LEDGER"

  if [ -s "$tmp/lat" ]; then
    printf '\n'
    LC_ALL=C sort -n "$tmp/lat" | LC_ALL=C awk '
      { v[n++] = $1 + 0 }
      END {
        if (n == 0) exit
        printf "coordinator response latency (queued -> drained), seconds: min %d  median %d  p90 %d  max %d\n",
          v[0], v[int((n - 1) * 0.5)], v[int((n - 1) * 0.9)], v[n - 1]
      }
    '
  fi

  rm -rf "$tmp"
  trap - EXIT
  return 0
}

# --- entry ------------------------------------------------------------------

[ "$#" -ge 1 ] || { usage; exit 2; }
SUBCOMMAND=$1
shift
case "$SUBCOMMAND" in
  drain-record) cmd_drain_record "$@" ;;
  outcome) cmd_outcome "$@" ;;
  task) cmd_task "$@" ;;
  report) cmd_report "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown subcommand: $SUBCOMMAND (drain-record outcome task report)" ;;
esac
