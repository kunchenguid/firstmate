#!/usr/bin/env bash
# Regression tests for cleanup endpoint and worktree-slot identity validation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-endpoint-safety)
REAL_TMUX=$(command -v tmux || true)

make_case() {  # <name>
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/data" \
    "$TMP_ROOT/$dir/home/config" "$TMP_ROOT/$dir/fakebin" \
    "$TMP_ROOT/$dir/worktree" "$TMP_ROOT/$dir/project"
  git init -q "$TMP_ROOT/$dir/project"
  : > "$TMP_ROOT/$dir/worktree/sentinel"
  : > "$TMP_ROOT/$dir/runtime.log"
  cat > "$TMP_ROOT/$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$TMP_ROOT/$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$TMP_ROOT/$dir/fakebin/tmux" "$TMP_ROOT/$dir/fakebin/treehouse"
  printf '%s\n' "$TMP_ROOT/$dir"
}

mark_case_as_treehouse_pool() {  # <case>
  local dir=$1
  rm -rf "$dir/worktree"
  mkdir -p "$dir/pool/1"
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm pool-fixture
  git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
  ln -s "pool/1/project" "$dir/worktree"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
    "$dir/pool/1/project" > "$dir/pool/treehouse-state.json"
  : > "$dir/worktree/sentinel"
}

claim_pool_slot() {  # <case> <task-id> [home]
  local dir=$1 id=$2 home=${3:-$1/home}
  printf 'task=%s\nhome=%s\n' "$id" "$home" > "$dir/pool/1/.fm-slot-owner"
}

run_case() {  # <case> <id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force
}

assert_refused_without_mutation() {  # <case> <id> <description>
  local dir=$1 id=$2 description=$3 rc
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: teardown unexpectedly succeeded"
  assert_present "$dir/home/state/$id.meta" "$description: metadata changed before refusal"
  assert_present "$dir/worktree/sentinel" "$description: worktree changed before refusal"
  [ ! -s "$dir/runtime.log" ] || fail "$description: runtime command ran before refusal: $(cat "$dir/runtime.log")"
}

test_invalid_endpoint_records_refuse_before_mutation() {
  local dir id=endpoint-a

  dir=$(make_case missing)
  fm_write_meta "$dir/home/state/$id.meta" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "missing endpoint"

  dir=$(make_case empty)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty endpoint"

  dir=$(make_case malformed)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=ambient-current-window" "worktree=$dir/worktree" \
    "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "malformed endpoint"

  dir=$(make_case mismatched)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-other-task" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "task-mismatched endpoint"

  dir=$(make_case empty-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty task binding"

  dir=$(make_case duplicate-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "duplicate task binding"

  pass "fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call"
}

test_control_lock_contention_refuses_before_mutation() {
  local dir id=locked-task lock holder i=0 rc
  dir=$(make_case control-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.control-$id.lock"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage a held lifecycle lock"
  }
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown unexpectedly succeeded under lifecycle lock contention"
  assert_present "$dir/home/state/$id.meta" "contended teardown removed task metadata"
  assert_present "$dir/worktree/sentinel" "contended teardown changed the worktree"
  assert_present "$lock" "contended teardown removed another action's lock"
  [ ! -s "$dir/runtime.log" ] \
    || fail "contended teardown reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "another lifecycle action is already running" \
    "contended teardown should serialize before reading mutable task metadata"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown: a concurrent lifecycle action refuses before mutation"
}

test_non_pool_teardown_ignores_task_set_lock() {
  local dir id=non-pool-task lock ready holder i=0
  dir=$(make_case non-pool-task-set-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/missing-worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.task-set.lock"
  ready="$dir/task-set-lock-ready"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage an in-progress task publication"
  }

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "non-pool teardown was blocked by an unrelated task publication: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "non-pool teardown left task metadata"
  assert_present "$lock" "non-pool teardown removed the publisher's lock"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown: non-pool cleanup ignores unrelated task publication locks"
}

test_metadata_lock_serializes_destructive_cleanup() {
  local dir id=metadata-locked-task lock ready release holder teardown_pid i=0 rc
  dir=$(make_case metadata-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.meta-$id.lock"
  ready="$dir/meta-lock-ready"
  release="$dir/meta-lock-release"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    while [ ! -e "$release" ]; do
      sleep 0.01
    done
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage a held metadata lock"
  }

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" &
  teardown_pid=$!
  sleep 0.2
  if ! kill -0 "$teardown_pid" 2>/dev/null; then
    : > "$release"
    wait "$holder" 2>/dev/null || true
    wait "$teardown_pid" 2>/dev/null || true
    fail "teardown did not wait for the shared metadata writer lock"
  fi
  assert_present "$dir/home/state/$id.meta" "metadata-lock contention removed task metadata"
  assert_present "$dir/worktree/sentinel" "metadata-lock contention changed the worktree"
  [ ! -s "$dir/runtime.log" ] \
    || fail "metadata-lock contention reached the runtime: $(cat "$dir/runtime.log")"

  : > "$release"
  wait "$holder" || fail "metadata lock holder failed"
  wait "$teardown_pid"; rc=$?
  expect_code 0 "$rc" "teardown should complete after the metadata writer releases"
  assert_absent "$dir/home/state/$id.meta" \
    "serialized teardown left a task record that a completed writer could resurrect"
  pass "fm-teardown: destructive cleanup serializes with metadata writers"
}

test_supported_backend_endpoint_records_validate() {
  local dir id backend target
  dir=$(make_case valid-backends)
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"

  id=tmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint refused"
  [ "$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET" = "tmux:firstmate:fm-$id" ] || fail "tmux endpoint validation returned wrong identity"

  id=tmux-spaced-session
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=team work:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint with a spaced session name refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "team work:fm-$id" ] || fail "tmux validation changed the spaced session identity"

  id=herdr-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Herdr endpoint refused"

  id=zellij-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:7" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=3" "zellij_pane_id=7"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Zellij endpoint refused"

  id=orca-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-7" \
    "worktree=$dir/worktree" "project=$dir/project" "backend=orca" "orca_worktree_id=worktree-9::/orca/worktree-9"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Orca endpoint refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = term-7 ] || fail "Orca validation did not select its terminal"

  id=cmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=workspace-1:surface-2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=cmux" "cmux_workspace_id=workspace-1" "cmux_surface_id=surface-2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid cmux endpoint refused"

  for backend in tmux herdr zellij orca cmux; do
    set +e
    fm_backend_kill "$backend" "" >/dev/null 2>&1
    target=$?
    set -e
    [ "$target" -ne 0 ] || fail "$backend generic kill accepted an empty target"
  done
  pass "cleanup identity: valid tmux, Herdr, Zellij, Orca, and cmux records validate while every empty backend target refuses"
}

test_orca_composite_worktree_id_validates() {
  local dir id real
  dir=$(make_case orca-composite-worktree-id)
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"

  real="411226f7-dc91-4d37-975d-32d412bf97a2::/Users/fleet/orca/workspaces/proj/fm-task"
  fm_backend_orca_worktree_id_valid "$real" \
    || fail "the composite worktree id Orca really returns was rejected"
  if fm_backend_orca_worktree_id_valid "$(printf 'wt-a::/orca/wt\na')"; then
    fail "a worktree id carrying a newline was accepted"
  fi
  if fm_backend_orca_worktree_id_valid "wt-atom"; then
    fail "a worktree id with no :: separator was accepted"
  fi

  id=orca-composite-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-11" \
    "worktree=$dir/worktree" "project=$dir/project" "backend=orca" \
    "orca_worktree_id=411226f7-dc91-4d37-975d-32d412bf97a2::$dir/worktree"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" \
    || fail "an Orca record carrying its real composite worktree id was refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = term-11 ] \
    || fail "Orca validation did not select its terminal"
  pass "cleanup identity: an Orca record's real composite worktree id validates while a separatorless or newline-carrying id refuses"
}

test_tmux_empty_target_refuses_without_invocation() {
  local dir rc
  dir=$(make_case direct-empty)
  set +e
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "direct empty tmux target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "direct empty tmux target invoked tmux"
  pass "tmux backend: direct empty target returns nonzero without invoking tmux"
}

test_recorded_process_identity_cleanup_is_exact() {
  local dir target_pid control_pid target_record control_record live_command
  dir=$(make_case recorded-process)
  sleep 30 &
  control_pid=$!
  sleep 30 &
  target_pid=$!
  printf '%s\n' "$control_pid" > "$dir/control.pid"
  printf '%s\n' "$target_pid" > "$dir/target.pid"
  target_record=$(cat "$dir/target.pid")
  control_record=$(cat "$dir/control.pid")
  [ "$target_record" = "$target_pid" ] && [ "$control_record" = "$control_pid" ] \
    || fail "recorded process identity changed before cleanup"
  live_command=$(ps -p "$target_record" -o comm= 2>/dev/null | tr -d '[:space:]')
  case "$live_command" in sleep) ;; *) fail "recorded target pid no longer belongs to the expected child" ;; esac
  kill -TERM "$target_record"
  wait "$target_record" 2>/dev/null || true
  kill -0 "$target_record" 2>/dev/null && fail "exact target pid survived cleanup"
  kill -0 "$control_record" 2>/dev/null || fail "independent control process was disturbed"
  kill -TERM "$control_record"
  wait "$control_record" 2>/dev/null || true
  pass "process cleanup: creation-time PID identity removes only the exact child and preserves the control child"
}

isolated_tmux_window_exists() {  # <dir> <socket> <session> <window>
  ( cd "$1" && "$REAL_TMUX" -S "$2" list-windows -t "$3" -F '#{window_name}' 2>/dev/null ) \
    | grep -Fqx "$4"
}

test_isolated_tmux_invalid_and_valid_cleanup() {
  local dir socket socket_id session='endpoint safety' target_id=target control=control target=fm-target
  local prefix_target=fm-prefix prefix_survivor=fm-prefix2 rc
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  dir=$(make_case isolated-real)
  socket=dedicated.sock
  socket_id="$dir/$socket"
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s "$session" -n "$control" )
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "$session:" -n "$target" )
  printf '%s\n' "$socket_id" > "$dir/socket.identity"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
set -eu
[ -z "\${TMUX:-}" ] && [ -z "\${TMUX_PANE:-}" ] || exit 91
[ "\${FM_TEST_TMUX_SOCKET:-}" = '$socket_id' ] || exit 92
[ "\$(cat '$dir/socket.identity')" = '$socket_id' ] || exit 93
printf 'tmux' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
cd '$dir'
exec '$REAL_TMUX' -S '$socket' "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  fm_write_meta "$dir/home/state/invalid.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  set +e
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" invalid --force \
    > "$dir/invalid.out" 2> "$dir/invalid.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated invalid endpoint unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated invalid endpoint reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "invalid cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "invalid cleanup removed target window"

  set +e
  # shellcheck disable=SC2016 # $1 expands inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/empty.out" 2> "$dir/empty.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated direct empty target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated direct empty target reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "direct empty cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "direct empty cleanup removed target window"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "=$session:" -n "$prefix_survivor" )
  # shellcheck disable=SC2016 # $1 and $2 expand inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill "$2"' _ "$ROOT" "$session:$prefix_target"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$prefix_survivor" \
    || fail "missing exact target cleanup removed its prefix-matched neighbor"

  fm_write_meta "$dir/home/state/$target_id.meta" \
    "window=$session:$target" "endpoint_task_id=$target_id" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$target_id" --force \
    > "$dir/valid.out" 2> "$dir/valid.err" \
    || fail "isolated valid endpoint teardown failed: $(cat "$dir/valid.err")"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" \
    && fail "valid cleanup did not remove the exact target window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" \
    || fail "valid cleanup removed the independent control window"
  grep -Fqx "tmux <kill-window> <-t> <=$session:=$target>" "$dir/runtime.log" \
    || fail "valid cleanup did not invoke exactly the recorded target: $(cat "$dir/runtime.log")"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null ) || true
  pass "fm-teardown: exact tmux cleanup preserves invalid and prefix-matched neighbors while removing only the recorded target"
}

test_bare_relative_origin_shares_project_lock_with_clone() {
  local dir second_project primary_lock clone_lock
  dir=$(make_case bare-relative-origin-lock)
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm lock-fixture
  mkdir -p "$dir/project/remotes"
  git clone -q --bare "$dir/project" "$dir/project/remotes/origin.git"
  git -C "$dir/project" remote add origin remotes/origin.git
  second_project="$dir/second-project"
  git clone -q "$dir/project/remotes/origin.git" "$second_project"

  primary_lock=$(FM_HOME="$dir/home" bash -c \
    '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$dir/project") \
    || fail "could not resolve the primary project's bare-origin lock"
  clone_lock=$(FM_HOME="$dir/home" bash -c \
    '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$second_project") \
    || fail "could not resolve the clone project's absolute-origin lock"
  [ "$primary_lock" = "$clone_lock" ] \
    || fail "bare and absolute forms of the same local origin resolved different project locks"

  pass "Treehouse locking resolves a bare local origin against its source project, matching the provisioned clone"
}

test_reused_pool_slot_refuses_before_touching_the_other_task() {
  local dir id=stale-task other=live-task worker rc

  dir=$(make_case slot-reuse)
  mark_case_as_treehouse_pool "$dir"
  # The reuse collision: the pool slot recorded for a finished task has already
  # been handed to another task, whose worker is live in it right now.
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$dir/home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  # Staged in this shell, not a command substitution: a background child of a
  # $(...) subshell does not outlive it, and the point of this worker is to be
  # alive in the slot while teardown runs.
  ( cd "$dir/worktree" && exec sleep 30 ) &
  worker=$!

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot a second task record still holds"
  kill -0 "$worker" 2>/dev/null || fail "teardown killed the worker holding the reused pool slot"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot a second task record still holds"
  assert_present "$dir/home/state/$other.meta" "teardown removed the live task's record"
  assert_present "$dir/home/state/$id.meta" "teardown removed the stale task's record before refusing"
  [ ! -s "$dir/runtime.log" ] \
    || fail "teardown reached the runtime on a contested pool slot: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "refusal should name the other task holding the slot"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true

  # The same collision recorded on a secondmate home field rather than a task
  # worktree is the same slot, and refuses the same way.
  dir=$(make_case slot-reuse-home)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$dir/home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" \
    "worktree=$dir/worktree" "home=$dir/worktree" \
    "project=$dir/project" "kind=secondmate"
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot a secondmate home record still holds"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot a secondmate home record still holds"
  assert_present "$dir/home/state/$other.meta" "teardown removed the secondmate record"
  [ ! -s "$dir/runtime.log" ] \
    || fail "teardown reached the runtime on a slot held by a secondmate home: $(cat "$dir/runtime.log")"

  # A second task record that is a hardlink of this one is still a second
  # claim on the slot, not this record reached through another spelling.
  dir=$(make_case slot-reuse-hardlink)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  ln "$dir/home/state/$id.meta" "$dir/home/state/$other.meta"
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot a hardlinked second task record still holds"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot a hardlinked second task record still holds"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "hardlink refusal should name the other task record"

  pass "fm-teardown: a pool slot named by a second task record is never returned, killed, or reset"
}

test_cross_home_pool_slot_collision_refuses() {
  local dir id=stale-task other=secondmate-task second_home second_project rc
  dir=$(make_case slot-reuse-cross-home)
  mark_case_as_treehouse_pool "$dir"
  printf 'fixture\n' > "$dir/project/tracked"
  git -C "$dir/project" add tracked
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  second_home="$dir/secondmate-home"
  second_project="$second_home/projects/project"
  mkdir -p "$second_home/projects" "$second_home/state" "$second_home/data"
  git clone -q "$dir/project" "$second_project"
  printf '%s\n' "- mate - fixture (home: $second_home; scope: test; projects: project; added 2026-01-01)" \
    > "$dir/home/data/secondmates.md"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$second_home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" \
    "worktree=$dir/worktree" "project=$second_project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot held by another firstmate home"
  assert_present "$dir/home/state/$id.meta" "cross-home collision removed stale metadata"
  assert_present "$second_home/state/$other.meta" "cross-home collision removed live metadata"
  assert_present "$dir/worktree/sentinel" "cross-home collision reset the shared slot"
  [ ! -s "$dir/runtime.log" ] \
    || fail "cross-home collision reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "cross-home refusal should name the task holding the slot"
  pass "fm-teardown: a pool slot held by another firstmate home is never returned"
}

test_sole_slot_record_still_tears_down() {
  local dir id=sole-task worker

  dir=$(make_case slot-sole)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  # A neighbouring task on its OWN slot must not look like a collision.
  mkdir -p "$dir/other-worktree"
  fm_write_meta "$dir/home/state/neighbour.meta" \
    "window=firstmate:fm-neighbour" "endpoint_task_id=neighbour" \
    "worktree=$dir/other-worktree" "project=$dir/project" "kind=scout"
  ( cd "$dir/other-worktree" && exec sleep 30 ) &
  worker=$!

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of a task that solely holds its slot failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "uncontested teardown left the task record"
  assert_present "$dir/home/state/neighbour.meta" "uncontested teardown removed the neighbour's record"
  kill -0 "$worker" 2>/dev/null || fail "uncontested teardown killed a worker in a different slot"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "uncontested teardown did not return its own pool slot: $(cat "$dir/runtime.log")"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true
  pass "fm-teardown: a task that solely holds its slot still returns it"
}

test_recorded_endpoint_that_changed_directory_still_tears_down() {
  local dir id=moved-task

  dir=$(make_case slot-endpoint-moved)
  mark_case_as_treehouse_pool "$dir"
  mkdir -p "$dir/other-directory"
  # The exact recorded worker may legitimately cd outside its worktree. Its
  # endpoint identity still owns the lifecycle; cwd alone must not brick it.
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = display-message ]; then
  printf '%s\n' '$dir/other-directory'
  exit 0
fi
printf 'tmux' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown refused its recorded endpoint after it changed directory: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "moved-endpoint teardown left the task record"
  grep -Fq "tmux <kill-window> <-t> <=firstmate:=fm-$id>" "$dir/runtime.log" \
    || fail "moved-endpoint teardown did not stop the exact recorded worker: $(cat "$dir/runtime.log")"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "moved-endpoint teardown did not return its uncontested pool slot: $(cat "$dir/runtime.log")"

  pass "fm-teardown: an exact recorded endpoint still tears down after changing cwd outside its worktree"
}

# --- Treehouse project-lock anchoring across home layouts --------------------
#
# The lock is anchored at the local root home, so every home on this machine
# that can reach the same pool must derive the identical file. A remote parent
# binding terminates that walk at the home holding it: its parent is on another
# machine and can neither hold nor observe a lock taken here.

write_local_parent_record() {  # <home> <parent-home>
  cat > "$1/.fm-secondmate-parent" <<REC
schema=fm-secondmate-parent.v1
route=local
parent_home=$2
REC
}

write_remote_parent_record() {  # <home>
  cat > "$1/.fm-secondmate-parent" <<'REC'
schema=fm-secondmate-parent.v1
route=remote
parent_host=machine-a
REC
}

make_home() {  # <path>
  mkdir -p "$1/state" "$1/data" "$1/config" "$1/projects"
}

resolve_project_lock() {  # <home> <project>
  FM_HOME="$1" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$2"
}

test_project_lock_anchors_at_the_local_root_across_home_layouts() {
  local dir main_home main_project local_mate remote_mate remote_child
  local main_lock mate_lock remote_lock child_lock orphan_lock rc
  dir=$(make_case project-lock-anchoring)
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm anchor-fixture

  # Main-home layout: a root home and a local secondmate beneath it.
  main_home="$dir/home"
  main_project="$main_home/projects/project"
  make_home "$main_home"
  git clone -q "$dir/project" "$main_project"
  local_mate="$dir/local-mate"
  make_home "$local_mate"
  write_local_parent_record "$local_mate" "$main_home"
  git clone -q "$dir/project" "$local_mate/projects/project"

  # Remote layout: a home seeded from another machine, plus its own local child.
  remote_mate="$dir/remote-mate"
  make_home "$remote_mate"
  write_remote_parent_record "$remote_mate"
  git clone -q "$dir/project" "$remote_mate/projects/project"
  remote_child="$dir/remote-mate-child"
  make_home "$remote_child"
  write_local_parent_record "$remote_child" "$remote_mate"
  git clone -q "$dir/project" "$remote_child/projects/project"

  main_lock=$(resolve_project_lock "$main_home" "$main_project") \
    || fail "the root home could not resolve its project lock"
  mate_lock=$(resolve_project_lock "$local_mate" "$local_mate/projects/project") \
    || fail "a local secondmate home could not resolve its project lock"
  remote_lock=$(resolve_project_lock "$remote_mate" "$remote_mate/projects/project") \
    || fail "a remote-seeded secondmate home could not resolve its project lock"
  child_lock=$(resolve_project_lock "$remote_child" "$remote_child/projects/project") \
    || fail "a local child of a remote-seeded home could not resolve its project lock"

  [ "$main_lock" = "$mate_lock" ] \
    || fail "the root home and its local secondmate derived different project locks"
  [ "$remote_lock" = "$child_lock" ] \
    || fail "a remote-seeded home and its local child derived different project locks"
  case "$remote_lock" in
    "$remote_mate/state/"*) ;;
    *) fail "a remote-seeded home anchored its project lock outside its own state: $remote_lock" ;;
  esac

  # An origin-less local-only project still resolves, keyed on its worktree top.
  git init -q "$remote_mate/projects/local-only"
  orphan_lock=$(resolve_project_lock "$remote_mate" "$remote_mate/projects/local-only") \
    || fail "an origin-less local-only project could not resolve its lock in a remote-seeded home"
  [ "$orphan_lock" != "$remote_lock" ] \
    || fail "an origin-less project shared the lock identity of an unrelated origin"

  # Everything other than a remote route still fails closed.
  printf 'schema=fm-secondmate-parent.v1\nroute=sideways\n' \
    > "$remote_child/.fm-secondmate-parent"
  set +e
  resolve_project_lock "$remote_child" "$remote_child/projects/project" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unsupported parent route resolved a project lock instead of refusing"

  pass "Treehouse project locking anchors at the local root for main-home, local-secondmate, and remote-seeded layouts"
}

test_remote_seeded_home_returns_its_uncontested_slot() {
  local dir id=remote-task rc
  dir=$(make_case remote-home-teardown)
  mark_case_as_treehouse_pool "$dir"
  write_remote_parent_record "$dir/home"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "teardown in a remote-seeded home refused its own uncontested slot: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "remote-seeded teardown left the task record"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "remote-seeded teardown did not return its own pool slot: $(cat "$dir/runtime.log")"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# remote-seeded Treehouse teardown command\n'
    printf '$ FM_HOME=%s bin/fm-teardown.sh %s --force\n' "$dir/home" "$id"
    printf 'stdout:\n'; cat "$dir/stdout"
    printf 'stderr:\n'; cat "$dir/stderr"
    printf 'exit=%s\nruntime calls:\n' "$rc"; cat "$dir/runtime.log"
    printf 'task metadata=%s\nslot sentinel=%s\n' \
      "$([ -e "$dir/home/state/$id.meta" ] && printf present || printf removed)" \
      "$([ -e "$dir/worktree/sentinel" ] && printf present || printf removed)"
  fi

  pass "fm-teardown: a remote-seeded secondmate home returns its own uncontested pool slot"
}

test_remote_seeded_home_still_refuses_a_slot_its_child_holds() {
  local dir id=remote-stale other=child-task child_home child_project rc
  dir=$(make_case remote-home-collision)
  mark_case_as_treehouse_pool "$dir"
  write_remote_parent_record "$dir/home"
  printf 'fixture\n' > "$dir/project/tracked"
  git -C "$dir/project" add tracked
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  child_home="$dir/child-home"
  child_project="$child_home/projects/project"
  make_home "$child_home"
  write_local_parent_record "$child_home" "$dir/home"
  git clone -q "$dir/project" "$child_project"
  printf '%s\n' "- mate - fixture (home: $child_home; scope: test; projects: project; added 2026-01-01)" \
    > "$dir/home/data/secondmates.md"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$child_home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" \
    "worktree=$dir/worktree" "project=$child_project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "a remote-seeded home returned a pool slot its own local child still holds"
  assert_present "$dir/home/state/$id.meta" "remote-layout collision removed stale metadata"
  assert_present "$child_home/state/$other.meta" "remote-layout collision removed live metadata"
  assert_present "$dir/worktree/sentinel" "remote-layout collision reset the shared slot"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "remote-layout refusal should name the task holding the slot"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# remote-seeded cross-home collision command\n'
    printf '$ FM_HOME=%s bin/fm-teardown.sh %s --force\n' "$dir/home" "$id"
    printf 'stderr:\n'; cat "$dir/stderr"
    printf 'exit=%s\nruntime calls=%s\n' "$rc" \
      "$([ -s "$dir/runtime.log" ] && cat "$dir/runtime.log" || printf none)"
    printf 'remote metadata=%s\nchild metadata=%s\nslot sentinel=%s\n' \
      "$([ -e "$dir/home/state/$id.meta" ] && printf preserved || printf removed)" \
      "$([ -e "$child_home/state/$other.meta" ] && printf preserved || printf removed)" \
      "$([ -e "$dir/worktree/sentinel" ] && printf preserved || printf removed)"
  fi

  pass "fm-teardown: slot ownership across a remote-seeded home and its local child still refuses"
}

test_remote_layout_homes_serialize_on_one_project_lock() {
  local dir id=remote-serialize child_home child_project lock holder rc waited=0
  dir=$(make_case remote-lock-exclusion)
  mark_case_as_treehouse_pool "$dir"
  write_remote_parent_record "$dir/home"
  printf 'fixture\n' > "$dir/project/tracked"
  git -C "$dir/project" add tracked
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  child_home="$dir/child-home"
  child_project="$child_home/projects/project"
  make_home "$child_home"
  write_local_parent_record "$child_home" "$dir/home"
  git clone -q "$dir/project" "$child_project"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  # The local child takes the lock its own home derives and stays alive holding
  # it, standing in for a slot allocation running in that home right now.
  lock=$(resolve_project_lock "$child_home" "$child_project") \
    || fail "the local child could not resolve the shared project lock"
  FM_HOME="$child_home" bash -c \
    '. "$1"; fm_lock_try_acquire "$2" || exit 1; : > "$3"; exec sleep 30' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$lock" "$dir/lock-held" &
  holder=$!
  while [ ! -e "$dir/lock-held" ] && [ "$waited" -lt 100 ]; do
    kill -0 "$holder" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$dir/lock-held" ] || fail "the local child never took the shared project lock"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$rc" -ne 0 ] \
    || fail "a remote-seeded home returned a pool slot while its local child held the shared lock"
  assert_present "$dir/home/state/$id.meta" "contended remote-layout teardown removed the task record"
  assert_present "$dir/worktree/sentinel" "contended remote-layout teardown reset the slot"
  [ ! -s "$dir/runtime.log" ] \
    || fail "contended remote-layout teardown reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "another Treehouse slot allocation or return is in progress" \
    "the refusal should name the shared project lock, not some unrelated check"

  pass "Treehouse project locking still serializes two homes across the remote-seeded boundary"
}

# The slot-reuse sequence with only ONE discoverable record: the finished task's
# worker exited, its slot was granted to another task, and that task leaves no
# record this home can enumerate. Nothing in the record scan contradicts the
# stale worktree= line, so the slot's own owner claim is the only evidence that
# it was reassigned. The slot is no longer this task's, so teardown finishes the
# task's own cleanup and leaves the slot - its worker, its copy, its claim -
# exactly as it found it.
assert_reassigned_slot_left_alone() {  # <case> <id> <other> <description>
  local dir=$1 id=$2 other=$3 description=$4
  assert_absent "$dir/home/state/$id.meta" "$description: the stale task's own record was not removed"
  assert_present "$dir/pool/1/.fm-slot-owner" "$description: another task's slot claim was removed"
  assert_contains "$(cat "$dir/pool/1/.fm-slot-owner")" "task=$other" \
    "$description: another task's slot claim was rewritten"
  assert_present "$dir/pool/1/project/.git" "$description: the reassigned slot's checkout was removed"
  ! grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "$description: the reassigned slot was returned to the pool: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "$description: the warning should name the task the slot was reassigned to"
  assert_contains "$(cat "$dir/stderr")" "reassigned" \
    "$description: the warning should name the reassignment as the cause"
}

test_reassigned_pool_slot_finishes_own_cleanup_without_touching_the_slot() {
  local dir id=stale-task other=reassigned-task worker rc

  # Dirty slot, --force, and a live worker inside it: --force authorizes
  # discarding this task's unlanded work, which is already gone with the slot,
  # never the other task's live work.
  dir=$(make_case slot-reassigned)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  claim_pool_slot "$dir" "$other" "$dir/other-home"
  # Staged in this shell, not a command substitution: a background child of a
  # $(...) subshell does not outlive it, and the point of this worker is to be
  # alive in the slot while teardown runs.
  ( cd "$dir/worktree" && exec sleep 30 ) &
  worker=$!

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "teardown of a task whose slot was reassigned failed: $(cat "$dir/stderr")"
  kill -0 "$worker" 2>/dev/null || fail "teardown killed the worker holding the reassigned pool slot"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot another task had claimed"
  assert_reassigned_slot_left_alone "$dir" "$id" "$other" "dirty reassigned slot with --force"
  assert_contains "$(cat "$dir/stderr")" "$dir/other-home" \
    "the warning should name the claimant's home"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true

  # The same reassignment on a CLEAN slot: a landed ship task torn down without
  # --force, which is the shape of the real incident. A clean, fully landed copy
  # passes every unlanded-work check, so only the ownership determination can
  # keep this slot out of the pool; a guard keyed off dirtiness would return it
  # and destroy the live task's copy.
  dir=$(make_case slot-reassigned-clean)
  mark_case_as_treehouse_pool "$dir"
  rm -f "$dir/worktree/sentinel"
  [ -z "$(git -C "$dir/worktree" status --porcelain)" ] \
    || fail "clean-slot fixture is not clean: $(git -C "$dir/worktree" status --porcelain)"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=ship"
  claim_pool_slot "$dir" "$other" "$dir/other-home"
  ( cd "$dir/worktree" && exec sleep 30 ) &
  worker=$!

  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "teardown of a clean ship task whose slot was reassigned failed: $(cat "$dir/stderr")"
  kill -0 "$worker" 2>/dev/null || fail "teardown killed the worker holding the clean reassigned pool slot"
  assert_reassigned_slot_left_alone "$dir" "$id" "$other" "clean reassigned slot without --force"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true

  # A claim that exists but cannot be read as a claim proves nothing either way,
  # so it refuses rather than guessing the slot is still this task's.
  dir=$(make_case slot-claim-unreadable)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  printf 'not-a-claim\n' > "$dir/pool/1/.fm-slot-owner"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot whose claim could not be read"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot whose claim could not be read"
  assert_present "$dir/pool/1/.fm-slot-owner" "teardown removed an unreadable slot claim"
  assert_present "$dir/home/state/$id.meta" "teardown removed the task record on an unreadable claim"
  [ ! -s "$dir/runtime.log" ] \
    || fail "teardown reached the runtime on an unreadable slot claim: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$dir/pool/1/.fm-slot-owner" \
    "unreadable-claim refusal should name the claim file to inspect"

  pass "fm-teardown: a pool slot claimed by another task is left alone while the task's own cleanup finishes"
}

# The reuse collision where BOTH records survive: the stale task's record still
# names the slot the pool handed on, and the claimant's own record names it too.
# The claim proves the stale record's teardown is records-only, so the record
# scan must not refuse it; once it is gone, the claimant tears down normally.
test_stale_record_on_claimed_slot_retires_then_claimant_tears_down() {
  local dir id=stale-task other=live-task rc

  dir=$(make_case slot-reassigned-both-records)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$dir/home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  claim_pool_slot "$dir" "$other"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "records-only teardown of a stale record on a claimed slot failed: $(cat "$dir/stderr")"
  assert_reassigned_slot_left_alone "$dir" "$id" "$other" "stale record beside the claimant's record"
  assert_present "$dir/worktree/sentinel" "records-only teardown reset the claimant's slot"
  assert_present "$dir/home/state/$other.meta" "records-only teardown removed the claimant's record"

  : > "$dir/runtime.log"
  run_case "$dir" "$other" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "claimant teardown failed after the stale record retired: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$other.meta" "claimant teardown left its record"
  assert_absent "$dir/pool/1/.fm-slot-owner" "claimant teardown left its spent slot claim behind"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "claimant teardown did not return its pool slot: $(cat "$dir/runtime.log")"

  pass "fm-teardown: a stale record on a claimed slot retires, then the claimant tears down"
}

# The two states that must never become a false refusal: the task's own claim,
# and no claim at all (a slot taken before claims existed, or already returned).
test_own_and_absent_slot_claims_still_tear_down() {
  local dir id=owned-task

  dir=$(make_case slot-claim-own)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  claim_pool_slot "$dir" "$id"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of a task holding its own slot claim failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "own-claim teardown left the task record"
  assert_absent "$dir/pool/1/.fm-slot-owner" "own-claim teardown left its spent slot claim behind"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "own-claim teardown did not return its own pool slot: $(cat "$dir/runtime.log")"

  dir=$(make_case slot-claim-absent)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of an unclaimed slot failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "unclaimed-slot teardown left the task record"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "unclaimed-slot teardown did not return its pool slot: $(cat "$dir/runtime.log")"

  pass "fm-teardown: a task's own slot claim, and an unclaimed slot, both still tear down"
}

# The tmux shim used by the endpoint-close tests below: every subcommand
# reaches the real isolated server, so presence is always read from real tmux.
# When FM_TEST_BLOCK_KILL is set, `kill-window` alone fails without forwarding,
# which is a close that genuinely could not do its job - the recorded window is
# demonstrably still there afterwards. Real tmux cannot be made to accept a
# kill-window and leave the window alive, so blocking the call is the only way
# to reach that state against a real endpoint.
# When FM_TEST_UNREADABLE_LIST is set, `list-windows` fails with a response
# that is NOT one of tmux's definitive missing-session/server answers, which is
# the transient-server and tmux-absent-from-PATH shape: the read never happened,
# so it proves nothing about whether the window survived.
# The socket stays a RELATIVE name reached from <dir>, matching the isolated
# case above: this fixture's absolute path is longer than a unix socket path
# may be on macOS.
write_close_failing_tmux_shim() {  # <dir> <socket-name> <real-tmux>
  local dir=$1 socket=$2 real=$3
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
printf 'tmux' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
if [ -n "\${FM_TEST_BLOCK_KILL:-}" ] && [ "\${1:-}" = kill-window ]; then
  echo "can't find window" >&2
  exit 1
fi
if [ -n "\${FM_TEST_UNREADABLE_LIST:-}" ] && [ "\${1:-}" = list-windows ]; then
  echo "lost server" >&2
  exit 1
fi
cd '$dir'
exec '$real' -S '$socket' "\$@"
SH
  chmod +x "$dir/fakebin/tmux"
}

# write_endpoint_close_meta: a task record whose worktree and project do not
# exist, which keeps the cases below on the endpoint close itself - the pool
# return and its own refusals are covered elsewhere in this file.
write_endpoint_close_meta() {  # <case-dir> <id> <window>
  fm_write_meta "$1/home/state/$2.meta" \
    "window=$3" "endpoint_task_id=$2" \
    "worktree=$1/nonexistent-worktree" "project=$1/nonexistent-project" \
    "kind=ship" "mode=no-mistakes"
}

test_failed_endpoint_close_refuses_before_removing_the_record() {
  local dir socket session='close failure' id=strand-task rc
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  dir=$(make_case close-failure)
  socket=dedicated.sock
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s "$session" -n control )
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "=$session:" -n "fm-$id" )
  write_close_failing_tmux_shim "$dir" "$socket" "$REAL_TMUX"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "fm-$id" \
    || fail "fixture did not create the task window"

  write_endpoint_close_meta "$dir" "$id" "$session:fm-$id"

  set +e
  env -u TMUX -u TMUX_PANE FM_TEST_BLOCK_KILL=1 \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" \
    > "$dir/failed.out" 2> "$dir/failed.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown reported success after a close that failed: $(cat "$dir/failed.err")"
  assert_no_grep "teardown $id complete" "$dir/failed.out" \
    "teardown announced a completed cleanup after a close that failed"
  assert_grep "kill-window" "$dir/runtime.log" "teardown never attempted the recorded close"
  assert_grep "is still present after its close" "$dir/failed.err" \
    "the backend's own close failure was swallowed instead of reported"
  assert_grep "could not be closed" "$dir/failed.err" \
    "teardown did not refuse on the reported close failure"
  # The refusal exists so the endpoint is not STRANDED: the record is the only
  # thing naming what survived, so it has to outlive the refusal.
  assert_present "$dir/home/state/$id.meta" \
    "teardown deleted the only durable record naming an endpoint it could not close"
  # That retention is this run's, not a durable one - a task carrying a backlog
  # transition has the next session's pending-close replay remove the retained
  # record - so the refusal has to say so instead of sending the operator away
  # trusting it.
  assert_grep "not durable across a session start" "$dir/failed.err" \
    "the refusal promised a retention teardown does not own"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "fm-$id" \
    || fail "the surviving endpoint disappeared, so this case no longer proves the hazard"
  isolated_tmux_window_exists "$dir" "$socket" "$session" control \
    || fail "the refused cleanup removed an independent window"

  # Same task, same records, with the close working again: the retained record
  # is what lets the rerun finish, so the refusal is recoverable, not terminal.
  env -u TMUX -u TMUX_PANE \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" \
    > "$dir/rerun.out" 2> "$dir/rerun.err" \
    || fail "the rerun after a recovered close still failed: $(cat "$dir/rerun.err")"
  assert_absent "$dir/home/state/$id.meta" "the recovered rerun left the task record behind"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "fm-$id" \
    && fail "the recovered rerun did not close the recorded endpoint"
  isolated_tmux_window_exists "$dir" "$socket" "$session" control \
    || fail "the recovered rerun removed an independent window"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null ) || true
  pass "fm-teardown: a close that genuinely failed refuses and keeps the record naming the surviving endpoint, and the same teardown finishes once the close works"
}

test_forced_teardown_continues_past_a_close_it_could_not_make() {
  local dir socket session='forced close failure' id=forced-task rc
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  dir=$(make_case forced-close-failure)
  socket=dedicated.sock
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s "$session" -n control )
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "=$session:" -n "fm-$id" )
  write_close_failing_tmux_shim "$dir" "$socket" "$REAL_TMUX"
  write_endpoint_close_meta "$dir" "$id" "$session:fm-$id"

  # Exactly the same case run twice, so the only difference is the operator's
  # explicit authority. Unforced it still refuses, which is what makes --force
  # an override rather than the absence of a gate.
  set +e
  env -u TMUX -u TMUX_PANE FM_TEST_BLOCK_KILL=1 \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" \
    > "$dir/unforced.out" 2> "$dir/unforced.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the unforced run did not refuse a close that failed: $(cat "$dir/unforced.err")"
  assert_present "$dir/home/state/$id.meta" "the unforced refusal removed the task record"
  grep -qF -- "--force" "$dir/unforced.err" \
    || fail "the refusal did not name the override that lets an operator through"

  env -u TMUX -u TMUX_PANE FM_TEST_BLOCK_KILL=1 \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" --force \
    > "$dir/forced.out" 2> "$dir/forced.err" \
    || fail "--force did not get past a close that failed: $(cat "$dir/forced.err")"
  assert_grep "teardown $id complete" "$dir/forced.out" "the forced cleanup did not finish"
  assert_absent "$dir/home/state/$id.meta" "the forced cleanup kept the task record"
  # Forced cleanup is the case that leaves nothing on disk naming the endpoint,
  # so the operator who forced it has to be told exactly what may survive.
  assert_grep "tmux" "$dir/forced.err" "the forced run did not name the backend it could not close"
  assert_grep "$session:fm-$id" "$dir/forced.err" \
    "the forced run did not name the endpoint it could not close"
  assert_grep "could not be closed" "$dir/forced.err" \
    "the forced run hid the close failure it continued past"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "fm-$id" \
    || fail "the forced run closed the window after all, so this case no longer proves the override"
  isolated_tmux_window_exists "$dir" "$socket" "$session" control \
    || fail "the forced cleanup removed an independent window"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null ) || true
  pass "fm-teardown: --force continues past a close it could not make while still reporting it, and the same case refuses without --force"
}

test_unreadable_close_read_refuses_while_a_definitive_absence_completes() {
  local dir socket='dedicated.sock' session='unreadable read' id=unreadable-task rc
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }

  # A close that failed, followed by an inventory read that could not run at
  # all. Nothing here shows the window absent, so treating it as closed would
  # strand exactly the endpoint the refusal exists to keep named.
  dir=$(make_case unreadable-close-read)
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s "$session" -n control )
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "=$session:" -n "fm-$id" )
  write_close_failing_tmux_shim "$dir" "$socket" "$REAL_TMUX"
  write_endpoint_close_meta "$dir" "$id" "$session:fm-$id"

  set +e
  env -u TMUX -u TMUX_PANE FM_TEST_BLOCK_KILL=1 FM_TEST_UNREADABLE_LIST=1 \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" \
    > "$dir/unreadable.out" 2> "$dir/unreadable.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unreadable inventory passed for proof the window closed: $(cat "$dir/unreadable.err")"
  assert_grep "could not be read after its close" "$dir/unreadable.err" \
    "the refusal did not come from the close re-read that could not run"
  assert_no_grep "teardown $id complete" "$dir/unreadable.out" \
    "teardown announced a cleanup it never verified"
  assert_present "$dir/home/state/$id.meta" \
    "teardown deleted the only durable record naming an endpoint it never saw close"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "fm-$id" \
    || fail "the unread endpoint disappeared, so this case no longer proves the hazard"
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null ) || true

  # The other direction, twice: tmux answering DEFINITIVELY that the session,
  # or its whole server, is absent is proof the window is gone, so an endpoint
  # that outlived its session is still ordinary silent cleanup.
  dir=$(make_case missing-session-close-read)
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s survivor -n control )
  write_close_failing_tmux_shim "$dir" "$socket" "$REAL_TMUX"
  write_endpoint_close_meta "$dir" "$id" "gone session:fm-$id"
  env -u TMUX -u TMUX_PANE FM_TEST_BLOCK_KILL=1 \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" \
    > "$dir/missing-session.out" 2> "$dir/missing-session.err" \
    || fail "a definitively absent session refused its own cleanup: $(cat "$dir/missing-session.err")"
  assert_grep "teardown $id complete" "$dir/missing-session.out" \
    "an endpoint whose session is definitively gone did not complete cleanup"
  assert_no_grep "could not be closed" "$dir/missing-session.err" \
    "an endpoint whose session is definitively gone produced a close refusal"
  assert_absent "$dir/home/state/$id.meta" \
    "an endpoint whose session is definitively gone left its task record behind"
  isolated_tmux_window_exists "$dir" "$socket" survivor control \
    || fail "cleaning up an absent session disturbed a live one"
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null ) || true

  dir=$(make_case missing-server-close-read)
  write_close_failing_tmux_shim "$dir" "$socket" "$REAL_TMUX"
  write_endpoint_close_meta "$dir" "$id" "$session:fm-$id"
  env -u TMUX -u TMUX_PANE FM_TEST_BLOCK_KILL=1 \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" \
    > "$dir/missing-server.out" 2> "$dir/missing-server.err" \
    || fail "a definitively absent server refused its own cleanup: $(cat "$dir/missing-server.err")"
  assert_grep "teardown $id complete" "$dir/missing-server.out" \
    "an endpoint whose server is definitively gone did not complete cleanup"
  assert_no_grep "could not be closed" "$dir/missing-server.err" \
    "an endpoint whose server is definitively gone produced a close refusal"
  assert_absent "$dir/home/state/$id.meta" \
    "an endpoint whose server is definitively gone left its task record behind"

  pass "fm-teardown: a close re-read that could not run refuses, while a definitively absent session or server still completes silently"
}

test_forced_secondmate_child_close_failure_still_refuses() {
  local dir socket='dedicated.sock' session='child close failure' mate parent=mate-task child=child-task rc
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  dir=$(make_case secondmate-child-close-failure)
  mate="$dir/mate"
  mkdir -p "$mate/state" "$mate/data" "$mate/config"
  printf '%s' "$parent" > "$mate/.fm-secondmate-home"
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s "$session" -n control )
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "=$session:" -n "fm-$child" )
  write_close_failing_tmux_shim "$dir" "$socket" "$REAL_TMUX"
  fm_write_meta "$dir/home/state/$parent.meta" \
    "window=$session:fm-$parent" "endpoint_task_id=$parent" \
    "worktree=$mate" "project=$mate" "home=$mate" \
    "kind=secondmate" "mode=secondmate" "harness=echo" "yolo=off" "projects=alpha"
  fm_write_meta "$mate/state/$child.meta" \
    "window=$session:fm-$child" "endpoint_task_id=$child" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=ship" "harness=echo"

  # Forced secondmate cleanup is the ONLY way into the child close path, so
  # --force cannot also be the way past it: honoring force here would delete
  # the refusal rather than override it, and discard a child home whose
  # endpoint is still live.
  set +e
  env -u TMUX -u TMUX_PANE FM_TEST_BLOCK_KILL=1 \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$parent" --force \
    > "$dir/child.out" 2> "$dir/child.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forced secondmate cleanup continued past a child close that failed: $(cat "$dir/child.err")"
  assert_grep "child $child" "$dir/child.err" \
    "the refusal did not name the child whose endpoint could not be closed"
  assert_grep "could not be closed" "$dir/child.err" \
    "forced secondmate cleanup swallowed the child close failure"
  assert_no_grep "teardown $parent complete" "$dir/child.out" \
    "forced secondmate cleanup reported a cleanup it stopped short of"
  assert_present "$mate/state/$child.meta" \
    "forced secondmate cleanup removed the record naming a child endpoint it could not close"
  assert_present "$dir/home/state/$parent.meta" \
    "forced secondmate cleanup removed the secondmate's own record after refusing"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "fm-$child" \
    || fail "the surviving child endpoint disappeared, so this case no longer proves the hazard"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null ) || true
  pass "fm-teardown: forced secondmate cleanup still refuses on a child endpoint close that failed"
}

test_orca_close_failure_refuses_even_under_force() {
  local dir orca_free id=orca-strand rc
  dir=$(make_case orca-close-failure)
  orca_free=$(fm_test_base_path_sans "$PATH" orca)
  ! PATH="$dir/fakebin:$orca_free" command -v orca >/dev/null 2>&1 \
    || fail "the orca-free search path still resolved orca"
  # The Orca arm reports a close its missing CLI never attempted, and the step
  # right after this close removes the Orca worktree through that same CLI, so
  # a forced continue could only die there having removed nothing. --force
  # therefore changes nothing at this site.
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-7" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "backend=orca" "orca_worktree_id=worktree-9::/orca/worktree-9" "kind=ship" "mode=no-mistakes"

  set +e
  env -u TMUX -u TMUX_PANE \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$orca_free" "$TEARDOWN" "$id" --force \
    > "$dir/orca-forced.out" 2> "$dir/orca-forced.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a forced Orca cleanup continued past a close that never happened: $(cat "$dir/orca-forced.err")"
  assert_grep "could not be closed" "$dir/orca-forced.err" \
    "the forced Orca run did not report the close it could not make"
  assert_no_grep "--force authorizes continuing" "$dir/orca-forced.err" \
    "the forced Orca run announced a continue it cannot carry out"
  assert_no_grep "teardown $id complete" "$dir/orca-forced.out" \
    "the forced Orca run reported a completed cleanup"
  assert_present "$dir/home/state/$id.meta" \
    "the forced Orca refusal removed the only durable record naming the terminal"
  # Unforced is not the interesting direction here: an Orca record whose CLI is
  # gone never reaches this close without --force, because the worktree
  # preflight above already refuses. --force is the only way in, and it still
  # stops - unlike the generic site, where
  # test_forced_teardown_continues_past_a_close_it_could_not_make proves the
  # same operator authority does get through.
  set +e
  env -u TMUX -u TMUX_PANE \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$orca_free" "$TEARDOWN" "$id" \
    > "$dir/orca-unforced.out" 2> "$dir/orca-unforced.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unforced Orca cleanup completed with no CLI to close its terminal: $(cat "$dir/orca-unforced.err")"
  assert_present "$dir/home/state/$id.meta" \
    "the unforced Orca refusal removed the only durable record naming the terminal"

  pass "fm-teardown: an Orca close its missing CLI never attempted refuses even under --force, keeping the record naming the terminal"
}

test_already_gone_endpoint_still_completes_without_a_refusal() {
  local dir socket session='already gone' id=gone-task
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  dir=$(make_case already-gone)
  socket=dedicated.sock
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s "$session" -n control )
  write_close_failing_tmux_shim "$dir" "$socket" "$REAL_TMUX"
  # The whole point of this case: the recorded window has already exited, so
  # its close cannot succeed and must still be the ordinary silent cleanup.
  isolated_tmux_window_exists "$dir" "$socket" "$session" "fm-$id" \
    && fail "the already-gone fixture unexpectedly has its task window"

  write_endpoint_close_meta "$dir" "$id" "$session:fm-$id"

  env -u TMUX -u TMUX_PANE \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" \
    > "$dir/gone.out" 2> "$dir/gone.err" \
    || fail "an already-exited endpoint refused cleanup: $(cat "$dir/gone.err")"
  assert_grep "teardown $id complete" "$dir/gone.out" \
    "an already-exited endpoint did not report a completed cleanup"
  assert_no_grep "could not be closed" "$dir/gone.err" \
    "an already-exited endpoint produced a close refusal"
  assert_no_grep "is still present after its close" "$dir/gone.err" \
    "an already-exited endpoint was reported as a surviving endpoint"
  assert_absent "$dir/home/state/$id.meta" \
    "an already-exited endpoint left its task record behind"

  # A server that is already gone entirely is the same ordinary case, and the
  # adapter is driven directly so no other teardown refusal can stand in for it.
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null ) || true
  # shellcheck disable=SC2016 # $1 and $2 expand inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_kill tmux "$2"' _ "$ROOT" "$session:fm-$id" \
    > "$dir/deadserver.out" 2> "$dir/deadserver.err" \
    || fail "closing an endpoint whose whole server is gone reported a failure: $(cat "$dir/deadserver.err")"
  [ ! -s "$dir/deadserver.err" ] \
    || fail "closing an endpoint whose whole server is gone was not silent: $(cat "$dir/deadserver.err")"

  pass "fm-teardown: an already-exited endpoint, and a server that is already gone, still complete cleanup silently"
}

# --- A persistent secondmate home seeded into a reused pool slot -------------
#
# Seeding a secondmate durably leases a pool slot that completed scouts used
# before, so their stale records - and, for a home seeded before seeding
# published its own claim, the slot's old owner claim - still name what is now
# the secondmate's home. Returning or resetting that slot would discard the
# seeded home. These cases drive the real bin/fm-home-seed.sh claim-slot and
# bin/fm-teardown.sh interfaces: the claim is reconciled only after the
# persistent owner is proved, a completed scout whose endpoint is gone then
# finishes its own cleanup without touching the home, and every unproved,
# contradictory, live, or incomplete shape refuses before any mutation.

PERSISTENT_MATE=harbor

# Lays the committed seed of a local secondmate over the case's pool slot: a
# durable Treehouse lease, the identity marker, the local parent binding, the
# home's operational files and project clone, and the registering route.
seed_slot_as_persistent_home() {  # <case> [lease-holder] [registered-home] [parent-home]
  local dir=$1 slot home holder registered parent
  slot=$(cd "$dir/pool/1/project" && pwd -P)
  home=$(cd "$dir/home" && pwd -P)
  holder=${2:-$PERSISTENT_MATE}
  registered=${3:-$slot}
  parent=${4:-$home}
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"%s"}]}\n' \
    "$slot" "$holder" > "$dir/pool/treehouse-state.json"
  printf '%s\n' "$PERSISTENT_MATE" > "$slot/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$slot/.fm-secondmate-parent"
  mkdir -p "$slot/data" "$slot/state" "$slot/config" "$slot/projects"
  printf 'Persistent fixture charter\n' > "$slot/data/charter.md"
  printf 'saved review\n' > "$slot/data/review.md"
  [ -d "$slot/projects/harbor/.git" ] || fm_git_init_commit "$slot/projects/harbor" >/dev/null
  printf -- '- %s - Persistent fixture domain (home: %s; scope: persistent work; projects: harbor; added 2026-09-29)\n' \
    "$PERSISTENT_MATE" "$registered" > "$dir/home/data/secondmates.md"
}

# A completed scout record naming the seeded slot: a report, a captain-call
# inventory that verifies, and an endpoint the fake tmux reports as gone.
write_persistent_scout() {  # <case> <id> [decision-keys]
  local dir=$1 id=$2 keys=${3:-}
  mkdir -p "$dir/home/data/$id"
  printf 'Complete fixture report with no unresolved choices.\n' > "$dir/home/data/$id/report.md"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout" \
    "decisions_reviewed=1" "decision_keys=$keys"
  printf 'done [at=123]: fixture report complete\n' > "$dir/home/state/$id.status"
}

make_persistent_case() {  # <name> <claim-owner> <scout-id>...
  local dir claimant=$2
  dir=$(make_case "$1")
  shift 2
  mark_case_as_treehouse_pool "$dir"
  seed_slot_as_persistent_home "$dir"
  while [ "$#" -gt 0 ]; do
    write_persistent_scout "$dir" "$1"
    shift
  done
  claim_pool_slot "$dir" "$claimant" "$(cd "$dir/home" && pwd -P)"
  printf '%s\n' "$dir"
}

# Every byte of the pool - the seeded home, its clone, its lease, the claim and
# any retained prior claim - plus both checkouts' commits.
persistent_home_fingerprint() {  # <case>
  (
    cd "$1/pool" || exit 1
    find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r path; do
      printf '%s %s\n' "$(cksum < "$path")" "$path"
    done
    git -C 1/project rev-parse HEAD
    git -C 1/project/projects/harbor rev-parse HEAD
  )
}

run_persistent_teardown() {  # <case> <id> [teardown flags...]
  local dir=$1 id=$2
  shift 2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" "$@" > "$dir/stdout" 2> "$dir/stderr"
}

run_claim_slot() {  # <case> [mate]
  local dir=$1 mate=${2:-$PERSISTENT_MATE}
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/project" \
    "$ROOT/bin/fm-home-seed.sh" claim-slot "$mate" > "$dir/claim.out" 2> "$dir/claim.err"
}

assert_persistent_teardown_refused() {  # <case> <id> <before-fingerprint> <description> [teardown flags...]
  local dir=$1 id=$2 before=$3 description=$4 meta_before rc=0
  shift 4
  meta_before=$(cksum < "$dir/home/state/$id.meta")
  : > "$dir/runtime.log"
  run_persistent_teardown "$dir" "$id" "$@" || rc=$?
  [ "$rc" -ne 0 ] || fail "$description: teardown succeeded: $(cat "$dir/stdout")"
  [ "$(cksum < "$dir/home/state/$id.meta")" = "$meta_before" ] \
    || fail "$description: the task record changed before the refusal"
  [ "$(persistent_home_fingerprint "$dir")" = "$before" ] \
    || fail "$description: the seeded home, its clone, lease, or claim changed"
  ! grep -Eq 'treehouse|kill-|send-keys' "$dir/runtime.log" \
    || fail "$description: a runtime close or pool command ran before the refusal: $(cat "$dir/runtime.log")"
}

assert_claim_slot_refused() {  # <case> <before-fingerprint> <description> <expected-diagnostic>
  local dir=$1 before=$2 description=$3 expected=$4 rc=0
  run_claim_slot "$dir" || rc=$?
  [ "$rc" -ne 0 ] || fail "$description: claim-slot succeeded: $(cat "$dir/claim.out")"
  [ "$(persistent_home_fingerprint "$dir")" = "$before" ] \
    || fail "$description: claim-slot changed the seeded home, its lease, or its claim"
  assert_contains "$(cat "$dir/claim.err")" "$expected" "$description: claim-slot diagnostic"
}

test_seeded_home_named_by_stale_scout_records_is_never_returned() {
  local dir before id

  # The live shape before reconciliation: both completed scouts still name the
  # seeded home and the claim still names the first. Neither order may proceed.
  for id in old-scout-a old-scout-b; do
    dir=$(make_persistent_case "stale-claim-$id" old-scout-a old-scout-a old-scout-b)
    before=$(persistent_home_fingerprint "$dir")
    assert_persistent_teardown_refused "$dir" "$id" "$before" "stale claim, two records, cleanup of $id"
    assert_present "$dir/home/state/old-scout-a.meta" "stale claim: old-scout-a's record was removed"
    assert_present "$dir/home/state/old-scout-b.meta" "stale claim: old-scout-b's record was removed"
  done

  # The last stale record alone: its old claim reads as its own, which used to
  # take the pool-return path against the seeded home. The durable lease is
  # proof the slot is a persistent home, so the refusal holds even with --force
  # and names the reconciliation to run.
  for id in unforced --force; do
    dir=$(make_persistent_case "stale-claim-sole$id" old-scout-a old-scout-a)
    before=$(persistent_home_fingerprint "$dir")
    if [ "$id" = --force ]; then
      assert_persistent_teardown_refused "$dir" old-scout-a "$before" "stale claim, sole record, --force" --force
    else
      assert_persistent_teardown_refused "$dir" old-scout-a "$before" "stale claim, sole record"
    fi
    assert_contains "$(cat "$dir/stderr")" "claim-slot $PERSISTENT_MATE" \
      "stale claim, sole record: the refusal should name the claim reconciliation"
  done

  pass "fm-teardown: a seeded persistent home named by stale scout records and an old claim is never returned, reset, or reaped"
}

test_reconciled_seeded_home_lets_completed_dead_scouts_finish() {
  local dir before home unrelated_before mate_before

  dir=$(make_persistent_case reconciled old-scout-a old-scout-a old-scout-b)
  home=$(cd "$dir/home" && pwd -P)
  # An unrelated task with its own endpoint must be left entirely alone.
  fm_write_meta "$dir/home/state/unrelated.meta" \
    "window=firstmate:fm-unrelated" "endpoint_task_id=unrelated" \
    "worktree=$dir/unrelated-worktree" "project=$dir/project" "kind=ship"
  unrelated_before=$(cksum < "$dir/home/state/unrelated.meta")

  run_claim_slot "$dir" || fail "claim-slot refused a proved persistent home: $(cat "$dir/claim.err")"
  [ "$(cat "$dir/pool/1/.fm-slot-owner")" = "$(printf 'task=%s\nhome=%s' "$PERSISTENT_MATE" "$home")" ] \
    || fail "claim-slot did not publish the secondmate's claim: $(cat "$dir/pool/1/.fm-slot-owner")"
  [ "$(cat "$dir/pool/1/.fm-slot-owner.prior")" = "$(printf 'task=old-scout-a\nhome=%s' "$home")" ] \
    || fail "claim-slot did not retain the replaced claim as recovery evidence"
  before=$(persistent_home_fingerprint "$dir")

  : > "$dir/runtime.log"
  run_persistent_teardown "$dir" old-scout-a \
    || fail "a completed dead scout on a reconciled persistent home did not finish: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/old-scout-a.meta" "old-scout-a's own record was not removed"
  assert_present "$dir/home/state/old-scout-b.meta" "old-scout-a's cleanup removed the other stale record"
  assert_contains "$(cat "$dir/stdout")" "left to task $PERSISTENT_MATE" \
    "the completion line should name the persistent owner the slot was left to"
  assert_contains "$(cat "$dir/stderr")" "old-scout-b" \
    "the cleanup should name the other stale record it left alone"
  [ "$(persistent_home_fingerprint "$dir")" = "$before" ] \
    || fail "cleanup of old-scout-a changed the seeded home, its clone, lease, or claim"
  ! grep -Fq 'treehouse' "$dir/runtime.log" \
    || fail "cleanup of old-scout-a ran a pool operation: $(cat "$dir/runtime.log")"
  ! grep -Eq 'kill-[a-z]* <-t> <[^>]*(fm-unrelated|fm-old-scout-b)' "$dir/runtime.log" \
    || fail "cleanup of old-scout-a closed an unrelated endpoint: $(cat "$dir/runtime.log")"
  [ "$(cksum < "$dir/home/state/unrelated.meta")" = "$unrelated_before" ] \
    || fail "cleanup of old-scout-a changed an unrelated task record"

  : > "$dir/runtime.log"
  run_persistent_teardown "$dir" old-scout-b \
    || fail "the second completed dead scout did not finish: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/old-scout-b.meta" "old-scout-b's own record was not removed"
  [ "$(persistent_home_fingerprint "$dir")" = "$before" ] \
    || fail "cleanup of old-scout-b changed the seeded home, its clone, lease, or claim"
  ! grep -Fq 'treehouse' "$dir/runtime.log" \
    || fail "cleanup of old-scout-b ran a pool operation: $(cat "$dir/runtime.log")"

  # Launching the secondmate first adds its own record naming the home. That
  # record is the proved owner itself, so a stale scout still finishes and the
  # secondmate's record and endpoint are untouched.
  dir=$(make_persistent_case reconciled-launched old-scout-a old-scout-a)
  run_claim_slot "$dir" || fail "claim-slot refused before launch: $(cat "$dir/claim.err")"
  fm_write_meta "$dir/home/state/$PERSISTENT_MATE.meta" \
    "window=firstmate:fm-$PERSISTENT_MATE" "endpoint_task_id=$PERSISTENT_MATE" \
    "kind=secondmate" "home=$dir/worktree" "worktree=$dir/worktree"
  mate_before=$(cksum < "$dir/home/state/$PERSISTENT_MATE.meta")
  before=$(persistent_home_fingerprint "$dir")
  : > "$dir/runtime.log"
  run_persistent_teardown "$dir" old-scout-a \
    || fail "a stale scout beside the launched secondmate's record did not finish: $(cat "$dir/stderr")"
  [ "$(cksum < "$dir/home/state/$PERSISTENT_MATE.meta")" = "$mate_before" ] \
    || fail "cleanup changed the launched secondmate's record"
  ! grep -Eq "kill-[a-z]* <-t> <[^>]*fm-$PERSISTENT_MATE" "$dir/runtime.log" \
    || fail "cleanup closed the launched secondmate's endpoint: $(cat "$dir/runtime.log")"
  [ "$(persistent_home_fingerprint "$dir")" = "$before" ] \
    || fail "cleanup beside the launched secondmate changed its home"

  # A second secondmate record naming the same home contradicts the proof.
  dir=$(make_persistent_case reconciled-contradicted old-scout-a old-scout-a)
  run_claim_slot "$dir" || fail "claim-slot refused before the contradiction: $(cat "$dir/claim.err")"
  fm_write_meta "$dir/home/state/other-mate.meta" \
    "window=firstmate:fm-other-mate" "endpoint_task_id=other-mate" \
    "kind=secondmate" "home=$dir/worktree" "worktree=$dir/worktree"
  before=$(persistent_home_fingerprint "$dir")
  assert_persistent_teardown_refused "$dir" old-scout-a "$before" "another secondmate record naming the home"
  assert_contains "$(cat "$dir/stderr")" "other-mate" \
    "the contradiction refusal should name the other secondmate record"

  pass "fm-teardown: after a proved claim reconciliation, completed scouts with dead endpoints finish without touching the seeded home"
}

test_persistent_home_reconciliation_refuses_unproved_ownership() {
  local dir before elsewhere

  # Each shape breaks one element of the proof. claim-slot refuses without
  # writing, and the stale scout's cleanup still refuses without touching.
  dir=$(make_persistent_case unproved-lease-holder old-scout-a old-scout-a old-scout-b)
  seed_slot_as_persistent_home "$dir" other-mate
  before=$(persistent_home_fingerprint "$dir")
  assert_claim_slot_refused "$dir" "$before" "mismatched lease holder" "lease"
  assert_persistent_teardown_refused "$dir" old-scout-a "$before" "mismatched lease holder"

  # A claim already naming the secondmate is a different owner, but on a
  # persistent home that alone must not skip the duplicate-record scan the
  # failed proof leaves in force.
  dir=$(make_persistent_case unproved-lease-reconciled-claim "$PERSISTENT_MATE" old-scout-a old-scout-b)
  seed_slot_as_persistent_home "$dir" other-mate
  before=$(persistent_home_fingerprint "$dir")
  assert_persistent_teardown_refused "$dir" old-scout-a "$before" "mismatched lease holder under a secondmate claim"
  assert_contains "$(cat "$dir/stderr")" "is also task old-scout-b's recorded worktree" \
    "mismatched lease holder under a secondmate claim: the duplicate-record refusal should stand"

  dir=$(make_persistent_case unproved-no-lease old-scout-a old-scout-a)
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$(cd "$dir/pool/1/project" && pwd -P)" \
    > "$dir/pool/treehouse-state.json"
  before=$(persistent_home_fingerprint "$dir")
  assert_claim_slot_refused "$dir" "$before" "no durable lease" "lease"
  assert_persistent_teardown_refused "$dir" old-scout-a "$before" "identity marker without a durable lease"

  dir=$(make_persistent_case unproved-pool-state old-scout-a old-scout-a)
  printf 'not json\n' > "$dir/pool/treehouse-state.json"
  before=$(persistent_home_fingerprint "$dir")
  assert_claim_slot_refused "$dir" "$before" "unreadable pool state" "lease"
  assert_persistent_teardown_refused "$dir" old-scout-a "$before" "unreadable pool state"

  dir=$(make_persistent_case unproved-registry old-scout-a old-scout-a old-scout-b)
  elsewhere="$dir/elsewhere-home"
  mkdir -p "$elsewhere/state" "$elsewhere/data"
  seed_slot_as_persistent_home "$dir" "$PERSISTENT_MATE" "$(cd "$elsewhere" && pwd -P)"
  before=$(persistent_home_fingerprint "$dir")
  assert_claim_slot_refused "$dir" "$before" "registry route naming another home" "registered"
  assert_persistent_teardown_refused "$dir" old-scout-a "$before" "registry route naming another home"

  dir=$(make_persistent_case unproved-parent old-scout-a old-scout-a old-scout-b)
  elsewhere="$dir/elsewhere-parent"
  mkdir -p "$elsewhere/state" "$elsewhere/data"
  seed_slot_as_persistent_home "$dir" "$PERSISTENT_MATE" "" "$(cd "$elsewhere" && pwd -P)"
  before=$(persistent_home_fingerprint "$dir")
  assert_claim_slot_refused "$dir" "$before" "parent binding naming another home" "parent"
  assert_persistent_teardown_refused "$dir" old-scout-a "$before" "parent binding naming another home"

  dir=$(make_persistent_case unproved-identity old-scout-a old-scout-a)
  printf 'other-mate\n' > "$dir/pool/1/project/.fm-secondmate-home"
  before=$(persistent_home_fingerprint "$dir")
  assert_claim_slot_refused "$dir" "$before" "identity marker naming another secondmate" "identity"
  assert_persistent_teardown_refused "$dir" old-scout-a "$before" "identity marker naming another secondmate"

  dir=$(make_persistent_case unproved-unsafe-claim old-scout-a old-scout-a)
  rm -f "$dir/pool/1/.fm-slot-owner"
  mkdir "$dir/pool/1/.fm-slot-owner"
  before=$(persistent_home_fingerprint "$dir")
  assert_claim_slot_refused "$dir" "$before" "unsafe claim" "claim"
  [ -d "$dir/pool/1/.fm-slot-owner" ] || fail "unsafe claim: claim-slot replaced a directory claim"
  assert_persistent_teardown_refused "$dir" old-scout-a "$before" "unsafe claim"

  pass "fm-teardown: a mismatched, missing, unreadable, or contradictory persistent-home proof refuses reconciliation and cleanup without mutation"
}

test_persistent_home_cleanup_keeps_completion_and_endpoint_gates() {
  local dir before rc mode

  # Absent report and a failing decision inventory keep refusing: reconciling
  # the home never completes a scout on its behalf.
  dir=$(make_persistent_case gate-report old-scout-a old-scout-a old-scout-b)
  run_claim_slot "$dir" || fail "claim-slot refused: $(cat "$dir/claim.err")"
  rm -f "$dir/home/data/old-scout-a/report.md"
  before=$(persistent_home_fingerprint "$dir")
  assert_persistent_teardown_refused "$dir" old-scout-a "$before" "absent scout report"
  assert_contains "$(cat "$dir/stderr")" "has no report" "absent report: the refusal should name the report"

  dir=$(make_persistent_case gate-decisions old-scout-a old-scout-a old-scout-b)
  run_claim_slot "$dir" || fail "claim-slot refused: $(cat "$dir/claim.err")"
  write_persistent_scout "$dir" old-scout-b fixture-unheld-decision
  before=$(persistent_home_fingerprint "$dir")
  assert_persistent_teardown_refused "$dir" old-scout-b "$before" "failing captain-call inventory"
  assert_contains "$(cat "$dir/stderr")" "captain-call completion gate" \
    "failing inventory: the refusal should name the completion gate"

  # A live or unreadable old endpoint cannot use the reconciled path: the
  # duplicate-record refusal stands until the endpoint is conclusively gone.
  # The scripted tmux reports each window listed in live-windows as running a
  # claude process; the real-backend death evidence is pinned separately by
  # tests/fm-teardown-persistent-slot-herdr-e2e.test.sh.
  dir=$(make_persistent_case gate-endpoint old-scout-a old-scout-a old-scout-b)
  run_claim_slot "$dir" || fail "claim-slot refused: $(cat "$dir/claim.err")"
  printf 'fm-old-scout-a\nfm-unrelated\n' > "$dir/live-windows"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
target=
prev=
for arg in "$@"; do
  [ "$prev" != -t ] || target=$arg
  prev=$arg
done
window=${target##*:}
window=${window#=}
case "${1:-}" in
  list-windows)
    if [ -n "${FM_TEST_UNREADABLE_LIST:-}" ]; then
      echo "lost server" >&2
      exit 1
    fi
    cat "${FM_TEST_LIVE_WINDOWS:?}"
    ;;
  display-message)
    case "$*" in
      *'#{pane_current_command}'*)
        ! grep -Fqx -- "$window" "$FM_TEST_LIVE_WINDOWS" || echo claude
        ;;
    esac
    ;;
  kill-window)
    grep -Fvx -- "$window" "$FM_TEST_LIVE_WINDOWS" > "$FM_TEST_LIVE_WINDOWS.next" || true
    mv "$FM_TEST_LIVE_WINDOWS.next" "$FM_TEST_LIVE_WINDOWS"
    ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  before=$(persistent_home_fingerprint "$dir")
  for mode in live unreadable; do
    : > "$dir/runtime.log"
    rc=0
    if [ "$mode" = unreadable ]; then
      FM_TEST_UNREADABLE_LIST=1 FM_TEST_LIVE_WINDOWS="$dir/live-windows" \
        run_persistent_teardown "$dir" old-scout-a || rc=$?
    else
      FM_TEST_LIVE_WINDOWS="$dir/live-windows" run_persistent_teardown "$dir" old-scout-a || rc=$?
    fi
    [ "$rc" -ne 0 ] || fail "$mode old endpoint: teardown finished on a reconciled home"
    assert_present "$dir/home/state/old-scout-a.meta" "$mode old endpoint: the record was removed"
    [ "$(persistent_home_fingerprint "$dir")" = "$before" ] \
      || fail "$mode old endpoint: the seeded home changed"
    ! grep -Eq 'treehouse|kill-' "$dir/runtime.log" \
      || fail "$mode old endpoint: a pool or close operation ran: $(cat "$dir/runtime.log")"
    grep -Fqx fm-old-scout-a "$dir/live-windows" || fail "$mode old endpoint: the live endpoint was closed"
    assert_contains "$(cat "$dir/stderr")" "is also task old-scout-b's recorded worktree" \
      "$mode old endpoint: the duplicate-record refusal should stand and name the other record"
  done

  # The interrupted cleanup retried once the endpoint is really gone finishes.
  printf 'fm-unrelated\n' > "$dir/live-windows"
  : > "$dir/runtime.log"
  FM_TEST_LIVE_WINDOWS="$dir/live-windows" run_persistent_teardown "$dir" old-scout-a \
    || fail "the retried cleanup after the endpoint died did not finish: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/old-scout-a.meta" "the retried cleanup left the record"
  [ "$(persistent_home_fingerprint "$dir")" = "$before" ] \
    || fail "the retried cleanup changed the seeded home"
  ! grep -Fq 'treehouse' "$dir/runtime.log" \
    || fail "the retried cleanup ran a pool operation: $(cat "$dir/runtime.log")"
  grep -Fqx fm-unrelated "$dir/live-windows" || fail "the retried cleanup closed an unrelated endpoint"

  pass "fm-teardown: reconciliation keeps the report, decision-inventory, and live or unreadable endpoint refusals, and a retry after endpoint death finishes"
}

test_persistent_home_claim_reconciliation_is_idempotent_and_recoverable() {
  local dir home claim prior lock_project lock_registry holder

  dir=$(make_persistent_case claim-idempotent old-scout-a old-scout-a)
  home=$(cd "$dir/home" && pwd -P)
  run_claim_slot "$dir" || fail "first claim-slot refused: $(cat "$dir/claim.err")"
  claim=$(cksum < "$dir/pool/1/.fm-slot-owner")
  prior=$(cksum < "$dir/pool/1/.fm-slot-owner.prior")
  run_claim_slot "$dir" || fail "repeated claim-slot refused: $(cat "$dir/claim.err")"
  assert_contains "$(cat "$dir/claim.out")" "unchanged" "a repeated claim-slot should report the claim unchanged"
  [ "$(cksum < "$dir/pool/1/.fm-slot-owner")" = "$claim" ] || fail "a repeated claim-slot rewrote the claim"
  [ "$(cksum < "$dir/pool/1/.fm-slot-owner.prior")" = "$prior" ] \
    || fail "a repeated claim-slot overwrote the retained prior claim"

  # A claim-slot killed after retaining the prior claim but before publishing
  # the new one: its temp file and both locks are left behind by a dead process.
  dir=$(make_persistent_case claim-interrupted old-scout-a old-scout-a)
  home=$(cd "$dir/home" && pwd -P)
  cp "$dir/pool/1/.fm-slot-owner" "$dir/pool/1/.fm-slot-owner.prior"
  printf 'task=%s\nhome=%s\n' "$PERSISTENT_MATE" "$home" > "$dir/pool/1/.fm-slot-owner.tmp.4242"
  lock_project=$(FM_HOME="$dir/home" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$dir/project") || fail "could not resolve the project lock"
  lock_registry="$dir/home/state/.secondmate-registry.lock"
  # shellcheck disable=SC2016 # Expanded by the inner shells, not this one.
  FM_HOME="$dir/home" bash -c '
    bash -c ". \"\$1\"; fm_lock_try_acquire \"\$2\" && fm_lock_try_acquire \"\$3\" && kill -KILL \"\$BASHPID\"" _ "$@"
    exit 0
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock_project" "$lock_registry" 2>/dev/null
  [ -e "$lock_project" ] && [ -e "$lock_registry" ] || fail "could not stage the abandoned locks"
  holder=$(cat "$lock_project/pid" 2>/dev/null || true)
  ! kill -0 "$holder" 2>/dev/null || fail "the staged lock holder is still alive"
  run_claim_slot "$dir" || fail "claim-slot did not recover an interrupted reconciliation: $(cat "$dir/claim.err")"
  [ "$(cat "$dir/pool/1/.fm-slot-owner")" = "$(printf 'task=%s\nhome=%s' "$PERSISTENT_MATE" "$home")" ] \
    || fail "the recovered claim-slot did not publish the secondmate's claim"
  [ "$(cat "$dir/pool/1/.fm-slot-owner.prior")" = "$(printf 'task=old-scout-a\nhome=%s' "$home")" ] \
    || fail "the recovered claim-slot lost the replaced claim's evidence"
  run_persistent_teardown "$dir" old-scout-a \
    || fail "the stale scout did not finish after a recovered reconciliation: $(cat "$dir/stderr")"
  ! grep -Fq 'treehouse' "$dir/runtime.log" \
    || fail "cleanup after a recovered reconciliation ran a pool operation: $(cat "$dir/runtime.log")"

  pass "fm-home-seed claim-slot: a repeated reconciliation is a no-op and an interrupted one converges without losing prior-claim evidence"
}

test_invalid_endpoint_records_refuse_before_mutation
test_control_lock_contention_refuses_before_mutation
test_non_pool_teardown_ignores_task_set_lock
test_metadata_lock_serializes_destructive_cleanup
test_supported_backend_endpoint_records_validate
test_orca_composite_worktree_id_validates
test_tmux_empty_target_refuses_without_invocation
test_recorded_process_identity_cleanup_is_exact
test_isolated_tmux_invalid_and_valid_cleanup
test_failed_endpoint_close_refuses_before_removing_the_record
test_forced_teardown_continues_past_a_close_it_could_not_make
test_unreadable_close_read_refuses_while_a_definitive_absence_completes
test_forced_secondmate_child_close_failure_still_refuses
test_orca_close_failure_refuses_even_under_force
test_already_gone_endpoint_still_completes_without_a_refusal
test_bare_relative_origin_shares_project_lock_with_clone
test_reused_pool_slot_refuses_before_touching_the_other_task
test_cross_home_pool_slot_collision_refuses
test_sole_slot_record_still_tears_down
test_reassigned_pool_slot_finishes_own_cleanup_without_touching_the_slot
test_stale_record_on_claimed_slot_retires_then_claimant_tears_down
test_own_and_absent_slot_claims_still_tear_down
test_seeded_home_named_by_stale_scout_records_is_never_returned
test_reconciled_seeded_home_lets_completed_dead_scouts_finish
test_persistent_home_reconciliation_refuses_unproved_ownership
test_persistent_home_cleanup_keeps_completion_and_endpoint_gates
test_persistent_home_claim_reconciliation_is_idempotent_and_recoverable
test_recorded_endpoint_that_changed_directory_still_tears_down
test_project_lock_anchors_at_the_local_root_across_home_layouts
test_remote_seeded_home_returns_its_uncontested_slot
test_remote_seeded_home_still_refuses_a_slot_its_child_holds
test_remote_layout_homes_serialize_on_one_project_lock
