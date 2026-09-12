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

# Fixture Git isolation for every suite that reaches this library; the helper's
# header owns the invariant and the layers it deliberately leaves in force.
# shellcheck source=tests/git-config-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-config-helpers.sh"

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

# Clear the tasks-axi env overrides. An operator shell exports TASKS_AXI_FILE
# (and may export TASKS_AXI_BACKEND) at its real home's backlog, and tasks-axi
# resolves that env AHEAD of the .tasks.toml a fixture copies, so a suite that
# seeds a temp home with bare `tasks-axi` would silently write the operator's
# live backlog instead - tests/fm-public-followup.test.sh did exactly that. Every
# fixture addresses its own data/backlog.md through its copied .tasks.toml, an
# explicit --file, or bin/fm-tasks-axi.sh; a case that verifies the wrapper
# against an ambient override sets TASKS_AXI_FILE itself.
unset TASKS_AXI_FILE TASKS_AXI_BACKEND

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

FM_TEST_OWNER_IDENTITY=$(fm_test_pid_identity "$$") || {
  rm -f "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

# --- process-event runner reaping -------------------------------------------
#
# A process-event runner is detached into its own process group and reparents to
# init, so removing a fixture directory does not stop one: only sweeping the home
# that owns it does. Registration goes through a `$$`-keyed registry file for the
# same reason the temp roots do - a fixture home is almost always built inside a
# command substitution (`home=$(make_home x)`), and an array append there never
# reaches the caller, so a suite that tracked its homes in a shell array was
# silently tracking nothing and left every runner it started behind.
#
# The sweep is scoped to the exact home (and its claim root when the suite uses a
# private one). It never matches on a script or process name, which would reach
# into another home's live runners.

FM_TEST_PROCEVENT_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-test-procevent.$$.XXXXXX") || return 1

fm_test_track_procevent_home() {  # <home> [claim-root]
  [ -n "${1:-}" ] || return 1
  printf '%s\t%s\n' "$1" "${2-}" >> "$FM_TEST_PROCEVENT_REGISTRY"
}

fm_test_reap_procevent_homes() {
  local home claim_root seen=$'\n'
  [ -f "$FM_TEST_PROCEVENT_REGISTRY" ] || return 0
  while IFS=$'\t' read -r home claim_root; do
    [ -n "$home" ] || continue
    case "$seen" in *$'\n'"$home"$'\n'*) continue ;; esac
    seen+="$home"$'\n'
    [ -d "$home/state/procevent" ] || continue
    if [ -n "$claim_root" ]; then
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_PROCEVENT_CLAIM_ROOT="$claim_root" \
        "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
    else
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
        "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
    fi
  done < "$FM_TEST_PROCEVENT_REGISTRY"
  rm -f "$FM_TEST_PROCEVENT_REGISTRY"
}

# Ceiling on how long a fixture's blocking stub may keep polling. A stub that
# waits for a trigger file by re-running `sleep` is a high-frequency source of
# process spawns, and one that outlives its test - because the test was killed
# before any cleanup ran - is what turned leftover fixtures into a host-wide
# process storm. Every blocking stub this suite writes stops itself at this
# bound, so an escaped one is bounded in duration and cost on its own, before
# its owner's guard reaps it.
FM_TEST_STUB_MAX_BLOCK_SECONDS=${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}
export FM_TEST_STUB_MAX_BLOCK_SECONDS

fm_test_cleanup() {
  local d
  fm_test_reap_procevent_homes
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
trap 'fm_test_cleanup; exit 129' HUP
trap 'fm_test_cleanup; exit 131' QUIT

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

# fm_test_fake_treehouse <fakebin> [lease-path]
# A fake Treehouse pool with the durable-lease behavior bin/fm-wake-lib.sh
# relies on (measured on Treehouse v2.1.1). An explicit <lease-path> pins what
# `get --lease` hands out for fixtures whose fake pane already bakes its own
# path in; otherwise the env knobs below decide:
#   FM_FAKE_TREEHOUSE_LOG         every invocation is appended as
#                                 "treehouse <arg> <arg>..." (one line each)
#   FM_FAKE_TREEHOUSE_LEASE_PATH  the path `get --lease` hands out; falls back
#                                 to FM_FAKE_PANE_PATH so the spawn fixtures'
#                                 fake pane already sits in the leased slot
#   FM_FAKE_TREEHOUSE_LEASES      file of "<path><TAB><holder>" lines: the
#                                 pool's durable leases. `get --lease` appends
#                                 one, `return` removes the target's, and
#                                 `status --json` reports each as leased.
#                                 Unset: leases are neither recorded nor read.
#   FM_FAKE_TREEHOUSE_SLOTS       file of slot paths (one per line) that
#                                 `status --json` lists as available when they
#                                 carry no lease; unset lists only leased slots
#   FM_FAKE_TREEHOUSE_GET_FAIL=1  `get --lease` fails like a full pool
# `return --if-lease-holder <h>` refuses with Treehouse's own messages when the
# target is unleased or leased to another holder, whatever --force says, and
# releases the lease otherwise; a bare `return` releases any lease unchecked.
# Lease paths are compared physically, so a fixture that reaches its slot
# through a symlink still matches; real Treehouse (v2.1.1) refuses a symlinked
# path as "not managed by treehouse" before any holder check.
fm_test_fake_treehouse() {
  local fakebin=$1 lease_path=${2-}
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'treehouse'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
leases=${FM_FAKE_TREEHOUSE_LEASES:-}
slots=${FM_FAKE_TREEHOUSE_SLOTS:-}
physical() { (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }
lease_holder() {  # <path> ; prints the holder, returns 1 when unleased
  local want path holder
  [ -n "$leases" ] && [ -f "$leases" ] || return 1
  want=$(physical "$1")
  while IFS=$'\t' read -r path holder || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    [ "$(physical "$path")" = "$want" ] || continue
    printf '%s\n' "$holder"
    return 0
  done < "$leases"
  return 1
}
lease_drop() {  # <path>
  local want path holder
  [ -n "$leases" ] && [ -f "$leases" ] || return 0
  want=$(physical "$1")
  : > "$leases.tmp"
  while IFS=$'\t' read -r path holder || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    [ "$(physical "$path")" != "$want" ] || continue
    printf '%s\t%s\n' "$path" "$holder" >> "$leases.tmp"
  done < "$leases"
  mv "$leases.tmp" "$leases"
}
json_string() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
case "${1:-}" in
  get)
    shift
    lease=0
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) lease=1 ;;
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift
    done
    [ "$lease" = 1 ] || exit 0
    if [ "${FM_FAKE_TREEHOUSE_GET_FAIL:-0}" = 1 ]; then
      echo "all 1 worktrees are in use or dirty (max_trees = 1). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml" >&2
      exit 1
    fi
    path=${FM_FAKE_TREEHOUSE_LEASE_PATH:-${FM_FAKE_PANE_PATH:-}}
    [ -n "$path" ] || { echo "fake treehouse: no lease path configured" >&2; exit 1; }
    [ -z "$leases" ] || printf '%s\t%s\n' "$path" "$holder" >> "$leases"
    printf '%s\n' "$path"
    exit 0
    ;;
  status)
    [ "${2:-}" = --json ] || exit 0
    printf '['
    sep=
    n=0
    if [ -n "$leases" ] && [ -f "$leases" ]; then
      while IFS=$'\t' read -r path holder || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        n=$((n + 1))
        printf '%s{"name":"%s","path":"%s","status":"leased","lease_id":"fake-%s","lease_holder":"%s","leased_at":"2026-09-12T00:00:00Z","processes":[]}' \
          "$sep" "$n" "$(json_string "$path")" "$n" "$(json_string "$holder")"
        sep=,
      done < "$leases"
    fi
    if [ -n "$slots" ] && [ -f "$slots" ]; then
      while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        lease_holder "$path" >/dev/null && continue
        n=$((n + 1))
        printf '%s{"name":"%s","path":"%s","status":"available","lease_id":"","lease_holder":"","leased_at":null,"processes":[]}' \
          "$sep" "$n" "$(json_string "$path")"
        sep=,
      done < "$slots"
    fi
    printf ']\n'
    exit 0
    ;;
  return)
    shift
    want=
    checked=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) ;;
        --if-lease-holder) shift; want=${1:-}; checked=1 ;;
        --if-lease-holder=*) want=${1#--if-lease-holder=}; checked=1 ;;
        --if-lease-id) shift ;;
        --if-lease-id=*) ;;
        *) target=$1 ;;
      esac
      shift
    done
    if [ "$checked" = 1 ]; then
      if ! have=$(lease_holder "$target"); then
        echo "failed to return worktree: lease precondition failed: worktree $target is not leased" >&2
        exit 1
      fi
      if [ "$have" != "$want" ]; then
        echo "failed to return worktree: lease precondition failed: lease holder does not match worktree $target" >&2
        exit 1
      fi
    fi
    lease_drop "$target"
    echo "Worktree returned to pool."
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  if [ -n "$lease_path" ]; then
    mv "$fakebin/treehouse" "$fakebin/treehouse-pool"
    cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
export FM_FAKE_TREEHOUSE_LEASE_PATH='$lease_path'
exec "\$(dirname "\$0")/treehouse-pool" "\$@"
SH
    chmod +x "$fakebin/treehouse"
  fi
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

# --- portable file timestamps -----------------------------------------------

# fm_touch_epoch <epoch> <path> [path...]: set each path's modification time to
# an absolute epoch second on every supported host.
#
# There is no portable touch(1) flag that takes an epoch: `touch -d @<epoch>` is
# a GNU extension and BSD touch rejects it outright ("out of range or illegal
# time specification"), leaving the file at its current mtime. A test that wants
# a beacon aged 700 seconds then silently measures a brand-new one.
# `touch -t [[CC]YY]MMDDhhmm[.SS]` is POSIX and both accept it, so the only
# host-specific step left is turning the epoch into that stamp, and date(1)
# spells that two incompatible ways. Probe them in this order: GNU date rejects
# `-r <seconds>` (its -r takes a file), while BSD date rejects `-d` as an
# illegal option, so whichever runs is the one that understood the request.
# TZ is pinned to UTC for date and touch so repeated DST hours stay unambiguous.
fm_touch_epoch() {
  local epoch=$1 stamp
  shift
  stamp=$(TZ=UTC0 date -d "@$epoch" +%Y%m%d%H%M.%S 2>/dev/null) \
    || stamp=$(TZ=UTC0 date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null) \
    || fail "fm_touch_epoch: date(1) accepted neither -d @<epoch> nor -r <epoch>"
  TZ=UTC0 touch -t "$stamp" "$@" \
    || fail "fm_touch_epoch: touch -t $stamp failed for $*"
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
# called. The initial branch is pinned rather than inherited from
# init.defaultBranch, so a fixture that names main resolves the same on a
# developer machine and on a runner that still defaults to master.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
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

# assert_equals <expected> <actual> <msg>
assert_equals() {
  [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

# assert_not_equals <unexpected> <actual> <msg>
assert_not_equals() {
  [ "$1" != "$2" ] || fail "$3 (unexpectedly got '$1')"
}

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

# fm_test_base_path_sans <base_path> <tool...>: returns the path to a single
# curated directory that resolves every tool <base_path> would have resolved,
# except the named ones. Some hosts have real system binaries (node, orca,
# ...) sitting in BASE_PATH; a fixture that simulates a tool as missing by
# omitting it from fakebin still falls through to that host binary via
# BASE_PATH, silently defeating the simulation. Dropping whole directories
# out of BASE_PATH is not a safe fix: on a usr-merged host /bin, /sbin, and
# /usr/sbin are symlinks that collapse to the same directory as /usr/bin, so
# dropping any one of them because it resolves the excluded tool drops every
# other tool a test still needs (git, awk, sed, ...) too. Building a curated
# directory instead hides only the named tool(s). Use only at the specific
# assertions that simulate a tool as absent - every other case keeps using
# bare BASE_PATH.
fm_test_base_path_sans() {
  local base_path=$1 dir src entry name tool skip
  shift
  local tools=("$@")
  dir=$(fm_test_tmproot fm-base-path-sans) || return 1
  local dirs
  IFS=: read -ra dirs <<< "$base_path"
  for src in "${dirs[@]}"; do
    [ -d "$src" ] || continue
    for entry in "$src"/*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name=${entry##*/}
      [ -e "$dir/$name" ] && continue
      skip=0
      for tool in "${tools[@]}"; do
        if [ "$name" = "$tool" ]; then
          skip=1
          break
        fi
      done
      [ "$skip" -eq 1 ] && continue
      ln -s "$entry" "$dir/$name" 2>/dev/null || true
    done
  done
  printf '%s\n' "$dir"
}
