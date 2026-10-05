#!/usr/bin/env bash
# A captain answer must become a durable record in the turn it arrives.
#
# bin/fm-send.sh closes a needs-decision only when the steer names the key with
# --resolve-key. A steer that leaves an open needs-decision behind may have been
# the captain's answer, and the next turn then asks the captain again. These
# tests drive the real fm-send and the real wake drain and assert on what the
# drain prints, never on source text:
#   1. A steer without --resolve-key or --keep-open still delivers, warns with an
#      `actionable:` line, and the drain prints UNCLOSED RELAYS for the key.
#   2. --resolve-key leaves no ledger entry and no section.
#   3. --keep-open leaves no ledger entry, no warning, and the decision stays open.
#   4. Answering the decision later closes it and clears the section.
#   5. A blocked: key is ordinary steering and is never listed.
#   6. A decision the worker reopens after the relay is a new question and is not
#      listed against the old steer.
#   7. A captured process-event result nobody acknowledged prints under
#      UNHANDLED CAPTURES once it is old enough, and clears when acknowledged.
#   8. An invalid --keep-open key refuses before anything is sent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-unclosed-relay)

make_stubs() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-t1 fm-t2 fm-t3 fm-t4; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes a fresh home dir with an empty state/
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

send_capture() {  # <fakebin> <home> <stderr-file> <fm-send args...>; returns fm-send's exit
  local fb=$1 home=$2 err=$3; shift 3
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_SEND_LOG=/dev/null FM_SEND_SETTLE=0 "$SEND" "$@" 2>"$err"
}

drain_out() {  # <home>
  FM_STATE_OVERRIDE="$1/state" FM_HOME="$1" "$DRAIN" 2>/dev/null
}

new_task() {  # <home> <id> <status-lines...>
  local home=$1 id=$2; shift 2
  fm_write_meta "$home/state/$id.meta" "window=sess:fm-$id" "kind=ship"
  : > "$home/state/$id.status"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$home/state/$id.status"; done
}

test_unanswered_steer_is_listed() {
  local dir fb home err out rc
  dir="$TMP_ROOT/listed"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home listed); err="$dir/err"
  new_task "$home" t1 'needs-decision [key=api-shape]: pick REST or RPC'

  send_capture "$fb" "$home" "$err" t1 "go with REST"; rc=$?
  expect_code 0 "$rc" "a steer that leaves a decision open must still be delivered"
  grep -qF "go with REST" "$home/state/t1.inbox/001.msg" || fail "the steer did not reach the inbox"
  assert_contains "$(cat "$err")" "actionable: this steer did not close the open decision(s) 'api-shape'" \
    "the sender was not told the decision stayed open"

  out=$(drain_out "$home")
  assert_contains "$out" "UNCLOSED RELAYS" "the drain did not surface the unclosed relay"
  assert_contains "$out" "t1 [key=api-shape] was steered 1 time(s)" "the drain line misses task, key, or count"
  pass "a steer that leaves a needs-decision open warns the sender and prints UNCLOSED RELAYS"
}

test_resolve_key_leaves_no_entry() {
  local dir fb home err out rc
  dir="$TMP_ROOT/resolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home resolved); err="$dir/err"
  new_task "$home" t2 'needs-decision [key=api-shape]: pick REST or RPC'

  send_capture "$fb" "$home" "$err" t2 --resolve-key api-shape "go with REST"; rc=$?
  expect_code 0 "$rc" "the answer send should succeed"
  [ ! -e "$home/state/t2.unclosed-relay" ] || fail "an answered decision left a ledger entry"
  assert_not_contains "$(cat "$err")" "actionable:" "an answer send must not warn"
  out=$(drain_out "$home")
  assert_not_contains "$out" "UNCLOSED RELAYS" "an answered decision printed UNCLOSED RELAYS"
  pass "--resolve-key records the answer and leaves nothing unclosed"
}

test_keep_open_leaves_no_entry() {
  local dir fb home err out rc
  dir="$TMP_ROOT/keep-open"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home keep-open); err="$dir/err"
  new_task "$home" t3 'needs-decision [key=api-shape]: pick REST or RPC'

  send_capture "$fb" "$home" "$err" t3 --keep-open api-shape "unrelated: rebase first"; rc=$?
  expect_code 0 "$rc" "a deliberate non-answer steer should succeed"
  [ ! -e "$home/state/t3.unclosed-relay" ] || fail "--keep-open still wrote a ledger entry"
  assert_not_contains "$(cat "$err")" "actionable:" "--keep-open must not warn"
  out=$(drain_out "$home")
  assert_not_contains "$out" "UNCLOSED RELAYS" "--keep-open printed UNCLOSED RELAYS"
  assert_contains "$out" "OPEN DECISIONS" "--keep-open must leave the decision open"
  pass "--keep-open sends a non-answer steer without a false alarm"
}

test_later_answer_clears_section() {
  local dir fb home err out
  dir="$TMP_ROOT/cleared"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home cleared); err="$dir/err"
  new_task "$home" t4 'needs-decision [key=api-shape]: pick REST or RPC'

  send_capture "$fb" "$home" "$err" t4 "go with REST" || fail "first steer failed"
  out=$(drain_out "$home")
  assert_contains "$out" "UNCLOSED RELAYS" "precondition: the relay should list before the close"
  send_capture "$fb" "$home" "$err" t4 --resolve-key api-shape "recorded: REST" || fail "the closing send failed"
  out=$(drain_out "$home")
  assert_not_contains "$out" "UNCLOSED RELAYS" "a closed decision still printed UNCLOSED RELAYS"
  pass "closing the decision retires its unclosed relay"
}

test_blocked_key_is_ordinary_steering() {
  local dir fb home err out
  dir="$TMP_ROOT/blocked"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home blocked); err="$dir/err"
  new_task "$home" t1 'blocked [key=ci-red]: CI is red'

  send_capture "$fb" "$home" "$err" t1 "retry CI" || fail "steer failed"
  [ ! -e "$home/state/t1.unclosed-relay" ] || fail "a blocked: key wrote a ledger entry"
  out=$(drain_out "$home")
  assert_not_contains "$out" "UNCLOSED RELAYS" "a blocked: key printed UNCLOSED RELAYS"
  pass "a blocked: key stays ordinary steering"
}

test_reopened_decision_is_a_new_question() {
  local dir fb home err out later
  dir="$TMP_ROOT/reopened"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home reopened); err="$dir/err"
  new_task "$home" t2 'needs-decision [key=api-shape] [at=1000]: pick REST or RPC'

  send_capture "$fb" "$home" "$err" t2 "go with REST" || fail "steer failed"
  out=$(drain_out "$home")
  assert_contains "$out" "UNCLOSED RELAYS" "precondition: the relay should list"
  later=$(( $(date +%s) + 1000 ))
  printf 'resolved [key=api-shape] [at=%s]: answered elsewhere\n' "$((later - 10))" >> "$home/state/t2.status"
  printf 'needs-decision [key=api-shape] [at=%s]: pick REST or RPC again\n' "$later" >> "$home/state/t2.status"
  out=$(drain_out "$home")
  assert_contains "$out" "OPEN DECISIONS" "precondition: the reopened decision should be open"
  assert_not_contains "$out" "UNCLOSED RELAYS" "a reopened decision was blamed on the older steer"
  pass "a decision reopened after the relay is not listed against the old steer"
}

test_unacknowledged_capture_is_listed() {
  local dir home inbox out
  dir="$TMP_ROOT/captures"; mkdir -p "$dir"
  home=$(setup_home captures)
  inbox="$home/state/procevent-inbox"
  mkdir -p "$inbox"
  chmod 700 "$inbox"
  printf 'feedback\n' > "$inbox/board.1.result"
  printf 'lavish\n' > "$inbox/board.1.adapter"
  touch -d '2 hours ago' "$inbox/board.1.result"
  printf 'feedback\n' > "$inbox/fresh.1.result"
  printf 'lavish\n' > "$inbox/fresh.1.adapter"

  out=$(drain_out "$home")
  assert_contains "$out" "UNHANDLED CAPTURES" "an old unacknowledged capture was not surfaced"
  assert_contains "$out" "board sequence 1 (lavish) captured 120 min ago" "the capture line misses source, sequence, or age"
  assert_contains "$out" "bin/fm-procevent.sh handled board 1" "the capture line misses the acknowledging command"
  assert_not_contains "$out" "fresh sequence" "a capture younger than the threshold must not be listed"

  : > "$inbox/board.1.handled"
  out=$(drain_out "$home")
  assert_not_contains "$out" "board sequence 1" "an acknowledged capture was still listed"
  pass "an old unacknowledged process-event capture prints under UNHANDLED CAPTURES until handled"
}

test_invalid_keep_open_refuses() {
  local dir fb home err rc
  dir="$TMP_ROOT/invalid"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home invalid); err="$dir/err"
  new_task "$home" t1 'needs-decision [key=api-shape]: pick'

  send_capture "$fb" "$home" "$err" t1 --keep-open 'bad key!' "text"; rc=$?
  expect_code 1 "$rc" "an invalid --keep-open key must refuse"
  [ ! -e "$home/state/t1.inbox/001.msg" ] || fail "a refused send still wrote an inbox record"
  pass "an invalid --keep-open key refuses before anything is sent"
}

test_unanswered_steer_is_listed
test_resolve_key_leaves_no_entry
test_keep_open_leaves_no_entry
test_later_answer_clears_section
test_blocked_key_is_ordinary_steering
test_reopened_decision_is_a_new_question
test_unacknowledged_capture_is_listed
test_invalid_keep_open_refuses
