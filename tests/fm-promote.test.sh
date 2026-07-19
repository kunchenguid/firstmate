#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-promote-tests)

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/fm-root/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/fm-root/bin/fm-guard.sh"
  chmod +x "$dir/fm-root/bin/fm-guard.sh"
  printf '%s\n' "$dir"
}

run_promote() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/fm-root" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    "$PROMOTE" "$@"
}

test_invalid_ids_refuse_before_lock_paths() {
  local dir rc escaped
  dir=$(make_case invalid)
  escaped="$dir/outside.meta.lock"
  rc=0
  run_promote "$dir" ../../outside > "$dir/stdout" 2> "$dir/stderr" || rc=$?
  [ "$rc" -eq 2 ] || fail "invalid promote id returned $rc"
  assert_absent "$escaped" "invalid promote id created an escaped lock"
  assert_grep 'invalid promote request' "$dir/stderr" "invalid promote id lacked a usage error"

  rc=0
  run_promote "$dir" safe extra > "$dir/extra.stdout" 2> "$dir/extra.stderr" || rc=$?
  [ "$rc" -eq 2 ] || fail "extra promote argument returned $rc"
  assert_absent "$dir/home/state/safe.meta.lock" "extra promote argument created a lock"
  pass "fm-promote validates argument count and task ids before lock paths"
}

test_valid_promotion_keeps_metadata_lock_scoped() {
  local dir
  dir=$(make_case valid)
  fm_write_meta "$dir/home/state/task.meta" \
    'kind=scout' \
    'mode=no-mistakes' \
    'sentinel=preserved'
  run_promote "$dir" task > "$dir/stdout" 2> "$dir/stderr" \
    || fail "valid promote failed"
  assert_grep 'kind=ship' "$dir/home/state/task.meta" "valid promote did not set ship kind"
  assert_grep 'sentinel=preserved' "$dir/home/state/task.meta" "valid promote lost metadata"
  assert_absent "$dir/home/state/task.meta.lock" "valid promote left its metadata lock"
  pass "fm-promote retains valid promotion behavior"
}

test_invalid_ids_refuse_before_lock_paths
test_valid_promotion_keeps_metadata_lock_scoped
