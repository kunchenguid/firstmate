#!/usr/bin/env bash
# tests/fm-sol-ruling-double.sh - deterministic stand-in for the external
# reasoning channel a Ruling Request is sent to.
#
# The live browser channel is not usable from a shell (there is no browser
# transport in the fleet and its snapshot path fails while exiting 0), so the
# response side of the contract is covered by this double instead. It is
# deliberately dumb: it reads the request, echoes back the ids and baseline it
# should agree with, and then applies exactly one named perturbation. There is
# no network, no randomness and no clock dependence, so a rejection a test sees
# here is a property of bin/fm-ruling-request.sh's validation and nothing else.
#
# Not named *.test.sh on purpose: bin/fm-test-run.sh selects tests/*.test.sh, so
# this fixture is never scheduled as a test of its own.
#
# Usage: fm-sol-ruling-double.sh <mode> <request-file>   response on stdout
#
# Modes:
#   valid                     a well-formed response that should be accepted
#   operator-reserved         valid, but answers with operator-reserved authority
#   id-mismatch               answers a different request id
#   session-mismatch          answers a different away session
#   stale-baseline            bound to a superseded commit
#   authority-expansion       answers an operator-reserved request as delegated
#   action-outside-boundary   recommends an action the request never authorized
#   waiver                    tries to waive one of the request's invariants
#   unverifiable-precondition names a precondition firstmate cannot check
#   unavailable-verification  names a verification the request does not offer
#   shell-injection           hides a command substitution in the action field
#   malformed-unknown-key     carries a key outside the response schema
#   malformed-missing-field   omits a required field
#   malformed-structure       emits a line that is not <key><tab><value>
set -u

MODE=${1:-}
REQUEST=${2:-}

[ -n "$MODE" ] && [ -f "$REQUEST" ] || {
  printf 'usage: fm-sol-ruling-double.sh <mode> <request-file>\n' >&2
  exit 2
}

field() {  # <key>
  awk -F '\t' -v k="$1" '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }' "$REQUEST"
}
REQ_ID=$(field request)
SESSION=$(field session)
BASELINE=$(field baseline)
ACTION=$(field authorized-action)
VERIFICATION=$(field available-verification)
PRECONDITION=$(field verifiable-precondition)
INVARIANT=$(field invariant)
AUTHORITY=delegated

case "$MODE" in
  id-mismatch) REQ_ID="rr-some-other-decision" ;;
  session-mismatch) SESSION="away-0000000000" ;;
  stale-baseline) BASELINE="${BASELINE%@*}@0000000000000000000000000000000000000000" ;;
  authority-expansion) AUTHORITY=delegated ;;
  operator-reserved) AUTHORITY=operator-reserved ;;
  action-outside-boundary) ACTION="rewrite-the-authorization-matrix" ;;
  unverifiable-precondition) PRECONDITION="trust that the module owner agrees" ;;
  unavailable-verification) VERIFICATION="run the full release suite on staging" ;;
  shell-injection) ACTION='adopt-builder; touch /tmp/fm-ruling-double-executed' ;;
esac

emit_common() {
  printf 'request\t%s\n' "$REQ_ID"
  printf 'session\t%s\n' "$SESSION"
  printf 'baseline\t%s\n' "$BASELINE"
  printf 'disposition\tAdopt the recommendation as written.\n'
  printf 'action\t%s\n' "$ACTION"
  printf 'rationale\tThe recommendation matches the cited module boundary and is reversible.\n'
  printf 'opposing\tThe simpler alternative would be easier to read at the two call sites.\n'
  printf 'verification\t%s\n' "$VERIFICATION"
  printf 'residual-uncertainty\tThe benchmark named as a falsifier has not been run.\n'
  printf 'authority\t%s\n' "$AUTHORITY"
  printf 'precondition\t%s\n' "$PRECONDITION"
  printf 'invalidator\tThe module is refactored before the change lands.\n'
}

case "$MODE" in
  malformed-unknown-key)
    emit_common
    printf 'certification\tthis advice certifies the change\n'
    ;;
  malformed-missing-field)
    emit_common | grep -v '^rationale	'
    ;;
  malformed-structure)
    emit_common
    printf 'this line has no tab separator\n'
    ;;
  waiver)
    emit_common
    printf 'waives\t%s\n' "${INVARIANT:-an invariant}"
    ;;
  *)
    emit_common
    ;;
esac
