#!/usr/bin/env bash
# Behavior tests for bin/fm-tasks-axi.sh home addressing and bootstrap's
# shadow-backlog check, over the split layout where the operational home lives
# outside the code root that carries the tracked .tasks.toml.
#
# The fork these guard against: .tasks.toml names data/backlog.md relative to
# the caller's working directory, and tasks-axi writes by renaming a temp file
# over its target, so a bare tasks-axi run from the code root turns a code-root
# symlink into the home's backlog into a private regular copy. The suite proves
# that every write through bin/fm-tasks-axi.sh lands in $FM_HOME/data from the
# code root (including archiving and relative --body-file arguments),
# that the command refuses addressing it cannot keep correct, and that bootstrap
# reports any code-root copy that is not this home's own file while staying
# silent for a link into the home, an absent copy, and the single-home layout.
# It also pins `done` reaching this home's guarded close: a bare close, a reason
# outside the done-class contract, a `--report` on a row that is not a scout, and
# a project row with no worker record are refused with the row untouched, a
# done-class close carrying a worker record passes and prints tasks-axi's own
# success line, and a home the transition gate skips keeps the raw pass-through.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-tasks-axi)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# The developer shell may pin any of these; each case states its own layout.
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

empty_backlog() {  # <path>
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$1"
}

# A code root carrying the tracked .tasks.toml and an operational home beside
# it, with the code-root backlog linked into the home the way an operator
# would try to keep the two in sync.
make_split() {  # <name>; prints the case directory
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/code/data" "$dir/home/data" "$dir/home/state" "$dir/home/config"
  cp "$ROOT/.tasks.toml" "$dir/code/.tasks.toml"
  empty_backlog "$dir/home/data/backlog.md"
  ln -s "$dir/home/data/backlog.md" "$dir/code/data/backlog.md"
  printf '%s\n' "$dir"
}

# Run the wrapper from the code root, as firstmate does.
wrapper_from_code() {  # <case-dir> <tasks-axi args...>
  local dir=$1
  shift
  (cd "$dir/code" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" "$@")
}

# Only the shadow-backlog lines matter here; the rest of a detect-only local
# bootstrap pass reports this host's toolchain, which is not under test, so it
# runs on the bare base PATH where every tool probe is a fast miss.
bootstrap_backlog_lines() {  # <code-root> [<home>]
  local code=$1 home=${2:-}
  if [ -n "$home" ]; then
    PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$code" FM_BOOTSTRAP_DETECT_ONLY=1 \
      FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" 2>&1 | grep '^BACKLOG_RECONCILE: code-root' || true
  else
    PATH="$BASE_PATH" FM_ROOT_OVERRIDE="$code" FM_BOOTSTRAP_DETECT_ONLY=1 \
      FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" 2>&1 | grep '^BACKLOG_RECONCILE: code-root' || true
  fi
}

test_guard_reports_regular_code_root_backlog() {
  local dir out
  dir=$(make_split guard-regular)
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_equals "" "$out" "a code-root link into this home must stay silent"

  rm "$dir/code/data/backlog.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_equals "" "$out" "an absent code-root backlog must stay silent"

  printf '## In flight\n\n## Queued\n\n- [ ] stray: written from the code root\n\n## Done\n' \
    > "$dir/code/data/backlog.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_contains "$out" "BACKLOG_RECONCILE: code-root $dir/code/data/backlog.md is not this home's $dir/home/data/backlog.md" \
    "a regular code-root backlog beside a separate home was not reported"
  assert_not_contains "$out" "done-archive.md" "an absent code-root archive was reported"
  pass "bootstrap reports a regular code-root backlog and stays silent for a link into the home or no copy"
}

test_guard_reports_foreign_link_and_archive() {
  local dir out
  dir=$(make_split guard-foreign)
  empty_backlog "$dir/elsewhere.md"
  rm "$dir/code/data/backlog.md"
  ln -s "$dir/elsewhere.md" "$dir/code/data/backlog.md"
  printf '## Done\n' > "$dir/code/data/done-archive.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_contains "$out" "code-root $dir/code/data/backlog.md is not this home's" \
    "a code-root backlog linked outside this home was not reported"
  assert_contains "$out" "code-root $dir/code/data/done-archive.md is not this home's $dir/home/data/done-archive.md" \
    "a regular code-root archive beside a separate home was not reported"
  pass "bootstrap reports a code-root backlog linked elsewhere and a forked archive"
}

test_guard_silent_for_single_home() {
  local dir out
  dir="$TMP_ROOT/single-guard"
  mkdir -p "$dir/data"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  printf '## Done\n' > "$dir/data/done-archive.md"
  out=$(bootstrap_backlog_lines "$dir")
  assert_equals "" "$out" "the single-home layout's own backlog was reported as a fork"
  out=$(bootstrap_backlog_lines "$dir" "$dir")
  assert_equals "" "$out" "FM_HOME naming the code root was reported as a fork"
  pass "bootstrap stays silent when the code root is the home"
}

# The end-to-end fork: a bare tasks-axi write from the code root. Whatever the
# installed tasks-axi does to the link, bootstrap must agree with the result:
# a replaced link is reported, a written-through link is not.
test_bare_tasks_axi_fork_is_detected() {
  local dir out
  dir=$(make_split bare-fork)
  (cd "$dir/code" && tasks-axi add bare-1 "written from the code root" >/dev/null 2>&1) \
    || fail "bare tasks-axi add failed in the code root"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  if [ -L "$dir/code/data/backlog.md" ]; then
    assert_grep "bare-1" "$dir/home/data/backlog.md" "a written-through link lost the row"
    assert_equals "" "$out" "a written-through link was reported as a fork"
    pass "bare tasks-axi wrote through the code-root link and bootstrap stayed silent"
  else
    assert_no_grep "bare-1" "$dir/home/data/backlog.md" "the replaced link still reached the home"
    assert_contains "$out" "code-root $dir/code/data/backlog.md is not this home's" \
      "bootstrap missed the fork a bare tasks-axi write left behind"
    pass "bare tasks-axi replaced the code-root link and bootstrap reported the fork"
  fi
}

test_wrapper_writes_through_to_home() {
  local dir i
  dir=$(make_split wrapper-home)
  for i in 1 2; do
    wrapper_from_code "$dir" add "ship-$i" "ship $i" >/dev/null || fail "add ship-$i failed"
    wrapper_from_code "$dir" start "ship-$i" >/dev/null || fail "start ship-$i failed"
    wrapper_from_code "$dir" "done" "ship-$i" --note "local main" >/dev/null || fail "done ship-$i failed"
  done
  wrapper_from_code "$dir" add call-1 "captain call" >/dev/null || fail "add call-1 failed"
  wrapper_from_code "$dir" hold call-1 --reason "awaiting the captain" --kind captain >/dev/null \
    || fail "hold call-1 failed"
  printf 'RELATIVE-BODY-MARKER\n' > "$dir/code/body.md"
  wrapper_from_code "$dir" update call-1 --body-file body.md >/dev/null \
    || fail "update with a caller-relative --body-file failed"
  wrapper_from_code "$dir" prune --keep 1 >/dev/null || fail "prune failed"

  [ -L "$dir/code/data/backlog.md" ] || fail "a wrapper write replaced the code-root link"
  [ "$dir/code/data/backlog.md" -ef "$dir/home/data/backlog.md" ] \
    || fail "the code-root link no longer names the home's backlog"
  assert_grep "call-1" "$dir/home/data/backlog.md" "the held row did not land in the home"
  assert_grep "RELATIVE-BODY-MARKER" "$dir/home/data/backlog.md" \
    "a caller-relative --body-file was not read from the caller's directory"
  assert_present "$dir/home/data/done-archive.md" "archiving did not reach the home"
  assert_grep "ship-1" "$dir/home/data/done-archive.md" "the oldest closed row was not archived in the home"
  assert_absent "$dir/code/data/done-archive.md" "archiving wrote a code-root archive"
  assert_equals "" "$(bootstrap_backlog_lines "$dir/code" "$dir/home")" \
    "bootstrap reported a fork after only wrapper writes"
  pass "fm-tasks-axi.sh writes, holds, archives, and reads relative body files through to the home from the code root"
}

test_wrapper_overrides_ambient_file() {
  local dir
  dir=$(make_split wrapper-ambient)
  empty_backlog "$dir/decoy.md"
  (cd "$dir/code" && TASKS_AXI_FILE="$dir/decoy.md" FM_HOME="$dir/home" "$WRAPPER" add amb-1 "ambient" >/dev/null) \
    || fail "add under an ambient TASKS_AXI_FILE failed"
  assert_grep "amb-1" "$dir/home/data/backlog.md" "an ambient TASKS_AXI_FILE diverted the write from the home"
  assert_no_grep "amb-1" "$dir/decoy.md" "an ambient TASKS_AXI_FILE received the write"
  wrapper_from_code "$dir" >/dev/null || fail "the no-command dashboard failed"
  pass "fm-tasks-axi.sh pins the home's backlog over an ambient TASKS_AXI_FILE and serves the dashboard"
}

test_wrapper_refusals() {
  local dir out rc before
  dir=$(make_split wrapper-refuse)
  before=$(cat "$dir/home/data/backlog.md")
  out=$(wrapper_from_code "$dir" add r-1 "explicit" --file "$dir/home/data/backlog.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "--file"
  assert_contains "$out" "drop --file" "--file refusal did not explain itself"
  out=$(wrapper_from_code "$dir" list --file="$dir/home/data/backlog.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "--file="

  mv "$dir/home/data/backlog.md" "$dir/home/real-backlog.md"
  ln -s "$dir/home/real-backlog.md" "$dir/home/data/backlog.md"
  out=$(wrapper_from_code "$dir" add r-2 "through a link" 2>&1)
  rc=$?
  expect_code 2 "$rc" "symlinked home backlog"
  assert_contains "$out" "is a symlink" "the symlinked home backlog refusal did not name the link"
  [ -L "$dir/home/data/backlog.md" ] || fail "a refused call still replaced the home link"
  assert_equals "$before" "$(cat "$dir/home/real-backlog.md")" "a refused call changed the backlog"

  out=$(cd "$dir/code" && FM_HOME="$dir/missing-home" "$WRAPPER" list 2>&1)
  rc=$?
  expect_code 2 "$rc" "missing data directory"
  pass "fm-tasks-axi.sh refuses caller --file, a symlinked home backlog, and an unresolvable home"
}

# Dispatch alone moves a row to In flight, because only bin/fm-spawn.sh
# creates the task record, status file, and inbox that go with it; a row
# hand-placed there through `add --start` would count as live work nobody runs.
test_wrapper_refuses_add_start() {
  local dir out rc before
  dir=$(make_split wrapper-add-start)
  before=$(cat "$dir/home/data/backlog.md")
  out=$(wrapper_from_code "$dir" add hs-1 "hand-started" --start 2>&1)
  rc=$?
  expect_code 2 "$rc" "add --start"
  assert_contains "$out" "bin/fm-spawn.sh" "the add --start refusal did not name the dispatch path"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused add --start still wrote a row"
  out=$(wrapper_from_code "$dir" create hs-c "hand-started via alias" --start 2>&1)
  rc=$?
  expect_code 2 "$rc" "create --start"
  assert_contains "$out" "bin/fm-spawn.sh" "the create --start refusal did not name the dispatch path"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused create --start still wrote a row"
  wrapper_from_code "$dir" add hs-2 "queued" >/dev/null || fail "plain add was refused"
  assert_grep "hs-2" "$dir/home/data/backlog.md" "plain add did not write its row"
  wrapper_from_code "$dir" start hs-2 >/dev/null || fail "start <id> was refused"
  pass "fm-tasks-axi.sh refuses add --start while plain add and start <id> pass through"
}

test_wrapper_single_home() {
  local dir
  dir="$TMP_ROOT/single-wrapper"
  mkdir -p "$dir/data"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  (cd "$dir" && FM_ROOT_OVERRIDE="$dir" "$WRAPPER" add solo-1 "single home" >/dev/null) \
    || fail "add in the single-home layout failed"
  assert_grep "solo-1" "$dir/data/backlog.md" "the single-home layout lost its own backlog write"
  pass "fm-tasks-axi.sh keeps the single-home layout addressing its own code-root backlog"
}

# `done` through the wrapper is the guarded close: a bare close and a reason
# outside the done-class contract are refused with the expected shape in the
# message, and project work no worker record ever proved was worked is refused
# too - each leaving the row untouched on refusal.
test_wrapper_done_is_guarded() {
  local dir out rc
  dir=$(make_split wrapper-done-guard)
  wrapper_from_code "$dir" add plain-1 "ordinary work" >/dev/null || fail "add plain-1 failed"
  wrapper_from_code "$dir" add proj-1 "project work" --kind ship --repo firstmate >/dev/null \
    || fail "add proj-1 failed"
  wrapper_from_code "$dir" start proj-1 >/dev/null || fail "start proj-1 failed"

  rc=0
  out=$(wrapper_from_code "$dir" "done" plain-1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a bare done closed an ordinary row with no done-class reason"
  assert_contains "$out" "done-class reason" "the ordinary-row bare refusal did not name the done-class rule"
  assert_contains "$(wrapper_from_code "$dir" show plain-1)" "state: queued" \
    "a refused bare close still moved an ordinary row"

  rc=0
  out=$(wrapper_from_code "$dir" "done" proj-1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a bare done closed a row with no done-class reason"
  assert_contains "$out" "done-class reason" "the bare-done refusal did not name the done-class rule"
  assert_contains "$out" "local main" "the bare-done refusal did not name the expected reason shape"
  assert_contains "$(wrapper_from_code "$dir" show proj-1)" "state: in_flight" \
    "a refused bare close still moved the row"

  rc=0
  out=$(wrapper_from_code "$dir" "done" proj-1 --note "Closed" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "free prose closed a project row through the wrapper"
  assert_contains "$out" "done-class reason" "the free-prose refusal did not name the done-class rule"
  assert_contains "$(wrapper_from_code "$dir" show proj-1)" "state: in_flight" \
    "a refused free-prose close still moved the row"

  rc=0
  out=$(wrapper_from_code "$dir" "done" proj-1 --note "local main" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a project row with no worker record closed through the wrapper"
  assert_contains "$out" "no worker record" "the worker-record refusal did not name its reason"
  assert_contains "$(wrapper_from_code "$dir" show proj-1)" "state: in_flight" \
    "a refused unworked close still moved the row"

  rc=0
  out=$(wrapper_from_code "$dir" close proj-1 --note "Closed" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the close alias bypassed the guarded close"
  assert_contains "$(wrapper_from_code "$dir" show proj-1)" "state: in_flight" \
    "a refused close-alias close still moved the row"
  pass "fm-tasks-axi.sh refuses a bare, free-prose, or unworked close on done and close"
}

# The same guarded close accepts a done-class reason once a worker record proves
# the project row was worked.
test_wrapper_done_closes_with_a_done_class_reason() {
  local dir out rc=0
  dir=$(make_split wrapper-done-valid)
  wrapper_from_code "$dir" add proj-2 "project work" --kind ship --repo firstmate >/dev/null \
    || fail "add proj-2 failed"
  wrapper_from_code "$dir" start proj-2 >/dev/null || fail "start proj-2 failed"
  printf 'spawn_gen=1\n' > "$dir/home/state/proj-2.meta"
  rc=0
  out=$(wrapper_from_code "$dir" "done" proj-2 --note "local main" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a done-class close carrying a worker record was refused: $out"
  assert_contains "$out" "ok: done proj-2 -> Done" \
    "the guarded close did not print tasks-axi's success line"
  assert_contains "$(wrapper_from_code "$dir" show proj-2)" "state: done" \
    "the guarded close did not mark the row done"
  pass "fm-tasks-axi.sh closes a worked project row for a done-class reason"
}

# A manual-backend home opts out of the transition gate, so its `done` keeps the
# raw pass-through the carve-out exists for.
test_wrapper_done_passes_through_on_a_manual_backend() {
  local dir rc=0 bare_rc=0
  dir=$(make_split wrapper-done-manual)
  printf 'manual\n' > "$dir/home/config/backlog-backend"
  wrapper_from_code "$dir" add proj-3 "project work" --kind ship --repo firstmate >/dev/null \
    || fail "add proj-3 failed"
  wrapper_from_code "$dir" start proj-3 >/dev/null || fail "start proj-3 failed"
  wrapper_from_code "$dir" "done" proj-3 --note "Closed" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a manual-backend home's done did not pass through to tasks-axi"
  assert_contains "$(wrapper_from_code "$dir" show proj-3)" "state: done" \
    "the manual-backend pass-through did not close the row"

  wrapper_from_code "$dir" add proj-4 "project work" --kind ship --repo firstmate >/dev/null \
    || fail "add proj-4 failed"
  wrapper_from_code "$dir" start proj-4 >/dev/null || fail "start proj-4 failed"
  wrapper_from_code "$dir" "done" proj-4 >/dev/null 2>&1 || bare_rc=$?
  [ "$bare_rc" -eq 0 ] || fail "a bare done was refused on a manual-backend home"
  assert_contains "$(wrapper_from_code "$dir" show proj-4)" "state: done" \
    "a bare manual-backend pass-through did not close the row"
  pass "fm-tasks-axi.sh passes done through unchanged on a manual-backend home"
}

# `--report` records a scout's own deliverable, so the guarded close refuses it
# on a row that is not a scout instead of closing under a fact nobody can check.
test_wrapper_done_refuses_a_report_on_a_non_scout_row() {
  local dir out rc=0
  dir=$(make_split wrapper-done-report)
  wrapper_from_code "$dir" add report-1 "ordinary work" --kind ship >/dev/null \
    || fail "add report-1 failed"
  rc=0
  out=$(wrapper_from_code "$dir" "done" report-1 --report data/report-1/report.md 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-scout row was closed against a scout deliverable"
  assert_contains "$out" "report completion is for scout rows" \
    "the non-scout report refusal did not name its rule"
  assert_contains "$(wrapper_from_code "$dir" show report-1)" "state: queued" \
    "a refused report close still moved the row"
  pass "fm-tasks-axi.sh refuses a report close on a row that is not a scout"
}

test_guard_reports_regular_code_root_backlog
test_guard_reports_foreign_link_and_archive
test_guard_silent_for_single_home
if [ "$HAVE_TASKS_AXI" = 1 ]; then
  test_bare_tasks_axi_fork_is_detected
  test_wrapper_writes_through_to_home
  test_wrapper_overrides_ambient_file
  test_wrapper_refusals
  test_wrapper_refuses_add_start
  test_wrapper_single_home
  test_wrapper_done_is_guarded
  test_wrapper_done_closes_with_a_done_class_reason
  test_wrapper_done_passes_through_on_a_manual_backend
  test_wrapper_done_refuses_a_report_on_a_non_scout_row
else
  echo "skip: tasks-axi not found; home-addressing cases not run"
fi
