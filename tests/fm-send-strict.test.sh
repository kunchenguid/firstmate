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
    if [ "$literal" = 1 ] && [ "${FM_FAKE_TMUX_SEND_TEXT_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    # FM_FAKE_TMUX_SEND_KEY_FAIL names one key whose delivery fails, so the
    # --key exit contract can be driven both ways from the same stub.
    if [ "$literal" = 0 ] && [ -n "${FM_FAKE_TMUX_SEND_KEY_FAIL:-}" ] \
      && [ "${1:-}" = "$FM_FAKE_TMUX_SEND_KEY_FAIL" ]; then
      exit 1
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
    if [ -n "${FM_FAKE_TMUX_CAPTURE_BEFORE:-}" ] \
      && [ -n "${FM_FAKE_TMUX_CAPTURE_AFTER:-}" ] \
      && [ -n "${FM_FAKE_TMUX_CAPTURE_COUNT:-}" ]; then
      count=0
      [ ! -f "$FM_FAKE_TMUX_CAPTURE_COUNT" ] || count=$(cat "$FM_FAKE_TMUX_CAPTURE_COUNT")
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_FAKE_TMUX_CAPTURE_COUNT"
      if [ "$count" -eq 1 ]; then
        cat "$FM_FAKE_TMUX_CAPTURE_BEFORE"
      else
        cat "$FM_FAKE_TMUX_CAPTURE_AFTER"
      fi
    elif [ -n "${FM_FAKE_TMUX_CAPTURE_FILE:-}" ]; then
      cat "$FM_FAKE_TMUX_CAPTURE_FILE"
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

test_cursor_idle_placeholders_are_exact_and_scoped() {
  local dir fb home err log capture rc enters
  dir="$TMP_ROOT/cursor-idle"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home cursoridle); err="$dir/send.err"
  log="$dir/tmux.log"; capture="$dir/capture"; : > "$log"
  fm_write_meta "$home/state/codex-idle.meta" \
    "window=sess:fm-codex-idle" "kind=ship" "harness=codex"
  fm_write_meta "$home/state/cursor-idle.meta" \
    "window=sess:fm-cursor-idle" "kind=ship" "harness=cursor"

  printf '╭────────────────────╮\n│ Type a message...  │\n╰────────────────────╯\n' > "$capture"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE_FILE="$capture" \
    FM_SEND_RETRIES=3 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$SEND" codex-idle "hold this text" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a non-Cursor worker accepted Cursor placeholder text as empty"
  enters=$(grep -c 'literal=0 arg=Enter' "$log" 2>/dev/null || true)
  [ "$enters" -eq 3 ] || fail "non-Cursor placeholder text did not consume the retry budget"

  : > "$log"
  printf '╭────────────────────╮\n│→ Type a message...x│\n╰────────────────────╯\n' > "$capture"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE_FILE="$capture" \
    FM_SEND_RETRIES=3 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$SEND" cursor-idle "hold this text" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "Cursor prefix text was accepted as a complete idle placeholder"
  enters=$(grep -c 'literal=0 arg=Enter' "$log" 2>/dev/null || true)
  [ "$enters" -eq 3 ] || fail "Cursor prefix text did not consume the retry budget"

  : > "$log"
  printf '╭────────────────────╮\n│ → Add a follow-up  │\n╰────────────────────╯\n' > "$capture"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE_FILE="$capture" \
    FM_SEND_RETRIES=3 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$SEND" cursor-idle "deliver this text" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "Cursor's exact idle placeholder should confirm delivery"
  enters=$(grep -c 'literal=0 arg=Enter' "$log" 2>/dev/null || true)
  [ "$enters" -eq 1 ] || fail "Cursor's exact placeholder should confirm on the first Enter"
  pass "fm-send: Cursor idle placeholders are exact and harness-scoped"
}

test_cursor_busy_footer_confirms_unknown_submit() {
  local dir fb home err log before after count rc enters
  dir="$TMP_ROOT/cursor-busy-confirm"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home cursorbusy); err="$dir/send.err"
  log="$dir/tmux.log"; before="$dir/before"; after="$dir/after"; count="$dir/captures"
  : > "$log"
  fm_write_meta "$home/state/cursor-busy.meta" \
    "window=sess:fm-cursor-busy" "kind=ship" "harness=cursor"
  printf '╭────────────────────╮\n│ → Add a follow-up  │\n╰────────────────────╯\n' > "$before"
  printf 'Cursor Agent is working\nctrl+c to stop\n' > "$after"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE_BEFORE="$before" \
    FM_FAKE_TMUX_CAPTURE_AFTER="$after" FM_FAKE_TMUX_CAPTURE_COUNT="$count" \
    FM_SEND_RETRIES=3 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$SEND" cursor-busy "deliver this text" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "Cursor busy footer should confirm an otherwise unknown submit"
  enters=$(grep -c 'literal=0 arg=Enter' "$log" 2>/dev/null || true)
  [ "$enters" -eq 1 ] || fail "Cursor busy transition should confirm after one Enter"
  pass "fm-send: Cursor busy footer confirms an unknown tmux submit"
}

test_cursor_placeholder_message_requires_confirmation() {
  local spec name message dir fb home err log capture rc enters
  for spec in 'add|Add a follow-up' 'type|Type a message...'; do
    name=${spec%%|*}
    message=${spec#*|}
    dir="$TMP_ROOT/cursor-placeholder-$name"; mkdir -p "$dir"
    fb=$(make_stubs "$dir"); home=$(setup_home "cursorplaceholder-$name")
    err="$dir/send.err"; log="$dir/tmux.log"; capture="$dir/capture"; : > "$log"
    fm_write_meta "$home/state/cursor-placeholder-$name.meta" \
      "window=sess:fm-cursor-placeholder-$name" "kind=ship" "harness=cursor"
    printf '╭────────────────────────╮\n│ → %-20s │\n╰────────────────────────╯\n' "$message" > "$capture"

    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
      FM_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE_FILE="$capture" \
      FM_SEND_RETRIES=3 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
      "$SEND" "cursor-placeholder-$name" "$message" >/dev/null 2>"$err"; rc=$?
    [ "$rc" -ne 0 ] || fail "Cursor placeholder message '$message' was falsely confirmed"
    enters=$(grep -c 'literal=0 arg=Enter' "$log" 2>/dev/null || true)
    [ "$enters" -eq 3 ] || fail "Cursor placeholder message '$message' did not require confirmation"
  done

  dir="$TMP_ROOT/cursor-placeholder-busy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home cursorplaceholderbusy)
  err="$dir/send.err"; log="$dir/tmux.log"; capture="$dir/capture"; : > "$log"
  fm_write_meta "$home/state/cursor-placeholder-busy.meta" \
    "window=sess:fm-cursor-placeholder-busy" "kind=ship" "harness=cursor"
  printf '╭────────────────────────╮\n│ → Add a follow-up      │\n╰────────────────────────╯\nctrl+c to stop\n' > "$capture"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE_FILE="$capture" \
    FM_SEND_RETRIES=3 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$SEND" cursor-placeholder-busy "Add a follow-up" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "Cursor placeholder message should confirm with busy evidence"
  pass "fm-send: Cursor placeholder messages require transition or busy evidence"
}

test_cursor_backend_failure_uses_actionable_send_error() {
  local dir fb home err log rc
  dir="$TMP_ROOT/cursor-send-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home cursorfail); err="$dir/send.err"
  log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/cursor-send-fail.meta" \
    "window=sess:fm-cursor-send-fail" "kind=ship" "harness=cursor"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_TMUX_LOG="$log" FM_FAKE_TMUX_SEND_TEXT_FAIL=1 FM_SEND_SETTLE=0 \
    "$SEND" cursor-send-fail "deliver this text" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "Cursor backend failure reported successful delivery"
  assert_contains "$(cat "$err")" \
    "text not sent to sess:fm-cursor-send-fail (tmux send failed" \
    "Cursor backend failure bypassed the actionable send error"
  pass "fm-send routes Cursor backend failures through send error handling"
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
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_fm_prefixed_herdr_session_is_an_explicit_target
test_healthy_fm_id_send_still_works
test_cursor_idle_placeholders_are_exact_and_scoped
test_cursor_busy_footer_confirms_unknown_submit
test_cursor_placeholder_message_requires_confirmation
test_cursor_backend_failure_uses_actionable_send_error
