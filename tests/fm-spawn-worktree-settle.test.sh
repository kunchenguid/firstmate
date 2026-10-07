#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
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
    if [ -n "${FM_FAKE_LEASE_PATH:-}" ] && [ -f "$FM_FAKE_LEASE_PATH" ]; then
      cat "$FM_FAKE_LEASE_PATH"
      exit 0
    fi
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
    for arg in "$@"; do
      case "$arg" in
        'treehouse get '*)
          [ -z "${FM_FAKE_PANE_LOG:-}" ] || printf '%s\n' "$arg" >> "$FM_FAKE_PANE_LOG"
          if [ -n "${FM_FAKE_LEASE_PATH:-}" ]; then
            (cd "$FM_FAKE_PROJECT" && eval "$arg --lease --lease-holder spawn-test") > "$FM_FAKE_LEASE_PATH" || exit 1
            if [ "${FM_FAKE_DIRTY_LEASE:-0}" = 1 ]; then
              printf 'preserve this work\n' > "$(cat "$FM_FAKE_LEASE_PATH")/uncommitted.txt"
            fi
          fi
          ;;
      esac
    done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile project_branch
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
  printf '.env\n' > "$proj/.gitignore"
  git -C "$proj" add .gitignore
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'ignore environment file'
  project_branch=$(git -C "$proj" branch --show-current)
  git -C "$proj" push --quiet origin "$project_branch"
  git -C "$wt" merge --quiet --ff-only "$project_branch"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@" 2>&1
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

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

test_spawn_syncs_a_configured_environment_file() {
  local rec id out status
  id=settle-env-sync-z3
  rec=$(make_settle_case settle-env-sync "$id" 0)
  read_settle_record "$rec"
  printf 'test-only-content\n' > "$PROJ_DIR/.env"
  printf '%s\t%s\t.env\n' "$PROJ_DIR" "$PROJ_DIR/.env" > "$HOME_DIR/config/worktree-env-sync.tsv"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should synchronize a configured environment file"
  cmp -s "$PROJ_DIR/.env" "$WT_DIR/.env" || fail "spawn did not copy the configured environment file into its worktree"$'\n'"$out"
  git -C "$WT_DIR" check-ignore -q -- .env || fail "spawn copied an environment file to a non-ignored worktree target"
  pass "spawn synchronizes configured local environment files after worktree setup"
}

# Different clones with identical origins and basenames were sharing a pool.
# A persistent wrong-clone cwd must fail before refresh, trust, or task wiring,
# for every harness, not just Claude's later trust-store scope check.
test_foreign_clone_slot_is_never_adopted() {
  local rec id harness out status foreign foreign_slot before
  for harness in codex claude; do
    id="settle-foreign-$harness"
    rec=$(make_settle_case "$id" "$id" 100000)
    read_settle_record "$rec"
    foreign="$(dirname "$PROJ_DIR")/other/project"
    foreign_slot="$(dirname "$PROJ_DIR")/foreign-slot"
    git clone --quiet "$(git -C "$PROJ_DIR" remote get-url origin)" "$foreign"
    git -C "$foreign" worktree add --quiet --detach "$foreign_slot" HEAD
    STALE_DIR=$foreign_slot
    before=$(git -C "$foreign_slot" rev-parse HEAD)
    fm_test_fake_sleep_noop "$FAKEBIN_DIR"
    out=$(run_settle_spawn "$id" --harness "$harness")
    status=$?
    [ "$status" -ne 0 ] || fail "$harness accepted another clone's slot"
    assert_contains "$out" 'different clone' "refusal did not identify wrong-clone ownership"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail 'foreign slot published task state'
    [ ! -e "$foreign/.git/FETCH_HEAD" ] || fail 'foreign slot fetched before ownership check'
    [ "$(git -C "$foreign_slot" rev-parse HEAD)" = "$before" ] || fail 'foreign slot was reset'
    pass "$harness refuses a foreign-clone slot before any refresh or trust write"
  done
}

test_old_treehouse_refuses_before_allocation() {
  local rec id out status
  id=settle-old-treehouse
  rec=$(make_settle_case "$id" "$id" 0)
  read_settle_record "$rec"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
case "$*" in *--root*) echo 'unknown flag: --root' >&2; exit 1 ;; esac
exit 0
SH
  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail 'old Treehouse unexpectedly launched'
  assert_contains "$out" 'v2.2.0 or newer' 'missing actionable upgrade diagnostic'
  assert_contains "$out" 'no slot was acquired' 'missing safe refusal diagnostic'
  [ ! -e "$COUNTFILE" ] || fail 'old Treehouse reached allocation polling'
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail 'old Treehouse published task metadata'
  pass 'old Treehouse refuses before endpoint allocation with an upgrade diagnostic'
}

test_clone_root_is_stable_and_quoted() {
  local rec id out status root1 root2 root3 original alias linked
  id=settle-clone-root
  rec=$(make_settle_case "$id" "$id" 0)
  read_settle_record "$rec"
  export FM_FAKE_PANE_LOG="$HOME_DIR/pane.log"
  export TREEHOUSE_ROOT="$HOME_DIR/pools with 'quotes'"
  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "initial clone root spawn failed: $out"
  root1=$(grep 'treehouse get --root' "$FM_FAKE_PANE_LOG")
  [ -n "$root1" ] || fail 'spawn did not send a scoped pool command'
  original=$PROJ_DIR
  alias="$HOME_DIR/project-alias"
  ln -s "$original" "$alias"
  PROJ_DIR=$alias
  : > "$FM_FAKE_PANE_LOG"
  fm_test_spawn_brief "$HOME_DIR" "$id-alias"
  out=$(run_settle_spawn "$id-alias")
  expect_code 0 $? "alias spawn failed: $out"
  root2=$(grep 'treehouse get --root' "$FM_FAKE_PANE_LOG")
  [ "$root1" = "$root2" ] || fail 'symlink alias changed clone namespace'
  linked="$HOME_DIR/linked-project"
  git -C "$original" worktree add --quiet --detach "$linked" HEAD
  PROJ_DIR=$linked
  : > "$FM_FAKE_PANE_LOG"
  fm_test_spawn_brief "$HOME_DIR" "$id-linked"
  out=$(run_settle_spawn "$id-linked")
  expect_code 0 $? "linked project spawn failed: $out"
  root3=$(grep 'treehouse get --root' "$FM_FAKE_PANE_LOG")
  [ "$root1" = "$root3" ] || fail 'linked project changed clone namespace'
  unset FM_FAKE_PANE_LOG TREEHOUSE_ROOT
  pass 'clone pool command is stable across symlink and linked-project aliases'
}

# Use real Treehouse when installed with --root, but always with a disposable
# HOME and root. The fake terminal only replaces the interactive subshell with
# --lease; the pool command, allocation, Git checks and spawn are all real.
test_real_treehouse_keeps_same_origin_clones_separate() {
  local real rec id case_dir original_home a b wt common expected root_a root_b legacy_a legacy_b snapshot out status
  real=$(command -v treehouse || true)
  if [ -z "$real" ] || ! "$real" get --root "$TMP_ROOT" --help >/dev/null 2>&1; then
    printf '# skip real clone-pool allocation: Treehouse v2.2.0+ required\n'
    return
  fi
  id=settle-real-clones
  rec=$(make_settle_case "$id" "$id" 0)
  read_settle_record "$rec"
  case_dir=$(dirname "$PROJ_DIR")
  a=$PROJ_DIR
  b="$case_dir/other/project"
  git clone --quiet "$(git -C "$a" remote get-url origin)" "$b"
  original_home=$HOME
  export HOME="$case_dir/isolated-user"
  mkdir -p "$HOME"
  unset TREEHOUSE_ROOT
  export TREEHOUSE_NO_UPDATE_CHECK=1
  # Create the exact legacy mixed-pool shape without touching ~/.treehouse.
  legacy_a=$(cd "$a" && "$real" get --lease --lease-holder legacy-a) || fail 'legacy a allocation failed'
  legacy_b=$(cd "$b" && "$real" get --lease --lease-holder legacy-b) || fail 'legacy b allocation failed'
  [ "$(dirname "$(dirname "$legacy_a")")" = "$(dirname "$(dirname "$legacy_b")")" ] || fail 'fixture did not reproduce a shared pool'
  snapshot=$(cat "$(dirname "$(dirname "$legacy_a")")/treehouse-state.json")
  # Forward through the real executable without modifying the user's binary.
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$real" > "$FAKEBIN_DIR/treehouse"
  export FM_FAKE_LEASE_PATH="$case_dir/leased-path"
  export FM_FAKE_PROJECT="$a"
  export FM_FAKE_PANE_LOG="$case_dir/pool-command"
  export TREEHOUSE_ROOT="$HOME/pool roots with 'quotes'"
  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "real clone-a spawn failed: $out"
  wt=$(cat "$FM_FAKE_LEASE_PATH")
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)
  expected=$(git -C "$a" rev-parse --path-format=absolute --git-common-dir)
  [ "$common" = "$expected" ] || fail 'clone-a spawn acquired another clone'
  root_a=$(dirname "$(dirname "$wt")")
  assert_grep "worktree=$wt" "$HOME_DIR/state/$id.meta" 'real lease not published'
  PROJ_DIR=$b
  export FM_FAKE_PROJECT="$b"
  fm_test_spawn_brief "$HOME_DIR" "$id-b"
  out=$(run_settle_spawn "$id-b")
  status=$?
  expect_code 0 "$status" "real clone-b spawn failed: $out"
  wt=$(cat "$FM_FAKE_LEASE_PATH")
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)
  expected=$(git -C "$b" rev-parse --path-format=absolute --git-common-dir)
  [ "$common" = "$expected" ] || fail 'clone-b spawn acquired another clone'
  root_b=$(dirname "$(dirname "$wt")")
  [ "$root_a" != "$root_b" ] || fail 'separate clones still share a pool'
  (cd "$b" && "$real" return --if-lease-holder spawn-test "$wt") >/dev/null \
    || fail 'absolute-path return could not release a clone-scoped slot'
  # Abort after allocation as well: no temporary leases may touch the legacy
  # foreign slots, even when the launch cannot reach its normal completion.
  export FM_FAKE_DIRTY_LEASE=1
  fm_test_spawn_brief "$HOME_DIR" "$id-abort"
  out=$(run_settle_spawn "$id-abort")
  status=$?
  [ "$status" -ne 0 ] || fail 'dirty real allocation unexpectedly launched'
  assert_contains "$out" 'is not clean' 'abort did not hit the dirty-copy guard'
  [ ! -e "$HOME_DIR/state/$id-abort.meta" ] || fail 'aborted allocation published state'
  assert_no_grep --lease "$FM_FAKE_PANE_LOG" 'spawn created temporary durable skip leases'
  [ "$snapshot" = "$(cat "$(dirname "$(dirname "$legacy_a")")/treehouse-state.json")" ] || fail 'spawn modified the legacy mixed pool'
  case "$root_b" in "$HOME/"*) ;; *) fail 'test pool escaped isolated HOME' ;; esac
  HOME=$original_home
  export HOME
  unset FM_FAKE_LEASE_PATH FM_FAKE_PROJECT FM_FAKE_PANE_LOG FM_FAKE_DIRTY_LEASE TREEHOUSE_ROOT TREEHOUSE_NO_UPDATE_CHECK
  pass 'real Treehouse allocates own-clone slots, quotes roots, and leaves mixed legacy pools untouched'
}

test_real_treehouse_keeps_same_origin_clones_separate
test_foreign_clone_slot_is_never_adopted
test_old_treehouse_refuses_before_allocation
test_clone_root_is_stable_and_quoted
test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_spawn_syncs_a_configured_environment_file

echo "# all fm-spawn-worktree-settle tests passed"
