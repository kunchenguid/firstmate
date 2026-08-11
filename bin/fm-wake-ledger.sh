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
#            the harness/model/effort join exists - and by this script's
#            `sweep` for a task that declared failure and was never torn down.
#            Fields: task, harness, model, effort, mode, role, deliverable,
#            project, backend, outcome, outcome_source, route, escalated,
#            findings, critic_vendor, critic_model, critic_independence, pr.
#            role and deliverable are the task identity axes; a
#            record written before that split carries the retired single kind
#            field instead and is never rewritten, because this ledger is
#            append-only evidence.
#            A task id may carry more than one terminal line: `sweep` records a
#            declared failure at declaration time and a later teardown records
#            the same task's release. The LAST terminal line for a task id is
#            its outcome; every reader here already resolves it that way.
#
# THE TERMINAL OUTCOME DEFINITION. This script owns it.
#
#   landed     the task's change reached its delivery target.
#   failed     the task ended without producing its change.
#   abandoned  the task's unlanded work was deliberately discarded.
#
# The enum is deliberately three members and is pinned to the v1 line schema.
# Widening it belongs to the unified terminal vocabulary that will arrive under
# a new schema token, not to a fourth member bolted onto v1.
#
# An outcome is worth nothing without its evidence, so every terminal line also
# carries WHERE ITS OUTCOME CAME FROM, in outcome_source:
#
#   declared    the task's own status log declared it (`done:` or `failed:`).
#   discarded   an operator tore the task down with --force.
#   unreleased  `sweep` found a declared failure with no terminal line and no
#               teardown; the task was still holding state when this was
#               written.
#   assumed     nothing corroborated the outcome. This is the historical
#               default: teardown set outcome=landed as a constant, so a line
#               with no outcome_source field reads as assumed rather than as
#               evidence, and the pre-existing records stay honest without a
#               rewrite.
#
# assumed exists because the constant is the actual defect. Before it, a fleet
# record reading "40 terminal (landed 40)" was not a success rate: nothing
# produced `failed`, so the numerator could not move. Naming the unsupported
# records is what makes the supported ones countable.
#
# DIAGNOSTIC ONLY - NO RATE. `report` prints terminal outcome COUNTS and never
# a success rate, and it says so in its own output. Two authoritative records
# still disagree about the same changes: this ledger counts tasks the fleet
# released, while the no-mistakes pipeline counts validation runs, and a task
# can hold many runs or none. Until that divergence is reconciled, a ratio
# computed here would be a number about neither. The divergence is a KNOWN
# NAMED GAP, not an oversight, and `report` names it every time it prints
# terminal outcomes.
#
# THE COORDINATOR NAMES THE COST, NOT THE SEQUENCE. `outcome <token>` with no
# sequence resolves the most recent wake record no outcome record joins, and
# that is the normal path. The sequence was once positional and validated only
# as an integer, so a coordinator recording after the fact supplied remembered
# or placeholder numbers; each one stored queued=unknown, which is also what a
# legitimately wiped state/ produces, so the corruption was invisible. On
# 2026-08-04 that had fabricated 200 of 249 outcome records. An explicitly
# passed sequence that joins no wake record is now refused; --allow-unjoined
# keeps the genuine wiped-state/ case reachable and a guess unreachable, and
# `reconcile` counts the records that join nothing so a silent corruption
# becomes a number a session start can report.
#
# THE CRITIC FIELDS: harness/model/effort describe the MAKER. critic_vendor,
# critic_model and critic_independence describe the checker that reviewed those
# bytes, so "was the checker independent of the maker, and on which dimensions?"
# is answerable from the record instead of by archaeology through pipeline
# history.
#
#   critic_vendor         the model provider that reviewed (anthropic, openai)
#   critic_model          the reviewing model (claude-opus-5, gpt-5.6-sol)
#   critic_independence   the DERIVED per-dimension verdict, as
#                         process:<v>+model:<v>+vendor:<v>+pool:<v>, each one
#                         independent, not-independent, or unknown
#
# INDEPENDENCE IS DERIVED AND UNWRITABLE. bin/fm-independence-lib.sh computes it
# from the pipeline's own invocation records and this fleet's declared routing
# config; this script only records what that owner returns. There is deliberately
# no argument here that states a reviewing identity or an independence result,
# because a claim anyone can write is one that will eventually be written
# wrongly - and an independence claim that is merely asserted is worth nothing.
# bin/fm-certify.sh refuses certification on the same derivation, so the record
# and the refusal can never disagree.
#
# WHY FOUR DIMENSIONS AND NOT ONE WORD. It is measured in this fleet that the
# pipeline's reviewers consume one shared subscription window regardless of which
# runtime the worker used, so a different harness does not imply an independent
# verifier. "Independent model, same billing account" and "independent vendor
# entirely" are different facts, and a single boolean would destroy exactly the
# distinction a reader needs.
#
# A review the pipeline recorded without a vendor or model contributes no such
# fact and therefore never makes a field "mixed": absence is not evidence of a
# second vendor. A field is "mixed" only when two reviews of that task recorded
# genuinely different values.
#
# All fields record "unknown" when they cannot be resolved - never a guess, and
# never omitted, because a field that appears only on the happy path would make
# the vendor question look answerable while under-reporting it. "unknown" means
# NOT RESOLVABLE, not "no reviewer ran": the same record's mode field says
# whether a task took a pipeline-validated path at all, so that fact is never
# serialized twice. Records written before these fields existed are NEVER
# backfilled: a guessed identity is indistinguishable from an observed one
# afterwards, which is the corruption this ledger already suffered once.
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
#   fm-wake-ledger.sh outcome <token> [<seq>...] [--allow-unjoined]
#                     [--task <id>] [--defect <class>] [--note <text>]
#       With no seq, record against the most recent wake record no outcome
#       joins - the normal path. With one or more seq, append one outcome
#       record each; a seq matching no wake record is refused unless
#       --allow-unjoined says the wake records are genuinely gone. task and
#       after are resolved from the matching wake record when --task is absent.
#   fm-wake-ledger.sh task <id> [--outcome landed|failed|abandoned]
#                     [--source declared|discarded|unreleased|assumed]
#                     [--harness H] [--model M] [--effort E] [--mode M]
#                     [--role R] [--deliverable D] [--project P]
#                     [--backend B] [--pr URL]
#                     [--route R] [--escalated yes|no] [--findings N]
#                     [--critic-repo PATH] [--critic-branch B]
#       Append one terminal task record. Absent facts record as unknown rather
#       than being guessed, and an absent --source records assumed rather than
#       implying evidence nobody produced. Called by teardown, which supplies
#       them from the task metadata it is about to delete. --critic-repo with
#       --critic-branch names WHICH BYTES the reviewing identity is resolved for;
#       neither can assert what was found there, and there is no argument that
#       can.
#   fm-wake-ledger.sh task-record <id>
#       Print the LAST terminal record's key=value fields for a task, one per
#       line. Exit 1 when this ledger was read and holds no record for that id,
#       and exit 3 when the ledger itself could not be read - a host that cannot
#       see is not a task that never happened. Teardown deletes state/<id>.meta
#       immediately after writing that record, so this is the durable home of a
#       finished task's maker identity, delivery mode, pull request and derived
#       critic independence. bin/fm-certify.sh reads it to certify a task whose
#       task-local state is gone.
#   fm-wake-ledger.sh derive <status-file>
#       Print "<outcome> <outcome_source>" for a task's status log: the LAST
#       `done:` or `failed:` line decides, and a log with neither prints
#       "landed assumed". This is the one implementation of the mapping;
#       teardown calls it rather than restating it.
#   fm-wake-ledger.sh sweep [--dry-run]
#       Record the failures teardown will never see. For every task in state/
#       whose status log declares `failed:`, append one terminal record with
#       outcome=failed outcome_source=unreleased and leave a
#       state/<id>.terminal-recorded receipt so a rerun records nothing twice.
#       A task that fails and is never torn down is otherwise SILENT in this
#       ledger, and that silence is indistinguishable from a task that never
#       failed. A task holding state with no declaration at all is a different
#       thing and is not recorded here: it is already visible as an ordinary
#       unfinished task in the fleet state a session start reads, and guessing
#       a terminal outcome for it would put back the constant this replaced.
#       --dry-run prints the same lines and writes nothing. Teardown
#       removes the receipt with the rest of the task's state and writes its
#       own release record, which supersedes this one.
#   fm-wake-ledger.sh reconcile [--count]
#       Count the outcome records that join no wake record. --count prints that
#       number alone, for a caller that formats its own line. Session-start
#       bootstrap reports it so the corruption above cannot stay silent.
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
# fm-task-axis-lib.sh owns the identity axes and the deprecated kind= alias's
# derivation, so the sweep reads a pre-split record's role and deliverable
# through the same owner every other reader uses.
# shellcheck source=bin/fm-task-axis-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-task-axis-lib.sh"

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

# --- critic independence ----------------------------------------------------

# bin/fm-independence-lib.sh owns verifier identity capture and the derived
# independence verdict. Sourced rather than restated so this ledger records the
# same derivation the certification predicate refuses on: two copies of that
# rule would drift the moment only one was edited.
# shellcheck source=bin/fm-independence-lib.sh
. "$SCRIPT_DIR/fm-independence-lib.sh"

# Echo "<vendor>\t<model>\t<independence>" for the reviews the pipeline recorded
# against <repo>'s <branch>, where independence is the DERIVED per-dimension
# summary and never a value any caller supplied. Returns nonzero when nothing is
# resolvable at all, which the caller records as unknown.
#
# Reading the pipeline's tables is a deliberate soft coupling: an absent
# database, a schema that moves, or a host without python3 resolves to unknown
# and can never fail a teardown. The read is read-only and takes no lock.
ledger_resolve_critic() {  # <repo> <branch> <maker-harness> <maker-model>
  local repo=${1:-} branch=${2:-} mharness=${3:-} mmodel=${4:-}
  local steps critic vendor model dims summary
  # Loaded in this shell so the derivation below inherits the block: teardown
  # pays for one read of the pipeline, not one per consumer of it.
  fm_independence_steps_load "$repo" "$branch" || return 1
  steps=$FM_INDEPENDENCE_STEPS_VAL
  [ -n "$steps" ] || return 1
  # The reviewing identity is read from the MEMBER runs only, for the same
  # reason the derived verdict is: a run the pipeline cancelled or marked failed
  # never verified these bytes, so recording its reviewer as this task's checker
  # would name the wrong agent on the terminal line.
  critic=$(fm_independence_critic "$(fm_independence_members "$steps")") || return 1
  vendor=$(printf '%s' "$critic" | cut -f1)
  model=$(printf '%s' "$critic" | cut -f2)
  dims=$(fm_independence_dimensions "$repo" "$branch" "$mharness" "$mmodel")
  # One compact field per dimension, so the record answers "independent on
  # WHICH dimensions" rather than collapsing four different facts into one
  # word. bin/fm-certify.sh refuses certification on the same derivation, and
  # both the walk over the record and the words come from the library that owns
  # them rather than being restated here - only the unobserved word is this
  # record's own, matching the "unknown" every other unresolved field on the
  # same line already says.
  summary=$(fm_independence_each_dimension "$dims" unknown | awk -F'\t' '
    { out = out (out == "" ? "" : "+") $1 ":" $3 }
    END { print out }')
  printf '%s\t%s\t%s' "${vendor:-unknown}" "${model:-unknown}" "${summary:-unknown}"
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
# bounded tail read. With <full> non-empty the whole file is read instead: that
# is the refusal path only, where a wrong "no such wake" would be as damaging
# as the guess it exists to stop, so accuracy outranks the constant-time bound.
ledger_lookup_wake() {  # <seq> [<full>]
  local seq=$1 full=${2-} found
  [ -f "$LEDGER" ] || return 1
  found=$(
    if [ -n "$full" ]; then cat "$LEDGER"; else tail -n "$LEDGER_LOOKUP_TAIL" "$LEDGER"; fi 2>/dev/null \
    | LC_ALL=C awk -F '\t' \
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

# The sequence of the most recent wake record that no outcome record joins, from
# the same bounded tail read. This is what a bare `outcome` names, and it is why
# the coordinator no longer supplies a number: the file already knows which wake
# is outstanding, and it cannot misremember. An outcome record is always written
# after its wake record, so any wake inside the tail has its outcome inside the
# tail too - the bound can never invent an unrecorded wake, only decline to
# reach past one, which is a loud refusal rather than a wrong join.
ledger_newest_unrecorded_seq() {
  local found
  [ -f "$LEDGER" ] || return 1
  found=$(tail -n "$LEDGER_LOOKUP_TAIL" "$LEDGER" 2>/dev/null | LC_ALL=C awk -F '\t' \
    -v schema="$LEDGER_SCHEMA" '
    function fieldset(   i, p) {
      split("", f)
      for (i = 4; i <= NF; i++) {
        p = index($i, "=")
        if (p > 0) f[substr($i, 1, p - 1)] = substr($i, p + 1)
      }
    }
    $1 != schema { next }
    { fieldset() }
    $2 == "wake" {
      q = f["queued"]
      if (q == "") q = "unknown"
      n++
      wseq[n] = f["seq"]
      wq[n] = q
      next
    }
    # The join identity is the (seq, queued) pair, exactly as the report uses
    # it, so a sequence reused across a state wipe never masks the other wake.
    $2 == "outcome" { done[f["seq"], (f["queued"] == "" ? "unknown" : f["queued"])] = 1 ; next }
    END {
      for (i = n; i >= 1; i--) {
        if (!((wseq[i], wq[i]) in done)) { printf "%s", wseq[i]; exit }
      }
    }
  ') || return 1
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

# Outcome records joining no wake record, and the total outcome count, as
# "<unjoined><TAB><total>". A whole-file read: this is the reconciliation
# instrument, and a bounded one would under-report the very corruption it
# exists to expose. An absent ledger is a real zero; a ledger that exists and
# cannot be read returns nonzero rather than that same zero, because reporting
# "clean" for a file nobody could open is the silent all-clear this whole
# subcommand exists to abolish.
ledger_reconcile_counts() {
  [ -f "$LEDGER" ] || { printf '0\t0'; return 0; }
  LC_ALL=C awk -F '\t' -v schema="$LEDGER_SCHEMA" '
    function fieldset(   i, p) {
      split("", f)
      for (i = 4; i <= NF; i++) {
        p = index($i, "=")
        if (p > 0) f[substr($i, 1, p - 1)] = substr($i, p + 1)
      }
    }
    $1 != schema { next }
    { fieldset() }
    $2 == "wake" { wake[f["seq"], (f["queued"] == "" ? "unknown" : f["queued"])] = 1; next }
    $2 == "outcome" {
      total++
      if (!((f["seq"], (f["queued"] == "" ? "unknown" : f["queued"])) in wake)) unjoined++
      next
    }
    END { printf "%d\t%d", unjoined + 0, total + 0 }
  ' "$LEDGER" 2>/dev/null
}

cmd_outcome() {
  local token='' task='' defect='' note='' allow_unjoined='' resolved='' now seq
  local wake_row wake_rest wake_ts wake_task wake_queued after
  local -a seqs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || die "--task needs a value"; task=$2; shift 2 ;;
      --defect) [ "$#" -ge 2 ] || die "--defect needs a value"; defect=$2; shift 2 ;;
      --note) [ "$#" -ge 2 ] || die "--note needs a value"; note=$2; shift 2 ;;
      --allow-unjoined) allow_unjoined=1; shift ;;
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

  [ -n "$token" ] || die "outcome needs an outcome token"
  case "$token" in
    absorbed|inspected|steered|decided|escalated|repaired|false-positive) ;;
    *) die "unknown outcome token: $token (absorbed inspected steered decided escalated repaired false-positive)" ;;
  esac
  for seq in ${seqs[@]+"${seqs[@]}"}; do
    case "$seq" in
      ''|*[!0-9]*) die "wake sequence must be a number: $seq" ;;
    esac
  done
  # No sequence given is the normal path: name the cost, and let the ledger
  # name the wake. Resolving it here is the whole point - a number carried by
  # hand, from memory, after the fact is exactly what fabricated 200 records.
  if [ "${#seqs[@]}" -eq 0 ]; then
    [ -z "$allow_unjoined" ] \
      || die "--allow-unjoined applies to an explicit wake sequence, not a resolved one"
    resolved=$(ledger_newest_unrecorded_seq) \
      || die "no wake record without an outcome in the last $LEDGER_LOOKUP_TAIL ledger lines: nothing to record against"
    seqs=("$resolved")
  fi
  if [ -n "$task" ] && ! fm_task_id_path_safe "$task"; then
    die "unsafe task id: $task"
  fi
  case "$defect" in
    '') ;;
    *[!A-Za-z0-9._-]*) die "defect class must be [A-Za-z0-9._-]: $defect" ;;
  esac

  # Refuse before writing anything, so a rejected sequence in a multi-sequence
  # invocation cannot leave a half-recorded batch behind.
  if [ -z "$allow_unjoined" ]; then
    for seq in "${seqs[@]}"; do
      ledger_lookup_wake "$seq" >/dev/null && continue
      # The bounded read missed it; confirm against the whole file before
      # refusing, so the refusal states a fact rather than a lookup horizon.
      ledger_lookup_wake "$seq" full >/dev/null && continue
      die "wake sequence $seq joins no wake record: pass no sequence to record against the most recent unrecorded wake, or --allow-unjoined if the wake records are genuinely gone"
    done
  fi

  now=$(date +%s)
  for seq in "${seqs[@]}"; do
    wake_task=$task
    wake_queued=unknown
    after=unknown
    if wake_row=$(ledger_lookup_wake "$seq") || wake_row=$(ledger_lookup_wake "$seq" full); then
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
  local id='' outcome=landed osource=assumed route=unknown escalated=unknown findings=unknown
  local harness=unknown model=unknown effort=unknown mode=unknown
  local role=unknown deliverable=unknown
  local project=unknown backend=unknown pr='' now
  local critic_vendor='' critic_model='' critic_independence=''
  local critic_repo='' critic_branch='' resolved
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --critic-repo) [ "$#" -ge 2 ] || die "--critic-repo needs a value"; critic_repo=$2; shift 2 ;;
      --critic-branch) [ "$#" -ge 2 ] || die "--critic-branch needs a value"; critic_branch=$2; shift 2 ;;
      --outcome) [ "$#" -ge 2 ] || die "--outcome needs a value"; outcome=$2; shift 2 ;;
      --source) [ "$#" -ge 2 ] || die "--source needs a value"; osource=$2; shift 2 ;;
      --harness) [ "$#" -ge 2 ] || die "--harness needs a value"; harness=$2; shift 2 ;;
      --model) [ "$#" -ge 2 ] || die "--model needs a value"; model=$2; shift 2 ;;
      --effort) [ "$#" -ge 2 ] || die "--effort needs a value"; effort=$2; shift 2 ;;
      --mode) [ "$#" -ge 2 ] || die "--mode needs a value"; mode=$2; shift 2 ;;
      --role) [ "$#" -ge 2 ] || die "--role needs a value"; role=$2; shift 2 ;;
      --deliverable) [ "$#" -ge 2 ] || die "--deliverable needs a value"; deliverable=$2; shift 2 ;;
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
  # An unrecognized provenance is refused rather than downgraded to assumed: a
  # caller that meant to record evidence must not have it silently erased.
  case "$osource" in
    declared|discarded|unreleased|assumed) ;;
    *) die "unknown outcome source: $osource (declared discarded unreleased assumed)" ;;
  esac
  case "$escalated" in
    yes|no|unknown) ;;
    *) die "--escalated must be yes, no, or unknown: $escalated" ;;
  esac
  case "$findings" in
    unknown|'') findings=unknown ;;
    *[!0-9]*) die "--findings must be a count or unknown: $findings" ;;
  esac
  # THE REVIEWING IDENTITY IS ONLY EVER RESOLVED, NEVER STATED. There is
  # deliberately no --critic-process, --critic-vendor, --critic-model or
  # --critic-independence argument: an independence claim anyone can write is a
  # claim that will eventually be written wrongly, and this record exists to be
  # believed. --critic-repo and --critic-branch name WHICH BYTES to look at and
  # cannot assert what was found there.
  if resolved=$(ledger_resolve_critic "$critic_repo" "$critic_branch" "$harness" "$model"); then
    critic_vendor=${resolved%%"$TAB"*}
    resolved=${resolved#*"$TAB"}
    critic_model=${resolved%%"$TAB"*}
    critic_independence=${resolved#*"$TAB"}
  fi
  [ -n "$critic_vendor" ] || critic_vendor=unknown
  [ -n "$critic_model" ] || critic_model=unknown
  [ -n "$critic_independence" ] || critic_independence=unknown

  # A project path never enters the ledger; only its basename identifies it.
  project=$(basename "$project")

  now=$(date +%s)
  set -- \
    "task=$(ledger_sanitize "$id" "$LEDGER_ID_MAX")" \
    "harness=$(ledger_sanitize "${harness:-unknown}" "$LEDGER_SHORT_MAX")" \
    "model=$(ledger_sanitize "${model:-unknown}" "$LEDGER_KEY_MAX")" \
    "effort=$(ledger_sanitize "${effort:-unknown}" "$LEDGER_SHORT_MAX")" \
    "mode=$(ledger_sanitize "${mode:-unknown}" "$LEDGER_SHORT_MAX")" \
    "role=$(ledger_sanitize "${role:-unknown}" "$LEDGER_SHORT_MAX")" \
    "deliverable=$(ledger_sanitize "${deliverable:-unknown}" "$LEDGER_SHORT_MAX")" \
    "project=$(ledger_sanitize "${project:-unknown}" "$LEDGER_SHORT_MAX")" \
    "backend=$(ledger_sanitize "${backend:-unknown}" "$LEDGER_SHORT_MAX")" \
    "outcome=$outcome" \
    "outcome_source=$osource" \
    "route=$(ledger_sanitize "${route:-unknown}" "$LEDGER_SHORT_MAX")" \
    "escalated=$escalated" \
    "findings=$findings" \
    "critic_vendor=$(ledger_sanitize "$critic_vendor" "$LEDGER_SHORT_MAX")" \
    "critic_model=$(ledger_sanitize "$critic_model" "$LEDGER_KEY_MAX")" \
    "critic_independence=$(ledger_sanitize "$critic_independence" "$LEDGER_KEY_MAX")"
  [ -z "$pr" ] || set -- "$@" "pr=$(ledger_sanitize "$pr" "$LEDGER_KEY_MAX")"
  ledger_append "$now" task "$@" || {
    printf 'error: could not append terminal record for task %s to %s\n' "$id" "$LEDGER" >&2
    return 1
  }
  return 0
}

# Echo the key=value tail of the LAST terminal record for <id>, one field per
# line.
#
# WHY A READER EXISTS AT ALL. The terminal record is written immediately before
# teardown deletes state/<id>.meta, which makes it the only durable home for a
# finished task's harness, model, delivery mode, pull request and DERIVED critic
# independence. Every consumer that wants those facts after teardown would
# otherwise re-implement the line format, and this file is that format's single
# owner - a second parser is how an append-only evidence file starts being read
# two different ways.
#
# TWO FAILURES, TWO STATUSES, because only one of them is an OBSERVATION:
#
#   1  this ledger was read and holds no terminal record for that id - a fact
#      about the task, and the honest answer for one that never finished.
#   3  the ledger itself could not be read - a fact about this host, and no
#      evidence about the task at all. Returning 1 here would report a machine
#      that cannot see as a task that never happened, which is the collapse
#      every consumer of this file is built to refuse.
#
# The LAST record wins, matching every other reader here: `sweep` may record a
# declared failure at declaration time and a later teardown records the same
# task's release.
cmd_task_record() {
  local id=${1:-}
  [ -n "$id" ] || die "task-record needs a task id"
  fm_task_id_path_safe "$id" || die "unsafe task id: $id"
  [ -f "$LEDGER" ] && [ -r "$LEDGER" ] || return 3
  LC_ALL=C awk -F"$TAB" -v want="task=$id" '
    $2 == "task" {
      match_found = 0
      for (i = 4; i <= NF; i++) if ($i == want) match_found = 1
      if (!match_found) next
      last = ""
      for (i = 4; i <= NF; i++) last = last $i "\n"
    }
    END { if (last == "") exit 1; printf "%s", last }
  ' "$LEDGER"
}

# --- terminal outcome derivation --------------------------------------------

# The one mapping from a task's own status log to its terminal outcome. The
# LAST done: or failed: line decides, so a task that failed, was recovered, and
# then reported done records landed rather than its worst moment. blocked: and
# needs-decision: are open states, not outcomes, and never decide one. A log
# with no terminal declaration yields the historical constant, explicitly
# marked assumed so it can never be counted as evidence.
# fm-classify-lib.sh owns status_line_verb, the one parser for a status line's
# leading verb; the derivation below must read the same verbs the watcher and
# the daemon read rather than carry a second parser. Loaded on first use, not
# at source time: `drain-record` runs on the wake path and never derives an
# outcome, and that path must stay as cheap as it was.
_ledger_need_status_parser() {
  command -v status_line_verb >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh" 2>/dev/null || return 1
  command -v status_line_verb >/dev/null 2>&1
}

ledger_derive_outcome() {  # <status-file> -> "<outcome> <source>"
  local file=${1-} line verb outcome=''
  _ledger_need_status_parser || return 1
  if [ -n "$file" ] && [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      verb=$(status_line_verb "$line")
      case "$verb" in
        done) outcome=landed ;;
        failed) outcome=failed ;;
      esac
    done < "$file"
  fi
  [ -n "$outcome" ] || { printf 'landed assumed'; return 0; }
  printf '%s declared' "$outcome"
}

# One key's value from a task metadata file, last assignment winning. Absent
# key and absent file both yield the empty string; every caller substitutes
# unknown rather than guessing.
ledger_meta_value() {  # <meta-file> <key>
  [ -f "$1" ] || return 0
  LC_ALL=C awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$1"
}

cmd_derive() {
  local file='' derived
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -*) die "unknown flag for derive: $1" ;;
      *) [ -z "$file" ] || die "derive takes one status file"; file=$1; shift ;;
    esac
  done
  [ -n "$file" ] || die "derive needs a status file"
  # A refusal is louder than a wrong outcome: teardown falls back to the
  # unevidenced default when this exits nonzero, which is the old behavior.
  derived=$(ledger_derive_outcome "$file") || die "the status-line parser is unavailable"
  printf '%s\n' "$derived"
}

cmd_sweep() {
  local dry='' meta id derived outcome receipt recorded=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag for sweep: $1" ;;
    esac
  done

  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_task_id_path_safe "$id" || continue
    receipt="$STATE/$id.terminal-recorded"
    # The receipt is the whole idempotence story: this sweep runs at every
    # locked session start, and without it a task holding a declared failure
    # would append a fresh terminal record on every one of them.
    if [ -e "$receipt" ] || [ -L "$receipt" ]; then continue; fi
    derived=$(ledger_derive_outcome "$STATE/$id.status") \
      || die "the status-line parser is unavailable"
    outcome=${derived%% *}
    # Only a declared failure is recorded here. A declared done: or an
    # undeclared task is teardown's to record: teardown is still coming for it,
    # and its record carries facts this sweep cannot see.
    [ "$outcome" = failed ] || continue
    printf 'unreleased failure: %s\n' "$id"
    [ -z "$dry" ] || continue
    cmd_task "$id" \
      --outcome failed \
      --source unreleased \
      --harness "$(ledger_meta_value "$meta" harness)" \
      --model "$(ledger_meta_value "$meta" model)" \
      --effort "$(ledger_meta_value "$meta" effort)" \
      --mode "$(ledger_meta_value "$meta" mode)" \
      --role "$(fm_task_role "$meta")" \
      --deliverable "$(fm_task_deliverable "$meta")" \
      --project "$(ledger_meta_value "$meta" project)" \
      --backend "$(ledger_meta_value "$meta" backend)" \
      --route "$(ledger_meta_value "$meta" route)" || continue
    # Written only after the record is durable. A receipt ahead of the append
    # would suppress the retry that a failed append needs.
    printf 'failed\n' > "$receipt" 2>/dev/null || true
    recorded=$((recorded + 1))
  done
  [ -n "$dry" ] || [ "$recorded" -eq 0 ] \
    || printf 'recorded %s unreleased failure(s) as terminal records\n' "$recorded"
  return 0
}

cmd_reconcile() {
  local count_only='' counts unjoined total
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --count) count_only=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag for reconcile: $1" ;;
    esac
  done

  counts=$(ledger_reconcile_counts) || die "could not read $LEDGER"
  unjoined=${counts%%"$TAB"*}
  total=${counts#*"$TAB"}
  # A partial read must not become a fabricated number: this subcommand exists
  # to expose fabricated numbers.
  [ "$counts" = "$unjoined$TAB$total" ] || die "could not read $LEDGER"
  case "$unjoined" in ''|*[!0-9]*) die "could not read $LEDGER" ;; esac
  case "$total" in ''|*[!0-9]*) die "could not read $LEDGER" ;; esac
  if [ -n "$count_only" ]; then
    printf '%s\n' "$unjoined"
    return 0
  fi
  if [ "$unjoined" -eq 0 ]; then
    printf 'wake ledger: all %s outcome record(s) join a wake record\n' "$total"
    return 0
  fi
  printf 'wake ledger: %s of %s outcome record(s) join no wake record\n' "$unjoined" "$total"
  printf 'these record a cost against a wake that was never drained here; they are evidence of a bad join, not of supervision work\n'
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
    -v latfile="$tmp/lat" \
    -v dimensions="$FM_INDEPENDENCE_DIMENSIONS" '
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
      # A record written before outcome_source existed carries no evidence, and
      # that is exactly what assumed means, so the absent field maps onto it
      # rather than needing the file rewritten.
      terminal_source[t] = (f["outcome_source"] == "" ? "assumed" : f["outcome_source"])
      maker[t] = f["harness"] == "" ? "unknown" : f["harness"]
      # A record written before the critic fields existed carries none of them,
      # and reads exactly like one that could not resolve them: unknown.
      cvendor[t] = f["critic_vendor"] == "" ? "unknown" : f["critic_vendor"]
      cmodel[t] = f["critic_model"] == "" ? "unknown" : f["critic_model"]
      cind[t] = f["critic_independence"] == "" ? "unknown" : f["critic_independence"]
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
      for (t in terminal) {
        tasks++
        term_count[terminal[t]]++
        src_count[terminal_source[t]]++
      }
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
        printf "  by evidence:"
        split("declared discarded unreleased assumed", sv, " ")
        for (i = 1; i <= 4; i++) if (sv[i] in src_count) printf "  %s %d", sv[i], src_count[sv[i]]
        printf "\n"
        # Counts only, never a rate. Two records still disagree about the same
        # changes, so any ratio printed here would describe neither of them.
        printf "  counts are DIAGNOSTIC ONLY - not a success rate:"
        printf " assumed outcomes carry no evidence,"
        printf " and this ledger counts released tasks while the no-mistakes"
        printf " pipeline counts validation runs.\n"
        printf "  that fleet/pipeline divergence is a known, named, unreconciled gap.\n"
      }

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

      if (tasks > 0) {
        printf "\ncritic independence (DERIVED; unknown means could not observe, never independent):\n"
        for (t in terminal) {
          n_vendor[cvendor[t]]++
          n_model[cmodel[t]]++
          # Count each dimension separately. Collapsing them would destroy the
          # distinction between "independent model, same billing account" and
          # "independent vendor entirely", which is the whole point of storing
          # four dimensions rather than one word.
          if (cind[t] == "unknown") {
            # A record from before this field existed, or one whose reviewing
            # identity never resolved. Every dimension is unknown, and none of
            # them may be counted as independent.
            # The dimension list comes from its owner, so a dimension added
            # there is counted here rather than silently dropped.
            d = split(dimensions, every, " ")
            for (i = 1; i <= d; i++) n_dim[every[i] ":unknown"]++
          } else {
            n = split(cind[t], dims, "+")
            for (i = 1; i <= n; i++) n_dim[dims[i]]++
          }
          pairing[maker[t] " maker -> " cvendor[t] " critic"]++
        }
        printf "  vendor: "
        for (k in n_vendor) printf "  %s %d", k, n_vendor[k]
        printf "\n  model:  "
        for (k in n_model) printf "  %s %d", k, n_model[k]
        printf "\n"
        for (k in n_dim) printf "  %-52s %d\n", k, n_dim[k]
        for (k in pairing) printf "  %-52s %d\n", k, pairing[k]
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
  task-record) cmd_task_record "$@" ;;
  derive) cmd_derive "$@" ;;
  sweep) cmd_sweep "$@" ;;
  reconcile) cmd_reconcile "$@" ;;
  report) cmd_report "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown subcommand: $SUBCOMMAND (drain-record outcome task task-record derive sweep reconcile report)" ;;
esac
