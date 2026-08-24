#!/usr/bin/env bash
# fm-send remote-secondmate delivery: the remote inbox leg.
#
# A remote steer is delivered by durable record, never by typing its payload:
# fm-send crosses fm-on.sh to the host-local leg (fm-remote-secondmate-control.sh
# cmd_send), which writes the message idempotently into the remote home's
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
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"

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
set -u
cat > /dev/null
count=$(cat "$FM_SSH_COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$FM_SSH_COUNT"
printf '%s\n' "$*" >> "$FM_SSH_LOG"
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
remote_home=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$home_b64")
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done \
  < <(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$argv_b64")
cmd=${rargs[0]}
rc=0
env FM_HOME="$remote_home" FM_ROOT_OVERRIDE="$FM_REMOTE_CODE_ROOT" \
  "$FM_REMOTE_CODE_ROOT/bin/$cmd" "${rargs[@]:1}" || rc=$?
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

  fm_pending_reply_set "$pend" phase escalated \
    || fail "could not advance the ambiguous expectation to the escalated fixture phase"
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
  fm_pending_reply_set "$pend" phase delivery_unknown \
    || fail "could not restore the ambiguous expectation for the supported resend"

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
  grep -F 'resolved [key=upgrade-window]: answered: the weekend, freeze Friday' "$home/state/rsm.status" >/dev/null \
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

test_remote_steer_lands_in_remote_inbox
test_remote_rerun_is_idempotent
test_remote_retry_failure_preserves_ambiguous_expectation
test_remote_send_revalidates_after_retirement_lock
test_remote_send_revalidates_parent_route_after_retirement_lock
test_remote_resolve_key_closes_at_enqueue
test_remote_slash_rides_inbox
test_remote_real_failure_still_fails
test_remote_exit3_no_longer_delivered
test_remote_transport_loss_preserves_expectation
test_local_pending_reports_delivered_unconfirmed
test_local_pending_does_not_close_resolve_key
test_local_secondmate_pending_keeps_expectation_armed

echo "all fm-send-remote-delivery tests passed"
