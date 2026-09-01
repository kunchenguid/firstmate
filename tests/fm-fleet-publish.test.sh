#!/usr/bin/env bash
# Behavioral coverage for cadence publication of the canonical fleet snapshot:
# the disabled default, an enabled publish through the real producer, a failed
# producer leaving the previous published snapshot intact, and the atomicity a
# file-watching consumer depends on.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PUBLISH="$ROOT/bin/fm-fleet-publish.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-publish)
HOME_DIR="$TMP_ROOT/publish-home"
STUB_HOME="$TMP_ROOT/stub-home"
BOOT_HOME="$TMP_ROOT/boot-home"
DAEMON_PIDS=()

cleanup() {
  local record pid home
  for home in "$HOME_DIR" "$STUB_HOME" "$BOOT_HOME"; do
    record="$home/state/.fleet-publish-daemon"
    [ -f "$record" ] || continue
    pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "$record" 2>/dev/null | head -1)
    [ -n "$pid" ] && kill -KILL "$pid" >/dev/null 2>&1
  done
  for pid in ${DAEMON_PIDS[@]+"${DAEMON_PIDS[@]}"}; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

seed_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/projects"
  printf '# Seeded Firstmate home\n' > "$dir/AGENTS.md"
  cat > "$dir/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
}

seed_home "$HOME_DIR"
seed_home "$STUB_HOME"

run_publish() {  # <home> [env assignments handled by caller] <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$PUBLISH" "$@"
}

# --- 1. the disabled default ------------------------------------------------
#
# A home that configured nothing must publish nothing and must say so, because a
# home silently believing it publishes is the failure this mechanism removes.

out=$(run_publish "$HOME_DIR" status) \
  || fail "status must succeed on a home with no cadence configured"
case "$out" in
  *"publisher: disabled"*) ;;
  *) fail "an unconfigured home must report itself disabled, got: $out" ;;
esac

if run_publish "$HOME_DIR" start >/dev/null 2>&1; then
  fail "start must refuse a home with no cadence configured"
fi
if run_publish "$HOME_DIR" run >/dev/null 2>&1; then
  fail "run must refuse a home with no cadence configured"
fi
[ ! -e "$HOME_DIR/state/fleet-snapshot.json" ] \
  || fail "a disabled home must not publish a snapshot"
[ ! -e "$HOME_DIR/state/.fleet-publish-daemon" ] \
  || fail "a disabled home must not record a publisher"
pass "an unconfigured home reports itself disabled and publishes nothing"

# A present-but-unusable cadence is refused as unusable, never taken as a
# default, and the reason survives to the caller.
printf 'every-5s\n' > "$HOME_DIR/config/fleet-snapshot-cadence"
out=$(run_publish "$HOME_DIR" status)
case "$out" in
  *"publisher: misconfigured"*"one positive whole number of seconds"*) ;;
  *) fail "a malformed cadence must be reported as misconfigured, got: $out" ;;
esac
printf '3\n' > "$HOME_DIR/config/fleet-snapshot-cadence"
out=$(run_publish "$HOME_DIR" status)
case "$out" in
  *"publisher: misconfigured"*"floor"*) ;;
  *) fail "a cadence under the floor must be refused, got: $out" ;;
esac
if run_publish "$HOME_DIR" start >/dev/null 2>&1; then
  fail "start must refuse an unusable cadence rather than fall back to a default"
fi
pass "a malformed or too-small cadence is refused rather than silently defaulted"

# A cadence value too large for the shell to compare safely must be refused
# outright, not accepted through an overflowed floor comparison: `[ -lt ]` can
# fail with a nonzero exit on an oversized operand, which `if` reads as false,
# so an unbounded check would silently wave an absurd value through instead of
# refusing it.
printf '99999999999999999999\n' > "$HOME_DIR/config/fleet-snapshot-cadence"
out=$(run_publish "$HOME_DIR" status) \
  || fail "status must still succeed on an oversized cadence"
case "$out" in
  *"publisher: misconfigured"*"digit"*) ;;
  *) fail "an oversized cadence must be reported as misconfigured, got: $out" ;;
esac
if run_publish "$HOME_DIR" start >/dev/null 2>&1; then
  fail "start must refuse an oversized cadence rather than busy-loop with no pacing"
fi
if run_publish "$HOME_DIR" run >/dev/null 2>&1; then
  fail "run must refuse an oversized cadence rather than busy-loop with no pacing"
fi
pass "a cadence too large to compare safely is refused rather than accepted"

# --- 2. an enabled publish --------------------------------------------------
#
# Through the REAL producer, so the published bytes are proven to be a usable
# fm-fleet-snapshot.v1 for this home rather than whatever a stub agreed to emit.

printf '300\n' > "$HOME_DIR/config/fleet-snapshot-cadence"
run_publish "$HOME_DIR" publish >/dev/null \
  || fail "an enabled home must publish through the real producer"
jq -e --arg home "$HOME_DIR" '
  .schema == "fm-fleet-snapshot.v1"
  and .fm_home == $home
  and (.generated | type) == "string"
  and (.generated | length) > 0
  and (.tasks | type) == "array"
' "$HOME_DIR/state/fleet-snapshot.json" >/dev/null \
  || fail "the published artifact is not a usable fm-fleet-snapshot.v1 for this home"
out=$(run_publish "$HOME_DIR" status)
case "$out" in
  *"publisher: enabled cadence=300s"*) ;;
  *) fail "status must report the configured cadence, got: $out" ;;
esac
case "$out" in
  *"snapshot:"*"generated="*) ;;
  *) fail "status must read the published snapshot's own age, got: $out" ;;
esac
# The consumer's honesty depends on reading the age out of the artifact itself.
jq -e '.generated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' \
  "$HOME_DIR/state/fleet-snapshot.json" >/dev/null \
  || fail "the published artifact must carry its own parseable observation time"
pass "an enabled home publishes a schema-valid snapshot carrying its own age"

# --- the cadence loop itself ------------------------------------------------
#
# A fast stub producer keeps this bounded; the real producer already proved the
# schema above. What is under test here is that the detached publisher advances
# the artifact on its own and stops when the configuration goes away.

SEQ_FILE="$TMP_ROOT/stub-seq"
printf '0\n' > "$SEQ_FILE"
STUB="$TMP_ROOT/stub-snapshot.sh"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --json ] || exit 64
n=$(cat "$FM_TEST_SEQ_FILE" 2>/dev/null || echo 0)
n=$(( n + 1 ))
printf '%s\n' "$n" > "$FM_TEST_SEQ_FILE"
if [ -e "$FM_TEST_FAIL_FLAG" ]; then
  echo "stub producer refused on purpose" >&2
  exit 7
fi
printf '{"schema":"fm-fleet-snapshot.v1","generated":"2026-09-01T00:00:%02dZ","fm_home":"%s","roots":{},"backlog":{},"tasks":[],"marker":%s}\n' \
  "$(( n % 60 ))" "$FM_HOME" "$n"
SH
chmod +x "$STUB"

FAIL_FLAG="$TMP_ROOT/stub-fail"
printf '1\n' > "$STUB_HOME/config/fleet-snapshot-cadence"

run_stub() {  # <args...>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$STUB_HOME" \
    FM_TEST_SEQ_FILE="$SEQ_FILE" FM_TEST_FAIL_FLAG="$FAIL_FLAG" \
    FM_FLEET_PUBLISH_SNAPSHOT_CMD="$STUB" \
    FM_FLEET_PUBLISH_MIN_CADENCE=1 \
    FM_FLEET_PUBLISH_TICK_SECS=1 \
    FM_FLEET_PUBLISH_START_WAIT=30 \
    "$PUBLISH" "$@"
}

artifact_marker() {  # <home>
  jq -r '.marker // ""' "$1/state/fleet-snapshot.json" 2>/dev/null || true
}

wait_for_marker_beyond() {  # <home> <marker> [attempts]
  local home=$1 base=$2 attempts=${3:-300} i=0 got
  while [ "$i" -lt "$attempts" ]; do
    got=$(artifact_marker "$home")
    case "$got" in
      ''|*[!0-9]*) ;;
      *) [ "$got" -gt "$base" ] && return 0 ;;
    esac
    sleep 0.2
    i=$(( i + 1 ))
  done
  return 1
}

run_stub start >/dev/null || fail "the publisher did not start on a configured home"
daemon_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' \
  "$STUB_HOME/state/.fleet-publish-daemon" 2>/dev/null | head -1)
[ -n "$daemon_pid" ] || fail "a started publisher must record its pid"
DAEMON_PIDS+=("$daemon_pid")

wait_for_marker_beyond "$STUB_HOME" 0 \
  || fail "the publisher did not publish a first snapshot"
first=$(artifact_marker "$STUB_HOME")
wait_for_marker_beyond "$STUB_HOME" "$first" \
  || fail "the publisher did not republish on its cadence without being asked"
pass "a detached publisher republishes the snapshot on its own cadence"

# The publisher runs in its own process group and outlives the shell that
# started it: that is what lets the artifact keep advancing with no agent alive.
ppid=$(ps -o ppid= -p "$daemon_pid" 2>/dev/null | tr -d '[:space:]')
[ "$ppid" != "$$" ] \
  || fail "the publisher must not remain a child of the shell that started it"
pgid=$(ps -o pgid= -p "$daemon_pid" 2>/dev/null | tr -d '[:space:]')
[ "$pgid" = "$daemon_pid" ] \
  || fail "the publisher must run in its own process group, got pgid=$pgid"
pass "the publisher is detached from the shell and process group that started it"

# A second start is idempotent rather than a second publisher.
out=$(run_stub start) || fail "a second start must succeed"
case "$out" in
  *"already running"*) ;;
  *) fail "a second start must attach to the running publisher, got: $out" ;;
esac
pass "starting an already-running publisher does not start a second one"

# A crash leaves the singleton lock, the record, and the beacon behind. Coming
# back from exactly that is what the session-start arming exists for, so it is
# proven rather than assumed.
kill -KILL "$daemon_pid" 2>/dev/null || true
attempts=0
while [ "$attempts" -lt 100 ]; do
  kill -0 "$daemon_pid" 2>/dev/null || break
  sleep 0.1
  attempts=$(( attempts + 1 ))
done
[ -e "$STUB_HOME/state/.fleet-publish-daemon.lock" ] \
  || fail "a crashed publisher must leave its singleton lock behind for this case to mean anything"
out=$(run_stub status)
case "$out" in
  *"daemon=stopped"*) ;;
  *) fail "a crashed publisher must not still read as running, got: $out" ;;
esac
run_stub start >/dev/null || fail "start must recover from a crashed publisher's leftovers"
daemon_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' \
  "$STUB_HOME/state/.fleet-publish-daemon" 2>/dev/null | head -1)
[ -n "$daemon_pid" ] || fail "the recovered publisher recorded no pid"
DAEMON_PIDS+=("$daemon_pid")
kill -0 "$daemon_pid" 2>/dev/null || fail "the recovered publisher is not running"
recovered=$(artifact_marker "$STUB_HOME")
wait_for_marker_beyond "$STUB_HOME" "$recovered" \
  || fail "the recovered publisher did not resume its cadence"
pass "a crashed publisher is recovered by the next start rather than blocking it"

# Stopping acts on the same evidence status reports on, so a recorded pid a
# reboot handed to something else is never the thing that gets signalled.
DECOY_PID=
( exec -a fm-fleet-publish-decoy sleep 120 ) >/dev/null 2>&1 &
DECOY_PID=$!
DAEMON_PIDS+=("$DECOY_PID")
saved_record=$(cat "$STUB_HOME/state/.fleet-publish-daemon")
saved_beat_ref="$TMP_ROOT/beat-ref"
touch -r "$STUB_HOME/state/.fleet-publish-beat" "$saved_beat_ref"
printf 'pid=%s\nstarted=seeded\ncadence=1\n' "$DECOY_PID" \
  > "$STUB_HOME/state/.fleet-publish-daemon"
touch -t 202001010000 "$STUB_HOME/state/.fleet-publish-beat"
if run_stub stop >/dev/null 2>&1; then
  fail "stop must refuse a recorded pid that is not beating"
fi
kill -0 "$DECOY_PID" 2>/dev/null \
  || fail "stop signalled a live process that was not the publisher"
printf '%s\n' "$saved_record" > "$STUB_HOME/state/.fleet-publish-daemon"
touch -r "$saved_beat_ref" "$STUB_HOME/state/.fleet-publish-beat"
kill -KILL "$DECOY_PID" >/dev/null 2>&1 || true
wait "$DECOY_PID" >/dev/null 2>&1 || true
DECOY_PID=
pass "stop refuses a recorded pid that is not beating instead of signalling it"

# --- 3. a failed producer leaves the previous snapshot intact ---------------
#
# Degrading to stale is correct. Degrading to absent or truncated is not: the
# consumer's own honesty depends on still being able to say how old this is.

before=$(cat "$STUB_HOME/state/fleet-snapshot.json")
before_marker=$(artifact_marker "$STUB_HOME")
: > "$FAIL_FLAG"
# Let the running publisher take at least two failing turns.
attempts=0
seq_at_flag=$(cat "$SEQ_FILE")
while [ "$attempts" -lt 200 ]; do
  now_seq=$(cat "$SEQ_FILE" 2>/dev/null || echo 0)
  [ "$now_seq" -ge $(( seq_at_flag + 2 )) ] && break
  sleep 0.2
  attempts=$(( attempts + 1 ))
done
[ "$attempts" -lt 200 ] || fail "the publisher never attempted a failing read"

after=$(cat "$STUB_HOME/state/fleet-snapshot.json")
[ "$before" = "$after" ] \
  || fail "a failed snapshot read must leave the published snapshot byte-identical"
[ "$(artifact_marker "$STUB_HOME")" = "$before_marker" ] \
  || fail "a failed snapshot read must not advance the published snapshot"
grep -q 'snapshot read failed with exit 7' "$STUB_HOME/state/.fleet-publish.log" \
  || fail "a failed snapshot read must be recorded with its reason"
# No temporary file may be left behind at, or beside, the artifact.
leftovers=$(find "$STUB_HOME/state" -maxdepth 1 -name '.fleet-snapshot.json.*' 2>/dev/null | wc -l)
[ "$(printf '%s' "$leftovers" | tr -d '[:space:]')" = 0 ] \
  || fail "a failed publish must not leave a temporary publication file behind"
pass "a failed snapshot read leaves the previous published snapshot intact"

# A one-shot publish reports the failure to its caller instead of exiting clean.
if run_stub publish >/dev/null 2>&1; then
  fail "a one-shot publish must exit non-zero when the producer fails"
fi
rm -f "$FAIL_FLAG"
wait_for_marker_beyond "$STUB_HOME" "$before_marker" \
  || fail "the publisher must resume publishing once the producer recovers"
pass "publication resumes on its own once the producer recovers"

# --- the daemon honours a configuration that goes away ----------------------

rm -f "$STUB_HOME/config/fleet-snapshot-cadence"
attempts=0
while [ "$attempts" -lt 300 ]; do
  kill -0 "$daemon_pid" 2>/dev/null || break
  sleep 0.2
  attempts=$(( attempts + 1 ))
done
kill -0 "$daemon_pid" 2>/dev/null \
  && fail "removing the cadence must stop the running publisher"
[ -s "$STUB_HOME/state/fleet-snapshot.json" ] \
  || fail "stopping the publisher must leave the last published snapshot in place"
pass "removing the cadence stops the publisher and leaves the snapshot in place"

# --- 4. atomicity -----------------------------------------------------------
#
# A consumer that watches the file must never observe a half-written document.
# A slow producer emitting a large payload makes the write window wide enough to
# catch, and a reader loop asserts every observation is a whole document.

ATOMIC_HOME="$TMP_ROOT/atomic-home"
seed_home "$ATOMIC_HOME"
printf '300\n' > "$ATOMIC_HOME/config/fleet-snapshot-cadence"

SLOW_STUB="$TMP_ROOT/slow-snapshot.sh"
cat > "$SLOW_STUB" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --json ] || exit 64
filler=$(printf 'x%.0s' $(seq 1 200))
printf '{"schema":"fm-fleet-snapshot.v1","generated":"2026-09-01T00:01:00Z",'
printf '"fm_home":"%s","roots":{},"backlog":{},"marker":2,"tasks":[' "$FM_HOME"
i=0
while [ "$i" -lt 400 ]; do
  [ "$i" -eq 0 ] || printf ','
  printf '{"id":"task-%s","filler":"%s"}' "$i" "$filler"
  i=$(( i + 1 ))
  case $(( i % 40 )) in 0) sleep 0.2 ;; esac
done
printf ']}\n'
SH
chmod +x "$SLOW_STUB"

# Seed a complete previous document, so "the previous whole one" is a real
# alternative a reader can legitimately observe.
FAST_STUB="$TMP_ROOT/fast-snapshot.sh"
cat > "$FAST_STUB" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --json ] || exit 64
printf '{"schema":"fm-fleet-snapshot.v1","generated":"2026-09-01T00:00:01Z","fm_home":"%s","roots":{},"backlog":{},"tasks":[],"marker":1}\n' "$FM_HOME"
SH
chmod +x "$FAST_STUB"

FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ATOMIC_HOME" \
  FM_FLEET_PUBLISH_SNAPSHOT_CMD="$FAST_STUB" "$PUBLISH" publish >/dev/null \
  || fail "seeding the previous published snapshot failed"

# The reader is bounded by the publish itself, not by a wall clock, so the
# window it samples is exactly the window a torn write could appear in.
READER_VERDICT="$TMP_ROOT/reader-verdict"
READER_TEMPS="$TMP_ROOT/reader-temps"
: > "$READER_VERDICT"
: > "$READER_TEMPS"

FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ATOMIC_HOME" \
  FM_FLEET_PUBLISH_SNAPSHOT_CMD="$SLOW_STUB" \
  FM_FLEET_PUBLISH_TIMEOUT=120 "$PUBLISH" publish >/dev/null 2>&1 &
PUBLISH_PID=$!
DAEMON_PIDS+=("$PUBLISH_PID")

sample_artifact() {
  local marker
  marker=$(jq -r '.marker // "PARSE_FAILED"' \
    "$ATOMIC_HOME/state/fleet-snapshot.json" 2>/dev/null) || marker=PARSE_FAILED
  [ -n "$marker" ] || marker=PARSE_FAILED
  printf '%s\n' "$marker" >> "$READER_VERDICT"
  # A visible (non dot-prefixed) temporary beside the artifact would be a
  # directory-change event a watching consumer could try to read.
  find "$ATOMIC_HOME/state" -maxdepth 1 -name 'fleet-snapshot.json.*' 2>/dev/null \
    >> "$READER_TEMPS"
}

while kill -0 "$PUBLISH_PID" 2>/dev/null; do
  sample_artifact
done
wait "$PUBLISH_PID" || fail "the slow atomic publish failed"
sample_artifact

reads=$(grep -c . "$READER_VERDICT" 2>/dev/null || echo 0)
[ "$reads" -ge 5 ] || fail "the atomicity reader observed too few reads ($reads) to prove anything"
if grep -qv '^[12]$' "$READER_VERDICT"; then
  fail "a reader observed something other than a whole previous or next snapshot: $(sort -u "$READER_VERDICT" | tr '\n' ' ')"
fi
grep -q '^1$' "$READER_VERDICT" \
  || fail "the reader never observed the previous whole snapshot during the write"
grep -q '^2$' "$READER_VERDICT" \
  || fail "the reader never observed the next whole snapshot"
[ ! -s "$READER_TEMPS" ] \
  || fail "a visible temporary file appeared beside the published snapshot: $(head -1 "$READER_TEMPS")"
jq -e '.marker == 2 and (.tasks | length) == 400' \
  "$ATOMIC_HOME/state/fleet-snapshot.json" >/dev/null \
  || fail "the completed publish did not replace the artifact with the whole new document"
pass "a publish is atomic: a reader sees the previous whole snapshot or the next one"

# --- session-start arming ---------------------------------------------------
#
# The publisher has to come back on its own after a reboot or a crash, so a
# locked session boundary arms it. An opted-out home must pay nothing there, and
# an unusable configuration must reach the agent as an actionable line rather
# than a home that quietly stopped publishing.

seed_home "$BOOT_HOME"
run_bootstrap() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BOOT_HOME" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" check 2>&1
}

out=$(run_bootstrap)
case "$out" in
  *FLEET_PUBLISH*) fail "session start must say nothing about publishing on a home that did not opt in" ;;
esac
[ ! -e "$BOOT_HOME/state/.fleet-publish-daemon" ] \
  || fail "session start must not arm a publisher on a home that did not opt in"
pass "session start leaves a home that did not opt in alone"

printf 'never\n' > "$BOOT_HOME/config/fleet-snapshot-cadence"
out=$(run_bootstrap)
case "$out" in
  *"FLEET_PUBLISH: config/fleet-snapshot-cadence must be one positive whole number of seconds"*) ;;
  *) fail "session start must report an unusable cadence as an actionable line, got: $out" ;;
esac
case "$out" in
  *"FLEET_PUBLISH: fm-fleet-publish:"*) fail "the reported line must carry one prefix, not two" ;;
esac
pass "session start reports an unusable cadence instead of publishing nothing quietly"

printf '300\n' > "$BOOT_HOME/config/fleet-snapshot-cadence"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BOOT_HOME" FM_BOOTSTRAP_NETWORK=skip \
  FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" check >/dev/null 2>&1
[ ! -e "$BOOT_HOME/state/.fleet-publish-daemon" ] \
  || fail "a read-only session start must not arm a publisher"
pass "a read-only session start arms no publisher"

out=$(run_bootstrap)
case "$out" in
  *FLEET_PUBLISH*) fail "session start must arm the publisher silently when it works, got: $out" ;;
esac
boot_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' \
  "$BOOT_HOME/state/.fleet-publish-daemon" 2>/dev/null | head -1)
[ -n "$boot_pid" ] || fail "session start must arm a publisher on an opted-in home"
DAEMON_PIDS+=("$boot_pid")
kill -0 "$boot_pid" 2>/dev/null || fail "the publisher session start armed is not running"
pass "session start arms the publisher on an opted-in home"
