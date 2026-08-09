#!/usr/bin/env bash
# One-time migration helper: classify each legacy task through
# fm_disposition_live in read/reconcile mode, then create or recover the
# envelope for the in-flight attempt and bind only exact live evidence.
# It never migrates or retires branches and never discards unknown or
# unlanded work.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
# shellcheck source=bin/fm-attempt-lib.sh
. "$SCRIPT_DIR/fm-attempt-lib.sh"
# shellcheck source=bin/fm-disposition-lib.sh
. "$SCRIPT_DIR/fm-disposition-lib.sh"

STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

migration_observation_exists() {
  local aid=$1 name=$2 evidence=$3
  jq -e --arg name "$name" --argjson evidence "$evidence" '
    . as $record
    | any(.observations[]?; .name == $name and .generation == $record.envelope.generation and .evidence == $evidence)
  ' "$(attempt_path "$aid")" >/dev/null 2>&1
}

migration_observe_once() {
  local aid=$1 gen=$2 name=$3 evidence=$4
  migration_observation_exists "$aid" "$name" "$evidence" \
    || fm_attempt_observe "$aid" "$gen" "$name" "$evidence"
}

recover_migration_attempt() {
  local id=$1 f aid count=0 found=
  for f in "$(attempts_dir)"/*.json; do
    [ -e "$f" ] || continue
    jq -e --arg id "$id" --arg home "$FM_HOME" '
      .schema == "fm-attempt.v1"
      and .envelope.task_key == $id
      and .envelope.home_id == $home
      and (.envelope.task_source == "migration" or .envelope.task_source == "pi")
      and ([.receipts.retirement[]? | select(.state == "observed")] | length == 0)
    ' "$f" >/dev/null 2>&1 || continue
    aid=$(basename "$f" .json)
    found=$aid
    count=$((count + 1))
  done
  [ "$count" -le 1 ] || return 2
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$found"
}

migrate_one() {
  local id=$1 meta pr aid disp gen existing_attempt forge_evidence reconcile_evidence recover_rc
  meta="$STATE_DIR/$id.meta"
  [ -f "$meta" ] || { echo "skip: no meta for $id"; return 0; }
  mkdir -p "$(attempts_dir)" || return 1
  existing_attempt=$(sed -n 's/^attempt=//p' "$meta" | head -1)
  if [ -n "$existing_attempt" ]; then
    if [ -f "$(attempt_path "$existing_attempt")" ] \
      && jq -e --arg id "$id" '.envelope.task_key == $id' "$(attempt_path "$existing_attempt")" >/dev/null 2>&1; then
      echo "skip: $id already has $existing_attempt"
      return 0
    fi
    echo "migration: invalid existing attempt binding for $id" >&2
    return 1
  fi

  if aid=$(recover_migration_attempt "$id" 2>/dev/null); then
    :
  else
    recover_rc=$?
    if [ "$recover_rc" -eq 2 ]; then
      echo "migration: multiple unretired attempts match $id; refusing another allocation" >&2
      return 1
    fi
    aid=$(fm_attempt_alloc migration "$id" "$FM_HOME") || return 1
  fi
  gen=$(fm_attempt_generation "$aid") || return 1

  pr=$(sed -n 's/^pr=//p' "$meta" | head -1)
  if [ -n "$pr" ]; then
    forge_evidence=$(jq -n --arg pr "$pr" '{provider:"github",pr:$pr,state:"legacy-meta"}')
    migration_observe_once "$aid" "$gen" forge "$forge_evidence" || return 1
  fi

  disp=$(fm_disposition_live "$aid") || return 1
  case "$disp" in
    unknown)
      reconcile_evidence=$(jq -n '{disposition:"unknown",reader:"fm_disposition_live",migrated:true}')
      migration_observe_once "$aid" "$gen" migration "$reconcile_evidence" || return 1
      ;;
    landed|preserved_unlanded)
      reconcile_evidence=$(jq -n --arg disposition "$disp" \
        '{disposition:$disposition,reader:"fm_disposition_live",migrated:true}')
      fm_attempt_effect_observe "$aid" "$gen" landing "$reconcile_evidence" || return 1
      ;;
    *)
      echo "migration: invalid live disposition '$disp' for $id" >&2
      return 1
      ;;
  esac

  printf 'attempt=%s\n' "$aid" >> "$meta" || return 1
  case "$disp" in
    unknown) echo "preserved: $id disposition=unknown (journal evidence only)" ;;
    landed) echo "preserved: $id disposition=landed (exact landing evidence; terminal reconciliation required)" ;;
    preserved_unlanded) echo "preserved: $id disposition=preserved_unlanded (exact landing evidence; cleanup reconciliation required)" ;;
  esac
}

for id in "$@"; do
  migrate_one "$id" || exit 1
done
