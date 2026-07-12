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
# on EXIT. A test file that needs extra teardown (e.g. killing a daemon) should
# define its own EXIT trap and call fm_test_cleanup from inside it so registered
# dirs are still removed.
#
# Callers use it as TMP_ROOT=$(fm_test_tmproot ...), so the registration happens
# in a command-substitution subshell: an in-memory array would be discarded with
# that subshell, and a trap installed there would fire on subshell exit and wipe
# the dir the caller just asked for. So registrations go to a file, and the EXIT
# trap is installed here, at source time, in the sourcing shell - bash resets
# caught traps in subshells, so it fires exactly once, when the test process
# exits.

FM_TEST_CLEANUP_DIRS=()
FM_TEST_CLEANUP_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/fm-test-cleanup.XXXXXX")

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  if [ -f "$FM_TEST_CLEANUP_REGISTRY" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && rm -rf "$d"
    done < "$FM_TEST_CLEANUP_REGISTRY"
    rm -f "$FM_TEST_CLEANUP_REGISTRY"
  fi
}

trap fm_test_cleanup EXIT

# fm_test_register_cleanup <dir>: record <dir> for removal on EXIT. Safe to call
# from a subshell: the record is appended to the registry file the sourcing
# shell's trap reads.
fm_test_register_cleanup() {
  printf '%s\n' "$1" >> "$FM_TEST_CLEANUP_REGISTRY"
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  fm_test_register_cleanup "$root"
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

# --- hermetic base PATH -----------------------------------------------------
#
# Why this exists (task fmsend-verify-l2): the suites that exercise firstmate's
# missing-tool detection build a fakebin that deliberately OMITS a tool, then
# assert bootstrap prints "MISSING: <tool>". They prepended that fakebin to the
# REAL system dirs, so an omitted tool that happened to exist on the developer's
# machine silently satisfied the probe and the assertion failed. Two collisions
# were real and are the reason this helper exists: /usr/bin/orca is the GNOME
# screen reader (unrelated to firstmate's Orca backend - it merely shares the
# name) and /usr/bin/node is an ordinary Node install. `/bin` is a usrmerge
# symlink to `/usr/bin`, so no reordering of the real dirs could dodge either.
# CI stayed green only because its runners happen to lack both, which made this
# a local-only failure that blocked the gate for any developer who had them.
#
# fm_test_base_path builds a sanitized bin dir mirroring the real base dirs'
# executables EXCEPT the tools these suites control through their own fakebin,
# and sets FM_TEST_BASE_PATH_DIR to it. It writes that variable instead of
# echoing a path so the caller invokes it directly (NOT in a command
# substitution): a subshell would discard the cache, rebuilding the mirror's
# ~2000 symlinks on every call. The ambient machine therefore can never satisfy a
# firstmate tool probe, so a case that omits a tool genuinely runs without it and
# the assertion tests what it was written to test. Everything else - git, jq, and
# the coreutils the scripts really call - is mirrored through untouched, because
# the suites need real ones. The dir is built once per test process and cached.
#
# FM_TEST_BASE_PATH still overrides the whole thing, unchanged.

# The tools these suites control via fakebin are DERIVED from bootstrap's own
# TOOLS lists (every backend branch) rather than duplicated here, so a newly
# required tool cannot silently reintroduce the ambient-toolchain false-pass.
# FM_TEST_TOOL_EXTRA covers the backend binaries other scripts probe for outside
# bootstrap's lists. `git` is deliberately exempt: the suites need a real git, and
# their missing-git case shadows it with a shell function instead of relying on
# PATH.
#
# The derivation only understands literal `TOOLS="a b c"` assignments. It is
# validated before use against FM_TEST_TOOL_REQUIRED - the names the missing-tool
# suites actually shadow through their own fakebin - and a derivation that cannot
# be trusted FAILS the suite loudly rather than falling back to a partial
# blocklist, because a partial blocklist means a green suite that tests nothing.
FM_TEST_TOOL_EXEMPT="git"
FM_TEST_TOOL_EXTRA="herdr zellij cmux"
FM_TEST_TOOL_REQUIRED="tmux node gh treehouse no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi orca"
FM_TEST_TOOL_BLOCKLIST=""
FM_TEST_BASE_PATH_DIR=""

fm_test_tool_blocklist() {
  local declared name missing=""
  [ -z "$FM_TEST_TOOL_BLOCKLIST" ] || return 0
  declared=$(grep -o 'TOOLS="[^"]*"' "$ROOT/bin/fm-bootstrap.sh" | sed -e 's/^TOOLS="//' -e 's/"$//')
  [ -n "$declared" ] || fail "tests/lib.sh: could not derive the tool list from bin/fm-bootstrap.sh; its TOOLS shape changed and fm_test_tool_blocklist must be updated"
  case "$declared" in
    *'$'* | *'`'*)
      fail "tests/lib.sh: bin/fm-bootstrap.sh's TOOLS list is no longer a literal name list (it contains a substitution); fm_test_tool_blocklist must be updated or the missing-tool suites will be satisfied by the ambient toolchain"
      ;;
  esac
  for name in $declared $FM_TEST_TOOL_EXTRA; do
    case " $FM_TEST_TOOL_EXEMPT " in *" $name "*) continue ;; esac
    case " $FM_TEST_TOOL_BLOCKLIST " in *" $name "*) continue ;; esac
    FM_TEST_TOOL_BLOCKLIST="$FM_TEST_TOOL_BLOCKLIST $name"
  done
  FM_TEST_TOOL_BLOCKLIST=${FM_TEST_TOOL_BLOCKLIST# }
  for name in $FM_TEST_TOOL_REQUIRED; do
    case " $FM_TEST_TOOL_BLOCKLIST " in
      *" $name "*) ;;
      *) missing="$missing $name" ;;
    esac
  done
  if [ -n "$missing" ]; then
    FM_TEST_TOOL_BLOCKLIST=""
    fail "tests/lib.sh: tool blocklist derived from bin/fm-bootstrap.sh is missing:$missing - its TOOLS shape changed and fm_test_tool_blocklist must be updated; refusing to run the missing-tool suites against a partial blocklist"
  fi
}

fm_test_base_path() {
  local root dir src entry name
  if [ -n "$FM_TEST_BASE_PATH_DIR" ] && [ -d "$FM_TEST_BASE_PATH_DIR" ]; then
    return 0
  fi
  fm_test_tool_blocklist
  root=$(fm_test_tmproot fm-base-path)
  dir="$root/bin"
  mkdir -p "$dir"
  for src in /usr/bin /bin /usr/sbin /sbin; do
    [ -d "$src" ] || continue
    for entry in "$src"/*; do
      [ -f "$entry" ] && [ -x "$entry" ] || continue
      name=${entry##*/}
      case " $FM_TEST_TOOL_BLOCKLIST " in
        *" $name "*) continue ;;
      esac
      # First dir wins, mirroring real PATH precedence (and /bin == /usr/bin
      # under usrmerge, so this also dedupes the symlinked duplicates).
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name"
    done
  done
  FM_TEST_BASE_PATH_DIR=$dir
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
