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
# behavior-specific fake herdr/treehouse/no-mistakes mocks: those encode terminal
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

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "backend=herdr" \
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
# Write a minimal Herdr CLI double for tests that exercise generic capture/send
# dispatch rather than workspace creation.
fm_test_write_basic_herdr() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
if [ "${#args[@]}" -ge 2 ] && [ "${args[${#args[@]}-2]}" = --session ]; then
  unset 'args[${#args[@]}-1]' 'args[${#args[@]}-1]'
  args=("${args[@]}")
fi
cmd="${args[*]}"
[ -z "${FM_HERDR_CALL_LOG:-}" ] || printf '%s\n' "$cmd" >> "$FM_HERDR_CALL_LOG"
case "$cmd" in
  'status --json')
    printf '{"client":{"version":"0.7.3","protocol":16},"server":{"running":true}}\n'
    ;;
  'api schema')
    printf '{"result":{"methods":[]}}\n'
    ;;
  'workspace list')
    printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n'
    ;;
  workspace\ create\ *)
    printf '{"result":{"workspace":{"workspace_id":"w1"},"tab":{"tab_id":"seed"},"root_pane":{"pane_id":"w1:p0"}}}\n'
    ;;
  tab\ list\ *)
    printf '{"result":{"tabs":[]}}\n'
    ;;
  tab\ create\ *)
    printf '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"w1:p1"}}}\n'
    ;;
  pane\ get\ *)
    pane=${args[2]}
    [ "${FM_FAKE_HERDR_DEAD_PANE:-}" != "$pane" ] || exit 1
    printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' "$pane" "${FM_FAKE_HERDR_CWD:-/tmp}"
    ;;
  pane\ send-text\ *)
    [ -z "${FM_SEND_LOG:-}" ] || printf '%s' "${args[3]:-}" >> "$FM_SEND_LOG"
    [ -z "${FM_FAKE_LAUNCH_LOG:-}" ] || printf '%s\n' "${args[3]:-}" >> "$FM_FAKE_LAUNCH_LOG"
    printf 'send-keys target=%s:%s literal=1 arg=%s\n' "${HERDR_SESSION:-default}" "${args[2]}" "${args[3]:-}" >> "${FM_HERDR_LOG:-/dev/null}"
    ;;
  pane\ send-keys\ *)
    key=${args[3]:-}
    [ "$key" != enter ] || key=Enter
    printf 'send-keys target=%s:%s literal=0 arg=%s\n' "${HERDR_SESSION:-default}" "${args[2]}" "$key" >> "${FM_HERDR_LOG:-/dev/null}"
    ;;
  pane\ run\ *)
    case "${args[3]:-}" in
      'treehouse get'|export\ GOTMPDIR=*) ;;
      *) [ -z "${FM_FAKE_LAUNCH_LOG:-}" ] || printf '%s\n' "${args[3]:-}" >> "$FM_FAKE_LAUNCH_LOG" ;;
    esac
    printf 'run target=%s:%s arg=%s\n' "${HERDR_SESSION:-default}" "${args[2]}" "${args[3]:-}" >> "${FM_HERDR_LOG:-/dev/null}"
    ;;
  pane\ read\ *)
    printf '%b\n' "${FM_FAKE_HERDR_CAPTURE:-│ │}"
    ;;
  agent\ get\ *)
    case "${FM_FAKE_HERDR_AGENT_MODE:-live}" in
      missing)
        printf '{"error":{"code":"agent_not_found"}}\n' >&2
        exit 1
        ;;
      malformed)
        printf 'not-json\n'
        ;;
      *)
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "${FM_FAKE_HERDR_AGENT_STATUS:-working}"
        ;;
    esac
    ;;
  pane\ close\ *)
    printf 'pane close %s\n' "${args[2]}" >> "${FM_HERDR_LOG:-/dev/null}"
    ;;
  *)
    exit 0
    ;;
esac
SH
  chmod +x "$1"
}
