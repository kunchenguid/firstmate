#!/usr/bin/env bash
# Pin: fixture path capture must stay pure when git hooks write to stdout,
# without breaking PATH mocks that re-exec the "real" git.
#
# The classic shape is:
#   w=$(new_world name)   # helper runs git commit/push, then prints a path
#   git -C "$w/main" ...  # must see a real path, not hook banners
#
# Any core.hooksPath (or local hook) that prints instruments on commit, push or
# checkout used to glue those lines onto the captured path. tests/lib.sh
# installs a PATH shim that relocates git stdout to stderr by default and keeps
# it only for an allow-list of read-only subcommands; this file proves that
# default (including for clone, which no deny-list of "commit-side" subcommands
# would have covered), proves that the allow-list still returns real stdout,
# proves that turning the relocate off restores the corruption, and proves that
# command -v / PATH-mock re-exec stay safe (a shell-function wrap made
# command -v return "git" and hung teardown).
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
for h in pre-commit pre-push post-checkout; do
  cat > "$HOOKS/$h" <<'SH'
#!/bin/sh
echo "[FAKE-HOOK-INSTRUMENT] fixture-stdout-probe"
exit 0
SH
  chmod +x "$HOOKS/$h"
done

# Build a world the same way the known-bad fixtures do: bare origin, seed
# commit+push, clone, echo the world path. core.hooksPath is set on the seed
# and passed to the final clone with -c, so this fails on every machine, not
# only ones with a global hooksPath - and it covers the checkout side (clone
# runs post-checkout) as well as the commit side.
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
  # The last git before the path is printed: a clone whose post-checkout hook
  # writes instruments. No "hook-bearing subcommand" deny-list caught this one.
  git -c core.hooksPath="$HOOKS" clone -q "$w/origin.git" "$w/main"
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

# --- allow-list: read-only subcommands still hand back real stdout ---------
test_read_only_subcommands_keep_stdout() {
  local w got
  w=$(build_world allowlist)

  got=$(git -C "$w/main" rev-parse HEAD)
  case "$got" in
    ????????????????????????????????????????) ;;
    *) fail "rev-parse must return a bare commit id on stdout, got: $got" ;;
  esac
  got=$(git -C "$w/main" symbolic-ref --short HEAD)
  [ "$got" = main ] || fail "symbolic-ref stdout must survive the wrap, got: $got"
  got=$(git -C "$w/main" log -1 --format=%s)
  [ "$got" = c1 ] || fail "log stdout must survive the wrap, got: $got"
  got=$(git -C "$w/main" ls-files)
  [ "$got" = README.md ] || fail "ls-files stdout must survive the wrap, got: $got"
  got=$(git -C "$w/main" config --get remote.origin.url)
  [ -n "$got" ] || fail "config --get stdout must survive the wrap"
  got=$(git -C "$w/main" remote get-url origin)
  [ -n "$got" ] || fail "remote get-url stdout must survive the wrap"
  got=$(git -C "$w/main" worktree list --porcelain)
  case "$got" in
    worktree*) ;;
    *) fail "worktree list stdout must survive the wrap, got: $got" ;;
  esac
  got=$(git -C "$w/main" for-each-ref --format='%(refname)' refs/heads/)
  [ "$got" = refs/heads/main ] || fail "for-each-ref stdout must survive the wrap, got: $got"
  pass "read-only allow-list subcommands still return stdout to their callers"
}

# --- relocate side: mutating forms cannot reach a capture ------------------
test_mutating_subcommands_relocate_stdout() {
  local w out err
  w=$(build_world relocate-side)
  err="$TMP_ROOT/relocate-side.err"

  # `worktree add` prints "Preparing worktree ..." on stdout and runs
  # post-checkout hooks; the listing form of the same subcommand does not.
  out=$(git -C "$w/main" -c core.hooksPath="$HOOKS" worktree add "$w/wt" -b probe 2>"$err")
  [ -z "$out" ] || fail "worktree add stdout must be relocated, captured: $out"
  [ -s "$err" ] || fail "worktree add chatter must stay visible on stderr"
  grep -q 'FAKE-HOOK-INSTRUMENT' "$err" \
    || fail "post-checkout instrument must land on stderr, not vanish"

  out=$(git -C "$w/seed" commit -q --allow-empty -m c2 2>"$err")
  [ -z "$out" ] || fail "commit stdout must be relocated, captured: $out"
  pass "mutating subcommands relocate stdout while staying visible on stderr"
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

# --- command -v / PATH-mock re-exec must not hang or break toolbins --------
test_command_v_git_is_absolute_and_reexec_safe() {
  local resolved kind fakebin log
  resolved=$(command -v git)
  case "$resolved" in
    /*) ;;
    *) fail "command -v git must be absolute after lib.sh (got: $resolved) - a bare name hangs PATH mocks that re-exec it" ;;
  esac
  [ -x "$resolved" ] || fail "command -v git not executable: $resolved"
  kind=$(type -t git)
  [ "$kind" = file ] || fail "expected PATH shim file git, got type: $kind"
  case "$FM_TEST_REAL_GIT" in
    /*) ;;
    *) fail "FM_TEST_REAL_GIT must be absolute, got: $FM_TEST_REAL_GIT" ;;
  esac
  [ -x "$FM_TEST_REAL_GIT" ] || fail "FM_TEST_REAL_GIT not executable: $FM_TEST_REAL_GIT"
  # The obvious PATH-mock pattern: capture command -v, re-exec under fakebin first.
  # Must terminate (not recurse) and reach the real binary.
  fakebin="$TMP_ROOT/fakebin-reexec"
  log="$TMP_ROOT/reexec.log"
  mkdir -p "$fakebin"
  : > "$log"
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
printf 'mock-hit\n' >> '$log'
exec '$resolved' "\$@"
SH
  chmod +x "$fakebin/git"
  PATH="$fakebin:$PATH" git rev-parse --git-dir >/dev/null \
    || fail "PATH mock re-exec of command -v git failed"
  [ "$(cat "$log")" = mock-hit ] || fail "PATH mock was not entered"
  # Absolute real pin also works (what teardown/fleet-sync/secondmate-sync use).
  "$FM_TEST_REAL_GIT" rev-parse --git-dir >/dev/null \
    || fail "pinned real git binary must still run"
  pass "command -v git is absolute re-exec-safe; FM_TEST_REAL_GIT pins real binary"
}

# --- toolbin ln -s "$(command -v git)" must not be a relative dead link ------
test_toolbin_symlink_to_command_v_git_works() {
  local tb resolved bash_path
  tb="$TMP_ROOT/toolbin"
  mkdir -p "$tb"
  resolved=$(command -v git)
  bash_path=$(type -P bash)
  # Mirror fm-crew-state's make_no_timeout_toolbin: restricted PATH with the
  # tools the shim and the test need, no ambient /usr/bin.
  ln -s "$resolved" "$tb/git"
  ln -s "$bash_path" "$tb/bash"
  PATH="$tb" git rev-parse --git-dir >/dev/null \
    || fail "toolbin symlink to command -v git is dead or non-functional (resolved=$resolved)"
  pass "toolbin ln -s \"\$(command -v git)\" stays usable under restricted PATH"
}

test_default_capture_stays_pure_under_hooks
test_read_only_subcommands_keep_stdout
test_mutating_subcommands_relocate_stdout
test_keep_mode_still_corrupts_capture
test_command_v_git_is_absolute_and_reexec_safe
test_toolbin_symlink_to_command_v_git_works
