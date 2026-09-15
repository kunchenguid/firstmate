#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's spawn transaction: the repository
# preflight that runs before any endpoint exists, and the cleanup obligation
# that owns a freshly created endpoint until the task record names it.
#
# Both come from the same live failure. Spawning against a brand-new empty
# GitHub repository could not produce an isolated local copy, because there is
# no commit to detach from. The spawn nevertheless created its endpoint first,
# spent the whole worktree-detection window waiting for something that could
# not happen, and then exited leaving a live window that no record named - so
# nothing else would ever close it.
#
# The worktree-detection loop itself is covered by
# tests/fm-spawn-worktree-settle.test.sh; these cases are about what the spawn
# owns before and after that loop.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-transaction)

# A tmux stub that records every window it creates and every window it kills,
# so a test can assert that an aborted spawn closed exactly the endpoint it
# opened. The pane never leaves FM_FAKE_PANE_PATH, which is how a spawn whose
# local copy never materializes is simulated.
make_transaction_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  new-window)
    printf '%s\n' "new-window $*" >> "${FM_FAKE_WINDOW_LOG:?FM_FAKE_WINDOW_LOG unset}"
    exit 0
    ;;
  kill-window|kill-pane)
    printf '%s\n' "kill $*" >> "${FM_FAKE_WINDOW_LOG:?FM_FAKE_WINDOW_LOG unset}"
    exit 0
    ;;
  has-session|new-session|set-window-option|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> echoes "<home>|<fakebin>|<window-log>" for a home whose
# project is created by the caller.
make_case() {
  local name=$1 id=$2 case_dir home fakebin log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  log="$case_dir/window-log"
  fakebin=$(make_transaction_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id" "Exercise the spawn transaction for $id."
  : > "$log"
  printf '%s\n' "$home|$fakebin|$log"
}

run_spawn() {  # <home> <fakebin> <window-log> <id> <project> <pane-path>
  FM_ROOT_OVERRIDE='' FM_HOME="$1" \
    FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_PROJECTS_OVERRIDE="$1/projects" FM_CONFIG_OVERRIDE="$1/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$6" FM_FAKE_WINDOW_LOG="$3" \
    PATH="$2:$PATH" \
    "$SPAWN" "$4" "$5" --mode no-mistakes --yolo off 2>&1
}

# The reported case: a clone of a remote with no commits. The refusal has to
# arrive before any endpoint exists, so the operator gets an explanation rather
# than a minute of waiting followed by a window to close.
test_unborn_repository_is_refused_before_any_endpoint() {
  local rec home fakebin log id proj out status
  id=txn-unborn-z1
  rec=$(make_case unborn "$id")
  IFS='|' read -r home fakebin log <<EOF
$rec
EOF
  proj="$TMP_ROOT/unborn/project"
  git init -q --bare "$TMP_ROOT/unborn/remote.git"
  git clone --quiet "$TMP_ROOT/unborn/remote.git" "$proj" 2>/dev/null

  out=$(run_spawn "$home" "$fakebin" "$log" "$id" "$proj" "$proj")
  status=$?
  [ "$status" -ne 0 ] || fail "spawning against an unborn repository reported success: $out"
  assert_contains "$out" "$proj" "the refusal did not name the repository"
  assert_contains "$out" "has no commit on its default branch" \
    "the refusal did not explain that the repository has no commit"
  assert_contains "$out" "push an initial commit" \
    "the refusal did not tell the operator how to fix it"
  assert_absent "$home/state/$id.meta" \
    "a refused spawn published a task record"
  if grep -q 'new-window' "$log" 2>/dev/null; then
    fail "a refused spawn created an endpoint before the repository was checked"
  fi
  pass "an unborn repository is refused before any endpoint is created"
}

# Any failure before the task record is published has to close the endpoint the
# spawn created, because no record names it yet and so nothing else will. A
# pane that never leaves the project stands in for every such mid-spawn
# failure; the isolation check refuses it after the endpoint already exists.
test_mid_spawn_failure_closes_the_endpoint_it_created() {
  local rec home fakebin log id proj out status
  id=txn-cleanup-z2
  rec=$(make_case cleanup "$id")
  IFS='|' read -r home fakebin log <<EOF
$rec
EOF
  proj="$TMP_ROOT/cleanup/project"
  fm_git_init_commit "$proj"

  out=$(run_spawn "$home" "$fakebin" "$log" "$id" "$proj" "$proj")
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose local copy never appeared reported success: $out"
  assert_absent "$home/state/$id.meta" \
    "a failed spawn published a task record"
  grep -q 'new-window' "$log" \
    || fail "the fixture never created an endpoint, so nothing was under test"
  grep -q '^kill ' "$log" \
    || fail "a spawn that failed before publishing its record left its endpoint open: $(cat "$log")"
  pass "a spawn that fails before publishing its record closes the endpoint it created"
}

test_unborn_repository_is_refused_before_any_endpoint
test_mid_spawn_failure_closes_the_endpoint_it_created

printf '\nall spawn transaction tests passed\n'
