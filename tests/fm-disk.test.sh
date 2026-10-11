#!/usr/bin/env bash
# tests/fm-disk.test.sh - bin/fm-disk.sh's free-space floor and its reclaim of
# rebuildable ignored build output, driven through the script itself with a
# fake df for the floor and a real git repository for reclaim.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

DISK="$ROOT/bin/fm-disk.sh"
TMP_ROOT=$(fm_test_tmproot fm-disk-tests)

# A fake df reporting FM_FAKE_DF_AVAIL_KIB available, or garbage when unset.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake 100000000 1 %s 1%% /\n' "${FM_FAKE_DF_AVAIL_KIB:-unknown}"
SH
chmod +x "$FAKEBIN/df"

run_disk() {  # <config-dir> <args...>
  local config=$1
  shift
  FM_CONFIG_OVERRIDE="$config" PATH="$FAKEBIN:$PATH" bash "$DISK" "$@"
}

test_check_floor() {
  local config="$TMP_ROOT/check-config" rc err
  mkdir -p "$config"

  FM_FAKE_DF_AVAIL_KIB=$((6 * 1048576)) run_disk "$config" check "$TMP_ROOT" 2>/dev/null
  expect_code 0 $? "check: 6 GiB free passes the default 5 GiB floor"

  err=$(FM_FAKE_DF_AVAIL_KIB=$((4 * 1048576)) run_disk "$config" check "$TMP_ROOT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "check: 4 GiB free is under the default 5 GiB floor"
  case "$err" in
    *"4.0 GiB free"*"under the 5 GiB floor"*) ;;
    *) fail "check: refusal does not name the free space and the floor: $err" ;;
  esac

  printf '0\n' > "$config/min-free-disk-gib"
  FM_FAKE_DF_AVAIL_KIB=1 run_disk "$config" check "$TMP_ROOT" 2>/dev/null
  expect_code 0 $? "check: a floor of 0 disables the check"

  printf '2\n' > "$config/min-free-disk-gib"
  FM_FAKE_DF_AVAIL_KIB=$((3 * 1048576)) run_disk "$config" check "$TMP_ROOT" 2>/dev/null
  expect_code 0 $? "check: a configured floor replaces the default"

  printf '0\n10\n' > "$config/min-free-disk-gib"
  FM_FAKE_DF_AVAIL_KIB=1 run_disk "$config" check "$TMP_ROOT" 2>/dev/null
  expect_code 2 $? "check: a floor file with two values refuses rather than reading the first"

  printf 'lots\n' > "$config/min-free-disk-gib"
  FM_FAKE_DF_AVAIL_KIB=$((100 * 1048576)) run_disk "$config" check "$TMP_ROOT" 2>/dev/null
  expect_code 2 $? "check: a malformed floor refuses rather than guessing"

  rm -f "$config/min-free-disk-gib"
  err=$(run_disk "$config" check "$TMP_ROOT" 2>&1)
  rc=$?
  expect_code 0 "$rc" "check: an unreadable free figure does not refuse"
  case "$err" in
    *warning*) ;;
    *) fail "check: an unreadable free figure was skipped silently" ;;
  esac
  pass "check enforces the configured free-space floor and refuses a malformed one"
}

test_reclaim() {
  local repo="$TMP_ROOT/repo" config="$TMP_ROOT/reclaim-config" err
  mkdir -p "$config"
  git init -q "$repo"
  printf '%s\n' node_modules/ .next .venv > "$repo/.gitignore"
  mkdir -p "$repo/web/node_modules/dep" "$repo/web/.next/cache" "$repo/tracked/node_modules" \
    "$repo/.venv" "$repo/plain/.turbo" "$repo/real-deps" "$repo/nested/node_modules/linked-pkg" \
    "$repo/gitfile/.next"
  printf 'x\n' > "$repo/web/node_modules/dep/index.js"
  printf 'x\n' > "$repo/web/.next/cache/blob"
  printf 'vendored\n' > "$repo/tracked/node_modules/vendored.js"
  printf 'x\n' > "$repo/.venv/keep"
  printf 'x\n' > "$repo/plain/.turbo/keep"
  printf 'x\n' > "$repo/real-deps/keep"
  git init -q "$repo/nested/node_modules/linked-pkg"
  printf 'x\n' > "$repo/nested/node_modules/linked-pkg/src.js"
  git -C "$repo/nested/node_modules/linked-pkg" add src.js
  git -C "$repo/nested/node_modules/linked-pkg" commit -qm nested
  printf 'gitdir: /elsewhere\n' > "$repo/gitfile/.next/.git"
  mkdir -p "$repo/locked/node_modules/sealed"
  printf 'x\n' > "$repo/locked/node_modules/keep.js"
  printf 'x\n' > "$repo/locked/node_modules/sealed/hidden.js"
  chmod 000 "$repo/locked/node_modules/sealed"
  ln -s "$repo/real-deps" "$repo/web/linked_node_modules"
  ln -s "$repo/real-deps" "$repo/node_modules"
  git -C "$repo" add .gitignore plain/.turbo/keep real-deps/keep
  git -C "$repo" add -f tracked/node_modules/vendored.js
  git -C "$repo" commit -qm init

  err=$(run_disk "$config" reclaim "$repo" 2>&1)
  expect_code 0 $? "reclaim: exits 0"
  [ ! -e "$repo/web/node_modules" ] || fail "reclaim: kept an ignored node_modules"
  [ ! -e "$repo/web/.next" ] || fail "reclaim: kept an ignored .next"
  [ -e "$repo/tracked/node_modules/vendored.js" ] || fail "reclaim: deleted a directory holding a tracked file"
  [ -e "$repo/plain/.turbo/keep" ] || fail "reclaim: deleted a listed directory git does not ignore"
  [ -e "$repo/.venv/keep" ] || fail "reclaim: deleted an ignored directory that is not listed"
  [ -e "$repo/nested/node_modules/linked-pkg/src.js" ] \
    || fail "reclaim: deleted a directory holding a nested repository"
  [ -e "$repo/gitfile/.next/.git" ] || fail "reclaim: deleted a directory holding a .git file"
  chmod 755 "$repo/locked/node_modules/sealed"
  [ -e "$repo/locked/node_modules/keep.js" ] && [ -e "$repo/locked/node_modules/sealed/hidden.js" ] \
    || fail "reclaim: deleted a directory whose nested-repository search failed"
  [ -L "$repo/node_modules" ] && [ -e "$repo/real-deps/keep" ] \
    || fail "reclaim: followed or removed a symlink"
  case "$err" in
    *"(2 directories)"*) ;;
    *) fail "reclaim: did not report the two reclaimed directories: $err" ;;
  esac

  mkdir -p "$repo/web/.next" "$repo/web/node_modules"
  printf '# only .next\n.next\n' > "$config/reclaim-build-output"
  run_disk "$config" reclaim "$repo" 2>/dev/null
  [ ! -e "$repo/web/.next" ] && [ -d "$repo/web/node_modules" ] \
    || fail "reclaim: a configured list did not replace the default"

  : > "$config/reclaim-build-output"
  run_disk "$config" reclaim "$repo" 2>/dev/null
  [ -d "$repo/web/node_modules" ] || fail "reclaim: an empty list did not disable reclaim"

  printf '../escape\n' > "$config/reclaim-build-output"
  run_disk "$config" reclaim "$repo" 2>/dev/null
  expect_code 2 $? "reclaim: a name with a slash refuses"

  rm -f "$config/reclaim-build-output"
  mkdir -p "$TMP_ROOT/not-a-repo/node_modules"
  run_disk "$config" reclaim "$TMP_ROOT/not-a-repo" 2>/dev/null
  expect_code 0 $? "reclaim: a non-repository directory is skipped, not refused"
  [ -d "$TMP_ROOT/not-a-repo/node_modules" ] || fail "reclaim: deleted from a directory git cannot vouch for"
  pass "reclaim deletes only listed, ignored, untracked build output directories with no nested repository, and keeps one it cannot search"
}

test_check_floor
test_reclaim
