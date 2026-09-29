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

# A home that is itself a Firstmate checkout runs its own scripts, the way a
# leased secondmate worktree does.
make_checkout_home() {  # <dir>
  mkdir -p "$1/data" "$1/state" "$1/config"
  ln -s "$ROOT/bin" "$1/bin"
  cp "$ROOT/AGENTS.md" "$1/AGENTS.md"
  cp "$ROOT/.tasks.toml" "$1/.tasks.toml"
}

# A live verified-harness process holding <state>/.lock, the way a running
# session holds its home's lock. bash stays the process image (the trailing
# no-op defeats exec of the last command) under an argv[0] named claude.
hold_session_lock() {  # <state-dir>; prints the holder pid
  local fakebin="$TMP_ROOT/fakebin" pid
  mkdir -p "$fakebin" "$1"
  [ -e "$fakebin/claude" ] || ln -s /bin/bash "$fakebin/claude"
  "$fakebin/claude" -c 'sleep 60; :' >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$1/.lock"
  printf '%s\n' "$pid"
}

# The reported cross-home false positive: another checkout's bootstrap run
# with FM_HOME naming a secondmate home that is itself a Firstmate checkout.
# The invoking checkout's data/ is its own home's live backlog, not a fork of
# the secondmate's, so nothing may be reported against it - least of all a
# remedy that moves it aside.
test_guard_silent_for_cross_home_checkout() {
  local dir out
  dir="$TMP_ROOT/cross-home"
  make_checkout_home "$dir/main"
  make_checkout_home "$dir/mate"
  printf '## In flight\n\n## Queued\n\n- [ ] main-1: the main home'"'"'s own row\n\n## Done\n' \
    > "$dir/main/data/backlog.md"
  printf '## Done\n' > "$dir/main/data/done-archive.md"
  empty_backlog "$dir/mate/data/backlog.md"
  printf '## Done\n' > "$dir/mate/data/done-archive.md"
  out=$(PATH="$BASE_PATH" FM_HOME="$dir/mate" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_BOOTSTRAP_NETWORK=skip "$dir/main/bin/fm-bootstrap.sh" 2>&1 | grep '^BACKLOG_RECONCILE' || true)
  assert_not_contains "$out" "$dir/main/data" \
    "a cross-home bootstrap reported the invoking checkout's own data files"
  assert_equals "" "$out" "a cross-home bootstrap of a checkout home must stay silent"
  pass "another checkout's bootstrap stays silent for a home that is its own checkout"
}

# A separate operational home may carry its own .tasks.toml to select a
# backlog adapter without being a checkout. Its sessions still run the code
# root's scripts, so a bare tasks-axi write from the code root still forks the
# queue there, and the check must keep seeing it.
test_guard_reports_fork_beside_home_with_own_tasks_config() {
  local dir out
  dir=$(make_split guard-home-tasks-config)
  cp "$ROOT/.tasks.toml" "$dir/home/.tasks.toml"
  rm "$dir/code/data/backlog.md"
  printf '## In flight\n\n## Queued\n\n- [ ] stray: written from the code root\n\n## Done\n' \
    > "$dir/code/data/backlog.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_contains "$out" "BACKLOG_RECONCILE: code-root $dir/code/data/backlog.md is not this home's $dir/home/data/backlog.md" \
    "a code-root fork beside a home with its own .tasks.toml was not reported"
  assert_not_contains "${out##* - }" "move it aside" "a stray fork beside a non-checkout home incorrectly gained a move-aside remedy"
  assert_contains "${out##* - }" "this check cannot tell whether that file is another home's live record" "the non-destructive remedy was not used"
  pass "a home's own .tasks.toml does not hide a code-root fork"
}

# The remedy must never move another home's records. Whether the code root is
# another home is a durable identity fact - its own .fm-secondmate-home marker,
# this home's registered parent, or a secondmate home in a registry - so a home
# between sessions, with no live process, is still protected. A code-root copy
# inside the home (a checkout home whose data directory is relocated) is this
# home's to move.
test_guard_remedy_never_moves_external_code_root() {
  local dir out remedy holder
  dir=$(make_split guard-remedy-external)
  rm "$dir/code/data/backlog.md"
  empty_backlog "$dir/code/data/backlog.md"
  mkdir -p "$dir/code/state"
  printf 'sibling
' > "$dir/code/.fm-secondmate-home"
  
  # Also simulate stray/broken chain/ancestor/stale state
  holder=$(hold_session_lock "$dir/code/state")
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_contains "$out" "is not this home's $dir/home/data/backlog.md" "a code-root backlog was not reported"
  remedy=${out##* - }
  assert_contains "$remedy" "this check cannot tell whether that file is another home's live record" "the non-destructive remedy was not used"
  assert_contains "$remedy" "leave ambiguous rows untouched and report them to the captain" "the row-recovery instruction was missing"
  assert_not_contains "$remedy" "move it aside" "the remedy moved an external code root's backlog"
  
  rm "$dir/code/.fm-secondmate-home"
  
  # Relocated data
  rm -rf "$dir/home/.fm-secondmate-parent" "$dir/home/bin"
  mkdir -p "$dir/relocated"
  make_checkout_home "$dir/home"
  empty_backlog "$dir/relocated/backlog.md"
  out=$(PATH="$BASE_PATH" FM_HOME="$dir/home" FM_DATA_OVERRIDE="$dir/relocated" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" 2>&1 \
    | grep '^BACKLOG_RECONCILE: code-root' || true)
  assert_contains "$out" "code-root $dir/home/data/backlog.md is not this home's $dir/relocated/backlog.md" \
    "a checkout home's own code-root copy beside its relocated data was not reported"
  assert_contains "$out" "it is inside this home, so merge it into this home's copy and move it aside" "a code-root copy inside this home lost its move-aside remedy"
  pass "a code root outside the home never gets move-aside regardless of marker, registry, parent chain, cycle, or stale state/, while relocated-data keeps move-aside"
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

# The warning is an operator-facing recovery instruction, not an automatic
# row merger. Check that emitted contract with colliding IDs and unclaimed
# queued rows, and prove that inspection leaves both homes' books untouched.
test_guard_row_recovery_requires_unambiguous_ownership() {
  local dir out line name before
  dir=$(make_split guard-row-ownership)
  rm "$dir/code/data/backlog.md"
  mkdir -p "$dir/code/state" "$dir/code/data/shared-data" "$dir/home/data/shared-data"
  printf 'task: target work\n' > "$dir/home/state/shared-state.status"
  printf 'task: unrelated code-root work\n' > "$dir/code/state/shared-state.status"
  printf 'task: target-only work\n' > "$dir/home/state/target-only.status"
  for name in backlog.md done-archive.md; do
    printf '## Queued\n\n- [ ] shared-state: unrelated code-root work\n- [ ] shared-data: another colliding task\n- [ ] unclaimed: queued without records in either home\n- [ ] target-only: target-only work\n' \
      > "$dir/code/data/$name"
    printf '## Queued\n\n- [ ] shared-state: target work\n- [ ] shared-data: target data-backed task\n' \
      > "$dir/home/data/$name"
  done
  before=$(cksum "$dir/code/data/"*.md "$dir/home/data/"*.md)
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  for name in backlog.md done-archive.md; do
    line=$(printf '%s\n' "$out" | grep -F "code-root $dir/code/data/$name is not")
    assert_contains "$line" "a matching task id alone is not ownership evidence" \
      "the emitted recovery instruction treats an overlapping id as ownership"
    assert_contains "$line" "only rows corroborated as the same task by this home's records" \
      "the emitted recovery instruction lacks positive task evidence"
    assert_contains "$line" "whose id has no record in $dir/code" \
      "the emitted recovery instruction ignores competing code-root records"
    assert_contains "$line" "leave ambiguous rows untouched and report them to the captain" \
      "ambiguous recovery rows were not escalated"
    assert_contains "$line" "including every row both homes' records claim or neither home's records claim" \
      "colliding or unclaimed rows were silently excluded from recovery"
    assert_contains "$line" "queued rows may have no records yet" \
      "a missing queued row without records was treated as irrelevant"
    assert_not_contains "$line" "move it aside" "recovery moved another home's file"
  done
  assert_equals "$before" "$(cksum "$dir/code/data/"*.md "$dir/home/data/"*.md)" \
    "the ownership warning changed a home's backlog or archive"
  pass "recovery guidance requires task evidence and escalates overlapping ids and unclaimed queued rows without writes"
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
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  (cd "$dir" && FM_ROOT_OVERRIDE="$dir" "$WRAPPER" add solo-1 "single home" >/dev/null) \
    || fail "add in the single-home layout failed"
  assert_grep "solo-1" "$dir/data/backlog.md" "the single-home layout lost its own backlog write"
  pass "fm-tasks-axi.sh keeps the single-home layout addressing its own code-root backlog"
}

test_guard_reports_regular_code_root_backlog
test_guard_reports_foreign_link_and_archive
test_guard_silent_for_single_home
test_guard_silent_for_cross_home_checkout
test_guard_reports_fork_beside_home_with_own_tasks_config
test_guard_remedy_never_moves_external_code_root
test_guard_row_recovery_requires_unambiguous_ownership
if [ "$HAVE_TASKS_AXI" = 1 ]; then
  test_bare_tasks_axi_fork_is_detected
  test_wrapper_writes_through_to_home
  test_wrapper_overrides_ambient_file
  test_wrapper_refusals
  test_wrapper_refuses_add_start
  test_wrapper_single_home
else
  echo "skip: tasks-axi not found; home-addressing cases not run"
fi
