#!/usr/bin/env bash
# fm-route.sh - deterministic subscription routing selection and state transitions.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-routing-lib.sh
. "$SCRIPT_DIR/fm-routing-lib.sh"

usage() { fm_route_diagnostic 'usage: fm-route.sh select|reserve|verify-reservation|reservation-work-type|begin-admission|prepare-admission|commit-admission|abort-admission|recover-admission|release|failure|score|finalize|cleanup-ready|cleanup-finalize|observe|evidence|status|report ...'; exit 2; }
require_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || usage; }
validate_now() { case "$1" in ''|*[!0-9]*) fm_route_diagnostic 'invalid --now: expected non-negative epoch'; return 1 ;; esac; }
validate_terminal() { case "$1" in completed|failed_safe|escalated|cancelled|superseded) ;; *) fm_route_diagnostic 'invalid terminal outcome'; return 1 ;; esac; }
SEEN_OPTIONS=''
claim_option() {
  case " $SEEN_OPTIONS " in *" $1 "*) usage ;; esac
  SEEN_OPTIONS="$SEEN_OPTIONS $1"
}

command=${1:-}
[ -n "$command" ] || usage
shift
case "$command" in
  select)
    REQUEST=''; CANDIDATES=''; NOW=$(date +%s)
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in
      --request) require_value "$@"; [ -z "$REQUEST" ] || usage; REQUEST=$2; shift 2 ;;
      --candidates) require_value "$@"; [ -z "$CANDIDATES" ] || usage; CANDIDATES=$2; shift 2 ;;
      --now) require_value "$@"; NOW=$2; shift 2 ;; *) usage ;; esac; done
    [ -n "$REQUEST" ] && [ -r "$REQUEST" ] || { fm_route_diagnostic 'request file is required and must be readable'; exit 1; }
    [ -n "$CANDIDATES" ] && [ -r "$CANDIDATES" ] || { fm_route_diagnostic 'candidates file is required and must be readable'; exit 1; }
    if fm_route_select_policy_guard; then
      :
    else
      rc=$?
      if [ "$rc" -eq 10 ]; then
        fm_route_static_result
        exit 0
      fi
      exit "$rc"
    fi
    validate_now "$NOW"; fm_route_validate_request "$REQUEST"; fm_route_validate_candidates "$CANDIDATES"; fm_route_select "$REQUEST" "$CANDIDATES"
    ;;
  reserve|verify-reservation)
    TASK=''; GENERATION=''; PROFILE=''; PROVIDER=''; LANE=''; ACCOUNT=''; CLASS=''; WORK_TYPE=''; RISK=''; MODE=''; REQUEST=''; CANDIDATES=''; DECISION=''; NOW=$(date +%s); BURST=false
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in
      --task) require_value "$@"; TASK=$2; shift 2 ;; --generation) require_value "$@"; GENERATION=$2; shift 2 ;;
      --profile) require_value "$@"; PROFILE=$2; shift 2 ;; --provider) require_value "$@"; PROVIDER=$2; shift 2 ;;
      --lane) require_value "$@"; LANE=$2; shift 2 ;; --account) require_value "$@"; ACCOUNT=$2; shift 2 ;;
      --class) require_value "$@"; CLASS=$2; shift 2 ;; --work-type) require_value "$@"; WORK_TYPE=$2; shift 2 ;; --risk) require_value "$@"; RISK=$2; shift 2 ;;
      --mode) require_value "$@"; MODE=$2; shift 2 ;; --now) require_value "$@"; NOW=$2; shift 2 ;;
      --request) [ "$command" = reserve ] || usage; require_value "$@"; REQUEST=$2; shift 2 ;;
      --candidates) [ "$command" = reserve ] || usage; require_value "$@"; CANDIDATES=$2; shift 2 ;;
      --decision) [ "$command" = reserve ] || usage; require_value "$@"; DECISION=$2; shift 2 ;;
      --burst) [ "$command" = reserve ] || usage; BURST=true; shift ;; *) usage ;; esac; done
    if [ "$command" = reserve ]; then
      [ -n "$WORK_TYPE" ] || { fm_route_diagnostic 'work-type is required'; exit 1; }
      fm_route_validate_route_tuple "$TASK" "$GENERATION" "$PROFILE" "$PROVIDER" "$LANE" "$ACCOUNT" "$CLASS" "$WORK_TYPE" "$RISK" "$MODE"
      validate_now "$NOW"
      [ -n "$REQUEST" ] && [ -n "$CANDIDATES" ] && [ -n "$DECISION" ] || { fm_route_diagnostic 'selection evidence is required'; exit 1; }
      fm_route_reserve "$TASK" "$GENERATION" "$PROFILE" "$PROVIDER" "$LANE" "$ACCOUNT" "$CLASS" "$WORK_TYPE" "$RISK" "$MODE" "$BURST" "$NOW" "$REQUEST" "$CANDIDATES" "$DECISION"
    else
      [ -n "$WORK_TYPE" ] || { fm_route_diagnostic 'work-type is required'; exit 1; }
      fm_route_validate_route_tuple "$TASK" "$GENERATION" "$PROFILE" "$PROVIDER" "$LANE" "$ACCOUNT" "$CLASS" "$WORK_TYPE" "$RISK" "$MODE"
      validate_now "$NOW"
      fm_routing_with_lock fm_route_verify_locked "$TASK" "$GENERATION" "$PROFILE" "$PROVIDER" "$LANE" "$ACCOUNT" "$CLASS" "$WORK_TYPE" "$RISK" "$MODE"
    fi
    ;;
  reservation-work-type)
    TASK=''; GENERATION=''; PROFILE=''; PROVIDER=''; LANE=''; ACCOUNT=''; CLASS=''; RISK=''; MODE=''
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in
      --task) require_value "$@"; TASK=$2; shift 2 ;; --generation) require_value "$@"; GENERATION=$2; shift 2 ;;
      --profile) require_value "$@"; PROFILE=$2; shift 2 ;; --provider) require_value "$@"; PROVIDER=$2; shift 2 ;;
      --lane) require_value "$@"; LANE=$2; shift 2 ;; --account) require_value "$@"; ACCOUNT=$2; shift 2 ;;
      --class) require_value "$@"; CLASS=$2; shift 2 ;; --risk) require_value "$@"; RISK=$2; shift 2 ;;
      --mode) require_value "$@"; MODE=$2; shift 2 ;; *) usage ;; esac; done
    # Validate the legacy eight-field shape without guessing its missing work type.
    fm_route_validate_route_tuple "$TASK" "$GENERATION" "$PROFILE" "$PROVIDER" "$LANE" "$ACCOUNT" "$CLASS" implementation "$RISK" "$MODE"
    fm_routing_with_lock fm_route_reservation_work_type_locked "$TASK" "$GENERATION" "$PROFILE" "$PROVIDER" "$LANE" "$ACCOUNT" "$CLASS" "$RISK" "$MODE"
    ;;
  begin-admission)
    TASK=''; GENERATION=''; PROFILE=''; PROVIDER=''; LANE=''; ACCOUNT=''; CLASS=''; WORK_TYPE=''; RISK=''; MODE=''; TRANSITION=''; METADATA_FILE=''; CLAIM_FILE=''; PRIOR_GENERATION=''; PRIOR_CLAIM_FILE=''; LAUNCH_HARNESS=''; LAUNCH_MODEL=''; LAUNCH_EFFORT=''
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in
      --task) require_value "$@"; TASK=$2; shift 2 ;; --generation) require_value "$@"; GENERATION=$2; shift 2 ;;
      --profile) require_value "$@"; PROFILE=$2; shift 2 ;; --provider) require_value "$@"; PROVIDER=$2; shift 2 ;;
      --lane) require_value "$@"; LANE=$2; shift 2 ;; --account) require_value "$@"; ACCOUNT=$2; shift 2 ;;
      --class) require_value "$@"; CLASS=$2; shift 2 ;; --work-type) require_value "$@"; WORK_TYPE=$2; shift 2 ;; --risk) require_value "$@"; RISK=$2; shift 2 ;;
      --mode) require_value "$@"; MODE=$2; shift 2 ;; --transition) require_value "$@"; TRANSITION=$2; shift 2 ;;
      --launch-harness) require_value "$@"; LAUNCH_HARNESS=$2; shift 2 ;; --launch-model) require_value "$@"; LAUNCH_MODEL=$2; shift 2 ;;
      --launch-effort) require_value "$@"; LAUNCH_EFFORT=$2; shift 2 ;;
      --metadata-file) require_value "$@"; METADATA_FILE=$2; shift 2 ;; --claim-file) require_value "$@"; CLAIM_FILE=$2; shift 2 ;;
      --prior-generation) require_value "$@"; PRIOR_GENERATION=$2; shift 2 ;; --prior-claim-file) require_value "$@"; PRIOR_CLAIM_FILE=$2; shift 2 ;;
      *) usage ;;
    esac; done
    fm_route_validate_route_tuple "$TASK" "$GENERATION" "$PROFILE" "$PROVIDER" "$LANE" "$ACCOUNT" "$CLASS" "$WORK_TYPE" "$RISK" "$MODE"
    case "$TRANSITION" in fresh|inherit|replacement|off) ;; *) fm_route_diagnostic 'invalid admission transition'; exit 1 ;; esac
    if [ "$TRANSITION" != off ]; then
      [ -n "$LAUNCH_HARNESS" ] && [ -n "$LAUNCH_MODEL" ] && [ -n "$LAUNCH_EFFORT" ] \
        || { fm_route_diagnostic 'launch binding is required'; exit 1; }
    fi
    OWNER_PID=$PPID
    OWNER_START=$(fm_route_process_start "$OWNER_PID") || { fm_route_diagnostic 'admission owner identity is unavailable'; exit 1; }
    fm_routing_with_lock fm_route_begin_admission_locked "$TASK" "$GENERATION" "$PROFILE" "$PROVIDER" "$LANE" "$ACCOUNT" "$CLASS" "$WORK_TYPE" "$RISK" "$MODE" "$TRANSITION" "$METADATA_FILE" "$CLAIM_FILE" "$OWNER_PID" "$OWNER_START" "$PRIOR_GENERATION" "$PRIOR_CLAIM_FILE" "$LAUNCH_HARNESS" "$LAUNCH_MODEL" "$LAUNCH_EFFORT"
    ;;
  prepare-admission)
    TASK=''; CANDIDATE=''; CLAIM_FILE=''; PRIOR_CLAIM_FILE=''
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in
      --task) require_value "$@"; TASK=$2; shift 2 ;; --candidate) require_value "$@"; CANDIDATE=$2; shift 2 ;;
      --claim-file) require_value "$@"; CLAIM_FILE=$2; shift 2 ;; --prior-claim-file) require_value "$@"; PRIOR_CLAIM_FILE=$2; shift 2 ;;
      *) usage ;;
    esac; done
    fm_route_validate_identifier "$TASK" || { fm_route_diagnostic 'invalid task identifier'; exit 1; }
    OWNER_PID=$PPID
    OWNER_START=$(fm_route_process_start "$OWNER_PID") || { fm_route_diagnostic 'admission owner identity is unavailable'; exit 1; }
    fm_routing_with_lock fm_route_prepare_admission_locked "$TASK" "$CANDIDATE" "$CLAIM_FILE" "$PRIOR_CLAIM_FILE" "$OWNER_PID" "$OWNER_START"
    ;;
  commit-admission|abort-admission)
    TASK=''; CLAIM_FILE=''; PRIOR_CLAIM_FILE=''
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in
      --task) require_value "$@"; TASK=$2; shift 2 ;; --claim-file) require_value "$@"; CLAIM_FILE=$2; shift 2 ;;
      --prior-claim-file) require_value "$@"; PRIOR_CLAIM_FILE=$2; shift 2 ;; *) usage ;;
    esac; done
    fm_route_validate_identifier "$TASK" || { fm_route_diagnostic 'invalid task identifier'; exit 1; }
    OWNER_PID=$PPID
    OWNER_START=$(fm_route_process_start "$OWNER_PID") || { fm_route_diagnostic 'admission owner identity is unavailable'; exit 1; }
    if [ "$command" = commit-admission ]; then
      fm_routing_with_lock fm_route_commit_admission_locked "$TASK" "$CLAIM_FILE" "$PRIOR_CLAIM_FILE" "$OWNER_PID" "$OWNER_START"
    else
      fm_routing_with_lock fm_route_abort_admission_locked "$TASK" "$CLAIM_FILE" "$PRIOR_CLAIM_FILE" "$OWNER_PID" "$OWNER_START"
    fi
    ;;
  recover-admission)
    TASK=''; CLAIM_FILE=''; PRIOR_CLAIM_FILE=''
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in
      --task) require_value "$@"; TASK=$2; shift 2 ;; --claim-file) require_value "$@"; CLAIM_FILE=$2; shift 2 ;;
      --prior-claim-file) require_value "$@"; PRIOR_CLAIM_FILE=$2; shift 2 ;; *) usage ;;
    esac; done
    fm_route_validate_identifier "$TASK" || { fm_route_diagnostic 'invalid task identifier'; exit 1; }
    fm_routing_with_lock fm_route_recover_admission_locked "$TASK" "$CLAIM_FILE" "$PRIOR_CLAIM_FILE"
    ;;
  release)
    TASK=''; GENERATION=''; CLAIM_FILE=''
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in --task) require_value "$@"; TASK=$2; shift 2 ;; --generation) require_value "$@"; GENERATION=$2; shift 2 ;; --claim-file) require_value "$@"; CLAIM_FILE=$2; shift 2 ;; *) usage ;; esac; done
    fm_route_validate_identifier "$TASK" || { fm_route_diagnostic 'invalid task identifier'; exit 1; }
    fm_route_validate_identifier "$GENERATION" || { fm_route_diagnostic 'invalid generation identifier'; exit 1; }
    fm_routing_with_lock fm_route_release_locked "$TASK" "$GENERATION" "$CLAIM_FILE"
    ;;
  failure)
    TASK=''; GENERATION=''; PROVIDER=''; LANE=''; KIND=''; NOW=$(date +%s)
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in
      --task) require_value "$@"; TASK=$2; shift 2 ;; --generation) require_value "$@"; GENERATION=$2; shift 2 ;;
      --provider) require_value "$@"; PROVIDER=$2; shift 2 ;; --lane) require_value "$@"; LANE=$2; shift 2 ;;
      --kind) require_value "$@"; KIND=$2; shift 2 ;; --now) require_value "$@"; NOW=$2; shift 2 ;; *) usage ;; esac; done
    if ! fm_route_validate_identifier "$TASK" || ! fm_route_validate_identifier "$GENERATION" || ! fm_route_validate_identifier "$PROVIDER" || ! fm_route_validate_identifier "$LANE"; then
      fm_route_diagnostic 'invalid failure identifier'; exit 1
    fi
    case "$KIND" in transient|quota|auth|model|unsafe) ;; *) fm_route_diagnostic 'invalid failure kind'; exit 1 ;; esac
    validate_now "$NOW"; fm_routing_with_lock fm_route_failure_locked "$TASK" "$GENERATION" "$PROVIDER" "$LANE" "$KIND" "$NOW"
    ;;
  score)
    TASK=''; GENERATION=''; TERMINAL=''; TESTS=''; REVIEW=''; REDUNDANT=''; NOW=$(date +%s); EXTRA='{}'
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in
      --task) require_value "$@"; TASK=$2; shift 2 ;; --generation) require_value "$@"; GENERATION=$2; shift 2 ;;
      --terminal) require_value "$@"; TERMINAL=$2; shift 2 ;; --tests) require_value "$@"; TESTS=$2; shift 2 ;;
      --review) require_value "$@"; REVIEW=$2; shift 2 ;; --redundant) require_value "$@"; REDUNDANT=$2; shift 2 ;;
      --now) require_value "$@"; NOW=$2; shift 2 ;; --extra-json) require_value "$@"; EXTRA=$2; shift 2 ;; *) usage ;; esac; done
    if ! fm_route_validate_identifier "$TASK" || ! fm_route_validate_identifier "$GENERATION"; then fm_route_diagnostic 'invalid score identifier'; exit 1; fi
    validate_terminal "$TERMINAL"; case "$TESTS" in pass|fail|unknown) ;; *) fm_route_diagnostic 'invalid tests outcome'; exit 1 ;; esac
    case "$REVIEW" in pass|fail|unknown) ;; *) fm_route_diagnostic 'invalid review outcome'; exit 1 ;; esac
    case "$REDUNDANT" in yes|no) ;; *) fm_route_diagnostic 'invalid redundant outcome'; exit 1 ;; esac
    validate_now "$NOW"; fm_route_validate_extra_json "$EXTRA"
    fm_routing_with_lock fm_route_score_locked "$TASK" "$GENERATION" "$TERMINAL" "$TESTS" "$REVIEW" "$REDUNDANT" "$NOW"
    ;;
  finalize)
    TASK=''; GENERATION=''; TERMINAL=''; CLAIM_FILE=''
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in --task) require_value "$@"; TASK=$2; shift 2 ;; --generation) require_value "$@"; GENERATION=$2; shift 2 ;; --terminal) require_value "$@"; TERMINAL=$2; shift 2 ;; --claim-file) require_value "$@"; CLAIM_FILE=$2; shift 2 ;; *) usage ;; esac; done
    if ! fm_route_validate_identifier "$TASK" || ! fm_route_validate_identifier "$GENERATION"; then fm_route_diagnostic 'invalid finalize identifier'; exit 1; fi
    validate_terminal "$TERMINAL"; fm_routing_with_lock fm_route_finalize_locked "$TASK" "$GENERATION" "$TERMINAL" "$CLAIM_FILE"
    ;;
  cleanup-ready|cleanup-finalize)
    TASK=''; GENERATION=''; PROFILE=''; PROVIDER=''; LANE=''; ACCOUNT=''; CLASS=''; WORK_TYPE=''; RISK=''; MODE=''; TERMINAL=''
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in
      --task) require_value "$@"; TASK=$2; shift 2 ;; --generation) require_value "$@"; GENERATION=$2; shift 2 ;;
      --profile) require_value "$@"; PROFILE=$2; shift 2 ;; --provider) require_value "$@"; PROVIDER=$2; shift 2 ;;
      --lane) require_value "$@"; LANE=$2; shift 2 ;; --account) require_value "$@"; ACCOUNT=$2; shift 2 ;;
      --class) require_value "$@"; CLASS=$2; shift 2 ;; --work-type) require_value "$@"; WORK_TYPE=$2; shift 2 ;; --risk) require_value "$@"; RISK=$2; shift 2 ;;
      --mode) require_value "$@"; MODE=$2; shift 2 ;;
      --terminal) [ "$command" = cleanup-finalize ] || usage; require_value "$@"; TERMINAL=$2; shift 2 ;;
      *) usage ;;
    esac; done
    fm_route_validate_route_tuple "$TASK" "$GENERATION" "$PROFILE" "$PROVIDER" "$LANE" "$ACCOUNT" "$CLASS" "$WORK_TYPE" "$RISK" "$MODE"
    if [ "$command" = cleanup-ready ]; then
      fm_routing_with_lock fm_route_cleanup_ready_locked "$TASK" "$GENERATION" "$PROFILE" "$PROVIDER" "$LANE" "$ACCOUNT" "$CLASS" "$WORK_TYPE" "$RISK" "$MODE"
    else
      validate_terminal "$TERMINAL"
      fm_routing_with_lock fm_route_cleanup_finalize_locked "$TASK" "$GENERATION" "$PROFILE" "$PROVIDER" "$LANE" "$ACCOUNT" "$CLASS" "$WORK_TYPE" "$RISK" "$MODE" "$TERMINAL"
    fi
    ;;
  observe)
    REQUEST=''; DECISION=''; NOW=$(date +%s)
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in --request) require_value "$@"; REQUEST=$2; shift 2 ;; --decision) require_value "$@"; DECISION=$2; shift 2 ;; --now) require_value "$@"; NOW=$2; shift 2 ;; *) usage ;; esac; done
    [ -r "$REQUEST" ] || { fm_route_diagnostic 'request file is required and must be readable'; exit 1; }
    [ -r "$DECISION" ] || { fm_route_diagnostic 'decision file is required and must be readable'; exit 1; }
    validate_now "$NOW"; fm_route_validate_request "$REQUEST"; fm_routing_with_lock fm_route_observe_locked "$REQUEST" "$DECISION" "$NOW"
    ;;
  evidence)
    WORK_TYPE=
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in --work-type) require_value "$@"; WORK_TYPE=$2; shift 2 ;; *) usage ;; esac; done
    [ -n "$WORK_TYPE" ] || usage; fm_route_validate_work_type "$WORK_TYPE" || { fm_route_diagnostic 'invalid work type'; exit 1; }; fm_routing_with_lock fm_route_evidence_locked "$WORK_TYPE"
    ;;
  status)
    NOW=$(date +%s)
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in --now) require_value "$@"; NOW=$2; shift 2 ;; *) usage ;; esac; done
    validate_now "$NOW"; fm_routing_with_lock fm_route_status_locked "$NOW"
    ;;
  report)
    STAGE=''; MINIMUM=''
    while [ "$#" -gt 0 ]; do claim_option "$1"; case "$1" in --stage) require_value "$@"; STAGE=$2; shift 2 ;; --minimum) require_value "$@"; MINIMUM=$2; shift 2 ;; *) usage ;; esac; done
    case "$STAGE" in simulation|canary) ;; *) fm_route_diagnostic 'invalid report stage'; exit 1 ;; esac
    case "$MINIMUM" in ''|*[!0-9]*) fm_route_diagnostic 'invalid report minimum'; exit 1 ;; esac
    fm_routing_with_lock fm_route_report_locked "$STAGE" "$MINIMUM"
    ;;
  *) usage ;;
esac
