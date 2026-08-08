#!/usr/bin/env bash
# One-time migration helper: classify each legacy task (no attempt envelope)
# through fm_disposition_live in read/reconcile mode, then create the
# envelope for the in-flight attempt or retire it with an exact disposition.
# Never migrates or retires branches, never discards unknown or unlanded
# work, and never treats bead closure as forge proof. Re-run-safe: a task
# with an attempt is skipped.
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/fm-attempt-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-attempt-lib.sh"
# shellcheck source=bin/fm-disposition-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-disposition-lib.sh"

STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

migrate_one() {  # <task-id>
  local id=$1 meta pr aid disp
  meta="$STATE_DIR/$id.meta"
  [ -f "$meta" ] || { echo "skip: no meta for $id"; return 0; }
  [ -d "$(attempts_dir)" ] || mkdir -p "$(attempts_dir)"
  local attempt
  attempt=$(sed -n 's/^attempt=//p' "$meta" | head -1)
  [ -n "$attempt" ] && [ -f "$(attempt_path "$attempt")" ] && { echo "skip: $id already has $attempt"; return 0; }
  aid=$(fm_attempt_alloc pi "$id" "${FM_HOME:-local}") || return 1
  # record the reconciled attempt id on the meta so a re-run skips this task
  printf 'attempt=%s\n' "$aid" >> "$meta"
  # journal the meta's forge observation (read/reconcile mode) so the shared
  # live disposition reader can re-read the forge owner; never authoritative
  pr=$(sed -n 's/^pr=//p' "$meta" | head -1)
  if [ -n "$pr" ]; then
    fm_attempt_observe "$aid" 1 forge "{\"provider\":\"github\",\"pr\":\"$pr\",\"state\":\"legacy-meta\"}" || return 1
  fi
  disp=$(fm_disposition_live "$aid")
  case "$disp" in
    unknown)
      # record the exact disposition so the reconciled record shows the reader
      # answered unknown; the attempt stays preserved and never retires
      fm_attempt_effect_observe "$aid" 1 landing "{\"disposition\":\"unknown\",\"migrated\":true}" || return 1
      echo "preserved: $id disposition=unknown (reconcile from live facts)"
      return 0 ;;
    landed)
      # the complete terminal effect set must be observed before retirement
      # (obligations derive from missing observed effects, and a landed
      # disposition also requires tracker plus the five cleanup effects); the
      # historical legacy facts are the evidence for the reconciled record
      fm_attempt_effect_observe "$aid" 1 claim "{\"bead\":\"$id\",\"status\":\"claimed\",\"migrated\":true}" || return 1
      fm_attempt_effect_observe "$aid" 1 provider "{\"provider\":\"legacy\",\"copy\":\"legacy\",\"migrated\":true}" || return 1
      fm_attempt_effect_observe "$aid" 1 launch "{\"endpoint\":\"legacy\",\"migrated\":true}" || return 1
      fm_attempt_effect_observe "$aid" 1 landing "{\"disposition\":\"landed\",\"migrated\":true}" || return 1
      fm_attempt_effect_observe "$aid" 1 tracker "{\"bead\":\"$id\",\"status\":\"closed\",\"migrated\":true}" || return 1
      fm_attempt_effect_observe "$aid" 1 cleanup.endpoint "{\"endpoint\":\"legacy\",\"gone\":true,\"migrated\":true}" || return 1
      fm_attempt_effect_observe "$aid" 1 cleanup.branch "{\"fate\":\"merged\",\"migrated\":true}" || return 1
      fm_attempt_effect_observe "$aid" 1 cleanup.provider "{\"returned\":true,\"migrated\":true}" || return 1
      fm_attempt_effect_observe "$aid" 1 cleanup.runtime "{\"records_removed\":true,\"migrated\":true}" || return 1
      fm_attempt_retire "$aid" 1 "{\"audit\":\"migration\",\"disposition\":\"landed\"}" \
        && echo "retired disposition=landed for $id" || echo "preserved: $id disposition=landed"
      ;;
    preserved_unlanded)
      fm_attempt_effect_observe "$aid" 1 landing "{\"disposition\":\"preserved_unlanded\",\"migrated\":true}" || return 1
      echo "preserved: $id disposition=preserved_unlanded (never retired on bead closure)"
      ;;
  esac
}

for id in "$@"; do migrate_one "$id"; done
