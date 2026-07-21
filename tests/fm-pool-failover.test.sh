#!/usr/bin/env bash
# Behavior tests for fm-pool-failover.sh: moving a running task to another account.
#
# The dirty-worktree refusal is the safety-critical case here. A failover
# abandons the old worktree, so uncommitted work would be destroyed; these tests
# pin that it refuses, that it says why, and that it changes nothing on refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAILOVER="$ROOT/bin/fm-pool-failover.sh"
TMP_ROOT=$(fm_test_tmproot fm-pool-failover)
mkdir -p "$TMP_ROOT"

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  fm_fake_exit0 "$fakebin" treehouse
  fm_fake_exit0 "$fakebin" tmux
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/keys" "$home/projects"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$name"
  cat > "$home/config/dispatch-pool.json" <<'JSON'
{
  "backends": [
    { "id": "claude-1", "harness": "claude" },
    { "id": "claude-2", "harness": "claude" }
  ]
}
JSON
  cat > "$home/state/$id.meta" <<META
window=firstmate:fm-$id
worktree=$wt
project=$proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$id
model=default
effort=default
pool_backend=claude-1
META
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

failover() {
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POOL_KEY_DIR="$home/keys" PATH="$fakebin:$PATH" \
    "$FAILOVER" "$@" 2>&1
}

# Commit something on a task branch so the worktree looks like real work in flight.
commit_work() {
  local wt=$1
  printf 'work in progress\n' > "$wt/feature.txt"
  git -C "$wt" add feature.txt
  git -C "$wt" commit -qm 'task work' >/dev/null
}

test_refuses_a_dirty_worktree() {
  local rec id out status brief_before brief_after
  id=failover-dirty-a1
  rec=$(make_case failover-dirty "$id")
  read_case "$rec"
  commit_work "$WT_DIR"
  printf 'uncommitted and precious\n' > "$WT_DIR/unsaved.txt"
  brief_before=$(cat "$HOME_DIR/data/$id/brief.md")

  set +e
  out=$(failover "$HOME_DIR" "$FAKEBIN_DIR" "$id")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a dirty worktree must be refused"
  case "$out" in
    *"REFUSED"*"uncommitted changes"*) ;;
    *) fail "the refusal should name uncommitted changes, got: $out" ;;
  esac
  case "$out" in
    *"unsaved.txt"*) ;;
    *) fail "the refusal should show WHAT is uncommitted, got: $out" ;;
  esac
  brief_after=$(cat "$HOME_DIR/data/$id/brief.md")
  [ "$brief_before" = "$brief_after" ] || fail "a refused failover must not touch the brief"
  [ ! -f "$HOME_DIR/state/.pool-cooldown-claude-1" ] \
    || fail "a refused failover must not cool the old account down"
  [ -f "$WT_DIR/unsaved.txt" ] || fail "a refused failover must leave the worktree alone"
  pass "a dirty worktree is refused, with the reason, and nothing is changed"
}

test_succeeds_on_a_clean_worktree() {
  local rec id out status note tip
  id=failover-clean-b1
  rec=$(make_case failover-clean "$id")
  read_case "$rec"
  commit_work "$WT_DIR"
  tip=$(git -C "$WT_DIR" rev-parse --short HEAD)

  set +e
  out=$(failover "$HOME_DIR" "$FAKEBIN_DIR" "$id" --no-respawn)
  status=$?
  set -e
  expect_code 0 "$status" "a clean worktree should fail over: $out"
  case "$out" in
    *"account   claude-1 -> claude-2"*) ;;
    *) fail "the move should name both accounts, got: $out" ;;
  esac
  [ -f "$HOME_DIR/state/.pool-cooldown-claude-1" ] \
    || fail "the wedged account should be cooled down"

  note=$(cat "$HOME_DIR/data/$id/brief.md")
  case "$note" in
    *"# RESUME NOTE ("*) ;;
    *) fail "a RESUME NOTE should be appended, got: $note" ;;
  esac
  case "$note" in
    *"Your work is safe"*) ;;
    *) fail "the RESUME NOTE should state the work is safe, got: $note" ;;
  esac
  case "$note" in
    *"$tip"*) ;;
    *) fail "the RESUME NOTE should name the tip commit $tip, got: $note" ;;
  esac
  case "$note" in
    *"git checkout fm/failover-clean"*) ;;
    *) fail "the RESUME NOTE should give the branch recovery command, got: $note" ;;
  esac
  pass "a clean worktree fails over: old account cooled, RESUME NOTE names branch and tip"
}

test_refuses_a_detached_head() {
  local rec id out status
  id=failover-detached-c1
  rec=$(make_case failover-detached "$id")
  read_case "$rec"
  commit_work "$WT_DIR"
  git -C "$WT_DIR" checkout -q --detach
  set +e
  out=$(failover "$HOME_DIR" "$FAKEBIN_DIR" "$id" --no-respawn)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a detached HEAD must be refused"
  case "$out" in
    *"not on a named branch"*) ;;
    *) fail "the refusal should name the detached HEAD, got: $out" ;;
  esac
  pass "a detached HEAD is refused rather than silently losing the branch pointer"
}

test_refuses_a_default_branch() {
  local rec id out status
  id=failover-main-d1
  rec=$(make_case failover-main "$id")
  read_case "$rec"
  commit_work "$WT_DIR"
  # The project checkout already holds `main`; `master` is equally in the guard list.
  git -C "$WT_DIR" branch -qM master
  set +e
  out=$(failover "$HOME_DIR" "$FAKEBIN_DIR" "$id" --no-respawn)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a worktree on a default branch must be refused"
  case "$out" in
    *"pool machinery never operates on a default branch"*) ;;
    *) fail "the refusal should name the default-branch rule, got: $out" ;;
  esac
  pass "pool machinery refuses to operate on a default branch"
}

test_refuses_when_no_other_account_is_healthy() {
  local rec id out status
  id=failover-nowhere-e1
  rec=$(make_case failover-nowhere "$id")
  read_case "$rec"
  commit_work "$WT_DIR"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_POOL_KEY_DIR="$HOME_DIR/keys" \
    "$ROOT/bin/fm-pool.sh" cooldown claude-2 --seconds 900 >/dev/null
  set +e
  out=$(failover "$HOME_DIR" "$FAKEBIN_DIR" "$id" --no-respawn)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "failover with nowhere to go must be refused"
  case "$out" in
    *"no healthy replacement account is available"*) ;;
    *) fail "the refusal should say there is nowhere to move to, got: $out" ;;
  esac
  case "$(cat "$HOME_DIR/data/$id/brief.md")" in
    *"RESUME NOTE"*) fail "a refused failover must not append a RESUME NOTE" ;;
  esac
  pass "failover refuses when no healthy account is left, rather than moving to a dead one"
}

test_dry_run_changes_nothing() {
  local rec id out before after
  id=failover-dry-f1
  rec=$(make_case failover-dry "$id")
  read_case "$rec"
  commit_work "$WT_DIR"
  before=$(cat "$HOME_DIR/data/$id/brief.md")
  out=$(failover "$HOME_DIR" "$FAKEBIN_DIR" "$id" --dry-run)
  expect_code 0 $? "dry run should succeed: $out"
  after=$(cat "$HOME_DIR/data/$id/brief.md")
  [ "$before" = "$after" ] || fail "a dry run must not touch the brief"
  [ ! -f "$HOME_DIR/state/.pool-cooldown-claude-1" ] || fail "a dry run must not cool anything down"
  case "$out" in
    *"dry run: nothing changed"*) ;;
    *) fail "a dry run should say so, got: $out" ;;
  esac
  pass "--dry-run reports the planned move and changes nothing"
}

test_refuses_a_dirty_worktree
test_succeeds_on_a_clean_worktree
test_refuses_a_detached_head
test_refuses_a_default_branch
test_refuses_when_no_other_account_is_healthy
test_dry_run_changes_nothing

echo "# all fm-pool-failover tests passed"
