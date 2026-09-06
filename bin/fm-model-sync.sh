#!/usr/bin/env bash
# Sync requested/effective model metadata and push compact display to Herdr.
# Usage: fm-model-sync.sh <state-dir> <task-id> [--probe-only|--display-only]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-model-lib.sh
. "$SCRIPT_DIR/fm-model-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

MODE=all
STATE=${1:-}
ID=${2:-}
shift 2 || true
while [ $# -gt 0 ]; do
  case "$1" in
    --probe-only) MODE=probe; shift ;;
    --display-only) MODE=display; shift ;;
    *) shift ;;
  esac
done

[ -n "$STATE" ] && [ -n "$ID" ] || {
  cat >&2 <<'EOF'
usage: fm-model-sync.sh <state-dir> <task-id> [--probe-only|--display-only]
EOF
  exit 2
}

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for $ID" >&2; exit 1; }

if [ "$MODE" != display ]; then
  # Overlapping Pi/Claude lifecycle events can invoke this script concurrently
  # for the same task; serialize the read-probe-write below through the same
  # per-task meta lock fm-spawn.sh uses, so interleaved updates can never
  # revert a newer effective model or duplicate a history entry.
  MODEL_SYNC_LOCK=$(fm_meta_lock_path "$META") || exit 1
  fm_lock_acquire_wait "$MODEL_SYNC_LOCK"
  requested=$(fm_model_requested "$META")
  [ -n "$(fm_model_meta_get "$META" requested_model)" ] || fm_model_meta_upsert "$META" requested_model "$requested"
  # Always re-probe, even once an exact model is already recorded: a running
  # session can change models mid-flight (manual switch, provider fallback),
  # and fm_model_record_effective already no-ops when the probed value is
  # unchanged, so this stays cheap while still catching later changes.
  pane=$(fm_model_meta_get "$META" herdr_pane_id)
  if probe_out=$("$SCRIPT_DIR/fm-model-probe.sh" "$STATE" "$ID" "$pane" 2>/dev/null); then
    model=${probe_out#model=}
    model=${model%%$'\n'*}
    source_line=${probe_out#*$'\n'}
    source=${source_line#source=}
    [ -n "$model" ] || source=$FM_MODEL_SOURCE_UNKNOWN
    if [ -n "$model" ]; then
      tag=
      requested_lc=$(printf '%s' "$requested" | tr '[:upper:]' '[:lower:]')
      model_lc=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
      if [ "$requested_lc" != "$model_lc" ] && fm_model_id_is_exact "$model"; then
        tag=fallback
      fi
      fm_model_record_effective "$STATE" "$ID" "$META" "$model" "$source" "$tag" || true
    fi
  fi
  fm_lock_release "$MODEL_SYNC_LOCK"
fi

if [ "$MODE" = probe ]; then
  fm_model_report_lines "$META"
  exit 0
fi

backend=$(fm_backend_of_meta "$META")
[ "$backend" = herdr ] || exit 0
pane=$(fm_model_meta_get "$META" herdr_pane_id)
[ -n "$pane" ] || exit 0
harness=$(fm_model_meta_get "$META" harness)
display=$(fm_model_display_compact "$META")
requested=$(fm_model_requested "$META")
effective=$(fm_model_effective "$META")
source=$(fm_model_effective_source "$META")
command -v herdr >/dev/null 2>&1 || exit 0
herdr pane report-metadata "$pane" \
  --source "$FM_MODEL_DISPLAY_SOURCE" \
  --agent "$harness" \
  --display-agent "$display" \
  --token "requested-model=$requested" \
  --token "effective-model=$effective" \
  --token "model-source=$source" \
  >/dev/null 2>&1 || true

if [ "$MODE" = display ]; then
  exit 0
fi

fm_model_report_lines "$META"
