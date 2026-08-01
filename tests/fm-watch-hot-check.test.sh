#!/usr/bin/env bash
# Tests for bin/fm-watch.sh's hot-check fast path: a check may pair
# state/<id>.check.sh with a sibling state/<id>.check-hot marker naming an
# events-pending file, so it runs immediately (through the same trusted
# dispatch as the CHECK_INTERVAL sweep) instead of waiting out the sweep
# window. Uses the same bounded foreground checkpoint wrapper as
# fm-watch-checkpoint.test.sh, since check dispatch does not depend on any
# recorded tmux window.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-hot-check)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

# install_check <home> <id> <script-body>: write and register a valid custom
# check under <id>, returning nothing (the caller reads state/<id>.check.sh).
install_check() {
  local home=$1 id=$2 body=$3
  printf '%s\n' "$body" > "$home/state/$id.check.sh"
  chmod 0700 "$home/state/$id.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null \
    || fail "could not register check $id"
}

# install_hot_marker <home> <id> <events-file>: pair a check with a hot marker
# naming <events-file> (created if absent, left untouched otherwise).
install_hot_marker() {
  local home=$1 id=$2 events=$3
  printf '%s\n' "$events" > "$home/state/$id.check-hot"
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

test_hot_marker_fires_before_sweep_interval() {
  local home events out err status
  home=$(make_home fires)
  events="$home/data/hotid.events"
  mkdir -p "$home/data"
  printf 'event\n' > "$events"
  install_check "$home" hotid $'#!/usr/bin/env bash\nprintf "hot check fired\\n"'
  install_hot_marker "$home" hotid "$events"
  # A fresh .last-check keeps this cycle's sweep gate genuinely not-due (a
  # missing .last-check reads as maximally stale and would sweep once on its
  # own on the very first cycle), isolating the assertion to the hot path.
  touch "$home/state/.last-check"
  out="$home/out.txt"; err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "hot marker checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "hot-triggered check did not produce a check wake"
  assert_contains "$(cat "$out")" "hot check fired" "hot-triggered check output missing"
  pass "a non-empty events file fires its paired check well inside the sweep window"
}

test_empty_events_file_does_not_fire() {
  local home events out err status
  home=$(make_home empty)
  events="$home/data/hotid.events"
  mkdir -p "$home/data"
  : > "$events"
  install_check "$home" hotid $'#!/usr/bin/env bash\nprintf "should-not-fire\\n"'
  install_hot_marker "$home" hotid "$events"
  touch "$home/state/.last-check"
  out="$home/out.txt"; err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 3 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "empty-events-file checkpoint exit"
  assert_not_contains "$(cat "$out")" "should-not-fire" "check ran despite an empty events file"
  pass "an empty (or missing) events file never triggers the hot path"
}

test_hot_marker_without_matching_check_is_noop() {
  local home events out err status
  home=$(make_home orphan)
  events="$home/data/orphan.events"
  mkdir -p "$home/data"
  printf 'event\n' > "$events"
  install_hot_marker "$home" orphan "$events"
  touch "$home/state/.last-check"
  out="$home/out.txt"; err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 3 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "orphan hot-marker checkpoint exit"
  pass "a check-hot marker with no matching check.sh is a silent no-op"
}

test_hot_path_never_touches_last_check() {
  local home events out err status before after
  home=$(make_home lastcheck)
  events="$home/data/hotid.events"
  mkdir -p "$home/data"
  printf 'event\n' > "$events"
  install_check "$home" hotid $'#!/usr/bin/env bash\nprintf "hot check fired\\n"'
  install_hot_marker "$home" hotid "$events"
  touch "$home/state/.last-check"
  before=$(file_mtime "$home/state/.last-check")
  out="$home/out.txt"; err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "hot marker (last-check probe) checkpoint exit"
  assert_contains "$(cat "$out")" "hot check fired" "hot path did not fire despite a fresh .last-check"
  after=$(file_mtime "$home/state/.last-check")
  [ "$before" = "$after" ] || fail ".last-check mtime changed from a hot run ($before -> $after); the sweep cadence must stay independent of hot activity"
  pass "a hot run fires independently of .last-check and never advances the sweep's own timer"
}

test_hot_marker_never_bypasses_check_trust() {
  local home events out pid i ran_marker
  home=$(make_home tamper)
  events="$home/data/hotid.events"
  ran_marker="$home/state/hotid.tampered-run.marker"
  mkdir -p "$home/data"
  printf 'event\n' > "$events"
  install_check "$home" hotid $'#!/usr/bin/env bash\nexit 0'
  out="$home/out.txt"
  # Run the real watcher (not the bounded checkpoint) in the background so it
  # is long-lived past its own startup: fm-pr-check-migrate.sh already
  # quarantines any *.check.sh whose bytes mismatch its trust hash BEFORE the
  # main loop starts, which would confound this test by removing the file
  # before hot_check_scan ever saw it. Tampering only after the watcher is
  # confirmed past that one-time startup step isolates the assertion to the
  # live sweep/hot rejection path this feature adds.
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$ROOT/bin/fm-watch.sh" >"$out" 2>&1 &
  pid=$!
  i=0
  while [ ! -e "$home/state/.pr-check-migration-v1" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  assert_present "$home/state/.pr-check-migration-v1" "startup migration never completed"
  assert_present "$home/state/hotid.check.sh" "check.sh was removed before it could be tampered live"

  # Tamper the check's bytes without re-registering, so its check-trust hash
  # no longer matches, then arm the hot marker on the freshly-tampered check.
  printf '%s\n' '#!/usr/bin/env bash' "printf 'tampered\\n' >> '$ran_marker'" \
    > "$home/state/hotid.check.sh"
  chmod 0700 "$home/state/hotid.check.sh"
  install_hot_marker "$home" hotid "$events"

  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "watcher never exited with a rejection wake for the live-tampered check"
  fi
  wait "$pid" 2>/dev/null || true
  assert_contains "$(cat "$out")" "check: rejected unauthenticated state checks:" \
    "a hot marker paired with a live-tampered check must be rejected, not executed"
  assert_contains "$(cat "$out")" "hotid.check.sh" "rejection reason must name the tampered check"
  assert_absent "$ran_marker" "the tampered check must never actually run"
  pass "a hot marker never bypasses or weakens check-trust validation"
}

test_hot_path_bounded_to_one_run_per_cycle() {
  local home events counter out err status lines
  home=$(make_home bounded)
  events="$home/data/hotid.events"
  counter="$home/data/hotid.count"
  mkdir -p "$home/data"
  printf 'event\n' > "$events"
  : > "$counter"
  # Never produces output (never wakes), so the checkpoint keeps running for
  # its full bounded window while the events file stays non-empty throughout -
  # the scenario a busy-looping hot path would blow up on.
  install_check "$home" hotid "#!/usr/bin/env bash
printf x >> '$counter'"
  install_hot_marker "$home" hotid "$events"
  touch "$home/state/.last-check"
  out="$home/out.txt"; err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 4 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "silent hot-run checkpoint exit"
  lines=$(wc -c < "$counter" | tr -d '[:space:]')
  [ "$lines" -ge 1 ] || fail "hot path never ran despite a non-empty events file the whole time"
  [ "$lines" -le 20 ] || fail "hot path ran $lines times in ~4s of FM_POLL=1 cycles - looks like a busy loop, not one run per cycle"
  pass "a check that never clears its events file reruns at most once per poll cycle, not in a tight loop"
}

test_hot_marker_fires_before_sweep_interval
test_empty_events_file_does_not_fire
test_hot_marker_without_matching_check_is_noop
test_hot_path_never_touches_last_check
test_hot_marker_never_bypasses_check_trust
test_hot_path_bounded_to_one_run_per_cycle
