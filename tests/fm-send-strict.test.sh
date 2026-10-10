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
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\nfm-mpf-lane-m8\nfm-lane-ok\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
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
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=: Firstmate instruction waiting" \
    "exact id should ring the doorbell at the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit the doorbell with Enter"
  grep -qF 'lost dispatch' "$home/state/mpf-lane-m8.inbox/001.msg" \
    || fail "exact id should record the steer in the task inbox"
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
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=: Firstmate instruction waiting" \
    "healthy send should ring the doorbell at the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit the doorbell with Enter"
  grep -qF 'hello captain' "$home/state/lane-ok.inbox/001.msg" \
    || fail "healthy send should record the steer in the task inbox"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends record the steer and ring once"
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

# fm-send's option loop used to end in an unconditional `*) break ;;`, so any
# token it did not recognise - including one obviously shaped as a flag - fell
# out of the loop and became the positional message text. A steer invoked with a
# flag that does not exist was durably written into a live worker's steering
# inbox as the literal flag string while fm-send exited 0: the worker was
# mis-steered, and the caller got a success code and no diagnostic. That is the
# one silent, durable, worker-reaching failure mode on this script, so the
# absence of the record is asserted here and not just the exit code - the whole
# point of the defect is that the exit code lied.
test_unknown_flag_is_refused_before_anything_is_recorded() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unknown-flag"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unknownflag); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  # The stub reports fm-lane-ok as a live window, so a send that got past the
  # refusal really would ring: the empty-log assertion below is not vacuous.
  fm_write_meta "$home/state/lane-uf.meta" "window=sess:fm-lane-ok" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-uf --not-a-real-flag some text >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unrecognised flag was accepted instead of refused"
  assert_contains "$(cat "$err")" "unknown flag '--not-a-real-flag'" \
    "the refusal should name the offending token"
  assert_contains "$(cat "$err")" "--resolve-key, --fire-and-forget, and --key" \
    "the refusal should name the flags fm-send actually accepts"
  [ ! -e "$home/state/lane-uf.inbox" ] \
    || fail "the refused flag still created a steering record"$'\n'"$(ls -R "$home/state/lane-uf.inbox")"
  [ ! -s "$log" ] || fail "the refused flag still rang the doorbell"$'\n'"$(cat "$log")"
  pass "fm-send strict: an unrecognised flag is refused, not delivered as the message body"
}

# The refusal is an allowlist, not a pattern. --key is a real, supported flag
# that is parsed AFTER the option loop, so it must keep falling through the loop
# untouched; a blanket "starts with -- and matched no case arm, therefore refuse"
# rule would break it. Its two existing cross-checks are asserted here alongside,
# so a future tightening of the loop cannot swallow them silently.
test_key_flag_still_falls_through_the_allowlist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/key-allowlist"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home keyallow); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ka.meta" "window=sess:fm-lane-ka" "kind=ship"
  printf 'needs-decision [key=k]: choose\n' > "$home/state/lane-ka.status"
  fm_write_meta "$home/state/sm-ka.meta" "window=sess:fm-sm-ka" "kind=secondmate"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-ka --key Enter >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "--key must still reach the key plane, not be refused as unknown"
  assert_no_grep 'unknown flag' "$err" "--key was refused by the unrecognised-flag allowlist"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-ka literal=0 arg=Enter" "--key should still deliver its key"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-ka --resolve-key k --key Enter >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key with --key should still refuse"
  assert_contains "$(cat "$err")" "--resolve-key cannot accompany --key" \
    "the --resolve-key/--key cross-check should keep its exact error"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sm-ka --fire-and-forget 0123456789abcdef --key Enter >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--fire-and-forget with --key should still refuse"
  assert_contains "$(cat "$err")" "--fire-and-forget cannot accompany --key" \
    "the --fire-and-forget/--key cross-check should keep its exact error"
  pass "fm-send strict: --key stays in the allowlist and its cross-checks keep their errors"
}

# A message whose text legitimately begins with a single dash must remain
# sendable. Only a --<token> is refused, so a single-dash word is still plain
# text and needs no ceremony.
test_leading_dash_messages_still_send() {
  local dir fb home err log rc
  dir="$TMP_ROOT/leading-dash"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home leadingdash); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  # fm-lane-ok is the stub's live window, so the doorbell really rings here.
  fm_write_meta "$home/state/lane-ld.meta" "window=sess:fm-lane-ok" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-ld "-1 means failure" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a single-dash message should still send"
  grep -qF -- '-1 means failure' "$home/state/lane-ld.inbox/001.msg" \
    || fail "the single-dash message was not recorded verbatim"
  pass "fm-send strict: a single-dash message is still text, not a flag"
}

# The option loop breaks at --key without consuming anything after it, and the
# key path reads only the key itself, so every remaining argument used to be
# discarded in silence while the key was still delivered and the command still
# exited 0. That is the same silent-delivery shape this script's unknown-flag
# refusal exists to remove, so the key path must refuse a trailing argument
# rather than drop it. The absence of the keystroke is asserted, not just the
# exit code, because the defect was that delivery happened anyway.
test_trailing_arguments_after_key_are_refused() {
  local dir fb home err log rc
  dir="$TMP_ROOT/key-trailing"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home keytrailing); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-kt.meta" "window=sess:fm-lane-kt" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-kt --key Enter --not-a-real-flag >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a trailing argument after --key was accepted instead of refused"
  assert_contains "$(cat "$err")" "--not-a-real-flag" \
    "the refusal should name the discarded argument"
  assert_no_grep 'literal=0 arg=Enter' "$log" \
    "the key was still delivered despite the trailing argument being refused"

  # A trailing plain word is the same defect without the flag shape.
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-kt --key Enter stray >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a trailing word after --key was accepted instead of refused"
  assert_no_grep 'literal=0 arg=Enter' "$log" \
    "the key was still delivered despite a trailing word being refused"
  pass "fm-send strict: --key refuses a trailing argument instead of silently discarding it"
}

# The --fire-and-forget/--key incompatibility used to hold only when the flag
# came first, because FIRE_AND_FORGET_ID is set by the option loop and the loop
# breaks at --key. Reversing the order bypassed both that check and the
# --resolve-key glob beside it. The guard must hold on either ordering.
test_fire_and_forget_with_key_is_refused_in_either_order() {
  local dir fb home err log rc
  dir="$TMP_ROOT/key-faf-order"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home keyfaforder); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/sm-fo.meta" "window=sess:fm-sm-fo" "kind=secondmate"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sm-fo --fire-and-forget 0123456789abcdef --key Enter >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--fire-and-forget before --key should be refused"
  assert_contains "$(cat "$err")" "--fire-and-forget cannot accompany --key" \
    "the flag-first ordering should keep its exact error"

  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sm-fo --key Enter --fire-and-forget 0123456789abcdef >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--fire-and-forget after --key should be refused too"
  assert_contains "$(cat "$err")" "--fire-and-forget cannot accompany --key" \
    "the key-first ordering should give the same incompatibility error"
  assert_no_grep 'literal=0 arg=Enter' "$log" \
    "the key was still delivered despite the incompatible flag being refused"
  pass "fm-send strict: --fire-and-forget and --key are incompatible in either order"
}

test_exact_lane_id_send_still_works
test_key_send_exit_status_follows_delivery
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_fm_prefixed_herdr_session_is_an_explicit_target
test_healthy_fm_id_send_still_works
test_unknown_flag_is_refused_before_anything_is_recorded
test_key_flag_still_falls_through_the_allowlist
test_leading_dash_messages_still_send
test_trailing_arguments_after_key_are_refused
test_fire_and_forget_with_key_is_refused_in_either_order
