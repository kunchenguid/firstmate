#!/usr/bin/env bash
# Behavior tests for bin/fm-workspace-busy.sh: advisory read-only workspace
# activity check. Hermetic over temp git fixtures; never touches a real home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUSY="$ROOT/bin/fm-workspace-busy.sh"
TMP_ROOT=$(fm_test_tmproot fm-workspace-busy)

# --- fixture helpers --------------------------------------------------------

make_repo() {  # <name> -> prints path
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "test"
  printf 'seed\n' >"$d/README"
  git -C "$d" add README
  git -C "$d" commit -q -m seed
  # Normalize mtimes into the past so a just-created fixture is not "recent"
  # under the default window. touch -t is portable on macOS and GNU.
  touch -t 202001011200 "$d/README" 2>/dev/null || true
  printf '%s' "$d"
}

run_busy() {  # <dir> [extra args...] -> sets RC, OUT, ERR
  local dir=$1
  shift
  OUT=$("$BUSY" "$dir" "$@" 2>"$TMP_ROOT/err") && RC=0 || RC=$?
  ERR=$(cat "$TMP_ROOT/err" 2>/dev/null || true)
}

expect_quiet() {  # <label>
  [ "$RC" -eq 0 ] || fail "$1: expected quiet exit 0, got $RC (out='$OUT' err='$ERR')"
  [ -z "$OUT" ] || fail "$1: expected empty stdout when quiet, got '$OUT'"
}

expect_busy() {  # <label> <substring of reason>
  local label=$1 want=$2
  [ "$RC" -eq 1 ] || fail "$label: expected busy exit 1, got $RC (out='$OUT' err='$ERR')"
  [ -n "$OUT" ] || fail "$label: expected a reason line on stdout"
  case "$OUT" in
    *"$want"*) ;;
    *) fail "$label: expected reason containing '$want', got '$OUT'" ;;
  esac
}

expect_usage() {  # <label>
  [ "$RC" -eq 2 ] || fail "$1: expected usage exit 2, got $RC (out='$OUT' err='$ERR')"
}

# Snapshot the target tree's non-.git paths so we can prove the script wrote nothing.
tree_fingerprint() {  # <dir>
  # List every path under dir except .git, with type and size only (no mtime),
  # so a pure read cannot look like a write.
  (cd "$1" && find . -path './.git' -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
    if [ -f "$p" ]; then
      # size only
      wc -c <"$p" | tr -d ' '
      printf ' F %s\n' "$p"
    elif [ -d "$p" ]; then
      printf 'D %s\n' "$p"
    else
      printf 'O %s\n' "$p"
    fi
  done)
}

# --- usage errors -----------------------------------------------------------

test_missing_path() {
  run_busy "$TMP_ROOT/does-not-exist-$$"
  expect_usage "missing path"
  case "$ERR" in
    *'does not exist'*) ;;
    *) fail "missing path: expected 'does not exist' on stderr, got '$ERR'" ;;
  esac
  pass "missing path exits 2"
}

test_not_a_repo() {
  local d="$TMP_ROOT/not-a-repo"
  mkdir -p "$d"
  printf 'x\n' >"$d/file"
  run_busy "$d"
  expect_usage "not a repo"
  case "$ERR" in
    *'not a git work tree'*) ;;
    *) fail "not a repo: expected work-tree error, got '$ERR'" ;;
  esac
  pass "non-repository exits 2"
}

test_no_args() {
  OUT=$("$BUSY" 2>"$TMP_ROOT/err") && RC=0 || RC=$?
  ERR=$(cat "$TMP_ROOT/err")
  expect_usage "no args"
  pass "missing <dir> exits 2"
}

# --- quiet clean tree -------------------------------------------------------

test_clean_quiet() {
  local d before after
  d=$(make_repo clean-quiet)
  # Age the only file well outside the default window.
  touch -t 202001011200 "$d/README"
  before=$(tree_fingerprint "$d")
  run_busy "$d" --window 60
  expect_quiet "clean quiet"
  after=$(tree_fingerprint "$d")
  [ "$before" = "$after" ] || fail "clean quiet: script mutated the tree"
  pass "clean quiet tree prints nothing and exits 0"
}

# --- uncommitted changes ----------------------------------------------------

test_uncommitted_tracked() {
  local d
  d=$(make_repo dirty-tracked)
  printf 'edited\n' >"$d/README"
  run_busy "$d" --window 60
  expect_busy "dirty tracked" "uncommitted changes"
  pass "uncommitted tracked edit reports busy"
}

test_uncommitted_untracked() {
  local d
  d=$(make_repo dirty-untracked)
  printf 'new\n' >"$d/newfile.txt"
  run_busy "$d" --window 60
  expect_busy "dirty untracked" "uncommitted changes"
  pass "untracked non-ignored file reports busy"
}

# --- recent mtime (clean index, file touched) -------------------------------

test_recent_mtime() {
  local d
  d=$(make_repo recent-mtime)
  # Content-identical rewrite so porcelain stays clean, but mtime is now.
  # git status is clean when content matches HEAD; touch updates mtime only.
  touch "$d/README"
  run_busy "$d" --window 300
  expect_busy "recent mtime" "recent write"
  pass "recent mtime on a clean tree reports busy"
}

test_old_mtime_quiet() {
  local d
  d=$(make_repo old-mtime)
  touch -t 202001011200 "$d/README"
  run_busy "$d" --window 60
  expect_quiet "old mtime"
  pass "aged mtime outside the window is quiet"
}

# --- ignored paths do not false-busy ----------------------------------------

test_ignored_path_not_busy() {
  local d
  d=$(make_repo ignored-path)
  printf 'cache/\n' >"$d/.gitignore"
  git -C "$d" add .gitignore
  git -C "$d" commit -q -m 'ignore cache'
  touch -t 202001011200 "$d/README" "$d/.gitignore"
  mkdir -p "$d/cache"
  # Fresh write under an ignored path must not count.
  printf 'blob\n' >"$d/cache/hot.bin"
  touch "$d/cache/hot.bin"
  run_busy "$d" --window 300
  expect_quiet "ignored recent write"
  pass "ignored path writes do not trigger busy"
}

# --- git operation in progress ----------------------------------------------

# git rev-parse --git-path often returns a relative path; tests must resolve
# it against the fixture root (mirrors abs_git_path in the script).
fixture_git_path() {  # <repo> <name>
  local repo=$1 name=$2 p
  p=$(git -C "$repo" rev-parse --git-path "$name")
  case "$p" in
    /*) printf '%s' "$p" ;;
    *) printf '%s/%s' "$repo" "$p" ;;
  esac
}

test_index_lock_busy() {
  local d lock
  d=$(make_repo index-lock)
  touch -t 202001011200 "$d/README"
  lock=$(fixture_git_path "$d" index.lock)
  # Create a fake lock file (read-only check; we do not hold a real git lock).
  printf 'fake\n' >"$lock"
  run_busy "$d" --window 60
  expect_busy "index.lock" "git operation in progress"
  # Clean up the fixture lock so temp cleanup is tidy.
  rm -f "$lock"
  pass "index.lock reports git operation in progress"
}

test_merge_head_busy() {
  local d path
  d=$(make_repo merge-head)
  touch -t 202001011200 "$d/README"
  path=$(fixture_git_path "$d" MERGE_HEAD)
  # A plausible 40-hex placeholder; content is irrelevant, presence is the signal.
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$path"
  run_busy "$d" --window 60
  expect_busy "MERGE_HEAD" "git operation in progress"
  rm -f "$path"
  pass "MERGE_HEAD reports git operation in progress"
}

test_rebase_head_busy() {
  local d path
  d=$(make_repo rebase-head)
  touch -t 202001011200 "$d/README"
  path=$(fixture_git_path "$d" REBASE_HEAD)
  printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$path"
  run_busy "$d" --window 60
  expect_busy "REBASE_HEAD" "git operation in progress"
  rm -f "$path"
  pass "REBASE_HEAD reports git operation in progress"
}

# --- writes nothing ---------------------------------------------------------

test_writes_nothing() {
  local d before after
  d=$(make_repo no-write)
  touch -t 202001011200 "$d/README"
  before=$(tree_fingerprint "$d")
  # Run every interesting path shape against the same tree.
  run_busy "$d" --window 60
  expect_quiet "writes-nothing quiet"
  printf 'edit\n' >"$d/README"
  run_busy "$d" --window 60
  expect_busy "writes-nothing dirty" "uncommitted changes"
  # Restore clean content and age it so a second quiet run is possible.
  git -C "$d" checkout -q -- README
  touch -t 202001011200 "$d/README"
  after=$(tree_fingerprint "$d")
  # The edit we made for the dirty case is restored; fingerprint should match
  # the pre-check clean tree (README size may match seed).
  before=$(tree_fingerprint "$d")
  run_busy "$d" --window 60 --no-process
  expect_quiet "writes-nothing final"
  after=$(tree_fingerprint "$d")
  [ "$before" = "$after" ] || fail "writes-nothing: tree changed across a quiet check"
  # No lock / state / marker files of our own naming.
  if find "$d" -name '*workspace-busy*' -o -name '*.fm-busy*' 2>/dev/null | grep -q .; then
    fail "writes-nothing: found a workspace-busy marker under the tree"
  fi
  pass "script writes nothing under the target tree"
}

# --- process scan opt-in shape ----------------------------------------------

test_process_flag_accepted() {
  local d
  d=$(make_repo process-flag)
  touch -t 202001011200 "$d/README"
  # --process must not crash; with only this script's pid in the tree scan
  # path (excluded as $$), a clean aged tree stays quiet when no foreign
  # cwd is present.
  run_busy "$d" --window 60 --process
  # Either quiet (no foreign cwd) or busy with a live-process reason if some
  # ambient agent has cwd here (unlikely under TMP_ROOT). Both are valid
  # exit shapes for the flag; only a usage error (2) is wrong.
  [ "$RC" -eq 0 ] || [ "$RC" -eq 1 ] || fail "process flag: unexpected exit $RC err='$ERR'"
  if [ "$RC" -eq 1 ]; then
    case "$OUT" in
      *'live process cwd'*|*'uncommitted'*|*'recent write'*|*'git operation'*) ;;
      *) fail "process flag: unexpected busy reason '$OUT'" ;;
    esac
  fi
  pass "--process is accepted and returns quiet or a concrete busy reason"
}

# --- help -------------------------------------------------------------------

test_help() {
  OUT=$("$BUSY" --help 2>"$TMP_ROOT/err") && RC=0 || RC=$?
  ERR=$(cat "$TMP_ROOT/err")
  [ "$RC" -eq 0 ] || fail "help: expected exit 0, got $RC"
  case "$ERR" in
    *'usage: fm-workspace-busy.sh'*) ;;
    *) fail "help: expected usage on stderr, got '$ERR'" ;;
  esac
  pass "--help prints usage and exits 0"
}

# --- run --------------------------------------------------------------------

test_missing_path
test_not_a_repo
test_no_args
test_clean_quiet
test_uncommitted_tracked
test_uncommitted_untracked
test_recent_mtime
test_old_mtime_quiet
test_ignored_path_not_busy
test_index_lock_busy
test_merge_head_busy
test_rebase_head_busy
test_writes_nothing
test_process_flag_accepted
test_help

echo "# fm-workspace-busy.test.sh: all assertions passed"
