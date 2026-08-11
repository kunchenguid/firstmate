#!/usr/bin/env bash
# How fm-spawn.sh acquires a task worktree, and where that worktree is allowed
# to live (bin/fm-spawn.sh's lease + settle block, bin/fm-treehouse-lib.sh).
#
# Firstmate leases the worktree itself and sends the pane a plain cd, because the
# pool must land on the repo's own filesystem and the only lever for that is the
# HOME treehouse runs under - which an interactive `treehouse get` would leak into
# the crew agent's shell. These tests hold that contract in place:
#
#   - the lease output, not the pane's cwd, decides worktree= in state/<id>.meta,
#     so the transient stale pane_current_path some tmux/WSL setups report on a
#     brand-new window can no longer record another real checkout as the worktree
#   - the pane is sent a cd and never a command that would change its HOME
#   - treehouse is invoked under the pool HOME firstmate resolved
#   - a worktree split from its object store is refused, because git blocks in
#     read_gitfile_gently there and the validation pipeline hangs forever
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
LIB="$ROOT/bin/fm-treehouse-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    # Record everything sent to the pane so a test can prove what the crew's
    # shell was actually asked to run.
    printf '%s\n' "$*" >> "${FM_FAKE_SENDKEYS_LOG:-/dev/null}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # Fake treehouse: `get --lease` prints the worktree path on stdout, exactly as
  # the real one does, and records the HOME it was invoked under - that HOME is
  # the entire pool-selection mechanism, so a test can assert it arrived.
	  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    printf '%s\n' "${HOME:-}" > "${FM_FAKE_TREEHOUSE_HOMEFILE:-/dev/null}"
    printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_ARGSFILE:-/dev/null}"
    printf '%s\n' "${FM_FAKE_TREEHOUSE_WT:-}"
    exit 0
    ;;
  return)
    printf '%s\n' "${HOME:-}" > "${FM_FAKE_TREEHOUSE_RETURN_HOMEFILE:-/dev/null}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
  SENDKEYS_LOG="$CASE_DIR/sendkeys.log"
  TREEHOUSE_HOMEFILE="$CASE_DIR/treehouse-home"
  TREEHOUSE_RETURN_HOMEFILE="$CASE_DIR/treehouse-return-home"
  TREEHOUSE_ARGSFILE="$CASE_DIR/treehouse-args"
}

run_settle_spawn() {
  local id=$1 lease_wt=${2:-$WT_DIR}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_TREEHOUSE_WT="$lease_wt" \
    FM_FAKE_TREEHOUSE_HOMEFILE="$TREEHOUSE_HOMEFILE" \
    FM_FAKE_TREEHOUSE_RETURN_HOMEFILE="$TREEHOUSE_RETURN_HOMEFILE" \
    FM_FAKE_TREEHOUSE_ARGSFILE="$TREEHOUSE_ARGSFILE" \
    FM_FAKE_SENDKEYS_LOG="$SENDKEYS_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# The crew agent inherits whatever the pane's shell has. An interactive
# `treehouse get` runs that shell as a child of treehouse, so the pool HOME would
# become the agent's HOME - wrong ~/.claude, wrong git config, wrong gh
# credentials. Firstmate must therefore send the pane a cd and nothing else.
test_pane_is_sent_a_cd_and_never_a_home_changing_command() {
  local rec id out status
  id=settle-pane-cd-z3
  rec=$(make_settle_case settle-pane-cd "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_grep "cd '$WT_DIR'" "$SENDKEYS_LOG" \
    "the pane was never sent a cd into the leased worktree"
  # Match the invocation, not the bare word: firstmate's own checkout is itself a
  # treehouse pool path, so it appears inside the launch command legitimately.
  assert_no_grep "treehouse get" "$SENDKEYS_LOG" \
    "the pane was sent a treehouse get, which would run the agent's shell under the pool HOME"
  assert_no_grep "HOME=" "$SENDKEYS_LOG" \
    "the pane was sent a HOME assignment, which the agent would inherit"
  pass "the pane receives a plain cd and nothing that changes its HOME"
}

# The pool is selected solely by the HOME treehouse runs under, so that override
# reaching the treehouse process - and carrying --lease - is the mechanism.
test_treehouse_is_leased_under_the_resolved_pool_home() {
  local rec id out status expected_home recorded_home
  id=settle-pool-home-z4
  rec=$(make_settle_case settle-pool-home "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_grep "--lease" "$TREEHOUSE_ARGSFILE" "treehouse was not invoked with --lease"
  assert_grep "fm-$id" "$TREEHOUSE_ARGSFILE" "the lease did not record this task as its holder"
  expected_home=$(bash -c '. "$1"; fm_treehouse_pool_home "$2"' _ "$LIB" "$PROJ_DIR")
  recorded_home=$(cat "$TREEHOUSE_HOMEFILE")
  [ "$recorded_home" = "$expected_home" ] \
    || fail "treehouse ran under HOME '$recorded_home', expected the resolved pool home '$expected_home'"
  pass "treehouse is leased under the pool HOME firstmate resolved for the repo"
}

# The lease output is the authority for worktree=. A pane that never arrives is a
# failed spawn, not a spawn that silently records some other path.
test_pane_that_never_lands_fails_the_spawn() {
  local rec id out status expected_home recorded_home
  id=settle-never-lands-z5
  rec=$(make_settle_case settle-never-lands "$id" 999999)
  read_settle_record "$rec"

  out=$(FM_SPAWN_SETTLE_POLLS=2 run_settle_spawn "$id")
  status=$?
  [ "$status" != 0 ] || fail "spawn reported success though the pane never entered the worktree"
  assert_contains "$out" "did not enter the leased worktree" \
    "the failure did not name the pane never reaching the worktree"
  [ ! -f "$HOME_DIR/state/$id.meta" ] \
    || fail "a spawn whose pane never landed still published task metadata"
  expected_home=$(bash -c '. "$1"; fm_treehouse_pool_home "$2"' _ "$LIB" "$PROJ_DIR")
  recorded_home=$(cat "$TREEHOUSE_RETURN_HOMEFILE")
  [ "$recorded_home" = "$expected_home" ] \
    || fail "abort cleanup returned under HOME '$recorded_home', expected '$expected_home'"
  pass "a pane that never enters the leased worktree fails the spawn loudly"
}

# --- bin/fm-treehouse-lib.sh decisions --------------------------------------
#
# Placement decisions are driven through a stubbed fm_treehouse_device rather than
# real mounts: a second filesystem is not something a test can rely on having, and
# the behavior under test is what these functions do with a given pair of device
# ids. FM_TEST_DEVICES holds "<path-prefix>=<device>" entries, longest-matching
# intent first. Both the raw and the physically-resolved form of every path are
# registered, because the library canonicalizes the object store with pwd -P
# (/var -> /private/var on macOS) while reading $HOME as given.
phys() {  # <path>
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

run_lib_with_devices() {  # <arg>...  (FM_TEST_BODY / FM_TEST_DEVICES in env)
  bash -c '
    . "$1"
    shift
    fm_treehouse_device() {  # <path>
      local path=$1 entry
      for entry in $FM_TEST_DEVICES; do
        case "$path" in
          "${entry%%=*}"*) printf "%s\n" "${entry#*=}"; return 0 ;;
        esac
      done
      printf "0\n"
    }
    eval "$FM_TEST_BODY"
  ' _ "$LIB" "$@"
}

test_pool_home_stays_on_the_home_filesystem_when_not_split() {
  local repo out
  repo="$TMP_ROOT/pool-home-same"
  fm_git_init_commit "$repo"
  # shellcheck disable=SC2016  # single quotes are deliberate: the body is eval'd inside the subshell
  out=$(FM_TEST_BODY='fm_treehouse_pool_home "$1"' \
    FM_TEST_DEVICES="$HOME=10 $(phys "$HOME")=10 $TMP_ROOT=10 $(phys "$TMP_ROOT")=10" \
    run_lib_with_devices "$repo")
  case "$out" in
    "$HOME"/.fm-pools/*) : ;;
    *) fail "same-filesystem repo should pool under \$HOME/.fm-pools/, got '$out'" ;;
  esac
  pass "a repo on \$HOME's filesystem pools on that filesystem"
}

# Segregation is a safety property: treehouse's prune and destroy act on a pool,
# so two projects sharing one pool means a cleanup aimed at one can reach the
# other's worktrees - including work that exists nowhere else yet.
test_each_project_gets_its_own_pool() {
  local repo_a repo_b out_a out_b
  repo_a="$TMP_ROOT/segregation-a"
  repo_b="$TMP_ROOT/segregation-b"
  fm_git_init_commit "$repo_a"
  fm_git_init_commit "$repo_b"
  # shellcheck disable=SC2016  # single quotes are deliberate: the body is eval'd inside the subshell
  out_a=$(FM_TEST_BODY='fm_treehouse_pool_home "$1"' \
    FM_TEST_DEVICES="$HOME=10 $(phys "$HOME")=10 $TMP_ROOT=10 $(phys "$TMP_ROOT")=10" \
    run_lib_with_devices "$repo_a")
  # shellcheck disable=SC2016  # single quotes are deliberate: the body is eval'd inside the subshell
  out_b=$(FM_TEST_BODY='fm_treehouse_pool_home "$1"' \
    FM_TEST_DEVICES="$HOME=10 $(phys "$HOME")=10 $TMP_ROOT=10 $(phys "$TMP_ROOT")=10" \
    run_lib_with_devices "$repo_b")
  [ -n "$out_a" ] && [ -n "$out_b" ] || fail "pool home resolution produced an empty path"
  [ "$out_a" != "$out_b" ] \
    || fail "two projects resolved to the same pool '$out_a'; a prune for one could reach the other"
  case "$out_a" in *segregation-a-*) : ;; *) fail "pool '$out_a' does not name its project" ;; esac
  case "$out_b" in *segregation-b-*) : ;; *) fail "pool '$out_b' does not name its project" ;; esac
  pass "each project resolves to its own pool root"
}

# Same directory name, different location: the discriminator must still separate
# them, or a prune for one project would reach the other's worktrees.
test_same_named_projects_do_not_share_a_pool() {
  local repo_a repo_b out_a out_b
  repo_a="$TMP_ROOT/copy-one/samename"
  repo_b="$TMP_ROOT/copy-two/samename"
  fm_git_init_commit "$repo_a"
  fm_git_init_commit "$repo_b"
  # shellcheck disable=SC2016  # single quotes are deliberate: the body is eval'd inside the subshell
  out_a=$(FM_TEST_BODY='fm_treehouse_pool_home "$1"' \
    FM_TEST_DEVICES="$HOME=10 $(phys "$HOME")=10 $TMP_ROOT=10 $(phys "$TMP_ROOT")=10" \
    run_lib_with_devices "$repo_a")
  # shellcheck disable=SC2016  # single quotes are deliberate: the body is eval'd inside the subshell
  out_b=$(FM_TEST_BODY='fm_treehouse_pool_home "$1"' \
    FM_TEST_DEVICES="$HOME=10 $(phys "$HOME")=10 $TMP_ROOT=10 $(phys "$TMP_ROOT")=10" \
    run_lib_with_devices "$repo_b")
  [ "$out_a" != "$out_b" ] \
    || fail "two same-named projects shared pool '$out_a'"
  pass "two projects with the same directory name still get separate pools"
}

test_pool_home_moves_to_the_object_store_filesystem_when_split() {
  local repo out expected
  repo="$TMP_ROOT/pool-home-split"
  fm_git_init_commit "$repo"
  # Everything under TMP_ROOT is device 77, $HOME is 10, and TMP_ROOT's parent is
  # unregistered (0) - so the mount-point walk stops exactly at TMP_ROOT.
  expected=$(phys "$TMP_ROOT")
  # shellcheck disable=SC2016  # single quotes are deliberate: the body is eval'd inside the subshell
  out=$(FM_TEST_BODY='fm_treehouse_pool_home "$1"' \
    FM_TEST_DEVICES="$HOME=10 $(phys "$HOME")=10 $TMP_ROOT=77 $(phys "$TMP_ROOT")=77" \
    run_lib_with_devices "$repo")
  [ -n "$out" ] || fail "split repo produced no pool home"
  [ "$out" != "$HOME" ] \
    || fail "a repo on another filesystem must not use \$HOME's pool"
  case "$out" in
    "$expected"/.fm-pools/*) : ;;
    *) fail "split repo should pool under $expected/.fm-pools/, got '$out'" ;;
  esac
  pass "a repo on another filesystem pools at that filesystem's mount point"
}

test_colocation_check_separates_split_from_undeterminable() {
  local repo repo_phys status
  repo="$TMP_ROOT/colocation-check"
  fm_git_init_commit "$repo"
  repo_phys=$(phys "$repo")
  status=0
  # shellcheck disable=SC2016  # single quotes are deliberate: the body is eval'd inside the subshell
  FM_TEST_BODY='fm_treehouse_worktree_colocated "$1"' \
    FM_TEST_DEVICES="$repo=42 $repo_phys=42" \
    run_lib_with_devices "$repo" >/dev/null || status=$?
  expect_code 0 "$status" "a worktree sharing its object store's filesystem should report colocated"
  status=0
  # shellcheck disable=SC2016  # single quotes are deliberate: the body is eval'd inside the subshell
  FM_TEST_BODY='fm_treehouse_worktree_colocated "$1"' \
    FM_TEST_DEVICES="$repo_phys/.git=99 $repo/.git=99 $repo=42 $repo_phys=42" \
    run_lib_with_devices "$repo" >/dev/null || status=$?
  expect_code 1 "$status" "a worktree split from its object store should report split"
  status=0
  # shellcheck disable=SC2016  # single quotes are deliberate: the body is eval'd inside the subshell
  FM_TEST_BODY='fm_treehouse_worktree_colocated "$1"' \
    FM_TEST_DEVICES="" \
    run_lib_with_devices "$TMP_ROOT/not-a-repo-at-all" >/dev/null || status=$?
  expect_code 2 "$status" "a path with no resolvable object store should report undeterminable, not split"
  pass "the colocation check distinguishes colocated, split, and undeterminable"
}

test_mount_point_resolves_to_a_real_ancestor() {
  local out
  out=$(bash -c '. "$1"; fm_treehouse_mount_point "$2"' _ "$LIB" "$TMP_ROOT")
  [ -n "$out" ] && [ -d "$out" ] \
    || fail "mount point of $TMP_ROOT did not resolve to a directory (got '$out')"
  case "$(phys "$TMP_ROOT")" in
    "$out"*) : ;;
    *) fail "mount point '$out' is not an ancestor of $TMP_ROOT" ;;
  esac
  pass "the mount-point walk resolves to a real ancestor directory"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_pane_is_sent_a_cd_and_never_a_home_changing_command
test_treehouse_is_leased_under_the_resolved_pool_home
test_pane_that_never_lands_fails_the_spawn
test_pool_home_stays_on_the_home_filesystem_when_not_split
test_each_project_gets_its_own_pool
test_same_named_projects_do_not_share_a_pool
test_pool_home_moves_to_the_object_store_filesystem_when_split
test_colocation_check_separates_split_from_undeterminable
test_mount_point_resolves_to_a_real_ancestor

echo "# all fm-spawn-worktree-settle tests passed"
