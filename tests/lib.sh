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

# Block until <pid>'s published command line IS <argv> twice in a row, or fail
# after a bounded wait.
#
# `cmd &` forks first and only then runs execve, and a process sampled inside
# that window still reports the forking shell's own command line; while execve
# is swapping the address space the kernel publishes no argv at all, which ps
# renders as a bracketed placeholder. A test that samples a freshly started
# child before it has finished becoming itself therefore records an identity
# that changes milliseconds later for reasons unrelated to what it asserts -
# reliably green on a warm machine, red on a cold runner that widens the window.
# Requiring two identical reads makes a mid-execve transient insufficient, and
# the bounded wait fails loudly instead of quietly sampling early. The match is
# the WHOLE command line, never a substring: a forking shell's command line can
# contain the command it is about to exec, so a substring match would accept the
# very pre-exec image this exists to wait past.
fm_test_wait_exec_settled() {  # <pid> <argv> [<ticks>]
  local pid=$1 want=$2 limit=${3:-500} i=0 seen prev=
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  while [ "$i" -lt "$limit" ]; do
    seen=$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null || true)
    seen=${seen#"${seen%%[![:space:]]*}"}
    seen=${seen%"${seen##*[![:space:]]}"}
    if [ "$seen" = "$want" ]; then
      if [ "$prev" = settled ]; then
        return 0
      fi
      prev=settled
    else
      prev=
    fi
    sleep 0.01
    i=$((i + 1))
  done
  return 1
}

FM_TEST_OWNER_IDENTITY=$(fm_test_pid_identity "$$") || {
  rm -f "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

fm_test_cleanup() {
  local d
  fm_test_reap_tracked_pids
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

# --- spawned-process registry -----------------------------------------------
#
# A test that starts a real background process (a watcher, an arm, a daemon)
# owns that process for its whole life. `fail` exits the script immediately, so
# a reap written after an assertion never runs on the failing path and the
# process outlives the script: reparented to init, still holding whatever
# stdout it inherited. One such survivor was enough to hold an entire test lane
# open indefinitely with no diagnostic. Registering the PID makes the reap
# unconditional, because the same EXIT/INT/TERM traps that remove temp roots
# also stop every registered process.
#
# Reaping is TERM, a bounded grace, then KILL: a process whose signal handler
# was dropped survives TERM, and waiting on it forever is how a stuck reap
# becomes a stuck script and then a stuck lane. Nothing here ever matches on a
# command line - lanes share this machine's process table, and a pattern kill
# reaches into a sibling lane.
#
# The registry is a `$$`-keyed file for the same reason the temp-root registry
# is: a helper that runs inside `$(...)` cannot write to the caller's arrays.
# Registration costs one append and no fork, because it runs at every spawn in
# suites that start dozens of real processes.

FM_TEST_PID_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-test-pids.$$.XXXXXX") || return 1
# Ticks of 0.05s allowed between TERM and KILL, and again after KILL.
FM_TEST_REAP_GRACE_TICKS=${FM_TEST_REAP_GRACE_TICKS:-60}

# Register one or more PIDs this test started, so cleanup reaps them even when
# an assertion fails before the test's own reap runs.
fm_test_track_pid() {  # <pid> [<pid>...]
  local pid
  for pid in "$@"; do
    case "$pid" in
      '' | *[!0-9]*) continue ;;
    esac
    printf '%s\n' "$pid" >> "$FM_TEST_PID_REGISTRY" 2>/dev/null || true
  done
}

# PIDs descended from <pid> in the current process table, deepest last. Read
# from the live parent/child graph, never from a command-line match.
fm_test_descendant_pids() {  # <pid>
  local root=$1
  case "$root" in
    '' | *[!0-9]*) return 0 ;;
  esac
  ps -eo pid=,ppid= 2>/dev/null | awk -v root="$root" '
    { pid[NR] = $1; ppid[NR] = $2; n = NR }
    END {
      want[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= n; i++) {
          if (!(pid[i] in want) && (ppid[i] in want)) {
            want[pid[i]] = 1
            changed = 1
          }
        }
      }
      for (p in want) {
        if (p != root) print p
      }
    }'
}

fm_test_pid_gone() {  # <pid>
  ! kill -0 "$1" 2>/dev/null
}

# TERM one PID, allow a bounded grace, then KILL. Bash reaps a finished
# background job from its own SIGCHLD handler, so kill -0 stops succeeding as
# soon as the process is really gone and the grace is never spent on a zombie.
fm_test_signal_pid_hard() {  # <pid>
  local pid=$1 i=0
  fm_test_pid_gone "$pid" && return 0
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt "$FM_TEST_REAP_GRACE_TICKS" ] && ! fm_test_pid_gone "$pid"; do
    sleep 0.05
    i=$((i + 1))
  done
  fm_test_pid_gone "$pid" && return 0
  kill -KILL "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt "$FM_TEST_REAP_GRACE_TICKS" ] && ! fm_test_pid_gone "$pid"; do
    sleep 0.05
    i=$((i + 1))
  done
  fm_test_pid_gone "$pid"
}

# Reap <pid>, then whatever it left running. Signalling the process first and
# its leftovers second is deliberate: a process that cleans up after itself gets
# to, and only what actually outlived it is signalled directly. Returns non-zero
# when something survived both TERM and KILL, which is worth surfacing rather
# than waiting out.
fm_test_reap_pid() {  # <pid>
  local pid=$1 kid rc=0 kids
  case "$pid" in
    '' | *[!0-9]*) return 0 ;;
  esac
  kids=$(fm_test_descendant_pids "$pid")
  fm_test_signal_pid_hard "$pid" || rc=1
  wait "$pid" 2>/dev/null || true
  # Anything from that snapshot still alive is now an orphan of this test, so
  # reap it by the PID recorded while it was still a verified descendant.
  for kid in $kids; do
    fm_test_pid_gone "$kid" && continue
    fm_test_signal_pid_hard "$kid" || rc=1
  done
  return "$rc"
}

# Reap every registered PID that is still one of this shell's own live jobs.
#
# Job-table membership is the PID-recycling guard: bash drops a job as soon as
# it reaps it, so a PID the kernel later hands to an unrelated process is not in
# the table and is never signalled. It also costs nothing, unlike recording each
# PID's identity at registration.
#
# `jobs` must run in THIS shell. A command or process substitution runs it in a
# subshell with no copy of the job table, which would report every job gone and
# silently reap nothing - the same trap bin/fm-test-run.sh's scheduler documents.
fm_test_reap_tracked_pids() {
  local pid live
  [ -n "${FM_TEST_PID_REGISTRY:-}" ] || return 0
  [ -f "$FM_TEST_PID_REGISTRY" ] || return 0
  live="$FM_TEST_PID_REGISTRY.live"
  : > "$live"
  jobs -rp >> "$live" 2>/dev/null || true
  jobs -sp >> "$live" 2>/dev/null || true
  while IFS= read -r pid; do
    case "$pid" in
      '' | *[!0-9]*) continue ;;
    esac
    grep -qx -- "$pid" "$live" 2>/dev/null || continue
    fm_test_pid_gone "$pid" && continue
    fm_test_reap_pid "$pid" || true
  done < "$FM_TEST_PID_REGISTRY"
  rm -f "$live" "$FM_TEST_PID_REGISTRY"
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX") || return 1
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
    rm -rf "$dir"
  done
}

fm_test_reap_orphans

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir. fm_fake_version_tool drops a stub for a tool
# whose installed version bootstrap gates, so a fixture cannot be reported as an
# unparseable build simply for answering `--version` with nothing.

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
