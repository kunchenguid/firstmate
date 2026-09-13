#!/usr/bin/env bash
# Behavior tests for bin/fm-gram-check.sh, the standing Gram intake check.
#
# Two surfaces are exercised through their executable interfaces:
#
#   * arming/disarming state/gram.check.sh with its trust binding. Arming is the
#     half that fails silently if it ever regresses, and the cost is specific: an
#     unregistered shim is NOT inert, because the watcher rejects it every cycle
#     and wakes firstmate about unauthenticated state checks. So every refusal
#     path here asserts the same invariant - this home never ends up holding a
#     shim without a matching binding.
#
#   * the `check` action itself, whose whole job is the reporting contract: new
#     owner messages are always news, a repeated diagnostic is reported once and
#     goes quiet, a changed diagnostic is news again, a silent poll prints
#     nothing, and a poll past its bound still reports rather than disappearing.
#
# The poll underneath is stubbed per case, because what fm-gram.sh itself does is
# tests/fm-gram.test.sh's subject. No case contacts a real Herdr server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-gram-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-gram-check)

make_home() {  # <name>
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# A copy of the check tool with its own bin/, so a case can decide what the poll
# and the trust registrar do. <poll-body> and <register-body> are shell fragments
# run by the respective stub; an empty register body means the real registrar.
make_tool() {  # <name> <poll-body> [register-body]
  local name=$1 poll=$2 register=${3:-} bin lib
  bin="$TMP_ROOT/$name/bin"
  mkdir -p "$bin"
  cp "$ROOT/bin/fm-gram-check.sh" "$bin/fm-gram-check.sh"
  chmod +x "$bin/fm-gram-check.sh"
  for lib in fm-timeout-lib.sh fm-pr-lib.sh fm-line-cap-lib.sh fm-check-lib.sh fm-wake-lib.sh; do
    [ -e "$bin/$lib" ] || ln -s "$ROOT/bin/$lib" "$bin/$lib"
  done
  printf '#!/usr/bin/env bash\n%s\n' "$poll" > "$bin/fm-gram.sh"
  chmod +x "$bin/fm-gram.sh"
  if [ -n "$register" ]; then
    printf '#!/usr/bin/env bash\n%s\n' "$register" > "$bin/fm-check-register.sh"
    chmod +x "$bin/fm-check-register.sh"
  else
    [ -e "$bin/fm-check-register.sh" ] || ln -s "$ROOT/bin/fm-check-register.sh" "$bin/fm-check-register.sh"
  fi
  printf '%s\n' "$bin"
}

run_check() {  # <home> <out> <check-bin> [env...]
  local home=$1 out=$2 check=$3
  shift 3
  local status=0
  env -u FM_GRAM_BUDGET FM_CHECK_TIMEOUT=30 \
    "$@" FM_HOME="$home" "$check" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

shim_is_registered() {  # <home>
  FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1"; . "$2"; . "$3"
    fm_custom_check_registered "$4" gram
  ' _ "$ROOT/bin/fm-pr-lib.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-check-lib.sh" "$1/state"
}

shim_mode() {  # <home>
  fm_pr_file_mode_or_stat "$1/state/gram.check.sh" 2>/dev/null \
    || stat -f %Lp "$1/state/gram.check.sh" 2>/dev/null \
    || stat -c %a "$1/state/gram.check.sh"
}

test_help_and_usage() {
  local out rc=0
  out=$("$CHECK" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "check" "--help lists the check action"
  assert_contains "$out" "arm" "--help lists the arm action"
  assert_contains "$out" "disarm" "--help lists the disarm action"
  rc=0
  out=$("$CHECK" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must exit 2"
  assert_contains "$out" "unknown action" "unknown action is refused loudly"
  pass "fm-gram-check: help and usage plumbing"
}

test_arm_writes_a_private_registered_shim_and_disarm_removes_it() {
  local home out
  home=$(make_home arm)
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/gram.check.sh" "arm names the shim it wrote"
  assert_present "$home/state/gram.check.sh" "arm writes the check shim"
  assert_present "$home/state/gram.check-trust" "arm binds the shim for the watcher"
  assert_equals 700 "$(shim_mode "$home")" "the shim is owner-only and executable"
  shim_is_registered "$home" || fail "an armed shim must satisfy the watcher's own registration predicate"

  # The shim is the watcher's executable contract, so what it dispatches matters.
  assert_contains "$(cat "$home/state/gram.check.sh")" "fm-gram-check.sh check" \
    "the shim dispatches this tool's check action"
  assert_contains "$(cat "$home/state/gram.check.sh")" "FM_HOME=$home" \
    "the shim pins the absolute home it was armed for"

  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "re-arm must succeed: $out"
  assert_contains "$out" "armed" "re-arm stays armed"
  shim_is_registered "$home" || fail "re-arm must leave the shim registered"

  out=$(FM_HOME="$home" "$CHECK" disarm 2>&1) || fail "disarm must succeed: $out"
  assert_absent "$home/state/gram.check.sh" "disarm removes the check shim"
  assert_absent "$home/state/gram.check-trust" "disarm removes the trust binding"
  pass "fm-gram-check: arm writes a private registered shim, re-arm is idempotent, disarm removes it"
}

test_disarm_removes_the_report_record() {
  local home out
  home=$(make_home disarm_record)
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || fail "arm must succeed"
  out="$home/out.txt"
  run_check "$home" "$out" "$(make_tool disarm_record_tool 'echo "fm-gram: herdr gram list failed (gram_unavailable)"')/fm-gram-check.sh"
  assert_present "$home/state/.gram-check" "a reported diagnostic records its news key"
  FM_HOME="$home" "$CHECK" disarm >/dev/null 2>&1 || fail "disarm must succeed"
  assert_absent "$home/state/.gram-check" "disarm removes the report record"
  pass "fm-gram-check: disarm clears the report record as well as the shim"
}

test_arm_resolves_a_relative_home_into_the_shim() {
  local home rel out
  home=$(make_home relative)
  rel="$(basename "$home")"
  out=$(cd "$TMP_ROOT" && env FM_HOME="$rel" "$CHECK" arm 2>&1) \
    || fail "arm with a relative FM_HOME must succeed: $out"
  assert_contains "$(cat "$home/state/gram.check.sh")" "export FM_HOME=$home" \
    "the shim pins the resolved absolute home, not the relative spelling"
  pass "fm-gram-check: arm resolves a relative home into the shim"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home target out rc=0
  home=$(make_home symlink)
  target="$TMP_ROOT/outside"
  mkdir -p "$target"
  printf '#!/usr/bin/env bash\n' > "$target/gram.check.sh"
  ln -s "$target/gram.check.sh" "$home/state/gram.check.sh"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse a symlink at the shim path"
  assert_contains "$out" "could not write" "arm reports the shim write failure"
  assert_absent "$home/state/gram.check-trust" "no trust binding is left behind by a refused arm"
  pass "fm-gram-check: arm refuses a symlink at the shim path"
}

test_arm_refuses_without_the_poll() {
  local bin home out rc=0
  # A copy of the check tool with no fm-gram.sh beside it is a home whose Gram
  # intake has not landed: arming must refuse rather than register a shim that
  # can only ever fail.
  bin=$(make_tool no_poll 'exit 0')
  rm -f "$bin/fm-gram.sh"
  home=$(make_home no_poll_home)
  out=$(FM_HOME="$home" "$bin/fm-gram-check.sh" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse when the poll is missing"
  assert_contains "$out" "Gram poll is missing" "arm names the missing poll"
  assert_absent "$home/state/gram.check.sh" "a refused arm writes no shim"
  pass "fm-gram-check: arm refuses without the poll it would schedule"
}

# An unregistered shim is worse than no shim: the watcher rejects it every cycle
# and wakes firstmate about unauthenticated state checks. A register that fails
# must therefore leave the home in one of the two safe states - the previously
# registered shim, or nothing at all.
test_a_failed_register_leaves_no_unregistered_shim() {
  local bin home out rc=0
  bin=$(make_tool failed_register 'exit 0' 'exit 1')
  home=$(make_home failed_register_home)
  out=$(FM_HOME="$home" "$bin/fm-gram-check.sh" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must fail when the trust registrar refuses"
  assert_contains "$out" "could not register" "arm names the registration failure"
  assert_absent "$home/state/gram.check.sh" \
    "a home with no previous shim must not be left holding an unregistered one"
  pass "fm-gram-check: a failed register never leaves an unregistered shim behind"
}

test_a_failed_register_restores_the_previously_registered_shim() {
  local bin home out before rc=0
  home=$(make_home failed_register_restore)
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || fail "the first arm must succeed"
  before=$(cat "$home/state/gram.check.sh")
  shim_is_registered "$home" || fail "the first arm must leave a registered shim"

  # A second arm from a DIFFERENT tool path writes different shim bytes, so the
  # rollback has something real to restore, and its registrar refuses.
  bin=$(make_tool failed_register_restore_tool 'exit 0' 'exit 1')
  out=$(FM_HOME="$home" "$bin/fm-gram-check.sh" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "the second arm must fail when its registrar refuses"
  assert_equals "$before" "$(cat "$home/state/gram.check.sh")" \
    "the previously registered shim bytes are restored verbatim"
  shim_is_registered "$home" || fail "the restored shim must still satisfy the registration predicate"
  pass "fm-gram-check: a failed register restores the shim that was already registered"
}

# The trap exists so an arm killed between writing the shim and binding it does
# not leave the unregistered shim behind. The registrar stub signals its parent
# to reproduce exactly that window.
test_an_interrupted_arm_rolls_back_and_says_so() {
  local bin home out rc=0
  # shellcheck disable=SC2016 # $PPID must expand inside the stub, not here.
  bin=$(make_tool interrupted_arm 'exit 0' 'kill -TERM "$PPID"; sleep 5; exit 1')
  home=$(make_home interrupted_arm_home)
  out=$(FM_HOME="$home" "$bin/fm-gram-check.sh" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "an interrupted arm must exit non-zero"
  assert_contains "$out" "arming was interrupted" "an interrupted arm says the check is not armed"
  assert_absent "$home/state/gram.check.sh" "an interrupted arm leaves no unregistered shim"
  assert_absent "$home/state/gram.check-trust" "an interrupted arm leaves no trust binding"
  pass "fm-gram-check: an interrupted arm rolls the shim back instead of leaving it unbound"
}

test_new_messages_are_always_news() {
  local bin home out
  bin=$(make_tool news 'echo "fm-gram: 2 new Gram message(s) from the owner are waiting in the captain inbox"')
  home=$(make_home news_home)
  out="$home/out.txt"
  run_check "$home" "$out" "$bin/fm-gram-check.sh"
  assert_contains "$(cat "$out")" "gram: 2 new Gram message(s)" "new owner messages emit one wake line"
  assert_equals 1 "$(grep -c . "$out")" "the report is exactly one line"

  out="$home/out2.txt"
  run_check "$home" "$out" "$bin/fm-gram-check.sh"
  assert_contains "$(cat "$out")" "gram: 2 new Gram message(s)" \
    "new owner messages doorbell every time, never deduplicated into silence"
  pass "fm-gram-check: new owner messages are always news"
}

test_a_repeated_diagnostic_is_reported_once() {
  local bin changed home out
  bin=$(make_tool repeat_diag 'echo "fm-gram: herdr gram list failed (gram_unavailable)"; exit 1')
  home=$(make_home repeat_diag_home)
  out="$home/out.txt"
  run_check "$home" "$out" "$bin/fm-gram-check.sh"
  assert_contains "$(cat "$out")" "gram: herdr gram list failed (gram_unavailable)" \
    "an unreachable Gram channel is reported"
  assert_equals 1 "$(grep -c . "$out")" "the report is exactly one line"
  assert_contains "$(cat "$home/state/.gram-check")" "fm-gram-check-v1" "the record carries its schema"

  out="$home/out2.txt"
  run_check "$home" "$out" "$bin/fm-gram-check.sh"
  [ ! -s "$out" ] || fail "the same diagnostic must not be reported again: $(cat "$out")"

  # A DIFFERENT diagnostic is news again, so a changing failure is never masked.
  changed=$(make_tool changed_diag 'echo "fm-gram: no HERDR_PANE_ID in this environment"; exit 1')
  out="$home/out3.txt"
  run_check "$home" "$out" "$changed/fm-gram-check.sh"
  assert_contains "$(cat "$out")" "gram: no HERDR_PANE_ID" "a changed diagnostic is news again"
  pass "fm-gram-check: a repeated diagnostic reports once, and a changed one is news again"
}

test_a_silent_poll_prints_nothing() {
  local bin home out
  bin=$(make_tool silent 'exit 0')
  home=$(make_home silent_home)
  out="$home/out.txt"
  run_check "$home" "$out" "$bin/fm-gram-check.sh"
  [ ! -s "$out" ] || fail "a poll with nothing to say must stay silent: $(cat "$out")"
  assert_absent "$home/state/.gram-check" "a silent poll records no news key"
  pass "fm-gram-check: a poll with nothing new prints nothing"
}

# The watcher dispatches every check as `timeout <FM_CHECK_TIMEOUT> bash <shim>`
# and hands it the same FM_CHECK_TIMEOUT, so a check that bounds its own poll
# with that value loses the race to the watcher's timeout every time: the process
# group is killed and no line is ever printed. Driving this case through the same
# outer bound the watcher applies is the only way the assertion means anything,
# because without it the branch passes here while being dead in production.
test_a_slow_poll_is_bounded_and_reported() {
  local bin home out status=0
  bin=$(make_tool slow 'sleep 30')
  home=$(make_home slow_home)
  out="$home/out.txt"
  # fm_run_timed is the same bounded-execution owner bin/fm-watch.sh uses to
  # dispatch a check, so this is the watcher's own outer bound, portable to a
  # host with no GNU timeout.
  # shellcheck disable=SC2016 # $1/$2 must expand inside the child shell.
  env -u FM_GRAM_BUDGET FM_CHECK_TIMEOUT=8 FM_HOME="$home" \
    bash -c '. "$1"; fm_run_timed 8 "$2" check' _ "$ROOT/bin/fm-timeout-lib.sh" \
    "$bin/fm-gram-check.sh" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "the check must finish inside the watcher's own bound, not be killed by it"
  assert_contains "$(cat "$out")" "did not finish inside" \
    "a hung poll must report under the watcher's outer bound, not die silently"
  assert_equals 1 "$(grep -c . "$out")" "the timeout report is exactly one line"
  pass "fm-gram-check: a hung poll reports in one line under the watcher's own outer bound"
}

test_help_and_usage
test_arm_writes_a_private_registered_shim_and_disarm_removes_it
test_disarm_removes_the_report_record
test_arm_resolves_a_relative_home_into_the_shim
test_arm_refuses_a_symlink_at_the_shim_path
test_arm_refuses_without_the_poll
test_a_failed_register_leaves_no_unregistered_shim
test_a_failed_register_restores_the_previously_registered_shim
test_an_interrupted_arm_rolls_back_and_says_so
test_new_messages_are_always_news
test_a_repeated_diagnostic_is_reported_once
test_a_silent_poll_prints_nothing
test_a_slow_poll_is_bounded_and_reported
