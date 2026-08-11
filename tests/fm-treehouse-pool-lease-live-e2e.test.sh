#!/usr/bin/env bash
# tests/fm-treehouse-pool-lease-live-e2e.test.sh - opt-in drift guard proving the
# INSTALLED treehouse still honours the pool contract fm-spawn.sh depends on.
#
# Why this file exists: firstmate leases each task's pooled copy itself
# (`treehouse get --lease --lease-holder <id>`) so the reservation outlives the
# pane's shell and holds across homes. Four properties of that contract are
# emitted by the vendor, not by firstmate, and a release could change any of them
# without notice:
#
#   1. `get --lease` prints ONLY the worktree path on stdout, so the path can be
#      read without parsing banners.
#   2. A leased copy is never handed out by a later `get`, even with no process
#      running inside it - the whole point, because a pane's shell dying is
#      exactly what used to free a copy a live task still owned.
#   3. `return` WITHOUT --force refuses a copy that still holds uncommitted work
#      rather than cleaning it, which is what keeps an abandoned copy's unlanded
#      work safe when firstmate declines to reclaim it.
#   4. `return --force` releases a LEASED copy back to the pool. Normal task
#      teardown depends on that call to free its slot, so a release that quietly
#      ignored it would fill the pool over a long run instead of racing over one
#      copy - a different failure, equally fatal.
#
# The portable counterpart in tests/fm-spawn-worktree-settle.test.sh pins
# firstmate's own behaviour on top of these, and runs in CI against whatever
# treehouse is installed. This guard reads the vendor contract directly and fails
# naming the tool and version. Run it after any treehouse upgrade and before
# trusting refreshed evidence in docs/verification/runtime-backends.md.
#
# It consumes no model tokens and never touches a pool outside its own fixture:
# the fixture repo pins `root` to a temporary directory, so every worktree and
# all pool state live and die inside that directory.
set -u

if [ "${FM_TREEHOUSE_POOL_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_TREEHOUSE_POOL_DRIFT=1 to run the installed-treehouse pool lease drift guard"
  exit 0
fi

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

LAB=
cleanup_all() {
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

command -v treehouse >/dev/null 2>&1 || fail "treehouse not found"
TH=$(command -v treehouse)
TH_VERSION=$("$TH" --version 2>/dev/null | head -1)
[ -n "$TH_VERSION" ] || TH_VERSION="unknown version"
note "treehouse $TH_VERSION at $TH"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-treehouse-pool.XXXXXX") || exit 1
REPO="$LAB/repo"
mkdir -p "$REPO" "$LAB/pool"
git -C "$REPO" init -q
printf '# pool lease guard\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm initial
printf 'max_trees = 3\nroot = "%s"\n' "$LAB/pool" > "$REPO/treehouse.toml"

lease() {  # <holder> -> prints stdout only
  ( cd "$REPO" && "$TH" get --lease --lease-holder "$1" ) </dev/null 2>/dev/null
}

WT_A=$(lease task-a)
case "$WT_A" in
  /*) ;;
  *) fail "treehouse $TH_VERSION: 'get --lease' did not print a bare absolute path on stdout (got '$WT_A')" ;;
esac
[ "$(printf '%s\n' "$WT_A" | wc -l | tr -d '[:space:]')" = 1 ] \
  || fail "treehouse $TH_VERSION: 'get --lease' printed more than the worktree path on stdout"
[ -d "$WT_A" ] || fail "treehouse $TH_VERSION: 'get --lease' printed a path that is not a directory: $WT_A"
[ "$(cd "$(git -C "$WT_A" rev-parse --show-toplevel)" && pwd -P)" = "$(cd "$WT_A" && pwd -P)" ] \
  || fail "treehouse $TH_VERSION: the leased path is not a worktree root: $WT_A"
pass "treehouse get --lease prints only the leased worktree's absolute path on stdout"

# Nothing is running inside WT_A - no subshell, no agent, no shell at all. Under
# a process-lifetime reservation this copy would look free; under a lease it
# must not be offered again.
WT_B=$(lease task-b)
[ -n "$WT_B" ] || fail "treehouse $TH_VERSION: a second lease returned no path"
[ "$WT_B" != "$WT_A" ] \
  || fail "treehouse $TH_VERSION: a later 'get --lease' re-offered the copy leased to task-a with no process inside it"
pass "a leased copy with no live process inside it is never re-offered by a later get"

# Prune must not reclaim a lease either: firstmate keeps an abandoned copy leased
# precisely so unlanded work survives until someone reconciles it.
( cd "$REPO" && "$TH" prune ) </dev/null >/dev/null 2>&1 || true
WT_C=$(lease task-c)
[ -n "$WT_C" ] && [ "$WT_C" != "$WT_A" ] && [ "$WT_C" != "$WT_B" ] \
  || fail "treehouse $TH_VERSION: prune reclaimed a leased copy (task-c was handed $WT_C)"
pass "prune leaves leased copies alone"

# The refusal firstmate leans on when it declines to reclaim an abandoned copy.
printf 'unlanded\n' > "$WT_A/unlanded.txt"
( cd "$REPO" && "$TH" return "$WT_A" ) </dev/null >/dev/null 2>&1 || true
[ -f "$WT_A/unlanded.txt" ] \
  || fail "treehouse $TH_VERSION: 'return' without --force cleaned a copy holding uncommitted work"
pass "return without --force refuses a copy holding uncommitted work instead of cleaning it"

# ... and the release firstmate performs once a copy is provably clean.
rm -f "$WT_A/unlanded.txt"
( cd "$REPO" && "$TH" return "$WT_A" ) </dev/null >/dev/null 2>&1 || true
WT_REUSED=$(lease task-d)
[ "$WT_REUSED" = "$WT_A" ] \
  || fail "treehouse $TH_VERSION: 'return' on a clean copy did not release it back to the pool (next lease got '$WT_REUSED', expected $WT_A)"
pass "return without --force releases a clean copy back to the pool non-interactively"

# WT_A is leased to task-d now. bin/fm-teardown.sh releases every completed
# task's copy with `return --force`; nothing expires a lease, and prune skips one
# (checked above). A release that stopped honouring --force over a lease would
# leak a slot per completed task and exhaust the pool part-way through a long run.
printf 'discarded by force\n' > "$WT_A/scratch.txt"
( cd "$REPO" && "$TH" return --force "$WT_A" ) </dev/null >/dev/null 2>&1 || true
WT_FORCED=$(lease task-e)
[ "$WT_FORCED" = "$WT_A" ] \
  || fail "treehouse $TH_VERSION: 'return --force' did not release the copy leased to task-d (next lease got '$WT_FORCED', expected $WT_A); teardown would leak a pool slot per task"
pass "return --force releases a leased copy back to the pool, which is how teardown frees a slot"

echo "# all fm-treehouse-pool-lease-live-e2e checks passed against treehouse $TH_VERSION"
