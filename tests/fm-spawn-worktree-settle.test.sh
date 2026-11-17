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
window_file="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}.window"
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
  list-windows) [ ! -s "$window_file" ] || cat "$window_file"; exit 0 ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    exit 0 ;;
  kill-window) : > "$window_file"; exit 0 ;;
  has-session|new-session) exit 0 ;;
  send-keys) exit 0 ;;
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
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
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

test_unborn_head_project_is_refused_at_once() {
  local rec id out status started elapsed
  id=settle-unborn-head-z5
  rec=$(make_settle_case settle-unborn "$id" 0)
  read_settle_record "$rec"
  PROJ_DIR="$TMP_ROOT/settle-unborn/unborn-project"
  git init -q "$PROJ_DIR"

  started=$SECONDS
  out=$(run_settle_spawn "$id")
  status=$?
  elapsed=$((SECONDS - started))
  expect_code 1 "$status" "spawn into a project with no commit should be refused"
  assert_contains "$out" "unborn HEAD" "the refusal did not name the unborn HEAD cause"
  assert_contains "$out" "make one commit" "the refusal did not name the remedy"
  [ "$elapsed" -lt 30 ] || fail "refusal took ${elapsed}s instead of failing before the treehouse wait"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  [ -z "$(git -C "$PROJ_DIR" rev-list --all 2>/dev/null)" ] || fail "spawn committed into the project"
  pass "a project with an unborn HEAD is refused at once with its cause named"
}

test_worker_scratch_is_excluded_from_status_and_staging() {
  local rec id out status kind before
  for kind in ship scout; do
    id="scratch-$kind-z6"
    rec=$(make_settle_case "scratch-$kind" "$id" 0)
    read_settle_record "$rec"
    # Scout and ship share the same preparation path; exercise both public
    # launch forms without starting a real model or touching the host's pool.
    if [ "$kind" = scout ]; then
      out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
        FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
        FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
        FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$WT_DIR" \
        FM_FAKE_PANE_STALE="$STALE_DIR" FM_FAKE_PANE_STALE_READS=0 \
        FM_FAKE_PANE_COUNTFILE="$COUNTFILE" PATH="$FAKEBIN_DIR:$PATH" \
        "$SPAWN" "$id" "$PROJ_DIR" --scout 2>&1)
    else
      out=$(run_settle_spawn "$id")
    fi
    status=$?
    expect_code 0 "$status" "scratch $kind spawn should succeed: $out"
    [ -d "$WT_DIR/.fm-scratch" ] || fail "$kind spawn did not create its scratch root"
    before=$(git -C "$WT_DIR" status --porcelain --untracked-files=all)
    mkdir -p "$WT_DIR/.fm-scratch/arbitrary worker name/lab"
    printf 'proof\n' > "$WT_DIR/.fm-scratch/arbitrary worker name/output.bin"
    printf 'marker\n' > "$WT_DIR/.fm-scratch/arbitrary worker name/lab/.fm-lab-home"
    git -C "$WT_DIR" init -q "$WT_DIR/.fm-scratch/nested-clone"
    printf 'nested output\n' > "$WT_DIR/.fm-scratch/nested-clone/result.txt"
    [ "$(git -C "$WT_DIR" status --porcelain --untracked-files=all)" = "$before" ] \
      || fail "$kind worker scratch leaked into git status"
    git -C "$WT_DIR" add -A || fail "$kind git add -A failed"
    [ -z "$(git -C "$WT_DIR" diff --cached --name-only -- .fm-scratch)" ] \
      || fail "$kind git add -A staged worker scratch"
    # The exclusion is rooted. A project-owned directory with the same leaf
    # name below a source directory must remain visible.
    mkdir -p "$WT_DIR/src/.fm-scratch"
    printf 'project data\n' > "$WT_DIR/src/.fm-scratch/keep.txt"
    git -C "$WT_DIR" add -A || fail "$kind project add -A failed"
    git -C "$WT_DIR" diff --cached --name-only -- src/.fm-scratch/keep.txt | grep -q keep.txt \
      || fail "$kind scratch exclusion hid a project path outside the reserved root"
  done
  pass "spawned ship and scout scratch stays out of git status and git add -A"
}

test_worker_scratch_collisions_refuse_launch() {
  local rec id kind out status exclude
  for kind in tracked symlink file unignored; do
    id="scratch-collision-$kind-z7"
    rec=$(make_settle_case "scratch-collision-$kind" "$id" 0)
    read_settle_record "$rec"
    exclude=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
    case "$kind" in
      tracked)
        mkdir "$WT_DIR/.fm-scratch"
        printf 'project content\n' > "$WT_DIR/.fm-scratch/keep.txt"
        git -C "$WT_DIR" add .fm-scratch/keep.txt
        git -C "$WT_DIR" commit -qm 'track project content'
        # Fresh spawn resets to origin/main. Put the collision on that
        # fixture base, not on a side branch the reset intentionally drops.
        git -C "$PROJ_DIR.origin.git" fetch -q "$WT_DIR" HEAD:refs/heads/main
        ;;
      symlink)
        printf '/.fm-scratch\n' >> "$exclude"
        ln -s "$STALE_DIR" "$WT_DIR/.fm-scratch"
        ;;
      file)
        printf '/.fm-scratch\n' >> "$exclude"
        printf 'project content\n' > "$WT_DIR/.fm-scratch"
        ;;
      unignored)
        printf '/.gitignore\n' >> "$exclude"
        printf '!/.fm-scratch/\n' > "$WT_DIR/.gitignore"
        ;;
    esac
    out=$(run_settle_spawn "$id")
    status=$?
    [ "$status" -ne 0 ] || fail "spawn accepted $kind scratch collision"
    if [ "$kind" = unignored ]; then
      assert_contains "$out" 'refusing to launch with visible worker scratch' "ineffective exclusion did not stop launch"
    else
      assert_contains "$out" 'refusing to reserve worker scratch' "collision did not explain the reserved path"
    fi
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "scratch collision published task metadata"
    case "$kind" in
      tracked) assert_present "$WT_DIR/.fm-scratch/keep.txt" "tracked scratch collision was removed" ;;
      symlink) [ -L "$WT_DIR/.fm-scratch" ] || fail "scratch symlink was changed" ;;
      file) assert_present "$WT_DIR/.fm-scratch" "scratch file collision was removed" ;;
      unignored) assert_grep '!/.fm-scratch/' "$WT_DIR/.gitignore" "spawn changed project ignore rules" ;;
    esac
  done
  pass "spawn refuses scratch path collisions and project rules that defeat its exclusion"
}

test_gate_worktree_scratch_uses_tracked_exclusion() {
  local case_dir primary gate lab rc
  case_dir="$TMP_ROOT/gate-scratch"
  primary="$case_dir/primary"
  gate="$case_dir/gate-wt"
  fm_git_init_commit "$primary"
  cp "$ROOT/.gitignore" "$primary/.gitignore"
  git -C "$primary" add .gitignore
  git -C "$primary" commit -qm 'ignore reserved scratch'
  printf '/.worker-only/\n' >> "$primary/.git/info/exclude"
  git clone -q --bare "$primary" "$case_dir/gate.git"
  git --git-dir="$case_dir/gate.git" worktree add -q "$gate" -b gate
  mkdir -p "$gate/.worker-only" "$gate/.fm-scratch/arbitrary worker name" "$gate/src/.fm-scratch"
  rc=0
  git -C "$gate" check-ignore -q .worker-only/ || rc=$?
  expect_code 1 "$rc" 'gate fixture inherited the worker-only exclusion'
  lab=$(mktemp -d "$gate/.fm-scratch/fm-lab.XXXXXX")
  "$ROOT/bin/fm-lab-home.sh" create "$lab" >/dev/null || fail 'gate lab creation failed'
  assert_present "$lab/.fm-lab-home" 'gate lab marker missing'
  printf 'proof\n' > "$gate/.fm-scratch/arbitrary worker name/output.bin"
  git init -q "$gate/.fm-scratch/nested-clone"
  printf 'nested proof\n' > "$gate/.fm-scratch/nested-clone/output.bin"
  printf 'project content\n' > "$gate/src/.fm-scratch/keep.txt"
  [ -z "$(git -C "$gate" status --porcelain --untracked-files=all -- .fm-scratch)" ] \
    || fail 'gate scratch leaked into git status'
  git -C "$gate" add -A || fail 'gate git add -A failed'
  [ -z "$(git -C "$gate" diff --cached --name-only -- .fm-scratch)" ] \
    || fail 'gate git add -A staged scratch or lab markers'
  git -C "$gate" diff --cached --name-only -- src/.fm-scratch/keep.txt | grep -q keep.txt \
    || fail 'gate exclusion hid a project path outside the reserved root'
  pass 'gate scratch and lab markers stay ignored without worker info/exclude'
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_unborn_head_project_is_refused_at_once
test_worker_scratch_is_excluded_from_status_and_staging
test_worker_scratch_collisions_refuse_launch
test_gate_worktree_scratch_uses_tracked_exclusion

echo "# all fm-spawn-worktree-settle tests passed"
