#!/usr/bin/env bash
# fm-send strict target resolution and key delivery reporting.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
# They also verify that a key send reports whether delivery actually succeeded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    # FM_FAKE_TMUX_SEND_KEY_FAIL names one key whose delivery fails, so the
    # --key exit contract can be driven both ways from the same stub.
    if [ "$literal" = 0 ] && [ -n "${FM_FAKE_TMUX_SEND_KEY_FAIL:-}" ] \
      && [ "${1:-}" = "$FM_FAKE_TMUX_SEND_KEY_FAIL" ]; then
      exit 1
    fi
    if [ -n "${FM_FAKE_TMUX_COMPOSER:-}" ]; then
      if [ "$literal" = 1 ]; then
        if [ -n "${FM_FAKE_TMUX_TYPE_HOLD:-}" ]; then
          if mkdir "$FM_FAKE_TMUX_TYPE_HOLD.active" 2>/dev/null; then
            : > "$FM_FAKE_TMUX_TYPE_HOLD.started"
            while [ ! -e "$FM_FAKE_TMUX_TYPE_HOLD.release" ]; do
              /bin/sleep 0.01
            done
            rmdir "$FM_FAKE_TMUX_TYPE_HOLD.active"
          else
            : > "$FM_FAKE_TMUX_TYPE_HOLD.overlap"
          fi
        fi
        printf '╭──────────────────────────────╮\n│ > %-27.27s│\n╰──────────────────────────────╯\n' "${1:-}" > "$FM_FAKE_TMUX_COMPOSER"
        [ "${FM_FAKE_TMUX_SWALLOW_ENTER:-0}" != 1 ] || printf 'esc to interrupt\n' >> "$FM_FAKE_TMUX_COMPOSER"
      elif [ "${1:-}" = C-c ]; then
        [ ! -d "${FM_FAKE_TMUX_TYPE_HOLD:-}.active" ] || : > "$FM_FAKE_TMUX_TYPE_HOLD.overlap"
        printf '╭────╮\n│    │\n╰────╯\n' > "$FM_FAKE_TMUX_COMPOSER"
      elif [ "${1:-}" = Enter ]; then
        if [ "${FM_FAKE_TMUX_SWALLOW_ENTER:-0}" != 1 ]; then
          printf '╭────╮\n│    │\n╰────╯\n' > "$FM_FAKE_TMUX_COMPOSER"
        fi
      fi
    fi
    exit 0 ;;
  display-message)
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf 'capture-pane\n' >> "$FM_TMUX_LOG"
    if [ -n "${FM_FAKE_TMUX_COMPOSER:-}" ]; then
      cat "$FM_FAKE_TMUX_COMPOSER"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane send-keys") : ;;
esac
SH
  chmod +x "$fb/herdr"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_fm_prefixed_herdr_session_is_an_explicit_target() {
  local dir fb home err log herdr_log rc
  dir="$TMP_ROOT/fm-remote-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home fmremote); err="$dir/send.err"; log="$dir/tmux.log"; herdr_log="$dir/herdr.log"
  : > "$log"
  : > "$herdr_log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 \
    "$SEND" fm-remote:w1:p2 --key Enter >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an fm-prefixed Herdr session target should be accepted as explicit"
  assert_grep 'pane get w1:p2 --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not verified in its session"
  assert_grep 'pane send-keys w1:p2 enter --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not sent its key in its session"
  assert_no_grep '--session default' "$herdr_log" "fm-prefixed Herdr target fell back to the default session"
  pass "fm-send strict: fm-prefixed Herdr sessions remain explicit backend targets"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=hello captain" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends still type once and submit"
}

test_stale_composer_refuses_before_typing() {
  local dir fb home err log composer rc
  dir="$TMP_ROOT/stale-composer"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home stalecomposer); err="$dir/send.err"; log="$dir/tmux.log"; composer="$dir/composer"
  : > "$log"
  printf '╭──────────────────────────────╮\n│ > %-27s│\n╰──────────────────────────────╯\n' 'stale instruction' > "$composer"
  fm_write_meta "$home/state/parked-codex.meta" "window=sess:fm-parked-codex" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_COMPOSER="$composer" FM_SEND_SETTLE=0 \
    "$SEND" parked-codex "new intended steer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a parked Codex lane with stale composer text reported successful delivery"
  assert_contains "$(cat "$err")" "composer is not empty" "stale-composer refusal should name the unsafe baseline"
  assert_no_grep 'send-keys .*literal=1' "$log" "stale-composer refusal must not append the intended steer"
  assert_no_grep 'send-keys .*arg=Enter' "$log" "stale-composer refusal must not submit the stale instruction"
  assert_contains "$(cat "$composer")" "stale instruction" "stale-composer refusal must preserve the existing draft"
  pass "fm-send delivery: stale parked-lane composer refuses before typing or submitting"
}

test_empty_composer_delivers_intended_text_once() {
  local dir fb home err log composer rc
  dir="$TMP_ROOT/accepted-delivery"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home accepted); err="$dir/send.err"; log="$dir/tmux.log"; composer="$dir/composer"
  : > "$log"
  printf '╭────╮\n│    │\n╰────╯\n' > "$composer"
  fm_write_meta "$home/state/ready-codex.meta" "window=sess:fm-ready-codex" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_COMPOSER="$composer" FM_SEND_SETTLE=0 \
    "$SEND" ready-codex "new intended steer" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an empty Codex composer should accept the intended steer"
  [ "$(grep -c 'literal=1 arg=new intended steer' "$log")" -eq 1 ] \
    || fail "the intended steer was not typed exactly once: $(cat "$log")"
  [ "$(grep -c 'literal=0 arg=Enter' "$log")" -eq 1 ] \
    || fail "the intended steer was not submitted exactly once: $(cat "$log")"
  [ "$(sed -n '2p' "$composer")" = '│    │' ] \
    || fail "the accepted delivery did not clear the composer: $(cat "$composer")"
  pass "fm-send delivery: an empty composer accepts the intended steer exactly once"
}

test_busy_queue_confirmation_survives_empty_preflight() {
  local dir fb home err log composer rc
  dir="$TMP_ROOT/busy-queue"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home busyqueue); err="$dir/send.err"; log="$dir/tmux.log"; composer="$dir/composer"
  : > "$log"
  printf '╭────╮\n│    │\n╰────╯\nesc to interrupt\n' > "$composer"
  fm_write_meta "$home/state/busy-codex.meta" "window=sess:fm-busy-codex" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_COMPOSER="$composer" FM_FAKE_TMUX_SWALLOW_ENTER=1 \
    FM_SEND_RETRIES=3 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$SEND" busy-codex "queued intended steer" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a busy lane should retain the proven queued-Enter confirmation"
  [ "$(grep -c 'literal=1 arg=queued intended steer' "$log")" -eq 1 ] \
    || fail "the busy-queued steer was not typed exactly once: $(cat "$log")"
  [ "$(grep -c 'literal=0 arg=Enter' "$log")" -eq 3 ] \
    || fail "the busy-queued steer did not consume the Enter retry budget: $(cat "$log")"
  pass "fm-send delivery: empty preflight preserves proven busy-queue acceptance"
}

test_concurrent_sends_serialize_per_endpoint() {
  local dir fb first_home second_home first_tmp second_tmp task endpoint log composer hold first_pid second_pid key_pid first_rc second_rc key_rc i
  dir="$TMP_ROOT/concurrent-sends"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); first_home=$(setup_home concurrent-first); second_home=$(setup_home concurrent-second)
  first_tmp="$dir/tmp-first"; second_tmp="$dir/tmp-second"; mkdir -p "$first_tmp" "$second_tmp"
  task="shared-codex-$RANDOM"; endpoint="sess:fm-$task"
  log="$dir/tmux.log"; composer="$dir/composer"; hold="$dir/type-hold"
  : > "$log"
  printf '╭────╮\n│    │\n╰────╯\n' > "$composer"
  fm_write_meta "$first_home/state/$task.meta" "window=$endpoint" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" TMPDIR="$first_tmp" FM_HOME="$first_home" FM_ROOT_OVERRIDE="$first_home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_COMPOSER="$composer" FM_FAKE_TMUX_TYPE_HOLD="$hold" FM_SEND_SETTLE=0 \
    "$SEND" "$task" "first intended steer" >/dev/null 2>"$dir/first.err" &
  first_pid=$!
  for i in $(seq 1 1000); do
    [ ! -e "$hold.started" ] || break
    /bin/sleep 0.01
  done
  [ -e "$hold.started" ] || fail "the first concurrent send never reached the held type boundary: $(cat "$dir/first.err")"

  PATH="$fb:$PATH" TMPDIR="$second_tmp" FM_HOME="$second_home" FM_ROOT_OVERRIDE="$second_home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_COMPOSER="$composer" FM_FAKE_TMUX_TYPE_HOLD="$hold" FM_SEND_SETTLE=0 \
    bash -c '. "$1/bin/fm-backend.sh"; [ "$(fm_backend_send_text_submit tmux "$2" "second intended steer" 3 0 0)" = empty ]' \
      _ "$ROOT" "$endpoint" >/dev/null 2>"$dir/second.err" &
  second_pid=$!
  /bin/sleep 0.1
  PATH="$fb:$PATH" TMPDIR="$second_tmp" FM_HOME="$second_home" FM_ROOT_OVERRIDE="$second_home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_COMPOSER="$composer" "$SEND" "$endpoint" --key C-c >/dev/null 2>"$dir/key.err" &
  key_pid=$!
  : > "$hold.release"
  wait "$first_pid"; first_rc=$?
  wait "$second_pid"; second_rc=$?
  wait "$key_pid"; key_rc=$?

  expect_code 0 "$first_rc" "the first serialized send should succeed"
  expect_code 0 "$second_rc" "the second serialized send should succeed"
  expect_code 0 "$key_rc" "the serialized composer-mutating key should succeed"
  [ ! -e "$hold.overlap" ] || fail "two sends entered the shared endpoint type boundary concurrently"
  [ "$(grep -c 'literal=1 arg=.* intended steer' "$log")" -eq 2 ] \
    || fail "serialized sends did not each type exactly once: $(cat "$log")"
  pass "fm-send delivery: send and shared injection submit serialize per resolved endpoint"
}

# A --key send is how firstmate interrupts a worker, so its exit status is the
# only signal that the interrupt actually landed.
# Reporting success for a key that was never delivered would leave supervision
# believing a runaway worker had been stopped, so the failing case must exit
# nonzero and name the key.
# Both directions are asserted from one stub so the failing case cannot go
# quietly vacuous if the key ever stops being delivered at all.
test_key_send_exit_status_follows_delivery() {
  local dir fb home err log rc
  dir="$TMP_ROOT/key-exit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home keyexit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-key.meta" "window=sess:fm-lane-key" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a delivered --key interrupt should report success"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-key literal=0 arg=Escape" "the delivered case should send the named key"

  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_SEND_KEY_FAIL=Escape \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an undelivered --key interrupt reported success"
  assert_contains "$(cat "$err")" "key 'Escape' not sent" "the undelivered case should name the key that failed"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-key literal=0 arg=Escape" "the undelivered case should still have attempted the send"
  pass "fm-send --key: exit status follows delivery, and an undelivered key never reports success"
}

test_exact_lane_id_send_still_works
test_key_send_exit_status_follows_delivery
test_stale_composer_refuses_before_typing
test_empty_composer_delivers_intended_text_once
test_busy_queue_confirmation_survives_empty_preflight
test_concurrent_sends_serialize_per_endpoint
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_fm_prefixed_herdr_session_is_an_explicit_target
test_healthy_fm_id_send_still_works
