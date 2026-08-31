#!/usr/bin/env bash
# Deterministically route a Codex worker from exactly five scored factors.
#
# Scores are 0-2 for ambiguity, boundary clarity, risk, diagnosis need, and
# verification quality.
# An explicit captain model/effort override has highest precedence.
# Otherwise a declared hard floor raises, but never lowers, the scored tier.
# The inspectable record is written to data/<task-id>/model-routing.tsv.
# Usage: fm-task-model-route.sh <task-id> <five score/evidence pairs> [--floor <name>] [--override-model <slug> --override-effort <effort>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  echo "usage: fm-task-model-route.sh <task-id> --ambiguity <0-2> --ambiguity-evidence <text> --boundary-clarity <0-2> --boundary-clarity-evidence <text> --risk <0-2> --risk-evidence <text> --diagnosis <0-2> --diagnosis-evidence <text> --verification <0-2> --verification-evidence <text> [--floor <none|architecture|security|data-migration|unknown-production-incident|user-behavior|multi-module>] [--override-model <slug> --override-effort <effort>]" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
ID=$1
shift
case "$ID" in ''|*[!A-Za-z0-9._-]*) usage ;; esac

AMBIGUITY='' AMBIGUITY_EVIDENCE=''
BOUNDARY='' BOUNDARY_EVIDENCE=''
RISK='' RISK_EVIDENCE=''
DIAGNOSIS='' DIAGNOSIS_EVIDENCE=''
VERIFICATION='' VERIFICATION_EVIDENCE=''
FLOOR=none
OVERRIDE_MODEL='' OVERRIDE_EFFORT=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
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

tier_rank() {
  case "$1" in luna) echo 1 ;; terra) echo 2 ;; sol) echo 3 ;; *) echo 0 ;; esac
}
model_tier() {
  case "$1" in
    gpt-5.6-luna) echo luna ;;
    gpt-5.6-terra) echo terra ;;
    gpt-5.6-sol) echo sol ;;
    *) return 1 ;;
  esac
}
default_effort() {
  case "$1" in luna) echo medium ;; terra|sol) echo high ;; esac
}
effort_supported() {
  case "$1:$2" in
    luna:low|luna:medium|luna:high|luna:xhigh|luna:max) return 0 ;;
    terra:low|terra:medium|terra:high|terra:xhigh|terra:max|terra:ultra) return 0 ;;
    sol:low|sol:medium|sol:high|sol:xhigh|sol:max|sol:ultra) return 0 ;;
  esac
  return 1
}

TOTAL=$((AMBIGUITY + BOUNDARY + RISK + DIAGNOSIS + VERIFICATION))
if [ "$TOTAL" -le 2 ]; then SCORE_TIER=luna
elif [ "$TOTAL" -le 6 ]; then SCORE_TIER=terra
else SCORE_TIER=sol
fi
case "$FLOOR" in
  none) FLOOR_TIER=luna ;;
  user-behavior|multi-module) FLOOR_TIER=terra ;;
  architecture|security|data-migration|unknown-production-incident) FLOOR_TIER=sol ;;
  *) usage ;;
esac

MINIMUM_TIER=$SCORE_TIER
if [ "$(tier_rank "$FLOOR_TIER")" -gt "$(tier_rank "$MINIMUM_TIER")" ]; then
  MINIMUM_TIER=$FLOOR_TIER
fi

if [ -n "$OVERRIDE_MODEL" ] || [ -n "$OVERRIDE_EFFORT" ]; then
  [ -n "$OVERRIDE_MODEL" ] && [ -n "$OVERRIDE_EFFORT" ] || usage
  SELECTED_TIER=$(model_tier "$OVERRIDE_MODEL") || usage
  if ! effort_supported "$SELECTED_TIER" "$OVERRIDE_EFFORT"; then
    echo "error: $OVERRIDE_MODEL does not support effort $OVERRIDE_EFFORT" >&2
    exit 2
  fi
  MODEL=$OVERRIDE_MODEL
  EFFORT=$OVERRIDE_EFFORT
  PRECEDENCE=user_override
else
  SELECTED_TIER=$MINIMUM_TIER
  MODEL="gpt-5.6-$SELECTED_TIER"
  EFFORT=$(default_effort "$SELECTED_TIER")
  if [ "$MINIMUM_TIER" != "$SCORE_TIER" ]; then PRECEDENCE=hard_floor
  else PRECEDENCE=five_factor_score
  fi
fi

DIR="$DATA/$ID"
mkdir -p "$DIR" || exit 1
RECORD="$DIR/model-routing.tsv"
TMP=$(mktemp "$DIR/.model-routing.XXXXXX") || exit 1
trap 'rm -f -- "$TMP"' EXIT HUP INT TERM
{
  printf 'version\t1\n'
  printf 'task_id\t%s\n' "$ID"
  printf 'ambiguity\t%s\t%s\n' "$AMBIGUITY" "$AMBIGUITY_EVIDENCE"
  printf 'boundary_clarity\t%s\t%s\n' "$BOUNDARY" "$BOUNDARY_EVIDENCE"
  printf 'risk\t%s\t%s\n' "$RISK" "$RISK_EVIDENCE"
  printf 'diagnosis\t%s\t%s\n' "$DIAGNOSIS" "$DIAGNOSIS_EVIDENCE"
  printf 'verification\t%s\t%s\n' "$VERIFICATION" "$VERIFICATION_EVIDENCE"
  printf 'total\t%s\n' "$TOTAL"
  printf 'score_tier\t%s\n' "$SCORE_TIER"
  printf 'floor\t%s\n' "$FLOOR"
  printf 'minimum_tier\t%s\n' "$MINIMUM_TIER"
  printf 'precedence\t%s\n' "$PRECEDENCE"
  printf 'selected_tier\t%s\n' "$SELECTED_TIER"
  printf 'model\t%s\n' "$MODEL"
  printf 'effort\t%s\n' "$EFFORT"
  printf 'quota_policy\tquota may choose credentials or equivalent candidates but must not lower minimum_tier\n'
} > "$TMP" || exit 1
chmod 0600 "$TMP" || exit 1
mv -f -- "$TMP" "$RECORD" || exit 1
trap - EXIT HUP INT TERM
printf 'routed: %s model=%s effort=%s total=%s precedence=%s record=%s\n' \
  "$ID" "$MODEL" "$EFFORT" "$TOTAL" "$PRECEDENCE" "$RECORD"
