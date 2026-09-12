#!/usr/bin/env bash
# Behavior guard for the opaque acknowledgement receipt.
#
# A routine wake used to cost three supervisor interactions: drain, read the
# status file the wake pointed at, then retype a sequence and a generation into
# a four-argument acknowledgement. The drain now hands back the whole event and
# one opaque receipt, so handling is drain-then-acknowledge.
#
# The durable-until-handled guarantee is the point of the design and is what
# these tests exist to protect: presentation must acknowledge nothing, an
# interruption before the acknowledgement must re-present the same event, and a
# stale or foreign receipt must be refused rather than quietly consume a row.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
GRANT="$ROOT/bin/fm-wake-grant.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-ack-receipt)

make_case() {  # <name> -> case dir with an initialized state root
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

printed_receipt() {  # <stderr-file>
  sed -n 's/^WAKE_ACK_REQUIRED:.*--ack \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$1" | tail -1
}

test_handled_then_acknowledged_consumes_exactly_that_wake() {
  local dir state receipt
  dir=$(make_case handled-then-acked); state="$dir/state"

  printf 'blocked: the synthetic vendor key expired\n' > "$state/task-a.status"
  append_wake "$state" signal task-a.status "signal: $state/task-a.status" \
    || fail "wake append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "drain failed: $(cat "$dir/drain.err")"

  # Interaction one delivers the whole event: the durable row AND the status
  # line it points at, so handling needs no separate read of the status file.
  grep -q "$(printf '\tsignal\ttask-a.status\t')" "$dir/drain.out" \
    || fail "the drain did not present the durable wake row: $(cat "$dir/drain.out")"
  grep -Fq 'blocked: the synthetic vendor key expired' "$dir/drain.out" \
    || fail "the drain did not deliver the event content with the row: $(cat "$dir/drain.out")"

  receipt=$(printed_receipt "$dir/drain.err")
  [ -n "$receipt" ] || fail "the drain printed no acknowledgement receipt: $(cat "$dir/drain.err")"
  [ "$(receipt_field "$receipt" actor)" = main ] \
    || fail "the receipt was not issued to the draining actor"

  # Presentation alone must consume nothing.
  [ -s "$state/.wake-queue" ] \
    || fail "presentation consumed the durable wake before it was handled"

  # Interaction two: hand the receipt back, whole.
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack "$receipt" 2> "$dir/ack.err" \
    || fail "acknowledging with the printed receipt failed: $(cat "$dir/ack.err")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "the acknowledged wake stayed queued: $(cat "$state/.wake-queue")"
  case "$(cat "$state/.watcher-down")" in
    acked:*) ;;
    *) fail "the acknowledgement did not retire its recovery episode" ;;
  esac
  pass "a handled wake is delivered whole and acknowledged with one opaque receipt"
}

test_interruption_before_acknowledgement_re_presents_the_same_event() {
  local dir state first_out second_out receipt
  dir=$(make_case interrupted); state="$dir/state"

  printf 'needs-decision [key=api-shape]: pick the synthetic API shape\n' > "$state/task-b.status"
  append_wake "$state" signal task-b.status "signal: $state/task-b.status" \
    || fail "wake append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" \
    || fail "first drain failed"
  receipt=$(printed_receipt "$dir/first.err")
  [ -n "$receipt" ] || fail "first drain printed no receipt"

  # The turn is interrupted here: the receipt is never handed back. Whatever a
  # restarted supervisor does next, the event must still be waiting for it.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/second.out" 2> "$dir/second.err" \
    || fail "re-drain after interruption failed"
  first_out=$(awk -F '\t' 'NF == 5' "$dir/first.out")
  second_out=$(awk -F '\t' 'NF == 5' "$dir/second.out")
  [ "$first_out" = "$second_out" ] \
    || fail "the interrupted wake was not re-presented identically: [$first_out] vs [$second_out]"

  # The receipt from the interrupted turn still settles it: re-handling is
  # idempotent, not a second obligation.
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack "$receipt" 2> "$dir/ack.err" \
    || fail "the interrupted turn's receipt was refused on replay: $(cat "$dir/ack.err")"
  [ ! -s "$state/.wake-queue" ] || fail "the replayed acknowledgement consumed nothing"
  pass "an interruption before acknowledgement re-presents the same event, and its receipt still settles it"
}

test_a_stale_receipt_is_refused_without_consuming_the_current_wake() {
  local dir state stale_receipt current_receipt rc
  dir=$(make_case stale-receipt); state="$dir/state"

  append_wake "$state" check first 'check: first poll result' || fail "first append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" || fail "first drain failed"
  stale_receipt=$(printed_receipt "$dir/first.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack "$stale_receipt" || fail "first acknowledgement failed"

  append_wake "$state" check second 'check: second poll result' || fail "second append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/second.out" 2> "$dir/second.err" || fail "second drain failed"
  current_receipt=$(printed_receipt "$dir/second.err")

  rc=0
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack "$stale_receipt" \
    > "$dir/stale.out" 2> "$dir/stale.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "a stale receipt failed instead of degrading safely: $(cat "$dir/stale.err")"
  grep -Fq 'acknowledged nothing' "$dir/stale.err" \
    || fail "a stale receipt was not reported as acknowledging nothing: $(cat "$dir/stale.err")"
  grep -Fq -e "--ack $current_receipt" "$dir/stale.err" \
    || fail "the refusal did not name the current wake's own receipt: $(cat "$dir/stale.err")"
  grep -q "$(printf '\tcheck\tsecond\t')" "$state/.wake-queue" \
    || fail "a stale receipt consumed the current wake"
  pass "a stale receipt consumes nothing and names the current wake's receipt"
}

test_a_mangled_receipt_is_refused_outright() {
  local dir state receipt rc out
  dir=$(make_case mangled-receipt); state="$dir/state"
  append_wake "$state" check only 'check: only poll result' || fail "append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" || fail "drain failed"
  receipt=$(printed_receipt "$dir/drain.err")
  [ -n "$receipt" ] || fail "drain printed no receipt"

  # One transposed character: the checksum no longer matches its own body.
  for candidate in "${receipt%?}z" "not-a-receipt" "fmw9.${receipt#*.}" ""; do
    rc=0
    out=$(FM_STATE_OVERRIDE="$state" "$DRAIN" --ack "$candidate" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "a malformed receipt ('$candidate') was not refused as a usage error (rc=$rc): $out"
    assert_contains "$out" 'not a valid acknowledgement receipt' "the refusal did not say what was wrong: $out"
    [ -s "$state/.wake-queue" ] || fail "a malformed receipt ('$candidate') consumed the durable wake"
  done
  pass "a malformed receipt is refused outright and consumes nothing"
}

test_another_actors_receipt_is_refused() {
  local dir state branch_receipt rc out
  dir=$(make_case foreign-receipt); state="$dir/state"

  append_wake "$state" signal task-c.status "signal: task-c" || fail "append failed"
  printf 'working: synthetic\n' > "$state/task-c.status"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" foreign-case || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish foreign-case 1 || fail "grant publication failed"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" \
    > "$dir/branch.out" 2> "$dir/branch.err" || fail "branch drain failed: $(cat "$dir/branch.err")"
  branch_receipt=$(printed_receipt "$dir/branch.err")
  [ -n "$branch_receipt" ] || fail "branch drain printed no receipt"
  [ "$(receipt_field "$branch_receipt" actor)" = branch ] \
    || fail "the branch receipt was not issued to the branch actor"

  # Main must not be able to settle the branch's granted row with the branch's
  # own receipt: per-actor scoping is what keeps a mixed queue safe to split.
  rc=0
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN" --ack "$branch_receipt" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "main accepted a branch receipt (rc=$rc): $out"
  assert_contains "$out" 'issued to the branch supervisor' "the refusal did not name the mismatch: $out"
  [ -s "$state/.wake-queue" ] || fail "a foreign receipt consumed the granted row"

  FM_STATE_OVERRIDE="$state" "$GRANT" deactivate "$$" foreign-case || fail "branch owner deactivation failed"
  pass "a receipt issued to another supervisor is refused and consumes nothing"
}

test_the_deprecated_argument_pair_still_works_and_says_so() {
  local dir state receipt sequence generation
  dir=$(make_case deprecated-pair); state="$dir/state"
  append_wake "$state" check legacy 'check: legacy caller' || fail "append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" || fail "drain failed"
  receipt=$(printed_receipt "$dir/drain.err")
  sequence=$(receipt_field "$receipt" sequence)
  generation=$(receipt_field "$receipt" generation)

  FM_STATE_OVERRIDE="$state" "$DRAIN" \
    --ack-through "$sequence" --recovery-generation "$generation" 2> "$dir/ack.err" \
    || fail "the deprecated argument pair stopped working: $(cat "$dir/ack.err")"
  grep -Fq 'is deprecated' "$dir/ack.err" \
    || fail "the deprecated argument pair did not say it is deprecated: $(cat "$dir/ack.err")"
  [ ! -s "$state/.wake-queue" ] || fail "the deprecated acknowledgement consumed nothing"
  pass "the deprecated argument pair still acknowledges and announces its own deprecation"
}

test_an_unreadable_event_is_reported_instead_of_silently_omitted() {
  local dir state
  dir=$(make_case unreadable-event); state="$dir/state"

  # A status file that cannot be read safely: the row is still durable, but the
  # drain cannot deliver the event, and must say so rather than look empty.
  ln -s "$dir/outside-target" "$state/task-d.status"
  printf 'must-not-be-read\n' > "$dir/outside-target"
  append_wake "$state" signal task-d.status "signal: task-d" || fail "append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" || fail "drain failed"
  grep -Fq 'wake annotation unavailable: task-d.status' "$dir/drain.out" \
    || fail "an undeliverable event was omitted in silence: $(cat "$dir/drain.out")"
  ! grep -Fq 'must-not-be-read' "$dir/drain.out" \
    || fail "the drain followed an out-of-state status symlink"
  pass "an event the drain cannot deliver is named, never silently omitted"
}

test_handled_then_acknowledged_consumes_exactly_that_wake
test_interruption_before_acknowledgement_re_presents_the_same_event
test_a_stale_receipt_is_refused_without_consuming_the_current_wake
test_a_mangled_receipt_is_refused_outright
test_another_actors_receipt_is_refused
test_the_deprecated_argument_pair_still_works_and_says_so
test_an_unreadable_event_is_reported_instead_of_silently_omitted
