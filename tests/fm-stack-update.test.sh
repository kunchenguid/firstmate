#!/usr/bin/env bash
# Tests for bin/fm-stack-update.sh: the stack step of /updatefirstmate.
#
# The guarantees under test:
#   - Every stack tool is updated through its own update path, and tasks-axi,
#     whose `update` verb edits a backlog task, goes through npm instead.
#   - The per-tool verdict comes from the version before and after, so an
#     advance reports old..new and an unchanged tool reports already current.
#   - The shared no-mistakes daemon is never forced: no --force or --yes, and
#     its own refusal while pipeline runs are active is reported as deferred.
#   - A missing tool, a failed or timed-out update, and a tasks-axi copy that
#     npm does not own are reported as skipped rather than worked around.
#
# Every tool is a fake in a fixture PATH that hides the real stack tools, so no
# case ever probes, updates, or otherwise touches a tool installed on this host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STACK_UPDATE="$ROOT/bin/fm-stack-update.sh"
TMP_ROOT=$(fm_test_tmproot fm-stack-update-tests)
STACK_TOOLS="no-mistakes treehouse gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi"
# shellcheck disable=SC2086
BASE_PATH=$(fm_test_base_path_sans "${FM_TEST_BASE_PATH:-/usr/bin:/bin}" $STACK_TOOLS npm)

# A fake stack tool. It prints `<name> version v<version>` from its state file,
# logs every other invocation with its arguments, and on `update` (or, for
# tasks-axi, npm's install) behaves as its mode file says:
#   bump    the version file takes the .next version
#   same    nothing changes
#   refuse  no-mistakes' own refusal while pipeline runs are active
#   fail    a failed update
#   slow    an update that outlives the bound
write_fake_tool() {  # <path> <name>
  cat > "$1" <<SH
#!/usr/bin/env bash
name=$2
SH
  cat >> "$1" <<'SH'
if [ "${1:-}" = --version ]; then
  printf '%s version v%s\n' "$name" "$(cat "$FM_FAKE_DIR/$name.version")"
  exit 0
fi
printf '%s %s\n' "$name" "$*" >> "$FM_FAKE_DIR/calls"
[ "${1:-}" = update ] || exit 0
exec "$FM_FAKE_DIR/apply" "$name"
SH
  chmod +x "$1"
}

new_world() {  # <name> -> world dir
  local w="$TMP_ROOT/$1" tool
  mkdir -p "$w/fakebin" "$w/fake/npmroot/tasks-axi/bin"
  : > "$w/fake/calls"
  cat > "$w/fake/apply" <<'SH'
#!/usr/bin/env bash
name=$1
case "$(cat "$FM_FAKE_DIR/$name.mode" 2>/dev/null || echo bump)" in
  bump) cp "$FM_FAKE_DIR/$name.next" "$FM_FAKE_DIR/$name.version"; echo "updated $name" ;;
  same) echo "$name is already up to date" ;;
  refuse) echo "Error: refusing update because 1 active pipeline runs are in progress; pass --force to stop/restart the daemon anyway" >&2; exit 1 ;;
  fail) echo "Error: download failed: registry unreachable" >&2; exit 1 ;;
  slow) sleep 5 ;;
esac
SH
  chmod +x "$w/fake/apply"
  for tool in $STACK_TOOLS; do
    printf '1.0.0\n' > "$w/fake/$tool.version"
    printf '1.1.0\n' > "$w/fake/$tool.next"
    if [ "$tool" = tasks-axi ]; then
      write_fake_tool "$w/fake/npmroot/tasks-axi/bin/tasks-axi" tasks-axi
      ln -s "$w/fake/npmroot/tasks-axi/bin/tasks-axi" "$w/fakebin/tasks-axi"
    else
      write_fake_tool "$w/fakebin/$tool" "$tool"
    fi
  done
  cat > "$w/fakebin/npm" <<'SH'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >> "$FM_FAKE_DIR/calls"
case "$*" in
  "root -g") printf '%s\n' "$FM_FAKE_DIR/npmroot" ;;
  "install -g tasks-axi@latest") exec "$FM_FAKE_DIR/apply" tasks-axi ;;
esac
SH
  chmod +x "$w/fakebin/npm"
  printf '%s\n' "$w"
}

run_stack_update() {  # <world> [env...]
  local w=$1
  shift
  env "$@" FM_FAKE_DIR="$w/fake" PATH="$w/fakebin:$BASE_PATH" bash "$STACK_UPDATE"
}

test_every_tool_updates_through_its_own_path() {
  local w out tool
  w=$(new_world all-bump)
  out=$(run_stack_update "$w") || fail "the stack update exited nonzero: $out"
  for tool in $STACK_TOOLS; do
    assert_contains "$out" "$tool: updated 1.0.0..1.1.0" "$tool reports its advance"
  done
  grep -Fxq 'npm install -g tasks-axi@latest' "$w/fake/calls" || fail "tasks-axi did not update through npm"
  assert_no_grep 'tasks-axi update' "$w/fake/calls" "tasks-axi's update verb edits a backlog task and must never be called"
  for tool in no-mistakes treehouse gh-axi chrome-devtools-axi lavish-axi quota-axi; do
    grep -Fxq "$tool update" "$w/fake/calls" || fail "$tool did not update through its own update command with no extra flags"
  done
  pass "every stack tool updates through its own path and reports old..new"
}

test_unchanged_tool_is_already_current() {
  local w out
  w=$(new_world all-same)
  for tool in $STACK_TOOLS; do echo same > "$w/fake/$tool.mode"; done
  out=$(run_stack_update "$w")
  assert_contains "$out" "lavish-axi: already current (1.0.0)" "an unchanged tool reports already current"
  assert_not_contains "$out" "updated" "no tool claims an update it did not get"
  pass "a tool whose version did not move reports already current"
}

test_active_pipeline_runs_defer_no_mistakes() {
  local w out
  w=$(new_world nm-refuse)
  echo refuse > "$w/fake/no-mistakes.mode"
  out=$(run_stack_update "$w")
  assert_contains "$out" "no-mistakes: deferred: pipeline runs are active on the shared daemon" "the shared daemon's refusal is reported as deferred"
  assert_no_grep '--force' "$w/fake/calls" "the shared daemon is never forced"
  assert_no_grep '--yes' "$w/fake/calls" "no update prompt is answered for the operator"
  assert_no_grep ' -y' "$w/fake/calls" "no update prompt is answered for the operator"
  assert_contains "$out" "treehouse: updated 1.0.0..1.1.0" "a deferred no-mistakes does not stop the other tools"
  pass "active pipeline runs defer the no-mistakes update instead of forcing it"
}

test_missing_tool_is_skipped() {
  local w out
  w=$(new_world missing)
  rm "$w/fakebin/treehouse"
  out=$(run_stack_update "$w")
  assert_contains "$out" "treehouse: skipped: not installed" "a missing tool is skipped, not installed"
  assert_contains "$out" "gh-axi: updated 1.0.0..1.1.0" "the other tools still update"
  pass "a tool that is not installed is skipped"
}

test_failed_and_timed_out_updates_are_skipped() {
  local w out
  w=$(new_world fail)
  echo fail > "$w/fake/gh-axi.mode"
  echo slow > "$w/fake/quota-axi.mode"
  out=$(run_stack_update "$w" FM_STACK_UPDATE_TIMEOUT=1)
  assert_contains "$out" "gh-axi: skipped: update failed: Error: download failed: registry unreachable" "a failed update is skipped with its own error"
  assert_contains "$out" "quota-axi: skipped: update timed out after 1s" "a hung update is bounded and skipped"
  pass "failed and timed-out updates are skipped and reported"
}

test_tasks_axi_outside_npm_root_is_skipped() {
  local w out
  w=$(new_world foreign-tasks-axi)
  rm "$w/fakebin/tasks-axi"
  write_fake_tool "$w/fakebin/tasks-axi" tasks-axi
  out=$(run_stack_update "$w")
  assert_contains "$out" "tasks-axi: skipped: not an npm global install" "a tasks-axi npm does not own is skipped"
  assert_no_grep 'npm install' "$w/fake/calls" "npm never installs a second, shadowed tasks-axi"
  pass "a tasks-axi installed outside npm's global root is skipped"
}

test_invalid_arguments_refuse() {
  local w
  w=$(new_world invalid)
  local rc=0
  run_stack_update "$w" FM_STACK_UPDATE_TIMEOUT=soon >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a non-numeric timeout"
  rc=0
  env FM_FAKE_DIR="$w/fake" PATH="$w/fakebin:$BASE_PATH" bash "$STACK_UPDATE" --force >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown argument"
  [ ! -s "$w/fake/calls" ] || fail "a refused invocation still ran an update: $(cat "$w/fake/calls")"
  pass "an invalid timeout or argument refuses before any update"
}

test_every_tool_updates_through_its_own_path
test_unchanged_tool_is_already_current
test_active_pipeline_runs_defer_no_mistakes
test_missing_tool_is_skipped
test_failed_and_timed_out_updates_are_skipped
test_tasks_axi_outside_npm_root_is_skipped
test_invalid_arguments_refuse

echo "# all fm-stack-update tests passed"
