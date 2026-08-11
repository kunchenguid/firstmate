#!/usr/bin/env bash
# fm-commitment-register.sh - the typed register of RECORDED-BUT-NOT-YET-REAL
# commitments, and the only interpreter of commitments/ and of the pinned probe
# block in a decision file.
#
# WHY THIS EXISTS. A commitment recorded with no enforcement probe reads as
# protection while protecting nothing. This fleet hit that failure four separate
# ways in one day: a captain ruling recorded and never enforced; a guard believed
# to close an inversion that has no runtime caller at all; a derived-state row
# that went stale inside a hand-maintained literal while being trusted; and a
# dated exception that self-expired into prose and was saved by a human filing a
# reminder rather than by any structure. Each was found by a person looking. None
# would have surfaced on its own.
#
# So an entry here carries a PROBE, and the probe is the load-bearing field. The
# entry's state is computed from that probe on every read and is never stored:
#
#   SATISFIED   the probe passed. The entry retires - it stops being surfaced,
#               with no hand edit. A register that needs hand-maintenance is the
#               defect it was built to fix.
#   UNMET       the probe reached a verdict and the commitment is not real yet.
#   UNOBSERVED  the probe reached no verdict, the entry is inadmissible, or the
#               entry is attested rather than probed. Three values, as everywhere
#               else in this fleet: could-not-observe is a real result, and it is
#               never read as enforced.
#
# THREE ENTRY CLASSES, two producers.
#
#   ruling_not_enforced      a ruling is recorded and nothing enforces it
#   authorisation_not_owned  authorised work has no owner
#         Both are JSON entries under commitments/ or the home overlay, and both
#         declare a TYPED probe (see probe_kinds in commitments/schema.json).
#         Typed rather than a raw command because the tracked register ships to
#         every home and a shared file must never become a shell-execution seam.
#
#   ruled_finding_not_met    a review finding was ruled, a fix was reported
#         APPLIED, and nothing establishes that the criterion is MET. Applied is
#         an action; met is a predicate, and a pipeline only ever knows the action
#         happened. These are NOT hand-registered here: the captain ruling of
#         2026-08-10 (data/captain-rulings-2026-08-10/ruled-criterion-must-carry-a-probe.md)
#         pins the probe into the decision file firstmate already writes, at
#         $FM_HOME/data/<task-id>/decision-<key>.md, as exactly one fenced block:
#
#             ```probe
#             tier: executable | cited-control | attested
#             run: <command, run from the task worktree; exit 0 means met>
#             control: <name of the test or artifact watched to fail first>
#             reason: <required for tier attested only - why no probe is possible>
#             ```
#
#         The format is pinned so what firstmate writes and what this file reads
#         cannot drift, which is why this register discovers those probes rather
#         than asking anyone to copy them into a second place.
#
# THE TIERS are the ruling's three, shared by both producers, because forcing a
# probe where none is possible would recreate this same failure one level up:
#   executable     the probe runs directly and its result is the answer.
#   cited-control  the probe confirms a named test exists and passes NOW, while
#                  the watched-it-fail observation is cited as a named artifact
#                  rather than a claim. The DEFAULT: the strongest routinely
#                  achievable form. The ruling pins `control` as a NAME, so it is
#                  surfaced and marked when it also resolves on disk, never gated
#                  on - what no mechanism can confirm is that the cited artifact
#                  records a real red observation, which is why the tier is
#                  "cited" rather than "verified".
#   attested       the criterion genuinely cannot execute. It carries a reason,
#                  declares no probe, and NEVER reaches SATISFIED: it stays marked
#                  and visible rather than being read as verified.
#
# NO BACK-FILLING. A decision key ruled before 2026-08-10 carries no probe block,
# and none is invented for it: it simply has no registered probe, so the fold
# below behaves for it exactly as it always did, and this register reports its
# criterion as could-not-observe rather than manufacturing evidence. A fabricated
# record is indistinguishable from a real one afterwards.
#
# NOT A REPLACEMENT FOR DILIGENCE. Every instance this register was built from was
# caught by a worker re-checking its own work. The probe is a floor beneath that,
# never a substitute, and a green entry licenses nothing.
#
# TRUST BOUNDARY. A decision file's `run:` is executed. Those files are
# firstmate-written, home-private, gitignored material in the operational home
# this command was pointed at - the same trust class as the rest of $FM_HOME/data.
# The tracked register deliberately has no such field: it ships between homes, and
# a shared file that could execute would be a different thing entirely.
#
# Three-valued results are produced and consumed through bin/fm-verify-lib.sh, so
# no probe's silence, error, or empty answer can reach a pass terminal.
#
# WHY THIS IS NOT bin/fm-decision-surface.sh, said plainly. That script is this
# fleet's derived-state composer and its typed verdicts are the right shape, and
# fm-verify-lib.sh's three-valued observation type is used here rather than
# reinvented. The decision surface still does not fit as the host, for three
# reasons that are properties of the input rather than preferences:
#   1. Different input class. The decision surface composes ONE home's live
#      operational state - tasks, holds, wake ledger - through
#      bin/fm-fleet-snapshot.sh. This reads TRACKED repository material that ships
#      to every home and answers about the code itself, and it must answer
#      identically in a home that has no tasks, no snapshot, and no fleet at all.
#   2. Different call site and cost budget. The decision surface is invoked by a
#      human or a composer once; --closes runs inside bin/fm-classify-lib.sh's
#      open-decision fold, on the wake-drain path, per resolved status line.
#      Putting that on a composer that loads a fleet snapshot first would make the
#      fold pay for state it does not read.
#   3. Different failure obligation. A commitment that cannot be evaluated must
#      take a fail-closed EXIT STATUS a caller ignoring stdout still stops on. The
#      decision surface reports; it is not a gate.
# What the decision surface does own is the fact that this compensation now has an
# owner at all: its owners ledger carries the unenforced_commitments row pointing
# here, so the two surfaces are joined rather than parallel.
#
# WHAT IT DOES AND DOES NOT TOUCH. It takes no lock and touches no project. It
# does NOT execute anything from the tracked register, which is the whole reason
# that register's probes are typed. It DOES execute three things, all of them
# home-private or repo-local: a decision file's `run:` (see TRUST BOUNDARY above),
# an entry's declared owner command, and an entry's named test. The only thing it
# writes is the decision-probe result cache described under Environment below.
# Because a `run:` executes inside the task worktree, a probe that writes scratch
# files there leaves that worktree dirty, which bin/fm-teardown.sh's dirty check
# then refuses on - a `run:` that mutates its worktree is a badly written probe,
# and the cache bounds how often it runs but cannot make it harmless.
#
# TWO KINDS OF PROBE, AND THEY ARE NOT THE SAME QUESTION. Conflating them is what
# produced both the original hazard and the first, over-broad attempt at fixing
# it, so the distinction is written here rather than left to be re-derived:
#
#   The register's OWN TYPED probes are a CLOSED set defined in this file and
#   named by kind in commitments/schema.json. This repository owns every one of
#   them, can audit what each does, and bounds each at 10s. Running one is a COST
#   decision, and the cost is small and known.
#
#   A decision file's `run:` is ARBITRARY TEXT written by whoever authored a
#   ruling, executed by `bash -c` inside a task worktree. Running one is a TRUST
#   decision, and no bound makes it a small one.
#
# They must not share a switch, because a switch that answers the trust question
# would silence the cost one too.
#
# That first paragraph is only true because of probe_target_fault below: the
# KINDS are closed, but the TARGETS they run come out of the entry's own JSON,
# and an entry can arrive from the gitignored home overlay. Every path a typed
# probe names is therefore resolved only under the tracked code root - no
# absolute path, no upward traversal, no symlink out - and an entry naming a
# target outside it is inadmissible rather than executed. Without that, "this
# repository owns every one of them" would be a hope rather than a property, and
# the cost argument for running typed probes at session start would not hold.
#
# SESSION START RUNS TYPED PROBES AND NEVER A DECISION-FILE `run:`. The arbitrary-
# execution chain is real and it is specific: bin/fm-session-start.sh runs
# bin/fm-admission.sh, which runs bin/fm-fleet-snapshot.sh, which calls
# status_open_decisions per task, which reaches the closure gate below - which
# would otherwise `bash -c` a ruling author's text inside a task worktree on the
# critical path of every session. That is the FOLD. It is not the --open relay:
# --open never collects decision probes at all, deliberately, because the fold is
# their surface. So bin/fm-session-start.sh sets
# FM_COMMITMENT_NO_DECISION_RUN=1 on exactly the two calls that reach the fold -
# its wake drain and its admission read - and on nothing else. The variable is
# never exported over session start's whole subtree, because that subtree
# relaunches secondmates through bin/fm-spawn.sh, which scrubs no environment: a
# safety flag that escaped into a long-lived agent would silently wedge closure
# there for that agent's whole life.
#
# The typed probes keep running at session start, which is what lets an entry
# whose commitment became real retire there with no hand edit. Suppressing them
# would leave every registered entry printing forever, and a session start that
# cries wolf is one that gets turned off - the same end the safety rule exists to
# prevent.
#
# NOT RUNNING IS NOT ACCEPTING. When a decision `run:` is not executed, no stored
# verdict stands in for it either - serving a cached PASS would close a key on an
# observation this session did not make - so the answer is could-not-observe, the
# resolution stays visibly unverified, and the fold keeps showing the decision.
# Fail-open here would be worse than the cost it avoids. A wake drain, a
# decision-hold read, or a fleet snapshot run OUTSIDE session start sets no such
# variable and evaluates decision probes normally; session start's own wake drain
# and admission read are inside the guard and report those keys as still open.
#
# WHAT THIS SUPERSEDES, recorded rather than quietly rewritten, because the
# reasoning is the part worth inheriting. The rule was first accepted in the
# blanket form "SESSION START MUST EXECUTE NO PROBE - session start may report
# RECORDED state; it may never execute a probe to find out." Built that way it
# defeated the criterion it shares a page with: with no probe running, nothing at
# session start is ever SATISFIED, so every registered entry prints a
# could-not-observe line forever and never retires when its commitment becomes
# real - the cry-wolf outcome the safety rule exists to prevent, since a session
# start that always shouts is one that gets turned off. The rule is therefore
# narrowed to its hazard: the guard covers decision-file `run:` EXECUTION only.
# Typed probes remain permitted at session start precisely because their targets
# are constrained to the tracked code root, which is what makes them a cost
# question rather than a trust one; if that constraint is ever relaxed, this
# permission has to be reconsidered with it. commitments/schema.json carries the
# same supersession under probe_bounds.
#
# bin/fm-bootstrap.sh relays --open at every session start, so session
# start cannot report a clean or quiet state while a registered commitment is open,
# and bin/fm-classify-lib.sh's open-decision fold calls --closes so a reported-
# applied fix cannot close a criterion nothing established.
#
# Usage:
#   fm-commitment-register.sh [--json]
#       Every entry - both JSON classes and every discovered decision probe -
#       with its computed state and the evidence behind it.
#   fm-commitment-register.sh <id> [--json]
#       One entry. A discovered decision probe's id is decision:<task>:<key>.
#   fm-commitment-register.sh --open
#       One complete "COMMITMENT: ..." line per REGISTERED entry that is not
#       SATISFIED, in the form bin/fm-bootstrap.sh relays verbatim. Silent when
#       every registered entry is satisfied. Never suppressed by age, count, or
#       rate: a quieter question hides a genuine unmet commitment along with the
#       noise. Discovered decision probes are deliberately NOT relayed here - the
#       open-decision fold is their surface, and this adds no second one.
#   fm-commitment-register.sh --closes <task-id> <decision-key>
#       May a `resolved` event for this keyed decision be accepted? Exits 0 when
#       no probe is registered for the key, when its probe passes, or when it is
#       an attested criterion (whose acceptance is printed, never silent), and
#       non-zero otherwise with one line of evidence.
#   Any report may be combined with --no-decision-run, which is
#       FM_COMMITMENT_NO_DECISION_RUN=1 as a flag: execute no decision file's
#       `run:` and report every such criterion as could-not-observe rather than
#       finding out. The register's own typed probes are unaffected. See TWO KINDS
#       OF PROBE above.
#   fm-commitment-register.sh --help
#
# Exit status is the verdict, so a caller that ignores stdout still stops safely:
#   0  every entry is SATISFIED (or, for --closes, the resolution is accepted)
#   2  usage error
#   3  at least one entry is UNMET, and none is UNOBSERVED
#   4  at least one entry is UNOBSERVED - including a register that could not be
#      read at all, which is never a quiet pass
#
# Entries are read from three places, and a JSON id must be unique across the two
# JSON sources:
#   commitments/<id>.json                tracked; commitments about this repo's own
#                                        shared code, shipped to every home. Its
#                                        absence is UNOBSERVED, not silence: the
#                                        directory ships with bin/, so a missing
#                                        one means the register is not working.
#   $FM_HOME/data/commitments/<id>.json  optional home overlay for captain-private
#                                        commitments that must not reach a shared
#                                        template repo. Its absence is silent.
#   $FM_HOME/data/<task>/decision-<key>.md  discovered ruled-finding probes.
#
# Environment:
#   FM_HOME                       operational home to read (default: repo root)
#   FM_COMMITMENT_DIR             read this tracked register instead (tests)
#   FM_COMMITMENT_HOME_DIR        read this home overlay instead (tests)
#   FM_COMMITMENT_NO_DECISION_RUN 1 to execute no decision file's `run:` and
#                                 report every such criterion as could-not-observe
#                                 (default 0). The register's own typed probes are
#                                 unaffected. Set by bin/fm-session-start.sh on the
#                                 two calls that reach the open-decision fold, and
#                                 on nothing else; see TWO KINDS OF PROBE above.
#   FM_COMMITMENT_PROBE_TIMEOUT   seconds bounding one register-entry probe
#                                 (default 10)
#   FM_COMMITMENT_DECISION_PROBE_TIMEOUT
#                                 seconds bounding one decision-file `run:`
#                                 (default 60)
#   FM_COMMITMENT_PROBE_CACHE_TTL seconds a decision-probe result stays servable
#                                 (default 120; 0 disables the cache entirely)
#   FM_COMMITMENT_PROBE_CACHE_DIR where those results live (default
#                                 $FM_HOME/state/commitment-probe-cache)
#
# THE TWO PROBE BOUNDS, both stated wherever either is, because prose claiming
# what the code does not do is the failure this whole file is about. The register's
# OWN typed probes are bounded at 10s: they read this repository, and none of them
# is a test invocation. A decision file's `run:` is bounded at 60s, and that number
# is derived rather than picked. The 2026-08-10 ruling makes cited-control the
# DEFAULT tier and its `run` is a test invocation, so the bound has to let the
# pinned default finish or it refuses every such closure forever, which is a park
# rather than a verdict. Measured on the machine this was written on:
# tests/fm-commitment-register.test.sh runs in 7.8s (three runs: 7.82, 7.82, 7.81),
# and a pinned cited-control probe invokes that suite TWICE - once per grep in the
# `run` - so one probe costs about 15.6s. 60s is therefore roughly 4x observed with
# headroom for machine load, and that ratio is what the next person changing this
# number is trading. commitments/schema.json carries the same two numbers and the
# same derivation under probe_bounds, and a test pins them equal.
#
# A PROBE THAT TIMES OUT IS REPORTED AS A TIMEOUT, distinct from every other
# could-not-observe cause. Could-not-observe is safe because it can never wrongly
# pass, but it also cannot close a key, so a chronically timing-out probe would
# otherwise block a closure forever while reading as an ordinary open item. Its
# evidence therefore leads with TIMEOUT and names the bound, so someone fixes the
# probe rather than wondering why a key will not close.
#
# THE DECISION-PROBE CACHE, and the one rule it may not break. --closes runs on
# the open-decision fold's hot path, which recomputes from the whole status stream
# on every wake drain, every fleet snapshot, and every decision-hold read - so an
# uncached probe re-runs a test for the remaining life of a status file, once per
# fold, per task. The cache bounds that. It may not buy the cost back with the
# correctness this register exists to establish, so:
#   - a served result CARRIES ITS OBSERVATION TIME in its own evidence, so an old
#     answer can never read as a fresh one, and bin/fm-classify-lib.sh surfaces
#     that evidence on the ACCEPT path too rather than discarding it;
#   - it is keyed on what the probe's answer actually DEPENDS on: the decision
#     file's bytes, the task worktree, and that worktree's head. Deliberately NOT
#     on the task status file, because the open-decision fold is DRIVEN by status
#     appends - keying on those would invalidate the entry precisely on the append
#     where the cache was meant to help, while a worktree whose head moved past the
#     recorded verdict would still be answered from before;
#   - past the freshness bound it is not served at all: the probe re-runs, and if
#     it cannot re-run the answer is could-not-observe, never the stale verdict.
# The cache is an accelerator for an answer, never a substitute for one.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG_DIR="${FM_COMMITMENT_DIR:-$FM_ROOT/commitments}"
HOME_REG_DIR="${FM_COMMITMENT_HOME_DIR:-$DATA/commitments}"

# shellcheck source=bin/fm-verify-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-verify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

EXIT_OK=0
EXIT_USAGE=2
EXIT_UNMET=3
EXIT_UNOBSERVED=4

SCHEMA=fm-commitment-register.v1
SCHEMA_VERSION=1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SCRIPT_DIR/fm-commitment-register.sh"
}

die() { printf 'fm-commitment-register: %s\n' "$1" >&2; exit "$EXIT_USAGE"; }

MODE=human
TARGET=
CLOSES_TASK=
CLOSES_KEY=

# No decision file's `run:` executes in this mode, and the register's own typed
# probes are untouched by it - see TWO KINDS OF PROBE above. Anything other than a
# literal 1 leaves execution on, so a stray or empty value cannot silently disarm
# the only thing that answers a ruled criterion.
NO_DECISION_RUN=0
[ "${FM_COMMITMENT_NO_DECISION_RUN:-0}" != 1 ] || NO_DECISION_RUN=1

while [ $# -gt 0 ]; do
  case "$1" in
    --json) [ "$MODE" = human ] || die "--json, --open and --closes are different reports"; MODE=json ;;
    --open) [ "$MODE" = human ] || die "--json, --open and --closes are different reports"; MODE=open ;;
    --no-decision-run) NO_DECISION_RUN=1 ;;
    --closes)
      [ "$MODE" = human ] || die "--json, --open and --closes are different reports"
      MODE=closes
      shift
      [ $# -ge 2 ] || die "--closes needs a task id and a decision key"
      CLOSES_TASK=$1
      CLOSES_KEY=$2
      shift
      ;;
    -h|--help) usage; exit "$EXIT_OK" ;;
    -*) die "unknown option $1" ;;
    *)
      [ -z "$TARGET" ] || die "one commitment id at a time"
      TARGET=$1
      ;;
  esac
  shift
done

# jq reads JSON ENTRIES, and only the reports that read them need it. --closes
# reads a decision file's pinned probe block, which is line-oriented text parsed
# in shell, so gating it on jq would stall the whole fleet's decision lifecycle on
# a dependency the operation never uses: no `resolved` event could close anywhere,
# for want of a tool that would not have been called.
case "$MODE" in
  closes) ;;
  *)
    command -v jq >/dev/null 2>&1 || {
      # No jq means no JSON entry can be read at all. That is the register
      # failing, not an empty register, so it takes the fail-closed exit rather
      # than a quiet 0.
      case "$MODE" in
        open) printf 'COMMITMENT: register unreadable - jq is required to read commitment entries\n' ;;
        *) printf 'fm-commitment-register: jq is required to read commitment entries\n' >&2 ;;
      esac
      exit "$EXIT_UNOBSERVED"
    }
    ;;
esac

# A probe must be bounded on every supported host, so a wedged command cannot
# stall session start. With no bounding tool the probe does not run: reporting it
# unobservable is honest, and it is also the answer that never reads as enforced.
PROBE_TIMEOUT=${FM_COMMITMENT_PROBE_TIMEOUT:-10}
# A decision file's `run:` gets its own, larger bound. Both numbers and the
# derivation behind the second one are stated under THE TWO PROBE BOUNDS above and
# in commitments/schema.json's probe_bounds, which a test pins equal to these.
DECISION_PROBE_TIMEOUT_DEFAULT=60
DECISION_PROBE_TIMEOUT=${FM_COMMITMENT_DECISION_PROBE_TIMEOUT:-$DECISION_PROBE_TIMEOUT_DEFAULT}
PROBE_CACHE_TTL=${FM_COMMITMENT_PROBE_CACHE_TTL:-120}
PROBE_CACHE_DIR=${FM_COMMITMENT_PROBE_CACHE_DIR:-$STATE/commitment-probe-cache}
bounding_tool() {
  if command -v timeout >/dev/null 2>&1; then printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'
  else return 1
  fi
}
run_timed() {  # <seconds> <command...>
  local seconds=$1 tool
  shift
  tool=$(bounding_tool) || return 125
  "$tool" -k 2 "$seconds" "$@"
}

# An evidence string becomes the last field of a fm-verify.sh record, which is
# newline-delimited. Commas survive because evidence is last; a newline would
# split the record, so it is folded rather than carried.
sanitize() { printf '%s' "$1" | tr '\n\t' '  '; }

# --- probes ------------------------------------------------------------------
#
# Each probe sets PROBE_RESULT (PASS|FAIL|NO_VERIFIER_RAN), PROBE_REASON from
# bin/fm-verify.sh's closed reason vocabulary, and PROBE_EVIDENCE. Nothing else
# reads a probe's exit status: the result IS the answer.

PROBE_RESULT=
PROBE_REASON=
PROBE_EVIDENCE=

probe_answer() {  # <result> <reason> <evidence>
  PROBE_RESULT=$1
  PROBE_REASON=$2
  PROBE_EVIDENCE=$(sanitize "$3")
}

# A killed probe. Its own reason, and evidence that leads with the word, because
# could-not-observe cannot close a key: a probe that always times out would
# otherwise block a closure forever while reading as an ordinary open item.
probe_timed_out() {  # <what> <seconds>
  probe_answer NO_VERIFIER_RAN no_verdict_reached \
    "TIMEOUT: $1 was stopped at its ${2}s bound rather than answering, so this is could-not-observe and cannot pass - raise the bound or make the probe finish inside it, because nothing closes until it does"
}

# The answer for a decision file's `run:` this caller may not execute.
# Could-not-observe, never a pass and never an acceptance: not running must not
# mean accepting.
probe_not_executed() {  # <what>
  probe_answer NO_VERIFIER_RAN verifier_unavailable \
    "NOT RUN: this caller executes no decision-file run command, so $1 was not executed and the criterion stays unverified rather than accepted"
}

# Does every harness firstmate can launch compose a session whose permission
# enforcement is active? bin/fm-launch-lib.sh's launch_permission_posture is the
# single owner of that answer; this probe reads it and never inspects a flag.
probe_launch_permission_enforced() {  # <probe-json>
  local lib="$SCRIPT_DIR/fm-launch-lib.sh" postures unrestricted unknown
  if [ ! -r "$lib" ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "bin/fm-launch-lib.sh is not readable, so the launch posture could not be read"
    return 0
  fi
  postures=$(
    # shellcheck source=bin/fm-launch-lib.sh disable=SC1090,SC1091
    . "$lib" 2>/dev/null && launch_permission_posture 2>/dev/null
  ) || postures=
  if [ -z "$postures" ]; then
    probe_answer NO_VERIFIER_RAN empty_result_set \
      "bin/fm-launch-lib.sh reported no launch posture for any harness"
    return 0
  fi
  unrestricted=$(printf '%s\n' "$postures" | awk '$2 == "unrestricted" { printf "%s ", $1 }')
  unknown=$(printf '%s\n' "$postures" | awk '$2 == "unknown" { printf "%s ", $1 }')
  if [ -n "$unrestricted" ]; then
    probe_answer FAIL verifier_reported_failure \
      "these harnesses launch a worker with permission enforcement disabled: ${unrestricted% }"
    return 0
  fi
  if [ -n "$unknown" ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "no harness is unrestricted, but the permission posture of ${unknown% } is not recorded, so enforcement cannot be claimed"
    return 0
  fi
  probe_answer PASS verified "every launchable harness composes a session with permission enforcement active"
}

# --- typed-probe targets live under the tracked code root --------------------
#
# The probe KINDS are a closed set; the TARGETS they run are not. command, test
# and defined_in come out of the entry's own JSON, and entries arrive from the
# gitignored $FM_HOME/data/commitments/ overlay as well as from the tracked
# register - so without this, one unreviewed file could name any absolute
# executable and have it run on the critical path of every session in the fleet.
# That is a trust decision reached through the door labelled cost, which is
# exactly the conflation TWO KINDS OF PROBE says must not happen. Constraining
# targets to the tracked code root is what makes "this repository owns every one
# of them" true rather than nearly true, and it is the reason typed probes are
# allowed to run at session start at all.
#
# Prints one refusal reason, or nothing when the target is admissible. An ABSENT
# target is not refused: an owner or test that does not exist is an OBSERVED
# absence, and reporting it as unobservable would hide the very thing the entry
# was written to catch.
probe_target_fault() {  # <field> <value>
  local field=$1 rel=$2 root dir base parent
  case "$rel" in
    '') return 0 ;;
    *[![:print:]]*)
      printf '%s carries a non-printable character, so what it names cannot be read' "$field"
      return 0
      ;;
    /*)
      printf '%s "%s" is an absolute path, and a typed probe target is resolved only under the tracked code root, never taken verbatim' \
        "$field" "$rel"
      return 0
      ;;
    ..|../*|*/../*|*/..)
      printf '%s "%s" traverses upward, so it can leave the tracked code root' "$field" "$rel"
      return 0
      ;;
  esac
  root=$(CDPATH='' cd -- "$FM_ROOT" 2>/dev/null && pwd -P) || {
    printf 'the tracked code root cannot be resolved, so %s "%s" cannot be shown to live under it' "$field" "$rel"
    return 0
  }
  dir=$(dirname -- "$rel")
  base=$(basename -- "$rel")
  case "$base" in
    ''|.|..) printf '%s "%s" names no file' "$field" "$rel"; return 0 ;;
  esac
  # An absent parent escapes nothing, and the probe's own answer for a target
  # that is not there is the observed absence it exists to report.
  parent=$(CDPATH='' cd -- "$FM_ROOT/$dir" 2>/dev/null && pwd -P) || return 0
  case "$parent" in
    "$root"|"$root"/*) ;;
    *)
      printf '%s "%s" resolves to %s, outside the tracked code root %s' \
        "$field" "$rel" "$parent/$base" "$root"
      return 0
      ;;
  esac
  if [ -L "$parent/$base" ]; then
    printf '%s "%s" is a symlink, so what it resolves to is not what this register audited' \
      "$field" "$rel"
    return 0
  fi
}

# Reads .args into the caller's PROBE_ARGV array.
PROBE_ARGV=()
read_probe_argv() {  # <probe-json>
  local line
  PROBE_ARGV=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    PROBE_ARGV+=("$line")
  done < <(printf '%s' "$1" | jq -r '(.args // [])[]')
}

# The answer probe_command_answers last read, so a probe that must inspect that
# answer does not have to run the owner a second time to see it.
PROBE_COMMAND_OUT=

# Does the declared owner exist and answer? An owner that is not there is an
# observed absence, not an unobservable one - that distinction is the whole point
# of naming an owner in the entry.
probe_command_answers() {  # <probe-json>
  local probe=$1 rel cmd out rc fault
  PROBE_COMMAND_OUT=
  rel=$(printf '%s' "$probe" | jq -r '.command // ""')
  if [ -z "$rel" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "probe declares no command"
    return 0
  fi
  fault=$(probe_target_fault command "$rel")
  if [ -n "$fault" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "refusing to run this probe: $fault"
    return 0
  fi
  cmd="$FM_ROOT/$rel"
  if [ ! -x "$cmd" ]; then
    probe_answer FAIL verifier_reported_failure \
      "the declared owner $rel is not present and executable, so nothing performs this commitment"
    return 0
  fi
  if ! bounding_tool >/dev/null; then
    probe_answer NO_VERIFIER_RAN verifier_unavailable \
      "no timeout tool is available to bound the declared owner $rel, so it was not run"
    return 0
  fi
  read_probe_argv "$probe"
  out=$(run_timed "$PROBE_TIMEOUT" "$cmd" "${PROBE_ARGV[@]+"${PROBE_ARGV[@]}"}" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    probe_timed_out "the declared owner $rel" "$PROBE_TIMEOUT"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    probe_answer FAIL verifier_reported_failure "the declared owner $rel exited $rc"
    return 0
  fi
  if [ -z "$out" ]; then
    probe_answer NO_VERIFIER_RAN empty_result_set \
      "the declared owner $rel exited 0 printing nothing, which answers nothing"
    return 0
  fi
  PROBE_COMMAND_OUT=$out
  probe_answer PASS verified "the declared owner $rel answered"
}

# Does the declared owner's ANSWER say what the commitment requires? command_answers
# establishes only that something answered, which is the right question for "does
# an owner exist" and the wrong one for "does the derived row say what it should":
# a composer that prints a stale row exits 0 and prints plenty. This kind reads the
# answer with a jq filter, so a commitment about the CONTENT of derived state is
# probed against that content rather than against the composer's exit status.
# The filter is jq rather than a command because the tracked register must never
# become a shell-execution seam; see TRUST BOUNDARY in the header.
probe_command_answer_matches() {  # <probe-json>
  local probe=$1 filter verdict
  filter=$(printf '%s' "$probe" | jq -r '.jq // ""')
  if [ -z "$filter" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "probe declares no jq filter over the answer"
    return 0
  fi
  probe_command_answers "$probe"
  # Only an answer that arrived can be read; an absent or silent owner keeps the
  # verdict command_answers already reached for it.
  [ "$PROBE_RESULT" = PASS ] || return 0
  local rel
  rel=$(printf '%s' "$probe" | jq -r '.command // ""')
  verdict=$(printf '%s' "$PROBE_COMMAND_OUT" | jq -r "$filter" 2>/dev/null) || verdict=
  case "$verdict" in
    true) probe_answer PASS verified "the answer from $rel satisfies the declared condition" ;;
    false)
      probe_answer FAIL verifier_reported_failure \
        "the answer from $rel does not satisfy the declared condition, so what it reports is not what was committed"
      ;;
    *)
      probe_answer NO_VERIFIER_RAN verification_unreachable \
        "the condition over $rel's answer produced \"${verdict:-nothing}\" rather than true or false, so the answer was not read"
      ;;
  esac
}

# Does the named test exist and pass NOW? The probe half of the cited-control
# tier: it establishes that the criterion holds today, while the entry's cited
# control carries the watched-it-fail observation proving the test can go red. A
# test that is absent is FAIL, not could-not-observe: a criterion whose test does
# not exist was never established, and calling that unobservable would hide it.
probe_test_passes() {  # <probe-json>
  local probe=$1 rel test out rc fault
  rel=$(printf '%s' "$probe" | jq -r '.test // ""')
  if [ -z "$rel" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "probe declares no test"
    return 0
  fi
  fault=$(probe_target_fault test "$rel")
  if [ -n "$fault" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "refusing to run this probe: $fault"
    return 0
  fi
  test="$FM_ROOT/$rel"
  if [ ! -f "$test" ]; then
    probe_answer FAIL verifier_reported_failure \
      "the named test $rel does not exist, so the criterion it was to establish never was established"
    return 0
  fi
  if ! bounding_tool >/dev/null; then
    probe_answer NO_VERIFIER_RAN verifier_unavailable \
      "no timeout tool is available to bound $rel, so it was not run"
    return 0
  fi
  read_probe_argv "$probe"
  if [ -x "$test" ]; then
    out=$(run_timed "$PROBE_TIMEOUT" "$test" "${PROBE_ARGV[@]+"${PROBE_ARGV[@]}"}" 2>&1)
  else
    out=$(run_timed "$PROBE_TIMEOUT" bash "$test" "${PROBE_ARGV[@]+"${PROBE_ARGV[@]}"}" 2>&1)
  fi
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    probe_timed_out "the named test $rel" "$PROBE_TIMEOUT"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    probe_answer FAIL verifier_reported_failure \
      "the named test $rel exited $rc: $(printf '%s' "$out" | tail -1)"
    return 0
  fi
  probe_answer PASS verified "the named test $rel passes now"
}

# Does this guard have a runtime caller? A function reachable only from its own
# tests enforces nothing in production, however correct the function is.
#
# A TEXTUAL MENTION IS NOT A CALLER. This entry class is precisely "a guard
# believed to close an inversion that has no runtime caller at all", so a plain
# word match would let `# task_base_verify_branch should be wired in here` retire
# the entry while the guard still guards nothing - the register reproducing its
# own defect. Comment lines are therefore dropped before the match, and what is
# left must look like a CALL: the symbol at a command position, not merely
# somewhere on the line.
probe_symbol_called() {  # <probe-json>
  local probe=$1 symbol defined_in callers call_re fault
  symbol=$(printf '%s' "$probe" | jq -r '.symbol // ""')
  defined_in=$(printf '%s' "$probe" | jq -r '.defined_in // ""')
  if [ -z "$symbol" ] || [ -z "$defined_in" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "probe declares no symbol or no defining file"
    return 0
  fi
  fault=$(probe_target_fault defined_in "$defined_in")
  if [ -n "$fault" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "refusing to read this probe's target: $fault"
    return 0
  fi
  # The symbol goes into a regular expression below, so a name carrying regex
  # syntax is refused rather than silently matching more than it names. "." is
  # refused with the rest: bash permits it in a function name, and interpolated it
  # matches any character, so a declared fm.verify would report SATISFIED on a
  # caller of fm_verify - the over-match this check exists to prevent.
  case "$symbol" in
    *[!A-Za-z0-9_-]*)
      probe_answer NO_VERIFIER_RAN usage_error \
        "\"$symbol\" is not a plain shell function name, so a call to it cannot be told from a pattern matching one"
      return 0
      ;;
  esac
  if [ ! -r "$FM_ROOT/$defined_in" ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "$defined_in is not readable, so a definition of $symbol could not be told from a call to it"
    return 0
  fi
  if [ ! -d "$FM_ROOT/bin" ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "$FM_ROOT/bin is not readable, so callers of $symbol could not be enumerated"
    return 0
  fi
  # Command position: start of line, or after a separator that begins a new
  # command. A definition (`name()`) does not match, because the character after
  # the name has to be whitespace or a terminator rather than "(".
  call_re="(^|[;&|(){}]|&&|\\|\\||\\\$\\()[[:space:]]*(if[[:space:]]+|while[[:space:]]+|until[[:space:]]+|then[[:space:]]+|else[[:space:]]+|elif[[:space:]]+|do[[:space:]]+|![[:space:]]+)*${symbol}([[:space:]]|[;&|)]|\$)"
  callers=$(
    grep -rlw -- "$symbol" "$FM_ROOT/bin" 2>/dev/null |
      grep -vF -- "$FM_ROOT/$defined_in" |
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        grep -v '^[[:space:]]*#' -- "$f" 2>/dev/null |
          grep -qE -- "$call_re" && printf '%s\n' "$f"
      done |
      sed "s#^$FM_ROOT/##" | sort | tr '\n' ' '
  )
  if [ -z "$callers" ]; then
    probe_answer FAIL verifier_reported_failure \
      "$symbol is defined in $defined_in and called from nowhere under bin/, so it guards nothing at runtime; a mention in a comment or a usage string is not a caller"
    return 0
  fi
  probe_answer PASS verified "$symbol is called from ${callers% }"
}

# Does anything own this authorisation? An authorisation with no owner decays
# into prose exactly the way a dated exception does.
probe_work_owned() {  # <probe-json>
  local probe=$1 id show rc git_answered=0 state=
  id=$(printf '%s' "$probe" | jq -r '.work_id // ""')
  if [ -z "$id" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "probe declares no work_id"
    return 0
  fi
  if [ -f "$STATE/$id.meta" ]; then
    probe_answer PASS verified "a live task record owns $id"
    return 0
  fi
  # git first, because a branch answers without any backlog backend at all.
  if command -v git >/dev/null 2>&1 && git -C "$FM_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git_answered=1
    if git -C "$FM_ROOT" rev-parse --verify --quiet "refs/heads/fm/$id" >/dev/null 2>&1; then
      probe_answer PASS verified "a local branch fm/$id owns $id"
      return 0
    fi
  fi
  # The compatibility floor in fm-tasks-axi-lib.sh gates MUTATION features
  # (update --archive-body, multi-id mv) and costs three subprocesses to answer.
  # This is a read, so it gates on the two things a read actually needs - a
  # non-manual backend and the tool being present - and lets the read itself
  # answer. Session start is on every session's critical path; a check that is
  # slow enough to be turned off protects nothing.
  if fm_backlog_backend_manual "$CONFIG" || ! command -v tasks-axi >/dev/null 2>&1 \
    || ! bounding_tool >/dev/null; then
    probe_answer NO_VERIFIER_RAN verifier_unavailable \
      "no live task record and no local branch owns $id, and the backlog could not be read mechanically here, so an already-dispatched or already-landed record cannot be ruled out"
    return 0
  fi
  show=$(cd "$FM_HOME" && run_timed "$PROBE_TIMEOUT" tasks-axi show "$id" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    probe_timed_out "the backlog read for $id" "$PROBE_TIMEOUT"
    return 0
  fi
  if [ "$rc" -eq 0 ] && [ -n "$show" ]; then
    state=$(printf '%s\n' "$show" | awk -F': ' '$1 ~ /^ *state$/ { print $2; exit }')
  fi
  case "$state" in
    in_flight|done)
      probe_answer PASS verified "the backlog records $id as $state"
      return 0
      ;;
  esac
  if [ "$git_answered" -eq 0 ]; then
    probe_answer NO_VERIFIER_RAN verifier_unavailable \
      "the backlog does not own $id and no git checkout was readable, so a branch owning it could not be ruled out"
    return 0
  fi
  probe_answer FAIL verifier_reported_failure \
    "nothing owns $id: no live task record, no local branch fm/$id, and no in-flight or done backlog record"
}

# Typed probes are the closed, audited, 10s-bounded set described under TWO KINDS
# OF PROBE, so they carry no execution guard: running one is a cost this file can
# account for, and refusing to run them is what would leave a satisfied entry
# printing forever.
run_probe() {  # <probe-json>
  local kind
  kind=$(printf '%s' "$1" | jq -r '.kind // ""')
  case "$kind" in
    launch_permission_enforced) probe_launch_permission_enforced "$1" ;;
    command_answers) probe_command_answers "$1" ;;
    command_answer_matches) probe_command_answer_matches "$1" ;;
    test_passes) probe_test_passes "$1" ;;
    symbol_called) probe_symbol_called "$1" ;;
    work_owned) probe_work_owned "$1" ;;
    *) probe_answer NO_VERIFIER_RAN usage_error "unknown probe kind \"$kind\"" ;;
  esac
}

# --- the pinned decision-file probe block ------------------------------------
#
# One fenced ```probe block per decision file, in the format the 2026-08-10 ruling
# pinned. The parser refuses a second block rather than choosing one: a file
# carrying two probes has no single answer, and picking either would invent one.

DP_TIER='' DP_RUN='' DP_CONTROL='' DP_REASON='' DP_FAULT=''
parse_decision_probe() {  # <decision-file> -> 0 with DP_* set, 1 when no block
  local file=$1 line in_block=0 blocks=0 key value
  DP_TIER='' DP_RUN='' DP_CONTROL='' DP_REASON='' DP_FAULT=''
  # An existing file this process cannot read may carry a probe nobody can see,
  # so it is a fault rather than "no block" - and reading it unguarded would put a
  # shell error on stderr instead of an answer.
  if [ ! -r "$file" ]; then
    DP_FAULT="the decision file exists but cannot be read, so a registered probe cannot be ruled out"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '```probe'|'```probe '*)
        if [ "$in_block" -eq 1 ]; then
          DP_FAULT="a probe block is opened inside another probe block"
          return 0
        fi
        blocks=$((blocks + 1))
        in_block=1
        continue
        ;;
    esac
    if [ "$in_block" -eq 1 ]; then
      case "$line" in
        '```'*) in_block=0; continue ;;
      esac
      case "$line" in
        *:*) ;;
        *) continue ;;
      esac
      key=${line%%:*}
      key=${key#"${key%%[![:space:]]*}"}
      key=${key%"${key##*[![:space:]]}"}
      value=${line#*:}
      value=${value#"${value%%[![:space:]]*}"}
      value=${value%"${value##*[![:space:]]}"}
      case "$key" in
        tier) DP_TIER=$value ;;
        run) DP_RUN=$value ;;
        control) DP_CONTROL=$value ;;
        reason) DP_REASON=$value ;;
      esac
    fi
  done < "$file"
  [ "$blocks" -ne 0 ] || return 1
  if [ "$blocks" -gt 1 ]; then
    DP_FAULT="the file carries $blocks probe blocks; the pinned format allows exactly one"
    return 0
  fi
  [ "$in_block" -eq 0 ] || DP_FAULT="the probe block is never closed"
  return 0
}

# Validates DP_* against the pinned per-tier requirements. Prints one fault, or
# nothing when the block is well formed.
decision_probe_fault() {
  [ -z "$DP_FAULT" ] || { printf '%s' "$DP_FAULT"; return 0; }
  case "$DP_TIER" in
    executable)
      [ -n "$DP_RUN" ] || { printf 'tier executable declares no run'; return 0; }
      ;;
    cited-control)
      [ -n "$DP_RUN" ] || { printf 'tier cited-control declares no run'; return 0; }
      [ -n "$DP_CONTROL" ] || { printf 'tier cited-control declares no control'; return 0; }
      ;;
    attested)
      [ -n "$DP_REASON" ] || { printf 'tier attested declares no reason'; return 0; }
      [ -z "$DP_RUN" ] || { printf 'tier attested carries a run; an attested criterion declares no probe'; return 0; }
      ;;
    '') printf 'the probe block declares no tier' ;;
    *) printf 'unknown tier "%s"' "$DP_TIER" ;;
  esac
}

decision_file() {  # <task> <key>
  printf '%s/%s/decision-%s.md' "$DATA" "$1" "$2"
}

# The worktree the ruling says a `run:` executes from. An absent record or an
# absent directory is could-not-observe: the probe did not run, and a probe that
# did not run is never a pass.
task_worktree() {  # <task> -> path, or empty
  local meta="$STATE/$1.meta" wt
  [ -r "$meta" ] || return 1
  wt=$(sed -n 's/^worktree=//p' "$meta" | head -1)
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  printf '%s' "$wt"
}

# --- the decision-probe result cache -----------------------------------------
#
# See THE DECISION-PROBE CACHE in the header for why this exists and the one rule
# it may not break. Everything below is best-effort: a cache that cannot be read
# or written costs a probe run, never an answer.

TAB=$'\t'

# A key's fingerprint: what the probe's answer actually DEPENDS on. That is the
# decision file's own bytes (which subsume tier, run and control, and change
# whenever the criterion is rewritten), the worktree the `run:` executes from, and
# that worktree's head - a new commit is the ordinary way a criterion becomes met,
# so a stored verdict from before it is inapplicable rather than merely old.
#
# The task's status stream is deliberately NOT in the key. The open-decision fold
# is DRIVEN by status appends, so keying on them would miss on the one append
# where the cache was supposed to help and hit only on idle tasks - and it would
# say nothing about the worktree, where the answer actually lives.
probe_cache_fingerprint() {  # <task> <key> <worktree>
  local file bytes=no-decision-file head=no-head
  file=$(decision_file "$1" "$2")
  # The redirection is guarded rather than silenced: an absent file would put a
  # shell error on stderr before any 2>/dev/null on the command could apply, and
  # this runs inside a fold that must answer rather than emit.
  [ -r "$file" ] && bytes=$(cksum < "$file" 2>/dev/null || printf 'unreadable-decision')
  if command -v git >/dev/null 2>&1; then
    head=$(git -C "$3" rev-parse HEAD 2>/dev/null) || head=
    [ -n "$head" ] || head=no-head
  else
    head=no-git
  fi
  # The record below is tab-separated and the fingerprint is not its last field,
  # so a tab in any component is folded rather than carried.
  local fp="$bytes|$head|$3"
  printf '%s' "${fp//$'\t'/ }"
}

probe_cache_path() {  # <task> <key>
  local safe="$1__$2"
  printf '%s/%s' "$PROBE_CACHE_DIR" "$(printf '%s' "$safe" | tr -c 'A-Za-z0-9._-' '_')"
}

# 0 with PROBE_* set from a result still inside the freshness bound. Anything
# else - no entry, a different fingerprint, an unreadable or malformed line, or an
# observation older than the bound - returns 1, and the caller runs the probe.
probe_cache_read() {  # <task> <key> <fingerprint> <now>
  local path line stamp iso fp result reason evidence age t=$'\t'
  [ "$PROBE_CACHE_TTL" -gt 0 ] 2>/dev/null || return 1
  path=$(probe_cache_path "$1" "$2")
  [ -r "$path" ] || return 1
  IFS= read -r line < "$path" 2>/dev/null || return 1
  case "$line" in *"$t"*"$t"*"$t"*"$t"*"$t"*) ;; *) return 1 ;; esac
  stamp=${line%%"$t"*};  line=${line#*"$t"}
  iso=${line%%"$t"*};    line=${line#*"$t"}
  fp=${line%%"$t"*};     line=${line#*"$t"}
  result=${line%%"$t"*}; line=${line#*"$t"}
  reason=${line%%"$t"*}
  evidence=${line#*"$t"}
  [ -n "$stamp" ] && [ -n "$result" ] && [ -n "$reason" ] || return 1
  case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
  [ "$fp" = "$3" ] || return 1
  age=$(( $4 - stamp ))
  [ "$age" -ge 0 ] && [ "$age" -le "$PROBE_CACHE_TTL" ] || return 1
  # The observation time rides the evidence, so nothing downstream - a refusal
  # note, a fold record, a human read - can mistake this for a fresh answer.
  probe_answer "$result" "$reason" \
    "$evidence [observed ${iso:-at an unrecorded time}, ${age}s ago, within the ${PROBE_CACHE_TTL}s freshness bound]"
  PROBE_FROM_CACHE=1
  return 0
}

probe_cache_write() {  # <task> <key> <fingerprint> <now> <iso>
  local path tmp
  [ "$PROBE_CACHE_TTL" -gt 0 ] 2>/dev/null || return 0
  path=$(probe_cache_path "$1" "$2")
  mkdir -p "$PROBE_CACHE_DIR" 2>/dev/null || return 0
  tmp="$path.$$"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$4" "$5" "$3" "$PROBE_RESULT" "$PROBE_REASON" "$PROBE_EVIDENCE" \
    > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# 1 when the PROBE_* fields were served from a stored observation rather than
# from a run just now. Read by the closure gate, so an acceptance resting on an
# earlier observation says so instead of passing silently.
PROBE_FROM_CACHE=0

# Runs one parsed decision probe, setting PROBE_*. DP_* must already be valid.
run_decision_probe() {  # <task> <key>
  local task=$1 key=$2 wt out rc fingerprint now iso stamps
  PROBE_FROM_CACHE=0
  if [ "$DP_TIER" = attested ]; then
    # Marked and visible, never verified: an attested criterion has no verdict to
    # reach, so it stays could-not-observe by construction rather than by failure.
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "attested, not probed: $DP_REASON"
    return 0
  fi
  if [ "$DP_TIER" = cited-control ] && [ -z "$DP_CONTROL" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "tier cited-control cites no control"
    return 0
  fi
  if ! wt=$(task_worktree "$task"); then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "the task worktree for $task is not recorded or no longer exists, so the probe for $key could not be run from it"
    return 0
  fi
  if ! bounding_tool >/dev/null; then
    probe_answer NO_VERIFIER_RAN verifier_unavailable \
      "no timeout tool is available to bound the probe for $key, so it was not run"
    return 0
  fi
  # The trust decision, and the only guard in this file. No execution, and no
  # stored verdict standing in for one either: serving a cached PASS would CLOSE a
  # key on an observation this caller did not make, which is the accepting half of
  # the same failure, so the honest answer is could-not-observe and the closure
  # gate keeps the decision open.
  if [ "$NO_DECISION_RUN" -eq 1 ]; then
    probe_not_executed "the probe for $key"
    return 0
  fi
  # Everything above this line is a guard that costs nothing to re-evaluate, so
  # only the execution below is worth caching - and only it can be served from a
  # stored observation.
  stamps=$(date -u "+%s${TAB}%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || stamps=
  now=${stamps%%"$TAB"*}
  iso=${stamps#*"$TAB"}
  fingerprint=$(probe_cache_fingerprint "$task" "$key" "$wt")
  case "$now" in
    ''|*[!0-9]*) now= ;;
    *) probe_cache_read "$task" "$key" "$fingerprint" "$now" && return 0 ;;
  esac
  out=$(cd "$wt" && run_timed "$DECISION_PROBE_TIMEOUT" bash -c "$DP_RUN" 2>&1)
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    probe_timed_out "the probe for $key" "$DECISION_PROBE_TIMEOUT"
  elif [ "$rc" -eq 125 ] || [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "the probe for $key could not execute (exit $rc): $(printf '%s' "$out" | tail -1)"
  elif [ "$rc" -ne 0 ]; then
    probe_answer FAIL verifier_reported_failure \
      "the criterion is not met: the probe for $key exited $rc: $(printf '%s' "$out" | tail -1)"
  elif [ "$DP_TIER" = cited-control ]; then
    probe_answer PASS verified \
      "the probe for $key passes now, with $(control_citation "$DP_CONTROL") cited as the control watched to fail first"
  else
    probe_answer PASS verified "the probe for $key exits 0, so the criterion is met"
  fi
  [ -z "$now" ] || probe_cache_write "$task" "$key" "$fingerprint" "$now" "$iso"
  return 0
}

# --- admissibility -----------------------------------------------------------
#
# schema.json owns the field contract; it is read rather than restated, so the
# two cannot disagree. An inadmissible entry is reported, never dropped.

REFUSED_KEYS=
REQUIRED_KEYS=
SCHEMA_PATH=
SCHEMA_READ=0
read_schema() {
  [ "$SCHEMA_READ" -eq 0 ] || return 0
  local path="$REG_DIR/schema.json"
  [ -r "$path" ] || return 1
  jq -e '.commitment_schema_version and .required and .refused_keys
         and .assurance_tiers and .required_by_assurance' "$path" >/dev/null 2>&1 || return 1
  REFUSED_KEYS=$(jq -r '.refused_keys[]' "$path")
  REQUIRED_KEYS=$(jq -r '.required | keys[]' "$path")
  SCHEMA_PATH=$path
  SCHEMA_READ=1
  return 0
}

# Prints one refusal reason, or nothing when the entry is admissible.
entry_inadmissible_reason() {  # <entry-json> <expected-id>
  local doc=$1 want=$2 key got tier fault
  printf '%s' "$doc" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { printf 'entry is not a JSON object'; return 0; }
  got=$(printf '%s' "$doc" | jq -r '.id // ""')
  [ "$got" = "$want" ] \
    || { printf 'entry id "%s" does not match its filename "%s"' "$got" "$want"; return 0; }
  got=$(printf '%s' "$doc" | jq -r '.commitment_schema_version // ""')
  [ "$got" = "$SCHEMA_VERSION" ] \
    || { printf 'commitment_schema_version is "%s", not %s' "$got" "$SCHEMA_VERSION"; return 0; }
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if printf '%s' "$doc" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1; then
      printf 'entry carries a hand-written "%s"; a status word must not be able to satisfy a commitment' "$key"
      return 0
    fi
  done <<EOF
$REFUSED_KEYS
EOF
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! printf '%s' "$doc" | jq -e --arg k "$key" '(.[$k] // "") != ""' >/dev/null 2>&1; then
      printf 'entry has no %s' "$key"
      return 0
    fi
  done <<EOF
$REQUIRED_KEYS
EOF
  tier=$(printf '%s' "$doc" | jq -r '.assurance // ""')
  if ! jq -e --arg t "$tier" '.assurance_tiers | has($t)' "$SCHEMA_PATH" >/dev/null 2>&1; then
    printf 'unknown assurance tier "%s"' "$tier"
    return 0
  fi
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! printf '%s' "$doc" | jq -e --arg k "$key" '(.[$k] // "") != "" or ((.[$k] | type) == "object")' >/dev/null 2>&1; then
      printf 'assurance tier "%s" requires %s, and the entry has none' "$tier" "$key"
      return 0
    fi
  done < <(jq -r --arg t "$tier" '.required_by_assurance[$t][]? ' "$SCHEMA_PATH")
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if printf '%s' "$doc" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1; then
      printf 'assurance tier "%s" forbids %s' "$tier" "$key"
      return 0
    fi
  done < <(jq -r --arg t "$tier" '.forbidden_by_assurance[$t][]? ' "$SCHEMA_PATH")
  if [ "$tier" != attested ]; then
    printf '%s' "$doc" | jq -e '(.probe | type) == "object" and ((.probe.kind // "") != "")' >/dev/null 2>&1 \
      || { printf 'entry declares no probe; an entry without one cannot be admitted'; return 0; }
  fi
  # Every path field a probe kind can carry, refused HERE rather than only inside
  # each kind, so the entry is reported inadmissible before anything is run and a
  # kind added later inherits the constraint by naming one of these fields. The
  # field names are what is enumerated, not the kinds, because the target is the
  # thing being constrained. See probe_target_fault above for why.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    got=$(printf '%s' "$doc" | jq -r --arg k "$key" '.probe[$k] // ""' 2>/dev/null) || got=
    fault=$(probe_target_fault "probe.$key" "$got")
    [ -z "$fault" ] || { printf 'inadmissible probe target: %s' "$fault"; return 0; }
  done <<EOF
command
test
defined_in
EOF
  # unobserved_conditions is the only field that can WITHHOLD satisfaction, so a
  # malformed one is the one malformation that would let a passing probe retire a
  # half-observed commitment. A bare string, an array of objects, or a null member
  # all make the read below produce nothing, and nothing reads as "no half was
  # declared" - the exact outcome the field exists to prevent. So the type is
  # validated here and a bad one makes the entry inadmissible.
  if printf '%s' "$doc" | jq -e 'has("unobserved_conditions")' >/dev/null 2>&1; then
    printf '%s' "$doc" | jq -e '
      (.unobserved_conditions | type) == "array"
      and (.unobserved_conditions | length) > 0
      and all(.unobserved_conditions[]; type == "string" and (. | length) > 0)' >/dev/null 2>&1 \
      || { printf 'unobserved_conditions must be a non-empty array of non-empty strings; a malformed one would silently skip the guard that stops a passing probe retiring a half-observed commitment'; return 0; }
  fi
  return 0
}

# --- reading the register ----------------------------------------------------

REGISTER_FAULT=
ENTRY_IDS=()
ENTRY_PATHS=()
ENTRY_SOURCES=()

collect_dir() {  # <dir> <required 0|1>
  local dir=$1 required=$2 f base i
  if [ ! -d "$dir" ]; then
    [ "$required" -eq 0 ] || REGISTER_FAULT="the tracked register $dir is absent, so no commitment could be read"
    return 0
  fi
  if [ ! -r "$dir" ]; then
    REGISTER_FAULT="the register $dir is not readable"
    return 0
  fi
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    base=${f##*/}
    case "$base" in schema.json) continue ;; esac
    base=${base%.json}
    for i in "${ENTRY_IDS[@]+"${ENTRY_IDS[@]}"}"; do
      if [ "$i" = "$base" ]; then
        REGISTER_FAULT="commitment id \"$base\" is declared twice; an id must be unique across the tracked register and the home overlay"
        return 0
      fi
    done
    ENTRY_IDS+=("$base")
    ENTRY_PATHS+=("$f")
    ENTRY_SOURCES+=(json)
  done
}

# Discovered ruled-finding probes. Only files that actually carry a probe block
# become entries: a decision ruled before the format existed has no registered
# probe, and manufacturing one for it is exactly what the ruling forbids.
collect_decisions() {
  local f task key
  [ -d "$DATA" ] || return 0
  for f in "$DATA"/*/decision-*.md; do
    [ -e "$f" ] || continue
    task=${f#"$DATA"/}
    task=${task%%/*}
    key=${f##*/decision-}
    key=${key%.md}
    parse_decision_probe "$f" || continue
    ENTRY_IDS+=("decision:$task:$key")
    ENTRY_PATHS+=("$f")
    ENTRY_SOURCES+=(decision)
  done
}

# --closes reads no register at all: it is asked about one named decision key and
# reads only that key's file. Collecting entries for it would spend the fold's
# budget on JSON it never looks at, and would drag jq back onto a path that does
# not use it.
if [ "$MODE" != closes ]; then
  collect_dir "$REG_DIR" 1
  [ -n "$REGISTER_FAULT" ] || collect_dir "$HOME_REG_DIR" 0
  if [ -z "$REGISTER_FAULT" ] && [ "${#ENTRY_IDS[@]}" -gt 0 ] && ! read_schema; then
    REGISTER_FAULT="$REG_DIR/schema.json is missing or unreadable, so no entry could be validated"
  fi
  # --open does not need the decision inventory either: it deliberately leaves
  # discovered probes to the open-decision fold rather than adding a second
  # surface for them.
  case "$MODE" in
    open) ;;
    *) [ -n "$REGISTER_FAULT" ] || collect_decisions ;;
  esac
fi

# --- evaluation --------------------------------------------------------------

ENTRY_STATE=''
# The three handlers fm_verify_case dispatches to. It calls them BY NAME, which
# is the mechanism that lets it refuse a consumer that does not supply all three,
# so they are invoked indirectly and never from this file.
# shellcheck disable=SC2329
on_pass() { ENTRY_STATE=SATISFIED; }
# shellcheck disable=SC2329
on_fail() { ENTRY_STATE=UNMET; }
# shellcheck disable=SC2329
on_unverified() { ENTRY_STATE=UNOBSERVED; }

E_ID='' E_RECORDED='' E_AUTHORITY='' E_UNMET_STATE='' E_SATISFIED_WHEN='' E_TIER='' E_KIND=''
E_CONTROL='' E_DEADLINE='' E_NOTE='' E_OVERDUE=0 E_SOURCE='' E_UNOBSERVED_CONDITIONS=''

reset_entry_fields() {
  E_RECORDED='' E_AUTHORITY='' E_UNMET_STATE='' E_SATISFIED_WHEN='' E_TIER='' E_KIND=''
  E_CONTROL='' E_DEADLINE='' E_NOTE='' E_OVERDUE=0 E_UNOBSERVED_CONDITIONS=''
}

# Maps PROBE_* onto ENTRY_STATE through the three-valued consumer, which refuses a
# reader that does not handle all three.
settle_entry_state() {  # <id>
  local record
  record=$(printf 'verify[1]{verifier,result,reason,evidence_ref}:\n  commitment:%s,%s,%s,%s\n' \
    "$1" "$PROBE_RESULT" "$PROBE_REASON" "$PROBE_EVIDENCE")
  ENTRY_STATE=
  fm_verify_case "$record" on_pass on_fail on_unverified
  if [ -z "$ENTRY_STATE" ]; then
    ENTRY_STATE=UNOBSERVED
    probe_answer NO_VERIFIER_RAN usage_error "the probe result could not be read as a three-valued observation"
  fi
}

evaluate_json_entry() {  # <id> <path>
  local id=$1 path=$2 doc reason
  if ! doc=$(cat "$path" 2>/dev/null) || ! printf '%s' "$doc" | jq -e . >/dev/null 2>&1; then
    ENTRY_STATE=UNOBSERVED
    probe_answer NO_VERIFIER_RAN usage_error "entry file $path could not be read as JSON"
    return 0
  fi
  reason=$(entry_inadmissible_reason "$doc" "$id")
  E_RECORDED=$(printf '%s' "$doc" | jq -r '.recorded // ""')
  E_AUTHORITY=$(printf '%s' "$doc" | jq -r '.authority // ""')
  E_UNMET_STATE=$(printf '%s' "$doc" | jq -r '.unmet_state // ""')
  E_SATISFIED_WHEN=$(printf '%s' "$doc" | jq -r '.satisfied_when // ""')
  E_TIER=$(printf '%s' "$doc" | jq -r '.assurance // ""')
  E_KIND=$(printf '%s' "$doc" | jq -r '.probe.kind // ""')
  E_CONTROL=$(printf '%s' "$doc" | jq -r '.control // ""')
  E_DEADLINE=$(printf '%s' "$doc" | jq -r '.deadline // ""')
  E_NOTE=$(printf '%s' "$doc" | jq -r '.note // ""')
  # A malformed field is already inadmissible below; this read only has to avoid
  # putting jq's complaint about it on the caller's stderr in the meantime.
  E_UNOBSERVED_CONDITIONS=$(printf '%s' "$doc" \
    | jq -r '(.unobserved_conditions // []) | join("; ")' 2>/dev/null) \
    || E_UNOBSERVED_CONDITIONS=''
  if [ -n "$reason" ]; then
    # Inadmissible is could-not-observe, and loudly so: an entry this file cannot
    # interpret is an entry whose commitment it cannot judge.
    ENTRY_STATE=UNOBSERVED
    probe_answer NO_VERIFIER_RAN usage_error "inadmissible entry: $reason"
    return 0
  fi
  if [ "$E_TIER" = attested ]; then
    ENTRY_STATE=UNOBSERVED
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "attested, not probed: $(printf '%s' "$doc" | jq -r '.reason // "no reason recorded"')"
    return 0
  fi
  run_probe "$(printf '%s' "$doc" | jq -c '.probe')"
  if [ "$E_TIER" = cited-control ] && [ "$PROBE_RESULT" = PASS ]; then
    probe_answer PASS verified \
      "$PROBE_EVIDENCE, with $(control_citation "$E_CONTROL") cited as the control watched to fail first"
  fi
  # A commitment whose probe covers only part of it must not have that part's
  # verdict read as the whole. The covered half is reported exactly as the probe
  # found it; the declared-uncovered half is could-not-observe, which is what
  # stops the entry retiring on half an answer. The field can only ever withhold
  # SATISFIED, never grant it, which is why it is not a refused status word.
  if [ -n "$E_UNOBSERVED_CONDITIONS" ]; then
    if [ "$PROBE_RESULT" = PASS ]; then
      probe_answer NO_VERIFIER_RAN verification_unreachable \
        "$PROBE_EVIDENCE - but this commitment also requires $E_UNOBSERVED_CONDITIONS, which no probe here observes, so only part of it is answered"
    else
      probe_answer "$PROBE_RESULT" "$PROBE_REASON" \
        "$PROBE_EVIDENCE; and this commitment further requires $E_UNOBSERVED_CONDITIONS, which no probe here observes"
    fi
  fi
  settle_entry_state "$id"
}

# The ruling pins `control` as the NAME of the test or artifact watched to fail
# first, so the register surfaces it rather than gating on it - a name is not
# required to be a resolvable path, and rejecting a legitimate citation that is
# not one would make the tier unusable. When the name does resolve to something on
# disk, say so, because that is strictly more than the citation claimed. What the
# register cannot do is confirm the artifact records a real red observation; that
# is why the tier is "cited", and why it sits below nothing and above a claim.
control_citation() {  # <control> -> the citation, marked when it resolves
  if [ -n "${1:-}" ] && { [ -e "$FM_ROOT/$1" ] || [ -e "$FM_HOME/$1" ] || [ -e "$1" ]; }; then
    printf '%s (resolves on disk)' "$1"
  else
    printf '%s' "${1:-an unnamed control}"
  fi
}

evaluate_decision_entry() {  # <id> <path>
  local id=$1 path=$2 task key fault
  task=${id#decision:}
  key=${task#*:}
  task=${task%%:*}
  E_AUTHORITY=${path#"$FM_HOME"/}
  E_UNMET_STATE=RULED-NOT-MET
  E_SATISFIED_WHEN="the probe this ruling pinned exits 0, so the ruled criterion is met rather than merely applied"
  if ! parse_decision_probe "$path"; then
    ENTRY_STATE=UNOBSERVED
    probe_answer NO_VERIFIER_RAN usage_error "the decision file carries no probe block"
    return 0
  fi
  E_TIER=$DP_TIER
  E_CONTROL=$DP_CONTROL
  E_RECORDED="ruled criterion for decision $key on task $task"
  fault=$(decision_probe_fault)
  if [ -n "$fault" ]; then
    ENTRY_STATE=UNOBSERVED
    probe_answer NO_VERIFIER_RAN usage_error "inadmissible probe block: $fault"
    return 0
  fi
  run_decision_probe "$task" "$key"
  settle_entry_state "$id"
}

evaluate_entry() {  # <index>
  local i=$1 today
  E_ID=${ENTRY_IDS[$i]}
  E_SOURCE=${ENTRY_SOURCES[$i]}
  reset_entry_fields
  case "$E_SOURCE" in
    decision) evaluate_decision_entry "$E_ID" "${ENTRY_PATHS[$i]}" ;;
    *) evaluate_json_entry "$E_ID" "${ENTRY_PATHS[$i]}" ;;
  esac
  if [ "$ENTRY_STATE" != SATISFIED ] && [ -n "$E_DEADLINE" ]; then
    today=$(date -u +%Y-%m-%d)
    [ "$E_DEADLINE" \< "$today" ] && E_OVERDUE=1
  fi
  return 0
}

# --- reports -----------------------------------------------------------------

open_line() {
  local label detail
  if [ "$ENTRY_STATE" = UNMET ]; then
    label="UNMET (${E_UNMET_STATE:-unlabelled})"
  else
    label=COULD-NOT-OBSERVE
  fi
  detail=$PROBE_EVIDENCE
  [ "$E_OVERDUE" -eq 1 ] && detail="$detail; past its $E_DEADLINE deadline"
  printf 'COMMITMENT: %s %s - %s\n' "$E_ID" "$label" "$detail"
}

render_open() {
  local worst="$EXIT_OK" i
  if [ -n "$REGISTER_FAULT" ]; then
    printf 'COMMITMENT: register unreadable - %s\n' "$REGISTER_FAULT"
    return "$EXIT_UNOBSERVED"
  fi
  for i in "${!ENTRY_IDS[@]}"; do
    evaluate_entry "$i"
    case "$ENTRY_STATE" in
      SATISFIED) continue ;;
      UNMET) [ "$worst" -eq "$EXIT_UNOBSERVED" ] || worst=$EXIT_UNMET ;;
      *) worst=$EXIT_UNOBSERVED ;;
    esac
    open_line
  done
  return "$worst"
}

render_human() {
  local worst="$EXIT_OK" i satisfied=0 unmet=0 unobserved=0 shown=0
  if [ -n "$REGISTER_FAULT" ]; then
    printf 'commitment register · UNREADABLE\n  %s\n' "$REGISTER_FAULT"
    return "$EXIT_UNOBSERVED"
  fi
  printf 'Commitments recorded, and whether a probe says they are real yet.\n\n'
  for i in "${!ENTRY_IDS[@]}"; do
    [ -z "$TARGET" ] || [ "${ENTRY_IDS[$i]}" = "$TARGET" ] || continue
    evaluate_entry "$i"
    shown=$((shown + 1))
    case "$ENTRY_STATE" in
      SATISFIED) satisfied=$((satisfied + 1)); printf '  SATISFIED   %s (retired: the probe passed)\n' "$E_ID" ;;
      UNMET) unmet=$((unmet + 1)); [ "$worst" -eq "$EXIT_UNOBSERVED" ] || worst=$EXIT_UNMET
        printf '  UNMET       %s   %s\n' "$E_ID" "${E_UNMET_STATE:-unlabelled}" ;;
      *) unobserved=$((unobserved + 1)); worst=$EXIT_UNOBSERVED
        printf '  UNOBSERVED  %s   could-not-observe\n' "$E_ID" ;;
    esac
    [ -z "$E_RECORDED" ] || printf '              recorded:   %s\n' "$E_RECORDED"
    [ -z "$E_AUTHORITY" ] || printf '              authority:  %s\n' "$E_AUTHORITY"
    [ -z "$E_SATISFIED_WHEN" ] || printf '              real when:  %s\n' "$E_SATISFIED_WHEN"
    printf '              tier:       %s\n' "${E_TIER:-none declared}"
    [ -z "$E_CONTROL" ] || printf '              control:    %s\n' "$E_CONTROL"
    printf '              observed:   %s\n' "$PROBE_EVIDENCE"
    [ -z "$E_UNOBSERVED_CONDITIONS" ] \
      || printf '              not probed: %s\n' "$E_UNOBSERVED_CONDITIONS"
    [ "$E_OVERDUE" -eq 1 ] && printf '              OVERDUE:    the %s deadline has passed\n' "$E_DEADLINE"
    [ -z "$E_NOTE" ] || printf '              note:       %s\n' "$E_NOTE"
    printf '\n'
  done
  if [ -n "$TARGET" ] && [ "$shown" -eq 0 ]; then
    printf 'fm-commitment-register: no commitment with id "%s"\n' "$TARGET" >&2
    return "$EXIT_UNOBSERVED"
  fi
  printf '%s satisfied · %s unmet · %s could-not-observe\n' "$satisfied" "$unmet" "$unobserved"
  printf 'A state here is computed from the probe on every read and is never stored.\n'
  return "$worst"
}

render_json() {
  local worst="$EXIT_OK" i shown=0 rows='[]' row
  if [ -n "$REGISTER_FAULT" ]; then
    jq -n --arg schema "$SCHEMA" --arg fault "$REGISTER_FAULT" \
      '{schema:$schema, register_fault:$fault, entries:[]}'
    return "$EXIT_UNOBSERVED"
  fi
  for i in "${!ENTRY_IDS[@]}"; do
    [ -z "$TARGET" ] || [ "${ENTRY_IDS[$i]}" = "$TARGET" ] || continue
    evaluate_entry "$i"
    shown=$((shown + 1))
    case "$ENTRY_STATE" in
      UNMET) [ "$worst" -eq "$EXIT_UNOBSERVED" ] || worst=$EXIT_UNMET ;;
      UNOBSERVED) worst=$EXIT_UNOBSERVED ;;
    esac
    row=$(jq -cn \
      --arg id "$E_ID" --arg source "$E_SOURCE" --arg recorded "$E_RECORDED" \
      --arg authority "$E_AUTHORITY" --arg unmet_state "$E_UNMET_STATE" \
      --arg satisfied_when "$E_SATISFIED_WHEN" --arg tier "$E_TIER" \
      --arg kind "$E_KIND" --arg control "$E_CONTROL" --arg deadline "$E_DEADLINE" \
      --arg note "$E_NOTE" --arg state "$ENTRY_STATE" --arg result "$PROBE_RESULT" \
      --arg reason "$PROBE_REASON" --arg evidence "$PROBE_EVIDENCE" \
      --arg unobserved "$E_UNOBSERVED_CONDITIONS" \
      --argjson overdue "$E_OVERDUE" \
      '{id:$id, source:$source, recorded:$recorded, authority:$authority,
        unmet_state:$unmet_state, satisfied_when:$satisfied_when,
        assurance:(if $tier == "" then null else $tier end),
        probe_kind:(if $kind == "" then null else $kind end),
        control:(if $control == "" then null else $control end),
        deadline:(if $deadline == "" then null else $deadline end),
        note:(if $note == "" then null else $note end),
        unobserved_conditions:(if $unobserved == "" then null else $unobserved end),
        state:$state, probe_result:$result, probe_reason:$reason,
        probe_evidence:$evidence, overdue:($overdue == 1),
        state_is_derived:true}')
    rows=$(printf '%s' "$rows" | jq -c --argjson r "$row" '. + [$r]')
  done
  jq -n --arg schema "$SCHEMA" --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg register "$REG_DIR" --arg overlay "$HOME_REG_DIR" --argjson rows "$rows" \
    '{schema:$schema, generated:$generated, register:$register,
      home_overlay:$overlay, register_fault:null, entries:$rows}'
  if [ -n "$TARGET" ] && [ "$shown" -eq 0 ]; then
    printf 'fm-commitment-register: no commitment with id "%s"\n' "$TARGET" >&2
    return "$EXIT_UNOBSERVED"
  fi
  return "$worst"
}

# The closure gate. Silence plus exit 0 is "no probe is registered for this key",
# which is the answer for every decision ruled before the format existed.
render_closes() {
  local file
  file=$(decision_file "$CLOSES_TASK" "$CLOSES_KEY")
  # No decision file at all means no probe is registered for this key, which is
  # the answer for every decision ruled before the format existed - accept, and
  # say nothing. A file that EXISTS but cannot be read is a different answer: it
  # may carry a probe nobody can see, so it refuses rather than accepting.
  [ -e "$file" ] || return "$EXIT_OK"
  if [ ! -r "$file" ]; then
    printf 'the decision file %s exists but cannot be read, so a registered probe cannot be ruled out and this resolution is not accepted\n' \
      "${file#"$FM_HOME"/}"
    return "$EXIT_UNOBSERVED"
  fi
  parse_decision_probe "$file" || return "$EXIT_OK"
  local fault
  fault=$(decision_probe_fault)
  if [ -n "$fault" ]; then
    printf 'the probe block in %s cannot be read (%s), so this resolution is not accepted\n' \
      "${file#"$FM_HOME"/}" "$fault"
    return "$EXIT_UNOBSERVED"
  fi
  if [ "$DP_TIER" = attested ]; then
    # Accepted, never silently: the acceptance itself says it was attested rather
    # than verified, so nothing downstream can read it as a passed probe.
    printf 'accepted as ATTESTED-NOT-PROBED, not verified: %s\n' "$DP_REASON"
    return "$EXIT_OK"
  fi
  run_decision_probe "$CLOSES_TASK" "$CLOSES_KEY"
  case "$PROBE_RESULT" in
    PASS)
      # An acceptance resting on an earlier observation says when that
      # observation was made. Silence here would be exactly the "old answer
      # served as a current one" the cache is not allowed to introduce.
      [ "$PROBE_FROM_CACHE" -eq 0 ] || printf 'accepted on a probe result: %s\n' "$PROBE_EVIDENCE"
      return "$EXIT_OK"
      ;;
    FAIL) printf '%s\n' "$PROBE_EVIDENCE"; return "$EXIT_UNMET" ;;
    *) printf '%s\n' "$PROBE_EVIDENCE"; return "$EXIT_UNOBSERVED" ;;
  esac
}

case "$MODE" in
  open)
    [ -z "$TARGET" ] || die "--open reports the whole register"
    render_open
    exit $?
    ;;
  closes)
    [ -z "$TARGET" ] || die "--closes takes a task id and a decision key"
    render_closes
    exit $?
    ;;
  json) render_json; exit $? ;;
  *) render_human; exit $? ;;
esac
