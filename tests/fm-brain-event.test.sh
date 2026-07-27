#!/usr/bin/env bash
# Behavior tests for the optional idempotent brain-event lifecycle bridge.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-brain-event.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
CAPTURE="$TMP_ROOT/capture"
FAKE="$TMP_ROOT/fake-brain-event"

cat > "$FAKE" <<'SH'
#!/usr/bin/env bash
printf 'agent=%s\n' "${BRAIN_AGENT:-}"
printf 'arg=%s\n' "$@"
SH
chmod +x "$FAKE"

run_bridge() {
  FM_BRAIN_EVENT_COMMAND="$FAKE" \
    "$ROOT/bin/fm-brain-event.sh" decision-resolved DECISION task-1 \
    'hold-1|sha256-safe-digest' \
    'resolved captain decision hold hold-1 digest=sha256-safe-digest routed=ship-1' \
    --artifact-ref report.md > "$1" 2> "$2"
}

run_bridge "$CAPTURE.1" "$CAPTURE.1.err"
run_bridge "$CAPTURE.2" "$CAPTURE.2.err"

cmp -s "$CAPTURE.1" "$CAPTURE.2" \
  || fail "same lifecycle identity did not produce the same brain-event invocation"
grep -qx 'agent=firstmate' "$CAPTURE.1" \
  || fail "bridge did not scope the event to firstmate"
grep -qx 'arg=DECISION' "$CAPTURE.1" \
  || fail "bridge did not forward the event type"
grep -qx 'arg=--source-kind' "$CAPTURE.1" \
  || fail "bridge did not provide source provenance"
grep -qx 'arg=--task-id' "$CAPTURE.1" \
  || fail "bridge did not provide task provenance"
grep -Eq '^arg=firstmate:decision-resolved:[0-9a-f]{32}$' "$CAPTURE.1" \
  || fail "bridge did not generate the bounded deterministic event id"
if grep -Fq 'Captain decision:' "$CAPTURE.1"; then
  fail "bridge forwarded raw captain decision content"
fi
pass "fm-brain-event: deterministic provenance excludes raw decision content"

FAIL="$TMP_ROOT/fail-brain-event"
cat > "$FAIL" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$FAIL"
set +e
FM_BRAIN_EVENT_COMMAND="$FAIL" \
  "$ROOT/bin/fm-brain-event.sh" teardown TASK_DONE task-2 stable safe \
  > "$CAPTURE.fail" 2> "$CAPTURE.fail.err"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "brain-event failure changed the lifecycle outcome"
grep -Fq 'lifecycle event was not accepted' "$CAPTURE.fail.err" \
  || fail "brain-event failure was not surfaced as a warning"
pass "fm-brain-event: configured delivery failure is visible but non-fatal"

set +e
FM_BRAIN_EVENT_COMMAND="$FAKE" \
  "$ROOT/bin/fm-brain-event.sh" 'bad/action' NOTE task-3 stable safe \
  > "$CAPTURE.invalid" 2> "$CAPTURE.invalid.err"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "invalid optional invocation changed lifecycle outcome"
[ ! -s "$CAPTURE.invalid" ] || fail "invalid action reached brain-event"
grep -Fq 'invalid action' "$CAPTURE.invalid.err" \
  || fail "invalid action was not diagnosed"
pass "fm-brain-event: invalid lifecycle metadata fails closed without breaking Firstmate"
