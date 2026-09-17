#!/usr/bin/env bash
# Behavioral coverage for scoped, remotely reconstructable task workspaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

WORKSPACE="$ROOT/bin/fm-workspace.sh"
LIB="$ROOT/bin/fm-workspace-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-workspace)

make_case() {  # <name> [backend]
  local name=$1 backend=${2:-tmux} d home project origin wt fake head
  d="$TMP_ROOT/$name"
  home="$d/home"
  project="$d/project"
  origin="$d/origin.git"
  wt="$d/scoped/home-a/repo-pool/1/repo"
  fake="$d/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fake" "$(dirname "$wt")"
  git init -q --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git clone -q "$origin" "$project" 2>/dev/null
  git -C "$project" commit -q --allow-empty -m base
  git -C "$project" push -q origin main
  git -C "$project" remote set-head origin main
  git -C "$project" worktree add -q -b "fm/task-x1" "$wt" main
  printf 'feature\n' > "$wt/feature.txt"
  git -C "$wt" add feature.txt
  git -C "$wt" commit -q -m feature
  head=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" push -q origin HEAD:refs/heads/fm/task-x1
  git -C "$wt" push -q origin HEAD:refs/pull/7/head
  mkdir -p "$d/scoped/home-a/repo-pool"
  printf '{}\n' > "$d/scoped/home-a/repo-pool/treehouse-state.json"

  cat > "$fake/gh" <<SH
#!/usr/bin/env bash
printf '%s\t%s\t%s\t%s\t%s\n' OPEN '$head' 'fm/task-x1' 'fm/lower-stack' 'https://github.com/example/repo/pull/7'
SH
  cat > "$fake/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
root=
if [ "${1:-}" = --root ]; then root=$2; shift 2; fi
case "${1:-}" in
  return)
    target=${@: -1}
    git -C "$target" checkout -q --detach main
    git -C "$target" reset -q --hard main
    git -C "$target" clean -q -fdx
    ;;
  destroy)
    target=$2
    if [ -n "${FM_TEST_DESTROY_FAIL_ONCE:-}" ] && [ ! -e "$FM_TEST_DESTROY_FAIL_ONCE" ]; then
      : > "$FM_TEST_DESTROY_FAIL_ONCE"
      exit 1
    fi
    [ ! -e "$target" ] || git -C "$FM_TEST_PROJECT" worktree remove --force "$target"
    ;;
  get)
    count_file="$FM_TEST_TREEHOUSE_COUNT"
    count=$(cat "$count_file" 2>/dev/null || printf 1)
    target="$root/restored-pool/$count/repo"
    mkdir -p "$(dirname "$target")"
    git -C "$FM_TEST_PROJECT" worktree add -q --detach "$target" main
    printf '%s\n' $((count + 1)) > "$count_file"
    printf '%s\n' "$target"
    ;;
  prune)
    printf '%s\n' "$*" >> "$FM_TEST_PRUNE_LOG"
    ;;
esac
SH
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '@pane\n' ;;
  send-keys) ;;
esac
exit 0
SH
  cat > "$fake/orca" <<'SH'
#!/usr/bin/env bash
printf '{}\n'
SH
  chmod +x "$fake/gh" "$fake/treehouse" "$fake/tmux" "$fake/orca"

  {
    printf 'window=firstmate:fm-task-x1\n'
    printf 'endpoint_task_id=task-x1\n'
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$project"
    printf 'harness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\n'
    printf 'spawn_gen=test-generation\n'
    printf 'workspace_state=active\nworkspace_root=%s\n' "$d/scoped/home-a"
    printf 'pr=https://github.com/example/repo/pull/7\npr_head=%s\n' "$head"
    case "$backend" in
      tmux) ;;
      herdr) printf 'backend=herdr\nwindow=lab:pane\nherdr_session=lab\nherdr_workspace_id=ws\nherdr_tab_id=tab\nherdr_pane_id=pane\n' ;;
      zellij) printf 'backend=zellij\nwindow=lab:7\nzellij_session=lab\nzellij_tab_id=tab\nzellij_pane_id=7\n' ;;
      cmux) printf 'backend=cmux\nwindow=ws:surface\ncmux_workspace_id=ws\ncmux_surface_id=surface\n' ;;
      orca) printf 'backend=orca\nwindow=fm-task-x1\nterminal=terminal-1\norca_worktree_id=worktree-1\n' ;;
    esac
  } > "$home/state/task-x1.meta"
  chmod 0600 "$home/state/task-x1.meta"
  printf '%s|%s|%s|%s|%s|%s\n' "$d" "$home" "$project" "$wt" "$fake" "$head"
}

read_case() { IFS='|' read -r D HOME_DIR PROJECT WT FAKEBIN HEAD <<EOF
$1
EOF
}

run_workspace() {
  FM_HOME="$HOME_DIR" FM_WORKSPACE_ROOT_BASE="$D/scoped-base" \
  FM_TEST_PROJECT="$PROJECT" FM_TEST_TREEHOUSE_COUNT="$D/treehouse-count" \
  FM_TEST_PRUNE_LOG="$D/prune.log" PATH="$FAKEBIN:$PATH" \
    "$WORKSPACE" "$@" 2>&1
}

test_two_homes_are_collision_proof() {
  local project h1 h2 r1 r2
  project="$TMP_ROOT/scope-project"
  h1="$TMP_ROOT/scope-home-a"
  h2="$TMP_ROOT/scope-home-b"
  mkdir -p "$project" "$h1" "$h2"
  git init -q "$project"
  r1=$(FM_HOME="$h1" FM_WORKSPACE_ROOT_BASE="$TMP_ROOT/scopes" bash -c '. "$1"; fm_workspace_root_for_home "$FM_HOME"' _ "$LIB")
  r2=$(FM_HOME="$h2" FM_WORKSPACE_ROOT_BASE="$TMP_ROOT/scopes" bash -c '. "$1"; fm_workspace_root_for_home "$FM_HOME"' _ "$LIB")
  [ "$r1" != "$r2" ] || fail "two homes resolved the same workspace root"
  case "$r1$r2" in *"$HOME/.treehouse"*) fail "a scoped root fell back to the global Treehouse pool" ;; esac
  mkdir -p "$TMP_ROOT/root-shape/.treehouse/repo-pool/1/repo"
  printf '{}\n' > "$TMP_ROOT/root-shape/.treehouse/repo-pool/treehouse-state.json"
  [ "$(bash -c '. "$1"; fm_workspace_root_from_worktree "$2"' _ "$LIB" "$TMP_ROOT/root-shape/.treehouse/repo-pool/1/repo")" = "$TMP_ROOT/root-shape" ] \
    || fail "Treehouse's .treehouse pool shape did not resolve to its configured root"
  pass "two Firstmate homes using one project resolve collision-proof non-global roots"
}

test_release_and_exact_stacked_restore() {
  local rec out restored
  rec=$(make_case release-restore)
  read_case "$rec"
  out=$(run_workspace release task-x1) || fail "clean remote-preserved release failed: $out"
  [ ! -d "$WT" ] || fail "release retained the local task workspace"
  assert_grep 'workspace_state=released' "$HOME_DIR/state/task-x1.meta" "release state was not durable"
  assert_grep 'workspace_base=fm/lower-stack' "$HOME_DIR/state/task-x1.meta" "stacked PR base was not preserved"
  assert_grep "workspace_head=$HEAD" "$HOME_DIR/state/task-x1.meta" "exact remote head was not preserved"

  out=$(run_workspace restore task-x1) || fail "exact reconstruction failed: $out"
  restored=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/task-x1.meta")
  [ -d "$restored" ] || fail "restore did not create a local workspace"
  [ "$(git -C "$restored" rev-parse HEAD)" = "$HEAD" ] || fail "restore did not use the exact PR head"
  [ "$(git -C "$restored" symbolic-ref --short HEAD)" = fm/task-x1 ] || fail "restore did not recreate the PR branch"
  assert_grep 'workspace_state=restored' "$HOME_DIR/state/task-x1.meta" "restore did not publish its relaunch handoff"
  pass "an open stacked PR releases locally and reconstructs its exact head and branch"
}

test_dirty_and_unpushed_refuse() {
  local rec out local_head
  rec=$(make_case dirty)
  read_case "$rec"
  printf 'secret=keep\n' > "$WT/.env"
  out=$(run_workspace release task-x1) && fail "dirty workspace was released"
  assert_contains "$out" "dirty or untracked" "dirty refusal was not explicit"
  [ -d "$WT" ] || fail "dirty refusal removed the workspace"
  assert_grep 'workspace_state=active' "$HOME_DIR/state/task-x1.meta" "dirty refusal rewrote lifecycle state"

  rec=$(make_case unpushed)
  read_case "$rec"
  printf 'unique\n' > "$WT/unique.txt"
  git -C "$WT" add unique.txt
  git -C "$WT" commit -q -m unique
  local_head=$(git -C "$WT" rev-parse HEAD)
  out=$(run_workspace release task-x1) && fail "unpushed workspace was released"
  assert_contains "$out" "not contained in remote PR head" "unpushed refusal did not name remote containment"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$local_head" ] || fail "unpushed refusal moved the unique commit"
  pass "dirty files and commits absent from the remote PR are retained with explicit refusals"
}

test_release_cleanup_retry_is_idempotent() {
  local rec out
  rec=$(make_case release-retry)
  read_case "$rec"
  out=$(FM_TEST_DESTROY_FAIL_ONCE="$D/destroy-failed-once" run_workspace release task-x1) \
    && fail "release reported success after exact cleanup failed"
  assert_contains "$out" "retry release to reclaim" "release did not explain its safe retry"
  assert_grep 'workspace_state=reclaim-pending' "$HOME_DIR/state/task-x1.meta" \
    "failed exact cleanup did not retain its durable retry state"
  [ -d "$WT" ] || fail "failed exact cleanup lost the retained idle workspace"

  out=$(run_workspace release task-x1) || fail "release retry did not reclaim safely: $out"
  [ ! -d "$WT" ] || fail "release retry left an idle workspace behind"
  assert_grep 'workspace_state=released' "$HOME_DIR/state/task-x1.meta" \
    "release retry did not publish completion"
  pass "interrupted exact cleanup is durably and idempotently reclaimed on retry"
}

test_backend_metadata_survives_release() {
  local backend rec out key
  for backend in tmux herdr zellij cmux; do
    rec=$(make_case "backend-$backend" "$backend")
    read_case "$rec"
    out=$(run_workspace release task-x1) || fail "$backend release failed: $out"
    assert_grep 'workspace_state=released' "$HOME_DIR/state/task-x1.meta" "$backend did not release"
    case "$backend" in
      tmux) key='window=firstmate:fm-task-x1' ;;
      herdr) key='herdr_pane_id=pane' ;;
      zellij) key='zellij_pane_id=7' ;;
      cmux) key='cmux_surface_id=surface' ;;
    esac
    assert_grep "$key" "$HOME_DIR/state/task-x1.meta" "$backend endpoint identity was lost"
  done

  rec=$(make_case backend-orca orca)
  read_case "$rec"
  out=$(run_workspace release task-x1) || fail "Orca release failed: $out"
  assert_grep 'workspace_state=released' "$HOME_DIR/state/task-x1.meta" "Orca did not release"
  assert_grep 'orca_worktree_id=worktree-1' "$HOME_DIR/state/task-x1.meta" "Orca reconstruction identity was lost"
  pass "release applies across tmux, Herdr, zellij, Orca, and cmux without losing endpoint identity"
}

test_legacy_audit_and_reclaim_stay_conservative() {
  local rec out log
  rec=$(make_case legacy-audit)
  read_case "$rec"
  : > "$D/prune.log"
  out=$(run_workspace audit-legacy "$D/legacy") || fail "legacy audit failed: $out"
  out=$(run_workspace reclaim-legacy "$D/legacy") || fail "legacy reclaim failed: $out"
  log=$(cat "$D/prune.log")
  assert_contains "$log" "prune --all --verbose" "audit did not use Treehouse's classifier"
  assert_contains "$log" "prune --all --verbose --yes" "reclaim did not execute the conservative candidates"
  assert_not_contains "$log" "prune-orphans" "legacy reclaim opted into unverified orphan deletion"
  assert_not_contains "$log" "include-unlanded" "legacy reclaim opted into unique-work deletion"
  pass "legacy global-pool audit and reclaim never opt into deleting unique or unverified work"
}

test_two_homes_are_collision_proof
test_release_and_exact_stacked_restore
test_dirty_and_unpushed_refuse
test_release_cleanup_retry_is_idempotent
test_backend_metadata_survives_release
test_legacy_audit_and_reclaim_stay_conservative
printf '# all fm-workspace tests passed\n'
