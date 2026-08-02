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
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

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
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. The first call installs the cleanup trap. A test file that needs
# extra teardown (e.g. killing a daemon) should define its own EXIT trap and
# call fm_test_cleanup from inside it so registered dirs are still removed.

FM_TEST_CLEANUP_DIRS=()

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$root")
  printf '%s\n' "$root"
}

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

# --- fm-spawn launch-delivery pane shell ------------------------------------
#
# fm-spawn refuses to report a spawn until the target pane proves it executed a
# probe and rebuilt the complete launch command; bin/fm-spawn.sh's header owns
# that launch-delivery contract. Every suite whose fake terminal drives a real
# spawn therefore needs a pane that behaves like a shell.
#
# fm_fake_pane_shell <fakebin> writes <fakebin>/pane-shell.sh, a helper the
# suite's own fake sources to answer exactly that protocol and nothing else; the
# fake stays the owner of every other subcommand:
#
#   . "$(dirname "$0")/pane-shell.sh"
#   case "${1:-}" in
#     capture-pane) fm_fake_pane_capture; exit 0 ;;
#     send-keys) fm_fake_pane_send "$@"; exit 0 ;;
#   esac
#
# One shared owner matters here beyond deduplication: a per-suite copy answers
# the staged-launch check by echoing the marker it parsed out of the submitted
# line, so it reports success even when the staging it was meant to verify is
# corrupt. This helper instead executes the submitted checksum against what the
# pane actually accumulated, so every suite runs the real verification.
#
# fm_fake_pane_send parses tmux's send-keys argv; a fake for another backend
# passes the submitted line straight to fm_fake_pane_line instead, the way a
# herdr fake answers `pane run` and `pane read`.
#
# The emulated screen and staged command live beside the helper, so no suite has
# to plumb state through the environment. A fake that also prints its own pane
# content composes it with fm_fake_pane_capture, keeping its own line offsets. When
# FM_FAKE_LAUNCH_LOG is set, the launch the pane finally evaluates is appended to
# it, which is how a suite asserts on the constructed launch command.
#
# This emulates a healthy pane only. Truncation, wrapping, and retry injection
# belong to tests/fm-spawn-launch-delivery.test.sh, which owns that contract and
# keeps its own purpose-built fake.

fm_fake_pane_shell() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/pane-shell.sh" <<'SH'
# Sourced by a suite's fake terminal. Owner: fm_fake_pane_shell in tests/lib.sh.
FM_FAKE_PANE_STATE="${BASH_SOURCE[0]%/*}/pane-shell-state"
mkdir -p "$FM_FAKE_PANE_STATE"
FM_FAKE_PANE_SCREEN="$FM_FAKE_PANE_STATE/screen"
FM_FAKE_PANE_STAGED="$FM_FAKE_PANE_STATE/staged"

fm_fake_pane_capture() {
  cat "$FM_FAKE_PANE_SCREEN" 2>/dev/null
  return 0
}

# fm_fake_pane_line <text>: run one submitted shell line as the pane would.
fm_fake_pane_line() {
  local text=${1:-} token staged rebuilt result
  staged=$(cat "$FM_FAKE_PANE_STAGED" 2>/dev/null || printf '')
  case "$text" in
    *__FM_SPAWN_READY_*)
      token=$(printf '%s\n' "$text" | sed -n "s/.*'__FM_SPAWN_READY_' '\([^']*\)'.*/\1/p")
      [ -n "$token" ] && printf '__FM_SPAWN_READY_%s\n' "$token" > "$FM_FAKE_PANE_SCREEN"
      ;;
    "FM_SPAWN_LAUNCH=''")
      : > "$FM_FAKE_PANE_STAGED"
      ;;
    FM_SPAWN_LAUNCH=*)
      rebuilt=$(FM_SPAWN_LAUNCH="$staged" bash -c "$text"'; printf %s "$FM_SPAWN_LAUNCH"')
      printf '%s' "$rebuilt" > "$FM_FAKE_PANE_STAGED"
      ;;
    *__FM_SPAWN_LAUNCH_OK_*)
      # Execute the submitted check against the real staged bytes rather than
      # echoing the marker back, so corrupt staging cannot report success.
      result=$(FM_SPAWN_LAUNCH="$staged" bash -c "$text")
      printf '%s\n' "$result" > "$FM_FAKE_PANE_SCREEN"
      ;;
    'eval "$FM_SPAWN_LAUNCH"')
      [ -n "${FM_FAKE_LAUNCH_LOG:-}" ] && printf '%s\n' "$staged" >> "$FM_FAKE_LAUNCH_LOG"
      # The delivery markers scroll away once the launch runs, so a fixture that
      # composes its own pane content is not left reading a stale marker line.
      : > "$FM_FAKE_PANE_SCREEN"
      ;;
  esac
  return 0
}

# fm_fake_pane_send <the fake's full argv>: accept a tmux send-keys call in any
# of the three shapes the backend uses - "-t <target> <text> Enter",
# "-t <target> -l <text>", and "-t <target> <key>".
fm_fake_pane_send() {
  local text
  shift
  [ "${1:-}" = -t ] && shift 2
  if [ "${1:-}" = -l ]; then
    text=${2:-}
  else
    text=${1:-}
  fi
  fm_fake_pane_line "$text"
}
SH
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
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

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
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
