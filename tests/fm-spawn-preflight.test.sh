#!/usr/bin/env bash
# Behavior tests for the home-owned spawn preflight hook ($FM_HOME/config/spawn-preflight).
#
# A home may install an executable preflight (e.g. a free-disk guard). A non-zero
# exit must refuse the spawn before any endpoint, worktree record or meta exists;
# a zero exit must let the spawn proceed, and the hook receives the task id.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-preflight)

make_case() { # <name> <id> -> "home|wt|fakebin|launchlog|project"
  local case_dir="$TMP_ROOT/$1" home proj wt fakebin
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$1"
  fm_test_spawn_brief "$home" "$2"
  printf '%s|%s|%s|%s|%s\n' "$home" "$wt" "$fakebin" "$case_dir/launch.log" "$proj"
}

write_preflight() { # <home> <exit-code>
  cat > "$1/config/spawn-preflight" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" > "$1/preflight.arg"
echo "disk guard: test says $2"
exit $2
SH
  chmod +x "$1/config/spawn-preflight"
}

run() { # <home> <wt> <fakebin> <launchlog> <id> <project>
  : > "$4"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$4" \
    fm_test_run_spawn "$1" "$2" "$3" "$5" "$6" --mode no-mistakes --yolo off 2>&1
}

test_failing_preflight_refuses_before_any_record() {
  local id=preflight-refuse-z1 home wt fakebin log proj out status
  IFS='|' read -r home wt fakebin log proj <<<"$(make_case refuse "$id")"
  write_preflight "$home" 3
  out=$(run "$home" "$wt" "$fakebin" "$log" "$id" "$proj")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded although the preflight exited 3"
  assert_contains "$out" "refused by $home/config/spawn-preflight" "refusal did not name the preflight"
  assert_contains "$out" "disk guard: test says 3" "preflight output was not surfaced"
  [ ! -e "$home/state/$id.meta" ] || fail "a refused spawn wrote $id.meta"
  [ ! -s "$log" ] || fail "a refused spawn still launched a harness"
  [ "$(cat "$home/preflight.arg")" = "$id" ] || fail "preflight did not receive the task id"
  pass "a failing spawn-preflight refuses before any meta or launch"
}

test_passing_preflight_lets_spawn_proceed() {
  local id=preflight-pass-z1 home wt fakebin log proj out status
  IFS='|' read -r home wt fakebin log proj <<<"$(make_case pass "$id")"
  write_preflight "$home" 0
  out=$(run "$home" "$wt" "$fakebin" "$log" "$id" "$proj")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the preflight passes"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ -e "$home/state/$id.meta" ] || fail "passing preflight: no meta written"
  pass "a passing spawn-preflight lets the spawn proceed"
}


test_failing_preflight_covers_scout_and_secondmates() {
  local kind id home wt fakebin log proj out status child
  for kind in scout local remote; do
    id="preflight-$kind-z1"
    IFS='|' read -r home wt fakebin log proj <<<"$(make_case "$kind" "$id")"
    write_preflight "$home" 3
    child="$(dirname "$home")/secondmate"
    case "$kind" in
      scout)
        out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout)
        status=$?
        ;;
      local)
        mkdir -p "$child/bin" "$child/data"
        printf '# Firstmate\n' > "$child/AGENTS.md"
        printf '%s\n' "$id" > "$child/.fm-secondmate-home"
        printf 'child captain\n' > "$child/data/captain-shared.md"
        printf 'parent captain\n' > "$home/data/captain-shared.md"
        out=$(FM_SKIP_SECONDMATE_SYNC=1 fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$child" claude --secondmate)
        status=$?
        [ ! -e "$child/state" ] || fail "preflight refusal created secondmate state"
        [ "$(cat "$child/data/captain-shared.md")" = 'child captain' ] || fail "preflight refusal propagated secondmate inheritance"
        ;;
      remote)
        printf -- '- %s - remote domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote work; projects: alpha; added 2026-08-02)\n' "$id" > "$home/data/secondmates.md"
        cat > "$fakebin/ssh" <<SH
#!/usr/bin/env bash
printf 'ssh\n' >> "$home/ssh.log"
exit 1
SH
        chmod +x "$fakebin/ssh"
        out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" --secondmate)
        status=$?
        [ ! -e "$home/ssh.log" ] || fail "preflight refusal contacted the remote host"
        ;;
    esac
    [ "$status" -ne 0 ] || fail "$kind spawn succeeded with a failing preflight"
    assert_contains "$out" "refused by $home/config/spawn-preflight" "$kind spawn bypassed preflight"
    [ "$(cat "$home/preflight.arg")" = "$id" ] || fail "$kind preflight received the wrong id"
    [ ! -e "$home/state/$id.meta" ] || fail "$kind preflight refusal published a task"
  done
  pass "failing preflight refuses scouts and local or remote secondmates before mutation"
}

test_batch_preflight_runs_for_each_new_task() {
  local id=preflight-batch-z1 other=preflight-batch-z2 home wt fakebin log proj out status
  IFS='|' read -r home wt fakebin log proj <<<"$(make_case batch "$id")"
  fm_test_spawn_brief "$home" "$other"
  write_preflight "$home" 3
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id=$proj" "$other=$proj" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "batch succeeded with a failing preflight"
  assert_contains "$out" "spawn of $id refused by" "first batch task bypassed preflight"
  assert_contains "$out" "spawn of $other refused by" "second batch task bypassed preflight"
  [ ! -e "$home/state/$id.meta" ] && [ ! -e "$home/state/$other.meta" ] || fail "batch refusal published a task"
  pass "batch dispatch checks preflight for every new task"
}

test_failing_preflight_refuses_before_any_record
test_passing_preflight_lets_spawn_proceed

test_failing_preflight_covers_scout_and_secondmates
test_batch_preflight_runs_for_each_new_task

echo "# all fm-spawn-preflight tests passed"
