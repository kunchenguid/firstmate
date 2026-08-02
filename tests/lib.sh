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
#
# Git hook stdout and path capture
# --------------------------------
# Fixture helpers often do `dir=$(make_case ...)` / `w=$(new_world ...)` while
# the helper runs git commands that fire hooks (commit, push, clone, worktree
# add, ...) and then prints a path. Any hook that writes to stdout (global
# core.hooksPath leak scanners, local hooks, ...) joins that capture and
# corrupts the path: the next `git -C "$dir/..."` dies with
# `fatal: cannot change to '[SCAN-SET]...'`.
#
# The capture shape predates hooks and is fragile against ANY git stdout, not
# just one scanner. Disabling hooks in fixtures would only green this machine
# and leave the shape intact for the next author.
#
# Durability: this library puts a small git wrapper early on PATH that relocates
# git's stdout to stderr BY DEFAULT - for every subcommand - and keeps stdout
# only for an explicit allow-list of read-only subcommands whose output callers
# legitimately capture (rev-parse, status, diff, `worktree list`, ...).
#
# The default points that way on purpose. A deny-list of "hook-bearing"
# subcommands is a list nobody can finish: whatever is missing from it corrupts
# a capture silently. Under allow-list-by-default, what is missing is a
# read-only subcommand, and it fails loudly at its own call site (an empty
# capture) the first time it runs. Instruments stay visible on stderr either
# way, and new tests can keep writing the obvious `dir=$(helper)` form.
#
# Implementation is a PATH shim (not a shell function named git):
#   - `command -v git` still returns an absolute path (the shim), so toolbins
#     that `ln -s "$(command -v git)" ...` and PATH mocks that re-exec
#     `$(command -v git)` keep working.
#   - The shim always re-execs the absolute real binary in FM_TEST_REAL_GIT, so
#     a fakebin/git that does `exec "$real"` cannot re-enter itself through a
#     bare name.
# Escape hatch for deliberate probes: FM_TEST_GIT_HOOK_STDOUT=keep.
# tests/fm-fixture-git-stdout.test.sh pins the safe default, the keep-mode
# failure, and the command -v / re-exec safety properties.

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

# --- git PATH shim: keep fixture path captures pure -------------------------
#
# Hook instruments (and ordinary porcelain chatter from commit/push/clone) write
# to the git process's stdout. Relocate that stream to stderr for every
# subcommand so `path=$(fixture_helper)` cannot absorb them, and keep stdout
# only for the read-only subcommands (rev-parse, status, diff, ...) whose
# results callers capture on purpose.
#
# Why a PATH shim rather than a shell function named git:
#   A function makes `command -v git` return the bare name "git". That breaks
#   every test that builds a toolbin with `ln -s "$(command -v git)"` (relative
#   symlink to nowhere) and every PATH mock that captures the "real" git via
#   command -v then `exec`s it: when fakebin is first on PATH, bare `git`
#   re-enters the mock and hangs. We already hit that hang once in teardown.
#   A PATH shim keeps command -v returning an absolute path that always ends at
#   the real binary.
#
# Rule for NEW tests that mock git
# --------------------------------
# Follow this without reading the shim body. A hang wastes an hour; a red
# assertion wastes a minute. LOUD = empty capture or immediate assertion
# failure. SILENT = hang or a corrupted pin that greens the wrong thing.
#
#   1. Source this library BEFORE any fakebin/git is on PATH and before
#      capturing "the real git". Loading with a fake already first pins
#      FM_TEST_REAL_GIT to that fake - SILENT wrong pin (or hang if the
#      fake then re-execs "real").
#   2. Call-through only via "$FM_TEST_REAL_GIT" - exported below as the
#      absolute path to the unwrapped binary - or a copy of it baked into
#      the mock at write time. Models: fm-teardown, fm-fleet-sync,
#      fm-secondmate-sync (search REAL_GIT_FOR_TEST / real_git=).
#   3. After load, command -v / type -P / which git is this wrap, not the
#      host binary. Comparing it to /usr/bin/git fails LOUDLY. Re-execing
#      the wrap path terminates (does not hang) but still relocates stdout
#      (see 7).
#   4. Never `exec git "$@"` from a PATH-shadowing fakebin/git.
#      SILENT hang: busy loop until the suite times out.
#   5. Never `real=$(command -v git)` inside the mock while fakebin is
#      first on PATH - finds itself; same SILENT hang as 4.
#   6. PATH=fakebin:$PATH keeps the wrap for non-mocked invocations;
#      PATH=fakebin:$BASE_PATH drops it for a hermetic SUT - SILENT:
#      dropping the wrap restores the capture-corruption hazard (a
#      captured path can absorb hook output). Pin with $FM_TEST_REAL_GIT
#      either way - PATH order does not replace (2).
#   7. Non-allow-listed subcommands send stdout to stderr under the wrap
#      (see keep= / 1>&2 below). Capturing stdout alone yields empty text -
#      usually LOUD (empty path, failed assertion); silent only if the
#      test checks exit status alone. Need porcelain/hook text: capture
#      with 2>&1, or set FM_TEST_GIT_HOOK_STDOUT=keep only for a
#      deliberate probe - never as a silent global for ordinary fixtures.
#
# Executable pin (shapes above, keep-mode, toolbin symlink): do not restate
# here - run tests/fm-fixture-git-stdout.test.sh.

FM_TEST_REAL_GIT=$(type -P git 2>/dev/null || true)
if [ -z "$FM_TEST_REAL_GIT" ] || [ ! -x "$FM_TEST_REAL_GIT" ]; then
  printf 'tests/lib.sh: cannot resolve a real git binary for fixture wrapping\n' >&2
  # shellcheck disable=SC2317 # exit is reached when this file is executed, not sourced.
  return 1 2>/dev/null || exit 1
fi
export FM_TEST_REAL_GIT

FM_TEST_GIT_WRAP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-gitwrap.XXXXXX")
# Absolute bash in the shebang: a restricted PATH toolbin (e.g. crew-state's
# no-timeout path) may omit /usr/bin, so `#!/usr/bin/env bash` cannot find bash.
FM_TEST_BASH=$(type -P bash 2>/dev/null || true)
if [ -z "$FM_TEST_BASH" ] || [ ! -x "$FM_TEST_BASH" ]; then
  printf 'tests/lib.sh: cannot resolve bash for the git PATH shim shebang\n' >&2
  # shellcheck disable=SC2317 # exit is reached when this file is executed, not sourced.
  return 1 2>/dev/null || exit 1
fi
# shellcheck disable=SC2016
cat > "$FM_TEST_GIT_WRAP_DIR/git" <<EOF
#!$FM_TEST_BASH
# Generated by tests/lib.sh - relocates git stdout to stderr by default and
# keeps it only for read-only subcommands (see the header there).
set -u
real='$FM_TEST_REAL_GIT'
# FM_TEST_GIT_HOOK_STDOUT=keep is the pre-fix stream layout: no relocation for
# any subcommand. Deliberate probes only (tests/fm-fixture-git-stdout.test.sh).
if [ "\${FM_TEST_GIT_HOOK_STDOUT:-relocate}" = keep ]; then
  exec "\$real" "\$@"
fi

# Find the subcommand and the word right after it, skipping global options.
# Only the separate-value options need a lookahead skip; every other leading
# dash-word is inert here.
subcmd=; next=; skip=0
for arg in "\$@"; do
  if [ "\$skip" -eq 1 ]; then
    skip=0
    continue
  fi
  if [ -n "\$subcmd" ]; then
    next=\$arg
    break
  fi
  case "\$arg" in
    -C|--git-dir|--work-tree|--namespace|--config-env|-c) skip=1 ;;
    -*) continue ;;
    *) subcmd=\$arg ;;
  esac
done

# Allow-list: read-only subcommands whose stdout callers legitimately capture.
# Everything else - including any hook-bearing subcommand nobody listed - gets
# stdout relocated to stderr, so it stays human-visible but can never join a
# command-substitution capture of a fixture path.
keep=0
case "\$subcmd" in
  # No subcommand at all: \`git --version\`, \`git --exec-path\`, bare usage.
  # Nothing runs a hook, and the info flags are captured on purpose.
  '')
    keep=1
    ;;
  rev-parse|rev-list|status|diff|diff-tree|diff-index|diff-files|log|show|\\
  shortlog|whatchanged|blame|describe|name-rev|symbolic-ref|show-ref|\\
  for-each-ref|ls-files|ls-tree|ls-remote|cat-file|merge-base|merge-tree|\\
  patch-id|hash-object|write-tree|commit-tree|check-ignore|check-attr|\\
  check-ref-format|count-objects|verify-commit|verify-tag|var|config|grep|\\
  version|help)
    keep=1
    ;;
  # Multiplexed subcommands: only their listing forms are read-only. The
  # mutating forms (worktree add, remote add, ...) run checkout hooks or print
  # porcelain, so they relocate like everything else.
  worktree)
    [ "\$next" = list ] && keep=1
    ;;
  remote)
    case "\$next" in ''|-v|--verbose|show|get-url) keep=1 ;; esac
    ;;
  branch)
    case "\$next" in
      ''|-a|-r|-v|-vv|-l|--list|--all|--remotes|--verbose|--show-current|\\
      --contains|--no-contains|--merged|--no-merged|--points-at|--format=*|\\
      --sort=*)
        keep=1
        ;;
    esac
    ;;
  tag)
    case "\$next" in ''|-l|--list|-n*|--contains|--points-at|--format=*|--sort=*) keep=1 ;; esac
    ;;
  stash|notes)
    case "\$next" in list|show) keep=1 ;; esac
    ;;
  submodule)
    case "\$next" in status|summary) keep=1 ;; esac
    ;;
esac
if [ "\$keep" -eq 1 ]; then
  exec "\$real" "\$@"
fi
exec "\$real" "\$@" 1>&2
EOF
chmod +x "$FM_TEST_GIT_WRAP_DIR/git"
# Prepend even if PATH already has another entry; tests that put a fakebin first
# still win for subprocesses, which is what they want.
export PATH="$FM_TEST_GIT_WRAP_DIR:$PATH"

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
# on EXIT. The cleanup trap is installed here, at library load. A test file that
# needs extra teardown (e.g. killing a daemon) should define its own EXIT trap
# and call fm_test_cleanup from inside it so registered dirs are still removed.
#
# Registration is file-mediated on purpose. The canonical call shape is
# `TMP_ROOT=$(fm_test_tmproot ...)`, so the function body runs in a
# command-substitution subshell: a bash array append there dies with the
# subshell and never reaches this shell. A line appended to
# $FM_TEST_CLEANUP_LIST survives, so the roots really are reclaimed.
# FM_TEST_CLEANUP_DIRS stays for callers that register a dir from this shell
# directly (tests/wake-helpers.sh, tests/fm-lint.test.sh).

FM_TEST_CLEANUP_DIRS=()
# Registered here rather than at first use, so the git PATH shim dir is still
# reclaimed when a test never calls fm_test_tmproot. It rides this library's
# EXIT trap: a file that installs its own EXIT trap without calling
# fm_test_cleanup (see above) leaves the shim dir behind under TMPDIR.
FM_TEST_CLEANUP_DIRS+=("$FM_TEST_GIT_WRAP_DIR")
FM_TEST_CLEANUP_LIST="$FM_TEST_GIT_WRAP_DIR/cleanup-dirs"
: > "$FM_TEST_CLEANUP_LIST"
export FM_TEST_CLEANUP_LIST
trap fm_test_cleanup EXIT

fm_test_cleanup() {
  local d
  if [ -f "$FM_TEST_CLEANUP_LIST" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && rm -rf "$d"
    done < "$FM_TEST_CLEANUP_LIST"
  fi
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  # Append, do not array-push: this usually runs inside $( ), and the trap
  # installed at library load reads this file back in the parent shell.
  printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_LIST"
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

# fm_fake_stamped_harnesses <fakebin>: install one fake binary per harness
# recorded in harness-adapters/SKILL.md, each reporting exactly its recorded
# build.
#
# Under FM_BOOTSTRAP_VERBOSE_FACTS=1, bin/fm-bootstrap.sh runs the read-only
# harness build-drift check, which compares those stamps against the harnesses on
# PATH. A hermetic fakebin PATH has none of them, so without this every verbose
# BOOTSTRAP_INFO assertion would also carry a drift fact per harness. Declaring
# them present at their recorded build keeps the real check running while silence
# still means silence. The drift outcomes themselves belong to
# tests/fm-harness-drift.test.sh.
fm_fake_stamped_harnesses() {
  local fakebin=$1 harness version
  while read -r harness version; do
    [ -n "$harness" ] || continue
    cat > "$fakebin/$harness" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = --version ] && { printf '%s\n' '$version'; exit 0; }
exit 0
SH
    chmod +x "$fakebin/$harness"
  done <<EOF
$("$ROOT/bin/fm-harness-drift.sh" --stamps)
EOF
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
