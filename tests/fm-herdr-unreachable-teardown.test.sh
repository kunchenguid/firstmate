#!/usr/bin/env bash
# Regression tests for captain-approved cleanup of an unreachable Herdr endpoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-herdr-unreachable)

make_fakebin() {  # <case-dir> <mode>
  local case_dir=$1 mode=$2
  mkdir -p "$case_dir/fakebin"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
[ "${1:-}" = return ] || exit 1
shift
wt=
for arg in "$@"; do
  case "$arg" in --force) ;; *) wt=$arg ;; esac
done
[ -n "$wt" ] || exit 1
git -C "$PWD" worktree remove --force "$wt"
SH
  if [ "$mode" = unreachable ]; then
    cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf 'herdr' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
printf '%s\n' '{"error":{"code":"invalid_endpoint","message":"recorded endpoint is unavailable"}}'
exit 1
SH
  else
    cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf 'herdr' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
closed=${FM_HERDR_CLOSED:?}
case "${1:-} ${2:-}" in
  "session list")
    printf '%s\n' "{\"sessions\":[{\"name\":\"lab\",\"running\":true,\"socket_path\":\"${FM_HERDR_SOCKET:?}\"}]}"
    ;;
  "pane get")
    if [ -f "$closed" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}}}'
    ;;
  "pane close")
    : > "$closed"
    printf '%s\n' '{"result":{"closed":true}}'
    ;;
  "workspace list")
    printf '%s\n' '{"error":{"code":"not_available"}}'
    exit 1
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
SH
  fi
  chmod +x "$case_dir/fakebin/treehouse" "$case_dir/fakebin/herdr"
}

make_case() {  # <name> <herdr-mode>
  local name=$1 mode=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config"
  git init -q "$case_dir/project"
  git -C "$case_dir/project" checkout -q -b main
  printf '%s\n' base > "$case_dir/project/file.txt"
  git -C "$case_dir/project" add file.txt
  git -C "$case_dir/project" commit -q -m base
  git -C "$case_dir/project" worktree add -q -b "fm/$name" "$case_dir/wt" main
  : > "$case_dir/runtime.log"
  : > "$case_dir/herdr.sock"
  make_fakebin "$case_dir" "$mode"
  fm_write_meta "$case_dir/state/$name.meta" \
    "window=lab:w1:p1" "endpoint_task_id=$name" \
    "worktree=$case_dir/wt" "project=$case_dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p1" \
    "kind=ship" "mode=local-only"
  printf '%s\n' "$case_dir"
}

run_teardown() {  # <case-dir> <id> [flag]
  local case_dir=$1 id=$2 flag=${3:-}
  if [ -n "$flag" ]; then
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_RUNTIME_LOG="$case_dir/runtime.log" FM_HERDR_CLOSED="$case_dir/closed" \
    FM_HERDR_SOCKET="$case_dir/herdr.sock" PATH="$case_dir/fakebin:$PATH" \
      "$TEARDOWN" "$id" "$flag"
  else
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_RUNTIME_LOG="$case_dir/runtime.log" FM_HERDR_CLOSED="$case_dir/closed" \
    FM_HERDR_SOCKET="$case_dir/herdr.sock" PATH="$case_dir/fakebin:$PATH" \
      "$TEARDOWN" "$id"
  fi
}

assert_refused_intact() {  # <case-dir> <id> <description> [flag]
  local case_dir=$1 id=$2 description=$3 flag=${4:-} rc
  set +e
  run_teardown "$case_dir" "$id" "$flag" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: teardown unexpectedly succeeded"
  assert_present "$case_dir/state/$id.meta" "$description: task metadata was removed"
  assert_present "$case_dir/wt" "$description: worktree was removed"
  assert_absent "$case_dir/closed" "$description: runtime pane was closed"
  ! grep -F 'treehouse <return>' "$case_dir/runtime.log" >/dev/null \
    || fail "$description: worktree return ran before refusal"
}

test_unreachable_requires_exact_approval() {
  local case_dir id=normal-refusal
  case_dir=$(make_case "$id" unreachable)
  assert_refused_intact "$case_dir" "$id" "unreachable endpoint without discard approval"
  assert_grep "ambiguous structured presence" "$case_dir/err" \
    "normal cleanup did not report the unreachable endpoint"
  pass "unreachable Herdr endpoint remains intact without the exact captain discard flag"
}

test_unreachable_approved_clean_checkout_succeeds() {
  local case_dir id=approved-clean
  case_dir=$(make_case "$id" unreachable)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/4' \
    'pr_head=5644454b8f40dcebf5c75835cdeb98978c4873e5' \
    >> "$case_dir/state/$id.meta"
  run_teardown "$case_dir" "$id" --discard-approved-by-captain \
    > "$case_dir/out" 2> "$case_dir/err" \
    || fail "approved unreachable cleanup failed: $(cat "$case_dir/err")"
  assert_absent "$case_dir/state/$id.meta" "approved cleanup retained task metadata"
  assert_absent "$case_dir/wt" "approved cleanup retained the exact worktree"
  grep -F 'treehouse <return> <--force>' "$case_dir/runtime.log" >/dev/null \
    || fail "approved cleanup did not return the verified worktree"
  pass "exact captain approval removes a clean, uniquely owned worktree when the Herdr endpoint is unreachable"
}

test_unreachable_refuses_identity_mismatches() {
  local case_dir id other

  id='repo-mismatch'
  case_dir=$(make_case "$id" unreachable)
  git init -q "$case_dir/other-project"
  other="$case_dir/other-project"
  perl -0pi -e "s{^project=.*$}{project=$other}m" "$case_dir/state/$id.meta"
  assert_refused_intact "$case_dir" "$id" "repository mismatch" --discard-approved-by-captain

  id='worktree-mismatch'
  case_dir=$(make_case "$id" unreachable)
  git init -q "$case_dir/other-worktree"
  other="$case_dir/other-worktree"
  perl -0pi -e "s{^worktree=.*$}{worktree=$other}m" "$case_dir/state/$id.meta"
  assert_refused_intact "$case_dir" "$id" "worktree mismatch" --discard-approved-by-captain

  id='branch-mismatch'
  case_dir=$(make_case "$id" unreachable)
  git -C "$case_dir/wt" branch -m fm/not-the-task
  assert_refused_intact "$case_dir" "$id" "branch mismatch" --discard-approved-by-captain

  pass "approved unreachable cleanup refuses mismatched repository, worktree, and branch identity"
}

test_unreachable_refuses_ambiguous_or_dirty_checkout() {
  local case_dir id

  id=ambiguous-owner
  case_dir=$(make_case "$id" unreachable)
  fm_write_meta "$case_dir/state/other-task.meta" \
    "window=lab:w9:p9" "endpoint_task_id=other-task" \
    "worktree=$case_dir/wt" "project=$case_dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w9" \
    "herdr_tab_id=w9:t9" "herdr_pane_id=w9:p9"
  assert_refused_intact "$case_dir" "$id" "ambiguous checkout ownership" --discard-approved-by-captain

  id=dirty-checkout
  case_dir=$(make_case "$id" unreachable)
  printf '%s\n' dirty >> "$case_dir/wt/file.txt"
  assert_refused_intact "$case_dir" "$id" "dirty checkout" --discard-approved-by-captain

  pass "approved unreachable cleanup refuses shared and dirty checkouts"
}

test_healthy_endpoint_uses_normal_close_path() {
  local case_dir id=healthy-endpoint
  case_dir=$(make_case "$id" healthy)
  run_teardown "$case_dir" "$id" --discard-approved-by-captain \
    > "$case_dir/out" 2> "$case_dir/err" \
    || fail "healthy endpoint cleanup failed: $(cat "$case_dir/err")"
  assert_present "$case_dir/closed" "healthy endpoint was not closed"
  assert_absent "$case_dir/state/$id.meta" "healthy endpoint cleanup retained metadata"
  assert_absent "$case_dir/wt" "healthy endpoint cleanup retained worktree"
  grep -F 'herdr <pane> <close> <w1:p1>' "$case_dir/runtime.log" >/dev/null \
    || fail "healthy endpoint did not use the normal exact-pane close path"
  pass "healthy Herdr endpoint still uses the normal locked close and confirmation path"
}

test_unreachable_requires_exact_approval
test_unreachable_approved_clean_checkout_succeeds
test_unreachable_refuses_identity_mismatches
test_unreachable_refuses_ambiguous_or_dirty_checkout
test_healthy_endpoint_uses_normal_close_path
