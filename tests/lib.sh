#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not re-point the
# cleanup registry file or reinstall its EXIT trap, both of which are set up
# once below.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and appends it to a registry
# FILE at $TMPDIR/fm-test-cleanup.<pid>; the EXIT trap that reads that file back
# and removes every listed dir is installed unconditionally at source time, in
# the sourcing shell. A test file that needs extra teardown (e.g. killing a
# daemon) should define its own EXIT trap and call fm_test_cleanup from inside
# it so registered dirs are still removed.

# Registration crosses a subshell boundary, so it goes through a FILE, not an
# array. fm_test_tmproot is called as `TMP=$(fm_test_tmproot x)`, and a command
# substitution runs in a subshell: an array appended there, or a trap installed
# there, belongs to the subshell and dies with it. That is not theoretical - it
# was live. The subshell's own EXIT trap fired the moment the function returned
# and deleted the directory it had just created, so callers received a path that
# did not exist, and the parent's array stayed empty so nothing was ever cleaned
# up. 2,308 temp directories had accumulated across the suites before this was
# found. Tests survived only because each one mkdir -p's its own subpaths.
#
# A file appended by the subshell is visible to the parent, and the trap is
# installed here at SOURCE time, which is the parent's shell.
FM_TEST_CLEANUP_REGISTRY="${TMPDIR:-/tmp}/fm-test-cleanup.$$"

fm_test_cleanup() {
  local d
  if [ -f "$FM_TEST_CLEANUP_REGISTRY" ]; then
    while read -r d; do
      [ -n "$d" ] && rm -rf "$d"
    done < "$FM_TEST_CLEANUP_REGISTRY"
    rm -f "$FM_TEST_CLEANUP_REGISTRY"
  fi
  # Cleanup succeeding is not a test result: never let it decide a suite's exit
  # code. The header above tells suites to call this from their own EXIT trap.
  return 0
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_REGISTRY"
  printf '%s\n' "$root"
}

trap fm_test_cleanup EXIT

# --- keeping tests off the captain's live multiplexers ----------------------
#
# herdr is the only surface firstmate spawns onto, so any suite that drives
# fm-spawn/fm-send/fm-peek without faking `herdr` will reach the CAPTAIN'S REAL
# SERVER and create real tabs in his real workspaces. That is not hypothetical:
# it happened twice during this migration, leaving stray `design-home`,
# `spawn-proj` and `alpha` workspaces behind for someone to notice and clean up.
#
# tmux is guarded the SAME WAY, and it is the more dangerous of the two. The
# cutover deliberately keeps the drain paths open, so `tmux kill-window`,
# `send-keys` and `capture-pane` are still live call sites - and a stray
# kill-window does not leave clutter for someone to tidy, it CLOSES a
# pre-cutover crewmate that may be holding unlanded commits. This class of
# accident is proven on this branch: an early cut of gate h3 drove the real tmux
# server and left `firstmate:fm-fallback-t8` behind in the captain's live
# session. That one was a create; a kill would not have been recoverable.
#
# There is no longer an FM_MUX to pin, and there should not be - headless is not
# a flag anyone gets to flip. So the net is a PATH shim instead: a `herdr` and a
# `tmux` that refuse loudly. A suite that fakes either one prepends its own
# fakebin ahead of these and never sees them; a suite that forgot gets an
# obvious, greppable failure rather than silently touching the fleet.
#
# The two opt-outs are SEPARATE because the need is separate: a gate that drives
# the real herdr binary has no business reaching real tmux, and vice versa. A
# live gate sets FM_TEST_ALLOW_LIVE_HERDR=1 and/or FM_TEST_ALLOW_LIVE_TMUX=1
# BEFORE sourcing this file, which is deliberate and visible at the top of those
# files, and scopes itself to a throwaway session or a private socket it created
# - never the fleet's.
#
# THE SHIMS ARE COMMITTED FILES, not temp dirs, because they are static content
# and every temp-dir shape had a defect the files do not: minting one per
# sourcing suite leaked a directory per test FILE forever, and a shared fixed
# path let one worktree's run truncate a shim another run was exec'ing while
# putting a guessable, world-creatable directory on PATH. Repo-owned needs no
# trap, cannot race, and cannot be pre-created by anyone who could not already
# edit the tests. They live one-per-tool so each can be withheld on its own.
if [ "${FM_TEST_ALLOW_LIVE_HERDR:-0}" != 1 ]; then
  FM_TEST_DENY_BIN="$ROOT/tests/denybin/herdr"
  PATH="$FM_TEST_DENY_BIN:$PATH"
  export PATH
fi
if [ "${FM_TEST_ALLOW_LIVE_TMUX:-0}" != 1 ]; then
  FM_TEST_DENY_TMUX_BIN="$ROOT/tests/denybin/tmux"
  PATH="$FM_TEST_DENY_TMUX_BIN:$PATH"
  export PATH
else
  # Opted in, but not unguarded. The opt-in hands a suite the same
  # `tmux kill-window` that closes a live pre-cutover crewmate carrying unlanded
  # commits, and a kill does not come back the way a stray create does. So the
  # real binary is reached through a guard that passes everything through EXCEPT
  # the destructive verbs, which it allows only against the throwaway session
  # the suite declares in FM_TEST_LIVE_TMUX_SESSION. No declaration means the
  # kill is refused, not aimed at whatever session happens to be current.
  PATH="$ROOT/tests/denybin/live-tmux:$PATH"
  export PATH
fi

# --- hermetic against the captain's own session pin -------------------------
#
# fm_herdr_up probes ${HERDR_SESSION:-default} because that is the session every
# herdr verb targets, and FM_HERDR_SESSION exports it. So a captain who runs his
# fleet under a named session - the configuration that pin exists for - would
# otherwise change what every fake-server suite asserts: the probe asks for
# `fleet` while a fake modelling `default` answers, and suites go red for a
# reason that has nothing to do with the behavior under test.
#
# Neutralising it here rather than per file is deliberate. "Remember to unset
# it" is a hope, not a property: one suite remembered and six did not, which is
# exactly how the divergence stayed invisible. A case that WANTS a named session
# sets it per invocation (env VAR=... or a prefix), which still works.
#
# The live gates are excluded on purpose: they drive the real binary, so the
# captain's pin is the session they must actually reach.
if [ "${FM_TEST_ALLOW_LIVE_HERDR:-0}" != 1 ]; then
  unset HERDR_SESSION FM_HERDR_SESSION
fi

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config. Both arguments are
# optional, so callers may invoke it bare.
# shellcheck disable=SC2120  # optional args; bare calls are intentional
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
