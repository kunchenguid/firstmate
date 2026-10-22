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
set -u
# An installed task-priority add-on must not change unrelated cases.
export FM_TASK_PRIORITY_CHECK=/nonexistent

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
  fm_test_tasks_toml "$dir/code/.tasks.toml"
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
  fm_test_tasks_toml "$dir/.tasks.toml"
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
    wrapper_from_code "$dir" "done" "ship-$i" >/dev/null || fail "done ship-$i failed"
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
  fm_test_tasks_toml "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  (cd "$dir" && FM_ROOT_OVERRIDE="$dir" "$WRAPPER" add solo-1 "single home" >/dev/null) \
    || fail "add in the single-home layout failed"
  assert_grep "solo-1" "$dir/data/backlog.md" "the single-home layout lost its own backlog write"
  pass "fm-tasks-axi.sh keeps the single-home layout addressing its own code-root backlog"
}

expect_captain_refusal() {  # <case-dir> <id> <tasks-axi args...>
  local dir=$1 id=$2 err status
  shift 2
  err=$(wrapper_from_code "$dir" "$@" 2>&1 >/dev/null); status=$?
  [ "$status" = 2 ] || fail "expected exit 2 refusing: $* (got $status)"
  case "$err" in *"$id"*) ;; *) fail "refusal of $* did not name $id: $err" ;; esac
}

test_wrapper_captain_ask_guard() {
  local dir bin
  dir=$(make_split captain-ask)
  bin="$dir/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'EOF'
#!/bin/sh
case "$3" in */pull/1) echo MERGED ;; *) echo OPEN ;; esac
EOF
  chmod +x "$bin/gh"
  printf 'Yes, ship it.\n' > "$dir/answer.txt"
  wrapper_from_code "$dir" add ca-1 "[captain-ask] pick one" >/dev/null
  wrapper_from_code "$dir" add ca-2 "[captain-ask] pick two" >/dev/null
  wrapper_from_code "$dir" add ca-3 "[captain-ask] pick three" >/dev/null
  wrapper_from_code "$dir" add plain-1 "ordinary" >/dev/null
  wrapper_from_code "$dir" add ca-4 "[captain-ask] pick four" >/dev/null
  wrapper_from_code "$dir" add ca-5 "[captain-ask] reconciled only" >/dev/null
  wrapper_from_code "$dir" update ca-5 --body "$(printf 'Resolution recorded by fm-captain-hold.\nDecision digest: d\nResolution mode: reconciled\n\nReconciliation evidence:\nmoot\n')" >/dev/null \
    || fail "could not write a reconciled-only record"
  expect_captain_refusal "$dir" ca-1 rm ca-1
  expect_captain_refusal "$dir" ca-1 "done" ca-1
  expect_captain_refusal "$dir" ca-1 hold ca-1 --reason parked --kind parked
  expect_captain_refusal "$dir" ca-1 rm --json ca-1
  expect_captain_refusal "$dir" ca-1 "done" --note --json plain ca-1
  expect_captain_refusal "$dir" ca-3 task rm ca-3
  expect_captain_refusal "$dir" ca-1 hold --kind parked --reason parked ca-1
  expect_captain_refusal "$dir" ca-5 rm ca-5
  expect_captain_refusal "$dir" ca-1 update ca-1 --title "pick one, untagged"
  expect_captain_refusal "$dir" ca-1 edit ca-1 --title "pick one, untagged"
  expect_captain_refusal "$dir" ca-2 update --repo plain-1 ca-2 --title "pick two, untagged"
  mkdir -p "$dir/unreadable"
  cat > "$dir/unreadable/tasks-axi" <<EOF
#!/bin/sh
[ "\$1" = show ] && exit 1
exec "$(command -v tasks-axi)" "\$@"
EOF
  chmod +x "$dir/unreadable/tasks-axi"
  PATH="$dir/unreadable:$PATH" expect_captain_refusal "$dir" ca-3 rm ca-3
  assert_grep "ca-1" "$dir/home/data/backlog.md" "the refused item left the backlog"
  assert_grep "ca-3" "$dir/home/data/backlog.md" "a refused item left the backlog"
  (cd "$dir/code" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$ROOT/bin/fm-captain-hold.sh" hold ca-1 --reason "pick one" >/dev/null \
    && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$ROOT/bin/fm-captain-hold.sh" answer ca-1 --decision-file "$dir/answer.txt" >/dev/null) \
    || fail "could not record a captain answer"
  wrapper_from_code "$dir" rm ca-1 >/dev/null 2>&1 || fail "rm of an answered [captain-ask] item was refused"
  wrapper_from_code "$dir" update ca-4 --pr https://github.com/o/r/pull/2 >/dev/null
  PATH="$bin:$PATH" expect_captain_refusal "$dir" ca-4 "done" ca-4
  wrapper_from_code "$dir" update ca-2 --pr https://github.com/o/r/pull/1 >/dev/null
  wrapper_from_code "$dir" update ca-2 --pr https://github.com/o/r/pull/2 >/dev/null
  (PATH="$bin:$PATH" wrapper_from_code "$dir" "done" ca-2 >/dev/null 2>&1) || fail "done with a merged PR among several links was refused"
  wrapper_from_code "$dir" rm plain-1 >/dev/null 2>&1 || fail "an untagged item was refused"
  pass "fm-tasks-axi.sh keeps [captain-ask] items until answered or merged and leaves other items alone"
}

# The optional task-priority add-on check refuses an add before tasks-axi runs; absent, it does nothing.
test_wrapper_runs_the_task_priority_check() {
  local dir stub rc
  dir=$(make_split priority-check)
  stub="$dir/check.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
case " $* " in *' --priority '*) exit 0 ;; esac
echo "task-priority: this task has no priority" >&2
exit 1
SH
  chmod +x "$stub"
  rc=0
  FM_TASK_PRIORITY_CHECK="$stub" wrapper_from_code "$dir" add pri-1 "no priority" >"$dir/out" 2>&1 || rc=$?
  assert_equals 1 "$rc" "a refusing check must return its exit status"
  assert_grep "task-priority: this task has no priority" "$dir/out" "the check's message was not shown"
  assert_no_grep "pri-1" "$dir/home/data/backlog.md" "a refused add still reached the backlog"
  FM_TASK_PRIORITY_CHECK="$stub" wrapper_from_code "$dir" add pri-2 "has priority" --priority 1 >/dev/null 2>&1 \
    || fail "an add with a priority was refused"
  assert_grep "pri-2" "$dir/home/data/backlog.md" "a passing add did not reach the backlog"
  FM_TASK_PRIORITY_CHECK="$dir/not-installed" wrapper_from_code "$dir" add pri-3 "check absent" >/dev/null 2>&1 \
    || fail "an add failed with the check absent"
  assert_grep "pri-3" "$dir/home/data/backlog.md" "an absent check blocked the add"
  FM_TASK_PRIORITY_CHECK="$stub" wrapper_from_code "$dir" list >/dev/null 2>&1 || fail "a non-add command was checked"
  pass "fm-tasks-axi.sh add honors the installed task-priority check and ignores its absence"
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
  test_wrapper_captain_ask_guard
  test_wrapper_runs_the_task_priority_check
else
  echo "skip: tasks-axi not found; home-addressing cases not run"
fi
