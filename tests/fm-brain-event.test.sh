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

# A machine without brain-event is the default, so an inactive bridge must be a
# silent no-op: no warning noise on any lifecycle command. The stripped PATH and
# throwaway HOME remove both discovery sources.
CLEAN_HOME="$TMP_ROOT/clean-home"
mkdir -p "$CLEAN_HOME"
set +e
env -u FM_BRAIN_EVENT_COMMAND PATH=/usr/bin:/bin HOME="$CLEAN_HOME" \
  "$ROOT/bin/fm-brain-event.sh" spawn TASK_START task-4 stable safe \
  > "$CAPTURE.absent" 2> "$CAPTURE.absent.err"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "missing brain-event changed the lifecycle outcome"
[ ! -s "$CAPTURE.absent" ] || fail "missing brain-event produced stdout"
[ ! -s "$CAPTURE.absent.err" ] \
  || fail "missing brain-event warned on a machine that never opted in"
pass "fm-brain-event: an uninstalled bridge is a silent no-op"

# Stock macOS ships neither timeout nor gtimeout, so the bound rests on the perl
# fallback. Without it a stalled event store would hang the lifecycle command for
# as long as the store stalls.
STALL="$TMP_ROOT/stalling-brain-event"
cat > "$STALL" <<'SH'
#!/usr/bin/env bash
sleep 600
SH
chmod +x "$STALL"
STARTED=$(date +%s)
set +e
env PATH=/usr/bin:/bin FM_BRAIN_EVENT_COMMAND="$STALL" FM_BRAIN_EVENT_TIMEOUT=2 \
  "$ROOT/bin/fm-brain-event.sh" teardown TASK_DONE task-5 stable safe \
  > "$CAPTURE.stall" 2> "$CAPTURE.stall.err"
RC=$?
set -e
ELAPSED=$(( $(date +%s) - STARTED ))
[ "$RC" -eq 0 ] || fail "a stalled event store changed the lifecycle outcome"
[ "$ELAPSED" -lt 30 ] \
  || fail "stalled event store was not bounded by FM_BRAIN_EVENT_TIMEOUT (${ELAPSED}s)"
grep -Fq 'lifecycle event was not accepted' "$CAPTURE.stall.err" \
  || fail "stalled event store was not surfaced as a warning"
pass "fm-brain-event: a stalled event store is bounded, not a hung lifecycle command"

# CI runs on Linux, where /usr/bin/timeout always wins the probe above, so the
# perl fallback that carries the whole bound on stock macOS would never run.
# Pin PATH to a scratch directory holding only the bridge's own dependencies.
scratch_bin() {  # <dir>
  mkdir -p "$1"
  for tool in bash env sleep perl awk shasum sha256sum; do
    if tool_path=$(command -v "$tool" 2>/dev/null) && [ -n "$tool_path" ]; then
      ln -sf "$tool_path" "$1/$tool"
    fi
  done
}

FALLBACK_BIN="$TMP_ROOT/fallback-bin"
scratch_bin "$FALLBACK_BIN"
[ -x "$FALLBACK_BIN/perl" ] || fail "test host has no perl to exercise the stock-macOS bound"
[ -x "$FALLBACK_BIN/shasum" ] || [ -x "$FALLBACK_BIN/sha256sum" ] \
  || fail "scratch PATH has no SHA-256 utility for the bridge"
[ ! -e "$FALLBACK_BIN/timeout" ] || fail "scratch PATH still offers timeout"
[ ! -e "$FALLBACK_BIN/gtimeout" ] || fail "scratch PATH still offers gtimeout"

set +e
env PATH="$FALLBACK_BIN" FM_BRAIN_EVENT_COMMAND="$FAKE" \
  "$ROOT/bin/fm-brain-event.sh" decision-resolved DECISION task-1 \
  'hold-1|sha256-safe-digest' \
  'resolved captain decision hold hold-1 digest=sha256-safe-digest routed=ship-1' \
  --artifact-ref report.md > "$CAPTURE.perl" 2> "$CAPTURE.perl.err"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "the perl-bounded path changed the lifecycle outcome on success"
cmp -s "$CAPTURE.perl" "$CAPTURE.1" \
  || fail "the perl-bounded path did not deliver the same event as the timeout path"
[ ! -s "$CAPTURE.perl.err" ] || fail "the perl-bounded path warned on a delivered event"

set +e
env PATH="$FALLBACK_BIN" FM_BRAIN_EVENT_COMMAND="$FAIL" \
  "$ROOT/bin/fm-brain-event.sh" teardown TASK_DONE task-6 stable safe \
  > "$CAPTURE.perlfail" 2> "$CAPTURE.perlfail.err"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "the perl-bounded path changed the lifecycle outcome on failure"
grep -Fq 'lifecycle event was not accepted' "$CAPTURE.perlfail.err" \
  || fail "the perl-bounded path lost the rejected event's exit status"

STARTED=$(date +%s)
set +e
env PATH="$FALLBACK_BIN" FM_BRAIN_EVENT_COMMAND="$STALL" FM_BRAIN_EVENT_TIMEOUT=2 \
  "$ROOT/bin/fm-brain-event.sh" teardown TASK_DONE task-7 stable safe \
  > "$CAPTURE.perlstall" 2> "$CAPTURE.perlstall.err"
RC=$?
set -e
ELAPSED=$(( $(date +%s) - STARTED ))
[ "$RC" -eq 0 ] || fail "the perl-bounded path changed the lifecycle outcome on a stall"
[ "$ELAPSED" -lt 30 ] \
  || fail "the perl fallback did not bound a stalled event store (${ELAPSED}s)"
grep -Fq 'lifecycle event was not accepted' "$CAPTURE.perlstall.err" \
  || fail "the perl fallback did not surface the abandoned event"
pass "fm-brain-event: the stock-macOS perl fallback delivers, reports and bounds events"

# `timeout 0` and `alarm 0` both mean "run unbounded", so a zero must fall back
# to the default rather than silently removing the bound.
SHIM_BIN="$TMP_ROOT/shim-bin"
scratch_bin "$SHIM_BIN"
cat > "$SHIM_BIN/timeout" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$FM_TEST_TIMEOUT_RECORD"
shift
exec "$@"
SH
chmod +x "$SHIM_BIN/timeout"
FM_TEST_TIMEOUT_RECORD="$CAPTURE.timeout-arg"
export FM_TEST_TIMEOUT_RECORD

set +e
env PATH="$SHIM_BIN" FM_BRAIN_EVENT_COMMAND="$FAKE" FM_BRAIN_EVENT_TIMEOUT=0 \
  "$ROOT/bin/fm-brain-event.sh" teardown TASK_DONE task-8 stable safe \
  > "$CAPTURE.zero" 2> "$CAPTURE.zero.err"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "a zero timeout changed the lifecycle outcome"
grep -qx '10' "$CAPTURE.timeout-arg" \
  || fail "FM_BRAIN_EVENT_TIMEOUT=0 disabled the bound instead of using the default"
[ -s "$CAPTURE.zero" ] || fail "a zero timeout stopped the event from being delivered"
pass "fm-brain-event: a zero timeout falls back to the default bound"

# A retry of the exact same lifecycle transition carries the same derived
# event_id. The real ingest API keys on event_id and full content: an
# identical repeat is a 409 event_conflict, not a fresh failure, because the
# first call already stored it. This stub reproduces that contract - first
# call per event-id stores silently, an identical repeat is rejected with the
# real client's exact wording - without ever touching a real brain.
CONFLICT_STORE="$TMP_ROOT/conflict-store"
mkdir -p "$CONFLICT_STORE"
CONFLICTING="$TMP_ROOT/conflicting-brain-event"
cat > "$CONFLICTING" <<'SH'
#!/usr/bin/env bash
event_id=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --event-id) event_id=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$event_id" ] || { echo 'stub: bridge sent no --event-id' >&2; exit 3; }
marker="$CONFLICT_STORE/$event_id"
if [ -e "$marker" ]; then
  echo 'brain-event: server avviste hendelsen (409): {"error":"event_conflict","message":"event_id finnes allerede med annet innhold eller identitet"}' >&2
  exit 2
fi
: > "$marker"
SH
chmod +x "$CONFLICTING"

CONFLICT_STORE="$CONFLICT_STORE" FM_BRAIN_EVENT_COMMAND="$CONFLICTING" \
  "$ROOT/bin/fm-brain-event.sh" activation-probe NOTE task-9 stable-identity safe \
  > "$CAPTURE.retry1" 2> "$CAPTURE.retry1.err"
[ ! -s "$CAPTURE.retry1.err" ] || fail "first delivery of a new event warned"

set +e
CONFLICT_STORE="$CONFLICT_STORE" FM_BRAIN_EVENT_COMMAND="$CONFLICTING" \
  "$ROOT/bin/fm-brain-event.sh" activation-probe NOTE task-9 stable-identity safe \
  > "$CAPTURE.retry2" 2> "$CAPTURE.retry2.err"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "an identical retry changed the lifecycle outcome"
[ ! -s "$CAPTURE.retry2.err" ] \
  || fail "an identical retry of an already-stored event still looked like a failure: $(cat "$CAPTURE.retry2.err")"
pass "fm-brain-event: an identical retry of an already-stored event is not a failure"

# A real rejection - wrong credential, unknown type, malformed payload - also
# exits 2 from the real client, and must still warn. The discriminator above
# must not swallow this.
REJECTED="$TMP_ROOT/rejected-brain-event"
cat > "$REJECTED" <<'SH'
#!/usr/bin/env bash
echo 'brain-event: server avviste hendelsen (401): {"error":"invalid_token","message":"scoped token er utlopt"}' >&2
exit 2
SH
chmod +x "$REJECTED"

set +e
FM_BRAIN_EVENT_COMMAND="$REJECTED" \
  "$ROOT/bin/fm-brain-event.sh" teardown TASK_DONE task-10 stable safe \
  > "$CAPTURE.rejected" 2> "$CAPTURE.rejected.err"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "a genuine rejection changed the lifecycle outcome"
grep -Fq 'lifecycle event was not accepted' "$CAPTURE.rejected.err" \
  || fail "a genuine 401 rejection was silently swallowed"
grep -Fq '"error":"invalid_token"' "$CAPTURE.rejected.err" \
  || fail "a genuine rejection lost the client's own diagnostic"
pass "fm-brain-event: a genuine rejection still warns"

# Capturing stderr must not censor a client that delivers the event and still
# has something to say - a degraded store, a locally queued event, a deprecation
# notice.
NOISY="$TMP_ROOT/noisy-brain-event"
cat > "$NOISY" <<'SH'
#!/usr/bin/env bash
echo 'brain-event: brain er degradert, hendelsen ble koet lokalt' >&2
SH
chmod +x "$NOISY"

set +e
FM_BRAIN_EVENT_COMMAND="$NOISY" \
  "$ROOT/bin/fm-brain-event.sh" spawn TASK_START task-11 stable safe \
  > "$CAPTURE.noisy" 2> "$CAPTURE.noisy.err"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "a delivered event with a client notice changed the lifecycle outcome"
grep -Fq 'koet lokalt' "$CAPTURE.noisy.err" \
  || fail "a successful delivery's own stderr was swallowed by the capture"
if grep -Fq 'lifecycle event was not accepted' "$CAPTURE.noisy.err"; then
  fail "a delivered event was reported as not accepted"
fi
pass "fm-brain-event: a delivered event's own diagnostics still reach the caller"
