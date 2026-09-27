#!/usr/bin/env bash
# Portable behavior tests for bin/fm-primary-endpoint-lib.sh and the central
# watcher wake integration. A copied Bash executable named kiro-cli provides a
# real process identity; a thin tmux fake supplies one Kiro composer and records
# terminal delivery. No model or live harness is used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary-endpoint)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
REAL_BASH=$(command -v bash)
cp "$REAL_BASH" "$FAKEBIN/kiro-cli"
chmod +x "$FAKEBIN/kiro-cli"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{cursor_y}'*) printf '1\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    cat "$FM_PRIMARY_TEST_SCREEN"
    ;;
  send-keys)
    printf '%s\n' "$*" >> "$FM_PRIMARY_TEST_SEND_LOG"
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

run_as_kiro() {  # <case-dir> <mode>
  local dir=$1 mode=$2
  mkdir -p "$dir/home/state" "$dir/root/bin"
  cp "$ROOT/bin/fm-primary-endpoint-lib.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-supervisor-target-lib.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-backend.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-agent-process-lib.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-gemini-lib.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-composer-lib.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-tmux-lib.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-push-transition-lib.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-transition-lib.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-line-cap-lib.sh" "$dir/root/bin/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/root/bin/"
  mkdir -p "$dir/root/bin/backends"
  cp "$ROOT/bin/backends/tmux.sh" "$dir/root/bin/backends/"
  printf '# Firstmate\n' > "$dir/root/AGENTS.md"
  : > "$dir/send.log"
  printf 'transcript\n\033[38;2;158;158;158m› ask a question or describe a task ↵\033[0m\n' > "$dir/idle.screen"
  printf 'transcript\n› half typed command\n' > "$dir/pending.screen"
  local fake_script
  fake_script=$(cat <<'FAKE_KIRO'
      set -eu
      mode=$1
      state=$FM_STATE_OVERRIDE
      printf "%s\n" "$$" > "$state/.lock"
      . "$FM_ROOT_OVERRIDE/bin/fm-primary-endpoint-lib.sh"
      fm_primary_endpoint_publish "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME"
      case "$mode" in
        direct)
          fm_primary_endpoint_ring_kiro_wake "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME"
          : > "$FM_PRIMARY_TEST_SEND_LOG"
          if FM_WATCH_FOREGROUND_CHECKPOINT=1 \
             fm_primary_endpoint_ring_kiro_wake "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME"; then
            exit 21
          fi
          [ ! -s "$FM_PRIMARY_TEST_SEND_LOG" ] || exit 22
          export FM_PRIMARY_TEST_SCREEN=${FM_PRIMARY_TEST_SCREEN%/*}/pending.screen
          if fm_primary_endpoint_ring_kiro_wake "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME"; then
            exit 23
          fi
          [ ! -s "$FM_PRIMARY_TEST_SEND_LOG" ] || exit 24
          ;;
        wake)
          fm_wake_append check primary-doorbell "check: primary doorbell"
          . "$FM_ROOT_OVERRIDE/bin/fm-push-transition-lib.sh"
          wake "check: primary doorbell"
          ;;
        reping)
          rings() { grep -c ' Enter' "$FM_PRIMARY_TEST_SEND_LOG" || true; }
          fm_wake_append check reping-a "check: reping a"
          fm_primary_endpoint_ring_pending "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME" || exit 31
          [ "$(rings)" = 1 ] || exit 32
          # The newest row is already rung: an idle pane is not rung again.
          if fm_primary_endpoint_ring_pending "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME"; then exit 33; fi
          [ "$(rings)" = 1 ] || exit 34
          # A newer row rings once more.
          fm_wake_append check reping-b "check: reping b"
          fm_primary_endpoint_ring_pending "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME" || exit 35
          [ "$(rings)" = 2 ] || exit 36
          # A busy pane refuses quietly and leaves the marker behind, so the
          # next idle poll rings for the same row.
          fm_wake_append check reping-c "check: reping c"
          export FM_PRIMARY_TEST_SCREEN=${FM_PRIMARY_TEST_SCREEN%/*}/pending.screen
          if fm_primary_endpoint_ring_pending "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME"; then exit 37; fi
          [ "$(rings)" = 2 ] || exit 38
          export FM_PRIMARY_TEST_SCREEN=${FM_PRIMARY_TEST_SCREEN%/*}/idle.screen
          fm_primary_endpoint_ring_pending "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME" || exit 39
          [ "$(rings)" = 3 ] || exit 40
          # An acknowledged (empty) queue never rings.
          : > "$state/.wake-queue"
          if fm_primary_endpoint_ring_pending "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME"; then exit 41; fi
          [ "$(rings)" = 3 ] || exit 42
          ;;
      esac
FAKE_KIRO
)
  MODE="$mode" PATH="$FAKEBIN:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_ROOT_OVERRIDE="$dir/root" TMUX_PANE='primary:0' \
    FM_PRIMARY_TEST_SCREEN="$dir/idle.screen" FM_PRIMARY_TEST_SEND_LOG="$dir/send.log" \
    "$FAKEBIN/kiro-cli" -c "$fake_script" _ "$mode"
}

test_direct_ring_and_safety_guards() {
  local dir="$TMP_ROOT/direct" record sent
  run_as_kiro "$dir" direct || fail "identity-bound direct ring scenario failed"
  record="$dir/home/state/.primary-endpoint"
  assert_present "$record" "SessionStart publication did not create a primary endpoint record"
  assert_grep 'schema=fm-primary-endpoint.v1' "$record" "endpoint schema is missing"
  assert_grep 'harness=kiro-cli' "$record" "endpoint is not Kiro-scoped"
  # The first successful send was cleared inside the scenario only after its
  # assertions, so repeat once under a fresh Kiro identity to inspect bytes.
  run_as_kiro "$dir-inspect" wake > "$dir/wake.out" 2>&1 \
    || fail "wake integration scenario failed: $(cat "$dir/wake.out")"
  sent=$(cat "$dir-inspect/send.log")
  assert_contains "$sent" ': Firstmate wake waiting:' "Kiro primary doorbell was not typed"
  assert_contains "$sent" 'fm-wake-drain.sh' "doorbell did not point at the existing drain owner"
  assert_contains "$sent" ' Enter' "doorbell was not submitted"
  pass "primary endpoint: lock-bound Kiro ring sends once and foreground/pending guards stay silent"
}

test_watcher_wake_rings_after_durable_queue_publication() {
  local dir="$TMP_ROOT/wake" out
  out=$(run_as_kiro "$dir" wake) || fail "central wake integration failed: $out"
  assert_contains "$out" 'check: primary doorbell' "central wake did not emit its actionable reason"
  assert_present "$dir/home/state/.wake-queue" "central wake did not retain the durable queue row"
  assert_grep 'primary-doorbell' "$dir/home/state/.wake-queue" "queued wake lost its key"
  assert_grep 'Firstmate wake waiting:' "$dir/send.log" "central wake did not ring the Kiro endpoint"
  pass "watcher wake: durable queue publication precedes the structural Kiro doorbell"
}

test_direct_ring_and_safety_guards
test_watcher_wake_rings_after_durable_queue_publication

test_reping_ladder_rings_once_per_newest_row() {
  # A doorbell refused while the pane was busy must be rung again by a later
  # poll, exactly once per newest queued row, and never for an idle pane whose
  # newest row was already rung or for an acknowledged queue.
  local dir="$TMP_ROOT/reping" rc=0
  run_as_kiro "$dir" reping > "$TMP_ROOT/reping.out" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "re-ring ladder scenario failed at step $rc: $(cat "$TMP_ROOT/reping.out")"
  assert_present "$dir/home/state/.primary-doorbell-rung" "re-ring ladder left no record of the sequence last rung"
  pass "re-ring ladder: one ring per newest queued row, retried after a busy refusal, silent when idle or acknowledged"
}
test_reping_ladder_rings_once_per_newest_row

test_primary_hook_delivers_startup_and_unacknowledged_wake_context() {
  local dir="$TMP_ROOT/primary-hook" shim home state hook out
  shim="$dir/root"; home="$dir/home"; state="$home/state"; hook="$shim/bin/fm-kiro-turnend-hook.sh"
  mkdir -p "$shim/bin" "$state"
  cp "$ROOT/bin/fm-kiro-turnend-hook.sh" "$hook"
  cat > "$shim/bin/fm-primary-scope-lib.sh" <<'SH'
fm_primary_scope_matches() { [ "${FM_PRIMARY_SCOPE_RESULT:-0}" = 0 ]; }
SH
  cat > "$shim/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'SESSION-DIGEST\n'
SH
  cat > "$shim/bin/fm-primary-endpoint-lib.sh" <<'SH'
fm_primary_endpoint_publish() { printf '%s\n' "$*" > "$FM_PRIMARY_PUBLISH_LOG"; }
SH
  cat > "$shim/bin/fm-session-lock-lib.sh" <<'SH'
fm_session_lock_owned_by_self() { return 0; }
SH
  cat > "$shim/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
printf 'WAKE-CONTEXT\nWAKE_ACK_REQUIRED: keep queued until handled\n'
SH
  chmod +x "$hook" "$shim/bin/fm-sessionstart-run.sh" "$shim/bin/fm-wake-drain.sh"

  out=$(printf '{"hook_event_name":"SessionStart"}\n' | \
    FM_KIRO_PRIMARY_HOOK=1 FM_ROOT_OVERRIDE="$shim" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_PRIMARY_PUBLISH_LOG="$dir/published" bash "$hook")
  assert_contains "$out" SESSION-DIGEST "primary SessionStart did not deliver the startup digest: '$out'"
  assert_contains "$out" 'KIRO_PRIMARY_ENDPOINT: structural wake doorbell published' \
    "primary SessionStart did not tell the model its doorbell is live: '$out'"
  assert_grep "$state $shim $home" "$dir/published" \
    "primary SessionStart did not publish its endpoint after startup"

  printf 'queued\n' > "$state/.wake-queue"
  out=$(printf '{"hook_event_name":"UserPromptSubmit"}\n' | \
    FM_KIRO_PRIMARY_HOOK=1 FM_ROOT_OVERRIDE="$shim" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash "$hook")
  assert_contains "$out" WAKE-CONTEXT "primary UserPromptSubmit did not attach wake context"
  assert_contains "$out" WAKE_ACK_REQUIRED "primary wake context lost its post-handling acknowledgement"
  assert_grep queued "$state/.wake-queue" "UserPromptSubmit consumed a wake before model handling"

  rm -f "$dir/published"
  out=$(printf '{"hook_event_name":"SessionStart"}\n' | \
    FM_KIRO_PRIMARY_HOOK=1 FM_PRIMARY_SCOPE_RESULT=1 FM_ROOT_OVERRIDE="$shim" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PRIMARY_PUBLISH_LOG="$dir/published" bash "$hook")
  [ -z "$out" ] || fail "an inherited primary hook in linked scope emitted context: '$out'"
  assert_absent "$dir/published" "an inherited primary hook published a worker endpoint"
  pass "Kiro primary hook: startup and wake context deliver only in primary scope without early acknowledgement"
}
test_primary_hook_delivers_startup_and_unacknowledged_wake_context
