#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root that also reaps processes leaked inside
# it, fakebin/PATH-shim helpers, deterministic git identity and fixture
# builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. Shared fake-toolchain and spawn-world
# builders live in tests/fixtures.sh; wake-queue mocks in wake-helpers.sh;
# secondmate-lifecycle mocks in secondmate-helpers.sh. Suite-specific fakes
# that encode a single test's terminal or lifecycle assumptions still belong
# with the tests that own them.
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

# The one owner of "which processes may this reaper signal" - both the cwd
# boundary and the per-signal identity recheck - shared with
# bin/fm-teardown.sh's leaked-process reap. Safe to source here because it is
# pure: unlike bin/fm-wake-lib.sh (which fm_test_pid_identity below must
# therefore call in a subshell with FM_STATE_OVERRIDE set), it creates no
# directories and resolves no home at source time.
# shellcheck source=bin/fm-proc-cwd-lib.sh
. "$ROOT/bin/fm-proc-cwd-lib.sh"

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
# it so registered dirs are still removed. Each registered dir is swept for
# leaked processes before it is removed - see "leaked-process sweep" below for
# why that has to happen before, not after.
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

# The OWNERSHIP identity - bin/fm-wake-lib.sh's fm_pid_identity, as the
# watcher and the turn-end guards compute it - for tests that assert against a
# real claim record, and for this file's own fixture-root owner marker. Any
# change to the process must read as a different owner there, so it includes
# the command line. A reaper needs the opposite (an identity that survives
# `exec`) and must use fm_proc_reap_identity instead; bin/fm-proc-cwd-lib.sh's
# header owns that distinction.
fm_test_pid_identity() {
  local pid=$1
  FM_STATE_OVERRIDE="${TMPDIR:-/tmp}" bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid"
}

FM_TEST_OWNER_IDENTITY=$(fm_test_pid_identity "$$") || {
  rm -f "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

# --- leaked-process sweep ---------------------------------------------------
#
# Removing a fixture root does not stop what is still running inside it. The
# suites that drive the real bin/fm-spawn.sh type `treehouse get` into the
# task's pane; whenever that pane belongs to a live runtime rather than a stub
# (an ambient herdr server is the case seen in practice), the REAL
# `treehouse get` runs, opens its subshell inside the fixture tree, and outlives
# the tree - leaving a process pair per spawning case whose working directory is
# a path that no longer exists. Observed 2026-09-03: 74 such `treehouse get`
# processes plus a child shell each, the oldest 6d18h old, every one traceable to
# a fixture root under TMPDIR.
#
# Production tasks already get this guarantee from bin/fm-teardown.sh's Fix 2.
# The boundary computation is shared with it (fm_pids_with_cwd_under in
# bin/fm-proc-cwd-lib.sh, which owns why cwd is the right key); the policy is
# not, and deliberately differs: teardown is fail-closed because it is about to
# destroy real work, while this sweep is best-effort because a leaked process
# must never be able to fail a suite.
#
# SCOPE IS THE SAFETY PROPERTY. A sweep that could reach a real task's worktree,
# another suite's tree, or the primary checkout would be worse than the leak it
# fixes, so two independent conditions must hold before anything is signalled:
# the directory must carry the .fm-test-fixture marker only fm_test_tmproot
# writes, and it must sit under TMPDIR. Neither the registry file nor a caller
# can widen that: an unmarked or non-TMPDIR path is skipped, not swept.

# fm_test_sweepable_root <dir>
# True only for a path this suite may sweep processes out of.
fm_test_sweepable_root() {
  local dir=$1 tmp_base
  [ -n "$dir" ] || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ -f "$dir/.fm-test-fixture" ] || return 1
  tmp_base=${TMPDIR:-/tmp}
  tmp_base=${tmp_base%/}
  tmp_base=$(cd -P -- "$tmp_base" 2>/dev/null && pwd -P) || return 1
  dir=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || return 1
  # Whole-component test, so a sibling of TMPDIR sharing its prefix never
  # qualifies. The root itself is never TMPDIR: it must be strictly beneath it.
  case "$dir" in "$tmp_base"/?*) return 0 ;; esac
  return 1
}

# fm_test_sweep_leaked_processes <dir>
# TERMs, then KILLs, every process whose cwd is under <dir>. Best-effort and
# always succeeds: an unsweepable path, an unreadable process list, or a
# survivor is left for the next run's fm_test_reap_orphans rather than raised.
#
# The KILL pass is not a formality. Half of each leaked pair is the runtime's
# pane shell, an interactive login shell that ignores SIGTERM - all 99 found on
# this machine survived TERM and needed KILL - so a TERM-only sweep would still
# leak one process per spawning case.
#
# A pid is not a safe reference to the process that was scanned, so every
# signal goes through fm_proc_safe_to_signal: the pid must still be inside the
# cwd boundary according to a FRESH scan, and must still be the same process
# whose identity was captured at scan time. Re-scanning alone would not close
# the window between listing a pid and signalling it - once that pid has exited
# and the OS has recycled the number, a cwd-only recheck cannot tell the
# replacement apart from the leak - so the sweep would be able to signal a
# process it never leaked. bin/fm-proc-cwd-lib.sh owns both halves of that
# predicate and the reason its identity is birth-only, which is what keeps a
# leaked process that exec'd in the meantime reapable rather than spared.
#
# Note the two remaining asymmetries with production teardown, both from the
# best-effort policy: a pid whose identity cannot be read is skipped rather
# than refused, and there is one TERM/KILL round rather than bounded retries.
fm_test_sweep_leaked_processes() {
  local dir=$1 pids pid identity i
  local -a tracked_pids tracked_identities
  fm_test_sweepable_root "$dir" || return 0
  pids=$(fm_pids_with_cwd_under "$dir" 2>/dev/null) || return 0
  [ -n "$pids" ] || return 0
  tracked_pids=()
  tracked_identities=()
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    identity=$(fm_proc_reap_identity "$pid" 2>/dev/null) || continue
    tracked_pids+=("$pid")
    tracked_identities+=("$identity")
  done <<EOF
$pids
EOF
  [ "${#tracked_pids[@]}" -gt 0 ] || return 0

  pids=$(fm_pids_with_cwd_under "$dir" 2>/dev/null) || return 0
  for i in "${!tracked_pids[@]}"; do
    if fm_proc_safe_to_signal "${tracked_pids[$i]}" "${tracked_identities[$i]}" "$pids"; then
      kill -TERM "${tracked_pids[$i]}" 2>/dev/null
    fi
  done

  sleep "${FM_TEST_SWEEP_GRACE:-0.5}"

  pids=$(fm_pids_with_cwd_under "$dir" 2>/dev/null) || return 0
  for i in "${!tracked_pids[@]}"; do
    if fm_proc_safe_to_signal "${tracked_pids[$i]}" "${tracked_identities[$i]}" "$pids"; then
      kill -KILL "${tracked_pids[$i]}" 2>/dev/null
    fi
  done
  return 0
}

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && fm_test_sweep_leaked_processes "$d"
    [ -n "$d" ] && rm -rf "$d"
  done
  if [ -f "$FM_TEST_CLEANUP_REGISTRY" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && fm_test_sweep_leaked_processes "$d"
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
    # A prior run killed hard enough to skip its traps leaked its processes as
    # well as its root. The owner checks above have already established this
    # root has no live owner and is older than the age floor, so anything still
    # rooted in it is orphaned by definition - and sweeping it here is the only
    # thing that stops those processes accumulating across runs.
    fm_test_sweep_leaked_processes "$dir"
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
