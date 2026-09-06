#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, root-safe
# unwritable/unreadable-path simulation (fm_run_dir_readonly and friends), and
# the common string/exit-code/file assertions. Shared fake-toolchain and
# spawn-world builders live in tests/fixtures.sh; wake-queue mocks in
# wake-helpers.sh; secondmate-lifecycle mocks in secondmate-helpers.sh.
# Suite-specific fakes that encode a single test's terminal or lifecycle
# assumptions still belong with the tests that own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh, fixtures.sh) source this library for ROOT/fail/pass, and the
# test that includes them may also source it directly. Re-sourcing must not wipe
# the registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Pin the fixture umask. Firstmate's state-root and process-event contracts
# refuse group- or world-writable state directories, and a permissive ambient
# umask (e.g. 0002) makes every `mkdir state` fixture fail that contract before
# the behavior under test can even run. 022 is the conventional default this
# suite's fixtures were written against.
umask 022

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
# on EXIT/INT/TERM. A test file that needs extra teardown (e.g. killing a
# daemon) should define its own EXIT trap and call fm_test_cleanup from inside
# it so registered dirs are still removed.
#
# The call site is almost always `TMP_ROOT=$(fm_test_tmproot prefix)`, which
# forks a subshell to capture stdout. Anything that function does to the
# current shell's state - an array append, a trap - dies with that subshell
# and never reaches the real caller, so registration cannot go through
# in-process state. `$$` is the one thing bash keeps stable across that
# boundary (it always resolves to the invoking shell's PID, not the
# subshell's - see `man bash` on `$$`), so fm_test_tmproot records the
# directory in a `$$`-keyed registry file instead, and the trap that reaps
# that file is armed once, here, at source time - which always runs in the
# real caller, never a subshell.

FM_TEST_CLEANUP_DIRS=()
FM_TEST_CLEANUP_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-test-cleanup.$$.XXXXXX") || return 1

# Directories currently write-blocked via fm_dir_block_writes, so
# fm_test_cleanup can unblock them if a signal cuts a test off before its
# matching fm_dir_unblock_writes runs. Lives in-process (not the registry
# file $$-keyed subshells need): every caller of fm_dir_block_writes runs
# directly in the test process, never in a captured subshell.
FM_TEST_BLOCKED_DIRS=()

fm_test_pid_identity() {
  local pid=$1
  FM_STATE_OVERRIDE="${TMPDIR:-/tmp}" bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid"
}

FM_TEST_OWNER_IDENTITY=$(fm_test_pid_identity "$$") || {
  rm -f "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

fm_test_cleanup() {
  local d
  # Restore write access to any directory a test left blocked via
  # fm_dir_block_writes before removing it below: a signal landing between
  # fm_dir_block_writes and its matching fm_dir_unblock_writes would otherwise
  # reach this trap while the directory is still unwritable, and a non-root
  # `rm -rf` cannot unlink entries from a write-blocked directory.
  for d in "${FM_TEST_BLOCKED_DIRS[@]:-}"; do
    [ -n "$d" ] && chmod u+w "$d" 2>/dev/null
  done
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

fm_test_tmproot() {
  local prefix=${1:-fm-test} root tmp_base
  tmp_base=${TMPDIR:-/tmp}
  tmp_base=${tmp_base%/}
  root=$(mktemp -d "$tmp_base/${prefix}.XXXXXX") || return 1
  root=$(cd -P -- "$root" && pwd -P) || return 1
  if ! printf '%s\n%s\n' "$$" "$FM_TEST_OWNER_IDENTITY" > "$root/.fm-test-fixture" ||
    ! printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_REGISTRY"; then
    rm -rf "$root"
    return 1
  fi
  printf '%s\n' "$root"
}

trap fm_test_cleanup EXIT
trap 'fm_test_cleanup; exit 130' INT
trap 'fm_test_cleanup; exit 143' TERM

# fm_test_reap_orphans: best-effort sweep for fixture roots left behind by a
# prior run that was killed hard enough to skip the traps above (e.g. a
# SIGKILL timeout). Only removes directories carrying the .fm-test-fixture
# marker fm_test_tmproot writes, so it never touches unrelated fm-* tmp dirs
# from real (non-test) firstmate commands. The marker identifies the owning
# shell across PID reuse, so the same live owner always wins over the age
# fallback for dead or unowned roots.
FM_TEST_ORPHAN_MAX_AGE_SECONDS=${FM_TEST_ORPHAN_MAX_AGE_SECONDS:-3600}

fm_test_reap_orphans() {
  local marker dir mtime now owner_pid owner_identity current_identity
  now=$(date +%s)
  for marker in "${TMPDIR:-/tmp}"/fm-*/.fm-test-fixture; do
    [ -e "$marker" ] || continue
    owner_pid=$(sed -n '1p' "$marker" 2>/dev/null) || owner_pid=
    owner_identity=$(sed -n '2,$p' "$marker" 2>/dev/null) || owner_identity=
    case "$owner_pid" in
      '' | *[!0-9]*) ;;
      *)
        current_identity=$(fm_test_pid_identity "$owner_pid" 2>/dev/null) || current_identity=
        if [ -n "$owner_identity" ] && [ "$current_identity" = "$owner_identity" ]; then
          continue
        fi
        ;;
    esac
    mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || continue
    [ $((now - mtime)) -ge "$FM_TEST_ORPHAN_MAX_AGE_SECONDS" ] || continue
    dir=$(dirname "$marker")
    if [ -d "$dir" ] && [ ! -L "$dir" ]; then
      find "$dir" -type d -exec chmod u+rwx {} + 2>/dev/null || true
    fi
    rm -rf "$dir"
  done
}

# A parent coordinator can reap once before it starts isolated child sections.
# Those children use their own EXIT cleanup and must not spend their bounded
# execution window repeating the same global stale-fixture scan.
if [ "${FM_TEST_SKIP_ORPHAN_REAP:-0}" != 1 ]; then
  fm_test_reap_orphans
fi

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir. fm_fake_crash_injector drops the shim a fake
# uses to crash the process under test deterministically. fm_fake_version_tool
# drops a stub for a tool whose installed version bootstrap gates, so a fixture
# cannot be reported as an unparseable build simply for answering `--version`
# with nothing.

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

# fm_fake_crash_injector <fakebin>
# Drops an `fm-crash-inject <pid>` shim that a PATH fake calls to simulate a
# hard crash of the process under test. It SIGKILLs <pid> and then returns only
# once that process is observably gone, so the fake never resumes work while its
# victim could still be running. Sleeping a fixed interval instead makes the
# injection a wall-clock bet that a loaded host loses: the fake wakes up and
# completes the very operation the case needs left unfinished. Exits non-zero
# with a diagnostic if the target outlives the signal, so a broken injection
# fails loudly rather than silently changing what the case measures.
fm_fake_crash_injector() {
  local fakebin=$1
  cat > "$fakebin/fm-crash-inject" <<'SH'
#!/usr/bin/env bash
set -u
target=${1:?fm-crash-inject: <pid> required}
case "$target" in
  ''|*[!0-9]*)
    echo "fm-crash-inject: '$target' is not a pid" >&2
    exit 1
    ;;
esac
kill -KILL "$target" 2>/dev/null || true
waited=0
while [ "$waited" -lt 600 ]; do
  case "$(ps -o state= -p "$target" 2>/dev/null | tr -d '[:space:]')" in
    ''|Z*) exit 0 ;;
  esac
  waited=$((waited + 1))
  sleep 0.05
done
echo "fm-crash-inject: pid $target still running 30s after SIGKILL" >&2
exit 1
SH
  chmod +x "$fakebin/fm-crash-inject"
}

# fm_fake_version_tool <fakebin> <tool> <override-env-var> <default-version>
# The stub answers `--version` with <override-env-var> when that variable is set
# and non-empty, and with <default-version> otherwise; every other invocation
# exits 0. A case that needs to drive a version floor exports the variable.
fm_fake_version_tool() {
  local fakebin=$1 tool=$2 override=$3 default=$4
  cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' "\${$override:-$default}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

# --- unwritable/unreadable-path simulation -----------------------------------
#
# chmod alone (the obvious way to simulate "this path cannot be written or
# read") only blocks a non-root caller: a root process holding
# CAP_DAC_OVERRIDE and/or CAP_DAC_READ_SEARCH - the default for a container's
# root user, and how a CI runner running this suite as root does - walks
# straight past permission bits and the simulated failure never happens, so
# the behavior it was meant to exercise silently goes untested.
#
# A read-only bind mount (this suite's first attempt at a fix) is enforced by
# the kernel regardless of DAC checks, but building one needs a mount
# namespace with CAP_SYS_ADMIN inside it, normally obtained via
# `unshare -rm` (a fresh user+mount namespace maps the caller to root inside
# it, which grants CAP_SYS_ADMIN there even when the real process lacks it).
# That in turn needs the kernel to allow creating unprivileged user
# namespaces at all, which some hosts disable - and it silently disabled
# itself right where it was needed most: CI's self-hosted runner refuses
# `unshare -rm` too, so every caller fell back to running fully unprotected
# and the assertions it was meant to gate on started failing outright instead
# of catching a real regression.
#
# Dropping CAP_DAC_OVERRIDE itself needs no namespace: CAP_SETPCAP (also
# ordinary for a container's root user) lets setpriv shrink the capability
# bounding set for one exec'd command, so <command...> ends up subject to
# plain file-mode checks like anyone else, while the calling shell (and
# every path <command...> is not meant to touch) keeps root's normal access -
# no uid change, so no separate traversal/ownership setup for the rest of the
# fixture tree. fm_run_without_dac_override is the primitive; the two
# wrappers below add the chmod and, for the directory form, an empirical
# proof the drop actually holds before trusting it with the real command,
# because assuming a namespace or capability trick works is exactly the
# mistake this whole rewrite exists to correct.

# fm_run_without_dac_override <command...>: run <command...> normally when
# not root (plain DAC checks already apply). As root, run it with both
# CAP_DAC_OVERRIDE and CAP_DAC_READ_SEARCH removed from the capability
# bounding set, so any file mode bits <command...> encounters (including ones
# it sets up itself, like a fake tool chmod'ing a path mid-run) are enforced
# against it instead of bypassed. Both capabilities independently let a
# process bypass a file's read permission bits, so a read-denial fixture
# (e.g. chmod 000) that dropped only CAP_DAC_OVERRIDE would still be read via
# CAP_DAC_READ_SEARCH alone - dropping just one leaves the other capability
# free to defeat the simulated failure.
# <command...> is looked up as a shell function first (via the exported
# BASH_FUNC_ mechanism), then as an external command, exactly as bash
# ordinarily resolves a simple command.
fm_run_without_dac_override() {
  if [ "$(id -u)" != 0 ]; then
    "$@"
    return $?
  fi
  # shellcheck disable=SC2016 # Positional parameters expand inside the child bash, not here.
  setpriv --bounding-set=-dac_override,-dac_read_search -- bash -c '"$@"' _ "$@"
}

# _fm_dac_override_drop_blocks_write <dir>: true only if
# fm_run_without_dac_override actually stops a throwaway write inside <dir>
# (which the caller must already have chmod a-w'd), proven empirically
# rather than assumed.
_fm_dac_override_drop_blocks_write() {
  local dir=$1 probe rc
  probe="$dir/.fm-run-dir-readonly-probe.$$"
  command -v setpriv >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2016 # Positional parameters expand inside the child bash, not here.
  fm_run_without_dac_override bash -c '>"$1"' _ "$probe" 2>/dev/null
  rc=$?
  rm -f "$probe" 2>/dev/null
  [ "$rc" -ne 0 ]
}

# fm_dir_block_writes <dir>: chmod <dir> unwritable and, as root, prove the
# block actually holds before returning success. Leaves <dir> writable again
# and refuses (nonzero, no diagnostic needed - the caller decides how loud to
# be) when running as root and the block cannot be proven.
#
# Split out from fm_run_dir_readonly for the one shape that wrapper cannot
# cover: a caller whose protected write happens after the command that
# triggers it has already returned, e.g. fm-startup-network.sh's `start`
# forks a detached worker and returns immediately, so the block has to
# outlive that call and be lifted explicitly later with fm_dir_unblock_writes
# once the worker has actually run - not the instant the launching command
# exits.
fm_dir_block_writes() {
  local dir=$1
  chmod a-w "$dir"
  if [ "$(id -u)" = 0 ] && ! _fm_dac_override_drop_blocks_write "$dir"; then
    chmod u+w "$dir"
    return 97
  fi
  FM_TEST_BLOCKED_DIRS+=("$dir")
  return 0
}

fm_dir_unblock_writes() {
  chmod u+w "$1"
}

# fm_run_dir_readonly <dir> <command...>: fm_dir_block_writes <dir>, run
# <command...>, then fm_dir_unblock_writes <dir>. Use this when <command...>
# itself performs (or fails to perform) the protected write before returning;
# use fm_dir_block_writes/fm_dir_unblock_writes directly when the write
# happens later, off a background worker <command...> only launches.
fm_run_dir_readonly() {
  local dir=$1
  shift
  if ! fm_dir_block_writes "$dir"; then
    printf 'fm_run_dir_readonly: cannot verify a write-block for root on %s; refusing to run %s unprotected\n' "$dir" "$1" >&2
    return 97
  fi
  fm_run_without_dac_override "$@"
  local rc=$?
  fm_dir_unblock_writes "$dir"
  return $rc
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

# fm_git_worktree <repo> <worktree> <branch>: initialize <repo> with one commit
# and a local bare origin, then add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$repo.origin.git"
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
