#!/usr/bin/env bash
# tests/fm-park.test.sh - the park marker (bin/fm-park.sh, bin/fm-park-lib.sh):
# firstmate's own record that a task was stopped on purpose.
#
# Coverage:
#   - park writes one single-link mode-0700 line and never touches the worker's
#     status file; unpark and list round-trip; unsafe input is refused
#   - the reader returns parked, absent, or malformed (never absent for a bad
#     marker): bad content, wrong mode, extra link, symlink
#   - a successful spawn clears the marker, a refused spawn keeps it
# Watcher and digest behavior live beside their owners: fm-watch-triage.test.sh
# and fm-session-start.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-park-lib.sh"

PARK="$ROOT/bin/fm-park.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-park-tests)

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

run_park() {  # <home> args...
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PARK" "$@" 2>&1
}

test_park_writes_a_private_single_link_marker_and_leaves_status_alone() {
  local home out f mode
  home=$(make_home basic)
  printf 'window=t:x\n' > "$home/state/t1.meta"
  printf 'paused: waiting for firstmate\n' > "$home/state/t1.status"
  out=$(run_park "$home" park t1 --reason "queued behind the one-worker rule") || fail "park failed: $out"
  f="$home/state/t1.parked"
  [ "$(cat "$f")" != "" ] || fail "marker is empty"
  [ "$(wc -l < "$f" | tr -d ' ')" = 1 ] || fail "marker is not exactly one line"
  mode=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")
  [ "$mode" = 700 ] || fail "marker mode is $mode, expected 700"
  [ "$(stat -c %h "$f" 2>/dev/null || stat -f %l "$f")" = 1 ] || fail "marker is not single-link"
  [ "$(cat "$home/state/t1.status")" = 'paused: waiting for firstmate' ] || fail "park touched the worker's status file"
  fm_park_status "$home/state" t1 || fail "written marker does not read back as parked"
  [ "$FM_PARK_REASON" = "queued behind the one-worker rule" ] || fail "reason did not round-trip: $FM_PARK_REASON"
  out=$(run_park "$home" list) || fail "list failed"
  assert_contains "$out" "queued behind the one-worker rule" "list lost the reason"
  run_park "$home" unpark t1 >/dev/null || fail "unpark failed"
  [ ! -e "$f" ] || fail "unpark left the marker"
  run_park "$home" unpark t1 >/dev/null || fail "unpark is not idempotent"
  pass "park writes a private single-link marker, round-trips, and never touches the status file"
}

test_park_refuses_unsafe_input() {
  local home out
  home=$(make_home refuse)
  printf 'window=t:x\n' > "$home/state/t1.meta"
  out=$(run_park "$home" park t1 --reason "") && fail "an empty reason was accepted"
  out=$(run_park "$home" park t1 --reason $'two\nlines') && fail "a multi-line reason was accepted"
  out=$(run_park "$home" park nosuch --reason "x") && fail "a task with no record was parked"
  out=$(run_park "$home" park '../evil' --reason "x") && fail "a path-shaped task id was accepted"
  ln -s /nonexistent "$home/state/t1.parked"
  out=$(run_park "$home" park t1 --reason "x") && fail "a symlinked marker path was replaced"
  assert_contains "$out" "not a regular file" "symlink refusal did not say why"
  pass "park refuses empty, multi-line, unknown-task, path-shaped, and symlinked input"
}

test_reader_never_reads_a_bad_marker_as_absent() {
  local home st f
  home=$(make_home reader)
  fm_park_status "$home/state" none && fail "no marker read as parked"
  st=0; fm_park_status "$home/state" none || st=$?
  [ "$st" -eq 1 ] || fail "absent marker returned $st, expected 1"

  f="$home/state/bad.parked"
  printf 'nonsense\n' > "$f"; chmod 0700 "$f"
  st=0; fm_park_status "$home/state" bad || st=$?
  [ "$st" -eq 2 ] || fail "bad content returned $st, expected 2"
  printf 'parked [at=1]: ok\n' > "$f"; chmod 0644 "$f"
  st=0; fm_park_status "$home/state" bad || st=$?
  [ "$st" -eq 2 ] || fail "wrong mode returned $st, expected 2"
  chmod 0700 "$f"; ln "$f" "$home/state/other-link"
  st=0; fm_park_status "$home/state" bad || st=$?
  [ "$st" -eq 2 ] || fail "extra hard link returned $st, expected 2"
  rm -f "$home/state/other-link"
  printf 'parked [at=1]: a\nparked [at=2]: b\n' > "$f"; chmod 0700 "$f"
  st=0; fm_park_status "$home/state" bad || st=$?
  [ "$st" -eq 2 ] || fail "two lines returned $st, expected 2"
  printf 'parked [at=1]:    \n' > "$f"
  st=0; fm_park_status "$home/state" bad || st=$?
  [ "$st" -eq 2 ] || fail "blank reason returned $st, expected 2"
  rm -f "$f"; ln -s /etc/hostname "$f"
  st=0; fm_park_status "$home/state" bad || st=$?
  [ "$st" -eq 2 ] || fail "symlink returned $st, expected 2"
  out=$(run_park "$home" list); st=$?
  [ "$st" -eq 3 ] || fail "list of a bad marker exited $st, expected 3"
  assert_contains "$out" "ERROR" "list did not flag the bad marker"
  pass "a malformed or unsafe marker returns an error status, never absent"
}

make_spawn_world() {  # <name> <id>
  local name=$1 id=$2 case_dir home primary proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise the park marker clear for $id."
  printf '%s\n' "$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <id> [pane-path]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="${6:-$wt}" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1
}

test_successful_spawn_clears_the_marker() {
  local rec home proj wt fakebin id out status
  id=park-spawn-z1
  rec=$(make_spawn_world spawn-clear "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  fm_test_fake_sleep_noop "$fakebin"
  printf 'paused: waiting for firstmate\n' > "$home/state/$id.status"
  printf 'parked [at=1700000000]: queued\n' > "$home/state/$id.parked"
  chmod 0700 "$home/state/$id.parked"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id"); status=$?
  expect_code 0 "$status" "spawn should succeed"$'\n'"$out"
  [ ! -e "$home/state/$id.parked" ] || fail "a successful spawn left the park marker"
  [ "$(cat "$home/state/$id.status")" = 'paused: waiting for firstmate' ] || fail "spawn rewrote the worker's status file through the park path"
  pass "a successful spawn clears the park marker"
}

test_refused_spawn_keeps_the_marker() {
  local rec home proj wt fakebin id out status
  id=park-spawn-z2
  rec=$(make_spawn_world spawn-refused "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  fm_test_fake_sleep_noop "$fakebin"
  printf 'parked [at=1700000000]: queued\n' > "$home/state/$id.parked"
  chmod 0700 "$home/state/$id.parked"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$proj"); status=$?
  [ "$status" -ne 0 ] || fail "spawn into the primary checkout succeeded"$'\n'"$out"
  [ -e "$home/state/$id.parked" ] || fail "a refused spawn cleared the park marker"
  pass "a refused spawn keeps the park marker"
}

test_park_writes_a_private_single_link_marker_and_leaves_status_alone
test_park_refuses_unsafe_input
test_reader_never_reads_a_bad_marker_as_absent
test_successful_spawn_clears_the_marker
test_refused_spawn_keeps_the_marker

echo "# all fm-park tests passed"
