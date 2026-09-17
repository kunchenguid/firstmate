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
  printf '%s\n' '.env' '*.pem' '*.sqlite' 'run/' 'node_modules/' '.venv/' 'build/' > "$wt/.gitignore"
  git -C "$wt" add feature.txt .gitignore
  git -C "$wt" commit -q -m feature
  head=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" push -q origin HEAD:refs/heads/fm/task-x1
  git -C "$wt" push -q origin HEAD:refs/pull/7/head
  mkdir -p "$d/scoped/home-a/repo-pool"
  printf '{}\n' > "$d/scoped/home-a/repo-pool/treehouse-state.json"

  printf '%s\t%s\t%s\t%s\t%s\n' OPEN "$head" 'fm/task-x1' 'fm/lower-stack' \
    'https://github.com/example/repo/pull/7' > "$fake/pr-7.tsv"
  cat > "$fake/gh" <<'SH'
#!/usr/bin/env bash
# gh pr view <url> --json ... -q ...: one recorded forge row per PR number.
dir=$(dirname "$0")
[ ! -e "$dir/gh-unavailable" ] || exit 1
row="$dir/pr-${3##*/}.tsv"
[ -f "$row" ] || exit 1
cat "$row"
SH
  cat > "$fake/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
root=
if [ "${1:-}" = --root ]; then root=$2; shift 2; fi
[ -z "${FM_TEST_TREEHOUSE_LOG:-}" ] || printf 'root=%s %s\n' "$root" "$*" >> "$FM_TEST_TREEHOUSE_LOG"
case "${1:-}" in
  return)
    target=${@: -1}
    git -C "$target" checkout -q --detach main
    git -C "$target" reset -q --hard main
    git -C "$target" clean -q -fdx
    if [ -n "${FM_TEST_RETURN_DIES_AFTER:-}" ] && [ ! -e "$FM_TEST_RETURN_DIES_AFTER" ]; then
      : > "$FM_TEST_RETURN_DIES_AFTER"
      exit 1
    fi
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
[ -z "${FM_TEST_BACKEND_LOG:-}" ] || printf 'tmux %s\n' "$*" >> "$FM_TEST_BACKEND_LOG"
case "${1:-}" in
  display-message)
    [ -z "${FM_TEST_ENDPOINT_MISSING:-}" ] || exit 1
    printf '@pane\n'
    ;;
  list-windows) ;;
  new-window) printf '@9\n' ;;
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
  FM_TEST_PRUNE_LOG="$D/prune.log" FM_TEST_TREEHOUSE_LOG="$D/treehouse.log" \
  FM_TEST_BACKEND_LOG="$D/backend.log" TMUX='' PATH="$FAKEBIN:$PATH" \
    "${WORKSPACE_BIN:-$WORKSPACE}" "$@" 2>&1
}

# The merge monitor validates a task record through bin/fm-pr-lib.sh's identity
# parser; a lifecycle rewrite must leave the record readable to it.
pr_identity_readable() {
  bash -c '. "$1"; fm_pr_metadata_identity_parse "$2" && [ "$FM_PR_META_NUMBER" = 7 ]' _ \
    "$ROOT/bin/fm-pr-lib.sh" "$HOME_DIR/state/task-x1.meta"
}

meta_value() { sed -n "s/^$1=//p" "$HOME_DIR/state/${2:-task-x1}.meta" | tail -1; }

# A copy of bin/ whose session-provider adapters are replaced at their function
# boundary, so restore's per-backend endpoint branches run for real through
# bin/fm-backend.sh's dispatch without needing each provider's live CLI.
STUB_ROOT=
make_stub_root() {
  local backends
  [ -z "$STUB_ROOT" ] || return 0
  STUB_ROOT="$TMP_ROOT/stub-root"
  mkdir -p "$STUB_ROOT"
  cp -R "$ROOT/bin" "$STUB_ROOT/bin"
  backends="$STUB_ROOT/bin/backends"
  cat > "$backends/herdr.sh" <<'SH'
_stub_log() { printf '%s\n' "$*" >> "$FM_TEST_BACKEND_LOG"; }
fm_backend_herdr_cli() { _stub_log "herdr cli $*"; [ -z "${FM_TEST_ENDPOINT_MISSING:-}" ]; }
fm_backend_herdr_container_ensure() { _stub_log "herdr container_ensure $*"; printf 'lab2:ws2\tseed2'; }
fm_backend_herdr_create_task() { _stub_log "herdr create_task $*"; printf 'tab9 pane9\n'; }
fm_backend_herdr_send_text_line() { _stub_log "herdr send $*"; }
SH
  cat > "$backends/zellij.sh" <<'SH'
_stub_log() { printf '%s\n' "$*" >> "$FM_TEST_BACKEND_LOG"; }
fm_backend_zellij_target_ready() { _stub_log "zellij target_ready $*"; [ -z "${FM_TEST_ENDPOINT_MISSING:-}" ]; }
fm_backend_zellij_container_ensure() { _stub_log "zellij container_ensure"; printf 'lab2'; }
fm_backend_zellij_create_task() { _stub_log "zellij create_task $*"; printf 'tab9 9\n'; }
fm_backend_zellij_send_text_line() { _stub_log "zellij send $*"; }
SH
  cat > "$backends/cmux.sh" <<'SH'
_stub_log() { printf '%s\n' "$*" >> "$FM_TEST_BACKEND_LOG"; }
fm_backend_cmux_target_ready() { _stub_log "cmux target_ready $*"; [ -z "${FM_TEST_ENDPOINT_MISSING:-}" ]; }
fm_backend_cmux_container_ensure() { _stub_log "cmux container_ensure"; }
fm_backend_cmux_create_task() { _stub_log "cmux create_task $*"; printf 'ws9 surface9\n'; }
fm_backend_cmux_send_text_line() { _stub_log "cmux send $*"; }
SH
  cat > "$backends/orca.sh" <<'SH'
_stub_log() { printf '%s\n' "$*" >> "$FM_TEST_BACKEND_LOG"; }
fm_backend_orca_worktree_create() {
  local target="$FM_TEST_ORCA_DIR/$2"
  _stub_log "orca worktree_create $*"
  git -C "$1" worktree add -q --detach "$target" main || return 1
  printf 'orca-wt-new\t%s' "$target"
}
fm_backend_orca_terminal_create() {
  _stub_log "orca terminal_create $*"
  [ -z "${FM_TEST_ORCA_TERMINAL_FAILS:-}" ] || return 1
  printf 'terminal-new'
}
fm_backend_orca_kill() { _stub_log "orca kill $*"; }
fm_backend_orca_remove_worktree() {
  _stub_log "orca remove_worktree $*"
  case "$1" in
    orca-wt-new) git -C "$FM_TEST_PROJECT" worktree remove --force "$FM_TEST_ORCA_DIR/fm-task-x1" ;;
    *) [ -z "${FM_TEST_ORCA_OLD_WT:-}" ] || git -C "$FM_TEST_PROJECT" worktree remove --force "$FM_TEST_ORCA_OLD_WT" ;;
  esac
}
SH
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
  pr_identity_readable || fail "release left a record the PR merge monitor can no longer validate"

  out=$(run_workspace restore task-x1) || fail "exact reconstruction failed: $out"
  restored=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/task-x1.meta")
  [ -d "$restored" ] || fail "restore did not create a local workspace"
  [ "$(git -C "$restored" rev-parse HEAD)" = "$HEAD" ] || fail "restore did not use the exact PR head"
  [ "$(git -C "$restored" symbolic-ref --short HEAD)" = fm/task-x1 ] || fail "restore did not recreate the PR branch"
  assert_grep 'workspace_state=restored' "$HOME_DIR/state/task-x1.meta" "restore did not publish its relaunch handoff"
  pr_identity_readable || fail "restore left a record the PR merge monitor can no longer validate"
  pass "an open stacked PR releases locally and reconstructs its exact head and branch"
}

test_dirty_and_unpushed_refuse() {
  local rec out local_head
  rec=$(make_case dirty)
  read_case "$rec"
  printf 'keep\n' > "$WT/scratch-notes.txt"
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

test_two_homes_share_one_project() {
  local rec out head_b wt_b home_b root_a root_b restored_a restored_b
  rec=$(make_case two-homes)
  read_case "$rec"
  home_b="$D/home-b"
  root_a="$D/scoped/home-a"
  root_b="$D/scoped/home-b"
  wt_b="$root_b/repo-pool/1/repo"
  mkdir -p "$home_b/state" "$root_b/repo-pool/1"
  printf '{}\n' > "$root_b/repo-pool/treehouse-state.json"
  git -C "$PROJECT" worktree add -q -b fm/task-y1 "$wt_b" main
  printf 'other home\n' > "$wt_b/other.txt"
  git -C "$wt_b" add other.txt
  git -C "$wt_b" commit -q -m other
  head_b=$(git -C "$wt_b" rev-parse HEAD)
  git -C "$wt_b" push -q origin HEAD:refs/heads/fm/task-y1
  git -C "$wt_b" push -q origin HEAD:refs/pull/8/head
  printf '%s\t%s\t%s\t%s\t%s\n' OPEN "$head_b" 'fm/task-y1' 'main' \
    'https://github.com/example/repo/pull/8' > "$FAKEBIN/pr-8.tsv"
  {
    printf 'window=firstmate:fm-task-y1\nendpoint_task_id=task-y1\n'
    printf 'worktree=%s\nproject=%s\n' "$wt_b" "$PROJECT"
    printf 'harness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\nspawn_gen=test-generation\n'
    printf 'workspace_state=active\nworkspace_root=%s\n' "$root_b"
    printf 'pr=https://github.com/example/repo/pull/8\npr_head=%s\n' "$head_b"
  } > "$home_b/state/task-y1.meta"
  chmod 0600 "$home_b/state/task-y1.meta"

  out=$(run_workspace release task-x1) || fail "home A release failed: $out"
  [ ! -d "$WT" ] || fail "home A release retained its workspace"
  [ -d "$wt_b" ] || fail "home A release removed home B's same-numbered slot"
  [ "$(git -C "$wt_b" rev-parse HEAD)" = "$head_b" ] || fail "home A release moved home B's workspace"
  assert_not_contains "$(cat "$D/treehouse.log")" "root=$root_b" "home A's release reached into home B's root"

  out=$(HOME_DIR=$home_b run_workspace release task-y1) || fail "home B release failed: $out"
  [ ! -d "$wt_b" ] || fail "home B release retained its workspace"
  assert_contains "$(cat "$D/treehouse.log")" "root=$root_b destroy $wt_b" "home B did not destroy through its own root"

  out=$(run_workspace restore task-x1) || fail "home A restore failed: $out"
  out=$(HOME_DIR=$home_b run_workspace restore task-y1) || fail "home B restore failed: $out"
  restored_a=$(meta_value worktree)
  restored_b=$(sed -n 's/^worktree=//p' "$home_b/state/task-y1.meta")
  case "$restored_a" in "$root_a"/*) ;; *) fail "home A restored outside its own root: $restored_a" ;; esac
  case "$restored_b" in "$root_b"/*) ;; *) fail "home B restored outside its own root: $restored_b" ;; esac
  [ "$(git -C "$restored_a" rev-parse HEAD)" = "$HEAD" ] || fail "home A restored the wrong head"
  [ "$(git -C "$restored_b" rev-parse HEAD)" = "$head_b" ] || fail "home B restored the wrong head"
  pass "two homes sharing one project release and reconstruct through their own roots without touching each other"
}

test_slot_claim_follows_release_and_restore() {
  local rec out marker restored
  rec=$(make_case slot-claim)
  read_case "$rec"
  marker="$(dirname "$WT")/.fm-slot-owner"
  printf 'task=task-x1\nhome=%s\n' "$HOME_DIR" > "$marker"
  out=$(run_workspace release task-x1) || fail "release failed: $out"
  [ ! -e "$marker" ] || fail "release left its claim on a slot Treehouse may hand to another task"

  out=$(run_workspace restore task-x1) || fail "restore failed: $out"
  restored=$(meta_value worktree)
  assert_grep 'task=task-x1' "$(dirname "$restored")/.fm-slot-owner" "restore did not claim its newly allocated slot"

  rec=$(make_case slot-claim-other)
  read_case "$rec"
  marker="$(dirname "$WT")/.fm-slot-owner"
  printf 'task=someone-else\nhome=/elsewhere\n' > "$marker"
  out=$(run_workspace release task-x1) || fail "release with a foreign claim failed: $out"
  assert_grep 'task=someone-else' "$marker" "release removed another task's slot claim"
  pass "release drops only its own slot claim and restore claims the reconstructed slot"
}

test_ignored_secret_and_runtime_material_refuse() {
  local rec out name
  for name in .env server.pem dev.sqlite run/app.pid run/app.log; do
    rec=$(make_case "ignored-$(printf '%s' "$name" | tr '/.' '--')")
    read_case "$rec"
    mkdir -p "$(dirname "$WT/$name")"
    printf 'keep\n' > "$WT/$name"
    [ -z "$(git -C "$WT" status --porcelain --untracked-files=all)" ] \
      || fail "fixture error: $name is not ignored, so the dirty check would mask the secret check"
    out=$(run_workspace release task-x1) && fail "ignored $name was released"
    assert_contains "$out" "ignored secret-like material" "ignored $name refusal did not name the secret check"
    [ -f "$WT/$name" ] || fail "ignored $name refusal removed the file"
    assert_grep 'workspace_state=active' "$HOME_DIR/state/task-x1.meta" "ignored $name refusal rewrote lifecycle state"
  done
  pass "project-local ignored env, key, database, PID, and log material refuses release and is retained"
}

test_generated_trees_do_not_refuse() {
  local rec out
  rec=$(make_case generated-trees)
  read_case "$rec"
  mkdir -p "$WT/node_modules/pkg/test" "$WT/.venv/lib/python/site-packages/lib" "$WT/build/out"
  printf 'fixture\n' > "$WT/node_modules/pkg/test/server.pem"
  printf 'fixture\n' > "$WT/node_modules/pkg/credentials.js"
  printf 'fixture\n' > "$WT/.venv/lib/python/site-packages/lib/secrets.py"
  printf 'fixture\n' > "$WT/build/out/compile.log"
  out=$(run_workspace release task-x1) || fail "bundled dependency fixtures refused release: $out"
  [ ! -d "$WT" ] || fail "release retained a workspace holding only reconstructable generated trees"
  assert_grep 'workspace_state=released' "$HOME_DIR/state/task-x1.meta" "generated-tree release did not complete"
  pass "secret-like names inside generated dependency, virtualenv, and build trees do not refuse release"
}

test_unavailable_or_changing_remote_proof_refuses() {
  local rec out base
  rec=$(make_case forge-down)
  read_case "$rec"
  : > "$FAKEBIN/gh-unavailable"
  out=$(run_workspace release task-x1) && fail "release proceeded without a forge read"
  assert_contains "$out" "could not read the exact remote PR head" "forge outage refusal was not explicit"
  [ -d "$WT" ] || fail "forge outage refusal removed the workspace"

  rec=$(make_case remote-down)
  read_case "$rec"
  git -C "$WT" remote set-url origin "$D/no-such-origin.git"
  out=$(run_workspace release task-x1) && fail "release proceeded without fetching the remote head"
  assert_contains "$out" "could not fetch the exact remote head" "unreachable remote refusal was not explicit"
  [ -d "$WT" ] || fail "unreachable remote refusal removed the workspace"

  rec=$(make_case head-moved)
  read_case "$rec"
  base=$(git -C "$PROJECT" rev-parse main)
  printf '%s\t%s\t%s\t%s\t%s\n' OPEN "$base" 'fm/task-x1' 'main' \
    'https://github.com/example/repo/pull/7' > "$FAKEBIN/pr-7.tsv"
  out=$(run_workspace release task-x1) && fail "release accepted a PR head that differs from the fetched head"
  assert_contains "$out" "PR head changed while it was being preserved" "moving PR head refusal was not explicit"
  [ -d "$WT" ] || fail "moving PR head refusal removed the workspace"
  assert_grep 'workspace_state=active' "$HOME_DIR/state/task-x1.meta" "moving PR head refusal rewrote lifecycle state"
  pass "an unavailable forge, an unreachable remote, and a PR head that moves mid-proof each refuse and retain"
}

test_scout_and_local_only_never_release() {
  local rec out
  rec=$(make_case scout)
  read_case "$rec"
  sed -i.bak 's/^kind=ship$/kind=scout/' "$HOME_DIR/state/task-x1.meta"
  out=$(run_workspace release task-x1) && fail "a scout workspace was released early"
  assert_contains "$out" "only to ship tasks" "scout refusal was not explicit"
  [ -d "$WT" ] || fail "scout refusal removed the workspace"

  rec=$(make_case local-only)
  read_case "$rec"
  sed -i.bak 's/^mode=no-mistakes$/mode=local-only/' "$HOME_DIR/state/task-x1.meta"
  out=$(run_workspace release task-x1) && fail "a local-only workspace was released early"
  assert_contains "$out" "local-only work is not remotely reconstructable" "local-only refusal was not explicit"
  [ -d "$WT" ] || fail "local-only refusal removed the workspace"
  pass "scout and local-only workspaces keep their own completion gates and never release early"
}

test_interrupted_return_recovers_from_journaled_proof() {
  local rec out
  rec=$(make_case interrupted-return)
  read_case "$rec"
  git -C "$PROJECT" commit -q --allow-empty -m 'trunk advanced past the PR merge base'
  git -C "$PROJECT" push -q origin main
  out=$(FM_TEST_RETURN_DIES_AFTER="$D/return-died" run_workspace release task-x1) \
    && fail "release reported success although it died after the return"
  assert_grep 'workspace_state=releasing' "$HOME_DIR/state/task-x1.meta" "interrupted release did not stay journaled as releasing"
  [ -d "$WT" ] || fail "fixture error: the returned slot should still exist"
  git -C "$WT" merge-base --is-ancestor HEAD "$HEAD" \
    && fail "fixture error: the returned trunk tip must not be contained in the PR head"

  out=$(run_workspace release task-x1) || fail "retry refused an already returned slot: $out"
  assert_not_contains "$out" "unique commits" "retry raised a false unique-commit refusal"
  [ ! -d "$WT" ] || fail "retry left the returned idle slot behind"
  assert_grep 'workspace_state=released' "$HOME_DIR/state/task-x1.meta" "retry did not publish completion"
  assert_grep "workspace_head=$HEAD" "$HOME_DIR/state/task-x1.meta" "retry lost the journaled reconstruction head"

  rec=$(make_case interrupted-before-return)
  read_case "$rec"
  sed -i.bak 's/^workspace_state=active$/workspace_state=releasing/' "$HOME_DIR/state/task-x1.meta"
  printf 'workspace_head=%s\nworkspace_branch=fm/task-x1\n' "$HEAD" >> "$HOME_DIR/state/task-x1.meta"
  printf 'unique\n' > "$WT/unique.txt"
  git -C "$WT" add unique.txt
  git -C "$WT" commit -q -m unique
  out=$(run_workspace release task-x1) && fail "a releasing slot still holding an unpushed commit was destroyed"
  assert_contains "$out" "not contained in remote PR head" "unreturned releasing slot skipped the containment proof"
  [ -f "$WT/unique.txt" ] || fail "unreturned releasing slot lost its unique commit"
  pass "a release that died after the return is reclaimed from its journal, while an unreturned slot is still fully proved"
}

test_restore_recreates_or_reuses_every_backend_endpoint() {
  local backend rec out restored log
  make_stub_root
  for backend in tmux herdr zellij cmux; do
    rec=$(make_case "restore-reuse-$backend" "$backend")
    read_case "$rec"
    out=$(WORKSPACE_BIN="$STUB_ROOT/bin/fm-workspace.sh" run_workspace release task-x1) || fail "$backend release failed: $out"
    : > "$D/backend.log"
    out=$(WORKSPACE_BIN="$STUB_ROOT/bin/fm-workspace.sh" run_workspace restore task-x1) || fail "$backend restore (reuse) failed: $out"
    restored=$(meta_value worktree)
    [ "$(git -C "$restored" rev-parse HEAD)" = "$HEAD" ] || fail "$backend restore did not use the exact PR head"
    [ "$(git -C "$restored" symbolic-ref --short HEAD)" = fm/task-x1 ] || fail "$backend restore did not recreate the PR branch"
    assert_equals restored "$(meta_value workspace_state)" "$backend restore did not publish its handoff"
    log=$(cat "$D/backend.log")
    assert_not_contains "$log" "create_task" "$backend restore recreated an endpoint that still existed"
    assert_not_contains "$log" "new-window" "$backend restore recreated an endpoint that still existed"
    assert_contains "$log" "cd -- '$restored'" "$backend restore did not move the reused endpoint into the workspace"
    case "$backend" in
      tmux) assert_equals 'firstmate:fm-task-x1' "$(meta_value window)" "tmux reuse changed the endpoint" ;;
      herdr) assert_equals 'lab:pane' "$(meta_value window)" "Herdr reuse changed the endpoint"
             assert_equals pane "$(meta_value herdr_pane_id)" "Herdr reuse lost its pane identity" ;;
      zellij) assert_equals 'lab:7' "$(meta_value window)" "zellij reuse changed the endpoint"
              assert_equals 7 "$(meta_value zellij_pane_id)" "zellij reuse lost its pane identity" ;;
      cmux) assert_equals 'ws:surface' "$(meta_value window)" "cmux reuse changed the endpoint"
            assert_equals surface "$(meta_value cmux_surface_id)" "cmux reuse lost its surface identity" ;;
    esac

    rec=$(make_case "restore-recreate-$backend" "$backend")
    read_case "$rec"
    out=$(WORKSPACE_BIN="$STUB_ROOT/bin/fm-workspace.sh" run_workspace release task-x1) || fail "$backend release failed: $out"
    : > "$D/backend.log"
    out=$(FM_TEST_ENDPOINT_MISSING=1 WORKSPACE_BIN="$STUB_ROOT/bin/fm-workspace.sh" run_workspace restore task-x1) \
      || fail "$backend restore (recreate) failed: $out"
    restored=$(meta_value worktree)
    [ "$(git -C "$restored" rev-parse HEAD)" = "$HEAD" ] || fail "$backend recreate did not use the exact PR head"
    assert_equals restored "$(meta_value workspace_state)" "$backend recreate did not publish its handoff"
    log=$(cat "$D/backend.log")
    assert_contains "$log" "cd -- '$restored'" "$backend recreate did not move the new endpoint into the workspace"
    case "$backend" in
      tmux) assert_contains "$log" "new-window" "tmux did not recreate its window"
            assert_equals 'firstmate:fm-task-x1' "$(meta_value window)" "tmux recreate recorded the wrong endpoint" ;;
      herdr) assert_contains "$log" "herdr create_task lab2:ws2 fm-task-x1 $restored seed2" "Herdr did not recreate its pane in the workspace"
             assert_equals 'lab2:pane9' "$(meta_value window)" "Herdr recreate recorded the wrong endpoint"
             assert_equals lab2 "$(meta_value herdr_session)" "Herdr recreate recorded the wrong session"
             assert_equals ws2 "$(meta_value herdr_workspace_id)" "Herdr recreate recorded the wrong workspace"
             assert_equals tab9 "$(meta_value herdr_tab_id)" "Herdr recreate recorded the wrong tab"
             assert_equals herdr "$(meta_value backend)" "Herdr recreate lost its backend" ;;
      zellij) assert_contains "$log" "zellij create_task lab2 fm-task-x1 $restored" "zellij did not recreate its pane in the workspace"
              assert_equals 'lab2:9' "$(meta_value window)" "zellij recreate recorded the wrong endpoint"
              assert_equals tab9 "$(meta_value zellij_tab_id)" "zellij recreate recorded the wrong tab"
              assert_equals zellij "$(meta_value backend)" "zellij recreate lost its backend" ;;
      cmux) assert_contains "$log" "cmux create_task fm-task-x1 $restored" "cmux did not recreate its surface in the workspace"
            assert_equals 'ws9:surface9' "$(meta_value window)" "cmux recreate recorded the wrong endpoint"
            assert_equals surface9 "$(meta_value cmux_surface_id)" "cmux recreate recorded the wrong surface"
            assert_equals cmux "$(meta_value backend)" "cmux recreate lost its backend" ;;
    esac
  done
  pass "restore reuses a surviving endpoint and recreates a missing one on tmux, Herdr, zellij, and cmux"
}

test_orca_restore_and_terminal_failure_cleanup() {
  local rec out restored log
  make_stub_root
  rec=$(make_case orca-restore orca)
  read_case "$rec"
  out=$(FM_TEST_ORCA_OLD_WT="$WT" WORKSPACE_BIN="$STUB_ROOT/bin/fm-workspace.sh" run_workspace release task-x1) \
    || fail "Orca release failed: $out"
  [ ! -d "$WT" ] || fail "Orca release retained its worktree"
  log=$(cat "$D/backend.log")
  assert_contains "$log" "orca kill terminal-1" "Orca release did not close its exact terminal"
  assert_contains "$log" "orca remove_worktree worktree-1" "Orca release did not remove its exact worktree"

  : > "$D/backend.log"
  out=$(FM_TEST_ORCA_DIR="$D/orca-worktrees" FM_TEST_ORCA_TERMINAL_FAILS=1 \
    WORKSPACE_BIN="$STUB_ROOT/bin/fm-workspace.sh" run_workspace restore task-x1) \
    && fail "Orca restore reported success without a terminal"
  assert_contains "$out" "could not create reconstructed Orca terminal" "Orca terminal failure was not explicit"
  assert_contains "$(cat "$D/backend.log")" "orca remove_worktree orca-wt-new" \
    "a failed Orca terminal creation orphaned the newly created worktree"
  [ ! -d "$D/orca-worktrees/fm-task-x1" ] || fail "the orphaned Orca worktree is still on disk"
  assert_equals released "$(meta_value workspace_state)" "a failed Orca restore rewrote lifecycle state"
  assert_equals worktree-1 "$(meta_value orca_worktree_id)" "a failed Orca restore rewrote the recorded identity"

  : > "$D/backend.log"
  out=$(FM_TEST_ORCA_DIR="$D/orca-worktrees" \
    WORKSPACE_BIN="$STUB_ROOT/bin/fm-workspace.sh" run_workspace restore task-x1) \
    || fail "Orca restore retry collided with or failed after the cleaned-up attempt: $out"
  restored=$(meta_value worktree)
  assert_equals "$D/orca-worktrees/fm-task-x1" "$restored" "Orca restore recorded the wrong worktree"
  [ "$(git -C "$restored" rev-parse HEAD)" = "$HEAD" ] || fail "Orca restore did not use the exact PR head"
  [ "$(git -C "$restored" symbolic-ref --short HEAD)" = fm/task-x1 ] || fail "Orca restore did not recreate the PR branch"
  assert_equals restored "$(meta_value workspace_state)" "Orca restore did not publish its handoff"
  assert_equals orca-wt-new "$(meta_value orca_worktree_id)" "Orca restore did not record the new worktree identity"
  assert_equals terminal-new "$(meta_value terminal)" "Orca restore did not record the new terminal"
  pass "Orca restore records its new worktree and terminal, and a terminal failure removes the fresh worktree so a retry succeeds"
}

test_two_homes_are_collision_proof
test_release_and_exact_stacked_restore
test_dirty_and_unpushed_refuse
test_release_cleanup_retry_is_idempotent
test_backend_metadata_survives_release
test_legacy_audit_and_reclaim_stay_conservative
test_two_homes_share_one_project
test_slot_claim_follows_release_and_restore
test_ignored_secret_and_runtime_material_refuse
test_generated_trees_do_not_refuse
test_unavailable_or_changing_remote_proof_refuses
test_scout_and_local_only_never_release
test_interrupted_return_recovers_from_journaled_proof
test_restore_recreates_or_reuses_every_backend_endpoint
test_orca_restore_and_terminal_failure_cleanup
printf '# all fm-workspace tests passed\n'
