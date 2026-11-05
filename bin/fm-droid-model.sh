#!/usr/bin/env bash
# Usage: fm-droid-model.sh observe|reconcile <task.meta> <spawn-generation>
# observe reads Droid hook JSON on stdin and records its session's model.
# Reconciliation updates only effective_model, under the task metadata lock.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ACTION=${1:-}
META=${2:-}
GEN=${3:-}
case "$ACTION" in observe|reconcile) ;; *) exit 2 ;; esac
[ -n "$META" ] && [ -n "$GEN" ] || exit 2
case "$GEN" in *[!A-Za-z0-9._-]*) exit 2 ;; esac
STATE=${META%/*}
FM_STATE_OVERRIDE=$STATE
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

[ "$(fm_meta_get "$META" harness)" = droid ] || exit 0
[ "$(fm_meta_get "$META" spawn_gen)" = "$GEN" ] || exit 0
OBSERVATION="$META.droid-model.$GEN"
TMP=
LOCK=
cleanup() {
  [ -z "$TMP" ] || rm -f "$TMP"
  [ -z "$LOCK" ] || fm_lock_release "$LOCK"
}
trap cleanup EXIT
if [ "$ACTION" = observe ]; then
  TRANSCRIPT=$(jq -er '.transcript_path | select(type == "string" and endswith(".jsonl"))') || exit 0
  MODEL=$(jq -er '.model | select(type == "string" and length > 0 and . != "default" and . != "unknown-at-spawn" and (test("^(anthropic|openai|oss)-latest-") | not) and (test("[\\r\\n*]") | not))' \
    "${TRANSCRIPT%.jsonl}.settings.json" 2>/dev/null) || exit 0
  TMP=$(mktemp "$OBSERVATION.XXXXXX")
  printf '%s\n' "$MODEL" > "$TMP"
  mv -f "$TMP" "$OBSERVATION"
  TMP=
fi
[ -f "$OBSERVATION" ] || exit 0
MODEL=$(cat "$OBSERVATION")
LOCK=$(fm_meta_lock_path "$META")
if ! fm_lock_try_acquire "$LOCK"; then LOCK=; exit 0; fi
[ "$(fm_meta_get "$META" harness)" = droid ] || exit 0
[ "$(fm_meta_get "$META" spawn_gen)" = "$GEN" ] || exit 0
[ "$(fm_meta_get "$META" effective_model)" != "$MODEL" ] || exit 0
TMP=$(mktemp "$META.droid-model.XXXXXX")
# Keep accounting before any trailing PR identity block; fm_pr_metadata_identity_parse
# rejects unrelated keys after pr=, invalidating an already registered PR poll.
printf 'effective_model=%s\n' "$MODEL" > "$TMP"
awk '!/^effective_model=/' "$META" >> "$TMP"
mv -f "$TMP" "$META"
TMP=
