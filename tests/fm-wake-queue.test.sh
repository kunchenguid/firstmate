#!/usr/bin/env bash
# tests/fm-wake-queue.test.sh - wake-queue losslessness (the queue safety matrix):
# concurrent append/drain, bounded structural enrichment, interruption safety,
# signal catch-up while no watcher runs, stale/check enqueue-before-suppressor
# ordering, atomic double-drain, duplicate collapse, and liveness assertion.
# Nothing is lost and nothing is double-consumed. General watcher/lock liveness
# lives in fm-watcher-lock.test.sh; daemon classification/injection in
# fm-daemon.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-tests)


test_concurrent_append_and_drain() {
  local dir state out1 out2 all pids i pid count unique malformed
  dir=$(make_case concurrent)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    append_wake "$state" signal "status-$i" "signal: $state/status-$i.status" &
    pids="$pids $!"
    i=$((i + 1))
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pids="$pids $!"
  for pid in $pids; do
    wait "$pid" || fail "concurrent append/drain subprocess failed"
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" || fail "final drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 40 ] || fail "expected 40 drained records, got $count"
  malformed=$(awk -F '\t' 'NF != 5 { bad++ } END { print bad + 0 }' "$all")
  [ "$malformed" -eq 0 ] || fail "drained records had malformed fields"
  unique=$(awk -F '\t' '{ keys[$4] = 1 } END { for (k in keys) count++; print count + 0 }' "$all")
  [ "$unique" -eq 40 ] || fail "expected 40 unique keys, got $unique"
  pass "concurrent append plus drain preserves queue records"
}

test_signal_catchup_without_running_watcher() {
  local dir state fakebin out drain_out status_file
  dir=$(make_case signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  status_file="$state/task.status"
  # The durable-queue catch-up contract applies to ACTIONABLE wakes (the always-on
  # watcher can absorb no-verb working: notes when the crew is provably working).
  # Use a captain-relevant verb so the wake is surfaced and the catch-up path is
  # tested.
  printf 'blocked: first\n' > "$status_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for first signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print first signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after first signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "first signal was not queued"

  printf 'done: second\n' >> "$status_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for second signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "signal written with no watcher was not caught"
  pass "signal written while no watcher runs is caught on next run"
}

test_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stale"
  printf 'idle prompt' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stale.meta"
  # A stale pane sitting on a captain-relevant status is actionable when the crew
  # is not provably working, so give the window one and prime the .seen-* marker
  # to its current signature so the per-poll signal scan does not pre-empt the
  # stale wake with a signal wake.
  printf 'done: ready in branch fm/stale\n' > "$state/stale.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$state/stale.status"); else sig=$(stat -c '%s:%Y' "$state/stale.status"); fi
  printf '%s' "$sig" > "$state/.seen-stale_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for stale pane"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not written"
  pass "stale wake is queued before suppressor state is advanced"
}

# Absorb-only-when-provably-working adds a new actionable wake: a non-terminal stale
# whose crew is NOT provably working is surfaced immediately. That new path must keep
# the queue-safety invariant - enqueue the stale wake BEFORE advancing the .stale-*
# suppressor - so a watcher killed between the two never swallows the surfaced finish.
test_not_working_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale-stopped)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (no captain-relevant verb); prime .seen-* so the per-poll
  # signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$state/stopped.status"); else sig=$(stat -c '%s:%Y' "$state/stopped.status"); fi
  printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # NOT provably working: no running pipeline, idle pane. (make_case installed the
  # fake fm-crew-state.sh the watcher reads via FM_CREW_STATE_BIN.)
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not surface a not-provably-working stale"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after the immediate stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced after the enqueue"
  unset FM_FAKE_CREW_STATE
  pass "a not-provably-working stale wake is queued before its suppressor is advanced"
}

test_check_output_is_queued() {
  local dir state fakebin out drain_out check_file
  dir=$(make_case check)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/1\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register queue custom check"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for check output"
  grep -F "check: $check_file: merged: https://example.test/pr/1" "$out" >/dev/null || fail "watcher did not print check wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after check wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/1' >/dev/null || fail "check wake was not queued"
  [ -e "$state/.last-check" ] || fail "check cadence marker was not written after queue append"
  pass "registered custom check output is queued before cadence suppression"
}

test_atomic_double_drain() {
  local dir state out1 out2 all count leftover
  dir=$(make_case double-drain)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  append_wake "$state" signal task "signal: $state/task.status" || fail "signal append failed"
  append_wake "$state" stale 's:fm-task' 'stale: s:fm-task' || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pid1=$!
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" &
  pid2=$!
  wait "$pid1" || fail "first drain failed"
  wait "$pid2" || fail "second drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 3 ] || fail "two drains consumed records more than once or lost records; got $count"
  leftover=$(FM_STATE_OVERRIDE="$state" "$DRAIN" | awk 'NF { count++ } END { print count + 0 }')
  [ "$leftover" -eq 0 ] || fail "queue was not empty after double drain"
  pass "two atomic drains cannot consume the same records twice"
}

test_drain_dedupes_obvious_duplicates() {
  local dir state out count
  dir=$(make_case dedupe)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "first heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "first signal append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "second heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status $state/task.turn-ended" || fail "second signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "dedupe drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected 2 deduped records, got $count"
  grep "$(printf '\theartbeat\theartbeat\theartbeat')" "$out" >/dev/null || fail "heartbeat was not preserved"
  grep "$(printf '\tsignal\ttask.status\t')" "$out" | grep -F "$state/task.turn-ended" >/dev/null || fail "latest signal payload was not preserved"
  pass "drain collapses obvious duplicate heartbeat and signal records"
}

# The drain runs at the top of every wake-handling turn, so it also asserts
# watcher liveness via fm-guard.sh: a lapsed re-arm chain then surfaces even on a
# plain drain-and-handle turn that runs no other supervision script. It must warn
# when work is in flight with no live watcher, and stay silent right after a
# normal fire (a fresh beacon within grace), so it never false-alarms every wake.
test_drain_asserts_watcher_liveness() {
  local dir state err
  dir=$(make_case drain-liveness)
  state="$dir/state"
  err="$dir/drain.err"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || fail "drain failed while asserting liveness"
  grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "drain did not surface the watcher-down banner with work in flight and no live watcher"
  : > "$err"
  touch "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$DRAIN" >/dev/null 2> "$err" || fail "drain failed with a fresh beacon"
  if grep -F 'WATCHER DOWN' "$err" >/dev/null; then
    fail "drain false-alarmed right after a normal fire (fresh beacon within grace)"
  fi
  pass "drain asserts watcher liveness: warns on a lapse, stays silent right after a fire"
}

test_structural_signal_enrichment_preserves_raw_rows() {
  local dir state out expected actual annotation_count outside perl_bin
  dir=$(make_case enrichment)
  state="$dir/state"
  out="$dir/drain.out"
  expected="$dir/expected.out"
  actual="$dir/actual.out"
  outside="$dir/outside-secret"
  printf 'working: first\n\ndone: latest event\n' > "$state/task.status"
  printf 'working: old turn-end context\n' > "$state/turn-only.status"
  printf 'must-not-be-read\n' > "$outside"
  ln -s "$outside" "$state/escape.status"
  perl_bin=$(command -v perl) || fail "perl is required for safe status reads"
  cat > "$dir/fakebin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -MFcntl=:DEFAULT ]; then
  for arg in "$@"; do
    if [ "$arg" = "${FM_WAKE_ENRICH_SWAP_PATH:-}" ]; then
      rm -f "$arg"
      ln -s "$FM_WAKE_ENRICH_SWAP_TARGET" "$arg"
      break
    fi
  done
fi
exec "$FM_WAKE_ENRICH_REAL_PERL" "$@"
SH
  chmod +x "$dir/fakebin/perl"

  append_wake "$state" signal task.status "signal: $outside" || fail "direct status wake append failed"
  append_wake "$state" signal task.turn-ended "signal: $outside" || fail "coalesced turn-end wake append failed"
  append_wake "$state" signal turn-only.turn-ended "signal: $outside" || fail "bare turn-end wake append failed"
  append_wake "$state" signal escape.status "signal: $outside" || fail "symlink status wake append failed"
  append_wake "$state" signal arbitrary-key "signal: $outside" || fail "non-status signal wake append failed"
  append_wake "$state" check task.check.sh "check: complete payload" || fail "check wake append failed"
  append_wake "$state" stale test:fm-task "stale: test:fm-task" || fail "stale wake append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat wake append failed"

  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_print_deduped "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state/.wake-queue" > "$expected"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WAKE_ENRICH_SWAP_PATH="$state/task.status" \
    FM_WAKE_ENRICH_SWAP_TARGET="$outside" FM_WAKE_ENRICH_REAL_PERL="$perl_bin" "$DRAIN" > "$out" \
    || fail "structural enrichment drain failed"
  awk -F '\t' 'NF == 5 { print }' "$out" > "$actual"
  cmp -s "$expected" "$actual" || fail "enrichment changed or reordered an authoritative raw row"

  annotation_count=$(grep -c '^wake annotation:' "$out" || true)
  [ "$annotation_count" -eq 1 ] || fail "expected only the unreadable-race-safe status annotation, got $annotation_count"
  if grep -E '^wake annotation:.*: task\.status:' "$out" >/dev/null; then
    fail "replaced status file produced an annotation"
  fi
  grep -F 'latest wake-EVENT observed at drain, not current state; historical / not necessarily the triggering event: turn-only.status:' "$out" >/dev/null \
    || fail "bare turn-end mapping did not carry the historical warning"
  if grep -F 'must-not-be-read' "$out" >/dev/null; then
    fail "drain trusted a payload path or followed an out-of-state status symlink"
  fi
  pass "structural signal enrichment is separate, deduped, home-local, and tier-zero for other wakes"
}

test_enrichment_caps_and_status_file_failures() {
  local dir state out fake_perl_log perl_bin i raw_count annotation_bytes annotation_count oversized_lines perl_reads
  dir=$(make_case caps)
  state="$dir/state"
  out="$dir/drain.out"
  fake_perl_log="$dir/perl.log"
  perl_bin=$(command -v perl) || fail "perl is required for safe status reads"
  cat > "$dir/fakebin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -MFcntl=:DEFAULT ]; then
  printf 'read\n' >> "$FM_WAKE_ENRICH_PERL_LOG"
fi
exec "$FM_WAKE_ENRICH_REAL_PERL" "$@"
SH
  chmod +x "$dir/fakebin/perl"
  awk 'BEGIN { printf "done: "; for (i = 0; i < 20000; i++) printf "x"; printf "\n" }' > "$state/huge.status"
  append_wake "$state" signal huge.status "signal: huge" || fail "huge status wake append failed"
  i=1
  while [ "$i" -le 8 ]; do
    awk -v n="$i" 'BEGIN { printf "working-%d: ", n; for (j = 0; j < 3000; j++) printf "y"; printf "\n" }' > "$state/many-$i.status"
    append_wake "$state" signal "many-$i.status" "signal: many-$i" || fail "many-status wake append failed"
    i=$((i + 1))
  done
  : > "$state/empty.status"
  append_wake "$state" signal empty.status "signal: empty" || fail "empty status wake append failed"
  append_wake "$state" signal missing.status "signal: missing" || fail "missing status wake append failed"
  mkdir "$state/malformed.status"
  append_wake "$state" signal malformed.status "signal: malformed" || fail "malformed status wake append failed"
  printf 'done: unreadable\n' > "$state/unreadable.status"
  chmod 000 "$state/unreadable.status"
  append_wake "$state" signal unreadable.status "signal: unreadable" || fail "unreadable status wake append failed"

  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WAKE_ENRICH_PERL_LOG="$fake_perl_log" \
    FM_WAKE_ENRICH_REAL_PERL="$perl_bin" "$DRAIN" > "$out" \
    || fail "capped enrichment drain failed"
  raw_count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out")
  [ "$raw_count" -eq 13 ] || fail "missing, unreadable, malformed, empty, or oversized status input hid a raw row"
  grep '^wake annotation:.*\[truncated\]$' "$out" >/dev/null || fail "per-item/input truncation marker was not emitted"
  grep -E '^wake annotation: [1-9][0-9]* annotations omitted \(global enrichment byte cap\)$' "$out" >/dev/null \
    || fail "global omitted-annotation marker was not emitted"
  annotation_bytes=$(LC_ALL=C awk '/^wake annotation:/ { bytes += length($0) + 1 } END { print bytes + 0 }' "$out")
  [ "$annotation_bytes" -le 8192 ] || fail "global annotation output exceeded 8192 bytes ($annotation_bytes)"
  oversized_lines=$(LC_ALL=C awk '/^wake annotation: latest/ && length($0) + 1 > 2048 { count++ } END { print count + 0 }' "$out")
  [ "$oversized_lines" -eq 0 ] || fail "a per-item annotation exceeded 2048 bytes"
  annotation_count=$(grep -c '^wake annotation: latest' "$out" || true)
  [ "$annotation_count" -lt 9 ] || fail "global cap did not omit any of the nine readable status annotations"
  perl_reads=$(wc -l < "$fake_perl_log" | tr -d ' ')
  [ "$perl_reads" -eq 8 ] || fail "enrichment read cap allowed $perl_reads safe reads instead of 8"
  grep -E '^wake annotation: [1-9][0-9]* annotations omitted \(enrichment read cap\)$' "$out" >/dev/null \
    || fail "enrichment read-cap omission marker was not emitted"
  if grep -E ': (empty|missing|malformed|unreadable)\.status:' "$out" >/dev/null; then
    fail "missing, unreadable, malformed, or empty status file produced an annotation"
  fi
  pass "bounded reads and per-item/global caps fail open with explicit truncation and omission markers"
}

wait_for_file_text() {  # <file> <fixed-text>
  local file=$1 expected=$2 i=0
  while [ "$i" -lt 100 ]; do
    grep -F "$expected" "$file" >/dev/null 2>&1 && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_slow_annotation_does_not_block_append_and_deleted_file_fails_open() {
  local dir state out1 out2 pid
  dir=$(make_case slow-annotation)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  printf 'done: disappears before bounded read\n' > "$state/slow.status"
  append_wake "$state" signal slow.status "signal: slow" || fail "slow status wake append failed"

  FM_STATE_OVERRIDE="$state" FM_WAKE_ENRICH_TEST_DELAY=3 "$DRAIN" > "$out1" &
  pid=$!
  wait_for_file_text "$out1" "$(printf '\tsignal\tslow.status\t')" \
    || { kill "$pid" 2>/dev/null || true; fail "slow drain did not commit its raw row"; }
  printf 'done: appended while first drain annotates\n' > "$state/next.status"
  append_wake "$state" signal next.status "signal: next" || fail "append blocked or failed during annotation"
  kill -0 "$pid" 2>/dev/null || fail "slow annotation finished before the concurrent append proved lock independence"
  rm -f "$state/slow.status"
  wait "$pid" || fail "deleted status file made the committed drain fail"
  grep -F "$(printf '\tsignal\tslow.status\t')" "$out1" >/dev/null || fail "deleted status file hid the committed raw row"
  if grep -F ': slow.status:' "$out1" >/dev/null; then
    fail "status deleted during annotation still produced an annotation"
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" || fail "follow-up drain after concurrent append failed"
  grep -F "$(printf '\tsignal\tnext.status\t')" "$out2" >/dev/null || fail "concurrent append was not left for the next drain"
  pass "slow annotation releases the append lock and a deleted status file fails open"
}

test_interruption_before_and_after_raw_commit() {
  local dir state before_out after_out replay_out empty_out pid rc count i
  dir=$(make_case interruption)
  state="$dir/state"
  before_out="$dir/before.out"
  after_out="$dir/after.out"
  replay_out="$dir/replay.out"
  empty_out="$dir/empty.out"
  printf 'done: interruption fixture\n' > "$state/task.status"
  append_wake "$state" signal task.status "signal: task" || fail "pre-commit interruption wake append failed"

  FM_STATE_OVERRIDE="$state" FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT=5 "$DRAIN" > "$before_out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && ! compgen -G "$state/.wake-queue.drain.*" >/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  compgen -G "$state/.wake-queue.drain.*" >/dev/null || { kill "$pid" 2>/dev/null || true; fail "pre-commit drain never rotated the queue"; }
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt drain before raw commitment"
  set +e
  wait "$pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "pre-commit interruption unexpectedly succeeded"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$replay_out" || fail "restored pre-commit wake did not drain"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$replay_out")
  [ "$count" -eq 1 ] || fail "pre-commit interruption lost or duplicated the restored row"

  append_wake "$state" signal task.status "signal: task after commit" || fail "post-commit interruption wake append failed"
  FM_STATE_OVERRIDE="$state" FM_WAKE_ENRICH_TEST_DELAY=5 "$DRAIN" > "$after_out" &
  pid=$!
  wait_for_file_text "$after_out" "$(printf '\tsignal\ttask.status\t')" \
    || { kill "$pid" 2>/dev/null || true; fail "post-commit drain did not print its raw row"; }
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt drain after raw commitment"
  set +e
  wait "$pid"
  set -e
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$empty_out" || fail "drain after post-commit interruption failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$after_out" "$empty_out")
  [ "$count" -eq 1 ] || fail "post-commit interruption restored or duplicated the consumed row"
  pass "interruptions restore before commitment and never replay after raw commitment"
}

test_concurrent_append_and_drain
test_signal_catchup_without_running_watcher
test_stale_enqueue_before_suppressor
test_not_working_stale_enqueue_before_suppressor
test_check_output_is_queued
test_atomic_double_drain
test_drain_dedupes_obvious_duplicates
test_drain_asserts_watcher_liveness
test_structural_signal_enrichment_preserves_raw_rows
test_enrichment_caps_and_status_file_failures
test_slow_annotation_does_not_block_append_and_deleted_file_fails_open
test_interruption_before_and_after_raw_commit
