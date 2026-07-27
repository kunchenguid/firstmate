#!/usr/bin/env bash
# Regression test for the fm-spawn.sh recovery-relaunch ownership guard
# (bin/fm-spawn.sh, resolve_recorded_task_worktree and the worktree-entry
# branch after it).
#
# A ship/scout spawn for a task id that already has state/<id>.meta is a
# relaunch of an interrupted task. Before the guard it ran the fresh-allocation
# path unchanged: `treehouse get` handed out ANOTHER worktree and the meta write
# truncated the record, so the recorded worktree - holding uncommitted edits and
# unpushed commits - was left with no durable owner, and a still-live recorded
# agent would have meant two workers on one task identity. The backends' own
# duplicate refusals never covered it: tmux only refuses while the task WINDOW
# still exists, which is exactly what an interrupted task no longer has.
#
# These cases pin the fixed behavior: a provable relaunch re-enters the recorded
# worktree without asking treehouse for a new one, an unprovable one refuses with
# every record and worktree intact, and a task id with no record still takes the
# unchanged fresh-allocation path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-recovery-guard)

# A fake tmux that honors the pane's `cd`: send-keys records the cd target (and
# every sent line), and the pane_current_path query reports it. FM_FAKE_WINDOWS
# and FM_FAKE_PANE_COMMAND drive fm_backend_tmux_agent_state's inventory and
# foreground-command reads.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -s "${FM_FAKE_CWD_FILE:-/nonexistent}" ]; then
      cat "$FM_FAKE_CWD_FILE"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
  *"#{pane_current_command}"*)
    printf '%s\n' "${FM_FAKE_PANE_COMMAND:-bash}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) printf '%s' "${FM_FAKE_WINDOWS:-}"; exit 0 ;;
  send-keys)
    for arg in "$@"; do
      case "$arg" in
        "cd "*)
          printf '%s\n' "$arg" >> "${FM_FAKE_SENT_FILE:-/dev/null}"
          target=${arg#cd }
          target=${target#\'}
          target=${target%\'}
          printf '%s\n' "$target" > "${FM_FAKE_CWD_FILE:-/dev/null}"
          ;;
        "treehouse get"|*)
          case "$arg" in
            -t|-l|send-keys|Enter|"$1") ;;
            *) printf '%s\n' "$arg" >> "${FM_FAKE_SENT_FILE:-/dev/null}" ;;
          esac
          ;;
      esac
    done
    exit 0
    ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # A fake `treehouse` that leases the NEXT free worktree, exactly like the real
  # one: it has no task identity, so a relaunch would silently get a different
  # copy. Calls are logged so a test can prove no fresh acquisition happened.
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id>: a firstmate home, a project, and two real worktrees -
# "a" (the one an interrupted task already owns) and "b" (the next free one a
# fresh allocation would hand out).
make_case() {
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  CASE_HOME="$case_dir/home"
  CASE_PROJ="$case_dir/project"
  CASE_WT_A="$case_dir/wt-a"
  CASE_WT_B="$case_dir/wt-b"
  CASE_FAKEBIN=$(make_fakebin "$case_dir/fake")
  CASE_CWD_FILE="$case_dir/pane-cwd"
  CASE_SENT_FILE="$case_dir/pane-sent"
  CASE_TREEHOUSE_LOG="$case_dir/treehouse-calls"
  mkdir -p "$CASE_HOME/data" "$CASE_HOME/projects" "$CASE_HOME/state" "$CASE_HOME/config"
  printf 'codex\n' > "$CASE_HOME/config/crew-harness"
  touch "$CASE_HOME/state/.last-watcher-beat"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT_A" "wt-a-$name"
  git -C "$CASE_PROJ" worktree add --quiet -b "wt-b-$name" "$CASE_WT_B"
  mkdir -p "$CASE_HOME/data/$id"
  printf 'brief for %s\n' "$id" > "$CASE_HOME/data/$id/brief.md"
  : > "$CASE_CWD_FILE"
  : > "$CASE_SENT_FILE"
  : > "$CASE_TREEHOUSE_LOG"
}

# run_spawn <id> <pane-path-when-no-cd-yet>: one spawn against the fake tmux.
run_spawn() {
  local id=$1 pane_path=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane_path" FM_FAKE_CWD_FILE="$CASE_CWD_FILE" \
    FM_FAKE_SENT_FILE="$CASE_SENT_FILE" FM_FAKE_LEASE_PATH="$pane_path" \
    FM_FAKE_POOL_PATH="${FM_FAKE_POOL_PATH:-$CASE_WT_A}" \
    FM_FAKE_POOL_STATUS="${FM_FAKE_POOL_STATUS:-leased}" \
    FM_FAKE_LEASE_HOLDER="${FM_FAKE_LEASE_HOLDER-fm-$id}" \
    FM_FAKE_TREEHOUSE_LOG="$CASE_TREEHOUSE_LOG" \
    FM_FAKE_WINDOWS="${FM_FAKE_WINDOWS:-}" FM_FAKE_PANE_COMMAND="${FM_FAKE_PANE_COMMAND:-bash}" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$CASE_PROJ" 2>&1
}

run_adopt() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" FM_STATE_OVERRIDE="$CASE_HOME/state" \
    FM_CONFIG_OVERRIDE="$CASE_HOME/config" FM_FAKE_POOL_PATH="$CASE_WT_A" \
    FM_FAKE_POOL_STATUS="${FM_FAKE_POOL_STATUS:-in-use}" \
    FM_FAKE_LEASE_HOLDER="${FM_FAKE_LEASE_HOLDER:-}" \
    FM_FAKE_WINDOWS="" PATH="$CASE_FAKEBIN:$PATH" \
    "$ROOT/bin/fm-adopt-worktree.sh" "$id" 2>&1
}

# leave_unlanded_work <worktree>: an unpushed commit plus an uncommitted edit -
# the work a relaunch must never orphan.
leave_unlanded_work() {
  local wt=$1
  printf 'unlanded\n' > "$wt/feature.txt"
  git -C "$wt" add feature.txt
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'unlanded work'
  printf 'dirty\n' > "$wt/scratch.txt"
}

# A relaunch of an interrupted task must re-enter the RECORDED worktree with its
# unlanded work intact, never ask treehouse for a fresh one.
test_relaunch_reuses_recorded_worktree() {
  local id out status
  id=recovery-reuse-a1
  make_case reuse "$id"
  out=$(run_spawn "$id" "$CASE_WT_A")
  expect_code 0 "$?" "first spawn should succeed"
  assert_grep "worktree=$CASE_WT_A" "$CASE_HOME/state/$id.meta" "first spawn did not record worktree a"

  # The worker did real work, then its window went away (interrupted task).
  leave_unlanded_work "$CASE_WT_A"
  : > "$CASE_CWD_FILE"
  : > "$CASE_SENT_FILE"
  : > "$CASE_TREEHOUSE_LOG"

  # treehouse would now hand out worktree b.
  out=$(run_spawn "$id" "$CASE_WT_B")
  status=$?
  expect_code 0 "$status" "relaunch into a provably free recorded worktree should succeed: $out"
  assert_grep "worktree=$CASE_WT_A" "$CASE_HOME/state/$id.meta" \
    "relaunch did not keep the recorded worktree"
  assert_no_grep "worktree=$CASE_WT_B" "$CASE_HOME/state/$id.meta" \
    "REGRESSION: relaunch allocated a fresh worktree and overwrote the task record"
  assert_no_grep 'get --lease' "$CASE_TREEHOUSE_LOG" \
    "REGRESSION: relaunch leased another worktree"
  assert_grep "cd '$CASE_WT_A'" "$CASE_SENT_FILE" "relaunch did not re-enter the recorded worktree"
  assert_present "$CASE_WT_A/scratch.txt" "relaunch lost the recorded worktree's uncommitted edit"
  assert_contains "$(git -C "$CASE_WT_A" log --oneline -1)" 'unlanded work' \
    "relaunch lost the recorded worktree's unpushed commit"
  assert_grep "lease_holder=fm-$id" "$CASE_HOME/state/$id.meta" \
    "relaunch dropped the verified native lease holder"

  : > "$CASE_CWD_FILE"
  : > "$CASE_SENT_FILE"
  out=$(run_spawn "$id" "$CASE_WT_B")
  status=$?
  expect_code 0 "$status" "second relaunch of the native lease should succeed: $out"
  assert_grep "lease_holder=fm-$id" "$CASE_HOME/state/$id.meta" \
    "second relaunch did not preserve the verified native lease holder"
  assert_grep "cd '$CASE_WT_A'" "$CASE_SENT_FILE" \
    "second relaunch did not re-enter the natively leased worktree"
  pass "consecutive relaunches preserve and reuse the verified native lease"
}

# A recorded endpoint that still reports a live agent must refuse: two workers
# on one task identity is the double-ownership case.
test_live_recorded_endpoint_refuses() {
  local id out status before
  id=recovery-live-a2
  make_case live "$id"
  out=$(run_spawn "$id" "$CASE_WT_A")
  expect_code 0 "$?" "first spawn should succeed"
  leave_unlanded_work "$CASE_WT_A"
  before=$(cat "$CASE_HOME/state/$id.meta")
  : > "$CASE_CWD_FILE"
  : > "$CASE_SENT_FILE"
  : > "$CASE_TREEHOUSE_LOG"

  out=$(FM_FAKE_WINDOWS="fm-$id
" FM_FAKE_PANE_COMMAND=codex run_spawn "$id" "$CASE_WT_B")
  status=$?
  expect_code 1 "$status" "relaunch onto a live recorded endpoint should refuse"
  assert_contains "$out" 'already has a recorded worker' "refusal did not name the recorded worker"
  assert_contains "$out" 'is alive' "refusal did not report the live endpoint state"
  [ "$before" = "$(cat "$CASE_HOME/state/$id.meta")" ] \
    || fail "refused relaunch still changed the task record"
  assert_no_grep 'get --lease' "$CASE_TREEHOUSE_LOG" "refused relaunch still leased a worktree"
  pass "a relaunch onto a live recorded endpoint refuses and leaves the record intact"
}

# A recorded worktree that is no longer an isolated worktree root cannot prove
# ownership either: refuse rather than silently starting a second copy.
test_unresolvable_recorded_worktree_refuses() {
  local id out status before
  id=recovery-gone-a3
  make_case gone "$id"
  out=$(run_spawn "$id" "$CASE_WT_A")
  expect_code 0 "$?" "first spawn should succeed"
  before=$(cat "$CASE_HOME/state/$id.meta")
  # Point the record at a path that is not a worktree root at all.
  sed "s|^worktree=.*|worktree=$TMP_ROOT/gone/not-a-worktree|" "$CASE_HOME/state/$id.meta" \
    > "$CASE_HOME/state/$id.meta.new"
  mv "$CASE_HOME/state/$id.meta.new" "$CASE_HOME/state/$id.meta"
  before=$(cat "$CASE_HOME/state/$id.meta")
  : > "$CASE_CWD_FILE"
  : > "$CASE_SENT_FILE"
  : > "$CASE_TREEHOUSE_LOG"

  out=$(run_spawn "$id" "$CASE_WT_B")
  status=$?
  expect_code 1 "$status" "relaunch with an unresolvable recorded worktree should refuse"
  assert_contains "$out" 'already has a recorded worker' "refusal did not name the recorded worker"
  [ "$before" = "$(cat "$CASE_HOME/state/$id.meta")" ] \
    || fail "refused relaunch still changed the task record"
  pass "a relaunch whose recorded worktree cannot be resolved refuses and preserves the record"
}

# The fresh-allocation path is untouched: a task id with no record still gets a
# treehouse worktree and a new record.
test_fresh_task_still_allocates() {
  local id out status
  id=recovery-fresh-a4
  make_case fresh "$id"
  out=$(run_spawn "$id" "$CASE_WT_A")
  status=$?
  expect_code 0 "$status" "a task with no record should spawn normally: $out"
  assert_contains "$out" "spawned $id" "fresh spawn did not report success"
  assert_grep "worktree=$CASE_WT_A" "$CASE_HOME/state/$id.meta" "fresh spawn did not record its worktree"
  assert_grep 'get --lease --lease-holder fm-'"$id" "$CASE_TREEHOUSE_LOG" \
    "fresh spawn did not durably lease its worktree"
  pass "a task id with no record still takes the unchanged fresh-allocation path"
}

# A relaunch must not rewrite the recorded contract: turning a recorded ship
# into a scout would drop teardown's unlanded-work protection.
test_kind_change_refuses() {
  local id out status before
  id=recovery-kind-a5
  make_case kind "$id"
  out=$(run_spawn "$id" "$CASE_WT_A")
  expect_code 0 "$?" "first spawn should succeed"
  leave_unlanded_work "$CASE_WT_A"
  before=$(cat "$CASE_HOME/state/$id.meta")
  : > "$CASE_CWD_FILE"
  : > "$CASE_SENT_FILE"
  : > "$CASE_TREEHOUSE_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$CASE_WT_B" FM_FAKE_CWD_FILE="$CASE_CWD_FILE" \
    FM_FAKE_SENT_FILE="$CASE_SENT_FILE" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$CASE_PROJ" --scout 2>&1)
  status=$?
  expect_code 1 "$status" "relaunching a recorded ship task as a scout should refuse"
  assert_contains "$out" 'is a ship task' "refusal did not name the recorded contract"
  [ "$before" = "$(cat "$CASE_HOME/state/$id.meta")" ] \
    || fail "refused relaunch still changed the task record"
  pass "a relaunch that would rewrite the recorded task contract refuses"
}

# A record from another project cannot authorize reuse of its worktree for this
# spawn, even when every other recovery check would pass.
test_project_change_refuses() {
  local id out status before other_project
  id=recovery-project-a6
  make_case project "$id"
  out=$(run_spawn "$id" "$CASE_WT_A")
  expect_code 0 "$?" "first spawn should succeed"
  leave_unlanded_work "$CASE_WT_A"
  other_project="$TMP_ROOT/project/other-project"
  mkdir -p "$other_project"
  sed "s|^project=.*|project=$other_project|" "$CASE_HOME/state/$id.meta" \
    > "$CASE_HOME/state/$id.meta.new"
  mv "$CASE_HOME/state/$id.meta.new" "$CASE_HOME/state/$id.meta"
  before=$(cat "$CASE_HOME/state/$id.meta")
  : > "$CASE_CWD_FILE"
  : > "$CASE_SENT_FILE"
  : > "$CASE_TREEHOUSE_LOG"

  out=$(run_spawn "$id" "$CASE_WT_B")
  status=$?
  expect_code 1 "$status" "relaunch whose record names another project should refuse"
  assert_contains "$out" 'recorded project' "refusal did not identify the recorded project mismatch"
  assert_contains "$out" 'does not match the requested project' \
    "refusal did not explain the requested project mismatch"
  [ "$before" = "$(cat "$CASE_HOME/state/$id.meta")" ] \
    || fail "cross-project refused relaunch still changed the task record"
  assert_no_grep 'treehouse get' "$CASE_SENT_FILE" \
    "cross-project refused relaunch still asked for a worktree"
  pass "a relaunch whose record names another project refuses"
}

test_legacy_copy_requires_durable_lease() {
  local id out status before
  id=recovery-adopt-a7
  make_case adoption "$id"
  out=$(run_spawn "$id" "$CASE_WT_A")
  expect_code 0 "$?" "first spawn should succeed"
  sed '/^lease_holder=/d' "$CASE_HOME/state/$id.meta" > "$CASE_HOME/state/$id.meta.new"
  mv "$CASE_HOME/state/$id.meta.new" "$CASE_HOME/state/$id.meta"
  printf 'preserve exactly\n' > "$CASE_WT_A/handoff.md"
  before=$(cat "$CASE_HOME/state/$id.meta")
  : > "$CASE_CWD_FILE"
  : > "$CASE_TREEHOUSE_LOG"

  out=$(FM_FAKE_POOL_STATUS=in-use FM_FAKE_LEASE_HOLDER='' run_spawn "$id" "$CASE_WT_B")
  status=$?
  expect_code 1 "$status" "legacy relaunch without durable proof should refuse"
  assert_contains "$out" 'require an existing lease' "refusal did not require a durable task lease"
  [ "$before" = "$(cat "$CASE_HOME/state/$id.meta")" ] || fail "refusal changed the legacy record"
  assert_grep 'preserve exactly' "$CASE_WT_A/handoff.md" "refusal changed legacy content"

  out=$(FM_FAKE_POOL_STATUS=in-use FM_FAKE_LEASE_HOLDER='' run_adopt "$id")
  status=$?
  expect_code 1 "$status" "unleased legacy adoption should refuse"
  assert_contains "$out" 'not a durable' "adoption did not require a durable task lease"

  out=$(FM_FAKE_POOL_STATUS=available FM_FAKE_LEASE_HOLDER='' run_spawn "$id" "$CASE_WT_B")
  status=$?
  expect_code 1 "$status" "adopted copy that became available should refuse"
  assert_contains "$out" 'status=available' \
    "available refusal did not report the current pool state"
  assert_grep 'preserve exactly' "$CASE_WT_A/handoff.md" \
    "available-state refusal changed adopted content"

  out=$(FM_FAKE_POOL_STATUS=leased FM_FAKE_LEASE_HOLDER=foreign-holder run_spawn "$id" "$CASE_WT_B")
  status=$?
  expect_code 1 "$status" "adopted copy with a foreign lease should refuse"
  assert_contains "$out" 'holder=foreign-holder' \
    "foreign-lease refusal did not report the current holder"
  assert_grep 'preserve exactly' "$CASE_WT_A/handoff.md" \
    "foreign-lease refusal changed adopted content"

  out=$(FM_FAKE_POOL_STATUS=leased FM_FAKE_LEASE_HOLDER="fm-$id" run_spawn "$id" "$CASE_WT_B")
  expect_code 0 "$?" "relaunch with an exact durable lease should succeed: $out"
  assert_grep "cd '$CASE_WT_A'" "$CASE_SENT_FILE" "leased relaunch did not enter the recovered copy"
  assert_present "$CASE_WT_A/handoff.md" "relaunch lost the untracked handoff"

  : > "$CASE_CWD_FILE"
  : > "$CASE_SENT_FILE"
  : > "$CASE_TREEHOUSE_LOG"
  FM_FAKE_TREEHOUSE_LOG="$CASE_TREEHOUSE_LOG" FM_FAKE_LEASE_PATH="$CASE_WT_B" FM_FAKE_POOL_PATH="$CASE_WT_A" \
    FM_FAKE_POOL_STATUS=leased FM_FAKE_LEASE_HOLDER="fm-$id" \
    "$CASE_FAKEBIN/treehouse" get --lease --lease-holder another-task >/dev/null
  assert_grep "get --lease --lease-holder another-task" "$CASE_TREEHOUSE_LOG" \
    "post-exit allocation was not exercised"
  assert_present "$CASE_WT_A/handoff.md" "post-exit allocation recycled the recovered copy"
  pass "recovered work stays leased and preserves its untracked handoff after worker exit"
}

test_holderless_record_uses_current_native_lease_proof() {
  local id out status before
  id=recovery-holderless-a8
  make_case holderless "$id"
  out=$(run_spawn "$id" "$CASE_WT_A")
  expect_code 0 "$?" "first spawn should succeed"
  sed '/^lease_holder=/d' "$CASE_HOME/state/$id.meta" > "$CASE_HOME/state/$id.meta.new"
  mv "$CASE_HOME/state/$id.meta.new" "$CASE_HOME/state/$id.meta"
  : > "$CASE_CWD_FILE"
  : > "$CASE_SENT_FILE"

  out=$(FM_FAKE_POOL_STATUS=leased FM_FAKE_LEASE_HOLDER="fm-$id" run_spawn "$id" "$CASE_WT_B")
  status=$?
  expect_code 0 "$status" "holder-less record with a matching current lease should relaunch: $out"
  assert_grep "lease_holder=fm-$id" "$CASE_HOME/state/$id.meta" \
    "matching current lease did not make the rewritten record self-describing"
  assert_grep "cd '$CASE_WT_A'" "$CASE_SENT_FILE" \
    "matching current lease did not re-enter the recorded worktree"

  sed '/^lease_holder=/d' "$CASE_HOME/state/$id.meta" > "$CASE_HOME/state/$id.meta.new"
  mv "$CASE_HOME/state/$id.meta.new" "$CASE_HOME/state/$id.meta"
  before=$(cat "$CASE_HOME/state/$id.meta")
  : > "$CASE_CWD_FILE"
  out=$(FM_FAKE_POOL_STATUS=leased FM_FAKE_LEASE_HOLDER=foreign-holder run_spawn "$id" "$CASE_WT_B")
  status=$?
  expect_code 1 "$status" "holder-less record with a foreign current lease should refuse"
  assert_contains "$out" 'holder=foreign-holder' "foreign-holder refusal did not report current ownership"
  [ "$before" = "$(cat "$CASE_HOME/state/$id.meta")" ] \
    || fail "foreign-holder refusal changed the holder-less record"
  pass "holder-less records trust only an exact matching current native lease"
}

test_relaunch_reuses_recorded_worktree
test_live_recorded_endpoint_refuses
test_kind_change_refuses
test_project_change_refuses
test_unresolvable_recorded_worktree_refuses
test_fresh_task_still_allocates
test_legacy_copy_requires_durable_lease
test_holderless_record_uses_current_native_lease_proof

echo "# all fm-spawn-recovery-guard tests passed"
