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

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Every watcher spawn evaluates the slow-check block on its first cycle, because
# a missing .last-check reads as "due immediately" regardless of FM_CHECK_INTERVAL.
# Without this the fseventsd early-warning check would run pgrep/top against the
# live host in every watcher test, coupling unrelated suites to this machine's real
# fseventsd footprint and adding a subprocess of latency to each first cycle. Tests
# that exercise the check itself set FM_TELEMETRY_FSEVENTSD_DISABLE=0 with fakes.
export FM_TELEMETRY_FSEVENTSD_DISABLE=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_test_pid_identity() {
  local pid=$1
  FM_STATE_OVERRIDE="${TMPDIR:-/tmp}" bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid"
}

# --- owned fixture processes -----------------------------------------------
#
# A long-lived fixture process registers one durable record through
# `bash tests/lib.sh owned-child-register ...`. The test runner supplies the
# registry directory when it owns the outer execution boundary; direct test
# invocations get a private registry below. Records carry enough identity to
# release and, if necessary, terminate only the exact process group a fixture
# created. Never substitute pathname or command-line discovery here.

fm_test_process_pgid() {
  local pid=$1 pgid
  pgid=$(LC_ALL=C ps -o pgid= -p "$pid" 2>/dev/null) || return 1
  pgid=$(printf '%s' "$pgid" | tr -d '[:space:]')
  case "$pgid" in ''|*[!0-9]*|0|1) return 1 ;; esac
  printf '%s\n' "$pgid"
}

fm_test_owned_group_live() {
  kill -0 -- "-$1" 2>/dev/null
}

fm_test_owned_child_register() { # <registry> <pid> <root> [release-or-stop-control...]
  local registry=$1 pid=$2 root=$3 pgid identity record tmp control
  shift 3
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -d "$registry" ] || return 1
  [ -d "$root" ] || return 1
  root=$(cd -P -- "$root" && pwd -P) || return 1
  pgid=$(fm_test_process_pgid "$pid") || return 1
  identity=$(fm_test_pid_identity "$pid") || return 1
  record="$registry/child.$pid"
  tmp="$registry/.child.$pid.$$"
  umask 077
  {
    printf '%s\n' "$pid" "$pgid" "$root" "$identity"
    for control in "$@"; do
      [ -n "$control" ] && printf '%s\n' "$control"
    done
  } > "$tmp" || return 1
  mv "$tmp" "$record"
}

fm_test_owned_group_wait_closed() { # <pgid> <iterations>
  local pgid=$1 iterations=$2 i=0
  while fm_test_owned_group_live "$pgid" && [ "$i" -lt "$iterations" ]; do
    sleep 0.02
    i=$((i + 1))
  done
  ! fm_test_owned_group_live "$pgid"
}

fm_test_owned_child_cleanup_record() { # <record>
  local record=$1 pid pgid root identity current current_pgid own_pgid control parent peer peer_pid peer_pgid peer_identity peer_current
  pid=$(sed -n '1p' "$record" 2>/dev/null) || return 1
  pgid=$(sed -n '2p' "$record" 2>/dev/null) || return 1
  root=$(sed -n '3p' "$record" 2>/dev/null) || return 1
  identity=$(sed -n '4p' "$record" 2>/dev/null) || return 1
  case "$pid:$pgid" in *[!0-9:]*) return 1 ;; esac
  [ -n "$identity" ] || return 1

  if [ -d "$root" ]; then
    while IFS= read -r control; do
      [ -n "$control" ] || continue
      parent=${control%/*}
      [ "$parent" != "$control" ] || parent=.
      [ -d "$parent" ] && : > "$control"
    done < <(sed -n '5,$p' "$record" 2>/dev/null)
  fi

  if fm_test_owned_group_wait_closed "$pgid" 150; then
    rm -f "$record"
    return 0
  fi

  current=$(fm_test_pid_identity "$pid" 2>/dev/null) || current=
  current_pgid=$(fm_test_process_pgid "$pid" 2>/dev/null) || current_pgid=
  if [ -z "$current" ] && fm_test_owned_group_live "$pgid"; then
    for peer in "${record%/*}"/child.*; do
      [ "$peer" != "$record" ] || continue
      [ -f "$peer" ] || continue
      peer_pid=$(sed -n '1p' "$peer" 2>/dev/null) || continue
      peer_pgid=$(sed -n '2p' "$peer" 2>/dev/null) || continue
      [ "$peer_pgid" = "$pgid" ] || continue
      peer_identity=$(sed -n '4p' "$peer" 2>/dev/null) || continue
      peer_current=$(fm_test_pid_identity "$peer_pid" 2>/dev/null) || continue
      if [ "$peer_current" = "$peer_identity" ]; then
        rm -f "$record"
        return 0
      fi
    done
  fi
  own_pgid=$(fm_test_process_pgid "$$" 2>/dev/null) || own_pgid=
  if [ "$current" != "$identity" ] || [ "$current_pgid" != "$pgid" ] || [ "$pgid" = "$own_pgid" ]; then
    printf 'fm-test: refusing ambiguous owned fixture group pid=%s pgid=%s root=%s\n' \
      "$pid" "$pgid" "$root" >&2
    return 1
  fi

  kill -TERM -- "-$pgid" 2>/dev/null || true
  if fm_test_owned_group_wait_closed "$pgid" 50; then
    rm -f "$record"
    return 0
  fi

  # The identity and membership above authorize this one bounded teardown
  # transaction. Escalation stays scoped to that already-proven group.
  kill -KILL -- "-$pgid" 2>/dev/null || true
  if fm_test_owned_group_wait_closed "$pgid" 50; then
    rm -f "$record"
    return 0
  fi
  printf 'fm-test: owned fixture group survived KILL pid=%s pgid=%s root=%s\n' \
    "$pid" "$pgid" "$root" >&2
  return 1
}

fm_test_owned_children_cleanup() { # <registry> [root]
  local registry=$1 only_root=${2:-} record root failed=0
  [ -d "$registry" ] || return 0
  for record in "$registry"/child.*; do
    [ -f "$record" ] || continue
    root=$(sed -n '3p' "$record" 2>/dev/null) || root=
    [ -z "$only_root" ] || [ "$root" = "$only_root" ] || continue
    fm_test_owned_child_cleanup_record "$record" || failed=1
  done
  [ "$failed" -eq 0 ]
}

fm_test_owned_children_assert_zero() { # <registry>
  local registry=$1 record pid pgid
  [ -d "$registry" ] || return 0
  for record in "$registry"/child.*; do
    [ -f "$record" ] || continue
    pid=$(sed -n '1p' "$record" 2>/dev/null) || pid=unknown
    pgid=$(sed -n '2p' "$record" 2>/dev/null) || pgid=unknown
    printf 'fm-test: registered fixture process remains pid=%s pgid=%s\n' "$pid" "$pgid" >&2
    return 1
  done
  return 0
}

fm_test_in_owned_process_group() {
  perl -MPOSIX -e '
    POSIX::setsid() >= 0 or die "setsid failed: $!\n";
    exec {$ARGV[0]} @ARGV or die "exec $ARGV[0] failed: $!\n";
  ' "$@"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  command=${1:-}
  shift || true
  case "$command" in
    owned-child-register)
      fm_test_owned_child_register "$@"
      exit $?
      ;;
    owned-children-cleanup)
      fm_test_owned_children_cleanup "$@" && fm_test_owned_children_assert_zero "$@"
      exit $?
      ;;
    owned-children-assert-zero)
      fm_test_owned_children_assert_zero "$@"
      exit $?
      ;;
    *)
      printf 'usage: bash tests/lib.sh owned-child-register|owned-children-cleanup|owned-children-assert-zero ...\n' >&2
      exit 2
      ;;
  esac
fi

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
FM_TEST_OWNED_CHILD_REGISTRY_OWNED=0
if [ -z "${FM_TEST_OWNED_CHILD_REGISTRY:-}" ]; then
  FM_TEST_OWNED_CHILD_REGISTRY=$(mktemp -d "${TMPDIR:-/tmp}/.fm-test-owned.$$.XXXXXX") || return 1
  FM_TEST_OWNED_CHILD_REGISTRY_OWNED=1
fi
export FM_TEST_OWNED_CHILD_REGISTRY
export FM_TEST_LIB="$ROOT/tests/lib.sh"

FM_TEST_OWNER_IDENTITY=$(fm_test_pid_identity "$$") || {
  rm -f "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

fm_test_cleanup() {
  local d failed=0
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] || continue
    if fm_test_owned_children_cleanup "$FM_TEST_OWNED_CHILD_REGISTRY" "$d"; then
      rm -rf "$d"
    else
      failed=1
    fi
  done
  if [ -f "$FM_TEST_CLEANUP_REGISTRY" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      if fm_test_owned_children_cleanup "$FM_TEST_OWNED_CHILD_REGISTRY" "$d"; then
        rm -rf "$d"
      else
        failed=1
      fi
    done < "$FM_TEST_CLEANUP_REGISTRY"
    rm -f "$FM_TEST_CLEANUP_REGISTRY"
  fi
  fm_test_owned_children_assert_zero "$FM_TEST_OWNED_CHILD_REGISTRY" || failed=1
  if [ "$FM_TEST_OWNED_CHILD_REGISTRY_OWNED" -eq 1 ] && [ "$failed" -eq 0 ] \
    && [ -d "$FM_TEST_OWNED_CHILD_REGISTRY" ]; then
    rmdir "$FM_TEST_OWNED_CHILD_REGISTRY" 2>/dev/null || failed=1
  fi
  [ "$failed" -eq 0 ]
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

fm_test_cleanup_on_exit() {
  local status=$?
  trap - EXIT
  fm_test_cleanup || status=1
  exit "$status"
}

trap fm_test_cleanup_on_exit EXIT
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
