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
  mkdir -p "$dir/home/state" "$dir/root"
  # The whole bin tree, so the library's transitive sources never drift out of
  # a hand-kept copy list.
  cp -R "$ROOT/bin" "$dir/root/bin"
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
fm_primary_endpoint_ensure() { FM_PRIMARY_ENDPOINT_ENSURED=current; }
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

# A real Kiro-shaped process chain for the every-turn ensure: a copied bash named
# kiro-cli owns the fleet lock and runs the SHIPPED hook through genuine nested
# shells, deeper than eight frames, exactly where a Kiro hook reaches it. Only
# the primary-scope predicate, the startup runner, supervision need, and the
# watcher arm are shimmed, so no digest runs and no watcher starts.
make_ensure_case() {  # <case-dir>
  local dir=$1 root=$1/root
  mkdir -p "$dir/home/state" "$root"
  cp -R "$ROOT/bin" "$root/bin"
  printf '# Firstmate\n' > "$root/AGENTS.md"
  cat > "$root/bin/fm-primary-scope-lib.sh" <<'SH'
fm_primary_scope_matches() { return 0; }
SH
  cat > "$root/bin/fm-supervision-lib.sh" <<'SH'
fm_supervision_needed() { return 1; }
SH
  printf '#!/usr/bin/env bash\nprintf "SESSION-DIGEST\\n"\n' > "$root/bin/fm-sessionstart-run.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/fm-watch-arm.sh"
  : > "$dir/send.log"
}

# Run <event> through the shipped hook <depth> shells below a kiro-cli process.
# With <lock-owner>=self that process records itself as the lock owner first;
# any other value is written to the lock verbatim. Prints the hook's context
# output, then `kiro=<pid>` for the session's own pid.
run_ensure_hook() {  # <case-dir> <event> <lock-owner> [depth] [pane]
  local dir=$1 event=$2 owner=$3 depth=${4:-10} pane=${5:-primary:0} hook inner
  hook="$dir/root/bin/fm-kiro-turnend-hook.sh"
  inner="printf '{\"hook_event_name\":\"%s\"}\\n' '$event' | bash '$hook'"
  PATH="$FAKEBIN:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_ROOT_OVERRIDE="$dir/root" FM_KIRO_PRIMARY_HOOK=1 TMUX_PANE="$pane" \
    FM_PRIMARY_TEST_SCREEN="$dir/idle.screen" FM_PRIMARY_TEST_SEND_LOG="$dir/send.log" \
    "$FAKEBIN/kiro-cli" -c "
      if [ '$owner' = self ]; then printf '%s\n' \"\$\$\" > '$dir/home/state/.lock'
      else printf '%s\n' '$owner' > '$dir/home/state/.lock'; fi
      $(fm_nested_bash_command "$depth" "$inner")
      printf 'kiro=%s\n' \"\$\$\""
}

endpoint_field() {  # <record> <key>
  sed -n "s/^$2=//p" "$1"
}

test_every_turn_hooks_ensure_the_doorbell() {
  local dir="$TMP_ROOT/ensure" record out pid
  make_ensure_case "$dir"
  record="$dir/home/state/.primary-endpoint"

  # Hooks that arrive after the first prompt never see SessionStart: a missing
  # doorbell is published by the next UserPromptSubmit, which says so once.
  out=$(run_ensure_hook "$dir" UserPromptSubmit self) || fail "UserPromptSubmit ensure scenario failed: $out"
  pid=$(printf '%s\n' "$out" | sed -n 's/^kiro=//p')
  assert_present "$record" "UserPromptSubmit did not publish a missing doorbell"
  [ "$(endpoint_field "$record" pid)" = "$pid" ] \
    || fail "published doorbell names pid '$(endpoint_field "$record" pid)', not the kiro session '$pid'"
  assert_contains "$out" 'KIRO_PRIMARY_ENDPOINT: structural wake doorbell published' \
    "UserPromptSubmit did not tell the model its doorbell became live: $out"

  # Stop publishes a missing doorbell too, silently.
  rm -f "$record"
  out=$(run_ensure_hook "$dir" Stop self) || fail "Stop ensure scenario failed: $out"
  pid=$(printf '%s\n' "$out" | sed -n 's/^kiro=//p')
  assert_present "$record" "Stop did not publish a missing doorbell"
  [ "$(endpoint_field "$record" pid)" = "$pid" ] || fail "Stop published the wrong pid"
  [ "$(printf '%s\n' "$out" | grep -vc '^kiro=')" = 0 ] || fail "Stop wrote context: $out"

  # A record left by an older session incarnation is republished for this one,
  # and a moved pane is followed.
  out=$(run_ensure_hook "$dir" UserPromptSubmit self 10 'primary:7') || fail "republish scenario failed: $out"
  pid=$(printf '%s\n' "$out" | sed -n 's/^kiro=//p')
  [ "$(endpoint_field "$record" pid)" = "$pid" ] || fail "an old-pid doorbell was not republished for pid '$pid'"
  [ "$(endpoint_field "$record" target)" = 'primary:7' ] || fail "a moved pane was not republished"

  # A current doorbell is left exactly as it is.
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_ROOT_OVERRIDE="$dir/root" TMUX_PANE='primary:0' \
    "$FAKEBIN/kiro-cli" -c "
      . '$dir/root/bin/fm-primary-endpoint-lib.sh'
      printf '%s\n' \"\$\$\" > '$dir/home/state/.lock'
      fm_primary_endpoint_ensure '$dir/home/state' '$dir/root' '$dir/home' || exit 3
      printf 'first=%s\n' \"\$FM_PRIMARY_ENDPOINT_ENSURED\"
      fm_primary_endpoint_ensure '$dir/home/state' '$dir/root' '$dir/home' || exit 4
      printf 'second=%s\n' \"\$FM_PRIMARY_ENDPOINT_ENSURED\"
      touch -d '2000-01-01' '$record'
      fm_primary_endpoint_ensure '$dir/home/state' '$dir/root' '$dir/home' || exit 5
      printf 'third=%s\n' \"\$FM_PRIMARY_ENDPOINT_ENSURED\"") \
    || fail "direct ensure scenario failed: $out"
  assert_contains "$out" 'first=published' "a new session's first ensure did not publish: $out"
  assert_contains "$out" 'second=current' "an unchanged doorbell was republished: $out"
  assert_contains "$out" 'third=current' "a current doorbell was rewritten: $out"
  touch "$dir/now"
  [ "$record" -ot "$dir/now" ] || fail "a current doorbell was rewritten on disk"
  pass "Kiro primary hooks: every turn publishes a missing doorbell, follows a new pid or pane, and leaves a current one alone"
}

test_ensure_refuses_another_sessions_lock() {
  local dir="$TMP_ROOT/ensure-foreign" record other out before
  make_ensure_case "$dir"
  record="$dir/home/state/.primary-endpoint"
  # Another live kiro-cli session holds the lock.
  "$FAKEBIN/kiro-cli" -c 'sleep 60' &
  other=$!
  for event in UserPromptSubmit Stop; do
    out=$(run_ensure_hook "$dir" "$event" "$other") || fail "$event foreign-lock scenario failed: $out"
    assert_absent "$record" "$event published a doorbell while another session owns the lock"
  done
  # Its own record stays byte-identical.
  printf 'schema=fm-primary-endpoint.v1\nharness=kiro-cli\nbackend=tmux\ntarget=other:1\npid=%s\npid_identity=x\nroot=%s\nhome=%s\n' \
    "$other" "$dir/root" "$dir/home" > "$record"
  before=$(cat "$record")
  for event in UserPromptSubmit Stop; do
    run_ensure_hook "$dir" "$event" "$other" >/dev/null || fail "$event foreign-lock scenario failed"
    [ "$(cat "$record")" = "$before" ] || fail "$event overwrote another session's doorbell"
  done
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  pass "Kiro primary hooks: the every-turn ensure refuses when another session owns the lock"
}

test_every_turn_hooks_ensure_the_doorbell
test_ensure_refuses_another_sessions_lock
