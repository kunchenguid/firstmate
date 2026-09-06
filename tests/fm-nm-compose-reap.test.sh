#!/usr/bin/env bash
# Behavior tests for the no-mistakes orphan Compose project reaper.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-compose-reap-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/docker.log"
ROOTS="$TMP_ROOT/worktrees"
mkdir -p "$ROOTS/repo/live-run"
ROOTS=$(cd "$ROOTS" && pwd -P)

cat > "$FAKEBIN/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_DOCKER_LOG"
if [ "$1 $2" = 'container ls' ]; then
  case "$*" in
    *com.docker.compose.project=orphan-a*)
      printf 'aaa111\torphan-a\t%s/repo/gone-a\n' "$FM_FAKE_ROOTS"
      printf 'aaa222\torphan-a\t%s/repo/gone-a\n' "$FM_FAKE_ROOTS"
      ;;
    *com.docker.compose.project=orphan-b*)
      printf 'bbb111\torphan-b\t%s/repo/gone-b\n' "$FM_FAKE_ROOTS"
      ;;
    *com.docker.compose.project=raced*)
      printf 'ccc111\traced\t%s/repo/gone-c\n' "$FM_FAKE_ROOTS"
      printf 'ccc222\traced\t%s/repo/live-run\n' "$FM_FAKE_ROOTS"
      ;;
    *)
      printf 'aaa111\torphan-a\t%s/repo/gone-a\n' "$FM_FAKE_ROOTS"
      printf 'aaa222\torphan-a\t%s/repo/gone-a\n' "$FM_FAKE_ROOTS"
      printf 'bbb111\torphan-b\t%s/repo/gone-b\n' "$FM_FAKE_ROOTS"
      printf 'ccc111\traced\t%s/repo/gone-c\n' "$FM_FAKE_ROOTS"
      printf 'ddd111\tlive\t%s/repo/live-run\n' "$FM_FAKE_ROOTS"
      printf 'eee111\tpersonal\t/Users/example/project\n'
      ;;
  esac
  exit 0
fi
if [ "$1 $2" = 'container rm' ]; then
  case " $* " in
    *' bbb111 '*) [ "${FM_FAKE_RM_FAIL_PROJECT:-}" != orphan-b ] || exit 1 ;;
  esac
  exit 0
fi
if [ "$1 $2" = 'network ls' ]; then
  case "$*" in
    *orphan-a*) printf 'abc001\n' ;;
    *orphan-b*) printf 'abc002\n' ;;
  esac
  exit 0
fi
[ "$1 $2" = 'network rm' ] && exit 0
exit 1
SH
chmod +x "$FAKEBIN/docker"

run_reaper() {
  # shellcheck disable=SC2153 # ROOT is provided by tests/lib.sh.
  PATH="$FAKEBIN:$PATH" FM_FAKE_DOCKER_LOG="$LOG" FM_FAKE_ROOTS="$ROOTS" \
    FM_NM_WORKTREE_ROOT="$ROOTS" "$ROOT/bin/fm-nm-compose-reap.sh"
}

test_scoped_cleanup_and_family_count() {
  local out
  : > "$LOG"
  out=$(run_reaper) || fail "orphan cleanup failed: $out"
  assert_contains "$out" 'removed 2 orphaned no-mistakes Compose project(s), 3 container(s), and 2 network(s)' \
    "cleanup did not report the complete two-project family"
  assert_grep 'container rm --force aaa111 aaa222' "$LOG" "first orphan project was not removed by captured IDs"
  assert_grep 'container rm --force bbb111' "$LOG" "second orphan project was not removed by captured IDs"
  assert_no_grep 'container rm.*ccc' "$LOG" "a project that gained a live sibling was touched"
  assert_no_grep 'container rm.*ddd' "$LOG" "a live no-mistakes project was touched"
  assert_no_grep 'container rm.*eee' "$LOG" "an unrelated Compose project was touched"
  pass "orphan cleanup is project-scoped, race-safe, and reports the whole family"
}

test_failure_is_loud() {
  local out rc=0
  : > "$LOG"
  out=$(FM_FAKE_RM_FAIL_PROJECT=orphan-b run_reaper) || rc=$?
  [ "$rc" -ne 0 ] || fail "container cleanup failure returned success"
  assert_contains "$out" 'NO_MISTAKES_DOCKER: project orphan-b was not fully removed because container cleanup failed' \
    "container cleanup failure was silent"
  assert_contains "$out" 'removed 1 orphaned no-mistakes Compose project(s), 2 container(s), and 1 network(s)' \
    "partial successful repair was not quantified"
  pass "partial cleanup failure is loud while successful repair remains quantified"
}

test_bootstrap_runs_cleanup_only_with_mutation_authority() {
  local home="$TMP_ROOT/bootstrap-home"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '%s\n' manual > "$home/config/backlog-backend"
  printf '%s\n' tmux > "$home/config/backend"
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" FM_FAKE_DOCKER_LOG="$LOG" FM_FAKE_ROOTS="$ROOTS" \
    FM_NM_WORKTREE_ROOT="$ROOTS" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null
  assert_no_grep 'container rm' "$LOG" "detect-only bootstrap mutated Docker state"

  : > "$LOG"
  PATH="$FAKEBIN:$PATH" FM_FAKE_DOCKER_LOG="$LOG" FM_FAKE_ROOTS="$ROOTS" \
    FM_NM_WORKTREE_ROOT="$ROOTS" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" >/dev/null
  assert_grep 'container rm --force aaa111 aaa222' "$LOG" \
    "locked local bootstrap did not invoke orphan cleanup"
  pass "bootstrap runs orphan cleanup only on its mutation-authorized local pass"
}

test_scoped_cleanup_and_family_count
test_failure_is_loud
test_bootstrap_runs_cleanup_only_with_mutation_authority
printf 'All fm-nm-compose-reap tests passed.\n'
