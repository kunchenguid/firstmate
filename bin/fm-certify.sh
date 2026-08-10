#!/usr/bin/env bash
# fm-certify.sh - the certification predicate, and the executable refusal of a
# certification claim the evidence does not support.
#
# WHY THIS EXISTS. "Certified" was a word anyone could write. Nothing composed
# the evidence that would have contradicted it, so a closure audit found the
# entire refs/notes/no-mistakes namespace holding exactly one attestation - for a
# commit not even on the trunk - while the record still read as certified work.
# The commission's rule is that no lifecycle claim may be written directly when
# its truth can be derived, so CERTIFIED is computed here and is not a word any
# caller may set.
#
#   CERTIFIED = every APPLICABLE certification predicate is satisfied
#               for those exact bytes
#
# THE FOURTH VALUE, AND WHY THE OBSERVATION TYPE DID NOT GROW ONE.
# bin/fm-verify-lib.sh owns firstmate's three-valued OBSERVATION type - PASS,
# FAIL, NO_VERIFIER_RAN - and it is exactly right at the level it works on: one
# verifier, one run. Certification sits one level up and needs a distinction that
# is not an observation at all:
#
#   applicable      this route can produce this evidence, so go and observe it
#   not-applicable  this route STRUCTURALLY CANNOT produce this evidence
#
# A fork-landing branch is DELIBERATELY unsigned, because the pipeline opens its
# pull request against upstream and signing the landing branch would duplicate a
# live contribution. Its missing attestation is not a gap in the evidence; it is
# the route working as designed.
#
# not-applicable is NEVER folded into could-not-observe. "We looked, and this
# route cannot produce this evidence" and "we could not look" need different
# repairs, and a reader needs them apart: forcing the first into pass or fail is
# measurably what let twelve honest per-pull-request disclosures collapse into
# one dishonest summary. It is equally never folded into a PASS - a
# not-applicable predicate is REPORTED on every line of the verdict, so a route
# that can certify less says so out loud instead of certifying quietly.
#
# APPLICABILITY IS DERIVED TOO. It is decided from the route the work actually
# took - the delivery mode recorded for the task, and whether the repository
# lands on a fork - never from an argument. An applicability flag a caller could
# set would be the same defect one level along: a writable escape hatch out of
# the very predicate this command exists to enforce.
#
# THE PREDICATES:
#
#   independence  the checker was independent of the maker, on the process,
#                 model, vendor and credential-pool dimensions.
#                 bin/fm-independence-lib.sh derives it. Always applicable: every
#                 route that validates anything has someone doing the checking.
#   attestation   a head-bound no-mistakes note covers the landed bytes.
#                 bin/fm-attest.sh verify is the owner. NOT APPLICABLE on the
#                 fork-landing route, which is deliberately unsigned.
#   pr-checks     the pull request's check rollup passed on those exact bytes.
#                 bin/fm-verify.sh pr-checks is the owner, and it already refuses
#                 to read an empty rollup as a pass. NOT APPLICABLE on the
#                 local-only route, which has no pull request by design.
#
# Usage:
#   fm-certify.sh <task-id> [--json]
#       Certify a live task from its own durable record.
#   fm-certify.sh --repo <path> --branch <name> [--maker-harness H]
#                 [--maker-model M] [--mode MODE] [--head SHA] [--pr URL] [--json]
#       Certify explicit bytes. Every argument names WHICH BYTES to look at or
#       WHO MADE them; none of them can assert a result.
#   fm-certify.sh --help
#
# Exit status is the verdict, so a caller that ignores stdout still stops safely:
#   0  LANDED_AND_CERTIFIED - every applicable predicate is satisfied
#   2  usage error
#   3  LANDED_WITH_VERIFICATION_GAP - an applicable predicate was OBSERVED unmet
#   4  LANDED_WITH_VERIFICATION_GAP - an applicable predicate could not be
#      observed at all, so certification may not be asserted
#
# Environment:
#   FM_HOME                   operational home to read
#   FM_PIPELINE_STATE_DB      validation-pipeline state database
#   FM_CERTIFY_ATTEST         attestation verifier to run (tests)
#   FM_CERTIFY_PR_VERIFIER    pull-request check verifier to run (tests)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-independence-lib.sh
. "$SCRIPT_DIR/fm-independence-lib.sh"

SCHEMA=fm-certify.v1

EXIT_CERTIFIED=0
EXIT_USAGE=2
EXIT_UNMET=3
EXIT_UNOBSERVED=4

STATE_CERTIFIED=LANDED_AND_CERTIFIED
STATE_GAP=LANDED_WITH_VERIFICATION_GAP

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$SCRIPT_DIR/fm-certify.sh"
}

die() { printf 'fm-certify: %s\n' "$1" >&2; exit "$EXIT_USAGE"; }

TASK=''
REPO=''
BRANCH=''
MAKER_HARNESS=''
MAKER_MODEL=''
MODE=''
HEAD=''
PR=''
MODE_OUT=human

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --json) MODE_OUT=json; shift ;;
    --repo) [ "$#" -ge 2 ] || die "--repo needs a value"; REPO=$2; shift 2 ;;
    --branch) [ "$#" -ge 2 ] || die "--branch needs a value"; BRANCH=$2; shift 2 ;;
    --maker-harness) [ "$#" -ge 2 ] || die "--maker-harness needs a value"; MAKER_HARNESS=$2; shift 2 ;;
    --maker-model) [ "$#" -ge 2 ] || die "--maker-model needs a value"; MAKER_MODEL=$2; shift 2 ;;
    --mode) [ "$#" -ge 2 ] || die "--mode needs a value"; MODE=$2; shift 2 ;;
    --head) [ "$#" -ge 2 ] || die "--head needs a value"; HEAD=$2; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || die "--pr needs a value"; PR=$2; shift 2 ;;
    # There is deliberately no argument that sets a predicate result, an
    # independence verdict, or an applicability. Every such value is derived.
    -*) die "unknown option: $1" ;;
    *)
      [ -z "$TASK" ] || die "only one task id may be given"
      TASK=$1
      shift
      ;;
  esac
done

meta_value() {  # <file> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -1
}

# Fill unstated facts from the task's own durable record. A task id names WHICH
# bytes to certify; it can no more assert a result than the explicit form can.
if [ -n "$TASK" ]; then
  META="$STATE/$TASK.meta"
  [ -f "$META" ] || die "no durable record for task $TASK"
  [ -n "$REPO" ] || REPO=$(meta_value "$META" project)
  [ -n "$MAKER_HARNESS" ] || MAKER_HARNESS=$(meta_value "$META" harness)
  [ -n "$MAKER_MODEL" ] || MAKER_MODEL=$(meta_value "$META" model)
  [ -n "$MODE" ] || MODE=$(meta_value "$META" mode)
  [ -n "$PR" ] || PR=$(meta_value "$META" pr)
  WT=$(meta_value "$META" worktree)
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if [ -z "$BRANCH" ]; then
      BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      [ "$BRANCH" != HEAD ] || BRANCH=''
    fi
    # The head is derived from the same place as the branch, and for the same
    # reason: a live task still has its worktree, so leaving the head unread
    # would make the attestation predicate permanently could-not-observe on
    # every signable route - a predicate nothing can ever satisfy is not a
    # gate, it is a certification command that can only ever refuse.
    [ -n "$HEAD" ] || HEAD=$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)
  fi
fi

[ -n "$REPO" ] || die "nothing to certify: give a task id or --repo"

# --- route derivation ---------------------------------------------------------
#
# The route is read from what the work actually did, never declared by a caller.

# Echo fork-landing when this repository pushes somewhere other than where it
# fetches, which is the shape whose landing branch is deliberately unsigned.
# Echoes nothing when the repository cannot be read: an unreadable route is not a
# route that excuses a predicate.
derive_landing_route() {
  local fetch push
  [ -d "$REPO" ] || return 0
  fetch=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
  push=$(git -C "$REPO" remote get-url --push origin 2>/dev/null || true)
  [ -n "$fetch" ] && [ -n "$push" ] || return 0
  [ "$fetch" != "$push" ] || return 0
  printf 'fork-landing'
}

LANDING_ROUTE=$(derive_landing_route)

# --- predicate evaluation -----------------------------------------------------
#
# Each predicate contributes one row: name, result, and reason. A result is one
# of the three observation values, or the applicability value not-applicable,
# which carries the route that caused it.

ROWS=''

add_row() {  # <predicate> <result> <reason> [route]
  ROWS="$ROWS$1	$2	$3	${4:-}
"
}

# The per-step identity behind the verdict, captured at invocation time. Kept
# beside the verdict so a reader can see WHICH steps were agent-backed and who
# ran each one, rather than only the run-level summary derived from them.
#
# Loaded in THIS shell rather than through a command substitution, so the
# derivation below inherits the block and the pipeline is read once.
fm_independence_steps_load "$REPO" "$BRANCH" || true
STEPS=$FM_INDEPENDENCE_STEPS_VAL

# INDEPENDENCE. Always applicable.
IND=$(fm_independence_dimensions "$REPO" "$BRANCH" "$MAKER_HARNESS" "$MAKER_MODEL")
IND_RESULT=$(fm_independence_overall "$IND")
IND_GAPS=$(fm_independence_gaps "$IND" | paste -sd, - 2>/dev/null || true)
case "$IND_RESULT" in
  PASS) add_row independence PASS "the checker was independent of the maker on every dimension" ;;
  FAIL) add_row independence FAIL "the checker was not independent of the maker: ${IND_GAPS:-unknown}" ;;
  *) add_row independence NO_VERIFIER_RAN "independence could not be established: ${IND_GAPS:-unknown}" ;;
esac

# ATTESTATION. Not applicable on the fork-landing route.
if [ "$LANDING_ROUTE" = fork-landing ]; then
  add_row attestation NOT_APPLICABLE \
    "this route lands on a fork, whose branch is deliberately unsigned because signing it would duplicate a live contribution" \
    fork-landing
elif [ -z "$HEAD" ]; then
  add_row attestation NO_VERIFIER_RAN "no landed head was given, so no attestation could be read for those bytes"
else
  ATTEST=${FM_CERTIFY_ATTEST:-$SCRIPT_DIR/fm-attest.sh}
  if [ ! -x "$ATTEST" ]; then
    add_row attestation NO_VERIFIER_RAN "the attestation verifier is not executable at $ATTEST"
  else
    # A repository that cannot be entered reached NO VERDICT. Letting the failed
    # cd fall through would hand its exit 1 to the refusal arm below and report
    # an observed refusal, with the verifier's empty output as its reason - a
    # could-not-observe wearing the words of an observation, which is the one
    # collapse this command exists to refuse. The attest owner reserves exit 2
    # for exactly this, so the miss is raised in its vocabulary.
    ATTEST_OUT=$(
      (
        cd "$REPO" 2>/dev/null || {
          printf 'the repository at %s could not be entered\n' "$REPO"
          exit 2
        }
        "$ATTEST" verify --head "$HEAD" 2>&1
      )
    ) && ATTEST_RC=0 || ATTEST_RC=$?
    case "$ATTEST_RC" in
      0) add_row attestation PASS "a head-bound attestation covers $HEAD" ;;
      1) add_row attestation FAIL "the attestation for $HEAD was refused: $(printf '%s' "$ATTEST_OUT" | head -1)" ;;
      # The attest owner reserves exit 2 for "no verdict was reached", which is
      # could-not-observe and must never be read as either verdict.
      *) add_row attestation NO_VERIFIER_RAN "no attestation verdict was reached for $HEAD: $(printf '%s' "$ATTEST_OUT" | head -1)" ;;
    esac
  fi
fi

# PR CHECKS. Not applicable on the local-only route, which has no pull request.
if [ "$MODE" = local-only ]; then
  add_row pr-checks NOT_APPLICABLE \
    "this route lands locally and opens no pull request, so no check rollup exists to read" \
    local-only
elif [ -z "$PR" ]; then
  add_row pr-checks NO_VERIFIER_RAN "no pull request was recorded, so no check rollup could be read"
else
  PRV=${FM_CERTIFY_PR_VERIFIER:-$SCRIPT_DIR/fm-verify.sh}
  if [ ! -x "$PRV" ]; then
    add_row pr-checks NO_VERIFIER_RAN "the pull-request verifier is not executable at $PRV"
  else
    PR_OUT=$("$PRV" pr-checks "$PR" 2>&1) && PR_RC=0 || PR_RC=$?
    case "$PR_RC" in
      0) add_row pr-checks PASS "the check rollup passed on the recorded pull request head" ;;
      1) add_row pr-checks FAIL "the check rollup did not pass: $(printf '%s' "$PR_OUT" | sed -n 's/^  //p' | head -1)" ;;
      *) add_row pr-checks NO_VERIFIER_RAN "no check verdict was reached: $(printf '%s' "$PR_OUT" | sed -n 's/^  //p' | head -1)" ;;
    esac
  fi
fi

# --- fold ---------------------------------------------------------------------
#
# Certification is over the APPLICABLE predicates. A not-applicable predicate is
# neither satisfied nor missing, so it moves the verdict in no direction at all -
# but it is still printed, because a route that certifies less has to say so.

CERT_STATE=$STATE_CERTIFIED
CERT_EXIT=$EXIT_CERTIFIED
GAPS=''
NOT_APPLICABLE=''

while IFS='	' read -r name result reason route; do
  [ -n "$name" ] || continue
  case "$result" in
    PASS) continue ;;
    # Carried WITH the route that caused it, and never silently dropped: a
    # route that can certify less has to say so wherever the state word goes.
    NOT_APPLICABLE)
      NOT_APPLICABLE="${NOT_APPLICABLE:+$NOT_APPLICABLE,}$name(${route:-unknown-route})"
      continue
      ;;
    # "unmet" is the predicate-neutral word: only independence has dimensions,
    # and an attestation or a check rollup that failed did not fail by being
    # dependent. The independence rewrite below supplies the dimension detail.
    FAIL)
      GAPS="${GAPS:+$GAPS,}$name:unmet"
      CERT_STATE=$STATE_GAP
      [ "$CERT_EXIT" = "$EXIT_UNOBSERVED" ] || CERT_EXIT=$EXIT_UNMET
      ;;
    *)
      GAPS="${GAPS:+$GAPS,}$name:could-not-observe"
      CERT_STATE=$STATE_GAP
      # Could-not-observe dominates: a run holding both an observed failure and
      # an unobservable predicate is not merely failing, it is unmeasured.
      CERT_EXIT=$EXIT_UNOBSERVED
      ;;
  esac
done <<EOF
$ROWS
EOF

# A FAIL on independence is reported by its own dimensions rather than by the
# generic word, so the gap names WHICH dimension could not be established.
case "$GAPS" in
  *independence:*)
    GAPS=$(printf '%s' "$GAPS" | sed "s|independence:[a-z-]*|independence(${IND_GAPS:-unknown})|")
    ;;
esac

# --- render -------------------------------------------------------------------

if [ "$MODE_OUT" = json ]; then
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$ROWS" | jq -R -s --arg schema "$SCHEMA" --arg state "$CERT_STATE" \
      --arg gaps "$GAPS" --arg na "$NOT_APPLICABLE" --arg branch "$BRANCH" \
      --arg route "${LANDING_ROUTE:-direct}" --arg dims "$IND" --arg steps "$STEPS" '
      {schema: $schema,
       state: $state,
       gap: (if $gaps == "" then null else $gaps end),
       not_applicable: (if $na == "" then [] else ($na | split(",")) end),
       branch: (if $branch == "" then null else $branch end),
       landing_route: $route,
       predicates: [ split("\n")[] | select(length > 0) | split("\t")
                     | {predicate: .[0], result: .[1], reason: .[2],
                        route: (if (.[3] // "") == "" then null else .[3] end)} ],
       independence: [ $dims | split("\n")[] | select(startswith("  independence-"))
                       | ltrimstr("  independence-") | split(",")
                       | {dimension: .[0], result: .[1], reason: .[2]} ],
       steps: [ $steps | split("\n")[] | select(length > 0) | split("\t")
                | {step: .[0], round: .[1], purpose: .[2], agent: .[3],
                   vendor: (if (.[4] // "") == "" then null else .[4] end),
                   model: (if (.[5] // "") == "" then null else .[5] end),
                   exit_status: .[6]} ]}'
  else
    printf '{"schema":"%s","state":"%s","error":"jq is required for --json"}\n' "$SCHEMA" "$CERT_STATE"
  fi
else
  # The not-applicable list travels ON the state line. Quoting the state word
  # alone must not be able to overstate what this route actually certified.
  printf '%s state=%s' "$SCHEMA" "$CERT_STATE"
  [ -z "$NOT_APPLICABLE" ] || printf ' not_applicable=%s' "$NOT_APPLICABLE"
  printf '\n'
  printf '%s' "$ROWS" | while IFS='	' read -r name result reason route; do
    [ -n "$name" ] || continue
    case "$result" in
      PASS) label=satisfied ;;
      FAIL) label=unmet ;;
      NOT_APPLICABLE) label="not-applicable" ;;
      *) label="could-not-observe" ;;
    esac
    printf '  %-14s %-18s %s\n' "$name" "$label" "$reason"
    [ -z "$route" ] || printf '  %-14s %-18s route=%s\n' '' '' "$route"
  done
  # bin/fm-independence-lib.sh owns the result-to-word mapping; it is passed in
  # rather than restated, so this renderer cannot drift into a fourth word for a
  # value the library already named.
  printf '%s\n' "$IND" | awk -F, \
    -v pass="$(fm_independence_label PASS)" \
    -v fail="$(fm_independence_label FAIL)" \
    -v unobserved="$(fm_independence_label NO_VERIFIER_RAN)" '
    /^  independence-/ {
      dim = $1
      sub(/^  independence-/, "", dim)
      if (dim == "overall") next
      label = ($2 == "PASS" ? pass : ($2 == "FAIL" ? fail : unobserved))
      printf "  %-14s %-18s %s\n", "  " dim, label, $3
    }'
  [ -z "$GAPS" ] || printf 'gap=%s\n' "$GAPS"
fi

exit "$CERT_EXIT"
