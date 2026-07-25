#!/usr/bin/env bash
# Pin: fixture path capture must stay pure when git hooks write to stdout.
#
# The classic shape is:
#   w=$(new_world name)   # helper runs git commit/push, then prints a path
#   git -C "$w/main" ...  # must see a real path, not hook banners
#
# Any core.hooksPath (or local hook) that prints instruments on commit/push
# used to glue those lines onto the captured path. tests/lib.sh wraps git so
# hook-bearing subcommands relocate stdout to stderr by default; this file
# proves that default, and proves that turning the relocate off restores the
# corruption - so the protection cannot be removed without a loud failure.
#
# Do not "fix" a failure here by disabling hooks in fixtures. The scanner's
# instruments are intentional; the capture shape is what must stay safe.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-fixture-git-stdout)

HOOKS="$TMP_ROOT/hooks"
mkdir -p "$HOOKS"
# Minimal instrument hooks: same role as a global leak scanner's [SCAN-SET]
# lines - deliberate stdout, exit 0, not banners to strip.
for h in pre-commit pre-push; do
  cat > "$HOOKS/$h" <<'SH'
#!/bin/sh
echo "[FAKE-HOOK-INSTRUMENT] fixture-stdout-probe"
exit 0
SH
  chmod +x "$HOOKS/$h"
done

# Build a world the same way the known-bad fixtures do: bare origin, seed
# commit+push, clone, echo the world path. core.hooksPath is set on the seed
# so this fails on every machine, not only ones with a global hooksPath.
build_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w"
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  # Local hooksPath only - never touch the machine global config.
  git -C "$w/seed" config core.hooksPath "$HOOKS"
  printf 'seed\n' > "$w/seed/README.md"
  git -C "$w/seed" add README.md
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/main"
  printf '%s\n' "$w"
}

# --- default relocate: obvious capture shape stays pure --------------------
test_default_capture_stays_pure_under_hooks() {
  local w line_count
  w=$(build_world safe-default)

  line_count=$(printf '%s\n' "$w" | wc -l | tr -d ' ')
  [ "$line_count" = 1 ] || fail "default relocate: captured path must be one line, got $line_count:"$'\n'"$w"
  case "$w" in
    *'[FAKE-HOOK-INSTRUMENT]'*)
      fail "default relocate: hook instrument leaked into path capture:"$'\n'"$w"
      ;;
  esac
  [ -d "$w/main" ] || fail "default relocate: expected world dir missing: $w"
  git -C "$w/main" rev-parse HEAD >/dev/null \
    || fail "default relocate: git -C on captured path must work"
  pass "default git wrap keeps path capture pure under hook instruments"
}

# --- keep mode: the classic shape is still broken without the wrap ---------
test_keep_mode_still_corrupts_capture() {
  local w
  # Force the pre-fix stream layout so removing the relocate cannot pass.
  w=$(FM_TEST_GIT_HOOK_STDOUT=keep build_world keep-corrupt)

  case "$w" in
    *'[FAKE-HOOK-INSTRUMENT]'*)
      : # expected corruption
      ;;
    *)
      fail "keep mode: expected hook instrument in capture (probe hooks not firing?):"$'\n'"$w"
      ;;
  esac
  if git -C "$w/main" rev-parse HEAD >/dev/null 2>&1; then
    fail "keep mode: git -C should fail on hook-polluted path, but succeeded"
  fi
  pass "keep mode reintroduces capture corruption (wrapper is load-bearing)"
}

# --- real binary is pinned; production subprocesses stay unwrapped ---------
test_real_git_binary_is_pinned_and_callable() {
  local kind
  # After sourcing lib.sh, `git` is a shell function and FM_TEST_REAL_GIT is the
  # absolute binary. PATH mocks that re-exec "the real git" must use that pin
  # (command -v git only returns the function name). Production bin/* scripts
  # run as separate processes and always get the real binary from PATH.
  kind=$(type -t git)
  [ "$kind" = function ] || fail "expected shell function git after sourcing lib.sh, got: $kind"
  case "$FM_TEST_REAL_GIT" in
    /*) ;;
    *) fail "FM_TEST_REAL_GIT must be absolute, got: $FM_TEST_REAL_GIT" ;;
  esac
  [ -x "$FM_TEST_REAL_GIT" ] || fail "FM_TEST_REAL_GIT not executable: $FM_TEST_REAL_GIT"
  "$FM_TEST_REAL_GIT" rev-parse --git-dir >/dev/null \
    || fail "pinned real git binary must still run"
  pass "wrapper pins real git; PATH mocks and production subprocesses stay safe"
}

test_default_capture_stays_pure_under_hooks
test_keep_mode_still_corrupts_capture
test_real_git_binary_is_pinned_and_callable
