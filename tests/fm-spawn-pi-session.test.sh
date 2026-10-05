#!/usr/bin/env bash
# The Pi session contract: a fresh pi/pi-signed ship or scout opens a session
# scoped to THIS incarnation, `--session-id <task-id>.<spawn-gen>`, and the task
# record carries that same value as pi_session_id= so a relaunch can resume it.
#
# Pinned here, hermetically (fake tmux/treehouse, a stub pi answering --help):
#   1. A fresh pi ship spawn records pi_session_id= and launches the same id.
#   2. A fresh pi-signed spawn does the same under its own executable name.
#   3. A fresh pi scout records it too.
#   4. A secondmate on pi does neither: its session lifecycle is its own
#      home's, and the incarnation-scoped id is a crewmate/scout contract.
#   5. Re-spawning the same task id into the same copy path after teardown gets
#      a DIFFERENT session, so it cannot inherit the abandoned attempt's turns.
#
# The relaunch half of the contract - resuming the recorded id when the
# endpoint is gone or agent-free - is pinned by tests/fm-control-relaunch.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pi-session)

# new_case <name> <crew-harness> [pi-executable-name] -> sets the case globals.
# The stub <pi-executable-name> exists only to answer the launch's `--help`
# version probe; the launch itself is never executed, so every assertion reads
# the composed launch line from the fake tmux's FM_FAKE_LAUNCH_LOG.
new_case() {
  local name=$1 harness=$2 bin_name=${3:-pi}
  CASE="$TMP_ROOT/$name"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  cat > "$FAKEBIN/$bin_name" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --help) printf '%s\n' 'Options: --tui-mode <mode> --session-id <id>'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/$bin_name"
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_worktree "$PROJ" "$WT" "wt-$name"
  : > "$CASE/launch.log"
}

spawn_ship() {  # <id> [fm-spawn args...]
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" \
    --mode no-mistakes --yolo off "$@"
}

meta_field() {  # <id> <key>
  grep "^$2=" "$HOME_DIR/state/$1.meta" | tail -1 | cut -d= -f2-
}

test_fresh_pi_ship_spawn_records_and_runs_its_own_session() {
  local out rc recorded id=pi-s1
  new_case fresh-pi pi
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a fresh pi ship spawn should succeed"$'\n'"$out"
  recorded=$(meta_field "$id" pi_session_id)
  case "$recorded" in
    "$id".?*) ;;
    *) fail "the task record must carry an incarnation-scoped pi_session_id under $id, got '$recorded'" ;;
  esac
  assert_contains "$(cat "$CASE/launch.log")" "--session-id '$recorded'" \
    "the launch must run exactly the session id the record names"
  assert_not_contains "$(cat "$CASE/launch.log")" "--session '" \
    "a fresh spawn has no runtime reference to resume"
  pass "fm-spawn: a fresh pi ship runs the task's own persistent session and records it"
}

test_fresh_pi_signed_ship_spawn_records_and_runs_its_own_session() {
  local out rc recorded id=pi-signed-s1
  new_case fresh-pi-signed pi-signed pi-signed
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a fresh pi-signed ship spawn should succeed"$'\n'"$out"
  recorded=$(meta_field "$id" pi_session_id)
  case "$recorded" in
    "$id".?*) ;;
    *) fail "the task record must carry an incarnation-scoped pi_session_id under $id, got '$recorded'" ;;
  esac
  assert_contains "$(cat "$CASE/launch.log")" "--session-id '$recorded'" \
    "the signed wrapper's launch must run exactly the session id the record names"
  pass "fm-spawn: a fresh pi-signed ship runs the task's own persistent session and records it"
}

test_fresh_pi_scout_spawn_records_and_runs_its_own_session() {
  local out rc recorded id=pi-scout1
  new_case fresh-pi-scout pi
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --scout); rc=$?
  expect_code 0 "$rc" "a fresh pi scout spawn should succeed"$'\n'"$out"
  recorded=$(meta_field "$id" pi_session_id)
  case "$recorded" in
    "$id".?*) ;;
    *) fail "the scout record must carry an incarnation-scoped pi_session_id under $id, got '$recorded'" ;;
  esac
  assert_contains "$(cat "$CASE/launch.log")" "--session-id '$recorded'" \
    "the scout launch must run exactly the session id the record names"
  pass "fm-spawn: a fresh pi scout runs the task's own persistent session and records it"
}

# The regression review-25 reported: a task torn down and re-spawned under the
# same id lands in whatever copy path the pool hands out, which can be the one
# the abandoned attempt used. If the session id were the bare task id, Pi would
# recall that attempt's turns while the freshened worktree holds none of its
# work. Teardown removes state/<id>.meta, so the second spawn is an ordinary
# FRESH spawn - and it must select a session of its own.
test_respawn_after_teardown_does_not_inherit_the_previous_session() {
  local out rc id=pi-respawn first second second_launch
  new_case respawn-pi pi
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "the first fresh spawn should succeed"$'\n'"$out"
  first=$(meta_field "$id" pi_session_id)
  [ -n "$first" ] || fail "the first spawn recorded no pi_session_id"

  # What bin/fm-teardown.sh leaves behind: the task record is gone, the copy
  # path and the task id are free to be handed out again.
  rm -f "$HOME_DIR/state/$id.meta"
  : > "$CASE/launch.log"

  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "the re-spawn after teardown should succeed"$'\n'"$out"
  second=$(meta_field "$id" pi_session_id)
  second_launch=$(cat "$CASE/launch.log")
  [ -n "$second" ] || fail "the re-spawn recorded no pi_session_id"

  [ "$first" != "$second" ] \
    || fail "the re-spawn reused session id '$second', so it would recall the torn-down attempt"
  assert_contains "$second_launch" "--session-id '$second'" \
    "the re-spawn launch must run exactly the session id its own record names"
  assert_not_contains "$second_launch" "--session-id '$first'" \
    "the re-spawn launch must not select the abandoned attempt's session"
  pass "fm-spawn: re-spawning a torn-down task id opens a new Pi session, not the abandoned one"
}

test_pi_secondmate_spawn_gets_no_incarnation_session() {
  local out rc id=pi-sm1 sm
  new_case fresh-pi-sm pi
  printf 'pi\n' > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/config" "$sm/state" "$sm/projects"
  git init -q -b main "$sm"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate); rc=$?
  expect_code 0 "$rc" "a pi secondmate spawn should succeed"$'\n'"$out"
  [ -z "$(meta_field "$id" pi_session_id)" ] \
    || fail "a secondmate record must not carry an incarnation-scoped session id"
  assert_not_contains "$(cat "$CASE/launch.log")" "--session-id" \
    "a secondmate owns its session lifecycle; the incarnation-scoped id is not passed"
  pass "fm-spawn: a pi secondmate keeps its own session lifecycle, with no incarnation-scoped id"
}

test_fresh_pi_ship_spawn_records_and_runs_its_own_session
test_fresh_pi_signed_ship_spawn_records_and_runs_its_own_session
test_fresh_pi_scout_spawn_records_and_runs_its_own_session
test_pi_secondmate_spawn_gets_no_incarnation_session
test_respawn_after_teardown_does_not_inherit_the_previous_session
