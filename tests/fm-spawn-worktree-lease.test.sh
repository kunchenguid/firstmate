#!/usr/bin/env bash
# Regression tests for fm-spawn.sh leasing the task worktree (bin/fm-spawn.sh).
#
# The bug: fm-spawn acquired the task worktree with a bare, UNLEASED
# `treehouse get`. An unleased slot can be handed back by a later
# `treehouse get`/`prune` - so after a crash or a stuck-crew relaunch the pool
# could return the same slot reset onto the default branch, losing the task's
# branch and its in-flight commits. `no-mistakes axi respond` then fails ("no
# active run to respond to") because it resolves the active run by the
# checked-out branch. fm-spawn now leases the worktree under the task id, which
# reserves the slot (and its branch and commits) across restarts until teardown
# returns it, so a relaunch re-binds to the SAME worktree. Mirrors the leased
# firstmate homes in bin/fm-home-seed.sh.
#
# Coverage:
#   - spawn issues `treehouse get --lease --lease-holder <id>` and records the
#     leased worktree, so the lease is keyed to the task and teardown/recovery
#     can find it.
#   - a spawn that aborts after leasing returns the lease, so a failed launch
#     never leaks a reserved pool slot.
#   - (real treehouse, self-skipping) the lease contract fm-spawn/fm-teardown
#     rely on holds end to end: a leased slot and its branch/commit survive a
#     competing get + prune (idle-lease-survives-pool-op, and the enabler for
#     relaunch-rebinds-to-branch), and `treehouse return --force` frees it
#     (teardown-releases-lease).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-lease)

# --- hermetic fakes ---------------------------------------------------------

# make_lease_fakebin <dir>: a fake tmux whose `#{pane_current_path}` query
# returns FM_FAKE_PANE_PATH, and a fake treehouse that logs every invocation
# (one args line) to FM_FAKE_TH_LOG and, on `get`, prints FM_FAKE_LEASE_PATH -
# mirroring how `treehouse get --lease` prints only the leased path to stdout.
# Every other treehouse subcommand (the abort-time `return`) succeeds silently.
make_lease_fakebin() {
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
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TH_LOG:?FM_FAKE_TH_LOG unset}"
case "${1:-}" in
  get) printf '%s\n' "${FM_FAKE_LEASE_PATH:?FM_FAKE_LEASE_PATH unset}" ;;
  status)
    node -e 'console.log(JSON.stringify([{path: process.argv[1], status: "leased", lease_holder: process.argv[2]}]))' \
      "${FM_FAKE_LEASE_PATH:?FM_FAKE_LEASE_PATH unset}" \
      "${FM_FAKE_LEASE_HOLDER:?FM_FAKE_LEASE_HOLDER unset}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_lease_case <name> <id>: build a firstmate home, a project with a real
# worktree (the leased path the pane settles into), a separate non-worktree dir
# (for the abort case), a fakebin, and the treehouse-invocation log. Echoes a
# pipe-delimited record.
make_lease_case() {
  local name=$1 id=$2 case_dir home proj wt bad fakebin thlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  bad="$case_dir/not-a-worktree"
  thlog="$case_dir/treehouse.log"
  fakebin=$(make_lease_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$bad"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  : > "$thlog"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$bad|$fakebin|$thlog"
}

read_lease_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR BAD_DIR FAKEBIN_DIR THLOG <<EOF
$1
EOF
}

# run_lease_spawn <id> <lease-path> <pane-path>: drive fm-spawn with the fakes,
# leasing <lease-path> and settling the pane at <pane-path>.
run_lease_spawn() {
  local id=$1 lease=$2 pane=$3
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_LEASE_PATH="$lease" FM_FAKE_PANE_PATH="$pane" \
    FM_FAKE_LEASE_HOLDER="$id" \
    FM_FAKE_TH_LOG="$THLOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A successful spawn leases the worktree under the task id and records it, so a
# later crash/relaunch can re-bind to the same reserved slot.
test_spawn_leases_worktree_under_task_id() {
  local rec id out status
  id="lease-keyed-z1"
  rec=$(make_lease_case lease-keyed "$id")
  read_lease_record "$rec"

  set +e
  out=$(run_lease_spawn "$id" "$WT_DIR" "$WT_DIR")
  status=$?
  set -e

  expect_code 0 "$status" "spawn should succeed when the pane settles in the leased worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the leased worktree"
  assert_grep "get --lease --lease-holder $id" "$THLOG" \
    "spawn did not durably lease the task worktree under the task id"
  pass "spawn leases the task worktree under the task id and records it"
}

# A spawn that aborts after leasing (here: the pane settles at a path that is
# not an isolated worktree, so validate_spawn_worktree refuses) must return the
# lease so a failed launch never leaks a reserved pool slot.
test_spawn_abort_releases_leased_worktree() {
  local rec id out status
  id="lease-abort-z2"
  rec=$(make_lease_case lease-abort "$id")
  read_lease_record "$rec"

  set +e
  out=$(run_lease_spawn "$id" "$BAD_DIR" "$BAD_DIR")
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "spawn should have aborted when the pane never reaches an isolated worktree: $out"
  assert_grep "return --force $BAD_DIR" "$THLOG" \
    "aborted spawn leaked the lease instead of returning the leased worktree"
  pass "a spawn that aborts after leasing returns the lease (no leaked pool slot)"
}

test_relaunch_reuses_recorded_lease() {
  local rec id out status branch head
  id="lease-relaunch-z3"
  rec=$(make_lease_case lease-relaunch "$id")
  read_lease_record "$rec"

  out=$(run_lease_spawn "$id" "$WT_DIR" "$WT_DIR")
  status=$?
  expect_code 0 "$status" "initial spawn should acquire the task lease"
  git -C "$WT_DIR" checkout -q -b "fm/$id"
  printf '%s\n' in-flight > "$WT_DIR/inflight.txt"
  git -C "$WT_DIR" -c user.email=t@t -c user.name=t add inflight.txt
  git -C "$WT_DIR" -c user.email=t@t -c user.name=t commit -qm "task work"
  head=$(git -C "$WT_DIR" rev-parse HEAD)

  out=$(run_lease_spawn "$id" "$WT_DIR" "$WT_DIR")
  status=$?
  expect_code 0 "$status" "relaunch should reuse the recorded task lease"
  [ "$(grep -c "^get --lease --lease-holder $id$" "$THLOG")" -eq 1 ] \
    || fail "relaunch acquired a second worktree lease: $(cat "$THLOG")"
  assert_no_grep "return --force $WT_DIR" "$THLOG" \
    "successful relaunch returned the reused task lease"
  branch=$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)
  [ "$branch" = "fm/$id" ] || fail "relaunch lost the task branch (now '$branch')"
  [ "$(git -C "$WT_DIR" rev-parse HEAD)" = "$head" ] \
    || fail "relaunch lost the task's in-flight commit"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "relaunch did not preserve the recorded leased worktree"
  pass "relaunch reuses the recorded lease with its branch and commits"
}

test_relaunch_accepts_equivalent_status_path() {
  local rec id out status linked_wt
  id="lease-relaunch-symlink-z4"
  rec=$(make_lease_case lease-relaunch-symlink "$id")
  read_lease_record "$rec"

  out=$(run_lease_spawn "$id" "$WT_DIR" "$WT_DIR")
  status=$?
  expect_code 0 "$status" "initial spawn should acquire the task lease"
  linked_wt="$CASE_DIR/wt-link"
  ln -s "$WT_DIR" "$linked_wt"

  out=$(run_lease_spawn "$id" "$linked_wt" "$WT_DIR")
  status=$?
  expect_code 0 "$status" "relaunch should accept an equivalent Treehouse status path"
  [ "$(grep -c "^get --lease --lease-holder $id$" "$THLOG")" -eq 1 ] \
    || fail "equivalent status path caused a second lease acquisition: $(cat "$THLOG")"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "relaunch did not preserve the canonical leased worktree"
  pass "relaunch recognizes symlink-equivalent Treehouse lease paths"
}

test_aborted_relaunch_preserves_recorded_lease() {
  local rec id out status
  id="lease-relaunch-abort-z4"
  rec=$(make_lease_case lease-relaunch-abort "$id")
  read_lease_record "$rec"
  printf '%s\n' "worktree=$BAD_DIR" > "$HOME_DIR/state/$id.meta"

  set +e
  out=$(run_lease_spawn "$id" "$BAD_DIR" "$BAD_DIR")
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "relaunch should reject a recorded lease that is not an isolated worktree: $out"
  assert_no_grep '^get --lease ' "$THLOG" \
    "relaunch acquired a fresh lease instead of reusing the recorded lease"
  assert_no_grep "return --force $BAD_DIR" "$THLOG" \
    "aborted relaunch returned a lease acquired by the original spawn"
  pass "aborted relaunch preserves the original task lease"
}

# --- real treehouse: the lease contract fm-spawn/fm-teardown rely on ---------

treehouse_supports_lease() {
  command -v treehouse >/dev/null 2>&1 || return 1
  treehouse get --help 2>&1 | grep -q -- '--lease' || return 1
}

# End-to-end against the real treehouse binary, issuing the exact commands
# fm-spawn (lease) and fm-teardown (return --force) issue. Self-skips when
# treehouse (or its --lease support) is absent so hermetic CI stays green.
test_treehouse_lease_contract_real() {
  if ! treehouse_supports_lease; then
    pass "SKIP real-treehouse lease contract (treehouse with --lease not installed)"
    return 0
  fi
  local id=relaunch-rebind other=competing-slot case_dir repo wt branch head
  case_dir="$TMP_ROOT/real-lease"
  repo="$case_dir/repo"
  mkdir -p "$case_dir"
  fm_git_init_commit "$repo"
  # Keep the pool inside the scratch tree so it is isolated from any real pool.
  printf 'max_trees = 16\nroot = "%s"\n' "$case_dir" > "$repo/treehouse.toml"
  git -C "$repo" -c user.email=t@t -c user.name=t add treehouse.toml
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm "treehouse config"

  # Lease exactly as fm-spawn does (path-only stdout; banners to stderr).
  wt=$( cd "$repo" && treehouse get --lease --lease-holder "$id" ) \
    || fail "treehouse get --lease failed"
  [ -n "$wt" ] && [ -d "$wt" ] || fail "lease reported no worktree: '$wt'"

  # Put in-flight work on a task branch, as a crewmate would.
  git -C "$wt" checkout -q -b "fm/$id"
  printf 'in-flight\n' > "$wt/inflight.txt"
  git -C "$wt" -c user.email=t@t -c user.name=t add inflight.txt
  git -C "$wt" -c user.email=t@t -c user.name=t commit -qm "task work"
  head=$(git -C "$wt" rev-parse HEAD)

  # A competing pool acquire + prune (the crash-window recycling the old bare
  # `treehouse get` was vulnerable to) must NOT touch the leased slot.
  ( cd "$repo" && treehouse get --lease --lease-holder "$other" >/dev/null ) \
    || fail "competing treehouse get --lease failed"
  ( cd "$repo" && treehouse prune >/dev/null ) || fail "treehouse prune failed"

  # idle-lease-survives-pool-op + relaunch-rebinds-to-branch: the leased slot,
  # its branch, and its commit are all still there, so a relaunch cd'ing back
  # to this recorded path re-binds to the same branch instead of a reset copy.
  [ -d "$wt" ] || fail "leased worktree vanished after competing pool ops"
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD)
  [ "$branch" = "fm/$id" ] || fail "leased worktree lost its branch (now on '$branch')"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head" ] || fail "leased worktree lost its commit"
  ( cd "$repo" && treehouse status 2>/dev/null ) | grep -q "held by $id" \
    || fail "treehouse no longer reports the slot leased under the task id"

  # teardown-releases-lease: `treehouse return --force` frees the slot.
  ( cd "$repo" && treehouse return --force "$wt" >/dev/null ) \
    || fail "treehouse return --force failed to release the lease"
  if ( cd "$repo" && treehouse status 2>/dev/null ) | grep -q "held by $id"; then
    fail "lease was not released after treehouse return --force"
  fi
  # The scratch pool (and its remaining competing lease) lives entirely under
  # the fm_test_tmproot dir, removed on EXIT; no treehouse processes persist.
  pass "real treehouse: leased slot survives pool ops with its branch, and return frees it"
}

test_spawn_leases_worktree_under_task_id
test_spawn_abort_releases_leased_worktree
test_relaunch_reuses_recorded_lease
test_relaunch_accepts_equivalent_status_path
test_aborted_relaunch_preserves_recorded_lease
test_treehouse_lease_contract_real

echo "# all fm-spawn-worktree-lease tests passed"
