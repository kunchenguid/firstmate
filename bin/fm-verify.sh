#!/usr/bin/env bash
# fm-verify.sh - run a declared verifier and return a three-valued result, so
# that no verifier's silence, error, or absent result can be read as a pass.
#
# Exit status alone cannot carry a verification result, because it cannot
# distinguish "the verifier ran and reached a verdict" from "the verifier never
# reached one". Three real instances in this fleet:
#   - an empty GitHub check-run set read as green, because zero failing checks
#     looks exactly like all checks passing;
#   - chrome-devtools-axi printing "Protocol error (Target.setDiscoverTargets):
#     Target closed" and exiting 0, so a caller branching on exit status
#     concludes the page is fine;
#   - git merge-tree exiting 1 both for a real conflict and for a ref it cannot
#     resolve, so one exit status covers a verdict and a non-verdict.
#
# Usage:
#   fm-verify.sh [--evidence <path>] <verifier> [args...]
#   fm-verify.sh --list
#   fm-verify.sh -h | --help
#
# Options:
#   --evidence <path>  write the verifier's captured output here instead of a
#                      generated temporary file. The path must contain no comma
#                      and no newline, because it is a field of the emitted
#                      record.
#
# Declared verifiers (the registry is closed; an undeclared name is refused
# rather than run, because a name this script cannot interpret is a name whose
# output it cannot judge):
#   browser <subcommand> [args...]
#       Runs chrome-devtools-axi with the given arguments. This adapter never
#       returns FAIL, and that is deliberate rather than an omission:
#       chrome-devtools-axi is a control tool, not an assertion tool, so it has
#       no way to report "the page is bad" - only "here is what I saw" or a
#       failure to see it. The verdict on what it saw belongs to the caller.
#   pr-checks <pr-url>
#       Reads the pull request's check-run set through gh and classifies it with
#       bin/fm-verify-lib.sh.
#   merge-clean <base-ref> <head-ref> [repo-dir]
#       Runs git merge-tree --write-tree in <repo-dir> (default: the current
#       directory).
#
# Output is exactly one record on stdout, in every case:
#
#   verify[1]{verifier,result,reason,evidence_ref}:
#     browser,NO_VERIFIER_RAN,verification_unreachable,/tmp/fm-verify-browser.abc123.log
#
# result is one of:
#   PASS            the verifier ran, reached a verdict, and the verdict is good
#   FAIL            the verifier ran and reached a verdict, and it is bad
#   NO_VERIFIER_RAN no verdict was reached. Never a pass, never a failure of the
#                   subject, and never skippable.
#
# reason is one of this closed vocabulary:
#   verified                  PASS
#   verifier_reported_failure FAIL
#   verifier_undeclared       the verifier name is not in the registry
#   verifier_unavailable      the underlying tool is not installed
#   verification_unreachable  the verifier ran but could not reach its subject
#                             (ruling D3's token for the unreachable browser)
#   empty_result_set          the verifier returned no results at all
#   verification_incomplete   results exist but no verdict has been reached yet
#   no_verdict_reached        the verifier finished and reached no verdict, and
#                             none is coming: checks that completed SKIPPED,
#                             STALE, NEUTRAL, or with no conclusion at all
#   no_evidence               the verifier's output could not be captured
#   usage_error               the call itself was malformed
#
# Exit status: 0 for PASS and ONLY for PASS; 1 for FAIL; 2 for NO_VERIFIER_RAN.
# That mapping is the enforcement, not a convenience: a caller writing
# `if fm-verify.sh ...; then` gets the fail-closed answer by construction, so
# NO_VERIFIER_RAN cannot reach a pass terminal even in a caller that reads
# nothing but the status.
#
# TOOLING_GAP - chrome-devtools-axi reports transport failures on stdout while
# exiting 0. Until it exits non-zero, the browser adapter has to recognize those
# failures by their text, and the signature list below is deliberately biased:
# a false NO_VERIFIER_RAN costs one re-run, a false PASS is the defect this
# script exists to prevent. The durable fix belongs upstream in that tool, not
# in a longer list here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-verify-lib.sh
. "$SCRIPT_DIR/fm-verify-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

VERIFIERS=(browser pr-checks merge-clean)

RESULT=
REASON=
EVIDENCE=-
VERIFIER=-

set_result() {
  RESULT=$1
  REASON=$2
}

emit_and_exit() {
  printf 'verify[1]{verifier,result,reason,evidence_ref}:\n  %s,%s,%s,%s\n' \
    "$VERIFIER" "$RESULT" "$REASON" "$EVIDENCE"
  case "$RESULT" in
    PASS) exit 0 ;;
    FAIL) exit 1 ;;
    *) exit 2 ;;
  esac
}

# A refusal is still a result, so it goes out through the same record.
refuse() {
  VERIFIER=${VERIFIER:--}
  set_result NO_VERIFIER_RAN "$1"
  emit_and_exit
}

EVIDENCE_PATH=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --list)
      printf '%s\n' "${VERIFIERS[@]}"
      exit 0
      ;;
    --evidence)
      [ "$#" -ge 2 ] || refuse usage_error
      EVIDENCE_PATH=$2
      shift 2
      ;;
    --evidence=*)
      EVIDENCE_PATH=${1#--evidence=}
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      refuse usage_error
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -ge 1 ] || refuse usage_error
VERIFIER=$1
shift

# The registry closes before anything runs. A name this script cannot interpret
# is a name whose output it cannot judge, so it is refused rather than executed.
declared=1
for known in "${VERIFIERS[@]}"; do
  [ "$VERIFIER" = "$known" ] && declared=0 && break
done
[ "$declared" -eq 0 ] || refuse verifier_undeclared

if [ -n "$EVIDENCE_PATH" ]; then
  case "$EVIDENCE_PATH" in
    *,*) refuse usage_error ;;
  esac
  [[ $EVIDENCE_PATH != *$'\n'* ]] || refuse usage_error
fi

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-verify.XXXXXX") || refuse no_evidence
# shellcheck disable=SC2329  # invoked by the EXIT trap below.
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

if [ -n "$EVIDENCE_PATH" ]; then
  EVIDENCE=$EVIDENCE_PATH
else
  EVIDENCE=$(mktemp "${TMPDIR:-/tmp}/fm-verify-$VERIFIER.XXXXXX") || refuse no_evidence
fi
: > "$EVIDENCE" 2>/dev/null || refuse no_evidence

VERIFIER_STATUS=0
VERIFIER_OUT=
VERIFIER_ALL=

# run_verifier <command...>: run the command, capture its streams into the
# evidence file, and leave the status and stdout available for the adapter.
# Evidence is written before any judgement so that every result - including a
# refusal - points at what was actually observed.
run_verifier() {
  "$@" >"$WORKDIR/stdout" 2>"$WORKDIR/stderr"
  VERIFIER_STATUS=$?
  {
    printf 'fm-verify evidence\nverifier: %s\ncommand:' "$VERIFIER"
    printf ' %q' "$@"
    printf '\nexit_status: %s\n--- stdout ---\n' "$VERIFIER_STATUS"
    cat "$WORKDIR/stdout"
    printf -- '--- stderr ---\n'
    cat "$WORKDIR/stderr"
  } >>"$EVIDENCE" 2>/dev/null || return 1
  VERIFIER_OUT=$(cat "$WORKDIR/stdout")
  VERIFIER_ALL=$(cat "$WORKDIR/stdout" "$WORKDIR/stderr")
  return 0
}

# require_tool <name>: one availability guard for every adapter, so that a
# missing tool always reports the same reason and a new adapter cannot get the
# token wrong. Used as `require_tool <name> || return 0`.
require_tool() {
  command -v "$1" >/dev/null 2>&1 && return 0
  set_result NO_VERIFIER_RAN verifier_unavailable
  return 1
}

# --- browser ----------------------------------------------------------------

# Transport failures chrome-devtools-axi reports while exiting 0. See the
# TOOLING_GAP note in this file's header.
BROWSER_UNREACHABLE_SIGNATURES='protocol error
target closed
target.setdiscovertargets
no active session
econnrefused
could not connect
failed to connect
cannot connect to
browser not found
chrome not found
session not found'

output_is_unreachable() {
  local haystack signature
  haystack=$(printf '%s' "$VERIFIER_ALL" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r signature; do
    [ -n "$signature" ] || continue
    case "$haystack" in
      *"$signature"*) return 0 ;;
    esac
  done <<EOF
$BROWSER_UNREACHABLE_SIGNATURES
EOF
  return 1
}

verify_browser() {
  [ "$#" -ge 1 ] || refuse usage_error
  require_tool chrome-devtools-axi || return 0
  run_verifier chrome-devtools-axi "$@" || {
    set_result NO_VERIFIER_RAN no_evidence
    return 0
  }
  # Order matters: the transport check runs BEFORE the status check, because
  # the whole defect is a transport failure carrying a successful status.
  if output_is_unreachable; then
    set_result NO_VERIFIER_RAN verification_unreachable
    return 0
  fi
  # A non-zero exit for a reason no signature names - a chrome crash, a
  # page-load timeout, a DNS failure - is could-not-observe, the same as the
  # unreachable forge in verify_pr_checks below. chrome-devtools-axi is a
  # control tool, not an assertion tool, so it has no failing page to report:
  # calling this FAIL would assert a verdict the evidence never earned and
  # would hide a broken verifier among real failures.
  if [ "$VERIFIER_STATUS" -ne 0 ]; then
    set_result NO_VERIFIER_RAN verification_unreachable
    return 0
  fi
  if [ -z "$VERIFIER_ALL" ]; then
    set_result NO_VERIFIER_RAN empty_result_set
    return 0
  fi
  set_result PASS verified
}

# --- pr-checks --------------------------------------------------------------

verify_pr_checks() {
  local label
  [ "$#" -eq 1 ] || refuse usage_error
  require_tool gh || return 0
  require_tool jq || return 0
  run_verifier gh pr view "$1" --json statusCheckRollup || {
    set_result NO_VERIFIER_RAN no_evidence
    return 0
  }
  # An unreachable forge is not a failing pull request. Reporting FAIL here
  # would be a verdict this script never earned.
  if [ "$VERIFIER_STATUS" -ne 0 ]; then
    set_result NO_VERIFIER_RAN verification_unreachable
    return 0
  fi
  label=$(printf '%s' "$VERIFIER_OUT" | jq -r "$FM_VERIFY_CHECK_ROLLUP_EXPR" 2>/dev/null) || label=
  case "$label" in
    passing) set_result PASS verified ;;
    failing) set_result FAIL verifier_reported_failure ;;
    pending) set_result NO_VERIFIER_RAN verification_incomplete ;;
    inconclusive) set_result NO_VERIFIER_RAN no_verdict_reached ;;
    none) set_result NO_VERIFIER_RAN empty_result_set ;;
    *) set_result NO_VERIFIER_RAN verification_unreachable ;;
  esac
}

# --- merge-clean ------------------------------------------------------------

# git merge-tree --write-tree exits 1 for a conflict AND for a ref it cannot
# resolve. The tree object it writes on the conflict path is what separates
# them: a conflict is a verdict about the merge, an unresolvable ref is no
# verdict at all.
verify_merge_clean() {
  local repo first
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || refuse usage_error
  repo=${3:-.}
  require_tool git || return 0
  run_verifier git -C "$repo" merge-tree --write-tree "$1" "$2" || {
    set_result NO_VERIFIER_RAN no_evidence
    return 0
  }
  first=$(printf '%s\n' "$VERIFIER_OUT" | head -1)
  case "$first" in
    *[!0-9a-f]*) first= ;;
  esac
  # A full object name, not an abbreviation: git resolves short names, and this
  # check exists to prove merge-tree wrote a tree rather than printed a message.
  [ "${#first}" -eq 40 ] || [ "${#first}" -eq 64 ] || first=
  if [ -z "$first" ] || [ "$(git -C "$repo" cat-file -t "$first" 2>/dev/null)" != tree ]; then
    set_result NO_VERIFIER_RAN verification_unreachable
    return 0
  fi
  if [ "$VERIFIER_STATUS" -eq 0 ]; then
    set_result PASS verified
  else
    set_result FAIL verifier_reported_failure
  fi
}

# --- dispatch ---------------------------------------------------------------

case "$VERIFIER" in
  browser) verify_browser "$@" ;;
  pr-checks) verify_pr_checks "$@" ;;
  merge-clean) verify_merge_clean "$@" ;;
  *) refuse verifier_undeclared ;;
esac

emit_and_exit
