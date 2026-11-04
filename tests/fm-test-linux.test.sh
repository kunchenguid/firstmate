#!/usr/bin/env bash
# Behavior tests for bin/fm-test-linux.sh: it selects the shell tests changed on
# the branch, stops clearly without a container runtime, and (when
# FM_TEST_LINUX_CONTAINER=1 and a container engine is running) goes red on the
# GNU-incompatible `stat -f ... || stat -c ...` fixture form and green on the
# fixed form.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINUX_CHECK="$ROOT/bin/fm-test-linux.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-linux)
assert_present "$LINUX_CHECK" "bin/fm-test-linux.sh is missing"

GIT_IDENT=(-c user.email=t@example.invalid -c user.name=test)

make_repo() {  # <dir>
  mkdir -p "$1/tests"
  git -C "$1" init -q -b main
  printf 'x\n' > "$1/tests/kept.test.sh"
  printf 'x\n' > "$1/tests/gone.test.sh"
  printf 'x\n' > "$1/README.md"
  git -C "$1" add -A
  git -C "$1" "${GIT_IDENT[@]}" commit -q -m base
  git -C "$1" checkout -q -b feature
}

test_selects_changed_tests() {
  local repo="$TMP_ROOT/select" out
  make_repo "$repo"
  printf 'y\n' > "$repo/tests/added.test.sh"
  git -C "$repo" add tests/added.test.sh
  git -C "$repo" "${GIT_IDENT[@]}" commit -q -m add
  printf 'y\n' >> "$repo/tests/kept.test.sh"
  printf 'y\n' > "$repo/tests/untracked.test.sh"
  printf 'y\n' > "$repo/tests/helper.sh"
  printf 'y\n' >> "$repo/README.md"
  rm "$repo/tests/gone.test.sh"
  out=$(cd "$repo" && "$BASH" "$LINUX_CHECK" --base main --list 2>&1) || fail "--list failed: $out"
  assert_equals $'tests/added.test.sh\ntests/kept.test.sh\ntests/untracked.test.sh' "$out" "changed test selection"
  pass "selects committed, modified, and untracked tests only"
}

test_no_changed_tests_is_a_clean_pass() {
  local repo="$TMP_ROOT/none" out rc=0
  make_repo "$repo"
  out=$(cd "$repo" && FM_CONTAINER_RUNTIME=absent-runtime "$BASH" "$LINUX_CHECK" --base main 2>&1) || rc=$?
  assert_equals 0 "$rc" "no changed tests exit status"
  assert_contains "$out" "no changed shell tests" "no-change message"
  pass "no changed tests needs no runtime"
}

test_missing_runtime_stops_clearly() {
  local repo="$TMP_ROOT/runtime" out rc=0
  make_repo "$repo"
  printf 'y\n' > "$repo/tests/new.test.sh"
  out=$(cd "$repo" && FM_CONTAINER_RUNTIME=absent-runtime "$BASH" "$LINUX_CHECK" --base main 2>&1) || rc=$?
  assert_equals 2 "$rc" "missing runtime exit status"
  assert_contains "$out" "no container runtime found" "missing runtime message"
  pass "missing container runtime stops with exit 2"
}

container_ready() {
  local runtime
  [ "${FM_TEST_LINUX_CONTAINER:-}" = 1 ] || return 1
  for runtime in "${FM_CONTAINER_RUNTIME:-}" docker podman; do
    [ -n "$runtime" ] && command -v "$runtime" >/dev/null 2>&1 && "$runtime" info >/dev/null 2>&1 && return 0
  done
  return 1
}

test_gnu_stat_fixture_red_then_green() {
  local repo="$TMP_ROOT/gnu" out rc=0
  if ! container_ready; then
    pass "gnu stat fixture red then green skipped: set FM_TEST_LINUX_CONTAINER=1 with a running container engine"
    return 0
  fi
  make_repo "$repo"
  cat > "$repo/tests/stat-red.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
f=$(mktemp)
mark=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")
case "$mark" in *[!0-9]*) echo "not ok - marker contaminated"; exit 1 ;; esac
FIXTURE
  cat > "$repo/tests/stat-green.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
f=$(mktemp)
if mark=$(stat -c %Y "$f" 2>/dev/null); then :; else mark=$(stat -f %m "$f"); fi
case "$mark" in *[!0-9]*) echo "not ok - marker contaminated"; exit 1 ;; esac
FIXTURE
  out=$(cd "$repo" && "$BASH" "$LINUX_CHECK" --base main tests/stat-red.test.sh 2>&1) || rc=$?
  assert_equals 1 "$rc" "original fixture form must fail on Linux"
  assert_contains "$out" "FAIL tests/stat-red.test.sh" "red fixture reported"
  rc=0
  out=$(cd "$repo" && "$BASH" "$LINUX_CHECK" --base main tests/stat-green.test.sh 2>&1) || rc=$?
  assert_equals 0 "$rc" "fixed fixture form must pass on Linux: $out"
  assert_contains "$out" "PASS tests/stat-green.test.sh" "green fixture reported"
  pass "gnu stat fixture goes red on the original form and green on the fixed form"
}

fm_test_run test_selects_changed_tests test_no_changed_tests_is_a_clean_pass \
  test_missing_runtime_stops_clearly test_gnu_stat_fixture_red_then_green
