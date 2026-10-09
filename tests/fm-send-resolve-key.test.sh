#!/usr/bin/env bash
# fm-send answerer-closes (--resolve-key) behavior.
#
# A captain decision opened by a keyed needs-decision:/blocked: status line
# historically stayed open forever when the answer kicked off work: the worker's
# next line is working [key=<workstream>], never resolved [key=<decision>].
# fm-send's --resolve-key removes that writer-dependency at its source: the
# ANSWERING firstmate closes the decision in this home's own ledger at answer
# time - for a local target that is ENQUEUE time, because the durable inbox
# write is delivery to the task's record. These tests drive the real fm-send
# executable over stubbed transports and assert closure through the real
# consumer (fm-wake-drain.sh's OPEN DECISIONS section), never through source
# text:
#   1. An answer send closes the open decision, including the answer-starts-work
#      scenario where the worker never writes a matching resolved line.
#   2. A routine steer without the flag never closes anything, and a working:
#      line still cannot clear a captain decision.
#   3. A key that is not open refuses BEFORE anything is sent (mistype safety).
#   4. The close happens at enqueue: a failed doorbell ring still closes the
#      answered key (the record is durably sent), while a failed ENQUEUE - the
#      real local failure - closes nothing and leaves the decision open.
#   5. A local secondmate answer is marked+corr'd in its record yet closes the
#      same way, and the closing line carries the plain answer, not marker or
#      corr bytes.
#   6. A remote secondmate answer differs only at the transport layer: the
#      message crosses the stubbed ssh transport while the close is the same
#      local ledger append; a failed transport closes nothing.
#   7. Flag misuse (--key, empty message, explicit backend target) refuses.
#   8. A reserved pending-reply-* decision actually closes through --resolve-key
#      (the operator path the OPEN DECISIONS hint names), while an unrelated
#      writer's answered: note still cannot hijack or clear that key. A reserved
#      key this send cannot close refuses before anything is sent.
#   9. A mapped explicit endpoint may use its local decision ledger, answer
#      records cannot cross home boundaries, and declaration logging precedes
#      delivery so a failed append prevents the steer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
CAPTAIN_HOLD="$ROOT/bin/fm-captain-hold.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-resolve-key)

# Stub tmux: logs literal typed text to FM_SEND_LOG and lets the submit path
# reach a clean "empty" verdict (numeric cursor_y, empty bordered composer).
# FM_FAKE_TMUX_SEND_FAIL=1 makes send-keys fail so the delivery-failure leg can
# assert that a failed send closes nothing.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
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
      if [ -n "${FM_FAKE_TMUX_CHMOD_STATUS_ON_SEND:-}" ]; then
        chmod 0444 "$FM_FAKE_TMUX_CHMOD_STATUS_ON_SEND"
      fi
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows)
    printf '%s\n' fm-t1 fm-t2 fm-t3 fm-t4 fm-t5 fm-t6 fm-t7 fm-t8 fm-t9 fm-mate
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  cat > "$fb/date" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_DATE_CHMOD_AFTER_INBOX:-}" ] && [ -e "${FM_FAKE_DATE_INBOX:-}" ]; then
  chmod 0444 "$FM_FAKE_DATE_CHMOD_AFTER_INBOX"
fi
exec /bin/date "$@"
SH
  chmod +x "$fb/date"
  # Stub ssh transport for the remote-secondmate legs, selected via FM_SSH_BIN.
  # Records the full remote invocation and exits FM_FAKE_SSH_RC (default 0).
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "$FM_SSH_LOG"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <send-log> <fm-send args...>: run the real fm-send
# with the stubs on PATH against the given home. Guard noise goes to stderr,
# captured per test when the diagnostic matters.
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

setup_home() {  # <name> -> echoes a fresh home dir with an empty state/
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

setup_captain_hold() {  # <home> <task-id>
  local home=$1 id=$2 backlog="$1/data/backlog.md"
  mkdir -p "$home/data" "$home/config"
  if [ ! -f "$home/.tasks.toml" ]; then
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
    cat > "$backlog" <<'EOF'
# Backlog

## In flight

## Queued

## Done
EOF
  fi
  FM_TASKS_AXI_COMPATIBLE=1 tasks-axi add "$id" "Captain decision for $id" --kind captain --file "$backlog" >/dev/null
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$CAPTAIN_HOLD" hold "$id" \
    --reason "captain decision required" >/dev/null
}

setup_captain_answer() {  # <home> <task-id> <answer>
  local home=$1 id=$2 answer=$3 decision="$1/data/decision.txt"
  setup_captain_hold "$home" "$id"
  printf '%s\n' "$answer" > "$decision"
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$CAPTAIN_HOLD" answer "$id" \
    --decision-file "$decision" >/dev/null
}

drain_out() {  # <home>
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" 2>/dev/null
}

test_captain_decision_flag_absent_preserves_send_behavior() {
  local dir fb log home rc body
  dir="$TMP_ROOT/captain-absent"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home captain-absent)
  fm_write_meta "$home/state/tc0.meta" "window=sess:fm-tc0" "kind=ship"

  run_send "$fb" "$home" "$log" tc0 --captain-answer api-shape 'ordinary steer'; rc=$?
  expect_code 0 "$rc" "without the policy flag the option-looking text should remain an ordinary steer"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" \
    "$home/state/tc0.inbox/001.msg")
  [ "$body" = '--captain-answer api-shape ordinary steer' ] \
    || fail "the absent flag changed the original steer bytes: $body"
  pass "fm-send preserves option-looking steer bytes when captain-decides-findings is absent"
}

test_captain_decision_flag_requires_recorded_answer() {
  local dir fb log err home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is not installed; captain-answer enforcement requires its durable backlog)\n'
    return 0
  fi
  dir="$TMP_ROOT/captain-required"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home captain-required)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tc1.meta" "window=sess:fm-tc1" "kind=ship"
  printf 'needs-decision [key=api-shape]: choose an API\n' > "$home/state/tc1.status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tc1 --resolve-key api-shape --captain-answer api-shape "Use API A." >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a decision send without a recorded captain answer succeeded"
  assert_contains "$(cat "$err")" "missing a recorded captain answer" "the refusal should identify the missing captain answer"
  assert_contains "$(cat "$err")" "fm-captain-hold.sh answer <task-id> --decision-file <path>" \
    "the refusal should explain how to record the captain's answer"
  assert_contains "$(cat "$err")" "--captain-answer <task-id>" "the refusal should explain how to name the answer record"
  [ ! -s "$log" ] || fail "a refused decision answer was typed: $(cat "$log")"
  [ ! -e "$home/state/tc1.inbox/001.msg" ] || fail "a refused decision answer reached the worker"
  grep -qF 'needs-decision [key=api-shape]' "$home/state/tc1.status" \
    || fail "the refused decision was unexpectedly closed"
  pass "fm-send with captain-decides-findings refuses before delivery without a recorded captain answer"
}

test_captain_decision_flag_accepts_recorded_answer() {
  local dir fb log home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is not installed; captain-answer enforcement requires its durable backlog)\n'
    return 0
  fi
  dir="$TMP_ROOT/captain-accepted"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home captain-accepted)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tc2.meta" "window=sess:fm-tc2" "kind=ship"
  printf 'needs-decision [key=api-shape]: choose an API\n' > "$home/state/tc2.status"
  setup_captain_answer "$home" api-shape 'Use API A.'
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$CAPTAIN_HOLD" answer-recorded api-shape >/dev/null \
    || fail "the durable captain-hold answer was not recognized"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tc2 --resolve-key api-shape --captain-answer api-shape 'Use API A.' >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a decision send naming its recorded captain answer should succeed"
  grep -qF 'Use API A.' "$home/state/tc2.inbox/001.msg" \
    || fail "the captain answer did not reach the worker"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/tc2.status" \
    | grep -qF 'resolved [key=api-shape]: answered: Use API A.' \
    || fail "the sent answer did not close its matching decision"
  pass "fm-send accepts a named captain answer recorded by fm-captain-hold answer"
}

test_mapped_explicit_endpoint_can_resolve_decision() {
  local dir fb log err home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is not installed; captain-answer enforcement requires its durable backlog)\n'
    return 0
  fi
  dir="$TMP_ROOT/mapped-explicit-answer"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home mapped-explicit-answer)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/te1.meta" "window=sess:fm-te1" "kind=ship"
  printf 'needs-decision [key=route-choice]: select a route\n' > "$home/state/te1.status"
  setup_captain_answer "$home" route-choice 'Use route C.'

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" sess:fm-te1 \
    --resolve-key route-choice --captain-answer route-choice 'Use route C.' \
    >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a mapped explicit endpoint with task metadata should use this home's decision ledger: $(cat "$err")"
  grep -qF 'Use route C.' "$log" || fail "the mapped explicit endpoint did not receive the answer"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/te1.status" \
    | grep -qF 'resolved [key=route-choice]: answered: Use route C.' \
    || fail "the mapped explicit endpoint answer did not close its decision"
  pass "fm-send allows a mapped explicit endpoint to resolve its task's recorded decision"
}

test_remote_captain_decision_guard_runs_before_transport() {
  local dir fb log ssh_log err home rc
  dir="$TMP_ROOT/remote-captain-required"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; err="$dir/send.err"
  home=$(setup_home remote-captain-required)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/rmate.meta" "window=fm-remote:p1" "endpoint_task_id=rmate" \
    "remote_host=remote-host" "kind=secondmate"
  printf 'needs-decision [key=design]: choose a design\n' > "$home/state/rmate.status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 \
    "$SEND" rmate --resolve-key design --captain-answer design "choose A" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a remote decision send without a recorded captain answer succeeded"
  assert_contains "$(cat "$err")" "missing a recorded captain answer" \
    "the remote refusal should identify the missing captain answer"
  [ ! -s "$ssh_log" ] || fail "a refused remote answer crossed the transport: $(cat "$ssh_log")"
  [ ! -e "$home/state/rmate.inbox/001.msg" ] || fail "a refused remote answer reached its target"
  pass "fm-send applies captain-answer enforcement before remote delivery"
}

test_decision_declaration_is_structural_and_logged() {
  local dir fb log err home rc
  dir="$TMP_ROOT/decision-declaration"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home decision-declaration)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tg1.meta" "window=sess:fm-tg1" "kind=ship"
  printf 'needs-decision [key=review]: review decision\nblocked [key=dependency]: refresh dependency\n' \
    > "$home/state/tg1.status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" tg1 'approve every other finding' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an undeclared steer bypassed an open needs-decision key"
  assert_contains "$(cat "$err")" "require matching --resolve-key and --captain-answer declarations, or --no-decision" \
    "the structural refusal should request an explicit decision declaration"
  [ ! -e "$home/state/tg1.inbox/001.msg" ] || fail "an undeclared steer reached the worker"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:fm-tg1 'approve every other finding' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit endpoint matching task metadata bypassed the decision declaration"
  [ ! -s "$log" ] || fail "the undeclared explicit-endpoint steer was typed"

  run_send "$fb" "$home" "$log" tg1 --no-decision --resolve-key dependency 'refresh dependency'; rc=$?
  expect_code 0 "$rc" "a no-decision declaration may accompany an unrelated blocked-key resolution"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/tg1.status" \
    | grep -qF 'note: decision-declaration: no-decision' \
    || fail "the no-decision declaration was not logged in task status"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/tg1.status" \
    | grep -qF 'resolved [key=dependency]: answered: refresh dependency' \
    || fail "the unrelated blocker resolution did not remain effective"

  run_send "$fb" "$home" "$log" tg1 --no-decision --key Enter; rc=$?
  expect_code 0 "$rc" "a no-decision declaration should also cover a key send"
  [ "$(sed -E 's/ \[at=[0-9]+\]//' "$home/state/tg1.status" \
    | grep -Fc 'note: decision-declaration: no-decision')" -eq 2 ] \
    || fail "the key-send no-decision declaration was not recorded"
  pass "fm-send requires and logs structural decision declarations without inspecting steer wording"
}

test_invalid_status_source_refuses_policy_and_key_resolution() {
  local dir fb log err home key_home rc source
  dir="$TMP_ROOT/invalid-decision-status"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home invalid-decision-status)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tabsent.meta" "window=sess:fm-tabsent" "kind=ship"
  run_send "$fb" "$home" "$log" tabsent 'routine progress'; rc=$?
  expect_code 0 "$rc" "an absent status file should retain its no-open-decisions behavior"

  fm_write_meta "$home/state/tbad.meta" "window=sess:fm-tbad" "kind=ship"
  source="$home/state/decision-source"
  printf 'needs-decision [key=review]: choose a route\n' > "$source"
  ln -s "$source" "$home/state/tbad.status"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" tbad 'routine progress' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked decision-status source was treated as an empty ledger"
  assert_contains "$(cat "$err")" "cannot read or fold decision status file" \
    "the policy refusal should identify the invalid status source"
  [ ! -e "$home/state/tbad.inbox/001.msg" ] || fail "the steer reached a worker with an invalid status source"

  fm_write_meta "$home/state/tdir.meta" "window=sess:fm-tdir" "kind=ship"
  mkdir "$home/state/tdir.status"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" tdir 'routine progress' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a non-regular decision-status source was treated as an empty ledger"
  [ ! -e "$home/state/tdir.inbox/001.msg" ] || fail "the steer reached a worker with a non-regular status source"

  if [ "$(id -u)" -ne 0 ]; then
    fm_write_meta "$home/state/tunreadable.meta" "window=sess:fm-tunreadable" "kind=ship"
    status="$home/state/tunreadable.status"
    printf 'needs-decision [key=review]: choose a route\n' > "$status"
    chmod 000 "$status"
    env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
      "$SEND" tunreadable 'routine progress' >/dev/null 2>"$err"; rc=$?
    chmod 0600 "$status"
    [ "$rc" -ne 0 ] || fail "an unreadable decision-status source was treated as an empty ledger"
    assert_contains "$(cat "$err")" "cannot read or fold decision status file" \
      "the unreadable-source refusal should identify the invalid status source"
    [ ! -e "$home/state/tunreadable.inbox/001.msg" ] || fail "the steer reached a worker with an unreadable status source"
  fi

  if command -v tasks-axi >/dev/null 2>&1; then
    key_home=$(setup_home invalid-status-key-resolution)
    fm_write_meta "$key_home/state/tkey.meta" "window=sess:fm-tkey" "kind=ship"
    ln -s "$source" "$key_home/state/tkey.status"
    setup_captain_hold "$key_home" foo
    env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$key_home" FM_HOME="$key_home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
      FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tkey --resolve-key foo 'answer the held key' \
      >/dev/null 2>"$err"; rc=$?
    [ "$rc" -ne 0 ] || fail "the named-key fold treated an invalid status source as no live key and delivered via a held task"
    assert_contains "$(cat "$err")" "cannot read or fold decision status file" \
      "the named-key refusal should identify the invalid status source"
    [ ! -e "$key_home/state/tkey.inbox/001.msg" ] || fail "the answer reached a worker despite an invalid status source"
  fi
  pass "fm-send fails closed on existing invalid status sources while preserving absent-file behavior"
}

test_typed_no_decision_declaration_append_failure_prevents_delivery() {
  local dir fb log err home status rc
  if [ "$(id -u)" -eq 0 ]; then
    printf 'ok - skipped (read-only status append refusal is not testable as root)\n'
    return 0
  fi
  dir="$TMP_ROOT/typed-no-decision-append-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home typed-no-decision-append-fail)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/ttdf.meta" "window=sess:fm-ttdf" "kind=ship"
  status="$home/state/ttdf.status"
  printf 'needs-decision [key=review]: choose a route\n' > "$status"
  chmod 0444 "$status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 "$SEND" sess:fm-ttdf --no-decision 'routine progress' >/dev/null 2>"$err"; rc=$?
  chmod 0600 "$status"
  [ "$rc" -ne 0 ] || fail "typed delivery succeeded despite a failed declaration append"
  assert_contains "$(cat "$err")" "captain-decision declaration could not be recorded" \
    "the typed append refusal should identify the missing declaration"
  [ ! -s "$log" ] || fail "the typed steer reached a terminal without its declaration record"
  pass "fm-send refuses typed delivery when it cannot record the no-decision declaration"
}

test_inbox_no_decision_declaration_precedes_later_close_failure() {
  local dir fb log err home status rc
  if [ "$(id -u)" -eq 0 ]; then
    printf 'ok - skipped (read-only status append refusal is not testable as root)\n'
    return 0
  fi
  dir="$TMP_ROOT/inbox-declaration-before-close-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home inbox-declaration-before-close-fail)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tibf.meta" "window=sess:fm-tibf" "kind=ship"
  status="$home/state/tibf.status"
  printf 'needs-decision [key=review]: choose a route\nblocked [key=dependency]: refresh dependency\n' > "$status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_FAKE_DATE_CHMOD_AFTER_INBOX="$status" \
    FM_FAKE_DATE_INBOX="$home/state/tibf.inbox/001.msg" \
    "$SEND" tibf --no-decision --resolve-key dependency 'refresh dependency' \
    >/dev/null 2>"$err"; rc=$?
  chmod 0600 "$status"
  [ "$rc" -ne 0 ] || fail "the expected post-delivery inbox close failure did not occur"
  assert_contains "$(cat "$err")" "the answer was delivered" \
    "the close failure should report that inbox delivery already occurred"
  [ -e "$home/state/tibf.inbox/001.msg" ] || fail "the inbox steer was not durably delivered before the close failure"
  [ "$(sed -E 's/ \[at=[0-9]+\]//' "$status" | grep -Fc 'note: decision-declaration: no-decision')" -eq 1 ] \
    || fail "the declaration was not recorded exactly once before the later inbox bookkeeping failure"
  if grep -F 'resolved [key=dependency]' "$status" >/dev/null; then
    fail "the deliberately failed inbox close unexpectedly appeared in the status record"
  fi
  pass "fm-send records the decision declaration before a later inbox bookkeeping failure"
}

test_no_decision_declaration_append_failure_prevents_delivery() {
  local dir fb log err home status rc
  if [ "$(id -u)" -eq 0 ]; then
    printf 'ok - skipped (read-only status append refusal is not testable as root)\n'
    return 0
  fi
  dir="$TMP_ROOT/no-decision-append-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home no-decision-append-fail)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tdf.meta" "window=sess:fm-tdf" "kind=ship"
  status="$home/state/tdf.status"
  printf 'needs-decision [key=review]: choose a route\n' > "$status"
  chmod 0444 "$status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 "$SEND" tdf --no-decision 'routine progress' >/dev/null 2>"$err"; rc=$?
  chmod 0600 "$status"
  [ "$rc" -ne 0 ] || fail "the steer was delivered despite a failed declaration append"
  assert_contains "$(cat "$err")" "captain-decision declaration could not be recorded" \
    "the append refusal should identify the missing declaration"
  assert_contains "$(cat "$err")" "nothing was sent" "the append refusal should make the delivery outcome clear"
  [ ! -e "$home/state/tdf.inbox/001.msg" ] || fail "the steer reached the worker without its declaration record"
  [ ! -s "$log" ] || fail "the steer reached a terminal without its declaration record"
  pass "fm-send refuses delivery when it cannot record the no-decision declaration"
}

test_no_decision_declaration_precedes_later_close_failure() {
  local dir fb log err home status rc
  if [ "$(id -u)" -eq 0 ]; then
    printf 'ok - skipped (read-only status append refusal is not testable as root)\n'
    return 0
  fi
  dir="$TMP_ROOT/declaration-before-close-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home declaration-before-close-fail)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tdc.meta" "window=sess:fm-tdc" "kind=ship"
  status="$home/state/tdc.status"
  printf 'needs-decision [key=review]: choose a route\nblocked [key=dependency]: refresh dependency\n' \
    > "$status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_FAKE_TMUX_CHMOD_STATUS_ON_SEND="$status" \
    "$SEND" sess:fm-tdc --no-decision --resolve-key dependency 'refresh dependency' \
    >/dev/null 2>"$err"; rc=$?
  chmod 0600 "$status"
  [ "$rc" -ne 0 ] || fail "the expected post-delivery close failure did not occur"
  assert_contains "$(cat "$err")" "the answer was delivered" \
    "the close failure should report that delivery already occurred"
  grep -qF 'refresh dependency' "$log" || fail "the answer was not delivered before the close failure"
  [ "$(sed -E 's/ \[at=[0-9]+\]//' "$status" \
    | grep -Fc 'note: decision-declaration: no-decision')" -eq 1 ] \
    || fail "the declaration was not durably logged before the later close failure"
  if grep -F 'resolved [key=dependency]' "$status" >/dev/null; then
    fail "the deliberately failed close unexpectedly appeared in the status record"
  fi
  pass "fm-send records the no-decision declaration before a later close failure"
}

test_no_decision_cannot_resolve_a_needs_decision() {
  local dir fb log err home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is not installed; conflicting declaration test needs a recorded answer)\n'
    return 0
  fi
  dir="$TMP_ROOT/no-decision-conflict"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home no-decision-conflict)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tg2.meta" "window=sess:fm-tg2" "kind=ship"
  printf 'needs-decision [key=review]: review decision\n' > "$home/state/tg2.status"
  setup_captain_answer "$home" review 'Approve the reviewed change.'

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tg2 --no-decision --resolve-key review \
    --captain-answer review 'Approve the reviewed change.' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--no-decision accompanied an answer to its needs-decision key"
  assert_contains "$(cat "$err")" "--no-decision cannot accompany --resolve-key 'review'" \
    "the conflicting declaration should be identified"
  [ ! -e "$home/state/tg2.inbox/001.msg" ] || fail "the conflicting decision declaration reached the worker"
  pass "fm-send refuses --no-decision when the same send resolves a needs-decision"
}

test_multiple_needs_decisions_require_distinct_recorded_answers() {
  local dir fb log err home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is not installed; captain-answer enforcement requires its durable backlog)\n'
    return 0
  fi
  dir="$TMP_ROOT/multiple-captain-answers"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home multiple-captain-answers)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tm1.meta" "window=sess:fm-tm1" "kind=ship"
  printf 'needs-decision [key=nm-a]: first review\nneeds-decision [key=nm-b]: second review\n' \
    > "$home/state/tm1.status"
  setup_captain_answer "$home" nm-a 'Approve A.'

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tm1 --resolve-key nm-a --resolve-key nm-b \
    --captain-answer nm-a 'Approve both findings.' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "one recorded answer authorized two needs-decision keys"
  assert_contains "$(cat "$err")" "missing a recorded captain answer for this decision" \
    "the incomplete multi-key answer should identify its missing record"
  [ ! -e "$home/state/tm1.inbox/001.msg" ] || fail "the incompletely authorized multi-key answer reached the worker"

  setup_captain_answer "$home" nm-b 'Approve B.'
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tm1 --resolve-key nm-a --resolve-key nm-b \
    --captain-answer nm-a --captain-answer nm-b 'Approve both findings.' >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "separate recorded answers should authorize their matching decisions"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/tm1.status" \
    | grep -qF 'resolved [key=nm-a]: answered: Approve both findings.' \
    || fail "the first separately authorized decision was not closed"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/tm1.status" \
    | grep -qF 'resolved [key=nm-b]: answered: Approve both findings.' \
    || fail "the second separately authorized decision was not closed"
  pass "fm-send requires a distinct recorded captain answer for every needs-decision key"
}

test_captain_answer_scope_is_this_home() {
  local dir fb log err home foreign rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is not installed; captain-answer scope test needs its durable backlog)\n'
    return 0
  fi
  dir="$TMP_ROOT/captain-answer-home-scope"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home captain-answer-home-scope)
  foreign=$(setup_home captain-answer-foreign-data)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/thscope.meta" "window=sess:fm-thscope" "kind=ship"
  printf 'needs-decision [key=scope-choice]: choose a route\n' > "$home/state/thscope.status"
  setup_captain_hold "$home" scope-choice
  setup_captain_answer "$foreign" scope-choice 'A foreign answer must not authorize this home.'

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_DATA_OVERRIDE="$foreign/data" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" thscope --resolve-key scope-choice \
    --captain-answer scope-choice 'Use the local route.' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a different home's answer record authorized this decision"
  assert_contains "$(cat "$err")" "missing a recorded captain answer" \
    "the foreign answer refusal should identify the local record requirement"
  [ ! -e "$home/state/thscope.inbox/001.msg" ] || fail "the foreign answer reached this home's worker"

  printf '%s\n' 'The local captain chose the route.' > "$home/local-answer.txt"
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$CAPTAIN_HOLD" answer scope-choice --decision-file "$home/local-answer.txt" >/dev/null
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_DATA_OVERRIDE="$foreign/data" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" thscope --resolve-key scope-choice \
    --captain-answer scope-choice 'Use the local route.' >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "this home's recorded captain answer should still authorize its decision: $(cat "$err")"
  pass "fm-send captain-answer checks use only this home's recorded answer"
}

test_resolved_hold_answer_intake_uses_canonical_data() {
  local dir fb log err home foreign rc local_show foreign_show
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is not installed; keyed-answer intake needs its durable backlog)\n'
    return 0
  fi
  if ! env -u FM_TASKS_AXI_COMPATIBLE bash -c ". \"\$1\"; fm_tasks_axi_compatible" \
    _ "$ROOT/bin/fm-tasks-axi-lib.sh" >/dev/null 2>&1; then
    fail "tasks-axi must meet firstmate's required version and command-surface compatibility for nested captain-answer intake"
  fi
  dir="$TMP_ROOT/captain-answer-intake-scope"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home captain-answer-intake-local)
  foreign=$(setup_home captain-answer-intake-foreign)
  fm_write_meta "$home/state/thintake.meta" "window=sess:fm-thintake" "kind=ship"
  printf 'needs-decision [key=intake-choice]: choose a route\n' > "$home/state/thintake.status"
  setup_captain_hold "$home" intake-choice
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$CAPTAIN_HOLD" complete thintake intake-choice >/dev/null
  setup_captain_hold "$foreign" intake-choice
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_DATA_OVERRIDE="$foreign/data" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" thintake --resolve-key intake-choice \
    'Use the local intake path.' >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "the keyed-answer intake should use this home's held task: $(cat "$err")"
  local_show=$(cd "$home" && FM_TASKS_AXI_COMPATIBLE=1 tasks-axi show intake-choice --full \
    --file "$home/data/backlog.md") || fail "could not inspect the local captain-held task"
  foreign_show=$(cd "$foreign" && FM_TASKS_AXI_COMPATIBLE=1 tasks-axi show intake-choice --full \
    --file "$foreign/data/backlog.md") || fail "could not inspect the foreign captain-held task"
  assert_contains "$local_show" "state: done" "the local held task was not closed by its keyed answer"
  assert_contains "$foreign_show" "held: yes" "the foreign held task was unexpectedly changed"
  assert_not_contains "$foreign_show" "state: done" "the foreign held task was closed through FM_DATA_OVERRIDE"
  pass "fm-send keyed-answer intake uses only this home's data"
}

test_transferred_held_decision_requires_its_recorded_answer() {
  local dir fb log err home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is not installed; transferred-decision enforcement needs its durable backlog)\n'
    return 0
  fi
  dir="$TMP_ROOT/transferred-captain-decision"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home transferred-captain-decision)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/th1.meta" "window=sess:fm-th1" "kind=ship"
  printf 'needs-decision [key=transferred-choice]: choose a route\n' > "$home/state/th1.status"
  setup_captain_hold "$home" transferred-choice
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$CAPTAIN_HOLD" complete th1 transferred-choice >/dev/null

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" th1 'approve this finding' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unmarked steer bypassed a transferred captain-held decision"
  assert_contains "$(cat "$err")" "open decision key(s) 'transferred-choice'" \
    "the transferred hold refusal should name its decision key"
  [ ! -e "$home/state/th1.inbox/001.msg" ] || fail "an unmarked steer reached the worker despite a transferred hold"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" sess:fm-th1 'approve this finding' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit endpoint bypassed a transferred captain-held decision"
  [ ! -s "$log" ] || fail "the explicit-endpoint steer bypassed a transferred hold"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" th1 --no-decision 'routine progress update' \
    >/dev/null 2>"$err"; rc=$?
  [ "$rc" -eq 0 ] || fail "--no-decision should permit a non-answering steer for a transferred hold: $(cat "$err")"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/th1.status" \
    | grep -qF 'note: decision-declaration: no-decision' \
    || fail "the transferred-hold no-decision declaration was not logged"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" th1 --resolve-key transferred-choice \
    'use the north route' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a transferred hold was answered by fm-send instead of a captain record"
  assert_contains "$(cat "$err")" "settled only by bin/fm-captain-hold.sh answer" \
    "the transferred hold should point at the captain record"
  [ ! -e "$home/state/th1.inbox/002.msg" ] || fail "an unrecorded held answer reached the worker"

  setup_captain_answer "$home" unrelated-choice 'Choose the west route.'
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" th1 'use the north route' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unrelated captain answer settled the transferred hold"
  [ ! -e "$home/state/th1.inbox/002.msg" ] || fail "an unrelated held answer reached the worker"

  printf '%s\n' 'Use the north route.' > "$home/data/transferred-answer.txt"
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$CAPTAIN_HOLD" answer transferred-choice --decision-file "$home/data/transferred-answer.txt" >/dev/null
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" th1 'use the north route' >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "the held decision's own recorded answer should settle it: $(cat "$err")"
  grep -qF 'use the north route' "$home/state/th1.inbox/002.msg" \
    || fail "the captain's answer did not reach the worker once recorded"
  pass "fm-send gates transferred holds on their own recorded captain answer"
}

test_closed_unanswered_transferred_hold_still_gates_steers() {
  local dir fb log err home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is required for durable captain-hold compatibility)\n'
    return 0
  fi
  dir="$TMP_ROOT/closed-unanswered-transferred-hold"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home closed-unanswered-transferred-hold)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tclosed.meta" "window=sess:fm-tclosed" "kind=ship"
  printf 'needs-decision [key=closed-choice]: choose a route\n' > "$home/state/tclosed.status"
  setup_captain_hold "$home" closed-choice
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$CAPTAIN_HOLD" complete tclosed closed-choice >/dev/null
  (cd "$home" && FM_TASKS_AXI_COMPATIBLE=1 tasks-axi 'done' closed-choice >/dev/null) \
    || fail "could not close the transferred hold without recording an answer"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tclosed 'routine progress' \
    >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an ordinary steer bypassed a closed transferred hold without an answer"
  assert_contains "$(cat "$err")" "open decision key(s) 'closed-choice'" \
    "the refusal should identify the unanswered transferred decision"
  [ ! -e "$home/state/tclosed.inbox/001.msg" ] \
    || fail "the ordinary steer reached the worker despite an unanswered transferred hold"
  pass "fm-send keeps closed unanswered transferred decisions in the captain gate"
}

test_missing_and_unreadable_inventory_holds_block_plain_steers() {
  local dir fb log err home rc backlog
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is required for captain-hold inventory enforcement)\n'
    return 0
  fi
  dir="$TMP_ROOT/incomplete-captain-inventory"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"

  home=$(setup_home missing-inventory-hold)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tmissing.meta" "window=sess:fm-tmissing" "kind=ship" \
    "decision_keys=missing-choice"
  setup_captain_hold "$home" unrelated-choice
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tmissing 'routine progress' \
    >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a missing inventory task was treated as a settled decision"
  assert_contains "$(cat "$err")" "open decision key(s) 'missing-choice'" \
    "a missing inventory task should remain an open captain decision"
  [ ! -e "$home/state/tmissing.inbox/001.msg" ] \
    || fail "a steer reached the worker despite a missing inventory task"

  if [ "$(id -u)" -ne 0 ]; then
    home=$(setup_home unreadable-inventory-hold)
    mkdir -p "$home/config"
    : > "$home/config/captain-decides-findings"
    fm_write_meta "$home/state/tunreadable-hold.meta" "window=sess:fm-tunreadable-hold" \
      "kind=ship" "decision_keys=unreadable-choice"
    setup_captain_hold "$home" unreadable-choice
    backlog="$home/data/backlog.md"
    chmod 000 "$backlog"
    env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
      FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tunreadable-hold 'routine progress' \
      >/dev/null 2>"$err"; rc=$?
    chmod 0600 "$backlog"
    [ "$rc" -ne 0 ] || fail "an unreadable captain-held task was treated as a settled decision"
    assert_contains "$(cat "$err")" "open decision key(s) 'unreadable-choice'" \
      "an unreadable inventory task should remain an open captain decision"
    [ ! -e "$home/state/tunreadable-hold.inbox/001.msg" ] \
      || fail "a steer reached the worker despite an unreadable captain-held task"
  else
    printf 'ok - skipped unreadable-file leg (permission denial is not testable as root)\n'
  fi
  pass "fm-send keeps missing and unreadable captain-held inventory decisions open"
}

test_uninventoried_answered_hold_cannot_be_relayed() {
  local dir fb log err home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is required for durable captain-hold compatibility)\n'
    return 0
  fi
  dir="$TMP_ROOT/uninventoried-answered-hold"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home uninventoried-answered-hold)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tnoinv.meta" "window=sess:fm-tnoinv" "kind=ship"
  setup_captain_answer "$home" review 'Approve the unrelated review.'
  (cd "$home" && FM_TASKS_AXI_COMPATIBLE=1 tasks-axi 'done' review >/dev/null) \
    || fail "could not close the unrelated answered task"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tnoinv --resolve-key review \
    --captain-answer review 'approve the review' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unrelated answered task authorized a decision this target never had"
  assert_contains "$(cat "$err")" "no open decision with that key" \
    "the refusal should say the key is not this task's decision"
  [ ! -s "$log" ] || fail "the uninventoried answer was typed"
  [ ! -e "$home/state/tnoinv.inbox/001.msg" ] \
    || fail "the uninventoried answer reached the worker"
  if [ -f "$home/state/tnoinv.status" ] && grep -qF 'answered-key=review' "$home/state/tnoinv.status"; then
    fail "an answered-key declaration was logged for a decision this target never had"
  fi
  pass "fm-send refuses captain answers for keys absent from status and inventory"
}

test_self_resolved_decision_still_gates_steers() {
  local dir fb log err home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is required for durable captain-hold compatibility)\n'
    return 0
  fi
  dir="$TMP_ROOT/self-resolved-decision"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home self-resolved-decision)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tself.meta" "window=sess:fm-tself" "kind=ship"
  printf 'needs-decision [key=review]: approve the findings?\nresolved [key=review]: approved them myself\n' \
    > "$home/state/tself.status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tself 'approve every other finding' \
    >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a worker self-resolve cleared a decision without a captain answer"
  assert_contains "$(cat "$err")" "open decision key(s) 'review'" \
    "the self-resolved decision should remain open"
  [ ! -e "$home/state/tself.inbox/001.msg" ] || fail "a steer reached the worker after a self-resolve"

  setup_captain_answer "$home" review 'Approve only R1.'
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tself 'Approve only R1.' \
    >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "the exact captain answer record should settle the self-resolved decision: $(cat "$err")"
  pass "fm-send keeps a worker-resolved decision open until its captain answer record exists"
}

test_blocked_key_retains_decision_answer_requirement() {
  local dir fb log err home rc
  dir="$TMP_ROOT/blocked-decision-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home blocked-decision-key)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tblocked.meta" "window=sess:fm-tblocked" "kind=ship"
  printf '%s\n' 'needs-decision [key=review]: review this change' \
    'blocked [key=review]: waiting on the review answer' > "$home/state/tblocked.status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tblocked --resolve-key review \
    'approve the change' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a blocked key discarded its needs-decision captain-answer requirement"
  assert_contains "$(cat "$err")" "missing a recorded captain answer" \
    "the blocked decision should require its recorded captain answer"
  [ ! -e "$home/state/tblocked.inbox/001.msg" ] || fail "an answer without captain approval reached the worker"
  pass "fm-send preserves decision ownership when a key changes to blocked"
}

test_answered_key_note_does_not_settle_decision() {
  local dir fb log err home rc
  dir="$TMP_ROOT/answered-key-note"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home answered-key-note)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tnote.meta" "window=sess:fm-tnote" "kind=ship"
  printf '%s\n' 'needs-decision [key=review]: approve the findings?' \
    'resolved [key=review]: approved' 'note: decision-declaration: answered-key=review' \
    > "$home/state/tnote.status"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tnote 'approve every finding' \
    >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a status answered-key note settled a decision without a captain answer record"
  assert_contains "$(cat "$err")" "open decision key(s) 'review'" \
    "a forged answered-key note should leave the decision open"
  [ ! -e "$home/state/tnote.inbox/001.msg" ] || fail "a steer reached the worker on a forged note"
  pass "fm-send ignores status answered-key notes as answer authority"
}

test_old_key_answer_cannot_override_origin_hold() {
  local dir fb log err home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is required for durable captain-hold compatibility)\n'
    return 0
  fi
  dir="$TMP_ROOT/old-key-answer"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home old-key-answer)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tnew.meta" "window=sess:fm-tnew" "kind=ship"
  printf 'needs-decision [key=review]: review the new decision\n' > "$home/state/tnew.status"
  setup_captain_answer "$home" review 'Approve the old decision.'
  setup_captain_hold "$home" tnew-decision-review

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tnew --resolve-key review \
    --captain-answer review 'approve the new decision' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an old key-named answer authorized a different origin's unanswered decision"
  assert_contains "$(cat "$err")" "missing a recorded captain answer" \
    "the origin-derived unanswered hold should be authoritative"
  [ ! -e "$home/state/tnew.inbox/001.msg" ] || fail "the stale answer reached the worker"
  pass "fm-send binds a keyed answer to the origin-derived hold before a global key task"
}

test_double_relay_is_refused() {
  local dir fb log err home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is required for durable captain-hold compatibility)\n'
    return 0
  fi
  dir="$TMP_ROOT/double-relay"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home double-relay)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tdouble.meta" "window=sess:fm-tdouble" "kind=ship"
  printf 'needs-decision [key=review]: approve the findings?\n' > "$home/state/tdouble.status"
  setup_captain_answer "$home" review 'Approve only R1.'
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tdouble --resolve-key review \
    --captain-answer review 'Approve only R1.' >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "the first relay of a recorded answer should succeed: $(cat "$err")"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tdouble --resolve-key review \
    --captain-answer review 'Approve only R1.' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a second relay delivered an already-closed decision answer"
  assert_contains "$(cat "$err")" "no open decision with that key" \
    "the second relay should say the key is no longer open"
  [ ! -e "$home/state/tdouble.inbox/002.msg" ] || fail "the second relay reached the worker"
  [ "$(grep -c 'answered-key=review' "$home/state/tdouble.status")" -eq 1 ] \
    || fail "the second relay logged another answered-key declaration"
  pass "fm-send refuses a second relay of an already-closed decision"
}

test_answered_secondmate_decision_does_not_block() {
  local dir fb log err home child rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is required for durable captain-hold compatibility)\n'
    return 0
  fi
  dir="$TMP_ROOT/answered-secondmate"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home answered-secondmate-parent)
  child=$(setup_home answered-secondmate-child)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_secondmate_meta "$home/state/mate.meta" "$child" "sess:fm-mate"
  setup_captain_hold "$child" mate-call
  printf '%s\n' 'needs-decision [key=captain-hold-mate-call-1]: captain hold mate-call: pick a shard' \
    'resolved [key=captain-hold-mate-call-1]: captain hold mate-call: answered' \
    > "$home/state/mate.status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" fm-mate 'routine progress' \
    >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a resolved channel line settled a secondmate call without its answer record"
  assert_contains "$(cat "$err")" "captain-hold-mate-call-1" \
    "the unanswered secondmate call should remain open"

  printf '%s\n' 'Shard by team.' > "$child/data/mate-answer.txt"
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$child" FM_ROOT_OVERRIDE="$ROOT" \
    "$CAPTAIN_HOLD" answer mate-call --decision-file "$child/data/mate-answer.txt" >/dev/null \
    || fail "could not record the secondmate's captain answer"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" fm-mate 'routine progress' \
    >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an answered secondmate call should not block later steers: $(cat "$err")"
  pass "fm-send settles a secondmate parent-channel call by its own home's answer record"
}

test_terminal_status_does_not_settle_decisions() {
  local dir fb log err home rc verb
  dir="$TMP_ROOT/terminal-cleared-decision"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  for verb in 'done' failed; do
    home=$(setup_home "terminal-$verb")
    mkdir -p "$home/config"
    : > "$home/config/captain-decides-findings"
    fm_write_meta "$home/state/tterm.meta" "window=sess:fm-tterm" "kind=ship"
    printf 'needs-decision [key=gate-choice]: approve the gate?\n%s: finished\n' "$verb" \
      > "$home/state/tterm.status"
    env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
      FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tterm 'approve it' \
      >/dev/null 2>"$err"; rc=$?
    [ "$rc" -ne 0 ] || fail "a $verb: line cleared a decision without a captain answer"
    assert_contains "$(cat "$err")" "open decision key(s) 'gate-choice'" \
      "the decision cleared by $verb: should remain open"
    [ ! -e "$home/state/tterm.inbox/001.msg" ] || fail "a steer reached the worker after $verb:"
  done
  pass "fm-send keeps decisions cleared by done:/failed: open for the captain"
}

test_partial_inventory_transfer_still_gates_omitted_key() {
  local dir fb log err home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is required for durable captain-hold compatibility)\n'
    return 0
  fi
  dir="$TMP_ROOT/partial-inventory-transfer"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home partial-inventory-transfer)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/tpart.meta" "window=sess:fm-tpart" "kind=ship"
  printf 'needs-decision [key=first-choice]: first\nneeds-decision [key=second-choice]: second\n' \
    > "$home/state/tpart.status"
  setup_captain_answer "$home" first-choice 'Take the first route.'
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$CAPTAIN_HOLD" complete tpart first-choice >/dev/null 2>&1 || true
  grep -q '^captain-held.*\[key=second-choice\]' "$home/state/tpart.status" \
    || fail "fixture: complete did not transfer the omitted key: $(cat "$home/state/tpart.status")"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" tpart 'routine progress' \
    >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a key omitted from the transfer inventory was treated as settled"
  assert_contains "$(cat "$err")" "second-choice" \
    "the refusal should name the omitted decision key"
  [ ! -e "$home/state/tpart.inbox/001.msg" ] \
    || fail "a steer reached the worker despite the omitted unanswered decision"
  pass "fm-send gates a decision a partial captain-hold transfer left out of the inventory"
}

test_captain_answer_uses_authoritative_hold_identity() {
  local dir fb home log err rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is not installed; hold identity test needs its durable backlog)\n'
    return 0
  fi
  dir="$TMP_ROOT/captain-answer-authority"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home captain-answer-authority)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/ta1.meta" "window=sess:fm-ta1" "kind=ship"
  printf 'needs-decision [key=foo]: choose a route\n' > "$home/state/ta1.status"
  setup_captain_hold "$home" foo
  setup_captain_answer "$home" ta1-decision-foo 'Legacy answer for the wrong identity.'

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" ta1 --resolve-key foo \
    --captain-answer ta1-decision-foo 'Use the north route.' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a legacy answer authorized an existing exact hold identity"
  assert_contains "$(cat "$err")" "missing a recorded captain answer for this decision" \
    "the exact task should remain the answer owner"
  [ ! -e "$home/state/ta1.inbox/001.msg" ] || fail "the wrong-identity answer reached an open status decision"

  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$CAPTAIN_HOLD" complete ta1 foo >/dev/null
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" ta1 'Use the north route.' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a legacy answer settled a transferred exact hold identity"
  assert_contains "$(cat "$err")" "open decision key(s) 'foo'" \
    "the transferred exact task should remain the answer owner"
  [ ! -e "$home/state/ta1.inbox/001.msg" ] || fail "the wrong-identity answer reached the transferred hold"

  home=$(setup_home captain-open-hold-identity)
  fm_write_meta "$home/state/ta2.meta" "window=sess:fm-ta2" "kind=ship"
  setup_captain_answer "$home" baz 'Answer recorded for exact baz.'
  setup_captain_hold "$home" ta2-decision-baz
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" ta2 --resolve-key baz 'Do not answer the legacy row.' \
    >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an open legacy row displaced an existing exact task identity"
  [ ! -e "$home/state/ta2.inbox/001.msg" ] || fail "the exact-identity refusal reached the worker"
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$CAPTAIN_HOLD" open ta2-decision-baz >/dev/null \
    || fail "the wrong legacy hold was closed by the rejected answer"

  home=$(setup_home captain-legacy-identity)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/ta3.meta" "window=sess:fm-ta3" "kind=ship"
  printf 'needs-decision [key=bar]: choose a route\n' > "$home/state/ta3.status"
  setup_captain_answer "$home" ta3-decision-bar 'Legacy owner answer.'
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_TASKS_AXI_COMPATIBLE=1 "$SEND" ta3 --resolve-key bar \
    --captain-answer ta3-decision-bar 'Use the legacy route.' >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "the legacy identity should remain valid when no exact task exists"
  grep -qF 'Use the legacy route.' "$home/state/ta3.inbox/001.msg" \
    || fail "the valid legacy answer did not reach the worker"
  pass "fm-send binds recorded answers to the exact-first authoritative hold identity"
}

test_migrated_beads_hold_is_gated_and_uses_canonical_id() {
  local dir home graph beads fb log err scout key legacy canonical answer resolved rc
  if ! command -v bd >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (Beads migration relay requires bd, jq, and tasks-axi)\n'
    return 0
  fi
  dir="$TMP_ROOT/migrated-beads-send"; home="$dir/home"; graph="$dir/fm"
  mkdir -p "$home/data" "$home/config" "$home/state" "$graph"
  git -C "$graph" init -q
  if ! (cd "$graph" && bd init >"$dir/bd-init.log" 2>&1); then
    printf 'ok - skipped (bd cannot initialize the Beads migration fixture)\n'
    return 0
  fi
  beads="$graph/.beads"
  cat > "$home/.tasks.toml" <<EOF
backend = "beads"

[beads]
path = "$beads"
binary = "bd"
prefix = "fm"

[markdown]
path = "data/backlog.md"
EOF
  if ! (cd "$home" && tasks-axi list >/dev/null 2>&1); then
    printf 'ok - skipped (tasks-axi does not support the Beads backend required for migration relay)\n'
    return 0
  fi

  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  scout=sample-migrated-scout; key=github-delete
  legacy="$scout-decision-$key"; canonical=fm-relocated-captain-call
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add "$canonical" \
    'Captain call moved during migration' --repo sample >/dev/null) \
    || fail "could not create the migrated captain-held task"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold "$canonical" --kind captain \
    --reason 'captain must decide' >/dev/null) \
    || fail "could not hold the migrated captain task"
  BEADS_DIR="$beads" bd note "$canonical" \
    "migrated from data/backlog.md id $legacy on 2026-09-04" >/dev/null \
    || fail "could not record the legacy identity on the migrated task"
  fm_write_meta "$home/state/$scout.meta" "window=sess:fm-$scout" "kind=ship"
  printf 'needs-decision [key=%s]: choose whether to delete the repo\n' "$key" \
    > "$home/state/$scout.status"
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE='' \
    "$CAPTAIN_HOLD" complete "$scout" "$key" >/dev/null \
    || fail "complete did not transfer the migrated decision"
  resolved=$(FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE='' \
    "$CAPTAIN_HOLD" resolve-entry "$scout" "$key") \
    || fail "the shared resolver did not resolve the migrated identity"
  [ "$resolved" = "$canonical" ] \
    || fail "the shared resolver returned '$resolved' instead of canonical task id '$canonical'"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_DATA_OVERRIDE='' \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 \
    "$SEND" "$scout" 'routine progress' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unresolved migrated captain hold failed to gate an ordinary steer"
  assert_contains "$(cat "$err")" "open decision key(s) '$key'" \
    "the migrated decision refusal should name its inventory key"
  [ ! -e "$home/state/$scout.inbox/001.msg" ] \
    || fail "an ordinary steer reached the worker despite the migrated hold"

  answer="$home/data/captain-answer.txt"
  printf 'Do not delete the repository.\n' > "$answer"
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE='' \
    "$CAPTAIN_HOLD" answer "$canonical" --decision-file "$answer" >/dev/null \
    || fail "could not record the answer on the canonical migrated task"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_DATA_OVERRIDE='' \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 \
    "$SEND" "$scout" --resolve-key "$key" --captain-answer "$legacy" \
    'Do not delete the repository.' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "fm-send relayed a migrated hold instead of leaving it to the captain record"
  [ ! -e "$home/state/$scout.inbox/001.msg" ] \
    || fail "the legacy alias answer reached the worker"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_DATA_OVERRIDE='' \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 \
    "$SEND" "$scout" 'Do not delete the repository.' >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "the canonical migrated answer record should settle its transferred decision: $(cat "$err")"
  grep -qF 'Do not delete the repository.' "$home/state/$scout.inbox/001.msg" \
    || fail "the canonical migrated captain answer did not reach the worker"
  pass "fm-send gates migrated captain holds until their canonical task records an answer"
}

test_legacy_declined_answer_can_be_relayed() {
  local dir fb log err home hold_id decision digest body rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'ok - skipped (tasks-axi is not installed; legacy captain-answer relay needs its durable backlog)\n'
    return 0
  fi
  dir="$TMP_ROOT/legacy-declined-answer"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home legacy-declined-answer)
  mkdir -p "$home/config"
  : > "$home/config/captain-decides-findings"
  fm_write_meta "$home/state/td1.meta" "window=sess:fm-td1" "kind=ship"
  printf 'needs-decision [key=route-choice]: choose a route\n' > "$home/state/td1.status"
  hold_id=td1-decision-route-choice
  setup_captain_hold "$home" "$hold_id"
  decision='Declined: keep the current shape.'
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  else
    digest=$(printf '%s' "$decision" | sha256sum | awk '{print $1}')
  fi
  body="$home/data/legacy-decline-body.txt"
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nResolution mode: declined\n\nCaptain decision:\n%s\n' \
    "$digest" "$decision" > "$body"
  (cd "$home" && FM_TASKS_AXI_COMPATIBLE=1 tasks-axi update "$hold_id" \
    --body-file "$body" --archive-body >/dev/null) \
    || fail "could not seed the completed legacy declined-answer record"
  (cd "$home" && FM_TASKS_AXI_COMPATIBLE=1 tasks-axi 'done' "$hold_id" >/dev/null) \
    || fail "could not close the legacy captain-held task"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_TASKS_AXI_COMPATIBLE=1 "$SEND" td1 --resolve-key route-choice \
    --captain-answer "$hold_id" 'Keep the current shape.' >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a recorded legacy decline should authorize relaying the captain's answer: $(cat "$err")"
  grep -qF 'Keep the current shape.' "$home/state/td1.inbox/001.msg" \
    || fail "the legacy declined captain answer did not reach the worker"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/td1.status" \
    | grep -qF 'resolved [key=route-choice]: answered: Keep the current shape.' \
    || fail "the relayed legacy declined answer did not close its review decision"
  pass "fm-send relays decisions with a recorded legacy declined answer"
}

test_answer_send_closes_open_decision() {
  local dir fb log home rc out
  dir="$TMP_ROOT/closes"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home closes)
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/t1.status"
  printf 'working: kept busy on an unrelated stream\n' >> "$home/state/t1.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "precondition: the buried decision should list as open before the answer"

  run_send "$fb" "$home" "$log" t1 --resolve-key api-shape "go with REST"; rc=$?
  expect_code 0 "$rc" "an answer send with --resolve-key should succeed"
  grep -qF "go with REST" "$home/state/t1.inbox/001.msg" \
    || fail "the answer text should reach the worker's durable inbox record"
  assert_contains "$(cat "$log")" "Firstmate instruction waiting" "the doorbell should be rung for the answer"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t1.status" | grep -qF 'resolved [key=api-shape]: answered: go with REST' \
    || fail "fm-send did not append the closing resolved line:"$'\n'"$(cat "$home/state/t1.status")"
  # The drain folded the worker's `working:` line but never listed it, so the
  # close must leave the file for the watcher instead of marking it seen.
  if FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t1.status"; then
    fail "the answerer's close hid a worker line the drain never listed"
  fi

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: the answer send itself closes the open decision"
}

# The answerer's close is this home's own bookkeeping: it must not re-wake the
# session that wrote it, while any other writer's later line on the same task
# still must. Both directions are read through the production seen-signature
# gate the watcher's signal scan consumes (bin/fm-wake-lib.sh).
test_answer_close_is_self_announced() {
  local dir fb log home rc
  dir="$TMP_ROOT/self-announced"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home self-announced)
  fm_write_meta "$home/state/t9.meta" "window=sess:fm-t9" "kind=ship"
  printf 'needs-decision [key=port-choice]: 8080 or 9090\n' > "$home/state/t9.status"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t9.status" \
    || fail "could not prime the announced baseline"

  run_send "$fb" "$home" "$log" t9 --resolve-key port-choice "use 9090"; rc=$?
  expect_code 0 "$rc" "the answer send should succeed"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t9.status" | grep -qF 'resolved [key=port-choice]: answered: use 9090' \
    || fail "the closing resolved line is missing"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t9.status" \
    || fail "the answerer's own close was left to re-wake this same home"

  printf 'done: worker finished after the answer\n' >> "$home/state/t9.status"
  if FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t9.status"; then
    fail "a later worker line after the self-announced close was swallowed"
  fi
  pass "fm-send --resolve-key: the close never re-wakes its own home, later lines still do"
}

# Two distinct --resolve-key answers must each stay quiet even when the seen
# marker does NOT cover them. An in-flight watcher classification that lands
# after the first answer regresses the classified offset behind that answer's
# bytes, so the marker no longer vouches for them; only the home-appends ledger
# does. Without the ledger the second scan re-wakes this home over its own
# close. A later worker line on the same task still wakes.
test_separate_resolve_key_answers_do_not_rewake() {
  local dir fb log home rc status pre_answer ident
  dir="$TMP_ROOT/separate-answers"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home separate-answers)
  status="$home/state/t7.status"
  fm_write_meta "$home/state/t7.meta" "window=sess:fm-t7" "kind=ship"
  {
    printf 'needs-decision [key=budget]: approve spend?\n'
    printf 'needs-decision [key=vendor]: pick a vendor\n'
  } > "$status"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$status" \
    || fail "could not prime the announced baseline"
  pre_answer=$(wc -c < "$status" | tr -d '[:space:]')

  run_send "$fb" "$home" "$log" t7 --resolve-key budget "approved"; rc=$?
  expect_code 0 "$rc" "the first answer should succeed"

  # A watcher classification captured before the answer commits afterwards and
  # rewinds the classified offset behind the answer's bytes.
  ident=$(FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; _fm_open_decisions_file_ident "$2"
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$status") \
    || fail "could not read the status identity"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_status_seen_commit "$2" "$3" "$4" "$5"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$status" "$pre_answer" "$ident" \
    || fail "could not replay the stale watcher classification"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$status" \
    || fail "the first --resolve-key answer was left to re-wake this home"

  run_send "$fb" "$home" "$log" t7 --resolve-key vendor "acme"; rc=$?
  expect_code 0 "$rc" "the second answer should succeed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$status" \
    || fail "the second --resolve-key answer was left to re-wake this home"

  printf 'blocked: need staging credentials\n' >> "$status"
  if FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$status"; then
    fail "a later worker line after two answers was swallowed"
  fi
  pass "fm-send --resolve-key: separate answers do not each re-wake; later lines still do"
}

# The reported failure behind issue #2109: a worker that put the colon first
# (needs-decision: [key=X] ...) had its key silently folded to "default", so
# the answer's --resolve-key X refused with "no open decision or blocker with
# that key". The stated key must be honored in that position too, end to end
# through the real send.
test_colon_first_key_position_is_answerable() {
  local dir fb log home rc out
  dir="$TMP_ROOT/colon-first"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home colon-first)
  fm_write_meta "$home/state/t8.meta" "window=sess:fm-t8" "kind=ship"
  printf 'needs-decision: [key=seam-max-bound] cap the seam at 4 or 8\n' > "$home/state/t8.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=seam-max-bound]' >/dev/null \
    || fail "precondition: the colon-first decision should list as open under its stated key: $out"

  run_send "$fb" "$home" "$log" t8 --resolve-key seam-max-bound "cap it at 4"; rc=$?
  expect_code 0 "$rc" "answering a colon-first stated key should succeed, not refuse as unknown"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t8.status" | grep -qF 'resolved [key=seam-max-bound]: answered: cap it at 4' \
    || fail "the closing resolved line is missing:"$'\n'"$(cat "$home/state/t8.status")"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered colon-first decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a colon-first stated key is open under that key and answerable"
}

test_answer_starts_work_never_orphans() {
  local dir fb log home rc out
  dir="$TMP_ROOT/starts-work"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home starts-work)
  fm_write_meta "$home/state/t2.meta" "window=sess:fm-t2" "kind=ship"
  printf 'needs-decision [key=rollout]: big-bang or phased\n' > "$home/state/t2.status"

  run_send "$fb" "$home" "$log" t2 --resolve-key rollout "phased, gate each region"; rc=$?
  expect_code 0 "$rc" "the rollout answer send should succeed"
  # The forensic scenario: the answer starts a workstream, so the worker's next
  # events use a DIFFERENT key namespace and it never writes
  # resolved [key=rollout] itself.
  printf 'working [key=phased-impl]: building region gates\n' >> "$home/state/t2.status"
  printf 'done [key=phased-impl]: PR up\n' >> "$home/state/t2.status"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision orphaned after the answer started work: $out"
  fi
  pass "fm-send --resolve-key: an answer that starts a workstream leaves no orphaned decision"
}

test_routine_steer_never_closes() {
  local dir fb log home rc out
  dir="$TMP_ROOT/routine"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home routine)
  fm_write_meta "$home/state/t3.meta" "window=sess:fm-t3" "kind=ship"
  printf 'needs-decision [key=schema]: split or embed\n' > "$home/state/t3.status"

  run_send "$fb" "$home" "$log" t3 "unrelated nudge, keep going"; rc=$?
  expect_code 0 "$rc" "a routine steer should still succeed"
  printf 'working: resumed\n' >> "$home/state/t3.status"

  if grep -F 'resolved' "$home/state/t3.status" >/dev/null; then
    fail "a routine steer wrote a resolved line: $(cat "$home/state/t3.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=schema]' >/dev/null \
    || fail "a routine steer or later working line cleared an unanswered captain decision: $out"
  printf 'done: task complete\nnote: cleanup complete\n' >> "$home/state/t3.status"
  run_send "$fb" "$home" "$log" t3 --resolve-key schema "answer to a stale decision" > "$dir/terminal.out" 2> "$dir/terminal.err"; rc=$?
  expect_code 1 "$rc" "an answer to a terminally superseded decision must refuse"
  [ ! -e "$home/state/t3.inbox/002.msg" ] || fail "a stale decision answer was delivered"
  pass "fm-send preserves decisions through routine work and refuses superseded terminal decisions"
}

test_not_open_key_refuses_before_send() {
  local dir fb log home err rc out
  dir="$TMP_ROOT/not-open"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home not-open)
  fm_write_meta "$home/state/t4.meta" "window=sess:fm-t4" "kind=ship"
  printf 'needs-decision [key=real-key]: choose\n' > "$home/state/t4.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t4 --resolve-key mistyped "the answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a not-open key should refuse"
  assert_contains "$(cat "$err")" "--resolve-key 'mistyped'" "the refusal should name the bad key"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal should state nothing was sent"
  [ ! -s "$log" ] || fail "a refused answer still typed text: $(cat "$log")"
  [ ! -d "$home/state/t4.inbox" ] || fail "a refused answer still enqueued an inbox record"
  if grep -F 'resolved' "$home/state/t4.status" >/dev/null; then
    fail "a refused answer still closed something: $(cat "$home/state/t4.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=real-key]' >/dev/null \
    || fail "the real decision disappeared after a refused answer: $out"
  pass "fm-send --resolve-key: a key that is not open refuses loudly before anything is sent"
}

# The close is an enqueue-time fact: the durable record IS the delivery, so a
# failed doorbell keystroke must not reopen the split-brain where the close
# waited on an unconfirmable submit.
test_failed_ring_still_closes_at_enqueue() {
  local dir fb log home rc out
  dir="$TMP_ROOT/ring-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home ring-fail)
  fm_write_meta "$home/state/t5.meta" "window=sess:fm-t5" "kind=ship"
  printf 'blocked [key=creds]: need the deploy token\n' > "$home/state/t5.status"

  : > "$log"
  env PATH="$fb:$PATH" FM_FAKE_TMUX_SEND_FAIL=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t5 --resolve-key creds "token is in the vault now" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a failed doorbell must not fail the durably enqueued answer"
  grep -qF 'token is in the vault now' "$home/state/t5.inbox/001.msg" \
    || fail "the answer must be durably recorded despite the failed ring"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t5.status" | grep -qF 'resolved [key=creds]: answered: token is in the vault now' \
    || fail "the enqueued answer must close the decision at answer time: $(cat "$home/state/t5.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F '[key=creds]' >/dev/null; then
    fail "the answered blocker still lists as open after an enqueue-time close: $out"
  fi
  pass "fm-send --resolve-key: the close happens at enqueue, surviving a failed doorbell"
}

# The real local failure - an unwritable record - is the case that must never
# close anything: nothing durable was sent.
test_failed_enqueue_does_not_close() {
  local dir fb log home rc out
  dir="$TMP_ROOT/enqueue-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home enqueue-fail)
  fm_write_meta "$home/state/t5.meta" "window=sess:fm-t5" "kind=ship"
  printf 'blocked [key=creds]: need the deploy token\n' > "$home/state/t5.status"
  : > "$home/state/t5.inbox"   # a FILE where the inbox dir must go

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t5 --resolve-key creds "token is in the vault now" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a failed enqueue should exit nonzero"
  if grep -F 'resolved' "$home/state/t5.status" >/dev/null; then
    fail "a failed enqueue still closed the decision: $(cat "$home/state/t5.status")"
  fi
  [ ! -s "$log" ] || fail "a failed enqueue still typed something: $(cat "$log")"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=creds]' >/dev/null \
    || fail "the blocker vanished after a failed enqueue: $out"
  pass "fm-send --resolve-key: a failed enqueue never closes the decision"
}

test_multiple_keys_close_together() {
  local dir fb log home rc out
  dir="$TMP_ROOT/multi"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home multi)
  fm_write_meta "$home/state/t6.meta" "window=sess:fm-t6" "kind=ship"
  {
    printf 'needs-decision [key=k1]: first\n'
    printf 'blocked [key=k2]: second\n'
    printf 'needs-decision [key=k3]: third, unanswered\n'
  } > "$home/state/t6.status"

  run_send "$fb" "$home" "$log" t6 --resolve-key k1 --resolve-key k2 \
    "one answer covering both"; rc=$?
  expect_code 0 "$rc" "an answer resolving two keys should succeed"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=k3]' >/dev/null \
    || fail "the unanswered third decision must stay open: $out"
  if printf '%s' "$out" | grep -E '\[key=k1\]|\[key=k2\]' >/dev/null; then
    fail "an answered key is still open after a multi-key answer: $out"
  fi
  pass "fm-send --resolve-key: one answer closes each named key and only those"
}

# Issue 4767: the session-start drain listed both decisions (folding them
# without a watcher seen marker), and one answer closes both. The closes are
# this home's own bookkeeping, so the watcher must not wake it to reread them.
test_multiple_keys_close_after_fold_is_self_announced() {
  local dir fb log home rc out
  dir="$TMP_ROOT/multi-fold"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home multi-fold)
  fm_write_meta "$home/state/t7.meta" "window=sess:fm-t7" "kind=ship"
  {
    printf 'needs-decision [key=budget]: approve spend?\n'
    printf 'needs-decision [key=vendor]: pick a vendor\n'
  } > "$home/state/t7.status"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=vendor]' >/dev/null \
    || fail "precondition: the drain should list both decisions: $out"

  run_send "$fb" "$home" "$log" t7 --resolve-key budget --resolve-key vendor \
    "approve spend, pick acme"; rc=$?
  expect_code 0 "$rc" "an answer resolving two folded keys should succeed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t7.status" \
    || fail "one answer's two closes after an OPEN DECISIONS drain were left to re-wake this home"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "an answered folded key is still open: $out"
  fi
  pass "fm-send --resolve-key: one answer's closes after a drain fold never wake this home"
}

test_local_secondmate_answer_marked_and_closed() {
  local dir fb log home rc got out closing
  dir="$TMP_ROOT/sm"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  printf 'needs-decision [key=fleet-split]: shard by team or by repo\n' > "$home/state/domain.status"

  run_send "$fb" "$home" "$log" fm-domain --resolve-key fleet-split "shard by team"; rc=$?
  expect_code 0 "$rc" "a secondmate answer send should succeed"
  got=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" \
    "$home/state/domain.inbox/001.msg")
  case "$got" in
    "$FM_FROMFIRST_MARK"corr=*) : ;;
    *) fail "the secondmate answer's record lost its from-firstmate marker/corr framing: $got" ;;
  esac
  closing=$(grep -F 'resolved [key=fleet-split]' "$home/state/domain.status" || true)
  [ -n "$closing" ] || fail "the secondmate decision was not closed: $(cat "$home/state/domain.status")"
  case "$closing" in
    *corr=*) fail "the closing line leaked the corr token: $closing" ;;
  esac
  case "$closing" in
    *"$FM_FROMFIRST_SEPARATOR"*) fail "the closing line leaked marker bytes" ;;
  esac
  assert_contains "$closing" "shard by team" "the closing line should carry the plain answer"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered secondmate decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a marked local-secondmate answer closes with the plain answer text"
}

# Remote secondmate: the answer crosses the (stubbed) ssh transport through the
# real fm-on.sh + registry route, while the close is the SAME local ledger
# append as every other target kind - the transport is the only difference.
setup_remote_home() {  # <name> -> echoes home dir with remote meta + registry
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

test_remote_secondmate_answer_closes_locally() {
  local dir fb log home ssh_log rc out
  dir="$TMP_ROOT/remote-ok"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-ok)
  printf 'needs-decision [key=upgrade-window]: tonight or the weekend\n' > "$home/state/rsm.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=0 \
    "$SEND" rsm --resolve-key upgrade-window "the weekend, freeze Friday" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a remote secondmate answer send should succeed"
  assert_grep 'fm-remote-entrypoint.sh' "$ssh_log" \
    "the answer message should cross the remote transport"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/rsm.status" | grep -qF 'resolved [key=upgrade-window]: answered: the weekend, freeze Friday' \
    || fail "the remote answer did not close the local ledger: $(cat "$home/state/rsm.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered remote-secondmate decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a remote-secondmate answer closes the same local ledger, transport-only difference"
}

# The reported failure: a remote secondmate reply line prepends a
# "[corr=<hex>]" correlation tag ahead of "[key=...]"
# (needs-decision [corr=d448ea86afa4bf67] [key=x]: ...). The verb parser used
# to strip only a leading "[key=...]" token, so the corr tag stayed glued onto
# the returned verb and the fold never recognized the line as a decision at
# all - "--resolve-key x" refused with "no open decision with that key" even
# though the key was right there on the line. This drives the real fm-send
# over that exact line shape and asserts the answer now succeeds and closes it.
test_remote_reply_corr_tag_does_not_block_resolve_key() {
  local dir fb log home ssh_log rc out
  dir="$TMP_ROOT/remote-corr-tag"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-corr-tag)
  printf 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: pick the cadence\n' \
    > "$home/state/rsm.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=loan-installment-cadence-amount]' >/dev/null \
    || fail "precondition: the corr-tagged remote decision should list as open under its stated key: $out"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=0 \
    "$SEND" rsm --resolve-key loan-installment-cadence-amount "monthly" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "answering a corr-tagged remote decision should succeed, not refuse as unknown"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/rsm.status" | grep -qF 'resolved [key=loan-installment-cadence-amount]: answered: monthly' \
    || fail "the closing resolved line is missing:"$'\n'"$(cat "$home/state/rsm.status")"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered corr-tagged remote decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a remote reply's leading [corr=...] tag no longer blocks closing its stated key"
}

test_remote_transport_failure_does_not_close() {
  local dir fb log home ssh_log rc out
  dir="$TMP_ROOT/remote-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-fail)
  printf 'blocked [key=quota]: remote host is out of runway\n' > "$home/state/rsm.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=1 \
    "$SEND" rsm --resolve-key quota "quota refreshed, resume" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a failed remote transport should exit nonzero"
  if grep -F 'resolved' "$home/state/rsm.status" >/dev/null; then
    fail "a failed remote send still closed the decision: $(cat "$home/state/rsm.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=quota]' >/dev/null \
    || fail "the remote blocker vanished after a failed transport: $out"
  pass "fm-send --resolve-key: a failed remote transport never closes the decision"
}

test_flag_misuse_refuses() {
  local dir fb log home err rc
  dir="$TMP_ROOT/misuse"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home misuse)
  fm_write_meta "$home/state/t7.meta" "window=sess:fm-t7" "kind=ship"
  printf 'needs-decision [key=k]: choose\n' > "$home/state/t7.status"

  # --resolve-key with --key (both orders) is refused: an answer is text.
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key k --key Enter >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key before --key should refuse"
  assert_contains "$(cat "$err")" "cannot accompany --key" "the --key refusal should be explicit"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --key Enter --resolve-key k >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key after --key should refuse instead of being silently dropped"
  assert_contains "$(cat "$err")" "cannot accompany --key" "the trailing --resolve-key refusal should be explicit"

  # An empty answer message is refused.
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key k >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an empty answer message should refuse"
  assert_contains "$(cat "$err")" "nonempty answer message" "the empty-message refusal should be explicit"

  # An explicit backend target has no task ledger in this home.
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:elsewhere --resolve-key k "answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit backend target should refuse --resolve-key"
  assert_contains "$(cat "$err")" "no decision ledger" "the explicit-target refusal should be explicit"

  # A malformed key is refused before anything else.
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key 'bad key!' "answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed key should refuse"
  assert_contains "$(cat "$err")" "not a valid decision key" "the malformed-key refusal should be explicit"

  [ ! -s "$log" ] || fail "a refused misuse still typed text: $(cat "$log")"
  if grep -F 'resolved' "$home/state/t7.status" >/dev/null; then
    fail "a refused misuse still closed something: $(cat "$home/state/t7.status")"
  fi
  pass "fm-send --resolve-key: --key, empty message, explicit targets, and malformed keys refuse loudly"
}

# The reported silent no-op: fm-send --resolve-key on a reserved pending-reply-*
# key used to write "answered: ..." and exit 0 while the classify fold left the
# decision open. The operator path must actually close it, using the owning
# library's vocabulary, without weakening the guard against an unrelated writer.
test_reserved_pending_reply_key_closes_through_resolve_key() {
  local dir fb log home rc out key corr
  dir="$TMP_ROOT/reserved-close"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home reserved-close)
  corr=abcdef0123456789
  key="pending-reply-$corr"
  fm_write_meta "$home/state/mate.meta" "window=sess:fm-mate" "kind=ship"
  printf 'blocked [key=%s]: pending-reply-missed: task=mate pending-reply-id=%s request=ship it\n' \
    "$key" "$corr" > "$home/state/mate.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F "[key=$key]" >/dev/null \
    || fail "precondition: the reserved pending-reply decision should list as open: $out"

  run_send "$fb" "$home" "$log" mate --resolve-key "$key" "ack, false escalation"; rc=$?
  expect_code 0 "$rc" "closing a reserved pending-reply key via --resolve-key should succeed"
  grep -F "pending-reply-resolved: task=mate pending-reply-id=$corr via=operator-resolve-key" \
    "$home/state/mate.status" >/dev/null \
    || fail "the operator close did not write the owning library's close note:"$'\n'"$(cat "$home/state/mate.status")"
  if grep -E "resolved \[key=$key\]( \[at=[0-9]+\])?: answered:" "$home/state/mate.status" >/dev/null; then
    fail "the operator close still wrote a bare answered: note that the fold ignores:"$'\n'"$(cat "$home/state/mate.status")"
  fi

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the reserved pending-reply decision still lists as open after --resolve-key: $out"
  fi
  pass "fm-send --resolve-key: a reserved pending-reply key actually closes through the operator path"
}

test_unrelated_writer_cannot_close_or_hijack_reserved_key() {
  local dir fb log home rc out key corr
  dir="$TMP_ROOT/reserved-guard"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home reserved-guard)
  corr=abcdef0123456789
  key="pending-reply-$corr"
  fm_write_meta "$home/state/mate.meta" "window=sess:fm-mate" "kind=ship"
  {
    printf 'blocked [key=%s]: pending-reply-missed: task=mate pending-reply-id=%s request=ship it\n' \
      "$key" "$corr"
    printf 'blocked [key=%s]: shipping is blocked on infra\n' "$key"
    printf 'resolved [key=%s]: answered: operator thought this would close it\n' "$key"
    printf 'resolved [key=%s]: all good now\n' "$key"
  } > "$home/state/mate.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F "pending-reply-id=$corr" >/dev/null \
    || fail "an unrelated answered: resolution cleared a reserved decision: $out"
  if printf '%s' "$out" | grep -F 'shipping is blocked on infra' >/dev/null; then
    fail "an unrelated writer took over a reserved decision key: $out"
  fi

  run_send "$fb" "$home" "$log" mate --resolve-key "$key" "dismiss the missed-reply hold"; rc=$?
  expect_code 0 "$rc" "the operator close should still succeed after foreign no-op lines"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the reserved key stayed open after the operator close: $out"
  fi
  pass "fm-send --resolve-key: an unrelated writer cannot close or hijack a reserved key, and the operator close still can"
}

test_unclosable_reserved_key_refuses_before_send() {
  local dir fb log home err rc out
  dir="$TMP_ROOT/reserved-refuse"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home reserved-refuse)
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'blocked [key=secret-abc]: secret-held: keep this\n' > "$home/state/t1.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_CLASSIFY_RESERVED_KEY_PREFIXES='pending-reply- secret-' \
    "$SEND" t1 --resolve-key secret-abc "this must not silently no-op" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a reserved key this send cannot close should refuse"
  assert_contains "$(cat "$err")" "--resolve-key 'secret-abc'" "the refusal should name the reserved key"
  assert_contains "$(cat "$err")" "cannot take effect" "the refusal should say the close cannot take effect"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal should state nothing was sent"
  [ ! -s "$log" ] || fail "a refused reserved-key close still typed text: $(cat "$log")"
  [ ! -d "$home/state/t1.inbox" ] || fail "a refused reserved-key close still enqueued an inbox record"
  if grep -F 'resolved' "$home/state/t1.status" >/dev/null; then
    fail "a refused reserved-key close still wrote a resolved line: $(cat "$home/state/t1.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=secret-abc]' >/dev/null \
    || fail "the reserved decision disappeared after a refused close: $out"
  pass "fm-send --resolve-key: a reserved key this send cannot close refuses loudly before anything is sent"
}

test_long_decision_key_refuses_before_send() {
  local dir fb log home err key rc out
  dir="$TMP_ROOT/long-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home long-key)
  key=$(printf 'k%.0s' {1..230})
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=%s]: choose safely\n' "$key" > "$home/state/t1.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --resolve-key "$key" "answer the long-key decision" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a key whose close prefix cannot fit should refuse before sending"
  assert_contains "$(cat "$err")" "decision key of length 230" "the refusal should report the key-length cause"
  assert_contains "$(cat "$err")" "220-character status-line cap" "the refusal should report the truncation limit"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal should state nothing was sent"
  [ ! -s "$log" ] || fail "a refused long-key close still typed text: $(cat "$log")"
  [ ! -d "$home/state/t1.inbox" ] || fail "a refused long-key close still enqueued an inbox record"
  if grep -F 'resolved' "$home/state/t1.status" >/dev/null; then
    fail "a refused long-key close still wrote a malformed resolution: $(cat "$home/state/t1.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null \
    || fail "the long-key decision disappeared after a refused close: $out"
  pass "fm-send --resolve-key: an overlong decision key refuses before sending"
}

# The cap bounds the line that is actually APPENDED. The self-announced append
# stamps each close with its emission time, so a cap measured before the stamp
# lets the stored line overrun it and every 220-capped rendering downstream
# silently loses that much real note text.
test_stamped_close_line_stays_within_the_status_line_cap() {
  local dir fb log home rc answer line
  dir="$TMP_ROOT/cap-with-stamp"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home cap-with-stamp)
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=api-shape]: REST or gRPC\n' > "$home/state/t1.status"
  answer=$(printf 'x%.0s' {1..400})

  run_send "$fb" "$home" "$log" t1 --resolve-key api-shape "$answer"; rc=$?
  expect_code 0 "$rc" "answering with an over-long note should succeed, not refuse"
  line=$(grep -F 'resolved [key=api-shape]' "$home/state/t1.status") \
    || fail "the closing resolved line is missing:"$'\n'"$(cat "$home/state/t1.status")"
  case "$line" in
    *' [at='*']: '*) : ;;
    *) fail "the appended close carries no emission stamp: $line" ;;
  esac
  [ "${#line}" -le 220 ] \
    || fail "the appended close is ${#line} characters, past the 220-character cap: $line"
  pass "fm-send --resolve-key: a stamped close line stays inside the status-line cap"
}

test_failed_close_recovery_command_is_shell_safe() {
  local dir fb log home err marker answer rc diagnostic manual out
  dir="$TMP_ROOT/manual-close"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home "manual close")
  marker="$dir/injected"
  answer="ok'; touch $marker; echo '"
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=quote-safety]: choose safely\n' > "$home/state/t1.status"
  chmod 0400 "$home/state/t1.status"

  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --resolve-key quote-safety "$answer" >/dev/null 2>"$err"; rc=$?
  chmod 0600 "$home/state/t1.status"
  [ "$rc" -ne 0 ] || fail "a delivered answer with a failed close append should fail loudly"
  diagnostic=$(cat "$err")
  assert_contains "$diagnostic" "Close it manually with:" "the close failure should provide recovery guidance"
  manual=${diagnostic#*Close it manually with: }
  manual=${manual% - do not resend the answer.}
  bash -c "$manual" || fail "the generated manual close command should execute successfully"
  [ ! -e "$marker" ] || fail "the generated manual close command executed answer text as shell code"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the generated manual close command did not close the decision: $out"
  fi
  pass "fm-send --resolve-key: failed-close recovery commands safely quote operator text and paths"
}

test_remote_reserved_pending_reply_key_closes_locally() {
  local dir fb log home ssh_log rc out key corr
  dir="$TMP_ROOT/remote-reserved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-reserved)
  corr=d448ea86afa4bf67
  key="pending-reply-$corr"
  printf 'blocked [key=%s]: pending-reply-missed: task=rsm pending-reply-id=%s request=ship it\n' \
    "$key" "$corr" > "$home/state/rsm.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=0 \
    "$SEND" rsm --resolve-key "$key" "ack the missed-reply hold" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a remote reserved-key --resolve-key should succeed"
  grep -F "pending-reply-resolved: task=rsm pending-reply-id=$corr via=operator-resolve-key" \
    "$home/state/rsm.status" >/dev/null \
    || fail "the remote operator close did not write the owning library's close note: $(cat "$home/state/rsm.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the remote reserved pending-reply decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a remote secondmate reserved-key close is the same local ledger append"
}

# The decision-answer partition (bin/fm-send.sh header "Answering a decision"):
# a --resolve-key naming an open needs-decision or a captain-held task is a
# decision answer, main-owned while attended and refused for the supervision
# branch before anything is sent; a blocked: key is ordinary steering for
# either actor; and while the away-posture record exists the same branch
# answer is sent and closes the key, because main is parked. Main itself never
# meets the partition.
test_decision_answer_partition_relocates_under_the_record() {
  local dir fb log home rc out
  dir="$TMP_ROOT/partition"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home partition)
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/t1.status"
  printf 'blocked [key=token]: firstmate can refresh the token\n' >> "$home/state/t1.status"

  # Attended branch: the decision is refused at the partition, nothing sent.
  : > "$log"
  out=$(env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SUPERVISION_ACTOR=branch "$SEND" t1 --resolve-key api-shape "go with REST" 2>&1); rc=$?
  expect_code 6 "$rc" "an attended branch answering a decision must be refused at the partition"
  assert_contains "$out" "decision answer (fm-send --resolve-key) refused" "the partition refusal lost its action label"
  [ ! -e "$home/state/t1.inbox" ] || fail "a refused decision answer still reached the worker's inbox"
  [ ! -s "$log" ] || fail "a refused decision answer still rang the doorbell"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the refused answer closed the decision anyway: $out"

  # Attended branch: a blocked: key is steering, sent and closed under the
  # ordinary lease guard alone.
  FM_SUPERVISION_ACTOR=branch run_send "$fb" "$home" "$log" t1 --resolve-key token "refreshed the token; resume"; rc=$?
  expect_code 0 "$rc" "an attended branch resolving a blocker is ordinary steering"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t1.status" | grep -qF 'resolved [key=token]: answered: refreshed the token; resume' \
    || fail "the branch's blocker answer did not close the key:"$'\n'"$(cat "$home/state/t1.status")"
  grep -qF "refreshed the token; resume" "$home/state/t1.inbox/001.msg" \
    || fail "the branch's blocker answer did not reach the worker's inbox"

  # Under the record: the same decision answer is sent and closes the key.
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null || fail "away entry failed"
  out=$(env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SUPERVISION_ACTOR=branch "$SEND" t1 --resolve-key api-shape "go with REST" 2>&1); rc=$?
  expect_code 0 "$rc" "under the away-posture record the branch's decision answer must be sent: $out"
  assert_contains "$out" "main is parked" "the relocation did not announce itself"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t1.status" | grep -qF 'resolved [key=api-shape]: answered: go with REST' \
    || fail "the relocated answer did not close the decision:"$'\n'"$(cat "$home/state/t1.status")"
  grep -qF "go with REST" "$home/state/t1.inbox/002.msg" \
    || fail "the relocated answer did not reach the worker's inbox"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F '[key=api-shape]' >/dev/null; then
    fail "the relocated answer left the decision open: $out"
  fi

  # Main never meets the partition, attended or not.
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null || fail "away archive failed"
  printf 'needs-decision [key=db]: postgres or sqlite\n' >> "$home/state/t1.status"
  run_send "$fb" "$home" "$log" t1 --resolve-key db "postgres"; rc=$?
  expect_code 0 "$rc" "main answering a decision attended is unaffected by the partition"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t1.status" | grep -qF 'resolved [key=db]: answered: postgres' \
    || fail "main's attended decision answer did not close the key"
  pass "fm-send --resolve-key: a decision answer refuses the attended branch before sending, a blocked: key stays steering, and the away-posture record relocates the answer"
}

test_captain_decision_flag_absent_preserves_send_behavior
test_captain_decision_flag_requires_recorded_answer
test_captain_decision_flag_accepts_recorded_answer
test_mapped_explicit_endpoint_can_resolve_decision
test_captain_answer_scope_is_this_home
test_resolved_hold_answer_intake_uses_canonical_data
test_remote_captain_decision_guard_runs_before_transport
test_decision_declaration_is_structural_and_logged
test_invalid_status_source_refuses_policy_and_key_resolution
test_typed_no_decision_declaration_append_failure_prevents_delivery
test_inbox_no_decision_declaration_precedes_later_close_failure
test_no_decision_declaration_append_failure_prevents_delivery
test_no_decision_declaration_precedes_later_close_failure
test_no_decision_cannot_resolve_a_needs_decision
test_multiple_needs_decisions_require_distinct_recorded_answers
test_transferred_held_decision_requires_its_recorded_answer
test_closed_unanswered_transferred_hold_still_gates_steers
test_missing_and_unreadable_inventory_holds_block_plain_steers
test_uninventoried_answered_hold_cannot_be_relayed
test_self_resolved_decision_still_gates_steers
test_answered_key_note_does_not_settle_decision
test_blocked_key_retains_decision_answer_requirement
test_old_key_answer_cannot_override_origin_hold
test_double_relay_is_refused
test_answered_secondmate_decision_does_not_block
test_terminal_status_does_not_settle_decisions
test_partial_inventory_transfer_still_gates_omitted_key
test_captain_answer_uses_authoritative_hold_identity
test_migrated_beads_hold_is_gated_and_uses_canonical_id
test_legacy_declined_answer_can_be_relayed
test_answer_send_closes_open_decision
test_answer_close_is_self_announced
test_separate_resolve_key_answers_do_not_rewake
test_colon_first_key_position_is_answerable
test_answer_starts_work_never_orphans
test_routine_steer_never_closes
test_not_open_key_refuses_before_send
test_failed_ring_still_closes_at_enqueue
test_failed_enqueue_does_not_close
test_multiple_keys_close_together
test_multiple_keys_close_after_fold_is_self_announced
test_local_secondmate_answer_marked_and_closed
test_remote_secondmate_answer_closes_locally
test_remote_reply_corr_tag_does_not_block_resolve_key
test_remote_transport_failure_does_not_close
test_flag_misuse_refuses
test_reserved_pending_reply_key_closes_through_resolve_key
test_unrelated_writer_cannot_close_or_hijack_reserved_key
test_unclosable_reserved_key_refuses_before_send
test_long_decision_key_refuses_before_send
test_stamped_close_line_stays_within_the_status_line_cap
test_failed_close_recovery_command_is_shell_safe
test_remote_reserved_pending_reply_key_closes_locally
test_decision_answer_partition_relocates_under_the_record
