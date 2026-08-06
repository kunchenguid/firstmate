#!/usr/bin/env bash
# fm-verify-lib.sh - single owner of firstmate's three-valued observation type
# and of the check-set classification rule that depends on it.
#
# Source it; it defines and runs nothing on its own:
#   # shellcheck source=bin/fm-verify-lib.sh
#   . "$SCRIPT_DIR/fm-verify-lib.sh"
#
# THE TYPE RULE
#
# An observation returns three values, never two:
#   PASS             observed, and the subject is good
#   FAIL             observed, and the subject is bad
#   NO_VERIFIER_RAN  the observation did not happen
#
# The measured root cause of ten separate defects in this fleet was one type
# error: a function that can fail to OBSERVE returning the same type as one that
# observed a NEGATIVE result. "I looked and found nothing" and "I could not
# look" collapse into one value - empty, zero, false, absent - and that value
# then reads as fine.
#
# The third value never dies by being forgotten. It dies at a conversion: an
# exit code narrowing, an empty collection counting as zero failures, an
# unreadable file counting as no findings, a missing check set counting as a
# clean one. So this library gives consumers exactly one way to read a result -
# fm_verify_case, which refuses a consumer that does not handle all three - and
# exactly one way to narrow it - fm_verify_coerce, which is loud and logged.
#
# A caller who wants a two-branch read has to say so in writing, and the saying
# is the record.
#
# FM_VERIFY_CHECK_ROLLUP_EXPR is a jq expression evaluated against ONE pull
# request object carrying GitHub's statusCheckRollup field. It produces exactly
# one of:
#
#   none          no check ran at all - the empty set. NOT green, ever. A pull
#                 request whose checks were never created, whose workflow file
#                 is broken, or whose runs were pruned looks exactly like a
#                 pull request that passed, unless the empty set is named
#                 separately.
#   failing       at least one check reached a terminal negative verdict:
#                 FAILURE, STARTUP_FAILURE, or ERROR. A workflow that failed to
#                 start never clears by waiting and re-running reproduces it
#                 until someone fixes the workflow, so it is a verdict and not
#                 a could-not-observe.
#   pending       checks exist but at least one has not completed. No verdict
#                 yet, and one may still arrive.
#   inconclusive  every check completed, none failed, and at least one ended
#                 without earning a verdict - TIMED_OUT, CANCELLED,
#                 ACTION_REQUIRED, SKIPPED, STALE, NEUTRAL, an absent
#                 conclusion, or any conclusion this rule does not know, which
#                 reaches this label by design rather than by omission. None of
#                 them observed the pull request: a run cancelled by a
#                 superseding push or killed by a timeout says nothing about
#                 the code, and ACTION_REQUIRED completed only to say a human
#                 must act. Folding any of them into "passing" is the empty
#                 set's defect one level down, and folding them into "failing"
#                 asserts a verdict nothing earned. No verdict, and none is
#                 coming.
#   passing       the set is non-empty and EVERY member completed successfully.
#
# Two GitHub vocabularies meet here, which is why the rule reads
# .conclusion // .state: FAILURE, TIMED_OUT, CANCELLED, ACTION_REQUIRED,
# STARTUP_FAILURE, NEUTRAL, SKIPPED, STALE and SUCCESS are check-run
# conclusions, while ERROR belongs to the older commit-status state vocabulary.
#
# It lives here rather than inside either caller because it is a contract, and
# two copies of a contract drift the moment only one is edited. Consumers map
# these five labels onto their own vocabulary and must never collapse "none",
# "pending", or "inconclusive" into a pass:
#   - bin/fm-verify.sh maps none/pending/inconclusive to NO_VERIFIER_RAN and
#     passing to PASS.
#   - bin/fm-bearings-snapshot.sh renders them as a per-pull-request label.
#
# The expression takes no jq arguments, so a caller splices it into a larger
# single-quoted program without disturbing that program's own jq variables.

# shellcheck disable=SC2034,SC2016  # consumed by sourcing scripts, not by this
# file, and the $-prefixed names inside are jq variables that must reach jq
# unexpanded - the single quotes are the point.
FM_VERIFY_CHECK_ROLLUP_EXPR='
  (.statusCheckRollup // []) as $c
  | if ($c|length) == 0 then "none"
    elif any($c[]; (.conclusion // .state // "") as $s | ($s=="FAILURE" or $s=="STARTUP_FAILURE" or $s=="ERROR")) then "failing"
    elif any($c[]; ((.status // "") != "COMPLETED") and ((.state // "") != "SUCCESS")) then "pending"
    elif all($c[]; (.conclusion // .state // "") == "SUCCESS") then "passing"
    else "inconclusive" end'

# --- the three-valued observation type --------------------------------------

# fm_verify_parse <record>: read one bin/fm-verify.sh record and export its
# fields as FM_VERIFY_VERIFIER / FM_VERIFY_RESULT / FM_VERIFY_REASON /
# FM_VERIFY_EVIDENCE. Returns non-zero for anything it cannot parse, and leaves
# no partially-populated fields behind: an unparseable record is itself a
# could-not-observe, and a consumer that treated it as an empty PASS would be
# the very defect this file exists to prevent.
fm_verify_parse() {
  local record=$1 row rest verifier result reason evidence
  FM_VERIFY_VERIFIER=''
  FM_VERIFY_RESULT=''
  FM_VERIFY_REASON=''
  FM_VERIFY_EVIDENCE=''
  row=$(printf '%s\n' "$record" | sed -n 's/^  //p' | head -1)
  [ -n "$row" ] || return 1
  verifier=${row%%,*}
  rest=${row#*,}
  [ "$rest" != "$row" ] || return 1
  result=${rest%%,*}
  rest=${rest#*,}
  reason=${rest%%,*}
  rest=${rest#*,}
  evidence=$rest
  case "$result" in
    PASS|FAIL|NO_VERIFIER_RAN) ;;
    *) return 1 ;;
  esac
  [ -n "$verifier" ] && [ -n "$reason" ] || return 1
  # Published only once every field has been accepted: a record rejected on its
  # last field must leave nothing behind either, or a consumer reading the
  # globals without the status still sees a result extracted from a record this
  # function just refused.
  FM_VERIFY_VERIFIER=$verifier
  FM_VERIFY_RESULT=$result
  FM_VERIFY_REASON=$reason
  FM_VERIFY_EVIDENCE=$evidence
  return 0
}

# fm_verify_case <record> <on_pass> <on_fail> <on_unverified>: the only
# supported way to consume a result. Each handler is the name of a defined
# function and is called with no arguments; the parsed fields are available to
# it as the FM_VERIFY_* variables above.
#
# It refuses, with a stable token on stderr and status 3, when:
#   - fewer or more than three handlers are named (consumer exhaustiveness: a
#     consumer that branches on pass-versus-not-pass reintroduces the defect
#     against a perfectly correct producer);
#   - a named handler is not a defined function;
#   - the unverified handler is the same function as the pass or fail handler,
#     which is coercion written as a consumer. Use fm_verify_coerce for that,
#     where it is recorded.
# An unparseable record is reported the same way rather than dropped.
fm_verify_case() {
  local record=${1:-} on_pass=${2:-} on_fail=${3:-} on_unverified=${4:-} handler
  if [ "$#" -ne 4 ]; then
    printf 'fm-verify: consumer must handle all three results\n' >&2
    return 3
  fi
  for handler in "$on_pass" "$on_fail" "$on_unverified"; do
    if ! declare -F "$handler" >/dev/null 2>&1; then
      printf 'fm-verify: consumer must handle all three results\n' >&2
      return 3
    fi
  done
  if [ "$on_unverified" = "$on_pass" ] || [ "$on_unverified" = "$on_fail" ]; then
    printf 'fm-verify: NO_VERIFIER_RAN is not coercible; use fm_verify_coerce\n' >&2
    return 3
  fi
  if ! fm_verify_parse "$record"; then
    printf 'fm-verify: unreadable result record\n' >&2
    return 3
  fi
  case "$FM_VERIFY_RESULT" in
    PASS) "$on_pass" ;;
    FAIL) "$on_fail" ;;
    *) "$on_unverified" ;;
  esac
}

# fm_verify_coerce <record> <PASS|FAIL> <reason>: the one sanctioned narrowing
# of NO_VERIFIER_RAN, for the case where a caller genuinely decides to proceed
# without the observation. It prints the coerced result on stdout and writes the
# decision to stderr always, plus FM_VERIFY_COERCION_LOG or
# $FM_HOME/state/verify-coercions.log when either is writable. A coercion with
# no reason, or of an already-observed result, is refused: only the missing
# observation is a decision anyone gets to make.
fm_verify_coerce() {
  local record=${1:-} target=${2:-} reason=${3:-} log=
  if [ "$#" -ne 3 ] || [ -z "$reason" ]; then
    printf 'fm-verify: coercion needs a target and a reason\n' >&2
    return 3
  fi
  case "$target" in
    PASS|FAIL) ;;
    *)
      printf 'fm-verify: coercion target must be PASS or FAIL\n' >&2
      return 3
      ;;
  esac
  if ! fm_verify_parse "$record"; then
    printf 'fm-verify: unreadable result record\n' >&2
    return 3
  fi
  if [ "$FM_VERIFY_RESULT" != NO_VERIFIER_RAN ]; then
    printf 'fm-verify: only NO_VERIFIER_RAN is coercible\n' >&2
    return 3
  fi
  printf 'fm-verify: COERCED %s -> %s (%s): %s reason=%s evidence=%s\n' \
    NO_VERIFIER_RAN "$target" "$reason" "$FM_VERIFY_VERIFIER" \
    "$FM_VERIFY_REASON" "$FM_VERIFY_EVIDENCE" >&2
  if [ -n "${FM_VERIFY_COERCION_LOG:-}" ]; then
    log=$FM_VERIFY_COERCION_LOG
  elif [ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME/state" ] && [ -w "$FM_HOME/state" ]; then
    log=$FM_HOME/state/verify-coercions.log
  fi
  if [ -n "$log" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$FM_VERIFY_VERIFIER" "$target" "$FM_VERIFY_REASON" \
      "$FM_VERIFY_EVIDENCE" "$reason" >>"$log" 2>/dev/null || true
  fi
  FM_VERIFY_RESULT=$target
  printf '%s\n' "$target"
}
