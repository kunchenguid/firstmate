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

# Clear the task-worker marker bin/fm-spawn.sh exports into ship and scout
# panes. This suite builds git-init fixture repositories whose primary checkout
# it runs a copied bin/fm-test-run.sh in, and that runner refuses the primary
# under the marker. A case that verifies the refusal sets FM_TASK_ID itself.
unset FM_TASK_ID

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The one owner of "does an exact mode mean anything here", shared with
# production. Sourced here rather than per-suite so fm_test_assert_private_mode
# below asks the same question fm_pr_private_file_valid does, from the same
# code. The library has no side effects on source.
# shellcheck source=bin/fm-platform-lib.sh disable=SC1091
. "$ROOT/bin/fm-platform-lib.sh"

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
    # Both gates below are side-effect-free reads ANDed together, so their order
    # cannot change which markers are reaped - but it dominates what sourcing
    # this file costs. The age gate is one stat; the ownership gate spawns a
    # bash per marker to source a 1500-line library, which under MSYS's emulated
    # fork costs seconds rather than milliseconds. Ordering age first means a
    # marker too young to reap - which is every marker belonging to a concurrent
    # or recent run - is discarded before anything expensive runs.
    mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || continue
    [ $((now - mtime)) -ge "$FM_TEST_ORPHAN_MAX_AGE_SECONDS" ] || continue
    owner_pid=$(sed -n '1p' "$marker" 2>/dev/null) || owner_pid=
    owner_identity=$(sed -n '2,$p' "$marker" 2>/dev/null) || owner_identity=
    case "$owner_pid" in
      '' | *[!0-9]*) ;;
      *)
        # A pid the kernel no longer knows cannot match the recorded identity:
        # fm_pid_identity finds no process to describe, yields nothing, and both
        # branches below then fall through to the reap. Asking kill -0 first
        # reaches that same verdict for the price of a builtin, and it skips the
        # per-marker library source in precisely the case this function exists to
        # clean up, where the run that left the marker is already gone.
        if kill -0 "$owner_pid" 2>/dev/null; then
          current_identity=$(fm_test_pid_identity "$owner_pid" 2>/dev/null) || current_identity=
          if [ -n "$owner_identity" ] && [ "$current_identity" = "$owner_identity" ]; then
            continue
          fi
        fi
        ;;
    esac
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

# --- process field reads ----------------------------------------------------
#
# MSYS ps rejects field selection outright - `ps -o ppid= -p <pid>` exits 1 with
# "unknown option -- o" and prints nothing - so every predicate built on it reads
# empty there and silently concludes whatever empty happens to mean. The Cygwin
# procfs answers for MSYS pids, so these read it as a fallback. Field selection
# is still attempted first, so a POSIX host never reaches the fallback and its
# behavior is unchanged.
#
# The optional ps-command argument exists for the call sites that deliberately
# invoke /bin/ps to bypass a fake ps shim on PATH; it keeps that bypass intact.
#
# These are standalone-script-unfriendly by construction: a helper defined in the
# sourcing shell cannot reach a fixture written to disk and executed as its own
# process, so such fixtures inline the same shape instead of calling these.

fm_test_ppid() {  # <pid> [ps-command]
  local out
  out=$("${2:-ps}" -o ppid= -p "$1" 2>/dev/null | tr -d '[:space:]')
  [ -n "$out" ] || out=$(tr -d '[:space:]' 2>/dev/null < "/proc/$1/ppid")
  printf '%s' "$out"
}

fm_test_pgid() {  # <pid> [ps-command]
  local out
  out=$("${2:-ps}" -o pgid= -p "$1" 2>/dev/null | tr -d '[:space:]')
  [ -n "$out" ] || out=$(tr -d '[:space:]' 2>/dev/null < "/proc/$1/pgid")
  printf '%s' "$out"
}

# Empty means "no such process" and callers depend on that, so a dead pid must
# stay empty rather than gain a placeholder. Procfs delivers that for free: the
# whole /proc/<pid> directory is gone once the process is. The comm field is
# parenthesized and may itself contain spaces, so the state letter is taken as
# the first field after the last ") " rather than by a positional cut.
fm_test_pstate() {  # <pid> [ps-command]
  local out
  out=$("${2:-ps}" -o stat= -p "$1" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$out" ] && [ -r "/proc/$1/stat" ]; then
    out=$(cat "/proc/$1/stat" 2>/dev/null)
    out=${out##*') '}
    out=${out%% *}
  fi
  printf '%s' "$out"
}

# --- private-artifact assertion ---------------------------------------------
#
# fm_test_assert_private_mode <path> <expected-mode> <label> [file|dir]
#
# The test-side twin of fm_pr_private_file_valid: assert the exact mode where a
# mode can actually be stored, and assert the structure that still holds where
# it cannot. On a Git Bash noacl mount chmod is a silent no-op - a file chmod
# 0600 reads back 644 and a directory chmod 0700 reads back 755 - so an exact
# 0600/0700 equality there fails for a reason that has nothing to do with the
# behavior under test. (The read-only bit IS stored: chmod 0444 reads back 444
# and blocks writes, so a 0444 contract is real everywhere and must NOT come
# through here.)
#
# The kind argument is deliberately explicit rather than inferred. Inferring it
# from the path would make the structural branch assert only "it is whatever it
# happens to be", which can never fail - exactly the vacuous green tick this
# helper exists to avoid - and the expected mode is no signal either, since
# 0700 is both a private directory and a private executable shim.
#
# Where the mode is unstorable this prints its own weakened ok line. A silent
# pass would let a reader scanning the log read the suite's ordinary tick as
# proof of privacy; the line says in words which weaker property was checked.
fm_test_assert_private_mode() {  # <path> <expected-mode> <label> [file|dir]
  local path=$1 expected=$2 label=$3 kind=${4:-file} actual
  # Symlink first: a link to a real file passes -f, and a dangling one would
  # otherwise be reported as merely missing.
  [ ! -L "$path" ] || fail "$label: $path is a symlink"
  [ -e "$path" ] || fail "$label: $path does not exist"
  case "$kind" in
    file) [ -f "$path" ] || fail "$label: $path is not a regular file" ;;
    dir) [ -d "$path" ] || fail "$label: $path is not a directory" ;;
    *) fail "fm_test_assert_private_mode: unknown kind '$kind'" ;;
  esac
  if fm_platform_fs_honors_modes "$path"; then
    actual=$(fm_platform_file_mode "$path")
    [ "$actual" = "$expected" ] \
      || fail "$label: expected mode $expected, got ${actual:-<unreadable>}"
    return 0
  fi
  printf 'ok - %s (mode unstorable on this filesystem; structure checked)\n' "$label"
}

# --- live-capability gate ---------------------------------------------------
#
# fm_live_gate <policy> <vars> [tool ...]
#
# The single gate every live-harness guard opens with, so "can this host run
# this guard for real, and should it?" is decided in one place instead of in
# two dozen hand-rolled env checks. It returns 0 when the guard should run, and
# otherwise ends the script with one runner-readable line:
#
#   skip: live: <tool> absent                 this host cannot run the guard
#   skip: live: disabled by <VAR>=0           an explicit local opt-out
#   skip: live: opt-in; set <VAR>=1 to run    a guard that spends model tokens
#
# <policy> is default-on for a guard that spends no model tokens, so it runs
# wherever its tools are installed - notably on the machine the product and its
# validation actually run on - and opt-in for a guard that submits prompts,
# which stays deliberate. <vars> is the guard's own control variable, or a
# comma-separated list when a guard has more than one entry point.
#
# Setting any of those variables to 1 (or FM_LIVE=1, for every guard at once)
# both turns the guard on and makes an absent tool a hard failure rather than a
# skip, which is how "run it after a harness upgrade" keeps proving the guard
# actually ran. Setting one to 0 (or FM_LIVE=0) turns it off; a guard's own
# variable wins over FM_LIVE.
#
# Sourcing this library also exports FM_GATE_REFUSE_BYPASS=1, which is what
# lets a live guard drive the real fm-spawn/fm-send/fm-teardown from inside a
# no-mistakes gate worktree instead of being refused by
# bin/fm-gate-refuse-lib.sh.

fm_live_gate() {
  local policy=$1 vars=$2
  shift 2
  local var value rest primary requested=0 disabled_by='' tool
  local -a var_list=()

  case "$policy" in
    default-on | opt-in) ;;
    *) fail "fm_live_gate: unknown policy '$policy' (expected default-on or opt-in)" ;;
  esac

  rest=$vars
  while [ -n "$rest" ]; do
    var=${rest%%,*}
    if [ "$var" = "$rest" ]; then
      rest=''
    else
      rest=${rest#*,}
    fi
    [ -n "$var" ] && var_list+=("$var")
  done
  [ "${#var_list[@]}" -gt 0 ] || fail "fm_live_gate: at least one control variable is required"
  primary=${var_list[0]}

  for var in "${var_list[@]}"; do
    value=${!var:-}
    case "$value" in
      1) requested=1 ;;
      0) [ -n "$disabled_by" ] || disabled_by=$var ;;
    esac
  done

  if [ "$requested" -eq 0 ]; then
    if [ -n "$disabled_by" ]; then
      printf 'skip: live: disabled by %s=0\n' "$disabled_by"
      exit 0
    fi
    case "${FM_LIVE:-}" in
      0)
        printf 'skip: live: disabled by FM_LIVE=0\n'
        exit 0
        ;;
      1) requested=1 ;;
      *)
        if [ "$policy" = opt-in ]; then
          printf 'skip: live: opt-in; set %s=1 to run\n' "$primary"
          exit 0
        fi
        ;;
    esac
  fi

  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 && continue
    if [ "$requested" -eq 1 ]; then
      printf 'not ok - %s was requested but %s is not installed\n' "$primary" "$tool" >&2
      exit 1
    fi
    printf 'skip: live: %s absent\n' "$tool"
    exit 0
  done

  return 0
}

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
  # MSYS ps rejects -o outright, so field selection reads empty there and an
  # empty read would be mistaken for "the target is gone". The Cygwin procfs
  # answers for MSYS pids; /proc/<pid> disappears with the process, so an
  # unreadable stat file is the real "gone". Same shape as fm_test_pstate,
  # inlined because this shim runs as its own process.
  state=$(ps -o state= -p "$target" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$state" ] && [ -r "/proc/$target/stat" ]; then
    state=$(cat "/proc/$target/stat" 2>/dev/null)
    state=${state##*') '}
    state=${state%% *}
  fi
  case "$state" in
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
