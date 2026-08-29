#!/usr/bin/env bash
# tests/fm-worktree-ownership.test.sh - one worktree belongs to exactly one live
# task, enforced at both ends.
#
# Several safety properties quietly depend on that invariant. The sharpest is
# bin/fm-teardown.sh's leaked-process reap, which sends TERM then KILL to every
# process whose cwd is "this task's own worktree" precisely because that root is
# supposed to be unique; when two live tasks hold one worktree, tearing either
# one down kills the other's agent inside a worktree it is still working in.
#
# The invariant was reachable from both directions. A teardown released the
# worktree to the pool BEFORE retiring the endpoint and durable task state, so
# either failure could leave the task half-retired: pool says free, this task's
# record still claims it, next spawn gets it. And the spawn path accepted
# whatever worktree it was handed without checking whether a live record already
# named it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-ownership)

# --- spawn side ---------------------------------------------------------------

make_spawn_fakebin() {
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
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse claude
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> -> "<home>|<proj>|<wt>|<fakebin>|<id>"
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-z1
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$id"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

read_spawn_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR CASE_ID <<EOF
$1
EOF
}

test_spawn_refuses_a_worktree_another_live_task_claims() {
  local rec out
  rec=$(make_spawn_case claimed)
  read_spawn_case "$rec"
  # A live task already recorded against the very worktree the pool is about to
  # hand this spawn - the half-retired-teardown shape.
  fm_write_meta "$HOME_DIR/state/other-task.meta" \
    "window=sess:fm-other-task" "worktree=$WT_DIR" "project=$PROJ_DIR" "kind=ship"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_ID" "$PROJ_DIR" claude) \
    && fail "spawn accepted a worktree another live task still claims"
  case "$out" in
    *"other-task still claims"*) ;;
    *) fail "the refusal must name the claiming task (got: $out)" ;;
  esac
  [ ! -f "$HOME_DIR/state/$CASE_ID.meta" ] \
    || fail "a refused spawn must not publish its own record for that worktree"
  [ -f "$HOME_DIR/state/other-task.meta" ] \
    || fail "a refused spawn must leave the claiming task's record intact"
  pass "spawn: a worktree another live task claims is refused, naming that task"
}

test_spawn_accepts_the_worktree_its_own_record_names() {
  local rec out
  rec=$(make_spawn_case ownclaim)
  read_spawn_case "$rec"
  # A relaunch legitimately re-enters the worktree its OWN record already names.
  fm_write_meta "$HOME_DIR/state/$CASE_ID.meta" \
    "window=sess:fm-$CASE_ID" "worktree=$WT_DIR" "project=$PROJ_DIR" "kind=ship"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_ID" "$PROJ_DIR" claude) \
    || fail "spawn refused the worktree its own record names: $out"
  pass "spawn: a task's own recorded worktree is not treated as a conflict"
}

# --- teardown side ------------------------------------------------------------

make_teardown_case() {  # <name> -> case dir
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" \
    "$dir/fakebin" "$dir/worktree" "$dir/project"
  : > "$dir/runtime.log"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux <%s>\n' "$*" >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse <%s>\n' "$*" >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/treehouse"
  printf '%s\n' "$dir"
}

# The ordering assertion. The endpoint has to be retired before the isolated copy
# goes back to the pool, so a close that is refused, skipped, or fails can never
# leave the worktree available while this task's record still names it.
test_teardown_retires_the_endpoint_before_releasing_the_worktree() {
  local dir id=owned kill_line return_line
  dir=$(make_teardown_case teardown-order)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=sess:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout" "mode=no-mistakes"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" --force \
    > "$dir/out" 2> "$dir/err" || fail "teardown failed: $(cat "$dir/err")"

  kill_line=$(grep -n 'tmux <kill-window' "$dir/runtime.log" | head -1 | cut -d: -f1)
  return_line=$(grep -n 'treehouse <return' "$dir/runtime.log" | head -1 | cut -d: -f1)
  [ -n "$kill_line" ] \
    || fail "teardown never retired the endpoint: $(cat "$dir/runtime.log")"
  [ -n "$return_line" ] \
    || fail "teardown never returned the worktree: $(cat "$dir/runtime.log")"
  [ "$kill_line" -lt "$return_line" ] \
    || fail "the worktree was released before the endpoint was retired, so a refused close can strand a claimed worktree in the pool:"$'\n'"$(cat "$dir/runtime.log")"
  pass "teardown: the endpoint is retired before the worktree returns to the pool"
}

test_teardown_failure_preserves_the_record_and_provider_reservation() {
  local dir id=retire-failure out rc=0
  dir=$(make_teardown_case teardown-retirement-failure)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=sess:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout" "mode=no-mistakes"
  mkdir "$dir/home/state/$id.pr-poll-merge-notified"

  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" --force 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe post-endpoint retirement state did not fail teardown"
  grep -Fq 'tmux <kill-window' "$dir/runtime.log" \
    || fail "teardown did not reach endpoint retirement before the fixture failure: $out"
  if grep -Fq 'treehouse <return' "$dir/runtime.log"; then
    fail "failed task-state retirement returned the worktree to the provider"
  fi
  [ -f "$dir/home/state/$id.meta" ] \
    || fail "failed task-state retirement removed the worktree ownership record"
  pass "teardown: failed state retirement preserves the claim and reservation"
}

test_tmux_unconfirmed_close_preserves_the_record_and_provider_reservation() {
  local dir id=tmux-retained out rc=0
  dir=$(make_teardown_case teardown-tmux-retained)
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux <%s>\n' "$*" >> "${FM_RUNTIME_LOG:?}"
case "${1:-}" in
  list-windows) printf 'fm-%s\n' "${FM_TASK_ID:?}" ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=sess:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout" "mode=no-mistakes"

  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    FM_TASK_ID="$id" PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" --force 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "tmux teardown accepted a no-op close"
  case "$out" in *"tmux window"*"not confirmed gone"*) ;; *) fail "tmux refusal did not name the unconfirmed endpoint: $out" ;; esac
  if grep -Fq 'treehouse <return' "$dir/runtime.log"; then
    fail "tmux teardown returned the worktree after an unconfirmed close"
  fi
  [ -f "$dir/home/state/$id.meta" ] \
    || fail "tmux teardown removed metadata after an unconfirmed close"
  pass "teardown: an unconfirmed tmux close preserves the claim and reservation"
}

test_zellij_unconfirmed_close_preserves_the_record_and_provider_reservation() {
  local dir id=zellij-retained out rc=0
  dir=$(make_teardown_case teardown-zellij-retained)
  cat > "$dir/fakebin/zellij" <<'SH'
#!/usr/bin/env bash
printf 'zellij <%s>\n' "$*" >> "${FM_RUNTIME_LOG:?}"
case "$*" in
  "list-sessions --short --no-formatting") printf 'firstmate\n' ;;
  *"action list-panes --json"*) printf '[{"id":7,"tab_id":3,"is_plugin":false}]\n' ;;
  *"action list-tabs --json"*) printf '[{"tab_id":3,"name":"fm-%s"}]\n' "${FM_TASK_ID:?}" ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/zellij"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:7" "endpoint_task_id=$id" "backend=zellij" \
    "zellij_session=firstmate" "zellij_tab_id=3" "zellij_pane_id=7" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout" "mode=no-mistakes"

  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    FM_TASK_ID="$id" PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" --force 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Zellij teardown accepted a no-op close"
  case "$out" in *"Zellij tab"*"not confirmed gone"*) ;; *) fail "Zellij refusal did not name the unconfirmed endpoint: $out" ;; esac
  if grep -Fq 'treehouse <return' "$dir/runtime.log"; then
    fail "Zellij teardown returned the worktree after an unconfirmed close"
  fi
  [ -f "$dir/home/state/$id.meta" ] \
    || fail "Zellij teardown removed metadata after an unconfirmed close"
  pass "teardown: an unconfirmed Zellij close preserves the claim and reservation"
}

test_cmux_unconfirmed_close_preserves_the_record_and_provider_reservation() {
  local dir id=cmux-retained out rc=0
  dir=$(make_teardown_case teardown-cmux-retained)
  cat > "$dir/fakebin/cmux" <<'SH'
#!/usr/bin/env bash
printf 'cmux <%s>\n' "$*" >> "${FM_RUNTIME_LOG:?}"
case "${1:-}" in
  workspace) printf '{"workspaces":[{"id":"ws-retained","title":"fm-retained"}]}\n' ;;
  list-panes) printf '{"panes":[{"selected_surface_id":"sf-retained","surface_ids":["sf-retained"]}]}\n' ;;
  list-windows) printf '[{"id":"window-retained","workspace_count":1}]\n' ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/cmux"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=ws-retained:sf-retained" "endpoint_task_id=$id" "backend=cmux" \
    "cmux_workspace_id=ws-retained" "cmux_surface_id=sf-retained" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout" "mode=no-mistakes"

  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" --force 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "cmux teardown accepted a no-op close"
  case "$out" in *"cmux workspace"*"not confirmed gone"*) ;; *) fail "cmux refusal did not name the unconfirmed endpoint: $out" ;; esac
  if grep -Fq 'treehouse <return' "$dir/runtime.log"; then
    fail "cmux teardown returned the worktree after an unconfirmed close"
  fi
  [ -f "$dir/home/state/$id.meta" ] \
    || fail "cmux teardown removed metadata after an unconfirmed close"
  pass "teardown: an unconfirmed cmux close preserves the claim and reservation"
}

test_orca_unconfirmed_close_preserves_the_record_and_provider_reservation() {
  local dir id=orca-retained out rc=0
  dir=$(make_teardown_case teardown-orca-retained)
  cat > "$dir/fakebin/orca" <<'SH'
#!/usr/bin/env bash
printf 'orca <%s>\n' "$*" >> "${FM_RUNTIME_LOG:?}"
case "$*" in
  "worktree show --worktree id:wt-retained --json")
    printf '{"ok":true,"result":{"worktree":{"id":"wt-retained","path":"%s"}}}\n' "${FM_ORCA_WORKTREE_PATH:?}"
    ;;
  "terminal close --terminal term-retained --json")
    printf '{"ok":false,"error":{"code":"close_failed","message":"close failed"}}\n'
    ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/orca"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "backend=orca" \
    "terminal=term-retained" "orca_worktree_id=wt-retained" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout" "mode=no-mistakes"

  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    FM_ORCA_WORKTREE_PATH="$dir/worktree" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Orca teardown accepted a failed close acknowledgment"
  case "$out" in *"Orca terminal"*"native close reported failure"*) ;; *) fail "Orca refusal did not name the unconfirmed endpoint: $out" ;; esac
  if grep -Fq 'orca <worktree rm' "$dir/runtime.log"; then
    fail "Orca teardown removed the worktree after an unconfirmed close"
  fi
  [ -f "$dir/home/state/$id.meta" ] \
    || fail "Orca teardown removed metadata after an unconfirmed close"
  pass "teardown: an unconfirmed Orca close preserves the claim and reservation"
}

test_spawn_refuses_a_worktree_another_live_task_claims
test_spawn_accepts_the_worktree_its_own_record_names
test_teardown_retires_the_endpoint_before_releasing_the_worktree
test_teardown_failure_preserves_the_record_and_provider_reservation
test_tmux_unconfirmed_close_preserves_the_record_and_provider_reservation
test_zellij_unconfirmed_close_preserves_the_record_and_provider_reservation
test_cmux_unconfirmed_close_preserves_the_record_and_provider_reservation
test_orca_unconfirmed_close_preserves_the_record_and_provider_reservation

echo "# all fm-worktree-ownership tests passed"
