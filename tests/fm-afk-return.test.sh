#!/usr/bin/env bash
# Deterministic return-catch-up gate regression.
#
# Covers the second half of the 2026-07-14 incident: an away-mode blocked event
# survived in durable state, but the ordinary return request could proceed to
# Bearings before Firstmate owned remediation. The shared script now stops,
# drains, preserves evidence, and refuses ordinary work until every live open
# `blocked:` event is resolved or durably reclassified.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-return-tests)

install_runner() {  # <case-dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/home/state" "$dir/home/data" "$dir/home/config"
  cp "$ROOT/bin/fm-afk-return.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/"
  # fm-timeout-lib.sh: the shared hard bound fm-classify-lib.sh sources for the
  # wedge detector's bounded worktree write probe.
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/"
  cat > "$dir/bin/fm-afk-launch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = stop ] || exit 2
printf 'stop\n' >> "$FM_HOME/stop.log"
rm -f "$FM_HOME/state/.afk"
if [ -e "$FM_HOME/state/.fail-terminal-stop-once" ]; then
  rm -f "$FM_HOME/state/.fail-terminal-stop-once"
  exit 1
fi
rm -f "$FM_HOME/state/.afk-daemon-terminal"
SH
  cat > "$dir/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
file="$FM_HOME/state/.fake-drain"
if [ -e "$FM_HOME/state/.block-drain" ]; then
  : > "$FM_HOME/state/.drain-started"
  while [ -e "$FM_HOME/state/.block-drain" ]; do sleep 0.02; done
fi
if [ "${1:-}" = --ack-through ]; then
  [ "${3:-}" = --recovery-generation ] && [ "${4:-}" = fixture-generation ] || exit 2
  printf '%s\n' "$2" >> "$FM_HOME/state/.fake-drain-acks"
  : > "$file"
  exit 0
fi
if [ -s "$file" ]; then
  cat "$file"
  sequence=$(awk -F '\t' '$2 ~ /^[0-9]+$/ && $2 > max { max=$2 } END { print max + 0 }' "$file")
  printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through %s --recovery-generation fixture-generation\n' "$sequence" >&2
fi
SH
  chmod +x "$dir/bin/"*.sh
}

run_return() {  # <case-dir> <mode>
  local dir=$1 mode=$2
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$dir/bin/fm-afk-return.sh" "$mode" 2>&1
}

ack_return() {  # <case-dir> <return-output>
  local dir=$1 output=$2 sequence generation
  sequence=$(printf '%s\n' "$output" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' | tail -1)
  generation=$(printf '%s\n' "$output" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' | tail -1)
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "return output lacked a generation-bound post-handling acknowledgement: $output"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    "$dir/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation"
}

seed_live_blocker() {  # <case-dir> <backend> <key>
  local dir=$1 backend=$2 key=$3 target
  case "$backend" in
    tmux) target='synthetic:fm-repair-task' ;;
    herdr) target='fm-lab-synthetic:w1:p2' ;;
  esac
  cat > "$dir/home/state/repair-task.meta" <<EOF
window=$target
backend=$backend
kind=ship
EOF
  printf 'blocked [key=%s]: firstmate can refresh the synthetic token\n' "$key" > "$dir/home/state/repair-task.status"
}

test_return_gate_orders_catchup_before_bearings() {
  local dir out rc gate wake_count
  dir="$TMP_ROOT/ordering"
  install_runner "$dir"
  seed_live_blocker "$dir" herdr synthetic-dependency
  date +%s > "$dir/home/state/.afk"
  printf 'repair-task.status: blocked synthetic dependency\n' > "$dir/home/state/.subsuper-escalations"
  printf 'fm away-mode inject WEDGED: 4555s undelivered\n' > "$dir/home/state/.subsuper-inject-wedged"
  {
    printf '1784074271\t2\tsignal\trepair-task.status\tsignal: synthetic status\n'
    printf 'wake annotation: latest wake-EVENT observed at drain, not current state: repair-task.status: blocked synthetic dependency\n'
  } > "$dir/home/state/.fake-drain"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "return begin should gate on a live blocker (rc=$rc): $out"
  gate="$dir/home/state/.afk-return-catchup"
  [ -s "$gate" ] || fail "return begin did not persist its fail-closed catch-up gate"
  assert_contains "$out" 'firstmate-actionable blocker: repair-task [key=synthetic-dependency]' "return output did not assign blocker remediation to Firstmate"
  grep -F $'evidence\twake\t1784074271' "$gate" >/dev/null || fail "drained wake evidence was not retained in the durable gate"
  grep -F $'evidence\twake\twake annotation: latest wake-EVENT observed at drain, not current state: repair-task.status: blocked synthetic dependency' "$gate" >/dev/null \
    || fail "the separate drain annotation was not retained as away-return evidence"
  grep -F $'evidence\twedge\tfm away-mode inject WEDGED: 4555s undelivered' "$gate" >/dev/null || fail "wedge evidence was not retained in the durable gate"
  grep -F $'evidence\tescalation\trepair-task.status: blocked synthetic dependency' "$gate" >/dev/null || fail "buffered escalation evidence was not retained in the durable gate"
  [ "$(wc -l < "$dir/home/stop.log" | tr -d ' ')" -eq 1 ] || fail "return begin did not stop away mode exactly once"
  [ -s "$dir/home/state/.fake-drain" ] || fail "blocked return acknowledged its emitted wake before handling completed"
  [ ! -e "$dir/home/state/.fake-drain-acks" ] || fail "blocked return crossed the post-handling acknowledgement boundary"

  # The exact incident regression: Bearings is an ordinary request and must
  # refuse before reading/rendering while this shared gate remains open.
  set +e
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/fm-bearings-snapshot.sh" --json 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "Bearings should refuse behind the return gate (rc=$rc): $out"
  assert_contains "$out" 'return catch-up is pending' "Bearings refusal did not point to the shared return owner"

  # Restart/re-entry is idempotent: no second stop, no duplicate catch-up line,
  # and the same unresolved blocker remains authoritative.
  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "repeated begin should preserve the unresolved gate"
  [ "$(wc -l < "$dir/home/stop.log" | tr -d ' ')" -eq 1 ] || fail "repeated begin stopped an already-stopped daemon twice"
  wake_count=$(grep -c $'^evidence\twake\t1784074271' "$gate" || true)
  [ "$wake_count" -eq 1 ] || fail "repeated begin duplicated retained wake evidence ($wake_count copies)"
  [ "$(grep -c $'^evidence\twedge\t' "$gate" || true)" -eq 1 ] || fail "repeated begin duplicated retained wedge evidence"
  [ "$(grep -c $'^evidence\tescalation\t' "$gate" || true)" -eq 1 ] || fail "repeated begin duplicated retained escalation evidence"

  printf 'resolved [key=synthetic-dependency]: refreshed the synthetic token and resumed the task\n' >> "$dir/home/state/repair-task.status"
  out=$(run_return "$dir" check) || fail "resolved blocker did not clear return catch-up: $out"
  assert_contains "$out" 'catch-up clear' "successful check did not announce that ordinary work may proceed"
  [ ! -e "$gate" ] || fail "successful check left the return gate behind"
  [ ! -e "$dir/home/state/.subsuper-escalations" ] || fail "successful check left delivered escalation state behind"
  [ ! -e "$dir/home/state/.subsuper-inject-wedged" ] || fail "successful check left the wedge marker behind"
  [ -s "$dir/home/state/.fake-drain" ] || fail "successful return consumed its wake before handling completed"
  [ ! -e "$dir/home/state/.fake-drain-acks" ] || fail "successful return acknowledged its wake inside evidence publication"
  assert_contains "$out" 'WAKE_ACK_REQUIRED: after handling completes' "successful return did not hand acknowledgement to the handling turn"
  ack_return "$dir" "$out" || fail "post-handling acknowledgement failed"
  [ ! -s "$dir/home/state/.fake-drain" ] || fail "explicit post-handling acknowledgement left the handled wake durable"
  [ "$(cat "$dir/home/state/.fake-drain-acks" 2>/dev/null || true)" = 2 ] \
    || fail "explicit post-handling acknowledgement used the wrong wake sequence"

  out=$(run_return "$dir" check) || fail "an already-clear repeated check should be idempotent: $out"
  [ ! -e "$gate" ] || fail "idempotent clear check recreated a gate"
  pass "return catch-up precedes Bearings, owns live blocker remediation, preserves evidence once, and clears idempotently"
}

test_explicit_reclassification_requires_durable_reason() {
  local backend dir out rc
  for backend in tmux herdr; do
    dir="$TMP_ROOT/reclassify-$backend"
    install_runner "$dir"
    seed_live_blocker "$dir" "$backend" vendor-release
    date +%s > "$dir/home/state/.afk"
    : > "$dir/home/state/.fake-drain"
    set +e
    out=$(run_return "$dir" begin)
    rc=$?
    set -e
    [ "$rc" -eq 3 ] || fail "$backend blocker did not open the return gate"

    # A pause alone cannot mask the keyed blocker. The old concern must be
    # explicitly resolved with the durable reclassification reason first.
    printf 'paused [key=vendor-release]: waiting for the synthetic vendor window\n' >> "$dir/home/state/repair-task.status"
    set +e
    out=$(run_return "$dir" check)
    rc=$?
    set -e
    [ "$rc" -eq 3 ] || fail "$backend pause silently masked an unresolved blocked key"

    printf 'resolved [key=vendor-release]: reclassified as an external wait because the synthetic vendor owns the next event\n' >> "$dir/home/state/repair-task.status"
    printf 'paused [key=vendor-release]: waiting for the synthetic vendor window\n' >> "$dir/home/state/repair-task.status"
    out=$(run_return "$dir" check) || fail "$backend durable reclassification did not clear the return gate: $out"
    [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "$backend reclassification left a gate behind"
  done
  pass "tmux and Herdr blockers require the same explicit durable reclassification before ordinary work"
}

test_captain_decision_does_not_masquerade_as_firstmate_blocker() {
  local dir out
  dir="$TMP_ROOT/captain-decision"
  install_runner "$dir"
  cat > "$dir/home/state/decision-task.meta" <<'EOF'
window=synthetic:fm-decision-task
backend=tmux
kind=ship
EOF
  printf 'needs-decision [key=api-shape]: captain must choose the synthetic API shape\n' > "$dir/home/state/decision-task.status"
  date +%s > "$dir/home/state/.afk"
  printf '1784074271\t1\tsignal\tdecision-task.status\tsignal: synthetic decision\n' > "$dir/home/state/.fake-drain"
  out=$(run_return "$dir" begin) || fail "approval decision should not be treated as a firstmate blocker: $out"
  assert_contains "$out" 'catch-up wake:' "approval decision notification was not surfaced in catch-up"
  [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "approval decision incorrectly opened a firstmate blocker gate"
  pass "needs-decision remains reportable without masquerading as a firstmate-actionable blocker"
}

test_evidence_publication_failure_preserves_wake_for_redrain() {
  local dir out rc gate
  dir="$TMP_ROOT/evidence-publication-failure"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  printf '1784074271\t7\tsignal\trecovery-task.status\tsignal: recover after output failure\n' \
    > "$dir/home/state/.fake-drain"
  : > "$dir/read-only-output"

  set +e
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    "$dir/bin/fm-afk-return.sh" begin 3< "$dir/read-only-output" >&3 2> "$dir/failed.err"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "evidence publication failure should retain catch-up (rc=$rc)"
  [ -s "$dir/home/state/.fake-drain" ] || fail "publication failure removed the unhandled durable wake"
  [ ! -e "$dir/home/state/.fake-drain-acks" ] || fail "publication failure acknowledged the wake before delivery"
  [ -s "$gate" ] || fail "publication failure did not retain the catch-up gate"

  out=$(run_return "$dir" check) || fail "publication retry did not complete catch-up: $out"
  assert_contains "$out" 'catch-up wake: 1784074271' "publication retry did not re-drain the durable wake"
  assert_contains "$out" 'WAKE_ACK_REQUIRED: after handling completes' "publication retry did not return acknowledgement to the handling turn"
  [ -s "$dir/home/state/.fake-drain" ] || fail "successful evidence publication consumed the wake before handling"
  [ ! -e "$dir/home/state/.fake-drain-acks" ] || fail "successful evidence publication acknowledged the wake before handling"
  [ ! -e "$gate" ] || fail "successful publication retry left the catch-up gate pending"

  out=$(run_return "$dir" check) || fail "return did not recover after interruption before acknowledgement: $out"
  assert_contains "$out" 'catch-up wake: 1784074271' "interrupted handling did not re-drain the published wake"
  [ -s "$dir/home/state/.fake-drain" ] || fail "interrupted handling lost the published wake"
  ack_return "$dir" "$out" || fail "explicit acknowledgement after replay failed"
  [ ! -s "$dir/home/state/.fake-drain" ] || fail "explicit acknowledgement did not consume the replayed wake"
  [ "$(cat "$dir/home/state/.fake-drain-acks" 2>/dev/null || true)" = 7 ] \
    || fail "explicit acknowledgement after replay used the wrong wake sequence"
  pass "AFK return re-drains published wakes until handling acknowledges"
}

test_away_reentry_refuses_pending_return_gate() {
  local dir out rc
  dir="$TMP_ROOT/reentry"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  printf 'schema\tfm-afk-return.v1\nphase\tblocked\n' > "$dir/home/state/.afk-return-catchup"
  set +e
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/fm-afk-launch.sh" start 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "away re-entry succeeded while return catch-up was pending"
  assert_contains "$out" 'return catch-up is still pending' "away re-entry refusal did not explain the pending owner"
  [ ! -e "$dir/home/state/.afk" ] || fail "away re-entry wrote .afk despite the pending return gate"
  pass "away-mode re-entry fails closed while the prior return catch-up is pending"
}

test_check_retries_recorded_terminal_teardown() {
  local dir gate out rc
  dir="$TMP_ROOT/terminal-teardown"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  date +%s > "$dir/home/state/.afk"
  printf 'herdr\tsynthetic:pane\tsynthetic-workspace\n' > "$dir/home/state/.afk-daemon-terminal"
  touch "$dir/home/state/.fail-terminal-stop-once"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "failed terminal teardown should keep return catch-up gated (rc=$rc): $out"
  [ -e "$gate" ] || fail "failed terminal teardown cleared the return gate"
  [ -e "$dir/home/state/.afk-daemon-terminal" ] || fail "failed terminal teardown discarded its durable record"
  [ ! -e "$dir/home/state/.afk" ] || fail "failed terminal teardown did not preserve stop ordering"

  out=$(run_return "$dir" check) || fail "check did not retry recorded terminal teardown: $out"
  [ ! -e "$dir/home/state/.afk-daemon-terminal" ] || fail "successful check left the terminal teardown record behind"
  [ ! -e "$gate" ] || fail "successful terminal teardown retry left the return gate behind"
  [ "$(wc -l < "$dir/home/stop.log" | tr -d ' ')" -eq 2 ] || fail "check did not retry terminal teardown exactly once"
  pass "check retries recorded terminal teardown and keeps catch-up gated until success"
}

test_daemon_died_unexpectedly_surfaces_without_blocking() {
  local dir out rc
  dir="$TMP_ROOT/daemon-died-unexpectedly"
  install_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  # Simulates a launcher death-detection boundary having recorded that the
  # daemon exited before the captain returned. Marker presence is what
  # fm-afk-return.sh reacts to, regardless of which launcher path wrote it.
  : > "$dir/home/state/.afk-daemon-died-unexpectedly"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "an already-dead daemon should not block catch-up the way a live blocker does (rc=$rc): $out"
  assert_contains "$out" 'catch-up clear' "ordinary work was not cleared to proceed"
  assert_contains "$out" 'catch-up unsupervised: the away-mode daemon exited on its own before this return' \
    "the unexpected daemon death was not surfaced in the catch-up digest"
  [ ! -e "$dir/home/state/.afk-daemon-died-unexpectedly" ] || fail "the unexpected-death marker was not consumed after being surfaced"
  pass "an unexpectedly-dead away-mode daemon is surfaced as catch-up evidence without gating ordinary work"
}

test_daemon_death_marker_survives_interrupted_reconciliation() {
  local dir return_pid attempt marker_during_drain=0
  dir="$TMP_ROOT/daemon-death-interruption"
  install_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  : > "$dir/home/state/.afk-daemon-died-unexpectedly"
  : > "$dir/home/state/.block-drain"

  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    "$dir/bin/fm-afk-return.sh" begin > "$dir/return.out" 2>&1 &
  return_pid=$!
  attempt=0
  while [ ! -e "$dir/home/state/.drain-started" ] && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    sleep 0.02
  done
  [ -e "$dir/home/state/.afk-daemon-died-unexpectedly" ] && marker_during_drain=1
  kill -TERM "$return_pid" 2>/dev/null || true
  rm -f "$dir/home/state/.block-drain"
  wait "$return_pid" 2>/dev/null || true

  [ -e "$dir/home/state/.drain-started" ] || fail "interruption fixture never reached reconciliation after observing the death marker"
  [ "$marker_during_drain" -eq 1 ] || fail "unexpected-death marker was consumed before evidence publication"
  [ -e "$dir/home/state/.afk-daemon-died-unexpectedly" ] || fail "interrupted reconciliation lost the unpublished unexpected-death marker"
  pass "interrupted return preserves unexpected-death evidence until publication"
}

test_daemon_death_marker_survives_evidence_append_failure() {
  local dir fake_bin real_mktemp out rc gate
  dir="$TMP_ROOT/daemon-death-append-failure"
  install_runner "$dir"
  fake_bin="$dir/fake-bin"
  real_mktemp=$(command -v mktemp)
  gate="$dir/home/state/.afk-return-catchup"
  mkdir -p "$fake_bin"
  : > "$dir/home/state/.afk-daemon-died-unexpectedly"
  cat > "$fake_bin/mktemp" <<'SH'
#!/usr/bin/env bash
path=$("$REAL_MKTEMP" "$@") || exit 1
case "$1" in
  *.afk-return-evidence.*) chmod 400 "$path" || exit 1 ;;
esac
printf '%s\n' "$path"
SH
  chmod +x "$fake_bin/mktemp"

  set +e
  out=$(PATH="$fake_bin:$PATH" REAL_MKTEMP="$real_mktemp" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" "$dir/bin/fm-afk-return.sh" begin 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "unexpected-death evidence append failure should retain catch-up (rc=$rc): $out"
  [ -e "$dir/home/state/.afk-daemon-died-unexpectedly" ] \
    || fail "failed unexpected-death append consumed the only durable marker"
  [ -s "$gate" ] || fail "failed unexpected-death append did not persist a retry gate"
  assert_contains "$out" 'failed to stage unexpected-daemon-death evidence' \
    "failed unexpected-death append was not surfaced"
  pass "unexpected-death append failure preserves the marker for retry"
}

test_daemon_death_marker_removal_failure_keeps_retry_gate() {
  local dir out rc gate
  dir="$TMP_ROOT/daemon-death-marker-removal"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  date +%s > "$dir/home/state/.afk"
  mkdir "$dir/home/state/.afk-daemon-died-unexpectedly"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "marker removal failure should retain catch-up (rc=$rc): $out"
  assert_contains "$out" 'catch-up unsupervised: the away-mode daemon exited on its own before this return' \
    "marker removal failure did not publish the unexpected-death evidence"
  assert_contains "$out" 'failed to consume the unexpected-daemon-death marker' \
    "marker removal failure was not reported explicitly"
  [ -s "$gate" ] || fail "marker removal failure did not persist a retry gate"
  grep -F $'evidence\tunsupervised\tthe away-mode daemon exited on its own before this return' "$gate" >/dev/null \
    || fail "marker removal failure did not retain unexpected-death evidence in the gate"

  rmdir "$dir/home/state/.afk-daemon-died-unexpectedly"
  out=$(run_return "$dir" check) || fail "catch-up did not recover after marker removal became possible: $out"
  assert_contains "$out" 'catch-up unsupervised: the away-mode daemon exited on its own before this return' \
    "retry did not replay persisted unexpected-death evidence"
  [ ! -e "$gate" ] || fail "successful marker cleanup left the retry gate pending"
  pass "marker removal failure is explicit and preserves a durable retry gate"
}

test_return_gate_orders_catchup_before_bearings
test_explicit_reclassification_requires_durable_reason
test_captain_decision_does_not_masquerade_as_firstmate_blocker
test_evidence_publication_failure_preserves_wake_for_redrain
test_away_reentry_refuses_pending_return_gate
test_check_retries_recorded_terminal_teardown
test_daemon_died_unexpectedly_surfaces_without_blocking
test_daemon_death_marker_survives_interrupted_reconciliation
test_daemon_death_marker_survives_evidence_append_failure
test_daemon_death_marker_removal_failure_keeps_retry_gate
