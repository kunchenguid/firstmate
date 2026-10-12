#!/usr/bin/env bash
# tests/fm-send-inbox.test.sh - fm-send's inbox data plane.
#
# An ordinary text steer to a task recorded in this home no longer types its
# payload: fm-send appends a durable sequenced record to state/<id>.inbox/ and
# rings one constant self-describing doorbell line, best-effort. These tests
# drive the real fm-send executable over a stubbed tmux and pin:
#   1. The payload is durably recorded and never typed; only the doorbell
#      crosses the terminal, and the send exits 0 at enqueue.
#      The doorbell names the inbox once and never grows with the home's depth.
#   2. Multi-line steers are legal and round-trip byte-exact.
#   3. A re-send enqueues a NEW sequence and still never retypes a payload,
#      so the terminal can never truncate, garble, or duplicate a steer.
#   4. A composer holding pending text no longer blocks every wake: the send
#      recovers the skip itself (submitting contentful text, clearing
#      contentless junk) and the doorbell then rings with no skip reported.
#      A recovery the backend refuses instead emits the loud, countable
#      `fm-send: doorbell-skip` line and exit 4 - distinct from the silent
#      success and from every other doorbell notice - which advances the
#      per-task consecutive-skip counter. FM_SEND_SKIP_PAGE_MAX (default 3)
#      consecutive skips queue exactly one check wake, an explicitly empty or
#      zero threshold disables paging entirely, and any later ring that
#      is attempted resets the streak.
#   5. A failed doorbell is still a sent steer (exit 0, record durable): the
#      watcher's re-ring ladder owns delivery from the record on. A
#      fire-and-forget record whose ring did not land is owed one retry ring.
#   6. Carve-outs keep the typed plane: a leading "/" (any harness), a leading
#      "$" to codex, an explicit backend target, and the --key path.
#   7. A marked secondmate steer carries its marker + corr token in the record
#      body, and the pending-reply expectation is marked delivered at enqueue.
#   8. Pending-reply bookkeeping failure after enqueue never reports a
#      retryable send failure that could duplicate the durable instruction.
#   9. An unwritable inbox is a real local failure: nonzero exit, nothing
#      typed, and a just-created pending-reply expectation is discarded.
#  10. An empty or whitespace-only text steer is refused before anything is
#      marked, recorded, or typed - on the marked secondmate path that means
#      no marker-only record and no pending-reply expectation.
# Every case below that passes a literal `$...` message quotes it on purpose
# (the point is sending an unexpanded `$` line), so SC2016 is disabled.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-inbox)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub tmux: logs literal typed text to FM_SEND_LOG and lets the submit and
# composer paths reach clean verdicts. Env knobs:
#   FM_FAKE_TMUX_SEND_FAIL=1    every send-keys fails
#   FM_FAKE_TMUX_COMPOSER=pending  a statically pending composer that no key
#                              clears: the clear-or-submit recovery is impossible
#   FM_FAKE_TMUX_HELD_FILE=f    a live held composer: while f holds bytes the
#                              composer renders them as pending, Enter submits
#                              them (logged as `SUBMIT: <text>`) and clears f,
#                              and C-u clears f - unless FM_FAKE_TMUX_KEY_FAIL
#                              names that key, which is refused with exit 1
#                              (the invalid_key class)
make_stubs() { # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/tmux" <<'SH'
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
      printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
      exit 0
    fi
    key=${1:-}
    if [ "${FM_FAKE_TMUX_KEY_FAIL:-}" = "$key" ]; then exit 1; fi
    if [ -n "${FM_FAKE_TMUX_HELD_FILE:-}" ] && [ -s "$FM_FAKE_TMUX_HELD_FILE" ]; then
      case "$key" in
        Enter)
          printf 'SUBMIT: %s\n' "$(cat "$FM_FAKE_TMUX_HELD_FILE")" >> "$FM_SEND_LOG"
          : > "$FM_FAKE_TMUX_HELD_FILE"
          ;;
        C-u)
          printf 'CLEAR: %s\n' "$(cat "$FM_FAKE_TMUX_HELD_FILE")" >> "$FM_SEND_LOG"
          : > "$FM_FAKE_TMUX_HELD_FILE"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    # A bounded-window miss (FM_FAKE_TMUX_BOUNDED_MISS) renders an overlay that
    # owns the bottom rows for the inbox composer read's -S -20 capture, so the
    # held composer above it is visible only to the state and viewport reads.
    case "$*" in
    *'-S -20'*)
      if [ "${FM_FAKE_TMUX_BOUNDED_MISS:-0}" = 1 ]; then
        printf 'overlay palette rows\n(1) /clear\n(2) /compact\n'
        exit 0
      fi
      ;;
    esac
    if [ -n "${FM_FAKE_TMUX_HELD_FILE:-}" ] && [ -s "$FM_FAKE_TMUX_HELD_FILE" ]; then
      held=$(cat "$FM_FAKE_TMUX_HELD_FILE")
      # Build the border with a literal UTF-8 repeat: tr truncates multibyte
      # set members to their first byte, and a mangled border classifies as
      # pending-unproven instead of the pending verdict under test.
      border=
      width=$(( ${#held} + 2 ))
      while [ "$width" -gt 0 ]; do border="$border─"; width=$((width - 1)); done
      printf '╭%s╮\n│ %s │\n╰%s╯\n' "$border" "$held" "$border"
    elif [ "${FM_FAKE_TMUX_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat >"$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_case() { # <name> [harness] -> echoes case dir with home/state + t1 meta
  local name=$1 harness=${2:-claude} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=$harness"
  printf '%s\n' "$dir"
}

run_send() { # <case-dir> <err-file> [env...] -- <fm-send args...>
  local dir=$1 err=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  : >"$dir/send.log"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    FM_SEND_SETTLE=0 ${envs[@]+"${envs[@]}"} \
    "$SEND" "$@" >/dev/null 2>"$err"
}

record_body() { # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$2"
}

test_text_steer_rides_inbox() {
  local dir err rc rec body typed
  dir=$(setup_case rides)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "please rebase onto main"
  rc=$?
  expect_code 0 "$rc" "an inbox-plane steer should exit 0 at enqueue"
  rec="$dir/home/state/t1.inbox/001.msg"
  [ -f "$rec" ] || fail "the steer was not durably recorded at $rec"
  body=$(record_body _ "$rec")
  [ "$body" = "please rebase onto main" ] || fail "the recorded body differs: $body"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "Firstmate instruction waiting: list \"\$FM_TASK_INBOX\"/*.msg in your 't1.inbox' steering inbox" \
    "the doorbell should direct the worker to drain the inbox"
  assert_not_contains "$(cat "$err")" "doorbell" \
    "a landed doorbell reports no notice at all - the success output stays byte-unchanged"
  case "$typed" in
  *"please rebase onto main"*) fail "the payload must never be typed:"$'\n'"$typed" ;;
  esac
  pass "fm-send inbox: the payload is recorded durably and only the doorbell is typed"
}

# A home nested deep must not lengthen the doorbell: a long line wraps past
# what a composer read can prove, so a Herdr submit reports it never reached
# the pane and every re-ring fails the same way.
test_deep_home_doorbell_stays_short() {
  local shallow deep home err rest typed shallow_typed found
  shallow=$(setup_case shallow-home)
  run_send "$shallow" "$shallow/send.err" -- t1 "please continue" || fail "the shallow-home send failed"
  shallow_typed=$(cat "$shallow/send.log")
  deep="$TMP_ROOT/deep-home"
  home="$deep/one/two/three/four/five/six/seven/eight-secondmate-homes-nest-under-long-worktree-paths"
  mkdir -p "$home/state"
  make_stubs "$deep" >/dev/null
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  err="$deep/send.err"
  env PATH="$deep/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$deep/send.log" \
    FM_SEND_SETTLE=0 "$SEND" t1 "please continue" >/dev/null 2>"$err" ||
    fail "the deep-home send failed: $(cat "$err")"
  [ -f "$home/state/t1.inbox/001.msg" ] || fail "the deep-home steer was not durably recorded"
  typed=$(cat "$deep/send.log")
  [ "$typed" = "$shallow_typed" ] ||
    fail "the doorbell should not depend on the home's depth:"$'\n'"shallow: $shallow_typed"$'\n'"deep:    $typed"
  [ "${#typed}" -le 200 ] || fail "the doorbell should stay under 200 characters, got ${#typed}: $typed"
  case "$typed" in
  *"$deep"* | *"$TMP_ROOT"*) fail "the doorbell should not carry the home's absolute path: $typed" ;;
  esac
  rest=${typed#*t1.inbox}
  [ "$rest" != "$typed" ] || fail "the doorbell should name the inbox: $typed"
  case "$rest" in
  *t1.inbox*) fail "the doorbell should name the inbox once: $typed" ;;
  esac
  found=$(cd / && FM_TASK_INBOX="$home/state/t1.inbox" bash -c 'ls "$FM_TASK_INBOX"/*.msg') ||
    fail "a shell with FM_TASK_INBOX exported could not list the deep inbox"
  [ "$found" = "$home/state/t1.inbox/001.msg" ] ||
    fail "the doorbell's list instruction did not resolve the deep inbox from an unrelated cwd: $found"
  (cd / && FM_TASK_INBOX="$home/state/t1.inbox" bash -c 'mv "$FM_TASK_INBOX"/001.msg "$FM_TASK_INBOX"/handled/') ||
    fail "the doorbell's mv instruction did not acknowledge through FM_TASK_INBOX"
  [ -f "$home/state/t1.inbox/handled/001.msg" ] || fail "the acknowledged record did not land in handled/"
  pass "fm-send inbox: a deep home rings the same short doorbell naming the inbox once"
}

test_multiline_steer_is_legal() {
  local dir err rc body
  dir=$(setup_case multiline)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 $'first line\nsecond line\nthird: with punctuation'
  rc=$?
  expect_code 0 "$rc" "a multi-line steer should succeed"
  body=$(record_body _ "$dir/home/state/t1.inbox/001.msg")
  [ "$body" = $'first line\nsecond line\nthird: with punctuation' ] ||
    fail "the multi-line body did not round-trip:"$'\n'"$body"
  case "$(cat "$dir/send.log")" in
  *"second line"*) fail "a payload line leaked onto the typed channel" ;;
  esac
  pass "fm-send inbox: newlines are legal and the terminal can no longer truncate a steer"
}

test_resend_enqueues_new_sequence() {
  local dir err doorbells typed
  dir=$(setup_case resend)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "first send failed"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "second send failed"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] && [ -f "$dir/home/state/t1.inbox/002.msg" ] ||
    fail "a re-send should enqueue a new sequence:"$'\n'"$(ls "$dir/home/state/t1.inbox")"
  doorbells=$(grep -cF 'Firstmate instruction waiting' "$dir/send.log" || true)
  [ "$doorbells" = 1 ] || fail "each send rings once (the log is truncated per send), got $doorbells"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "numeric order" \
    "a newer record's doorbell should preserve inbox sequence ordering"
  case "$typed" in
  *"check the CI result"*) fail "a re-send typed the payload" ;;
  esac
  pass "fm-send inbox: a re-send is a new durable record, never a retyped payload"
}

# The composer-hold fix, part 1: the SEND recovers the skip instead of
# leaving the held line to block every later wake. Contentless junk is dropped
# with Ctrl-U as part of this send, so the doorbell that follows lands.
test_composer_junk_is_cleared_and_the_doorbell_rings() {
  local dir err rc held typed
  dir=$(setup_case junkclear)
  err="$dir/send.err"
  held="$dir/held.txt"
  printf '%s' '...' > "$held"
  run_send "$dir" "$err" FM_FAKE_TMUX_HELD_FILE="$held" -- t1 "steer past held junk"
  rc=$?
  expect_code 0 "$rc" "a recovered composer still lands the doorbell"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  [ ! -s "$held" ] || fail "the contentless held line should be gone"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "Firstmate instruction waiting" \
    "the doorbell should ring once the held junk is cleared"
  assert_contains "$typed" "CLEAR:" \
    "the contentless held line should be dropped with Ctrl-U"
  assert_not_contains "$typed" "SUBMIT:" \
    "contentless junk must be dropped, never submitted"
  assert_not_contains "$(cat "$err")" "doorbell-skip" \
    "a recovered ring must not report a skip"
  [ ! -e "$dir/home/state/t1.doorbell-skip" ] || fail "a recovered ring must not count a skip"
  pass "fm-send inbox: contentless composer junk is cleared as part of the send and the doorbell rings"
}

# Part 1, second half: contentful held text is SUBMITTED as part of the send -
# it may be a steer whose Enter never landed, and only submitting both preserves
# it and wakes the endpoint - and the doorbell rings behind it.
test_composer_stale_text_is_submitted_and_the_doorbell_rings() {
  local dir err rc held typed
  dir=$(setup_case stalesubmit)
  err="$dir/send.err"
  held="$dir/held.txt"
  printf '%s' "working: a stale line from an earlier send" > "$held"
  run_send "$dir" "$err" FM_FAKE_TMUX_HELD_FILE="$held" -- t1 "steer behind a stale line"
  rc=$?
  expect_code 0 "$rc" "a submitted stale line still lands the doorbell"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  [ ! -s "$held" ] || fail "the submitted line should be gone from the composer"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "SUBMIT: working: a stale line from an earlier send" \
    "the held line should be submitted, never destroyed"
  assert_contains "$typed" "Firstmate instruction waiting" \
    "the doorbell should ring after the submit"
  assert_not_contains "$(cat "$err")" "doorbell-skip" \
    "a recovered ring must not report a skip"
  [ ! -e "$dir/home/state/t1.doorbell-skip" ] || fail "a recovered ring must not count a skip"
  pass "fm-send inbox: contentful composer text is submitted as part of the send and the doorbell rings"
}

# Parts 2 and 3: when the recovery cannot run - no key clears the composer, or
# the backend refuses the clear key outright (the invalid_key class) - the skip
# is loud and countable: its own line, its own exit code, one counter tick, and
# no page yet. The exit and the line are pinned against the success output and
# against the two other doorbell notices.
test_composer_recovery_failure_is_a_loud_countable_skip() {
  local dir err rc held wakes
  dir=$(setup_case loudskip)
  err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- t1 "steer into a wedged composer"
  rc=$?
  expect_code 4 "$rc" "an impossible recovery is the distinct skip exit, never success"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  [ ! -s "$dir/send.log" ] || \
    fail "no doorbell may be typed when the recovery fails:"$'\n'"$(cat "$dir/send.log")"
  assert_contains "$(cat "$err")" "fm-send: doorbell-skip" \
    "the skip needs its own countable line"
  assert_contains "$(cat "$err")" "clear-or-submit failed" \
    "the skip line should name the failed recovery"
  assert_contains "$(cat "$err")" "do not resend" \
    "exit 4 must say the durable record already exists"
  assert_contains "$(cat "$err")" "consecutive composer-held skips for t1: 1" \
    "the skip should report its streak count"
  assert_not_contains "$(cat "$err")" "doorbell did not reach" \
    "the composer skip must be distinct from a failed doorbell"
  assert_not_contains "$(cat "$err")" "doorbell not typed because" \
    "the composer skip must be distinct from a dead pane"
  [ "$(cat "$dir/home/state/t1.doorbell-skip" 2>/dev/null)" = 1 ] || \
    fail "one blocked send should count one consecutive skip"
  [ ! -e "$dir/home/state/t1.doorbell-skip.paged" ] || fail "a single skip must not page"
  wakes=$(grep -c 't1.doorbell-skip' "$dir/home/state/.wake-queue" 2>/dev/null || true)
  [ "${wakes:-0}" = 0 ] || fail "a single skip must not queue a page, got ${wakes:-0}"

  # The shape agt-8 hit: the backend refuses the clear key itself.
  dir=$(setup_case refusedclear)
  err="$dir/send.err"
  held="$dir/held.txt"
  printf '%s' '!!!' > "$held"
  run_send "$dir" "$err" FM_FAKE_TMUX_HELD_FILE="$held" FM_FAKE_TMUX_KEY_FAIL=C-u \
    -- t1 "steer past a refused clear"
  rc=$?
  expect_code 4 "$rc" "a refused clear key is the loud skip, not a silent one"
  assert_contains "$(cat "$err")" "fm-send: doorbell-skip" \
    "a refused clear must still emit the countable skip line"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the refused-clear steer was not recorded"
  [ "$(cat "$dir/home/state/t1.doorbell-skip" 2>/dev/null)" = 1 ] || \
    fail "a refused clear should count one consecutive skip"
  pass "fm-send inbox: an impossible composer recovery is a loud, countable skip distinct from success"
}

# Part 3: the consecutive-skip counter pages once at the threshold, never
# twice in one streak, and any later ring that was attempted resets it.
test_consecutive_composer_skips_page_once_and_reset() {
  local dir err n rc wakes
  dir=$(setup_case skippage)
  err="$dir/send.err"
  for n in 1 2 3; do
    run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- t1 "steer $n"
    rc=$?
    [ "$rc" -eq 4 ] || fail "skip $n should exit with the countable skip code, got $rc"
  done
  [ "$(cat "$dir/home/state/t1.doorbell-skip" 2>/dev/null)" = 3 ] || \
    fail "three blocked sends should count three, got $(cat "$dir/home/state/t1.doorbell-skip" 2>/dev/null)"
  [ -e "$dir/home/state/t1.doorbell-skip.paged" ] || \
    fail "the third consecutive skip should arm the page marker"
  wakes=$(grep -c 't1.doorbell-skip' "$dir/home/state/.wake-queue" 2>/dev/null || true)
  [ "${wakes:-0}" = 1 ] || fail "N consecutive skips should queue exactly one page, got ${wakes:-0}"
  assert_contains "$(cat "$err")" "paged the supervisor at 3 consecutive skips" \
    "the page should be named in the skip that queued it"

  # A fourth skip counts but never pages twice in one streak.
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- t1 "steer 4"
  rc=$?
  [ "$rc" -eq 4 ] || fail "the fourth blocked send should still exit with the skip code, got $rc"
  [ "$(cat "$dir/home/state/t1.doorbell-skip" 2>/dev/null)" = 4 ] || \
    fail "the streak should keep counting"
  wakes=$(grep -c 't1.doorbell-skip' "$dir/home/state/.wake-queue" 2>/dev/null || true)
  [ "${wakes:-0}" = 1 ] || fail "one streak must page exactly once, got ${wakes:-0} page(s)"
  assert_not_contains "$(cat "$err")" "paged the supervisor" \
    "a streak must not page twice"

  # Any ring that is attempted ends the streak, so later history cannot page.
  run_send "$dir" "$err" -- t1 "steer with a healthy composer"
  rc=$?
  [ "$rc" -eq 0 ] || fail "a healthy composer should land the doorbell with exit 0, got $rc"
  [ ! -e "$dir/home/state/t1.doorbell-skip" ] || fail "a landed ring must clear the skip counter"
  [ ! -e "$dir/home/state/t1.doorbell-skip.paged" ] || fail "a landed ring must clear the page marker"
  assert_not_contains "$(cat "$err")" "doorbell-skip" \
    "the healthy send must report no skip at all"
  pass "fm-send inbox: N consecutive skips page once, and a landed ring resets the streak"
}

# The threshold is FM_SEND_SKIP_PAGE_MAX, the same tunable shape as the other
# rails: a caller can page sooner or later without touching the code.
test_skip_page_threshold_is_tunable() {
  local dir err n rc wakes
  dir=$(setup_case skippage-tunable)
  err="$dir/send.err"
  for n in 1 2; do
    run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending FM_SEND_SKIP_PAGE_MAX=2 -- t1 "steer $n"
    rc=$?
    [ "$rc" -eq 4 ] || fail "blocked send $n should exit with the skip code, got $rc"
  done
  wakes=$(grep -c 't1.doorbell-skip' "$dir/home/state/.wake-queue" 2>/dev/null || true)
  [ "${wakes:-0}" = 1 ] || fail "FM_SEND_SKIP_PAGE_MAX=2 should page on the second skip, got ${wakes:-0}"
  assert_contains "$(cat "$err")" "paged the supervisor at 2 consecutive skips" \
    "the page should name the configured threshold"
  pass "fm-send inbox: FM_SEND_SKIP_PAGE_MAX moves the page threshold"
}

# A page whose wake-queue append fails leaves no .paged marker, so the next
# skip in the same streak retries the page instead of never alerting.
test_failed_page_is_retried_by_the_next_skip() {
  local dir err rc wakes
  dir=$(setup_case skippage-retry)
  err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending FM_SEND_SKIP_PAGE_MAX=2 -- t1 "steer 1"
  mkdir "$dir/home/state/.wake-queue"
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending FM_SEND_SKIP_PAGE_MAX=2 -- t1 "steer 2"
  rc=$?
  expect_code 4 "$rc" "a skip whose page failed is still the countable skip"
  [ ! -e "$dir/home/state/t1.doorbell-skip.paged" ] || fail "a failed page must not arm the page marker"
  assert_contains "$(cat "$err")" "the supervisor page could not be queued" \
    "a failed page must be surfaced"
  rmdir "$dir/home/state/.wake-queue"
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending FM_SEND_SKIP_PAGE_MAX=2 -- t1 "steer 3"
  [ -e "$dir/home/state/t1.doorbell-skip.paged" ] || fail "the next skip should retry and arm the page"
  wakes=$(grep -c 't1.doorbell-skip' "$dir/home/state/.wake-queue" 2>/dev/null || true)
  [ "${wakes:-0}" = 1 ] || fail "the retried page should queue exactly once, got ${wakes:-0}"
  assert_contains "$(cat "$err")" "paged the supervisor at 2 consecutive skips" \
    "the retried page should be named"
  pass "fm-send inbox: a failed page leaves no marker and the next skip retries it"
}

# A threshold tuned off pages nothing: 0, 00, and an explicitly empty value
# all mean no paging, so a disabled rail can never page on its first skip,
# while a non-numeric value keeps the default instead of silencing the rail.
test_zero_or_empty_skip_threshold_disables_paging() {
  local dir err label val n rc wakes
  for label in 0 00 empty; do
    case "$label" in empty) val= ;; *) val=$label ;; esac
    dir=$(setup_case "skippage-off-$label")
    err="$dir/send.err"
    for n in 1 2 3; do
      run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending "FM_SEND_SKIP_PAGE_MAX=$val" -- t1 "steer $n"
      rc=$?
      [ "$rc" -eq 4 ] || fail "FM_SEND_SKIP_PAGE_MAX='$val' skip $n should exit 4, got $rc"
    done
    [ "$(cat "$dir/home/state/t1.doorbell-skip" 2>/dev/null)" = 3 ] || \
      fail "FM_SEND_SKIP_PAGE_MAX='$val' should still count the streak"
    [ ! -e "$dir/home/state/t1.doorbell-skip.paged" ] || \
      fail "FM_SEND_SKIP_PAGE_MAX='$val' must never arm a page"
    assert_not_contains "$(cat "$err")" "paged the supervisor" \
      "FM_SEND_SKIP_PAGE_MAX='$val' must never report a page"
    wakes=$(grep -c 't1.doorbell-skip' "$dir/home/state/.wake-queue" 2>/dev/null || true)
    [ "${wakes:-0}" = 0 ] || fail "FM_SEND_SKIP_PAGE_MAX='$val' queued ${wakes:-0} page(s)"
  done

  # A non-numeric value keeps the default rather than disabling the rail.
  dir=$(setup_case skippage-typo)
  err="$dir/send.err"
  for n in 1 2 3; do
    run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending FM_SEND_SKIP_PAGE_MAX=notanumber -- t1 "steer $n"
    rc=$?
    [ "$rc" -eq 4 ] || fail "a non-numeric threshold should keep skipping with exit 4, got $rc"
  done
  wakes=$(grep -c 't1.doorbell-skip' "$dir/home/state/.wake-queue" 2>/dev/null || true)
  [ "${wakes:-0}" = 1 ] || \
    fail "a non-numeric threshold should keep the default page at 3, got ${wakes:-0}"
  assert_contains "$(cat "$err")" "paged the supervisor at 3 consecutive skips" \
    "a typo should still page at the documented default"
  pass "fm-send inbox: a zero or empty FM_SEND_SKIP_PAGE_MAX disables paging and a typo keeps the default"
}

# A composer an overlay pushed above the bounded inbox read is still recovered:
# the state verdict sees it in the viewport, so the recovery reads the held text
# on that same basis, submits it, and the doorbell lands. Before the viewport
# fallback this read failed and the skip fired, leaving the line blocking wakes.
test_overlay_covered_composer_is_recovered_via_viewport_read() {
  local dir err rc held typed
  dir=$(setup_case overlaycovered)
  err="$dir/send.err"
  held="$dir/held.txt"
  printf '%s' 'stale line above the overlay' > "$held"
  run_send "$dir" "$err" FM_FAKE_TMUX_BOUNDED_MISS=1 FM_FAKE_TMUX_HELD_FILE="$held" -- \
    t1 "steer past an overlay"
  rc=$?
  expect_code 0 "$rc" "a viewport-readable composer should still land the doorbell"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "SUBMIT: stale line above the overlay" \
    "the held line should be read on the viewport basis and submitted"
  assert_contains "$typed" "Firstmate instruction waiting" \
    "the doorbell should ring after the overlay-covered composer is recovered"
  assert_not_contains "$(cat "$err")" "doorbell-skip" \
    "a viewport-recovered composer must not report a skip"
  [ ! -e "$dir/home/state/t1.doorbell-skip" ] || fail "a viewport recovery must not count a skip"
  pass "fm-send inbox: an overlay-covered composer is recovered through the viewport read"
}

# Concurrent skips serialize on the counter's lock: none is lost and the
# streak pages exactly once.
test_concurrent_skips_count_every_skip_and_page_once() {
  local dir n wakes
  dir=$(setup_case skippage-concurrent)
  for n in 1 2 3 4; do
    env PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" \
      FM_SEND_LOG="$dir/send.log" FM_SEND_SETTLE=0 FM_FAKE_TMUX_COMPOSER=pending FM_SEND_SKIP_PAGE_MAX=2 \
      "$SEND" t1 "steer $n" >/dev/null 2>&1 &
  done
  wait
  [ "$(cat "$dir/home/state/t1.doorbell-skip" 2>/dev/null)" = 4 ] || \
    fail "four concurrent skips should count four, got $(cat "$dir/home/state/t1.doorbell-skip" 2>/dev/null)"
  wakes=$(grep -c 't1.doorbell-skip' "$dir/home/state/.wake-queue" 2>/dev/null || true)
  [ "${wakes:-0}" = 1 ] || fail "concurrent skips should page exactly once, got ${wakes:-0}"
  pass "fm-send inbox: concurrent composer skips count every skip and page once"
}

# A mid-turn deferral breaks the streak: failed recovery -> deferral -> failed
# recovery is two separate streaks of one, never a page. Herdr is the backend
# with a native busy state, so the stub reports the agent status from a file.
test_deferral_breaks_the_skip_streak() {
  local dir err st rc wakes
  dir="$TMP_ROOT/skip-deferral"
  mkdir -p "$dir/home/state" "$dir/fakebin"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane read") printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n' ;;
  "agent get") printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$(cat "$FM_FAKE_HERDR_STATUS")" ;;
  "pane process-info") printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"claude","argv":["claude"]}]}}}\n' "${4:-}" ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/herdr"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/sleep"
  chmod +x "$dir/fakebin/sleep"
  fm_write_meta "$dir/home/state/t1.meta" "window=default:w1:p1" "backend=herdr" \
    "herdr_session=default" "herdr_pane_id=w1:p1" "kind=ship" "harness=claude"
  err="$dir/send.err"
  for st in idle working idle; do
    printf '%s\n' "$st" > "$dir/status"
    rc=0
    env PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" \
      FM_FAKE_HERDR_STATUS="$dir/status" FM_SEND_SETTLE=0 FM_SEND_SKIP_PAGE_MAX=2 \
      "$SEND" t1 "steer while $st" >/dev/null 2>"$err" || rc=$?
    case "$st" in
    working)
      expect_code 0 "$rc" "a mid-turn endpoint defers the doorbell"
      assert_contains "$(cat "$err")" "doorbell deferred" "the middle send should defer"
      [ ! -e "$dir/home/state/t1.doorbell-skip" ] || fail "a deferral must break the skip streak"
      ;;
    *) expect_code 4 "$rc" "a failed recovery on an idle endpoint is the countable skip" ;;
    esac
  done
  [ "$(cat "$dir/home/state/t1.doorbell-skip" 2>/dev/null)" = 1 ] || \
    fail "the skip after a deferral should start a new streak, got $(cat "$dir/home/state/t1.doorbell-skip" 2>/dev/null)"
  [ ! -e "$dir/home/state/t1.doorbell-skip.paged" ] || fail "a mixed streak must not page"
  wakes=$(grep -c 't1.doorbell-skip' "$dir/home/state/.wake-queue" 2>/dev/null || true)
  [ "${wakes:-0}" = 0 ] || fail "a mixed streak must not queue a page, got ${wakes:-0}"
  pass "fm-send inbox: a mid-turn deferral breaks the consecutive-skip streak"
}

test_failed_ring_is_still_sent() {
  local dir err rc
  dir=$(setup_case ringfail)
  err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_SEND_FAIL=1 -- t1 "steer into a dead pane"
  rc=$?
  expect_code 0 "$rc" "a failed doorbell must not fail the send"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  assert_contains "$(cat "$err")" "watcher will re-ring" \
    "the failed-ring notice should point at the re-ring"
  pass "fm-send inbox: a failed doorbell is still a durably sent steer"
}

# Contract: a fire-and-forget record stays outside the re-ring ladder, so a
# ring that did not land at enqueue is owed exactly one retry by the watcher.
test_fire_and_forget_unlanded_ring_owes_one_retry() {
  local dir err rc
  dir=$(setup_case faf-retry)
  mkdir -p "$dir/home/config"
  : > "$dir/home/config/wait-no-turns"
  err="$dir/send.err"
  # The stub lists only window fm-t1, so the secondmate takes it over.
  rm -f "$dir/home/state/t1.meta"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-t1" alpha claude
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- \
    fm-domain --fire-and-forget 0123456789abcdef "reconcile your books"; rc=$?
  expect_code 4 "$rc" "a blocked fire-and-forget ring reports the countable skip"
  [ "$(cat "$dir/home/state/domain.inbox/.retry-ring" 2>/dev/null)" = 001.msg ] \
    || fail "a skipped fire-and-forget ring did not owe its one retry"
  assert_contains "$(cat "$err")" "the watcher will ring it once more" \
    "the skip notice should promise exactly one retry"

  run_send "$dir" "$err" -- fm-domain --fire-and-forget 1123456789abcdef "reconcile again"; rc=$?
  expect_code 0 "$rc" "a rung fire-and-forget steer should succeed"
  [ "$(cat "$dir/home/state/domain.inbox/.retry-ring" 2>/dev/null)" = 001.msg ] \
    || fail "a ring that landed must not owe a retry for its own record"

  dir=$(setup_case ordinary-no-retry)
  err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- t1 "ordinary steer"
  [ ! -e "$dir/home/state/t1.inbox/.retry-ring" ] \
    || fail "an ordinary record rides the ladder and must not owe a separate retry"
  pass "fm-send inbox: a fire-and-forget ring that did not land owes one retry ring"
}

# Without the flag a skipped fire-and-forget ring is not owed a retry.
test_fire_and_forget_retry_stays_off_without_the_flag() {
  local dir err rc
  dir=$(setup_case faf-retry-off)
  err="$dir/send.err"
  [ ! -e "$dir/home/config/wait-no-turns" ]
  rm -f "$dir/home/state/t1.meta"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-t1" alpha claude
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- \
    fm-domain --fire-and-forget 0123456789abcdef "reconcile your books"; rc=$?
  expect_code 4 "$rc" "a blocked fire-and-forget ring reports the countable skip"
  [ ! -e "$dir/home/state/domain.inbox/.retry-ring" ] \
    || fail "an absent flag still owed a fire-and-forget retry"
  assert_contains "$(cat "$err")" "the watcher will re-ring" \
    "an absent flag should keep the ordinary re-ring notice"
  pass "fm-send inbox: without config/wait-no-turns a fire-and-forget ring is not retried"
}

test_harness_invocations_stay_typed() {
  local dir err typed
  # A slash command must reach the harness's own parser, on any harness.
  dir=$(setup_case slash)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "/no-mistakes" || fail "a slash send should succeed"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "/no-mistakes" "the slash command should be typed literally"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a slash command must not be routed to the inbox"
  # A codex `$<skill>` invocation likewise stays typed.
  dir=$(setup_case codexskill codex)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 '$no-mistakes' || fail "a codex \$skill send should succeed"
  assert_contains "$(cat "$dir/send.log")" '$no-mistakes' "the codex \$skill should be typed literally"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a codex \$skill must not be routed to the inbox"
  # The same `$` message to a non-codex harness is plain text: inbox plane.
  dir=$(setup_case dollartext claude)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 '$5/month is cheap' || fail "a claude \$-text send should succeed"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "a non-codex \$-message should ride the inbox"
  case "$(cat "$dir/send.log")" in
  *'$5/month'*) fail "a non-codex \$-message payload was typed" ;;
  esac
  pass "fm-send planes: slash and codex \$skill invocations stay typed; plain \$-text rides the inbox"
}

test_explicit_target_stays_typed() {
  local dir err
  dir=$(setup_case explicit)
  err="$dir/send.err"
  run_send "$dir" "$err" -- sess:win "hello there" || fail "an explicit-target send should succeed"
  assert_contains "$(cat "$dir/send.log")" "hello there" \
    "an explicit backend target should receive the literal text"
  [ -z "$(find "$dir/home/state" -maxdepth 1 -name '*.inbox' -print 2>/dev/null)" ] ||
    fail "an explicit target has no task record here and must not grow an inbox"
  pass "fm-send planes: an explicit backend target keeps the typed plane"
}

test_key_path_never_touches_inbox() {
  local dir err
  dir=$(setup_case keypath)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 --key Enter || fail "a --key send should succeed"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "the --key path must never write an inbox record"
  pass "fm-send planes: the --key lifecycle path never touches the inbox"
}

test_secondmate_marker_and_enqueue_delivery() {
  local dir err body corr pr_rec delivered
  dir=$(setup_case secondmate)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  run_send "$dir" "$err" -- fm-domain "please summarize fleet health" ||
    fail "a secondmate steer should succeed"
  body=$(record_body _ "$dir/home/state/domain.inbox/001.msg")
  case "$body" in
  "$FM_FROMFIRST_MARK"corr=*) : ;;
  *) fail "the recorded body lost the from-firstmate marker/corr framing:"$'\n'"$body" ;;
  esac
  corr=$(printf '%s' "$body" | grep -oE 'corr=[a-f0-9]{16}' | head -1 | cut -d= -f2)
  [ -n "$corr" ] || fail "no corr token in the recorded body"
  pr_rec="$dir/home/state/pending-replies/$corr"
  [ -f "$pr_rec" ] || fail "no pending-reply expectation was recorded at $pr_rec"
  delivered=$(grep '^delivered_epoch=' "$pr_rec" | cut -d= -f2)
  [ -n "$delivered" ] || fail "enqueue IS delivery: delivered_epoch should be set at enqueue time:"$'\n'"$(cat "$pr_rec")"
  case "$(cat "$dir/send.log")" in
  *"summarize fleet health"*) fail "the marked payload was typed" ;;
  esac
  pass "fm-send inbox: a secondmate steer records marker+corr in the body and is delivered at enqueue"
}

test_post_enqueue_bookkeeping_failure_is_not_retryable() {
  local dir err rc rec body
  dir=$(setup_case bookkeeping-failure)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  cat >"$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
source_arg=${@: -2:1}
target_arg=${@: -1}
if [ "${FM_FAIL_DELIVERY_CONFIRM:-0}" = 1 ] \
  && grep -q '^confirmed=' "$source_arg" 2>/dev/null; then
  # Simulate losing both the delivery commit and its prepared recovery marker.
  rm -f "$target_arg"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$dir/fakebin/mv"

  run_send "$dir" "$err" FM_FAIL_DELIVERY_CONFIRM=1 -- domain "durable once"
  rc=$?
  # The durable record IS the delivery: even with the commit AND its recovery
  # marker both lost, the steer was delivered, so fm-send must not signal a
  # status that invites a resend (a nonzero would make automated callers
  # enqueue the same instruction again under a new sequence). The degradation
  # surfaces as its own distinct do-not-resend condition instead.
  expect_code 0 "$rc" "a delivered steer must not report a resend-inviting failure over lost bookkeeping"
  rec="$dir/home/state/domain.inbox/001.msg"
  [ -f "$rec" ] || fail "bookkeeping failure test did not durably enqueue the steer"
  [ "$(find "$dir/home/state/domain.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] ||
    fail "the delivered steer was duplicated:"$'\n'"$(ls "$dir/home/state/domain.inbox")"
  body=$(record_body _ "$rec")
  case "$body" in
  "$FM_FROMFIRST_MARK"corr=*) : ;;
  *) fail "bookkeeping failure test lost the secondmate marker: $body" ;;
  esac
  assert_contains "$(cat "$err")" "reply-tracking-degraded" \
    "lost bookkeeping should surface as its own distinct degraded condition"
  assert_contains "$(cat "$err")" "do not resend" \
    "the degraded condition should give explicit do-not-resend guidance"
  assert_contains "$(cat "$err")" "durably recorded at" \
    "the degraded condition should name the already-delivered record"
  pass "fm-send inbox: lost reply bookkeeping never invites a resend, and the delivered steer is never duplicated"
}

test_meta_lock_contention_fails_bounded() {
  local dir err rc holder marker lock i
  dir=$(setup_case meta-lock)
  err="$dir/send.err"
  marker="$dir/meta-lock-held"
  lock="$dir/home/state/.meta-t1.lock"
  bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    touch "$3"
    sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$marker" &
  holder=$!
  i=0
  while [ ! -e "$marker" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$marker" ] || {
    kill "$holder" 2>/dev/null
    fail "the metadata lock holder did not start"
  }
  run_send "$dir" "$err" FM_TASK_INBOX_LOCK_WAIT_SECS=0 -- t1 "must not hang"
  rc=$?
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  [ "$rc" -ne 0 ] || fail "metadata lock contention should fail after the bounded wait"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a lock refusal must not enqueue a record"
  assert_contains "$(cat "$err")" "metadata could not be locked" \
    "the bounded metadata lock refusal should be explicit"
  pass "fm-send inbox: metadata lock contention fails bounded without enqueue"
}

test_unwritable_inbox_fails_loudly() {
  local dir err rc
  dir=$(setup_case unwritable)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  : >"$dir/home/state/domain.inbox" # a FILE where the inbox dir must go
  run_send "$dir" "$err" -- fm-domain "this cannot be recorded"
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unwritable inbox must fail the send"
  assert_contains "$(cat "$err")" "inbox record could not be written" \
    "the failure should name the unwritable inbox"
  [ ! -s "$dir/send.log" ] || fail "a failed enqueue still typed something:"$'\n'"$(cat "$dir/send.log")"
  [ -z "$(find "$dir/home/state/pending-replies" -type f -not -name '.*' 2>/dev/null)" ] ||
    fail "a failed enqueue should discard the just-created pending-reply expectation"
  pass "fm-send inbox: an unwritable record is a loud local failure that leaves no false expectation"
}

test_empty_message_refused() {
  local dir err rc
  # The lived defect: an empty marked secondmate steer used to deliver a
  # marker+corr record with no body and mint a pending-reply expectation the
  # parent could never see resolved.
  dir=$(setup_case empty-marked)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  run_send "$dir" "$err" -- fm-domain
  rc=$?
  [ "$rc" -ne 0 ] || fail "an empty secondmate steer should refuse"
  assert_contains "$(cat "$err")" "nonempty message" \
    "the empty-message refusal should be explicit"
  [ ! -d "$dir/home/state/domain.inbox" ] || fail "an empty steer still wrote an inbox record"
  [ -z "$(find "$dir/home/state/pending-replies" -type f -not -name '.*' 2>/dev/null)" ] ||
    fail "an empty steer still minted a pending-reply expectation"
  [ ! -s "$dir/send.log" ] || fail "an empty steer still typed something:"$'\n'"$(cat "$dir/send.log")"

  # An explicit empty-string argument is the same refusal.
  dir=$(setup_case empty-string-arg)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 ""
  rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit empty-string message should refuse"
  assert_contains "$(cat "$err")" "nonempty message" \
    "the empty-string refusal should be explicit"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "an empty-string steer still wrote an inbox record"

  # A whitespace-only message is equally contentless and refuses.
  dir=$(setup_case whitespace-only)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "   "
  rc=$?
  [ "$rc" -ne 0 ] || fail "a whitespace-only message should refuse"
  assert_contains "$(cat "$err")" "nonempty message" \
    "the whitespace-only refusal should be explicit"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a whitespace-only steer still wrote an inbox record"

  # The --key lifecycle path is unaffected: it takes no text at all.
  dir=$(setup_case keypath-after-refusal)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 --key Enter || fail "a --key send should still succeed"
  pass "fm-send: an empty or whitespace-only text steer refuses before marking, recording, or typing"
}

test_text_steer_rides_inbox
test_deep_home_doorbell_stays_short
test_multiline_steer_is_legal
test_resend_enqueues_new_sequence
test_composer_junk_is_cleared_and_the_doorbell_rings
test_composer_stale_text_is_submitted_and_the_doorbell_rings
test_composer_recovery_failure_is_a_loud_countable_skip
test_consecutive_composer_skips_page_once_and_reset
test_skip_page_threshold_is_tunable
test_zero_or_empty_skip_threshold_disables_paging
test_overlay_covered_composer_is_recovered_via_viewport_read
test_failed_page_is_retried_by_the_next_skip
test_concurrent_skips_count_every_skip_and_page_once
test_deferral_breaks_the_skip_streak
test_failed_ring_is_still_sent
test_fire_and_forget_unlanded_ring_owes_one_retry
test_fire_and_forget_retry_stays_off_without_the_flag
test_harness_invocations_stay_typed
test_explicit_target_stays_typed
test_key_path_never_touches_inbox
test_secondmate_marker_and_enqueue_delivery
test_post_enqueue_bookkeeping_failure_is_not_retryable
test_meta_lock_contention_fails_bounded
test_unwritable_inbox_fails_loudly
test_empty_message_refused
