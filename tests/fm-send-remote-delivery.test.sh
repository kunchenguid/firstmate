#!/usr/bin/env bash
# fm-send remote-secondmate delivery reporting.
#
# The remote send leg (fm-on.sh -> fm-remote-secondmate-control.sh cmd_send)
# runs fm-send's own verified submit host-locally on the remote machine and
# relays its exit status unchanged. A leg that delivered the text into the
# live verified pane but could not synchronously confirm the submit exits 3
# (the delivered-unconfirmed contract in bin/fm-send.sh's header); flattening
# that into a generic failure produced the false "error: text not sent"
# report that tempted duplicate resends of steers that had actually landed.
# These tests pin the delivery-reporting contract over the real fm-send +
# fm-on executables with a stubbed ssh transport (FM_SSH_BIN seam - the same
# process boundary tests/fm-on.test.sh proves preserves exit status):
#   1. Remote delivered-unconfirmed (ssh exit 3) is NOT a failure: exit 0, a
#      non-error delivered notice, the inner leg's stderr held back, and the
#      pending-reply expectation marked delivered (awaiting_report).
#   2. A real remote failure (nonzero, not 3/255) still fails loudly with the
#      remote stderr replayed and the undelivered expectation discarded.
#   3. Transport-unknown (ssh exit 255) still refuses loudly and preserves the
#      expectation as delivery_unknown.
#   4. A delivered-unconfirmed remote answer still closes its --resolve-key
#      decision (delivered-with-pending-confirmation counts as delivered).
#   5. A LOCAL typed-plane send (an explicit backend target, mirroring the
#      remote leg's inner send) whose submit read-back stays pending exits 3
#      with an honest non-error message (text delivered, submission
#      unconfirmed). Ordinary text steers to recorded tasks ride the durable
#      inbox instead and never reach this ladder.
#   6. A local typed-plane unconfirmed send (a harness-native slash answer)
#      still never closes a --resolve-key decision, and an unconfirmed typed
#      secondmate send keeps its reply expectation armed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-remote-delivery)

# Stub tmux for the local legs: logs literal typed text to FM_SEND_LOG. The
# default composer reads empty (clean submit); FM_FAKE_TMUX_PENDING=1 keeps a
# proven pending composer with no busy footer, so the real submit core
# exhausts its Enter budget and reports the pending verdict. The ssh stub
# records the invocation, emits FM_FAKE_SSH_STDERR as the remote leg's stderr,
# and exits FM_FAKE_SSH_RC - the exact relay contract the real transport
# preserves.
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
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ "${FM_FAKE_TMUX_PENDING:-0}" = 1 ]; then
      printf '╭────────────╮\n│ > steer    │\n╰────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "$FM_SSH_LOG"
[ -z "${FM_FAKE_SSH_STDERR:-}" ] || printf '%s\n' "$FM_FAKE_SSH_STDERR" >&2
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes a fresh home dir with an empty state/
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# A home with a remote-secondmate task meta plus the registry row fm-on.sh
# resolves the ssh route from - the same shape a live remote mate records.
setup_remote_home() {  # <name> -> echoes home dir
  local home
  home=$(setup_home "$1")
  mkdir -p "$home/data"
  fm_write_meta "$home/state/rsm.meta" \
    "window=fm-remote:w1:p1" \
    "endpoint_task_id=rsm" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  cat > "$home/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  printf '%s\n' "$home"
}

# The single non-dot pending-reply record in <home>, or empty.
pending_record() {  # <home>
  find "$1/state/pending-replies" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | head -1
}

drain_out() {  # <home>
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" 2>/dev/null
}

test_remote_delivered_unconfirmed_is_not_failure() {
  local dir fb log ssh_log home rc err rec
  dir="$TMP_ROOT/remote-du"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-du)

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=3 \
    FM_FAKE_SSH_STDERR='fm-send: text delivered to fm-remote:w1:p1 but submission is unconfirmed (verdict=pending; tried meta=/remote/home/state/fm-remote:w1:p1.meta; metadata window/terminal lookup; backend=herdr; endpoint=verified)' \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err"; rc=$?
  err=$(cat "$dir/err")
  expect_code 0 "$rc" "a delivered-unconfirmed remote send must not exit as a failure"
  assert_grep 'fm-remote-entrypoint.sh' "$ssh_log" "the steer should cross the remote transport"
  assert_contains "$err" "delivered to remote secondmate rsm" \
    "the outcome must be reported as delivered"
  assert_not_contains "$err" "text not sent" "a delivered steer must not read as not sent"
  assert_not_contains "$err" "not submitted" "a delivered steer must not read as not submitted"
  assert_not_contains "$err" "error: text" "a delivered steer must not carry an error-styled report"
  assert_not_contains "$err" "verdict=pending" \
    "the inner leg's unconfirmed diagnostics must be held back on a delivered outcome"

  rec=$(pending_record "$home")
  [ -n "$rec" ] || fail "the pending-reply expectation must survive a delivered-unconfirmed send"
  [ -n "$(grep '^delivered_epoch=' "$rec" | cut -d= -f2-)" ] \
    || fail "a delivered-unconfirmed send must mark the expectation delivered: $(cat "$rec")"
  [ "$(grep '^phase=' "$rec" | tail -1 | cut -d= -f2-)" = awaiting_report ] \
    || fail "a delivered-unconfirmed send must leave the expectation awaiting its report: $(cat "$rec")"
  pass "fm-send remote: delivered-unconfirmed reports delivered, exits 0, keeps the expectation armed"
}

test_remote_real_failure_still_fails() {
  local dir fb log ssh_log home rc err
  dir="$TMP_ROOT/remote-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-fail)

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=1 \
    FM_FAKE_SSH_STDERR='error: remote secondmate rsm endpoint metadata is invalid; refusing access until it is explicitly migrated' \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err"; rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "a genuinely failed remote send must exit nonzero"
  assert_contains "$err" "error: text not sent to remote:rsm" \
    "a real remote failure must still report a real error"
  assert_contains "$err" "endpoint metadata is invalid" \
    "a real remote failure must replay the remote leg's own stderr"
  [ -z "$(pending_record "$home")" ] \
    || fail "a failed send must discard its undelivered expectation"
  pass "fm-send remote: a real remote failure still fails loudly with the remote diagnostics"
}

test_remote_transport_unknown_preserves_expectation() {
  local dir fb log ssh_log home rc err rec
  dir="$TMP_ROOT/remote-255"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-255)

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=255 \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err"; rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "an unknown-completion transport loss must exit nonzero"
  assert_contains "$err" "delivery to remote secondmate rsm is unknown" \
    "transport loss must be reported as unknown delivery, not silently dropped"
  rec=$(pending_record "$home")
  [ -n "$rec" ] || fail "transport loss must preserve the expectation for reconciliation"
  [ "$(grep '^phase=' "$rec" | tail -1 | cut -d= -f2-)" = delivery_unknown ] \
    || fail "transport loss must move the expectation to delivery_unknown: $(cat "$rec")"
  pass "fm-send remote: ssh 255 still refuses loudly and preserves the expectation as delivery_unknown"
}

test_remote_delivered_unconfirmed_closes_resolve_key() {
  local dir fb log ssh_log home rc out
  dir="$TMP_ROOT/remote-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-key)
  printf 'needs-decision [key=upgrade-window]: tonight or the weekend\n' > "$home/state/rsm.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=3 \
    "$SEND" rsm --resolve-key upgrade-window "the weekend, freeze Friday" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a delivered-unconfirmed remote answer must not exit as a failure"
  grep -F 'resolved [key=upgrade-window]: answered: the weekend, freeze Friday' "$home/state/rsm.status" >/dev/null \
    || fail "a delivered-unconfirmed remote answer must close the decision: $(cat "$home/state/rsm.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision still lists as open after a delivered-unconfirmed answer: $out"
  fi
  pass "fm-send remote: a delivered-unconfirmed answer closes its --resolve-key decision"
}

test_local_secondmate_pending_keeps_expectation_armed() {
  local dir fb log home rc rec corr
  dir="$TMP_ROOT/local-pending-expectation"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home local-pending-expectation)
  fm_write_meta "$home/state/lsm.meta" \
    "window=sess:fm-lsm" "harness=claude" "kind=secondmate" "mode=secondmate" "home=$home/sm"

  # A harness-native slash invocation keeps the typed plane even for a marked
  # secondmate target, so this pins the kept armed-expectation semantics there.
  : > "$log"
  env PATH="$fb:$PATH" FM_FAKE_TMUX_PENDING=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lsm "/audit the ledger" >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "an unconfirmed local secondmate submit must exit delivered-unconfirmed"
  rec=$(pending_record "$home")
  [ -n "$rec" ] \
    || fail "the pending-reply expectation must survive an unconfirmed local secondmate send"
  [ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ] \
    || fail "the surviving expectation must stay armed, got $(fm_pending_reply_get "$rec" phase)"
  # Armed means resolvable: the mate's correlated report still closes it.
  corr=$(fm_pending_reply_get "$rec" corr_id)
  printf 'done [corr=%s]: ledger clean\n' "$corr" > "$home/state/lsm.status"
  fm_pending_reply_try_resolve "$home/state" "$corr" \
    || fail "a correlated report must still resolve the preserved expectation"
  pass "fm-send local: an unconfirmed secondmate send keeps its reply expectation armed"
}

test_local_pending_reports_delivered_unconfirmed() {
  local dir fb log home rc err
  dir="$TMP_ROOT/local-pending"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home local-pending)

  # An explicit backend target is the typed plane - the same shape the remote
  # leg's inner send runs host-locally - so the exit-3 ladder still governs it.
  : > "$log"
  env PATH="$fb:$PATH" FM_FAKE_TMUX_PENDING=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "steer text" >"$dir/out" 2>"$dir/err"; rc=$?
  err=$(cat "$dir/err")
  expect_code 3 "$rc" "an unconfirmed local submit must exit with the delivered-unconfirmed status"
  assert_contains "$err" "submission is unconfirmed" \
    "the unconfirmed local submit must be described honestly"
  assert_not_contains "$err" "not submitted" \
    "an unconfirmed local submit must not claim the text was not submitted"
  assert_not_contains "$err" "error:" \
    "an unconfirmed local submit must not carry an error-styled report"
  pass "fm-send local: an unconfirmed submit exits 3 with an honest non-error report"
}

test_local_pending_does_not_close_resolve_key() {
  local dir fb log home rc out
  dir="$TMP_ROOT/local-pending-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home local-pending-key)
  fm_write_meta "$home/state/t2.meta" "window=sess:fm-t2" "kind=ship"
  printf 'blocked [key=creds]: need the deploy token\n' > "$home/state/t2.status"

  # A harness-native slash answer keeps the typed plane, so the unconfirmed
  # ladder still governs it; a plain-text answer would close at enqueue instead.
  : > "$log"
  env PATH="$fb:$PATH" FM_FAKE_TMUX_PENDING=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t2 --resolve-key creds "/vault fetch deploy-token" >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "an unconfirmed local answer must exit with the delivered-unconfirmed status"
  if grep -F 'resolved' "$home/state/t2.status" >/dev/null; then
    fail "an unconfirmed local answer must not close the decision: $(cat "$home/state/t2.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=creds]' >/dev/null \
    || fail "the blocker must stay open after an unconfirmed local answer: $out"
  pass "fm-send local: an unconfirmed submit still never closes a --resolve-key decision"
}

test_remote_delivered_unconfirmed_is_not_failure
test_remote_real_failure_still_fails
test_remote_transport_unknown_preserves_expectation
test_remote_delivered_unconfirmed_closes_resolve_key
test_local_pending_reports_delivered_unconfirmed
test_local_pending_does_not_close_resolve_key
test_local_secondmate_pending_keeps_expectation_armed

echo "all fm-send-remote-delivery tests passed"
