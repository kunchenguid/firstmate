#!/usr/bin/env bash
# Regression tests for the legacy Herdr binder's serialization and its refusal
# of a task it does not own. Neither case reaches a live Herdr session, so this
# suite runs everywhere the rest of the unit tests do.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIND="$ROOT/bin/fm-herdr-endpoint-bind.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-endpoint-bind-locking)

make_case() {  # <name>
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/fakebin" \
    "$TMP_ROOT/$dir/worktree" "$TMP_ROOT/$dir/project"
  : > "$TMP_ROOT/$dir/runtime.log"
  cat > "$TMP_ROOT/$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf 'herdr <%s>\n' "$*" >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$TMP_ROOT/$dir/fakebin/herdr"
  printf '%s\n' "$TMP_ROOT/$dir"
}

run_bind() {  # <dir> <id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" \
    "$BIND" "$id"
}

write_herdr_meta() {  # <file> <id> <worktree> <project>
  local file=$1 id=$2 worktree=$3 project=$4
  fm_write_meta "$file" \
    "window=lab:w1:p2" "worktree=$worktree" "project=$project" "kind=scout" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
}

test_non_herdr_task_refuses_before_any_herdr_outcome() {
  local dir id=tmux-task rc before after
  dir=$(make_case non-herdr-bound)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  before=$(cat "$dir/home/state/$id.meta")

  set +e
  run_bind "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] \
    || fail "a valid tmux task should refuse with status 1, got $rc: $(cat "$dir/stderr")"
  assert_contains "$(cat "$dir/stderr")" "uses backend tmux, not Herdr" \
    "the refusal should name the task's real backend"
  [ -z "$(cat "$dir/stdout")" ] \
    || fail "a tmux task reported a Herdr outcome: $(cat "$dir/stdout")"
  after=$(cat "$dir/home/state/$id.meta")
  [ "$before" = "$after" ] || fail "the non-Herdr refusal changed task metadata"

  dir=$(make_case non-herdr-unbound)
  id=tmux-unbound-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  set +e
  run_bind "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] \
    || fail "an unbound tmux task should refuse with status 1, got $rc: $(cat "$dir/stderr")"
  assert_contains "$(cat "$dir/stderr")" "uses backend tmux, not Herdr" \
    "an unbound tmux task should refuse by backend, not by ambiguous metadata"

  pass "fm-herdr-endpoint-bind: a task whose backend is not Herdr refuses truthfully before any Herdr-specific outcome"
}

hold_lock() {  # <lock-path> -> echoes the holder pid
  local lock=$1 holder i=0
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) >/dev/null 2>&1 &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    return 1
  }
  printf '%s\n' "$holder"
}

test_metadata_lock_contention_refuses_before_any_read_or_publish() {
  local dir id=legacy-herdr lock holder rc before after
  dir=$(make_case metadata-lock)
  write_herdr_meta "$dir/home/state/$id.meta" "$id" "$dir/worktree" "$dir/project"
  before=$(cat "$dir/home/state/$id.meta")
  lock="$dir/home/state/.meta-$id.lock"
  holder=$(hold_lock "$lock") || fail "could not stage a held metadata lock"

  set +e
  run_bind "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$rc" -eq 1 ] \
    || fail "the binder should refuse under metadata-lock contention, got $rc: $(cat "$dir/stderr")"
  assert_contains "$(cat "$dir/stderr")" "metadata is being written by another lifecycle action" \
    "the binder should name metadata-lock contention"
  after=$(cat "$dir/home/state/$id.meta")
  [ "$before" = "$after" ] \
    || fail "the contended binder changed task metadata"
  [ ! -s "$dir/runtime.log" ] \
    || fail "the contended binder reached the runtime: $(cat "$dir/runtime.log")"
  assert_present "$lock" "the contended binder removed another action's metadata lock"

  pass "fm-herdr-endpoint-bind: a concurrent metadata writer refuses the binder before it reads or publishes metadata"
}

test_spawn_lock_contention_still_refuses() {
  local dir id=legacy-herdr lock holder rc
  dir=$(make_case spawn-lock)
  write_herdr_meta "$dir/home/state/$id.meta" "$id" "$dir/worktree" "$dir/project"
  lock="$dir/home/state/.spawn-$id.lock"
  holder=$(hold_lock "$lock") || fail "could not stage a held spawn lock"

  set +e
  run_bind "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$rc" -eq 1 ] \
    || fail "the binder should still refuse under spawn-lock contention, got $rc"
  assert_contains "$(cat "$dir/stderr")" "is being spawned or recovered" \
    "the binder should still name spawn-lock contention"
  [ ! -e "$dir/home/state/.meta-$id.lock" ] \
    || fail "the binder left a metadata lock behind after refusing on the spawn lock"

  pass "fm-herdr-endpoint-bind: the spawn lock is still acquired first and still refuses"
}

test_locks_are_released_after_a_refusal() {
  local dir id=legacy-herdr rc
  dir=$(make_case lock-release)
  write_herdr_meta "$dir/home/state/$id.meta" "$id" "$dir/worktree" "$dir/project"
  rm -rf "$dir/worktree"

  set +e
  run_bind "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "a missing worktree should refuse, got $rc: $(cat "$dir/stderr")"
  [ ! -e "$dir/home/state/.meta-$id.lock" ] \
    || fail "the binder held its metadata lock after refusing"
  [ ! -e "$dir/home/state/.spawn-$id.lock" ] \
    || fail "the binder held its spawn lock after refusing"

  pass "fm-herdr-endpoint-bind: both locks are released when the binding is refused"
}

test_non_herdr_task_refuses_before_any_herdr_outcome
test_metadata_lock_contention_refuses_before_any_read_or_publish
test_spawn_lock_contention_still_refuses
test_locks_are_released_after_a_refusal
