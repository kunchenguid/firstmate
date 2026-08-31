#!/usr/bin/env bash
# Deterministically route a Codex worker from exactly five scored factors.
#
# Scores are 0-2 for ambiguity, boundary clarity, risk, diagnosis need, and
# verification quality.
# An explicit captain model/effort override has highest precedence.
# Otherwise a declared hard floor raises, but never lowers, the scored tier.
# The inspectable record is written to data/<task-id>/model-routing.tsv.
# Usage: fm-task-model-route.sh <task-id> <five score/evidence pairs> [routing options]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-task-model-route-lib.sh
. "$SCRIPT_DIR/fm-task-model-route-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  echo "usage: fm-task-model-route.sh <task-id> --ambiguity <0-2> --ambiguity-evidence <text> --boundary-clarity <0-2> --boundary-clarity-evidence <text> --risk <0-2> --risk-evidence <text> --diagnosis <0-2> --diagnosis-evidence <text> --verification <0-2> --verification-evidence <text> [--floor <name>] [--override-model <slug> --override-effort <effort>] [--quota-candidate <profile> <model> <effort> <eligible|ineligible> <reason> <evidence>]... [--resolved-profile <profile> --resolved-model <slug> --resolved-effort <effort>]" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
ID=$1
shift
fm_task_id_creation_valid "$ID" || usage

AMBIGUITY='' AMBIGUITY_EVIDENCE=''
BOUNDARY='' BOUNDARY_EVIDENCE=''
RISK='' RISK_EVIDENCE=''
DIAGNOSIS='' DIAGNOSIS_EVIDENCE=''
VERIFICATION='' VERIFICATION_EVIDENCE=''
FLOOR=none
OVERRIDE_MODEL='' OVERRIDE_EFFORT=''
QUOTA_CANDIDATE_COUNT=0
RESOLVED_PROFILE='' RESOLVED_MODEL='' RESOLVED_EFFORT=''
declare -a QUOTA_PROFILES=() QUOTA_MODELS=() QUOTA_EFFORTS=()
declare -a QUOTA_ELIGIBILITY=() QUOTA_REASONS=() QUOTA_EVIDENCE=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --quota-candidate)
      [ "$#" -ge 7 ] || usage
      QUOTA_PROFILES+=("$2")
      QUOTA_MODELS+=("$3")
      QUOTA_EFFORTS+=("$4")
      QUOTA_ELIGIBILITY+=("$5")
      QUOTA_REASONS+=("$6")
      QUOTA_EVIDENCE+=("$7")
      QUOTA_CANDIDATE_COUNT=$((QUOTA_CANDIDATE_COUNT + 1))
      shift 7
      continue
      ;;
    *) [ "$#" -ge 2 ] || usage ;;
  esac
  case "$1" in
    --ambiguity) AMBIGUITY=$2 ;;
    --ambiguity-evidence) AMBIGUITY_EVIDENCE=$2 ;;
    --boundary-clarity) BOUNDARY=$2 ;;
    --boundary-clarity-evidence) BOUNDARY_EVIDENCE=$2 ;;
    --risk) RISK=$2 ;;
    --risk-evidence) RISK_EVIDENCE=$2 ;;
    --diagnosis) DIAGNOSIS=$2 ;;
    --diagnosis-evidence) DIAGNOSIS_EVIDENCE=$2 ;;
    --verification) VERIFICATION=$2 ;;
    --verification-evidence) VERIFICATION_EVIDENCE=$2 ;;
    --floor) FLOOR=$2 ;;
    --override-model) OVERRIDE_MODEL=$2 ;;
    --override-effort) OVERRIDE_EFFORT=$2 ;;
    --resolved-profile) RESOLVED_PROFILE=$2 ;;
    --resolved-model) RESOLVED_MODEL=$2 ;;
    --resolved-effort) RESOLVED_EFFORT=$2 ;;
    *) usage ;;
  esac
  shift 2
done

valid_score() { case "$1" in 0|1|2) return 0 ;; esac; return 1; }
valid_evidence() {
  [ -n "$1" ] || return 1
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
}
for score in "$AMBIGUITY" "$BOUNDARY" "$RISK" "$DIAGNOSIS" "$VERIFICATION"; do
  valid_score "$score" || usage
done
for evidence in "$AMBIGUITY_EVIDENCE" "$BOUNDARY_EVIDENCE" "$RISK_EVIDENCE" "$DIAGNOSIS_EVIDENCE" "$VERIFICATION_EVIDENCE"; do
  valid_evidence "$evidence" || usage
done

TOTAL=$((AMBIGUITY + BOUNDARY + RISK + DIAGNOSIS + VERIFICATION))
SCORE_TIER=$(fm_task_route_score_tier "$TOTAL") || usage
FLOOR_TIER=$(fm_task_route_floor_tier "$FLOOR") || usage

MINIMUM_TIER=$SCORE_TIER
if [ "$(fm_task_route_tier_rank "$FLOOR_TIER")" -gt "$(fm_task_route_tier_rank "$MINIMUM_TIER")" ]; then
  MINIMUM_TIER=$FLOOR_TIER
fi

if [ -n "$OVERRIDE_MODEL" ] || [ -n "$OVERRIDE_EFFORT" ]; then
  [ -n "$OVERRIDE_MODEL" ] && [ -n "$OVERRIDE_EFFORT" ] || usage
  SELECTED_TIER=$(fm_task_route_model_tier "$OVERRIDE_MODEL") || usage
  if ! fm_task_route_effort_supported "$SELECTED_TIER" "$OVERRIDE_EFFORT"; then
    echo "error: $OVERRIDE_MODEL does not support effort $OVERRIDE_EFFORT" >&2
    exit 2
  fi
  MODEL=$OVERRIDE_MODEL
  EFFORT=$OVERRIDE_EFFORT
  PRECEDENCE=user_override
else
  SELECTED_TIER=$MINIMUM_TIER
  MODEL="gpt-5.6-$SELECTED_TIER"
  EFFORT=$(fm_task_route_default_effort "$SELECTED_TIER")
  OVERRIDE_MODEL=none
  OVERRIDE_EFFORT=none
  if [ "$MINIMUM_TIER" != "$SCORE_TIER" ]; then PRECEDENCE=hard_floor
  else PRECEDENCE=five_factor_score
  fi
fi

if [ "$QUOTA_CANDIDATE_COUNT" -eq 0 ] && [ -z "$RESOLVED_PROFILE" ] \
  && [ -z "$RESOLVED_MODEL" ] && [ -z "$RESOLVED_EFFORT" ]; then
  RESOLVED_PROFILE=none
  RESOLVED_MODEL=$MODEL
  RESOLVED_EFFORT=$EFFORT
  RESOLUTION=deterministic
else
  [ "$QUOTA_CANDIDATE_COUNT" -gt 0 ] && [ -n "$RESOLVED_PROFILE" ] \
    && [ -n "$RESOLVED_MODEL" ] && [ -n "$RESOLVED_EFFORT" ] || usage
  QUOTA_PROFILE_SET=
  RESOLVED_PROFILE_MATCHES=0
  index=0
  while [ "$index" -lt "$QUOTA_CANDIDATE_COUNT" ]; do
    fm_task_route_quota_candidate_valid "${QUOTA_PROFILES[$index]}" \
      "${QUOTA_MODELS[$index]}" "${QUOTA_EFFORTS[$index]}" \
      "${QUOTA_ELIGIBILITY[$index]}" "${QUOTA_REASONS[$index]}" \
      "${QUOTA_EVIDENCE[$index]}" "$MINIMUM_TIER" "$OVERRIDE_MODEL" \
      "$OVERRIDE_EFFORT" || usage
    case ",$QUOTA_PROFILE_SET," in
      *,"${QUOTA_PROFILES[$index]}",*) usage ;;
    esac
    QUOTA_PROFILE_SET=${QUOTA_PROFILE_SET:+$QUOTA_PROFILE_SET,}${QUOTA_PROFILES[$index]}
    if [ "${QUOTA_PROFILES[$index]}" = "$RESOLVED_PROFILE" ] \
      && [ "${QUOTA_MODELS[$index]}" = "$RESOLVED_MODEL" ] \
      && [ "${QUOTA_EFFORTS[$index]}" = "$RESOLVED_EFFORT" ] \
      && [ "${QUOTA_ELIGIBILITY[$index]}" = eligible ] \
      && fm_task_route_quota_candidate_selectable "$RESOLVED_MODEL" \
        "$RESOLVED_EFFORT" "$MINIMUM_TIER" "$OVERRIDE_MODEL" \
        "$OVERRIDE_EFFORT"; then
      RESOLVED_PROFILE_MATCHES=$((RESOLVED_PROFILE_MATCHES + 1))
    fi
    index=$((index + 1))
  done
  [ "$RESOLVED_PROFILE_MATCHES" -eq 1 ] || usage
  RESOLUTION=quota_profile
fi

DIR="$DATA/$ID"
mkdir -p "$DIR" || exit 1
RECORD="$DIR/model-routing.tsv"
[ ! -e "$RECORD" ] && [ ! -L "$RECORD" ] || {
  echo "error: model route record already exists for $ID" >&2
  exit 1
}
TMP=$(mktemp "$DIR/.model-routing.XXXXXX") || exit 1
trap 'rm -f -- "$TMP"' EXIT HUP INT TERM
{
  printf 'version\t4\n'
  printf 'task_id\t%s\n' "$ID"
  printf 'ambiguity\t%s\t%s\n' "$AMBIGUITY" "$AMBIGUITY_EVIDENCE"
  printf 'boundary_clarity\t%s\t%s\n' "$BOUNDARY" "$BOUNDARY_EVIDENCE"
  printf 'risk\t%s\t%s\n' "$RISK" "$RISK_EVIDENCE"
  printf 'diagnosis_need\t%s\t%s\n' "$DIAGNOSIS" "$DIAGNOSIS_EVIDENCE"
  printf 'verification_quality\t%s\t%s\n' "$VERIFICATION" "$VERIFICATION_EVIDENCE"
  printf 'total\t%s\n' "$TOTAL"
  printf 'score_tier\t%s\n' "$SCORE_TIER"
  printf 'floor\t%s\n' "$FLOOR"
  printf 'minimum_tier\t%s\n' "$MINIMUM_TIER"
  printf 'override_model\t%s\n' "$OVERRIDE_MODEL"
  printf 'override_effort\t%s\n' "$OVERRIDE_EFFORT"
  printf 'precedence\t%s\n' "$PRECEDENCE"
  printf 'selected_tier\t%s\n' "$SELECTED_TIER"
  printf 'model\t%s\n' "$MODEL"
  printf 'effort\t%s\n' "$EFFORT"
  printf 'quota_candidate_count\t%s\n' "$QUOTA_CANDIDATE_COUNT"
  index=0
  while [ "$index" -lt "$QUOTA_CANDIDATE_COUNT" ]; do
    printf 'quota_candidate\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${QUOTA_PROFILES[$index]}" "${QUOTA_MODELS[$index]}" \
      "${QUOTA_EFFORTS[$index]}" "${QUOTA_ELIGIBILITY[$index]}" \
      "${QUOTA_REASONS[$index]}" "${QUOTA_EVIDENCE[$index]}"
    index=$((index + 1))
  done
  printf 'resolved_profile\t%s\n' "$RESOLVED_PROFILE"
  printf 'resolved_model\t%s\n' "$RESOLVED_MODEL"
  printf 'resolved_effort\t%s\n' "$RESOLVED_EFFORT"
  printf 'resolution\t%s\n' "$RESOLUTION"
  printf 'quota_policy\tquota records every configured profile with eligibility, rejection reason, and candidate-specific evidence; selection preserves explicit override exactly or otherwise never lowers minimum_tier\n'
} > "$TMP" || exit 1
chmod 0600 "$TMP" || exit 1
fm_task_route_record_parse "$TMP" || {
  echo "error: generated model route record did not satisfy the shared contract" >&2
  exit 1
}
ln "$TMP" "$RECORD" 2>/dev/null || {
  echo "error: model route record already exists for $ID" >&2
  exit 1
}
rm -f -- "$TMP" || true
trap - EXIT HUP INT TERM
printf 'routed: %s model=%s effort=%s total=%s precedence=%s record=%s\n' \
  "$ID" "$RESOLVED_MODEL" "$RESOLVED_EFFORT" "$TOTAL" "$PRECEDENCE" "$RECORD"
