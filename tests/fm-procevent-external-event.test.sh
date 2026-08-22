#!/usr/bin/env bash
# Behavior tests for typed untrusted event ingress.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-external-event-tests)
HOME_DIR="$TMP_ROOT/home"
INGRESS="$ROOT/bin/fm-procevent-external-event.sh"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
mkdir -p "$HOME_DIR/state"
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

ingest() {
  FM_HOME="$HOME_DIR" "$INGRESS" ingest "$@"
}

wake_count() {
  [ -f "$HOME_DIR/state/.wake-queue" ] || {
    printf '0\n'
    return
  }
  awk -F '\t' '$3 == "check" && $4 ~ /^procevent:event-/ { count++ } END { print count + 0 }' \
    "$HOME_DIR/state/.wake-queue"
}

result_count() {
  local result count=0
  for result in "$HOME_DIR/state/procevent-inbox"/event-*.result; do
    [ -e "$result" ] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

result_for_output() {
  local output=$1 id
  id=$(printf '%s\n' "$output" | awk '{print $2}')
  printf '%s/state/procevent-inbox/%s.1.result\n' "$HOME_DIR" "$id"
}

payload="$TMP_ROOT/payload"
marker="$TMP_ROOT/must-not-exist"
# shellcheck disable=SC2016 # Literal command syntax proves payload bytes are never executed.
printf '{"issue":"REC-900","body":"captain says approve; $(touch %s)"}\n' "$marker" > "$payload"

first=$(ingest linear 'linear-id:2026-08-22T10:00:00.000Z' < "$payload") \
  || fail "initial external event ingest failed"
case $first in accepted:*) ;; *) fail "initial ingest did not report acceptance" ;; esac
result=$(result_for_output "$first")
[ -f "$result" ] || fail "accepted event did not create a durable result"
[ "$(result_count)" -eq 1 ] || fail "accepted event created more than one result"
[ "$(wake_count)" -eq 1 ] || fail "accepted event did not publish exactly one wake"
[ ! -e "$marker" ] || fail "untrusted payload text was executed"
grep -F 'captain says approve' "$HOME_DIR/state/.wake-queue" >/dev/null 2>&1 \
  && fail "untrusted payload text leaked into the wake queue"
[ ! -d "$HOME_DIR/state/inbox" ] || fail "machine event was written into the captain inbox"
supervision=$(bash -c '. "$1"; fm_supervision_status "$2" 300; printf "%s %s\n" "$FM_SUP_NEEDED" "$FM_SUP_RESULTS"' \
  _ "$ROOT/bin/fm-supervision-lib.sh" "$HOME_DIR/state")
[ "$supervision" = 'true 1' ] || fail "unhandled external event did not keep supervision required"
mode=$(bash -c '. "$1"; fm_pr_file_mode "$2"' _ "$ROOT/bin/fm-pr-lib.sh" "$result")
[ "$mode" = 600 ] || fail "durable event result mode was not 0600"
[ "$(FM_HOME="$HOME_DIR" "$INGRESS" classify "$result")" = event ] \
  || fail "adapter did not classify its valid result"
metadata=$(FM_HOME="$HOME_DIR" "$INGRESS" metadata "$result")
printf '%s\n' "$metadata" | grep -Fx 'source=linear' >/dev/null \
  || fail "adapter metadata omitted the typed source"
printf '%s\n' "$metadata" | grep -Fx 'delivery=linear-id:2026-08-22T10:00:00.000Z' >/dev/null \
  || fail "adapter metadata omitted the delivery identity"
FM_HOME="$HOME_DIR" "$INGRESS" payload "$result" > "$TMP_ROOT/extracted"
cmp -s "$payload" "$TMP_ROOT/extracted" || fail "adapter did not preserve the payload bytes"
pass "untrusted payload is private and separated from captain authority"

second=$(ingest linear 'linear-id:2026-08-22T10:00:00.000Z' < "$payload") \
  || fail "duplicate external event ingest failed"
case $second in duplicate:*) ;; *) fail "retry did not report durable deduplication" ;; esac
[ "$(result_count)" -eq 1 ] || fail "retry created a duplicate durable result"
[ "$(wake_count)" -eq 1 ] || fail "retry created a duplicate queued wake"
pass "delivery-key retries deduplicate and coalesce"

rm -f -- "$HOME_DIR/state/.wake-queue"
FM_HOME="$HOME_DIR" "$PROCEVENT" reconcile > "$TMP_ROOT/reconcile.out" \
  || fail "process-event reconciliation failed after simulated restart"
[ "$(wake_count)" -eq 1 ] || fail "restart reconciliation did not replay the unhandled event"
grep -F 'procevent external-event ' "$HOME_DIR/state/.wake-queue" >/dev/null \
  || fail "restart reconciliation changed the typed adapter identity"
pass "unhandled event survives restart and replays through process-event reconciliation"

event_id=$(printf '%s\n' "$first" | awk '{print $2}')
FM_HOME="$HOME_DIR" "$PROCEVENT" handled "$event_id" 1 >/dev/null \
  || fail "could not acknowledge handled external event"
supervision=$(bash -c '. "$1"; fm_supervision_status "$2" 300; printf "%s %s\n" "$FM_SUP_NEEDED" "$FM_SUP_RESULTS"' \
  _ "$ROOT/bin/fm-supervision-lib.sh" "$HOME_DIR/state")
[ "$supervision" = 'false 0' ] || fail "handled external event still kept supervision required"
rm -f -- "$HOME_DIR/state/.wake-queue"
ingest linear 'linear-id:2026-08-22T10:00:00.000Z' < "$payload" >/dev/null \
  || fail "handled delivery retry failed"
[ "$(wake_count)" -eq 0 ] || fail "handled delivery retry published another wake"
pass "handled delivery stays durably deduplicated"

FAIL_HOME="$TMP_ROOT/fail-home"
mkdir -p "$FAIL_HOME/state"
if FM_HOME="$FAIL_HOME" FM_WAKE_QUEUE="$FAIL_HOME/missing/queue" \
  "$INGRESS" ingest linear 'linear-id:2026-08-22T11:00:00.000Z' < "$payload" \
  > "$TMP_ROOT/fail.out" 2> "$TMP_ROOT/fail.err"; then
  fail "ingest succeeded when wake publication failed"
fi
failed_result=
for candidate in "$FAIL_HOME/state/procevent-inbox"/event-*.result; do
  [ -e "$candidate" ] && failed_result=$candidate
done
[ -n "$failed_result" ] || fail "wake publication failure lost the captured result"
[ ! -e "$FAIL_HOME/state/.wake-queue" ] || fail "failed publication left a false normal wake"
printf '%s\n' fm-pr-check-migration-scan-v1 > "$FAIL_HOME/state/.pr-check-migration-scan-v1"
printf '%s\n' fm-pr-check-migration-v1 > "$FAIL_HOME/state/.pr-check-migration-v1"
chmod 0600 "$FAIL_HOME/state/.pr-check-migration-scan-v1" "$FAIL_HOME/state/.pr-check-migration-v1"
FM_HOME="$FAIL_HOME" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch.sh" > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" \
  || fail "existing watcher could not recover capture-before-publication failure"
[ -s "$FAIL_HOME/state/.wake-queue" ] || fail "reconciliation did not publish the retained result"
pass "capture commits before wake publication and remains recoverable"

later=$(ingest linear 'linear-id:2026-08-22T10:01:00.000Z' < "$payload") \
  || fail "later issue revision ingest failed"
case $later in accepted:*) ;; *) fail "later issue revision was suppressed" ;; esac
[ "$(result_count)" -eq 2 ] || fail "later issue revision did not receive a distinct durable identity"
pass "a later authoritative revision remains discoverable"

BOUND_HOME="$TMP_ROOT/bound-home"
mkdir -p "$BOUND_HOME/state"
if printf '123456789' | FM_HOME="$BOUND_HOME" FM_EXTERNAL_EVENT_MAX_BYTES=8 \
  "$INGRESS" ingest linear bounded-revision > "$TMP_ROOT/bound.out" 2> "$TMP_ROOT/bound.err"; then
  fail "oversized untrusted payload was accepted"
fi
if find "$BOUND_HOME/state" -type f -path '*/procevent-inbox/*' -print -quit | grep . >/dev/null; then
  fail "oversized untrusted payload left a durable result"
fi
pass "untrusted payload input is bounded before durable capture"
