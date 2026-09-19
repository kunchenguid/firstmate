#!/usr/bin/env bash
# Behavior tests for the per-project spawn setup hook bin/fm-spawn.sh runs
# before it launches a worker into a freshly allocated worktree.
#
# Every case drives the REAL fm-spawn against a fake terminal and a real git
# worktree, so what is proved is the launch outcome an operator sees: whether
# the worker started, whether the project's own provisioning actually ran in the
# right directory with the right environment, and what a broken hook refuses
# without leaving behind.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-setup-hook)

# One case: a firstmate home, a project clone with a local origin, a worktree
# the fake pane reports itself sitting in, and a fakebin. The project directory
# is always named "project", so config/spawn-setup/project is the hook every
# case installs and no case depends on a name the fixture picked.
make_case() { # <name> <id> [harness]
  local name=$1 id=$2 harness=${3:-codex} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude codex)
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  mkdir -p "$home/config/spawn-setup"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# Install the hook this home would run for the case's project.
write_hook() { # <body>
  cat > "$HOME_DIR/config/spawn-setup/project"
  chmod +x "$HOME_DIR/config/spawn-setup/project"
}

# A hook that records where it ran and what it was told, outside the worktree so
# the recording itself can never be what dirties the tree under test.
write_recording_hook() {
  write_hook <<EOF
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'pwd=%s\n' "\$PWD"
  printf 'task=%s\n' "\${FM_TASK_ID:-unset}"
  printf 'kind=%s\n' "\${FM_TASK_KIND:-unset}"
  printf 'project=%s\n' "\${FM_PROJECT:-unset}"
  printf 'worktree=%s\n' "\${FM_WORKTREE:-unset}"
} > "$CASE_DIR/hook-ran"
EOF
}

run_spawn() { # <id> [spawn args...]
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

run_ship() { # <id> [extra args...]
  local id=$1
  shift
  run_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@"
}

test_absent_hook_launches_silently() {
  local rec id out status
  id='setup-absent-r1'
  rec=$(make_case absent "$id")
  read_case_record "$rec"

  out=$(run_ship "$id")
  status=$?
  expect_code 0 "$status" "a project with no setup hook should launch"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the unconfigured spawn did not report success"
  assert_not_contains "$out" "setup hook" \
    "a project with no setup hook was told about hooks it has not configured"
  pass "a project with no setup hook launches with nothing said about setup"
}

test_hook_provisions_the_worktree_before_the_worker_starts() {
  local rec id out status kind
  # Scouts provision exactly like ship tasks: a scout that cannot run the
  # project's tests is no more useful than a worker that cannot build it.
  for kind in ship scout; do
    id="setup-runs-$kind-r1"
    rec=$(make_case "runs-$kind" "$id")
    read_case_record "$rec"
    write_recording_hook

    if [ "$kind" = scout ]; then
      out=$(run_spawn "$id" "$PROJ_DIR" --scout)
    else
      out=$(run_ship "$id")
    fi
    status=$?
    expect_code 0 "$status" "a $kind spawn with a working setup hook should launch"$'\n'"$out"
    assert_contains "$out" "spawned $id" "the provisioned $kind spawn did not report success"
    assert_present "$CASE_DIR/hook-ran" "the setup hook did not run for a $kind spawn"
    assert_grep "pwd=$WT_DIR" "$CASE_DIR/hook-ran" \
      "the setup hook did not run in the task worktree for a $kind spawn"
    assert_grep "task=$id" "$CASE_DIR/hook-ran" \
      "the setup hook was not told which task it was provisioning"
    assert_grep "kind=$kind" "$CASE_DIR/hook-ran" \
      "the setup hook was not told the task kind"
    assert_grep "project=$PROJ_DIR" "$CASE_DIR/hook-ran" \
      "the setup hook was not told the project clone this home spawns from"
    assert_grep "worktree=$WT_DIR" "$CASE_DIR/hook-ran" \
      "the setup hook was not told the worktree path"
    assert_present "$HOME_DIR/state/$id.meta" "the provisioned $kind spawn published no record"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# %s spawn with setup hook\n%s\n' "$kind" "$out"
      printf '# what the hook recorded\n'; cat "$CASE_DIR/hook-ran"
    fi
  done
  pass "a configured setup hook provisions the task worktree for both ship and scout spawns"
}

test_failing_hook_refuses_the_spawn_and_keeps_its_log() {
  local rec id out status log
  id='setup-fails-r1'
  rec=$(make_case fails "$id")
  read_case_record "$rec"
  # A hook interrupted partway through is the likeliest to have already written
  # an unignored path, and clearing that path is the first thing a retry of this
  # task id needs: the next spawn handed this pool slot is refused by the base
  # refresh until it is gone. So this refusal has to name it too.
  write_hook <<'HOOK'
#!/usr/bin/env bash
echo 'installing dependencies'
printf '{}\n' > .lsp-mcp.json
echo 'lockfile does not match the store' >&2
exit 3
HOOK

  out=$(run_ship "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched a worker after its setup hook failed"$'\n'"$out"
  assert_contains "$out" "failed (exit 3)" "the refusal did not name the hook's exit status"
  assert_contains "$out" "refusing to launch a worker into an unprovisioned worktree" \
    "the refusal did not explain why an unprovisioned worktree is not launched into"
  assert_contains "$out" "lockfile does not match the store" \
    "the refusal did not show what the project's own setup script reported"
  assert_contains "$out" ".lsp-mcp.json" \
    "the refusal did not name the unignored file the interrupted hook left to be cleared"
  assert_present "$WT_DIR/.lsp-mcp.json" \
    "the refusal deleted the file the failed hook left behind"
  assert_not_contains "$out" "spawned $id" "a refused spawn still reported success"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn published task metadata"
  assert_absent "$HOME_DIR/state/$id.status" "a refused spawn left a status record"
  # The excerpt is bounded, so the complete log has to survive for diagnosis.
  log=$(printf '%s\n' "$out" | sed -n 's/.*complete output kept at \(.*\) ---.*/\1/p' | tail -n 1)
  [ -n "$log" ] || fail "the refusal did not name a kept hook log"$'\n'"$out"
  assert_present "$log" "the refusal named a hook log that was not kept"
  assert_grep 'installing dependencies' "$log" "the kept hook log lost the hook's own output"
  pass "a failing setup hook refuses the spawn, shows the project's error, and keeps the full log"
}

test_signal_killed_hook_refuses_the_spawn() {
  local rec id out status
  id='setup-signal-r1'
  rec=$(make_case signal "$id")
  read_case_record "$rec"
  # A setup script killed by the OOM killer or a segfault leaves the worktree
  # just as unprovisioned as one that exits nonzero, and leaves no trace git
  # can see because everything half-written lives in ignored paths. The refusal
  # therefore rests entirely on the status fm_run_timed reports for a signal
  # death, which is the contract tests/fm-timeout-lib.test.sh pins.
  write_hook <<'HOOK'
#!/usr/bin/env bash
echo 'installing dependencies'
kill -9 $$
HOOK

  out=$(run_ship "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched a worker after its setup hook was killed by a signal"$'\n'"$out"
  assert_contains "$out" "refusing to launch a worker into an unprovisioned worktree" \
    "a hook killed by a signal did not refuse the way a hook that exits nonzero does"
  assert_not_contains "$out" "spawned $id" "a refused spawn still reported success"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn published task metadata"
  pass "a setup hook killed by a signal refuses the spawn instead of launching into it"
}

test_hook_that_dirties_the_worktree_refuses() {
  local rec id out status log
  id='setup-dirty-r1'
  rec=$(make_case dirty "$id")
  read_case_record "$rec"
  write_hook <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
echo 'recording machine notes for this checkout'
printf 'local machine notes\n' > workspace-notes.txt
HOOK

  out=$(run_ship "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a worktree its setup hook left dirty"$'\n'"$out"
  assert_contains "$out" "left files git does not ignore" \
    "the refusal did not name the rule the hook broke"
  assert_contains "$out" "workspace-notes.txt" "the refusal did not name the offending path"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn published task metadata"
  # This is the refusal where the hook's own output says which provisioning step
  # wrote the unignored path, so the log has to survive it like any other.
  log=$(printf '%s\n' "$out" | sed -n 's/.*complete output kept at \(.*\) ---.*/\1/p' | tail -n 1)
  [ -n "$log" ] || fail "the dirty-worktree refusal did not name a kept hook log"$'\n'"$out"
  assert_present "$log" "the dirty-worktree refusal named a hook log that was not kept"
  assert_grep 'recording machine notes' "$log" \
    "the kept hook log lost what the hook printed while dirtying the worktree"
  # Untracked work is never destroyed to make a spawn proceed, not even the
  # hook's own; the operator decides what that file was.
  assert_present "$WT_DIR/workspace-notes.txt" \
    "the refusal deleted the file the hook left behind"
  pass "a setup hook that leaves unignored files refuses the spawn without deleting them"
}

test_hook_writing_only_ignored_paths_launches() {
  local rec id out status
  id='setup-ignored-r1'
  rec=$(make_case ignored "$id")
  read_case_record "$rec"
  printf '.worktree-env\n' > "$PROJ_DIR/.gitignore"
  git -C "$PROJ_DIR" add .gitignore
  git -C "$PROJ_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'ignore generated worktree environment'
  git -C "$PROJ_DIR" push --quiet origin main
  write_hook <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
printf '{"web_port":3070}\n' > .worktree-env
HOOK

  out=$(run_ship "$id")
  status=$?
  expect_code 0 "$status" "a hook writing only ignored paths should launch"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the provisioned spawn did not report success"
  assert_grep 'web_port' "$WT_DIR/.worktree-env" \
    "the launched worktree lost what the hook provisioned"
  pass "a setup hook writing only ignored paths provisions the worktree and launches"
}

test_unusable_hook_refuses_rather_than_skipping() {
  local rec id out status shape
  # A hook the captain configured and firstmate then skipped is the exact
  # failure the hook exists to remove, so no shape may pass silently. The
  # refusal must also say what is wrong with the hook on its own: leaving that
  # to exec failure reports a forgotten chmod +x as a bare "exit 255" with an
  # empty log wherever fm_run_timed falls through to its perl mechanism, which
  # is any host without coreutils.
  for shape in not-executable dangling-symlink directory; do
    id="setup-unusable-${shape}-r1"
    rec=$(make_case "unusable-$shape" "$id")
    read_case_record "$rec"
    case "$shape" in
    not-executable)
      printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_DIR/config/spawn-setup/project"
      chmod 644 "$HOME_DIR/config/spawn-setup/project"
      ;;
    dangling-symlink)
      ln -s "$CASE_DIR/setup-script-that-moved" "$HOME_DIR/config/spawn-setup/project"
      ;;
    directory)
      mkdir -p "$HOME_DIR/config/spawn-setup/project"
      ;;
    esac

    out=$(run_ship "$id")
    status=$?
    [ "$status" -ne 0 ] || fail "spawn skipped a configured but unusable setup hook ($shape)"$'\n'"$out"
    assert_contains "$out" "is not a runnable file" \
      "the refusal did not name what is wrong with the hook ($shape)"
    assert_contains "$out" "chmod +x it" \
      "the refusal did not tell the operator how to fix the hook ($shape)"
    assert_contains "$out" "refusing to launch a worker into an unprovisioned worktree" \
      "the refusal did not explain why an unprovisioned worktree is not launched into ($shape)"
    assert_not_contains "$out" "spawned $id" "a refused spawn still reported success ($shape)"
    assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn published task metadata ($shape)"
  done
  pass "a configured but unusable setup hook refuses by name instead of being skipped"
}

test_hook_named_for_another_project_is_not_run() {
  local rec id out status
  id='setup-other-project-r1'
  rec=$(make_case other-project "$id")
  read_case_record "$rec"
  cat > "$HOME_DIR/config/spawn-setup/some-other-project" <<EOF
#!/usr/bin/env bash
touch "$CASE_DIR/wrong-hook-ran"
EOF
  chmod +x "$HOME_DIR/config/spawn-setup/some-other-project"

  out=$(run_ship "$id")
  status=$?
  expect_code 0 "$status" "a project with no hook of its own should launch"$'\n'"$out"
  assert_absent "$CASE_DIR/wrong-hook-ran" \
    "the spawn ran a hook belonging to a different project"
  pass "a hook named for another project is never run for this one"
}

test_skip_switch_accepts_only_off() {
  local rec id out status
  id='setup-skip-r1'
  rec=$(make_case skip "$id")
  read_case_record "$rec"
  write_recording_hook

  out=$(FM_SPAWN_SETUP=off run_ship "$id")
  status=$?
  expect_code 0 "$status" "the documented skip should still launch the worker"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the skipped-setup spawn did not report success"
  assert_contains "$out" "unprovisioned worktree" \
    "skipping setup was not reported as a consequence the operator should know about"
  assert_absent "$CASE_DIR/hook-ran" "the skip switch did not actually skip the hook"

  id='setup-skip-bad-value-r1'
  rec=$(make_case skip-bad-value "$id")
  read_case_record "$rec"
  write_recording_hook

  out=$(FM_SPAWN_SETUP=0 run_ship "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "an unrecognized skip value silently provisioned anyway"$'\n'"$out"
  assert_contains "$out" "the only accepted value is off" \
    "the refusal did not name the value the switch accepts"
  assert_absent "$CASE_DIR/hook-ran" "a refused skip value still ran the hook"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn published task metadata"
  pass "the setup skip switch honors off and refuses any other value"
}

test_hook_exceeding_its_bound_refuses() {
  local rec id out status
  id='setup-bound-r1'
  rec=$(make_case bound "$id")
  read_case_record "$rec"
  write_hook <<'HOOK'
#!/usr/bin/env bash
sleep 60
HOOK

  out=$(FM_SPAWN_SETUP_TIMEOUT=1 run_ship "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched after its setup hook ran past its bound"$'\n'"$out"
  assert_contains "$out" "did not finish within 1s" \
    "the refusal did not name the bound that was hit, so the override was not honored"
  assert_contains "$out" "half-provisioned worktree" \
    "the refusal did not explain what a hook killed mid-run leaves behind"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn published task metadata"
  pass "a setup hook that runs past the configured bound is killed and refuses the spawn"
}

test_an_unusable_bound_falls_back_instead_of_reaching_the_timeout_tool() {
  local rec id out status
  id='setup-bound-invalid-r1'
  rec=$(make_case bound-invalid "$id")
  read_case_record "$rec"
  # A value the bound cannot use must become the default rather than reach
  # fm_run_timed, where a non-numeric bound errors and a zero one silently
  # disables the deadline the lock depends on.
  write_recording_hook

  out=$(FM_SPAWN_SETUP_TIMEOUT=not-a-number run_ship "$id")
  status=$?
  expect_code 0 "$status" "an unusable setup bound should fall back and still provision"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the spawn with an unusable bound did not report success"
  assert_present "$CASE_DIR/hook-ran" "an unusable bound stopped the hook from running at all"
  assert_not_contains "$out" "did not finish within" \
    "an unusable bound was passed through instead of falling back to the default"
  pass "a setup bound that is not a positive integer falls back to the default"
}

# The ordering this pins is load-bearing rather than cosmetic: a project's own
# setup commonly syncs a main checkout's .claude/ into the worktree, and
# firstmate's launch settings carry the worker's own supervision wiring. The
# hook must therefore run first and be overwritten, never the other way round.
test_hook_runs_before_the_worker_launch_settings_are_written() {
  local rec id out status settings
  id='setup-claude-order-r1'
  rec=$(make_case claude-order "$id" claude)
  read_case_record "$rec"
  printf '.claude/\n' > "$PROJ_DIR/.gitignore"
  git -C "$PROJ_DIR" add .gitignore
  git -C "$PROJ_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'ignore local claude settings'
  git -C "$PROJ_DIR" push --quiet origin main
  write_hook <<EOF
#!/usr/bin/env bash
set -euo pipefail
mkdir -p .claude
printf '{"copiedFromAnotherCheckout":true}\n' > .claude/settings.local.json
cp .claude/settings.local.json "$CASE_DIR/hook-wrote-settings"
EOF

  out=$(run_ship "$id" --harness claude)
  status=$?
  expect_code 0 "$status" "a claude spawn with a setup hook should launch"$'\n'"$out"
  settings="$WT_DIR/.claude/settings.local.json"
  assert_present "$settings" "the claude spawn wrote no launch settings"
  # Without this the case would pass vacuously on a hook that never ran at all.
  assert_grep 'copiedFromAnotherCheckout' "$CASE_DIR/hook-wrote-settings" \
    "the hook never wrote the settings this case is about, so the ordering was not exercised"
  assert_no_grep 'copiedFromAnotherCheckout' "$settings" \
    "the setup hook's copied settings survived and replaced firstmate's worker wiring"
  assert_grep 'hooks' "$settings" "the launched worker's settings carry no hook wiring"
  pass "a setup hook runs before the worker's launch settings, so it cannot replace them"
}

# Provisioning steps are machine-local and each home's pool is its own, so a
# secondmate must not inherit hooks written for the primary's clones: one
# inherited hook would hard-stop every spawn in a home whose pool it does not
# describe. The primary-to-secondmate copy is where that would happen.
test_hooks_are_not_inherited_into_a_secondmate_home() {
  local d src dest
  d="$TMP_ROOT/inheritance"
  src="$d/primary-config"
  dest="$d/secondmate-home/config"
  mkdir -p "$src/spawn-setup" "$dest"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$src/spawn-setup/her-web"
  chmod +x "$src/spawn-setup/her-web"
  printf 'codex\n' > "$src/crew-harness"

  propagate_inheritable_config "$src" "$dest" \
    || fail "propagating the primary's shared configuration returned non-zero"

  assert_present "$dest/crew-harness" \
    "the fixture did not actually propagate anything, so the case proves nothing"
  assert_absent "$dest/spawn-setup" \
    "a secondmate home inherited setup hooks written for another home's pool"
  pass "setup hooks stay with the home that wrote them and are never inherited"
}

test_absent_hook_launches_silently
test_hooks_are_not_inherited_into_a_secondmate_home
test_hook_provisions_the_worktree_before_the_worker_starts
test_hook_writing_only_ignored_paths_launches
test_failing_hook_refuses_the_spawn_and_keeps_its_log
test_signal_killed_hook_refuses_the_spawn
test_hook_that_dirties_the_worktree_refuses
test_unusable_hook_refuses_rather_than_skipping
test_hook_named_for_another_project_is_not_run
test_skip_switch_accepts_only_off
test_hook_exceeding_its_bound_refuses
test_an_unusable_bound_falls_back_instead_of_reaching_the_timeout_tool
test_hook_runs_before_the_worker_launch_settings_are_written

echo "# all fm-spawn-setup-hook tests passed"
