#!/usr/bin/env bash
# fm-send remote-secondmate delivery: the remote inbox leg.
#
# A remote steer is delivered by durable record, never by typing its payload:
# fm-send crosses fm-on.sh to the host-local leg (fm-remote-secondmate-control.sh
# cmd_send_stdin), which writes the message idempotently into the remote home's
# steering inbox and rings the remote doorbell best-effort. These tests drive
# the real fm-send + fm-on executables with a stubbed ssh transport that
# EXECUTES the real host-local leg against a seeded remote-home fixture (the
# FM_SSH_BIN seam tests/fm-on.test.sh proves preserves exit status), and pin:
#   1. A remote text steer lands as a durable record in the remote home's
#      steering inbox, marker and corr token in the body, exits 0, and marks
#      the pending-reply expectation delivered at enqueue; a failed doorbell
#      never fails the send.
#   2. Re-running the identical leg is idempotent: an ambiguous transport
#      (executed remotely, then ssh exit 255) makes fm-send retry the same
#      leg once, and the remote inbox holds exactly ONE record afterwards.
#   3. A remote --resolve-key answer closes its decision at enqueue.
#   4. A remote harness-native "/..." steer also rides the inbox: the deleted
#      remote typed-payload plane is gone for every remote text.
#   5. A real remote failure still fails loudly with the remote leg's own
#      stderr and discards the undelivered expectation.
#   6. The deleted exit-3-as-delivered remap is GONE: a nonzero remote leg
#      status is a failure, never reported as delivered.
#   7. Pure transport loss (ssh 255 twice, nothing executed) fails with
#      resend-safe guidance - the deleted "do not resend" trap is gone - and
#      preserves the marked expectation for the record that may have landed.
#   8. A LOCAL typed-plane send (an explicit backend target or harness-native
#      slash) keeps its exit-3 delivered-unconfirmed contract, never closes a
#      --resolve-key decision unconfirmed, and keeps a marked expectation
#      armed.
#   9. The parent's reply tracker reads the remote inbox through the real
#      inbox-status leg (scenarios observed live on PR #7369): an unread
#      request escalates once, a lost-reply record that landed is marked
#      delivered without a resend, an unlanded record is resent once under its
#      correlation with a failed read never delaying the recheck, and the
#      resend's acknowledgement resolves the record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-remote-delivery)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub tmux for the local typed-plane legs: logs literal typed text to
# FM_SEND_LOG. The default composer reads empty (clean submit);
# FM_FAKE_TMUX_PENDING=1 keeps a proven pending composer with no busy footer,
# so the real submit core exhausts its Enter budget and reports the pending
# verdict. The ssh stub counts invocations, logs the wire line, and either
# fails with FM_FAKE_SSH_RC (emitting FM_FAKE_SSH_STDERR as the remote
# stderr), or decodes the entrypoint argv and executes the REAL host-local
# command against the decoded remote home - with FM_FAKE_SSH_AMBIGUOUS=1
# reporting ssh exit 255 after that execution (completion unknown, but the
# remote leg actually ran).
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
  list-windows) printf '%s\n' win fm-t2 fm-lsm; exit 0 ;;
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
set -u
count=$(cat "$FM_SSH_COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$FM_SSH_COUNT"
printf '%s\n' "$*" >> "$FM_SSH_LOG"
stdin_file="$FM_SSH_LOG.stdin.$count"
cat > "$stdin_file"
if [ -n "${FM_FAKE_SSH_HANG:-}" ]; then
  # A busy remote lane: the transport attempt never returns on its own. The
  # real sleep, because the stubbed one on PATH returns immediately.
  /bin/sleep "$FM_FAKE_SSH_HANG"
  exit 255
fi
if [ "${FM_FAKE_SSH_AFTER_AMBIGUOUS_RC:-0}" -ne 0 ] && [ "$count" -gt 1 ]; then
  exit "$FM_FAKE_SSH_AFTER_AMBIGUOUS_RC"
fi
if [ "${FM_FAKE_SSH_RC:-0}" -ne 0 ]; then
  [ -z "${FM_FAKE_SSH_STDERR:-}" ] || printf '%s\n' "$FM_FAKE_SSH_STDERR" >&2
  exit "${FM_FAKE_SSH_RC}"
fi
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2  # host, fm-remote-entrypoint.sh
home_b64=$3
argv_b64=$4
[ "${#argv_b64}" -le "${FM_FAKE_SSH_ARG_MAX:-32768}" ] || exit 255
remote_home=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$home_b64")
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done \
  < <(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$argv_b64")
cmd=${rargs[0]}
rc=0
# FM_FAKE_SSH_FAIL_SUBCMD makes one host-local leg unreachable while the rest
# of the transport answers (or fail outright with FM_FAKE_SSH_FAIL_SUBCMD_RC), and FM_FAKE_SSH_USAGE_SUBCMD makes one leg answer
# as a remote copy that does not have it. A mate that cannot take a turn has no herdr pane in
# this fixture, so its busy/idle observation is the one thing the fixture
# answers itself.
if [ -n "${FM_FAKE_SSH_FAIL_SUBCMD:-}" ] && [ "${rargs[1]:-}" = "$FM_FAKE_SSH_FAIL_SUBCMD" ]; then
  exit "${FM_FAKE_SSH_FAIL_SUBCMD_RC:-255}"
fi
# A remote copy that predates a leg answers it with the script's usage text
# and exit 2, and no schema line.
if [ -n "${FM_FAKE_SSH_USAGE_SUBCMD:-}" ] && [ "${rargs[1]:-}" = "$FM_FAKE_SSH_USAGE_SUBCMD" ]; then
  printf 'fm-remote-secondmate-control.sh <command> ...\n'
  exit 2
fi
if [ -n "${FM_FAKE_SSH_OBSERVE:-}" ] && [ "${rargs[0]}" = fm-remote-secondmate-control.sh ] \
  && [ "${rargs[1]:-}" = observe ]; then
  printf '%s\n' "$FM_FAKE_SSH_OBSERVE"
  exit 0
fi
env FM_HOME="$remote_home" FM_ROOT_OVERRIDE="$FM_REMOTE_CODE_ROOT" \
  "$FM_REMOTE_CODE_ROOT/bin/$cmd" "${rargs[@]:1}" < "$stdin_file" || rc=$?
if [ "${FM_FAKE_SSH_AMBIGUOUS:-0}" = 1 ] \
  || { [ "${FM_FAKE_SSH_AFTER_AMBIGUOUS_RC:-0}" -ne 0 ] && [ "$count" -eq 1 ]; }; then
  exit 255
fi
exit "$rc"
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes a fresh home dir with an empty state/
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# A seeded remote secondmate home the executed host-local leg validates and
# writes into: identity marker, Firstmate-checkout shape, and a parent-route
# endpoint record on Herdr in the dedicated fm-remote session.
setup_remote_secondmate_home() {  # <name> -> echoes remote home dir
  local rh="$TMP_ROOT/$1-rhome"
  mkdir -p "$rh/state/parent-route" "$rh/bin"
  printf 'rsm\n' > "$rh/.fm-secondmate-home"
  printf '# remote secondmate home fixture\n' > "$rh/AGENTS.md"
  fm_write_meta "$rh/state/parent-route/rsm.meta" \
    "window=fm-remote:p1" \
    "worktree=-" \
    "project=-" \
    "backend=herdr" \
    "endpoint_task_id=rsm" \
    "harness=claude" \
    "herdr_session=fm-remote" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=t1" \
    "herdr_pane_id=p1"
  printf '%s\n' "$rh"
}

# A parent home with a remote-secondmate task meta plus the registry row
# fm-on.sh resolves the ssh route from, pointing at <remote-home>.
setup_remote_parent_home() {  # <name> <remote-home> -> echoes home dir
  local home
  home=$(setup_home "$1")
  mkdir -p "$home/data"
  fm_write_meta "$home/state/rsm.meta" \
    "window=fm-remote:p1" \
    "endpoint_task_id=rsm" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:p1"
  cat > "$home/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: $2; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  printf '%s\n' "$home"
}

remote_inbox_records() {  # <remote-home>
  find "$1/state/parent-route/rsm.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null
}

# The single non-dot pending-reply record in <home>, or empty.
pending_record() {  # <home>
  find "$1/state/pending-replies" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | head -1
}

drain_out() {  # <home>
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" 2>/dev/null
}

send_env() {  # <fakebin> <parent-home> <ssh-log> [extra env...] -- <cmd...>
  local fb=$1 home=$2 ssh_log=$3
  shift 3
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" \
    FM_SSH_COUNT="$ssh_log.count" FM_REMOTE_CODE_ROOT="$ROOT" \
    "$@"
}

test_remote_large_steer_uses_stdin() {
  local dir fb ssh_log home rhome rc rec
  dir="$TMP_ROOT/remote-large"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-large)
  home=$(setup_remote_parent_home remote-large "$rhome")
  python3 - "$dir/expected" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    f.write("large steer " + "x" * 46000)
PY

  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_ARG_MAX=32768 \
    "$SEND" rsm "$(cat "$dir/expected")" >"$dir/out" 2>"$dir/err" || rc=$?
  expect_code 0 "$rc" "a large remote steer must be delivered through the remote stdin channel: $(cat "$dir/err")"
  rec=$(remote_inbox_records "$rhome" | head -1)
  [ -n "$rec" ] || fail "the large remote steer must land in the remote steering inbox"
  python3 - "$dir/expected" "$ssh_log.stdin.1" "$rec" <<'PY'
import sys
expected = open(sys.argv[1]).read()
stdin_payload = open(sys.argv[2]).read()
record = open(sys.argv[3]).read()
if expected not in stdin_payload:
    raise SystemExit("the large remote steer did not cross the SSH transport on stdin")
if expected not in record:
    raise SystemExit("remote inbox record omitted the large steer body")
PY
  pass "fm-send remote: large text steers use stdin instead of the SSH exec argument"
}

test_remote_steer_lands_in_remote_inbox() {
  local dir fb ssh_log home rhome rc err rec recs body pend
  dir="$TMP_ROOT/remote-inbox"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-inbox)
  home=$(setup_remote_parent_home remote-inbox "$rhome")

  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  expect_code 0 "$rc" "a durably recorded remote steer must exit 0: $err"
  assert_grep 'fm-remote-entrypoint.sh' "$ssh_log" "the steer should cross the remote transport"
  recs=$(remote_inbox_records "$rhome")
  [ -n "$recs" ] || fail "the steer must land as a record in the remote steering inbox"
  rec=$(printf '%s\n' "$recs" | head -1)
  body=$(cat "$rec")
  case "$body" in
    *"please rename the metric"*) : ;;
    *) fail "the remote record must carry the steer text: $body" ;;
  esac
  printf '%s' "$body" | grep -Eq 'corr=[a-f0-9]{16}' \
    || fail "the remote record must carry the marked request's corr token: $body"
  case "$body" in
    *"$FM_FROMFIRST_MARK"*) : ;;
    *) fail "the remote record must carry the from-firstmate marker: $body" ;;
  esac
  # The doorbell could not reach the fixture pane (no herdr CLI here); that
  # never fails the send, and the notice still names the durable record.
  assert_contains "$err" "durably recorded" \
    "a failed doorbell must be reported as a notice on a durably sent steer"
  assert_not_contains "$err" "error:" "a durably recorded steer must not carry an error report"
  pend=$(pending_record "$home")
  [ -n "$pend" ] || fail "the marked remote steer must keep its pending-reply expectation"
  [ -n "$(grep '^delivered_epoch=' "$pend" | cut -d= -f2-)" ] \
    || fail "a recorded remote steer must mark the expectation delivered at enqueue: $(cat "$pend")"
  [ "$(grep '^phase=' "$pend" | tail -1 | cut -d= -f2-)" = awaiting_report ] \
    || fail "the delivered expectation must await its report: $(cat "$pend")"
  pass "fm-send remote: a text steer lands as a durable remote inbox record and exits 0 at enqueue"
}

test_remote_rerun_is_idempotent() {
  local dir fb ssh_log home rhome rc err count pend corr expected_cmd arg quoted rec ssh_before resend_cmd
  dir="$TMP_ROOT/remote-idem"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-idem)
  home=$(setup_remote_parent_home remote-idem "$rhome")

  # Ambiguous transport: the remote leg executes for real, then ssh reports
  # 255 (completion unknown). fm-send retries the identical leg once; the
  # idempotent remote write must land both executions on the same record.
  rc=0
  (
    cd "$TMP_ROOT" || exit 1
    send_env "$fb" "${home#"$TMP_ROOT/"}" "$ssh_log" FM_FAKE_SSH_AMBIGUOUS=1 \
      "$SEND" rsm "please rename the metric"
  ) >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "a twice-lost transport must not claim confirmed delivery"
  [ "$(cat "$ssh_log.count")" = 2 ] \
    || fail "fm-send must retry the identical remote leg exactly once after ssh 255, got $(cat "$ssh_log.count") attempts"
  count=$(remote_inbox_records "$rhome" | grep -c . || true)
  [ "$count" = 1 ] \
    || fail "re-running the remote leg must dedup onto one record, found $count:"$'\n'"$(remote_inbox_records "$rhome")"
  assert_contains "$err" "Only the correlation-reusing resend below is idempotent" \
    "an unconfirmed remote steer must limit resend safety to correlation reuse"
  assert_not_contains "$err" "do not resend" \
    "the deleted do-not-resend trap must be gone for an unconfirmed remote steer"
  pend=$(pending_record "$home")
  [ -n "$pend" ] || fail "an unconfirmed remote steer must preserve its expectation for the record that may have landed"
  [ "$(grep '^phase=' "$pend" | tail -1 | cut -d= -f2-)" = delivery_unknown ] \
    || fail "the preserved expectation must record unknown delivery: $(cat "$pend")"
  corr=$(fm_pending_reply_get "$pend" corr_id)
  printf -v quoted '%q' "$home"
  expected_cmd="FM_HOME=$quoted FM_PENDING_REPLY_EXISTING_CORR=$corr"
  for arg in "$SEND" rsm "please rename the metric"; do
    printf -v quoted '%q' "$arg"
    expected_cmd="$expected_cmd $quoted"
  done
  assert_contains "$err" "$expected_cmd" \
    "double transport loss must print the exact correlation-reusing resend command"

  # A delivered record escalated for a missed report is genuinely stale: the
  # request reached the mate, so the same correlation must never be resent.
  fm_pending_reply_set "$pend" delivered_epoch 4242 \
    || fail "could not mark the fixture expectation delivered"
  fm_pending_reply_set "$pend" phase escalated \
    || fail "could not advance the delivered expectation to the escalated fixture phase"
  ssh_before=$(cat "$ssh_log.count")
  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SEND" rsm "please rename the metric" >"$dir/stale-resend.out" 2>"$dir/stale-resend.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "an explicitly requested non-reusable correlation must fail closed"
  assert_contains "$(cat "$dir/stale-resend.err")" "refusing to mint a replacement correlation" \
    "a stale explicit correlation must explain that no replacement was minted"
  [ "$(cat "$ssh_log.count")" = "$ssh_before" ] \
    || fail "a stale explicit correlation reached the remote transport"
  [ "$(find "$home/state/pending-replies" -maxdepth 1 -type f ! -name '.*' | wc -l | tr -d ' ')" = 1 ] \
    || fail "a stale explicit correlation minted a replacement expectation"
  [ "$(find "$rhome/state/parent-route/rsm.inbox" -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "a stale explicit correlation created another remote record"
  # The watcher escalates an unknown delivery as soon as it sees it, so the
  # printed resend routinely meets an escalated but still undelivered record;
  # that record stays the owner's to resend under the same correlation.
  fm_pending_reply_set "$pend" delivered_epoch "" \
    || fail "could not restore the undelivered fixture expectation"
  [ "$(fm_pending_reply_get "$pend" phase)" = escalated ] \
    || fail "the undelivered fixture expectation must remain escalated before the resend"

  resend_cmd=$(tail -1 "$dir/err")
  rc=0
  (
    unset FM_HOME
    env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_SETTLE=0 \
      FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" \
      FM_SSH_COUNT="$ssh_log.count" FM_REMOTE_CODE_ROOT="$ROOT" \
      bash -c "$resend_cmd"
  ) >"$dir/resend.out" 2>"$dir/resend.err" || rc=$?
  expect_code 0 "$rc" "the printed correlation-reusing resend must succeed without an inherited FM_HOME"
  count=$(find "$rhome/state/parent-route/rsm.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "the correlation-reusing resend must leave exactly one remote record, found $count"
  rec=$(find "$rhome/state/parent-route/rsm.inbox" -name '*.msg' | head -1)
  grep -F "corr=$corr" "$rec" >/dev/null \
    || fail "the deduplicated remote record did not preserve correlation $corr"
  [ -n "$(fm_pending_reply_get "$pend" delivered_epoch)" ] \
    || fail "the successful resend did not confirm pending-reply delivery: $(cat "$pend")"
  [ "$(fm_pending_reply_get "$pend" phase)" = awaiting_report ] \
    || fail "the successful resend did not restore awaiting_report: $(cat "$pend")"
  pass "fm-send remote: the printed correlation-reusing resend deduplicates onto the same record"
}

test_remote_retry_failure_preserves_ambiguous_expectation() {
  local dir fb ssh_log home rhome rc err pend
  dir="$TMP_ROOT/remote-ambiguous-then-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-ambiguous-then-fail)
  home=$(setup_remote_parent_home remote-ambiguous-then-fail "$rhome")

  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_AFTER_AMBIGUOUS_RC=1 \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "a failed retry after unknown completion must not claim delivery"
  assert_contains "$err" "first transport attempt had unknown completion" \
    "the final error must retain the first attempt's ambiguous completion"
  pend=$(pending_record "$home")
  [ -n "$pend" ] || fail "an ambiguous first attempt must preserve its expectation when the retry fails"
  [ "$(grep '^phase=' "$pend" | tail -1 | cut -d= -f2-)" = delivery_unknown ] \
    || fail "the ambiguous expectation must remain delivery_unknown after a failed retry: $(cat "$pend")"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 1 ] \
    || fail "the first attempt's durable record must remain the sole remote record"
  pass "fm-send remote: a failed retry cannot erase an earlier ambiguous delivery"
}

test_remote_fire_and_forget_never_arms_reply_recovery() {
  local dir fb ssh_log home rhome rc count delivery action
  dir="$TMP_ROOT/remote-fire-and-forget"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-fire-and-forget)
  home=$(setup_remote_parent_home remote-fire-and-forget "$rhome")
  delivery=0123456789abcdef

  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_AFTER_AMBIGUOUS_RC=1 \
    "$SEND" rsm --fire-and-forget "$delivery" "reconcile your own books" \
    >"$dir/out" 2>"$dir/err" || rc=$?
  expect_code 3 "$rc" "an ambiguous fire-and-forget delivery must report unconfirmed"
  [ "$(find "$home/state/pending-replies" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
    || fail "fire-and-forget delivery created a pending-reply expectation"
  count=$(find "$rhome/state/parent-route/rsm.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "the ambiguous fire-and-forget delivery did not land exactly once"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    fm_task_inbox_due_action "$rhome/state/parent-route" rsm)
  [ "$action" = quiet ] || fail "the remote fire-and-forget record armed inbox escalation: $action"

  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm --fire-and-forget "$delivery" "reconcile your own books" \
    >"$dir/retry.out" 2>"$dir/retry.err" \
    || fail "the fire-and-forget retry failed"
  count=$(find "$rhome/state/parent-route/rsm.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "the same fire-and-forget delivery id created a duplicate remote record"
  grep -F "delivery=$delivery" "$(remote_inbox_records "$rhome" | head -1)" >/dev/null \
    || fail "the remote record omitted its fire-and-forget delivery identity"
  pass "fm-send remote: fire-and-forget delivery is idempotent without reply recovery"
}

test_remote_send_revalidates_after_retirement_lock() {
  local dir rhome meta lock ready release rc sender_pid holder_pid
  dir="$TMP_ROOT/remote-retire-race"; mkdir -p "$dir"
  rhome=$(setup_remote_secondmate_home remote-retire-race)
  meta="$rhome/state/parent-route/rsm.meta"
  lock="$rhome/state/parent-route/.meta-rsm.lock"
  ready="$dir/lock-ready"
  release="$dir/release-lock"
  FM_STATE_OVERRIDE="$rhome/state/parent-route" bash -c '
    . "$1"
    fm_task_inbox_lock_acquire "$2" || exit 91
    : > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    rm -f "$5"
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$lock" "$ready" "$release" "$meta" &
  holder_pid=$!
  while [ ! -e "$ready" ]; do kill -0 "$holder_pid" 2>/dev/null || fail "metadata-lock holder exited early"; sleep 0.05; done

  rc=0
  env FM_HOME="$rhome" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" send rsm "retirement-race steer" \
    >"$dir/out" 2>"$dir/err" &
  sender_pid=$!
  sleep 0.2
  : > "$release"
  wait "$sender_pid" || rc=$?
  wait "$holder_pid" || fail "metadata-lock holder failed"
  [ "$rc" -ne 0 ] || fail "a send must not enqueue after endpoint retirement won the metadata lock"
  [ -z "$(remote_inbox_records "$rhome")" ] \
    || fail "a send re-created an orphan inbox after endpoint retirement"
  pass "remote control: send revalidates endpoint ownership under the metadata lock"
}

test_remote_send_revalidates_parent_route_after_retirement_lock() {
  local dir fb ssh_log home rhome meta lock ready release rc sender_pid holder_pid
  dir="$TMP_ROOT/remote-parent-retire-race"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-parent-retire-race)
  home=$(setup_remote_parent_home remote-parent-retire-race "$rhome")
  meta="$home/state/rsm.meta"
  lock="$home/state/.meta-rsm.lock"
  ready="$dir/lock-ready"
  release="$dir/release-lock"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_task_inbox_lock_acquire "$2" || exit 91
    : > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    rm -f "$5"
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$lock" "$ready" "$release" "$meta" &
  holder_pid=$!
  while [ ! -e "$ready" ]; do kill -0 "$holder_pid" 2>/dev/null || fail "parent metadata-lock holder exited early"; sleep 0.05; done

  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm "parent-retirement-race steer" >"$dir/out" 2>"$dir/err" &
  sender_pid=$!
  sleep 0.2
  : > "$release"
  wait "$sender_pid" || rc=$?
  wait "$holder_pid" || fail "parent metadata-lock holder failed"
  [ "$rc" -ne 0 ] || fail "a remote send must not enqueue after parent retirement won the metadata lock"
  [ -z "$(remote_inbox_records "$rhome")" ] \
    || fail "a remote send enqueued after its parent route retired"
  [ -z "$(pending_record "$home")" ] \
    || fail "a parent-route retirement failure left a created pending expectation"
  pass "fm-send remote: enqueue revalidates the parent route under its metadata lock"
}

test_remote_expected_host_revalidates_final_route() {
  local dir fb ssh_log home rhome rc err count
  dir="$TMP_ROOT/remote-expected-host"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-expected-host)
  home=$(setup_remote_parent_home remote-expected-host "$rhome")

  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    FM_SEND_EXPECTED_SPAWN_GEN="" FM_SEND_EXPECTED_REMOTE_HOST=remote-mac \
    "$SEND" rsm --fire-and-forget 1111111111111111 "matching expected host" \
    >"$dir/match.out" 2>"$dir/match.err" || rc=$?
  expect_code 0 "$rc" "a matching expected remote host must allow delivery"
  count=$(remote_inbox_records "$rhome" | grep -c . || true)
  [ "$count" = 1 ] || fail "a matching expected remote host did not deliver exactly once"

  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    FM_SEND_EXPECTED_SPAWN_GEN="" FM_SEND_EXPECTED_REMOTE_HOST=retired-mac \
    "$SEND" rsm --fire-and-forget 2222222222222222 "stale expected host" \
    >"$dir/mismatch.out" 2>"$dir/mismatch.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a mismatched expected remote host reported delivery"
  err=$(cat "$dir/mismatch.err")
  assert_contains "$err" "retired or changed route" \
    "a mismatched expected remote host did not report the route replacement: $err"
  count=$(remote_inbox_records "$rhome" | grep -c . || true)
  [ "$count" = 1 ] || fail "a mismatched expected remote host reached the remote inbox"
  pass "fm-send remote: expected host is enforced by final route validation"
}

test_remote_resolve_key_closes_at_enqueue() {
  local dir fb ssh_log home rhome rc out
  dir="$TMP_ROOT/remote-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-key)
  home=$(setup_remote_parent_home remote-key "$rhome")
  printf 'needs-decision [key=upgrade-window]: tonight or the weekend\n' > "$home/state/rsm.status"

  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm --resolve-key upgrade-window "the weekend, freeze Friday" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a durably recorded remote answer must exit 0"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/rsm.status" | grep -qF 'resolved [key=upgrade-window]: answered: the weekend, freeze Friday' \
    || fail "a recorded remote answer must close the decision at enqueue: $(cat "$home/state/rsm.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision still lists as open after a recorded remote answer: $out"
  fi
  grep -rqF 'the weekend, freeze Friday' "$rhome/state/parent-route/rsm.inbox" \
    || fail "the remote answer must land in the remote steering inbox"
  pass "fm-send remote: a --resolve-key answer closes its decision at enqueue"
}

test_remote_slash_rides_inbox() {
  local dir fb ssh_log home rhome rc recs
  dir="$TMP_ROOT/remote-slash"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-slash)
  home=$(setup_remote_parent_home remote-slash "$rhome")

  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm "/audit the ledger" >/dev/null 2>"$dir/err" || rc=$?
  expect_code 0 "$rc" "a remote harness-native steer must ride the inbox and exit 0"
  recs=$(remote_inbox_records "$rhome")
  [ -n "$recs" ] || fail "a remote '/' steer must land in the remote steering inbox, not a typed plane"
  grep -rqF '/audit the ledger' "$rhome/state/parent-route/rsm.inbox" \
    || fail "the remote record must carry the harness-native text verbatim"
  pass "fm-send remote: every remote text, harness-native included, rides the inbox"
}

test_remote_real_failure_still_fails() {
  local dir fb ssh_log home rhome rc err
  dir="$TMP_ROOT/remote-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-fail)
  home=$(setup_remote_parent_home remote-fail "$rhome")

  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_RC=1 \
    FM_FAKE_SSH_STDERR='error: remote secondmate rsm endpoint metadata is invalid; refusing access until it is explicitly migrated' \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "a genuinely failed remote send must exit nonzero"
  assert_contains "$err" "steer not sent to remote secondmate rsm" \
    "a real remote failure must still report a real error"
  assert_contains "$err" "endpoint metadata is invalid" \
    "a real remote failure must surface the remote leg's own stderr"
  [ -z "$(pending_record "$home")" ] \
    || fail "a failed send must discard its undelivered expectation"
  [ -z "$(remote_inbox_records "$rhome")" ] \
    || fail "a refused remote leg must leave no inbox record"
  pass "fm-send remote: a real remote failure still fails loudly with the remote diagnostics"
}

test_remote_exit3_no_longer_delivered() {
  local dir fb ssh_log home rhome rc err
  dir="$TMP_ROOT/remote-exit3"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-exit3)
  home=$(setup_remote_parent_home remote-exit3 "$rhome")

  # The typed-plane remote transport remapped a leg exit 3 to "delivered with
  # confirmation pending". That transport is deleted: any nonzero remote leg
  # status is a failure, never a delivery claim.
  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_RC=3 \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "a nonzero remote leg must no longer be remapped to delivered"
  assert_not_contains "$err" "delivered to remote secondmate" \
    "the deleted exit-3-as-delivered remap must be gone"
  assert_contains "$err" "steer not sent to remote secondmate rsm" \
    "a failed remote leg must report the steer as not sent"
  [ -z "$(pending_record "$home")" ] \
    || fail "a failed remote leg must discard its undelivered expectation"
  pass "fm-send remote: exit 3 from the remote leg is a failure, never a delivery claim"
}

test_remote_transport_loss_preserves_expectation() {
  local dir fb ssh_log home rhome rc err pend
  dir="$TMP_ROOT/remote-255"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-255)
  home=$(setup_remote_parent_home remote-255 "$rhome")

  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_RC=255 \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  [ "$rc" -ne 0 ] || fail "an unknown-completion transport loss must exit nonzero"
  [ "$(cat "$ssh_log.count")" = 2 ] \
    || fail "fm-send must retry the identical remote leg once on ssh 255, got $(cat "$ssh_log.count") attempts"
  assert_contains "$err" "Only the correlation-reusing resend below is idempotent" \
    "transport loss must print the supported safe resend boundary"
  assert_not_contains "$err" "do not resend" \
    "the deleted do-not-resend trap must be gone for transport loss"
  pend=$(pending_record "$home")
  [ -n "$pend" ] || fail "transport loss must preserve the expectation for reconciliation"
  [ "$(grep '^phase=' "$pend" | tail -1 | cut -d= -f2-)" = delivery_unknown ] \
    || fail "transport loss must move the expectation to delivery_unknown: $(cat "$pend")"
  pass "fm-send remote: ssh 255 fails with resend-safe guidance and preserves the expectation"
}

test_remote_send_budget_bounds_busy_lane() {
  local dir fb ssh_log home rhome rc err began elapsed count pend delivery corr ssh_before
  dir="$TMP_ROOT/remote-budget"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-budget)
  home=$(setup_remote_parent_home remote-budget "$rhome")
  delivery=aaaabbbbccccdddd

  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_SEND_REMOTE_BUDGET=invalid \
    "$SEND" rsm --key Enter >"$dir/key-invalid.out" 2>"$dir/key-invalid.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "an invalid remote key budget must fail"
  assert_contains "$(cat "$dir/key-invalid.err")" "must be a positive integer" \
    "an invalid remote key budget must explain its validation failure"
  [ ! -f "$ssh_log.count" ] || fail "an invalid remote key budget reached the transport"

  began=$(date +%s)
  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_HANG=60 FM_SEND_REMOTE_BUDGET=2 \
    "$SEND" rsm --key Enter >"$dir/key.out" 2>"$dir/key.err" || rc=$?
  elapsed=$(( $(date +%s) - began ))
  expect_code 1 "$rc" "a bounded remote key must preserve the existing failure contract"
  [ "$elapsed" -le 15 ] || fail "the bounded remote key waited ${elapsed}s behind the busy lane"
  assert_contains "$(cat "$dir/key.err")" "completion may be unknown" \
    "a bounded remote key failure must preserve its existing diagnostic"
  [ "$(cat "$ssh_log.count")" = 1 ] \
    || fail "a bounded remote key must make exactly one transport attempt"
  printf '0\n' > "$ssh_log.count"

  # T5: a fire-and-forget send to a mate behind a busy lane returns its
  # unconfirmed result within its own budget instead of waiting the lane out.
  began=$(date +%s)
  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_HANG=60 FM_SEND_REMOTE_BUDGET=2 \
    "$SEND" rsm --fire-and-forget "$delivery" "reconcile your own books" \
    >"$dir/out" 2>"$dir/err" || rc=$?
  elapsed=$(( $(date +%s) - began ))
  err=$(cat "$dir/err")
  expect_code 3 "$rc" "a budget-bounded fire-and-forget send must report unconfirmed: $err"
  [ "$elapsed" -le 15 ] || fail "the bounded send waited ${elapsed}s behind the busy lane"
  assert_contains "$err" "delivery-id=$delivery" \
    "the bounded unconfirmed result must name the reusable delivery id"
  [ "$(cat "$ssh_log.count")" = 1 ] \
    || fail "a budget hit must not retry into the same busy lane, got $(cat "$ssh_log.count") attempts"

  # A retry with the same delivery id against the recovered lane dedups onto
  # the same remote record.
  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm --fire-and-forget "$delivery" "reconcile your own books" \
    >"$dir/retry.out" 2>"$dir/retry.err" \
    || fail "the same-delivery-id retry after the budget hit failed"
  count=$(remote_inbox_records "$rhome" | grep -c . || true)
  [ "$count" = 1 ] || fail "the same-delivery-id retry did not dedup onto one record, found $count"

  # A reply-bearing send names the budget and prints the correlation-reusing
  # resend command, with the expectation preserved as delivery-unknown.
  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_HANG=60 FM_SEND_REMOTE_BUDGET=2 \
    "$SEND" rsm "please rename the metric" >"$dir/reply.out" 2>"$dir/reply.err" || rc=$?
  err=$(cat "$dir/reply.err")
  [ "$rc" -ne 0 ] || fail "a budget-bounded reply-bearing send must not claim confirmed delivery"
  assert_contains "$err" "within its 2s budget" \
    "the budget-bounded failure must name the budget that bounded it"
  assert_contains "$err" "Only the correlation-reusing resend below is idempotent" \
    "the budget-bounded failure must print the supported safe resend boundary"
  pend=$(pending_record "$home")
  [ -n "$pend" ] || fail "a budget-bounded reply-bearing send must preserve its expectation"
  [ "$(grep '^phase=' "$pend" | tail -1 | cut -d= -f2-)" = delivery_unknown ] \
    || fail "the preserved expectation must record unknown delivery: $(cat "$pend")"

  # Invalid transport configuration fails before a correlation-reusing resend
  # mutates the preserved expectation or reaches the transport.
  corr=$(fm_pending_reply_get "$pend" corr_id)
  cp "$pend" "$dir/pending-before-invalid-budget"
  ssh_before=$(cat "$ssh_log.count")
  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_SEND_REMOTE_BUDGET=invalid \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SEND" rsm "please rename the metric" >"$dir/invalid.out" 2>"$dir/invalid.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "an invalid remote budget must fail the resend"
  assert_contains "$(cat "$dir/invalid.err")" "must be a positive integer" \
    "an invalid remote budget must explain its validation failure"
  [ "$(cat "$ssh_log.count")" = "$ssh_before" ] \
    || fail "an invalid remote budget reached the remote transport"
  cmp -s "$dir/pending-before-invalid-budget" "$pend" \
    || fail "an invalid remote budget mutated the reusable pending expectation: $(cat "$pend")"
  pass "fm-send remote: the remote leg is budget-bounded and stays idempotent across the bound"
}

test_local_secondmate_pending_keeps_expectation_armed() {
  local dir fb log home rc rec corr
  dir="$TMP_ROOT/local-pending-expectation"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home local-pending-expectation)
  fm_write_meta "$home/state/lsm.meta" \
    "window=sess:fm-lsm" "harness=claude" "kind=secondmate" "mode=secondmate" "home=$home/sm"

  # A harness-native slash invocation keeps the typed plane for a LOCAL marked
  # secondmate target, so this pins the kept armed-expectation semantics there.
  : > "$log"
  rc=0
  env PATH="$fb:$PATH" FM_FAKE_TMUX_PENDING=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lsm "/audit the ledger" >/dev/null 2>&1 || rc=$?
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

  # An explicit backend target is the typed plane, so the exit-3 ladder still
  # governs it.
  : > "$log"
  rc=0
  env PATH="$fb:$PATH" FM_FAKE_TMUX_PENDING=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "steer text" >"$dir/out" 2>"$dir/err" || rc=$?
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
  rc=0
  env PATH="$fb:$PATH" FM_FAKE_TMUX_PENDING=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t2 --resolve-key creds "/vault fetch deploy-token" >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "an unconfirmed local answer must exit with the delivered-unconfirmed status"
  if grep -F 'resolved' "$home/state/t2.status" >/dev/null; then
    fail "an unconfirmed local answer must not close the decision: $(cat "$home/state/t2.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=creds]' >/dev/null \
    || fail "the blocker must stay open after an unconfirmed local answer: $out"
  pass "fm-send local: an unconfirmed submit still never closes a --resolve-key decision"
}

# --- reply tracker against the remote inbox (live-evidence scenarios) --------
# Each test below reproduces one scenario observed on a real ssh + fm-on hop
# (PR kunchenguid/firstmate#7369): the tracker reads the mate's host-local
# inbox through the real inbox-status leg and acts on what it finds. Time is
# the FM_PENDING_REPLY_NOW seam; transport faults are the fake ssh's, as in
# the tests above.

# One tracker pass over <home>'s pending replies at epoch <now>.
tracker_pass() {  # <fakebin> <home> <ssh-log> <now> [extra env...]
  local fb=$1 home=$2 ssh_log=$3 now=$4
  shift 4
  # The script is expanded by the inner shell, not this one.
  # shellcheck disable=SC2016
  send_env "$fb" "$home" "$ssh_log" FM_PENDING_REPLY_NOW="$now" "$@" \
    bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$FM_HOME/state"' _ "$ROOT" \
    >/dev/null 2>&1
}

# The tracker's own inbox-status read of <corr> at epoch <now>.
tracker_inbox_status() {  # <fakebin> <home> <ssh-log> <now> <corr>
  local fb=$1 home=$2 ssh_log=$3 now=$4 corr=$5
  # The script is expanded by the inner shell, not this one.
  # shellcheck disable=SC2016
  send_env "$fb" "$home" "$ssh_log" FM_PENDING_REPLY_NOW="$now" \
    bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_inbox_status "$FM_HOME/state" rsm "$2"' \
    _ "$ROOT" "$corr"
}

# A request sent to the remote mate at epoch <now>; prints its correlation id.
send_remote_request() {  # <fakebin> <home> <ssh-log> <now> <text> [extra env...]
  local fb=$1 home=$2 ssh_log=$3 now=$4 text=$5 before rec
  shift 5
  # A home can already hold earlier records, and find's order is the
  # filesystem's: report the record this send created, not the first listed.
  before=$(find "$home/state/pending-replies" -maxdepth 1 -type f ! -name '.*' 2>/dev/null)
  send_env "$fb" "$home" "$ssh_log" FM_PENDING_REPLY_NOW="$now" "$@" \
    "$SEND" rsm "$text" >/dev/null 2>&1 || true
  rec=$(find "$home/state/pending-replies" -maxdepth 1 -type f ! -name '.*' 2>/dev/null \
    | grep -vxF -e "${before:-/nonexistent}" | head -1)
  fm_pending_reply_get "$rec" corr_id
}

# Scenario 1: a delivered request the parked mate never reads.
test_remote_unread_request_escalates_once() {
  local dir fb ssh_log home rhome corr rec status lines open
  dir="$TMP_ROOT/remote-unread"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-unread)
  home=$(setup_remote_parent_home remote-unread "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 10000 "please append one line")
  [ -n "$corr" ] || fail "the request did not leave a pending-reply record"
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  status="$home/state/rsm.status"

  # The mate idles without ever being seen busy and the record is still
  # unhandled in its inbox: that is not a completed turn, and 299 s is under
  # the unread bound.
  tracker_pass "$fb" "$home" "$ssh_log" 10299 FM_FAKE_SSH_OBSERVE=idle
  [ ! -s "$status" ] || fail "an unread request escalated before the unread bound: $(cat "$status")"
  [ -z "$(fm_pending_reply_get "$rec" request_turn_completed_epoch)" ] \
    || fail "an idle never-busy mate with an unhandled request must not count as a completed turn"
  [ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ] \
    || fail "the unread request must keep awaiting its report: $(cat "$rec")"

  tracker_pass "$fb" "$home" "$ssh_log" 10300 FM_FAKE_SSH_OBSERVE=idle
  lines=$(grep -c 'pending-reply-unread' "$status" || true)
  [ "$lines" = 1 ] || fail "expected exactly one pending-reply-unread escalation at the bound, got $lines: $(cat "$status")"
  grep -F "blocked [key=pending-reply-$corr]" "$status" | grep -qF 'landed 5m ago, unread (1 unhandled' \
    || fail "the escalation must name the age and the unhandled count under the record's key: $(cat "$status")"
  grep -F 'pending-reply-unread' "$status" | grep -qF 'remedy: fm-peek.sh rsm, then fm-send.sh rsm --key Enter' \
    || fail "the escalation must carry the fm-peek / --key Enter remedy: $(cat "$status")"
  [ "$(fm_pending_reply_get "$rec" unread_escalated_epoch)" = 10300 ] \
    || fail "the unread escalation epoch was not recorded: $(cat "$rec")"
  open=$(status_open_decisions "$status" | cut -f1)
  [ "$open" = "pending-reply-$corr" ] || fail "the unread escalation must open its keyed decision, got '$open'"

  tracker_pass "$fb" "$home" "$ssh_log" 10900 FM_FAKE_SSH_OBSERVE=idle
  lines=$(grep -c 'pending-reply-unread' "$status" || true)
  [ "$lines" = 1 ] || fail "a later pass must not escalate the same unread request twice, got $lines"
  [ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ] \
    || fail "an unread escalation must leave the record tracking its report: $(cat "$rec")"
  pass "fm-pending-reply remote: an unread request escalates exactly once with age, count and remedy"
}

# Scenario 1, busy at delivery: a request that lands while the mate is already
# working on other work stays unread through that whole turn, so the busy flag
# set by that turn must not make the next idle count as the request's turn.
test_remote_unread_request_delivered_to_a_busy_mate_still_escalates() {
  local dir fb ssh_log home rhome corr rec status lines
  dir="$TMP_ROOT/remote-unread-busy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-unread-busy)
  home=$(setup_remote_parent_home remote-unread-busy "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 10000 "please append one line")
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  status="$home/state/rsm.status"

  tracker_pass "$fb" "$home" "$ssh_log" 10010 FM_FAKE_SSH_OBSERVE=busy
  [ "$(fm_pending_reply_get "$rec" turn_seen_busy)" = 1 ] \
    || fail "the busy observation was not recorded: $(cat "$rec")"
  tracker_pass "$fb" "$home" "$ssh_log" 10400 FM_FAKE_SSH_OBSERVE=busy

  tracker_pass "$fb" "$home" "$ssh_log" 10500 FM_FAKE_SSH_OBSERVE=idle
  [ -z "$(fm_pending_reply_get "$rec" request_turn_completed_epoch)" ] \
    || fail "an idle after a busy turn must not complete a request still unhandled in the inbox: $(cat "$rec")"
  lines=$(grep -c 'pending-reply-unread' "$status" || true)
  [ "$lines" = 1 ] || fail "expected one pending-reply-unread escalation past the bound, got $lines: $(cat "$status" 2>/dev/null)"

  mv "$rhome/state/parent-route/rsm.inbox"/*.msg "$rhome/state/parent-route/rsm.inbox/handled/"
  tracker_pass "$fb" "$home" "$ssh_log" 10600 FM_FAKE_SSH_OBSERVE=idle
  [ -n "$(fm_pending_reply_get "$rec" request_turn_completed_epoch)" ] \
    || fail "once the request is handled an idle mate is a completed turn: $(cat "$rec")"
  pass "fm-pending-reply remote: a request delivered to a busy mate that stays unread still escalates"
}

# Scenario 1, other half: once the mate has handled the request the same idle
# observation is an ordinary completed turn.
test_remote_handled_request_idle_counts_as_a_completed_turn() {
  local dir fb ssh_log home rhome corr rec status
  dir="$TMP_ROOT/remote-unread-handled"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-unread-handled)
  home=$(setup_remote_parent_home remote-unread-handled "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 10000 "please append one line")
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  status="$home/state/rsm.status"

  mv "$rhome/state/parent-route/rsm.inbox"/*.msg "$rhome/state/parent-route/rsm.inbox/handled/"
  tracker_pass "$fb" "$home" "$ssh_log" 10400 FM_FAKE_SSH_OBSERVE=idle
  [ ! -s "$status" ] || fail "a handled request must never be reported unread: $(cat "$status")"
  [ -n "$(fm_pending_reply_get "$rec" request_turn_completed_epoch)" ] \
    || fail "once the request is handled an idle mate is a completed turn: $(cat "$rec")"
  pass "fm-pending-reply remote: a handled request's idle observation is a completed turn"
}

# An inbox that cannot be read changes nothing: the idle observation counts
# exactly as it did before the tracker consulted the inbox.
test_remote_unreadable_inbox_leaves_the_idle_counting_as_before() {
  local dir fb ssh_log home rhome corr rec status
  dir="$TMP_ROOT/remote-unread-unreadable"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-unread-unreadable)
  home=$(setup_remote_parent_home remote-unread-unreadable "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 10000 "please append one line")
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  status="$home/state/rsm.status"

  tracker_pass "$fb" "$home" "$ssh_log" 10400 FM_FAKE_SSH_OBSERVE=idle FM_FAKE_SSH_FAIL_SUBCMD=inbox-status
  [ ! -s "$status" ] || fail "an unreadable inbox must not escalate anything: $(cat "$status")"
  [ -z "$(fm_pending_reply_get "$rec" unread_escalated_epoch)" ] \
    || fail "an unreadable inbox must not record an unread escalation"
  [ -n "$(fm_pending_reply_get "$rec" request_turn_completed_epoch)" ] \
    || fail "with the inbox unreadable the idle must count as a completed turn, as before: $(cat "$rec")"
  pass "fm-pending-reply remote: an unreadable inbox changes nothing about how an idle counts"
}

# Scenario 2: the reply to the send was lost but the record landed.
test_remote_lost_reply_reconciles_as_landed() {
  local dir fb ssh_log home rhome corr rec status count
  dir="$TMP_ROOT/remote-reconcile-landed"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-reconcile-landed)
  home=$(setup_remote_parent_home remote-reconcile-landed "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 11000 "please append one line" FM_FAKE_SSH_AMBIGUOUS=1)
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  status="$home/state/rsm.status"
  [ "$(fm_pending_reply_get "$rec" phase)" = delivery_unknown ] \
    || fail "a send whose reply was lost twice must be delivery_unknown: $(cat "$rec")"
  [ -f "$(fm_pending_reply_undelivered_text_path "$home/state" "$corr")" ] \
    || fail "an unconfirmed remote send must keep its request text for the one resend"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 1 ] \
    || fail "both attempts must have landed on one remote record"

  tracker_pass "$fb" "$home" "$ssh_log" 11016
  [ "$(fm_pending_reply_get "$rec" delivered_epoch)" = 11016 ] \
    || fail "a record found in the remote inbox must be marked delivered: $(cat "$rec")"
  [ "$(fm_pending_reply_get "$rec" delivery_reconcile)" = landed ] \
    || fail "the reconciliation must be recorded as landed: $(cat "$rec")"
  [ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ] \
    || fail "a landed request must await its report: $(cat "$rec")"
  [ ! -e "$(fm_pending_reply_undelivered_text_path "$home/state" "$corr")" ] \
    || fail "a landed request must drop its stored text"
  count=$(remote_inbox_records "$rhome" | grep -c . || true)
  [ "$count" = 1 ] || fail "a landed request must never be resent, found $count remote records"
  if [ -s "$status" ]; then
    fail "no escalation was open, so reconciliation must write nothing: $(cat "$status")"
  fi
  pass "fm-pending-reply remote: a record that landed behind a lost reply is marked delivered without a resend"
}

# Scenario 2 with the delivery-unknown decision already open: landing closes it.
test_remote_landed_reconciliation_closes_the_delivery_unknown_decision() {
  local dir fb ssh_log home rhome corr rec status open
  dir="$TMP_ROOT/remote-reconcile-closes"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-reconcile-closes)
  home=$(setup_remote_parent_home remote-reconcile-closes "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 11000 "please append one line" FM_FAKE_SSH_AMBIGUOUS=1)
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  status="$home/state/rsm.status"

  # While the host is down the tracker cannot read the inbox, so the unknown
  # delivery is escalated as a durable keyed decision.
  tracker_pass "$fb" "$home" "$ssh_log" 11010 FM_FAKE_SSH_RC=255
  [ "$(fm_pending_reply_get "$rec" phase)" = escalated ] \
    || fail "an unknown delivery with an unreadable inbox must escalate: $(cat "$rec")"
  open=$(status_open_decisions "$status" | cut -f1)
  [ "$open" = "pending-reply-$corr" ] || fail "the delivery-unknown decision must be open, got '$open'"

  tracker_pass "$fb" "$home" "$ssh_log" 11070
  [ "$(fm_pending_reply_get "$rec" delivery_reconcile)" = landed ] \
    || fail "the reachable host must reconcile the record as landed: $(cat "$rec")"
  [ -z "$(status_open_decisions "$status")" ] \
    || fail "landing must close the delivery-unknown decision: $(status_open_decisions "$status")"
  grep -F "resolved [key=pending-reply-$corr]" "$status" | grep -qF 'via=delivery-reconciled landed' \
    || fail "the close must say it was a delivery reconciliation: $(cat "$status")"
  [ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ] \
    || fail "a landed request must go back to awaiting its report: $(cat "$rec")"
  pass "fm-pending-reply remote: landing closes an open delivery-unknown decision with via=delivery-reconciled"
}

# Scenario 3 and finding 2: nothing landed because the host was down.
test_remote_unlanded_record_is_resent_once_and_recheck_is_not_delayed_by_a_failed_read() {
  local dir fb ssh_log home rhome corr rec status count resend_epoch
  dir="$TMP_ROOT/remote-resend"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-resend)
  home=$(setup_remote_parent_home remote-resend "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 12000 "please append one line" FM_FAKE_SSH_RC=255)
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  status="$home/state/rsm.status"
  [ "$(fm_pending_reply_get "$rec" phase)" = delivery_unknown ] \
    || fail "a send refused twice must be delivery_unknown: $(cat "$rec")"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 0 ] \
    || fail "nothing may have landed while the host was down"

  # First check, host still down: the read fails, the decision is escalated,
  # and the failed read must not start the recheck spacing.
  tracker_pass "$fb" "$home" "$ssh_log" 12040 FM_FAKE_SSH_RC=255
  [ "$(fm_pending_reply_get "$rec" phase)" = escalated ] \
    || fail "an unreadable inbox must leave the delivery-unknown escalation: $(cat "$rec")"
  [ -z "$(fm_pending_reply_get "$rec" delivery_checked_epoch)" ] \
    || fail "a failed inbox read must not count as a check: $(cat "$rec")"
  [ "$(fm_pending_reply_get "$rec" delivery_read_failed_epoch)" = 12040 ] \
    || fail "a failed inbox read must be recorded for the short backoff: $(cat "$rec")"
  [ "$(grep -c 'pending-reply-delivery-unknown' "$status" || true)" = 1 ] \
    || fail "expected one delivery-unknown escalation: $(cat "$status")"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 0 ] \
    || fail "an unreadable inbox must not trigger a resend"

  # The host is back and the short read-retry spacing (60 s) has passed - far
  # inside the 600 s recheck spacing: the next pass reads the inbox, finds the
  # record absent, and resends it once under the same correlation.
  tracker_pass "$fb" "$home" "$ssh_log" 12100
  count=$(remote_inbox_records "$rhome" | grep -c . || true)
  [ "$count" = 1 ] || fail "the reachable host must receive exactly one resend, found $count records"
  grep -qF "corr=$corr" "$(remote_inbox_records "$rhome" | head -1)" \
    || fail "the resend must reuse the original correlation"
  [ "$(fm_pending_reply_get "$rec" delivery_reconcile)" = resent ] \
    || fail "the reconciliation must be recorded as resent: $(cat "$rec")"
  resend_epoch=$(fm_pending_reply_get "$rec" delivery_resend_epoch)
  [ "$resend_epoch" = 12100 ] || fail "the resend epoch was not recorded: $(cat "$rec")"
  [ -n "$(fm_pending_reply_get "$rec" delivered_epoch)" ] \
    || fail "a resend that lands must confirm delivery: $(cat "$rec")"
  [ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ] \
    || fail "a resent request must await its report: $(cat "$rec")"
  [ -z "$(status_open_decisions "$status")" ] \
    || fail "the resend must close the delivery-unknown decision: $(status_open_decisions "$status")"
  grep -F "resolved [key=pending-reply-$corr]" "$status" | grep -qF 'via=delivery-reconciled resent' \
    || fail "the close must say the record was resent: $(cat "$status")"

  # No second resend on any later pass.
  tracker_pass "$fb" "$home" "$ssh_log" 12700
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 1 ] \
    || fail "a later pass must not resend again"
  [ "$(fm_pending_reply_get "$rec" delivery_resend_epoch)" = "$resend_epoch" ] \
    || fail "a later pass must not touch the resend epoch: $(cat "$rec")"
  pass "fm-pending-reply remote: an unlanded record is resent once, the first failed read does not delay it, and no second resend follows"
}

# Scenario 3, byte-exact: the remote inbox dedups on the whole body, so the
# resend carries the stored request with its trailing newline intact.
test_remote_resend_keeps_the_request_body_byte_exact() {
  local dir fb ssh_log home rhome corr text body
  dir="$TMP_ROOT/remote-resend-exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-resend-exact)
  home=$(setup_remote_parent_home remote-resend-exact "$rhome")
  text=$'please append one line\n'
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 12000 "$text" FM_FAKE_SSH_RC=255)
  [ "$(cat "$(fm_pending_reply_undelivered_text_path "$home/state" "$corr")"; printf x)" = "${text}x" ] \
    || fail "the unconfirmed send must store its request byte-exact"
  tracker_pass "$fb" "$home" "$ssh_log" 12040 FM_FAKE_SSH_RC=255
  tracker_pass "$fb" "$home" "$ssh_log" 12100
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 1 ] \
    || fail "the reachable host must receive exactly one resend"
  body=$(fm_task_inbox_body "$(remote_inbox_records "$rhome" | head -1)"; printf x)
  case "$body" in
    *"corr=$corr"*"$text"x) ;;
    *) fail "the resent body must end with the request's trailing newline: $(printf '%q' "$body")" ;;
  esac
  case "$body" in *$'\n\n'x) fail "the resend must not add a newline: $(printf '%q' "$body")" ;; esac
  pass "fm-pending-reply remote: the one resend keeps the stored request's trailing newline"
}

# Scenario 2 and 3, a close that cannot be written: the delivery-unknown
# decision is closed on a later pass instead of staying open for the task.
test_remote_failed_reconciliation_close_is_retried() {
  local dir fb ssh_log home rhome corr rec status
  dir="$TMP_ROOT/remote-close-retry"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"

  # Landed: the record stays undelivered until the close lands.
  rhome=$(setup_remote_secondmate_home remote-close-retry-landed)
  home=$(setup_remote_parent_home remote-close-retry-landed "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 11000 "please append one line" FM_FAKE_SSH_AMBIGUOUS=1)
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  status="$home/state/rsm.status"
  tracker_pass "$fb" "$home" "$ssh_log" 11010 FM_FAKE_SSH_RC=255
  [ "$(status_open_decisions "$status" | cut -f1)" = "pending-reply-$corr" ] \
    || fail "the delivery-unknown decision must be open: $(cat "$status")"
  chmod a-w "$status"
  tracker_pass "$fb" "$home" "$ssh_log" 11070
  chmod u+w "$status"
  [ -z "$(fm_pending_reply_get "$rec" delivered_epoch)" ] \
    || fail "a landed record whose close failed must stay undelivered: $(cat "$rec")"
  [ -n "$(status_open_decisions "$status")" ] || fail "the failed close must not have written"
  tracker_pass "$fb" "$home" "$ssh_log" 11670
  [ "$(fm_pending_reply_get "$rec" delivery_reconcile)" = landed ] \
    || fail "the next check must reconcile the record as landed: $(cat "$rec")"
  [ -z "$(status_open_decisions "$status")" ] \
    || fail "the retried check must close the decision: $(status_open_decisions "$status")"
  [ -n "$(fm_pending_reply_get "$rec" escalation_closed_epoch)" ] \
    || fail "the close must be recorded: $(cat "$rec")"

  # Resent: delivery is confirmed by fm-send, and a later pass retries the close.
  rhome=$(setup_remote_secondmate_home remote-close-retry-resent)
  home=$(setup_remote_parent_home remote-close-retry-resent "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 12000 "please append one line" FM_FAKE_SSH_RC=255)
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  status="$home/state/rsm.status"
  tracker_pass "$fb" "$home" "$ssh_log" 12040 FM_FAKE_SSH_RC=255
  chmod a-w "$status"
  tracker_pass "$fb" "$home" "$ssh_log" 12100
  chmod u+w "$status"
  [ "$(fm_pending_reply_get "$rec" delivery_reconcile)" = resent ] \
    && [ -n "$(fm_pending_reply_get "$rec" delivered_epoch)" ] \
    || fail "the resend must have landed and confirmed delivery: $(cat "$rec")"
  [ -n "$(status_open_decisions "$status")" ] && [ -z "$(fm_pending_reply_get "$rec" escalation_closed_epoch)" ] \
    || fail "the failed close must leave the decision open and unrecorded: $(cat "$rec")"
  tracker_pass "$fb" "$home" "$ssh_log" 12160
  [ -z "$(status_open_decisions "$status")" ] \
    || fail "a later pass must close the decision: $(status_open_decisions "$status")"
  grep -F "resolved [key=pending-reply-$corr]" "$status" | grep -qF 'via=delivery-reconciled resent' \
    || fail "the retried close must say the record was resent: $(cat "$status")"
  [ -n "$(fm_pending_reply_get "$rec" escalation_closed_epoch)" ] \
    || fail "the retried close must be recorded: $(cat "$rec")"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 1 ] || fail "the retry must not resend"
  pass "fm-pending-reply remote: a delivery-reconciled close that could not be written is retried on a later pass"
}

# Scenario 3 bounds: the recheck spacing, the stored text, and the age limit.
test_remote_undelivered_check_honours_spacing_text_and_age_limits() {
  local dir fb ssh_log home rhome corr rec before
  dir="$TMP_ROOT/remote-resend-bounds"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-resend-bounds)
  home=$(setup_remote_parent_home remote-resend-bounds "$rhome")

  # Spacing: a successful check ends the checking when it finds the record, so
  # the spacing is visible on a record whose last check is recent.
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 13000 "spaced request" FM_FAKE_SSH_RC=255)
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  fm_pending_reply_set "$rec" delivery_checked_epoch 13100
  before=$(cat "$ssh_log.count")
  tracker_pass "$fb" "$home" "$ssh_log" 13699
  [ "$(cat "$ssh_log.count")" = "$before" ] \
    || fail "a check inside the 600 s spacing must not touch the host"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 0 ] \
    || fail "a check inside the spacing must not resend"
  tracker_pass "$fb" "$home" "$ssh_log" 13700
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 1 ] \
    || fail "a check at the end of the spacing must resend the unlanded record"

  # Without the stored text the record is left to the printed resend command.
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 14000 "textless request" FM_FAKE_SSH_RC=255)
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  rm -f "$(fm_pending_reply_undelivered_text_path "$home/state" "$corr")"
  tracker_pass "$fb" "$home" "$ssh_log" 14001
  [ -z "$(fm_pending_reply_get "$rec" delivery_reconcile)" ] \
    || fail "a record without stored text must not be reconciled: $(cat "$rec")"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 1 ] \
    || fail "a record without stored text must not be resent"

  # A stale instruction must not land unannounced.
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 15000 "stale request" FM_FAKE_SSH_RC=255)
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  tracker_pass "$fb" "$home" "$ssh_log" 22201
  [ "$(fm_pending_reply_get "$rec" delivery_reconcile)" = absent ] \
    || fail "a request older than the resend limit must end as absent: $(cat "$rec")"
  [ ! -e "$(fm_pending_reply_undelivered_text_path "$home/state" "$corr")" ] \
    || fail "an abandoned resend must drop its stored text"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 1 ] \
    || fail "a request older than the resend limit must not be resent"
  pass "fm-pending-reply remote: the undelivered check honours its spacing, needs stored text, and stops at the age limit"
}

# Scenario 3, "once": a resend that itself fails is not repeated on the next
# check, even though the host is reachable again by then.
test_remote_failed_resend_is_never_repeated() {
  local dir fb ssh_log home rhome corr rec
  dir="$TMP_ROOT/remote-resend-once"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-resend-once)
  home=$(setup_remote_parent_home remote-resend-once "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 17000 "please append one line" FM_FAKE_SSH_RC=255)
  rec=$(fm_pending_reply_path "$home/state" "$corr")

  # The inbox can be read but the send leg is lost: the one resend is spent.
  tracker_pass "$fb" "$home" "$ssh_log" 17001 FM_FAKE_SSH_FAIL_SUBCMD=send-stdin
  [ "$(fm_pending_reply_get "$rec" delivery_resend_epoch)" = 17001 ] \
    || fail "the failed resend must still count as the one resend: $(cat "$rec")"
  [ -z "$(fm_pending_reply_get "$rec" delivered_epoch)" ] \
    || fail "a resend that was lost must not claim delivery: $(cat "$rec")"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 0 ] \
    || fail "the lost resend must not have landed"

  # Reachable again and past the spacing: the record is still absent, but no
  # second resend is made; checking just stops.
  tracker_pass "$fb" "$home" "$ssh_log" 17700
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 0 ] \
    || fail "a record whose one resend failed must not be resent again"
  [ "$(fm_pending_reply_get "$rec" delivery_reconcile)" = absent ] \
    || fail "the second check must end the checking as absent: $(cat "$rec")"
  pass "fm-pending-reply remote: a resend that failed is never repeated"
}

# Scenario 3, definite failure: a resend the remote leg refuses outright keeps
# the record tracked and escalates it as delivery-unknown.
test_remote_definitely_failed_resend_stays_tracked_and_escalates() {
  local dir fb ssh_log home rhome corr rec status open
  dir="$TMP_ROOT/remote-resend-refused"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-resend-refused)
  home=$(setup_remote_parent_home remote-resend-refused "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 18000 "please append one line" FM_FAKE_SSH_RC=255)
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  status="$home/state/rsm.status"
  [ "$(fm_pending_reply_get "$rec" phase)" = delivery_unknown ] \
    || fail "a send refused twice must be delivery_unknown: $(cat "$rec")"

  # The first check reads the inbox, finds nothing, and the one resend is
  # refused by the remote leg with a definite error.
  tracker_pass "$fb" "$home" "$ssh_log" 18001 FM_FAKE_SSH_FAIL_SUBCMD=send-stdin FM_FAKE_SSH_FAIL_SUBCMD_RC=1
  [ "$(fm_pending_reply_get "$rec" delivery_resend_epoch)" = 18001 ] \
    || fail "the refused resend must still count as the one resend: $(cat "$rec")"
  [ -z "$(fm_pending_reply_get "$rec" delivered_epoch)" ] \
    || fail "a refused resend must not claim delivery: $(cat "$rec")"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 0 ] \
    || fail "the refused resend must not have landed"
  [ "$(fm_pending_reply_get "$rec" phase)" = escalated ] \
    || fail "a refused resend must leave the record escalated, not orphaned: $(cat "$rec")"
  [ "$(grep -c 'pending-reply-delivery-unknown' "$status" || true)" = 1 ] \
    || fail "a refused resend must escalate as delivery-unknown: $(cat "$status" 2>/dev/null)"
  open=$(status_open_decisions "$status" | cut -f1)
  [ "$open" = "pending-reply-$corr" ] || fail "the delivery-unknown decision must be open, got '$open'"

  # The next check still finds it absent and ends the checking without a
  # second resend; the decision stays open for firstmate.
  tracker_pass "$fb" "$home" "$ssh_log" 18700
  [ "$(fm_pending_reply_get "$rec" delivery_reconcile)" = absent ] \
    || fail "the next check must end the checking as absent: $(cat "$rec")"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 0 ] \
    || fail "a record whose one resend was refused must not be resent again"
  [ ! -e "$(fm_pending_reply_undelivered_text_path "$home/state" "$corr")" ] \
    || fail "ending the checking must drop the stored text"
  open=$(status_open_decisions "$status" | cut -f1)
  [ "$open" = "pending-reply-$corr" ] || fail "the delivery-unknown decision must stay open, got '$open'"
  pass "fm-pending-reply remote: a resend refused outright stays tracked and escalates as delivery-unknown"
}

# A --resolve-key answer whose transport was lost twice is left to its printed
# resend command, the only send that closes the answered key: the tracker
# neither resends it nor closes its delivery-unknown decision.
test_remote_unconfirmed_resolve_key_answer_is_left_to_the_printed_resend() {
  local dir fb ssh_log home rhome corr rec status open
  dir="$TMP_ROOT/remote-resend-keyed"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-resend-keyed)
  home=$(setup_remote_parent_home remote-resend-keyed "$rhome")
  status="$home/state/rsm.status"
  printf 'needs-decision [key=upgrade-window]: tonight or the weekend\n' > "$status"
  send_env "$fb" "$home" "$ssh_log" FM_PENDING_REPLY_NOW=19000 FM_FAKE_SSH_RC=255 \
    "$SEND" rsm --resolve-key upgrade-window "the weekend, freeze Friday" >/dev/null 2>&1 || true
  corr=$(fm_pending_reply_get "$(pending_record "$home")" corr_id)
  [ -n "$corr" ] || fail "the keyed answer did not leave a pending-reply record"
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  [ "$(fm_pending_reply_get "$rec" phase)" = delivery_unknown ] \
    || fail "a keyed answer refused twice must be delivery_unknown: $(cat "$rec")"

  tracker_pass "$fb" "$home" "$ssh_log" 19010 FM_FAKE_SSH_RC=255
  [ "$(fm_pending_reply_get "$rec" phase)" = escalated ] \
    || fail "the unknown keyed answer must escalate: $(cat "$rec")"

  # Reachable again and past every spacing: still no reconciliation.
  tracker_pass "$fb" "$home" "$ssh_log" 19700
  tracker_pass "$fb" "$home" "$ssh_log" 20400
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 0 ] \
    || fail "the tracker must not resend a keyed answer"
  [ -z "$(fm_pending_reply_get "$rec" delivery_reconcile)" ] \
    || fail "the tracker must not reconcile a keyed answer: $(cat "$rec")"
  [ -z "$(fm_pending_reply_get "$rec" delivered_epoch)" ] \
    || fail "a keyed answer that never landed must not claim delivery: $(cat "$rec")"
  [ "$(fm_pending_reply_get "$rec" phase)" = escalated ] \
    || fail "the keyed answer's record must stay escalated: $(cat "$rec")"
  open=$(status_open_decisions "$status" | cut -f1 | sort | tr '\n' ' ')
  [ "$open" = "pending-reply-$corr upgrade-window " ] \
    || fail "the answered key and the delivery-unknown decision must both stay open, got '$open'"
  pass "fm-pending-reply remote: an unconfirmed --resolve-key answer is left to its printed resend"
}

# Review finding on the finding-2 fix: a failed read must be retried soon, but
# not on every watcher pass.
test_remote_failed_inbox_read_retries_after_the_short_backoff_only() {
  local dir fb ssh_log home rhome corr rec before
  dir="$TMP_ROOT/remote-read-backoff"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-read-backoff)
  home=$(setup_remote_parent_home remote-read-backoff "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 18000 "please append one line" FM_FAKE_SSH_RC=255)
  rec=$(fm_pending_reply_path "$home/state" "$corr")

  tracker_pass "$fb" "$home" "$ssh_log" 18010 FM_FAKE_SSH_RC=255
  [ "$(fm_pending_reply_get "$rec" delivery_read_failed_epoch)" = 18010 ] \
    || fail "a failed read must record when it failed: $(cat "$rec")"

  # The host is back, but the watcher passes inside the backoff do not read.
  before=$(cat "$ssh_log.count")
  tracker_pass "$fb" "$home" "$ssh_log" 18025
  tracker_pass "$fb" "$home" "$ssh_log" 18069
  [ "$(cat "$ssh_log.count")" = "$before" ] \
    || fail "a pass inside the read-retry backoff must not touch the host"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 0 ] \
    || fail "a pass inside the backoff must not resend"

  # At the end of the backoff the read happens, the record is found absent, and
  # the answered read clears the failure.
  tracker_pass "$fb" "$home" "$ssh_log" 18070
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 1 ] \
    || fail "the first pass after the backoff must read the inbox and resend"
  [ -z "$(fm_pending_reply_get "$rec" delivery_read_failed_epoch)" ] \
    || fail "an answered read must clear the recorded failure: $(cat "$rec")"
  [ "$(fm_pending_reply_get "$rec" delivery_checked_epoch)" = 18070 ] \
    || fail "an answered read is a check: $(cat "$rec")"
  pass "fm-pending-reply remote: a failed inbox read is retried after the short backoff and not before"
}

# A remote copy without the inbox-status leg answers every read with a usage
# error: it is probed at the short spacing, not on every pass.
test_remote_copy_without_the_inbox_status_leg_is_probed_at_the_short_spacing() {
  local dir fb ssh_log home rhome corr rec before pass_epoch
  dir="$TMP_ROOT/remote-no-leg"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-no-leg)
  home=$(setup_remote_parent_home remote-no-leg "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 19000 "please append one line" FM_FAKE_SSH_RC=255)
  rec=$(fm_pending_reply_path "$home/state" "$corr")

  before=$(cat "$ssh_log.count")
  for pass_epoch in 19010 19025 19040 19055; do
    tracker_pass "$fb" "$home" "$ssh_log" "$pass_epoch" FM_FAKE_SSH_USAGE_SUBCMD=inbox-status
  done
  [ "$(( $(cat "$ssh_log.count") - before ))" = 1 ] \
    || fail "four watcher passes inside 60 s must make one probe, made $(( $(cat "$ssh_log.count") - before ))"
  tracker_pass "$fb" "$home" "$ssh_log" 19070 FM_FAKE_SSH_USAGE_SUBCMD=inbox-status
  [ "$(( $(cat "$ssh_log.count") - before ))" = 2 ] \
    || fail "the pass after the spacing must probe again"
  [ -z "$(fm_pending_reply_get "$rec" delivered_epoch)" ] \
    || fail "a usage error must never claim delivery: $(cat "$rec")"
  [ -z "$(fm_pending_reply_get "$rec" delivery_checked_epoch)" ] \
    || fail "a usage error is not an answered read: $(cat "$rec")"
  [ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 0 ] \
    || fail "a usage error must not trigger a resend"
  pass "fm-pending-reply remote: a remote copy without the inbox-status leg is probed at the short spacing"
}

# A host that accepts the connection and then says nothing cannot hold the
# watcher past the read budget.
test_remote_silent_host_cannot_hold_the_tracker_past_the_read_budget() {
  local dir fb ssh_log home rhome corr rec start elapsed
  dir="$TMP_ROOT/remote-read-budget"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-read-budget)
  home=$(setup_remote_parent_home remote-read-budget "$rhome")
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 20000 "please append one line" FM_FAKE_SSH_RC=255)
  rec=$(fm_pending_reply_path "$home/state" "$corr")

  start=$SECONDS
  tracker_pass "$fb" "$home" "$ssh_log" 20010 FM_FAKE_SSH_HANG=25 FM_PENDING_REPLY_INBOX_READ_BUDGET=1
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt 15 ] || fail "a silent host held the tracker for ${elapsed}s despite a 1 s read budget"
  [ "$(fm_pending_reply_get "$rec" delivery_read_failed_epoch)" = 20010 ] \
    || fail "a read that hit its budget is a failed read: $(cat "$rec")"
  pass "fm-pending-reply remote: a silent host is cut off at the inbox read budget"
}

# Scenario 4: the resend is a real record in the mate's inbox; once the mate
# acknowledges it and reports, the parent's record resolves.
test_remote_resend_lands_and_acknowledgement_resolves_the_record() {
  local dir fb ssh_log home rhome corr rec status inbox status_out
  dir="$TMP_ROOT/remote-resend-ack"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-resend-ack)
  home=$(setup_remote_parent_home remote-resend-ack "$rhome")
  inbox="$rhome/state/parent-route/rsm.inbox"
  corr=$(send_remote_request "$fb" "$home" "$ssh_log" 16000 "please append one line" FM_FAKE_SSH_RC=255)
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  status="$home/state/rsm.status"
  tracker_pass "$fb" "$home" "$ssh_log" 16001

  [ -f "$inbox/001.msg" ] || fail "the resend must land as the first record in the remote inbox"
  grep -qF "corr=$corr please append one line" "$inbox/001.msg" \
    || fail "the resent record must carry the original marker, correlation and text: $(cat "$inbox/001.msg")"
  status_out=$(tracker_inbox_status "$fb" "$home" "$ssh_log" 16002 "$corr")
  assert_contains "$status_out" "unhandled=1" "the inbox status must count the landed resend"
  assert_contains "$status_out" "corr_state=unhandled" "the inbox status must report the resend unhandled"

  # The mate acknowledges it: handled/ and a correlated report on its channel.
  mv "$inbox/001.msg" "$inbox/handled/001.msg"
  status_out=$(tracker_inbox_status "$fb" "$home" "$ssh_log" 16003 "$corr")
  assert_contains "$status_out" "unhandled=0" "an acknowledged record must leave the unhandled count"
  assert_contains "$status_out" "corr_state=handled" "an acknowledged record must report handled"
  printf 'done corr=%s at=16004: read and appended\n' "$corr" >> "$status"
  tracker_pass "$fb" "$home" "$ssh_log" 16005
  [ "$(fm_pending_reply_get "$rec" phase)" = resolved ] \
    || fail "the correlated acknowledgement must resolve the parent record: $(cat "$rec")"
  [ "$(fm_pending_reply_get "$rec" resolved_via)" = status ] \
    || fail "the record must resolve through the status line: $(cat "$rec")"
  pass "fm-pending-reply remote: the resend lands in the remote inbox and the acknowledgement resolves the record"
}

# The inbox-status leg itself: its schema, the three correlation states, and a
# malformed correlation refused before anything is read.
test_remote_inbox_status_leg_reports_states_and_rejects_bad_corr() {
  local dir fb ssh_log home rhome out rc
  dir="$TMP_ROOT/remote-inbox-status"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home remote-inbox-status)
  home=$(setup_remote_parent_home remote-inbox-status "$rhome")
  leg() {  # [corr]
    send_env "$fb" "$home" "$ssh_log" "$ROOT/bin/fm-on.sh" rsm \
      fm-remote-secondmate-control.sh inbox-status rsm "$@" </dev/null
  }

  out=$(leg aaaaaaaaaaaaaaaa)
  [ "$(printf '%s\n' "$out" | head -1)" = "schema=fm-inbox-status.v1" ] \
    || fail "the leg must lead with its schema line: $out"
  assert_contains "$out" "unhandled=0" "an empty inbox has no unhandled records"
  assert_contains "$out" "corr_state=absent" "a correlation never sent is absent"

  fm_task_inbox_write "$rhome/state/parent-route" rsm "[fm] corr=bbbbbbbbbbbbbbbb first" >/dev/null
  fm_task_inbox_write "$rhome/state/parent-route" rsm "[fm] corr=cccccccccccccccc second" >/dev/null
  mv "$rhome/state/parent-route/rsm.inbox/002.msg" "$rhome/state/parent-route/rsm.inbox/handled/"
  out=$(leg bbbbbbbbbbbbbbbb)
  assert_contains "$out" "unhandled=1" "one record is still unhandled"
  assert_contains "$out" "corr_state=unhandled" "a waiting record reports unhandled"
  out=$(leg cccccccccccccccc)
  assert_contains "$out" "corr_state=handled" "an acknowledged record reports handled"

  rc=0
  out=$(leg 'not-a-corr' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed correlation must be refused"
  assert_contains "$out" "invalid correlation id" "the refusal must name the correlation"
  pass "fm-remote-secondmate-control inbox-status: schema, unhandled count, three correlation states, bad correlation refused"
}

test_remote_large_steer_uses_stdin
test_remote_steer_lands_in_remote_inbox
test_remote_rerun_is_idempotent
test_remote_retry_failure_preserves_ambiguous_expectation
test_remote_fire_and_forget_never_arms_reply_recovery
test_remote_send_revalidates_after_retirement_lock
test_remote_send_revalidates_parent_route_after_retirement_lock
test_remote_expected_host_revalidates_final_route
test_remote_resolve_key_closes_at_enqueue
test_remote_slash_rides_inbox
test_remote_real_failure_still_fails
test_remote_exit3_no_longer_delivered
test_remote_transport_loss_preserves_expectation
test_remote_send_budget_bounds_busy_lane
test_local_pending_reports_delivered_unconfirmed
test_local_pending_does_not_close_resolve_key
test_local_secondmate_pending_keeps_expectation_armed
test_remote_unread_request_escalates_once
test_remote_unread_request_delivered_to_a_busy_mate_still_escalates
test_remote_handled_request_idle_counts_as_a_completed_turn
test_remote_unreadable_inbox_leaves_the_idle_counting_as_before
test_remote_lost_reply_reconciles_as_landed
test_remote_landed_reconciliation_closes_the_delivery_unknown_decision
test_remote_unlanded_record_is_resent_once_and_recheck_is_not_delayed_by_a_failed_read
test_remote_resend_keeps_the_request_body_byte_exact
test_remote_failed_reconciliation_close_is_retried
test_remote_undelivered_check_honours_spacing_text_and_age_limits
test_remote_failed_resend_is_never_repeated
test_remote_definitely_failed_resend_stays_tracked_and_escalates
test_remote_unconfirmed_resolve_key_answer_is_left_to_the_printed_resend
test_remote_failed_inbox_read_retries_after_the_short_backoff_only
test_remote_copy_without_the_inbox_status_leg_is_probed_at_the_short_spacing
test_remote_silent_host_cannot_hold_the_tracker_past_the_read_budget
test_remote_resend_lands_and_acknowledgement_resolves_the_record
test_remote_inbox_status_leg_reports_states_and_rejects_bad_corr

echo "all fm-send-remote-delivery tests passed"
