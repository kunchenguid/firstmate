#!/usr/bin/env bash
# Usage: fm-droid-model.sh resolve <model|default>
#        fm-droid-model.sh observe|reconcile <task.meta> <spawn-generation>
# resolve accepts only exact IDs from the installed Droid catalog, never a
# custom entry's provider-facing model shorthand. Empty/default emits no pin.
# Catalog failure or an unsupported/ambiguous ID refuses without fallback.
# observe reads Droid hook JSON on stdin and records its session's model.
# Reconciliation updates only effective_model, under the task metadata lock.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ACTION=${1:-}
if [ "$ACTION" = resolve ]; then
  MODEL=${2:-}
  [ -n "$MODEL" ] && [ "$MODEL" != default ] || exit 0
  # The CLI owns native IDs and the merged custom registry. Do not inspect or
  # copy credential-bearing settings, or infer a provider from a backing model.
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  CATALOG=$(fm_run_timed 10 droid exec --help 2>/dev/null) || {
    echo "error: cannot read Droid model catalog; run 'droid exec --help' and retry with an exact model ID" >&2
    exit 1
  }
  MATCHES=$(printf '%s\n' "$CATALOG" | awk -v model="$MODEL" '
    /^(Available|Custom) Models:/ { models=1; next }
    /^[^[:space:]]/ { models=0 }
    models && $1 == model { count++ }
    END { print count+0 }
  ')
  [ "$MATCHES" = 1 ] || {
    echo "error: Droid model selection must match one exact catalog ID; found $MATCHES matches. Choose an ID from 'droid exec --help' (custom models require their custom: registry ID, not a backing model shorthand)." >&2
    exit 1
  }
  printf '%s' "$MODEL"
  exit 0
fi
META=${2:-}
GEN=${3:-}
case "$ACTION" in observe | reconcile) ;; *) exit 2 ;; esac
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
  printf '%s\n' "$MODEL" >"$TMP"
  mv -f "$TMP" "$OBSERVATION"
  TMP=
fi
[ -f "$OBSERVATION" ] || exit 0
MODEL=$(cat "$OBSERVATION")
LOCK=$(fm_meta_lock_path "$META")
if ! fm_lock_try_acquire "$LOCK"; then
  LOCK=
  exit 0
fi
[ "$(fm_meta_get "$META" harness)" = droid ] || exit 0
[ "$(fm_meta_get "$META" spawn_gen)" = "$GEN" ] || exit 0
[ "$(fm_meta_get "$META" effective_model)" != "$MODEL" ] || exit 0
TMP=$(mktemp "$META.droid-model.XXXXXX")
# Keep accounting before any trailing PR identity block; fm_pr_metadata_identity_parse
# rejects unrelated keys after pr=, invalidating an already registered PR poll.
printf 'effective_model=%s\n' "$MODEL" >"$TMP"
awk '!/^effective_model=/' "$META" >>"$TMP"
mv -f "$TMP" "$META"
TMP=
