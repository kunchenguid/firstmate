#!/usr/bin/env bash
# Behavior tests for fm-fleet-sync.sh drift handling.
#
# fm-fleet-sync fast-forwards a clone that is cleanly on its default branch. This
# suite pins the two behavioral additions on top of that:
#   - the one safe drift self-heals: a clean, detached HEAD that holds no unique
#     commits (it is an ancestor of origin/<default>) and whose <default> is free
#     to check out is re-attached and then fast-forwarded ("recovered:").
#   - every other off-default state is left untouched and reported as a loud,
#     quantified "STUCK: ... N commits behind ... - needs attention" warning
#     instead of a quiet skip.
# The pre-existing fast-forward / already-current / local-only / no-origin paths
# must be unchanged, and bootstrap must relay the new outcomes as FLEET_SYNC lines.
#
# It also pins the clone-root guard: a plain directory under projects/ resolves,
# through git's upward repository discovery, to the ENCLOSING repository - in a
# firstmate home, the firstmate checkout itself - so it must be skipped by name
# with the enclosing repo left untouched, in both the whole-fleet and
# single-project forms, while a symlinked clone dir still syncs.
#
# It also pins the orphaned .git/packed-refs.lock recovery in the fetch step
# (fetch_with_packed_refs_lock_guard, backed by bin/fm-lock-lib.sh's shared
# staleness proof): a provably-stale lock is retried then removed and the clone
# syncs (with a "recovered:" summary on stdout so a session-start refresh, which
# discards stderr, still surfaces it); a live lock (fake lsof holder) is never
# removed and the sync fails loudly; a live process merely holding the clone
# worktree dir as its cwd also blocks removal (the clone-dir liveness check); a
# transient lock that self-clears is retried without a force-remove; and any
# non-packed-refs.lock fetch failure keeps today's behavior with no retry.
#
# It also pins branch pruning end to end. A gone-upstream branch is pruned by
# default. A task branch pushed from a separate worktree (the no-mistakes shape)
# has no upstream, so it survives unless FM_FLEET_PRUNE_MERGED=1 opts in; then it
# is pruned only on a squash-merge content proof or a head that contains it of a
# PR merged into main. A PR merged into another base keeps the branch. Unpushed work, the checked-out branch, a branch with a worktree, and the
# default branch always survive, and FM_FLEET_PRUNE=0 disables every prune.
# The prune runs after the fast-forward, and bootstrap's time-bounded refresh
# keeps the content proof but makes no PR lookups.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-fleet-sync-tests)
HOME_N=0

# --- fixtures ---------------------------------------------------------------

# new_home: fresh isolated FM_HOME with an empty projects/ dir. Each test gets its
# own so the whole-fleet form never sees another test's clones.
new_home() {
  HOME_N=$((HOME_N + 1))
  local h="$TMP_ROOT/home-$HOME_N"
  mkdir -p "$h/projects"
  printf '%s\n' "$h"
}

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# build_pair <home> <name>: create projects/<name>, a clone of a fresh bare origin
# with one commit on main, plus a side "work-<name>" repo wired to that origin for
# advancing it later. Portable branch naming (no init -b) for older git.
build_pair() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0

  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  git clone --quiet "file://$remote_abs" "$clone"
  printf '%s\n' "$clone"
}

# advance_origin <home> <name> <msg>: push one more commit to <name>'s origin via
# its work repo, so the clone (until it fetches) is one commit behind origin/main.
advance_origin() {
  local home=$1 name=$2 msg=$3 work
  work="$home/work-$name"
  commit_file "$work" file.txt "$msg" "$msg"
  git -C "$work" push -q origin main
}

head_sha() { git -C "$1" rev-parse HEAD; }

# run_sync <home> [args...]: run fleet-sync against an isolated home, stdout only.
run_sync() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>/dev/null
}

# build_enclosing_home <name>: an FM_HOME that is itself nested inside another git
# repository - firstmate's own layout, where projects/ sits inside the firstmate
# checkout. The enclosing repo is a clean clone of a bare origin that is one commit
# ahead, so a sync that walked git discovery UP out of projects/<dir> would find a
# fast-forward available and visibly take it. Echoes the enclosing repo, which is
# also the home. Its work tree is left pristine so the only thing under projects/
# is what the test puts there.
build_enclosing_home() {
  local name=$1 root work remote enclosing remote_abs
  root="$TMP_ROOT/enclosing-$name"
  work="$root/work"
  remote="$root/remote.git"
  enclosing="$root/enclosing"
  mkdir -p "$root"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  printf '/projects/\n' > "$work/.gitignore"
  git -C "$work" add .gitignore
  commit_file "$work" AGENTS.md v0 C0

  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  git clone --quiet "file://$remote_abs" "$enclosing"
  commit_file "$work" AGENTS.md v1 C1
  git -C "$work" push -q origin main

  mkdir -p "$enclosing/projects"
  printf '%s\n' "$enclosing"
}

# --- packed-refs.lock fixtures ----------------------------------------------

# build_packed_prunable <home> <name>: like build_pair, but the clone has PACKED
# refs plus a local `feature` branch tracking a since-deleted origin/feature, so a
# fetch --prune must rewrite packed-refs - which an orphaned .git/packed-refs.lock
# blocks with Git's "Unable to create '...packed-refs.lock': File exists". origin/main
# is advanced by one commit so a successful sync fast-forwards. Echoes the clone path.
build_packed_prunable() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main
  git -C "$work" push -q origin main:refs/heads/feature

  git clone --quiet "file://$remote_abs" "$clone"
  git -C "$clone" branch -q feature origin/feature
  commit_file "$work" file.txt v1 C1
  git -C "$work" push -q origin main
  git -C "$work" push -q origin --delete feature
  git -C "$clone" pack-refs --all
  printf '%s\n' "$clone"
}

plant_packed_refs_lock() { : > "$1/.git/packed-refs.lock"; }

# lsof shims mirror tests/fm-teardown.test.sh: no-holder (provably free), a live
# holder, and an lsof error. Written into a per-home fakebin/ prepended to PATH.
lsof_no_holder() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$1/lsof"
}
lsof_live_holder() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$1/lsof"
}

# lsof shim: a holder ONLY for $FLEET_TEST_LIVE_DIR (a live `git -C <clone>` keeping
# its cwd there), and no holder of the lock file itself - the exact window the
# clone-dir liveness check must cover.
lsof_holds_only_live_dir() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
target=
for a in "$@"; do case "$a" in --|-*) ;; *) target=$a ;; esac; done
[ -n "${FLEET_TEST_LIVE_DIR:-}" ] && [ "$target" = "$FLEET_TEST_LIVE_DIR" ] && exit 0
exit 1
SH
  chmod +x "$1/lsof"
}

# git shim: fail the FIRST `fetch` with the packed-refs.lock signature and drop
# the lock (simulating the dying ref-rewrite finishing), then delegate every
# later call - including the retried fetch - to the real git so the sync completes.
git_transient_packed_refs_lock() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=; is_fetch=0
for a in "$@"; do [ "$a" = fetch ] && is_fetch=1; done
prev=
for a in "$@"; do [ "$prev" = -C ] && dir=$a; prev=$a; done
if [ "$is_fetch" = 1 ]; then
  n=$(cat "${GIT_FETCH_COUNTER:?}" 2>/dev/null || echo 0); n=$(( n + 1 ))
  printf '%s\n' "$n" > "$GIT_FETCH_COUNTER"
  if [ "$n" -eq 1 ]; then
    lock="$dir/.git/packed-refs.lock"
    echo "error: could not delete reference refs/remotes/origin/feature: Unable to create '$lock': File exists." >&2
    rm -f "$lock"
    exit 1
  fi
fi
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

# run_sync_guarded <home> <fakebin> <outfile> <errfile> [args...]: run fleet-sync
# with the fakebin on PATH and stdout/stderr captured separately. Per-test knobs
# (FM_FLEET_SYNC_PACKED_REFS_LOCK_*, GIT_FETCH_COUNTER) are read from the caller's
# exported environment.
run_sync_guarded() {
  local home=$1 fakebin=$2 outf=$3 errf=$4 realgit
  shift 4
  realgit=$(command -v git)
  PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$realgit" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-fleet-sync.sh" "$@" >"$outf" 2>"$errf"
}

# --- tests ------------------------------------------------------------------

test_detached_clean_ancestor_recovers() {
  local home clone out before after
  home=$(new_home)
  clone=$(build_pair "$home" alpha)
  advance_origin "$home" alpha C1
  before=$(head_sha "$clone")
  # Detach at the clone's main (C0), an ancestor of the now-advanced origin/main.
  git -C "$clone" checkout --detach --quiet

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "alpha: recovered: re-attached main, synced" "detached-clean-ancestor reports recovered"
  assert_not_contains "$out" "STUCK" "recovered case is not flagged STUCK"
  [ "$(git -C "$clone" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "expected re-attach to main, HEAD still detached"
  after=$(head_sha "$clone")
  [ "$after" != "$before" ] || fail "expected fast-forward after re-attach, HEAD unchanged"
  [ "$after" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "expected HEAD at origin/main after recovery"
  pass "detached clean ancestor is re-attached and fast-forwarded (recovered)"
}

test_detached_unique_commit_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" beta)
  git -C "$clone" checkout --detach --quiet
  commit_file "$clone" extra.txt unique "local unique work"
  before=$(head_sha "$clone")
  advance_origin "$home" beta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta: STUCK:" "detached-with-unique-commit reports STUCK"
  assert_contains "$out" "unique commits" "STUCK names the unique-commit state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "unique-commit case is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "expected unique-commit detached HEAD left untouched"
  pass "detached HEAD with unique commits is reported STUCK and left untouched"
}

test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched() {
  local home clone out before local_main
  home=$(new_home)
  clone=$(build_pair "$home" beta-local-default)
  commit_file "$clone" local.txt local "local divergent main commit"
  local_main=$(git -C "$clone" rev-parse main)
  git -C "$clone" checkout --detach --quiet HEAD^
  before=$(head_sha "$clone")
  advance_origin "$home" beta-local-default C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta-local-default: STUCK:" "diverged local default reports STUCK"
  assert_contains "$out" "local main diverged from origin/main" "STUCK names the unsafe local default"
  assert_not_contains "$out" "recovered" "diverged local default is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "detached HEAD was moved"
  ! git -C "$clone" symbolic-ref -q HEAD >/dev/null || fail "clone re-attached to local default"
  [ "$(git -C "$clone" rev-parse main)" = "$local_main" ] || fail "local default branch was moved"
  pass "detached clean ancestor with diverged local default is reported STUCK and left untouched"
}

test_dirty_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" gamma)
  advance_origin "$home" gamma C1
  before=$(head_sha "$clone")
  printf 'uncommitted edit\n' >> "$clone/file.txt"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "gamma: STUCK:" "dirty clone reports STUCK"
  assert_contains "$out" "uncommitted changes" "STUCK names the dirty state"
  assert_contains "$out" "1 commits behind origin/main" "STUCK quantifies how far behind"
  [ "$(head_sha "$clone")" = "$before" ] || fail "dirty clone HEAD was moved"
  grep -q "uncommitted edit" "$clone/file.txt" || fail "dirty working-tree change was discarded"
  pass "dirty working tree is reported STUCK and left untouched"
}

test_non_default_branch_is_stuck_untouched() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" delta)
  git -C "$clone" checkout -q -b feature
  advance_origin "$home" delta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "delta: STUCK: on branch feature" "non-default branch reports STUCK with branch name"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "named branch is never auto-changed"
  [ "$(git -C "$clone" symbolic-ref --short HEAD)" = "feature" ] || fail "named branch checkout was changed"
  pass "non-default named branch is reported STUCK and left untouched"
}

test_diverged_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" epsilon)
  # Local main gains its own commit; origin advances down a different line.
  commit_file "$clone" local.txt local "local divergent commit"
  before=$(head_sha "$clone")
  advance_origin "$home" epsilon C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "epsilon: STUCK:" "diverged clone reports STUCK"
  assert_contains "$out" "diverged main" "STUCK names the diverged state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  [ "$(head_sha "$clone")" = "$before" ] || fail "diverged clone was moved"
  pass "diverged default branch is reported STUCK and left untouched"
}

test_on_default_clean_behind_fast_forwards() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" zeta)
  advance_origin "$home" zeta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "zeta: synced" "on-default clean behind fast-forwards as before"
  assert_not_contains "$out" "recovered" "ordinary fast-forward is not labelled recovered"
  assert_not_contains "$out" "STUCK" "ordinary fast-forward is not flagged STUCK"
  [ "$(head_sha "$clone")" = "$(git -C "$clone" rev-parse origin/main)" ] || fail "clone was not fast-forwarded"
  pass "on-default clean behind clone still fast-forwards"
}

test_already_current_unchanged() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" eta)
  before=$(head_sha "$clone")

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "eta: already current" "already-current clone reports unchanged"
  assert_not_contains "$out" "STUCK" "already-current is not flagged STUCK"
  assert_not_contains "$out" "recovered" "already-current is not labelled recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "already-current clone was moved"
  pass "already-current clone is reported unchanged"
}

test_no_origin_skipped() {
  local home clone out
  home=$(new_home)
  clone="$home/projects/theta"
  git init -q "$clone"
  git -C "$clone" symbolic-ref HEAD refs/heads/main
  commit_file "$clone" file.txt v0 C0

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "theta: skipped: no origin remote" "no-origin clone is skipped as before"
  assert_not_contains "$out" "STUCK" "no-origin skip is not escalated to STUCK"
  pass "no-origin clone is skipped (benign), not flagged STUCK"
}

test_local_only_skipped() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" iota)
  advance_origin "$home" iota C1
  mkdir -p "$home/data"
  printf -- '- iota [local-only] - test project (added 2026-06-27)\n' > "$home/data/projects.md"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "iota: skipped: local-only project" "local-only clone is skipped as before"
  assert_not_contains "$out" "STUCK" "local-only skip is not escalated to STUCK"
  pass "local-only clone is skipped (benign), not flagged STUCK"
}

# A registry entry the parser refuses resolves to no posture at all, so sync must
# skip the clone rather than fall back to the default posture: reading a refusal
# as "no-mistakes" is how a local-only clone would be fetched and fast-forwarded.
test_unresolvable_registry_posture_skipped() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" omicron)
  advance_origin "$home" omicron C1
  before=$(head_sha "$clone")
  mkdir -p "$home/data"
  printf -- '- omicron [local-only forge=githb] - test project (added 2026-06-27)\n' > "$home/data/projects.md"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "omicron: skipped: registry entry does not resolve to a delivery posture" \
    "a refused registry entry was not reported as a skip"
  assert_not_contains "$out" "STUCK" "a refused registry entry was escalated to STUCK"
  [ "$(head_sha "$clone")" = "$before" ] || fail "a clone whose registry entry was refused was still fast-forwarded"
  pass "a clone whose registry entry the parser refuses is skipped, never synced on the default posture"
}

test_single_project_by_bare_name_resolves() {
  local home out
  home=$(new_home)
  build_pair "$home" kappa >/dev/null
  advance_origin "$home" kappa C1

  out=$(run_sync "$home" "kappa")

  assert_contains "$out" "kappa: synced" "bare project name resolves against the home's projects dir"
  pass "single-project form accepts a bare project name"
}

test_single_project_by_bare_name_ignores_cwd_shadow() {
  local home cwd out
  home=$(new_home)
  build_pair "$home" mu >/dev/null
  advance_origin "$home" mu C1
  cwd="$home/shadow"
  mkdir -p "$cwd/mu"

  out=$(cd "$cwd" && run_sync "$home" "mu")

  assert_contains "$out" "mu: synced" "bare project name prefers the home's projects dir"
  assert_not_contains "$out" "skipped: not a git repo" "bare project name ignores a cwd shadow directory"
  pass "single-project bare name resolution is not cwd-sensitive"
}

test_single_project_by_projects_relative_name_resolves() {
  local home out
  home=$(new_home)
  build_pair "$home" lambda >/dev/null
  advance_origin "$home" lambda C1

  out=$(run_sync "$home" "projects/lambda")

  assert_contains "$out" "lambda: synced" "projects/<name> form resolves against the home's projects dir"
  pass "single-project form accepts a projects/<name> relative name"
}

test_single_project_by_projects_relative_name_ignores_cwd_shadow() {
  local home cwd out
  home=$(new_home)
  build_pair "$home" nu >/dev/null
  advance_origin "$home" nu C1
  cwd="$home/shadow"
  mkdir -p "$cwd/projects/nu"

  out=$(cd "$cwd" && run_sync "$home" "projects/nu")

  assert_contains "$out" "nu: synced" "projects/<name> form prefers the home's projects dir"
  assert_not_contains "$out" "skipped: not a git repo" "projects/<name> form ignores a cwd shadow directory"
  pass "single-project projects/<name> resolution is not cwd-sensitive"
}

test_single_project_unresolvable_name_still_skips() {
  local home out
  home=$(new_home)

  out=$(run_sync "$home" "does-not-exist")

  assert_contains "$out" "skipped: not a directory" "an unresolvable name still hits the existing not-a-directory skip"
  pass "single-project form leaves a genuinely bad name unresolved"
}

test_whole_fleet_form() {
  local home behind current out
  home=$(new_home)
  behind=$(build_pair "$home" fleet-behind)
  advance_origin "$home" fleet-behind C1
  current=$(build_pair "$home" fleet-current)

  # Whole-fleet form: no project-dir argument.
  out=$(run_sync "$home")

  assert_contains "$out" "fleet-behind: synced" "whole-fleet form syncs a behind clone"
  assert_contains "$out" "fleet-current: already current" "whole-fleet form reports a current clone"
  : "$behind $current"
  pass "whole-fleet form processes every clone under projects/"
}

test_bootstrap_relays_recovered_and_stuck() {
  local home stuck rec out
  home=$(new_home)
  # A clone we will leave STUCK (dirty), and one that self-heals (detached-clean-ancestor).
  stuck=$(build_pair "$home" stuck-clone)
  advance_origin "$home" stuck-clone C1
  printf 'dirty\n' >> "$stuck/file.txt"
  rec=$(build_pair "$home" rec-clone)
  advance_origin "$home" rec-clone C1
  git -C "$rec" checkout --detach --quiet

  # Full bootstrap: no state/ dir -> secondmate sync no-ops; no .env -> X mode off.
  # We only assert the fleet-sync relay lines; other detect lines are irrelevant.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "FLEET_SYNC: stuck-clone: STUCK:" "bootstrap relays the STUCK outcome"
  assert_contains "$out" "FLEET_SYNC: rec-clone: recovered:" "bootstrap relays the recovered outcome"
  pass "bootstrap relays recovered: and STUCK: fleet-sync outcomes"
}

# --- packed-refs.lock guard tests -------------------------------------------

test_orphaned_stale_packed_refs_lock_recovers() {
  local home fakebin clone out err
  home=$(new_home)
  fakebin="$home/fb-lockstale"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" lockstale)
  plant_packed_refs_lock "$clone"
  lsof_no_holder "$fakebin"           # provably no live holder
  out="$home/out-lockstale"; err="$home/err-lockstale"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" lockstale
  set -e

  assert_grep "removed provably-stale packed-refs lock" "$err" \
    "stale lock: guard did not force-remove the provably-stale lock"
  assert_grep "fetch succeeded after stale packed-refs lock cleanup" "$err" \
    "stale lock: fetch did not succeed after cleanup"
  assert_contains "$(cat "$out")" "lockstale: synced" "stale lock: clone did not sync after recovery"
  assert_grep "recovered: removed a stale packed-refs lock" "$out" \
    "stale lock: recovery summary not emitted on stdout (bootstrap relays stdout, discards stderr)"
  assert_absent "$clone/.git/packed-refs.lock" "stale lock: lock should be gone after removal"
  [ "$(git -C "$clone" rev-parse HEAD)" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "stale lock: clone HEAD not at origin/main after recovery"
  pass "orphaned provably-stale packed-refs.lock is cleared and the clone syncs"
}

test_live_packed_refs_lock_is_never_removed() {
  local home fakebin clone out err before
  home=$(new_home)
  fakebin="$home/fb-locklive"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" locklive)
  plant_packed_refs_lock "$clone"
  lsof_live_holder "$fakebin"         # a live process holds the lock/.git open
  before=$(head_sha "$clone")
  out="$home/out-locklive"; err="$home/err-locklive"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locklive
  set -e

  assert_grep "is not provably stale" "$err" "live lock: guard did not explain the refusal"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "live lock: guard force-removed a live lock"
  assert_contains "$(cat "$out")" "locklive: skipped: fetch failed" "live lock: fleet-sync did not skip"
  assert_present "$clone/.git/packed-refs.lock" "live lock: lock must never be removed"
  [ "$(head_sha "$clone")" = "$before" ] || fail "live lock: clone was advanced despite the refusal"
  pass "a live packed-refs.lock is never removed and the sync fails loudly"
}

test_live_git_cwd_in_clone_dir_blocks_removal() {
  local home fakebin clone out err before
  home=$(new_home)
  fakebin="$home/fb-lockcwd"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" lockcwd)
  plant_packed_refs_lock "$clone"
  # Nobody holds the lock file, but a live process holds the clone worktree as its
  # cwd - the narrow race where git closed packed-refs.lock but has not yet exited.
  lsof_holds_only_live_dir "$fakebin"
  before=$(head_sha "$clone")
  out="$home/out-lockcwd"; err="$home/err-lockcwd"

  set +e
  FLEET_TEST_LIVE_DIR="$clone" \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" lockcwd
  set -e

  assert_grep "is not provably stale" "$err" "clone-cwd holder: guard did not refuse"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "clone-cwd holder: guard removed a lock while a live process held the clone dir"
  assert_present "$clone/.git/packed-refs.lock" "clone-cwd holder: lock must not be removed"
  [ "$(head_sha "$clone")" = "$before" ] || fail "clone-cwd holder: clone was advanced despite the refusal"
  pass "a live process holding the clone worktree dir blocks lock removal (clone-dir liveness)"
}

test_transient_packed_refs_lock_self_clears() {
  local home fakebin clone out err counter
  home=$(new_home)
  fakebin="$home/fb-locktrans"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" locktrans)
  plant_packed_refs_lock "$clone"
  git_transient_packed_refs_lock "$fakebin"   # fail once + drop lock, then real git
  counter="$home/git-fetch-count"; : > "$counter"
  out="$home/out-locktrans"; err="$home/err-locktrans"

  set +e
  GIT_FETCH_COUNTER="$counter" \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locktrans
  set -e

  assert_grep "cleared on its own" "$err" "transient lock: guard did not report the self-clear"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "transient lock: guard force-removed a lock that only needed patience"
  assert_contains "$(cat "$out")" "locktrans: synced" "transient lock: clone did not sync after self-clear"
  assert_grep "recovered: packed-refs lock cleared on its own" "$out" \
    "transient lock: recovery summary not emitted on stdout"
  assert_absent "$clone/.git/packed-refs.lock" "transient lock: lock should be gone after self-clear"
  pass "a transient packed-refs.lock that self-clears is retried without a force-remove"
}

test_non_clone_dir_never_syncs_the_enclosing_repo() {
  local home before out after
  home=$(build_enclosing_home nonclone)
  # A worktree container, not a clone: the repo is one level BELOW it.
  mkdir -p "$home/projects/not-a-clone/wt"
  before=$(head_sha "$home")

  out=$(run_sync "$home")
  after=$(head_sha "$home")

  assert_contains "$out" "not-a-clone: skipped: not a clone root" \
    "a non-repo directory under projects/ must be skipped by name"
  assert_not_contains "$out" "not-a-clone: synced" \
    "a non-repo directory must never be reported as a synced project"
  [ "$before" = "$after" ] || \
    fail "fleet-sync fast-forwarded the enclosing repo ($before -> $after) under a project's label"
  pass "a non-repo directory under projects/ never fast-forwards the enclosing repo"
}

test_non_clone_dir_named_directly_never_syncs_the_enclosing_repo() {
  local home before out after
  home=$(build_enclosing_home nonclonedirect)
  mkdir -p "$home/projects/not-a-clone"
  before=$(head_sha "$home")

  out=$(run_sync "$home" not-a-clone)
  after=$(head_sha "$home")

  assert_contains "$out" "not-a-clone: skipped: not a clone root" \
    "the single-project form must apply the same clone-root guard"
  [ "$before" = "$after" ] || \
    fail "the single-project form fast-forwarded the enclosing repo ($before -> $after)"
  pass "the single-project form also refuses a directory that is not its own clone root"
}

test_symlinked_clone_still_syncs() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" sigma)
  advance_origin "$home" sigma C1
  # A symlinked clone dir is a real clone root and must not be mistaken for a
  # directory nested in someone else's repo.
  mv "$clone" "$home/real-sigma"
  ln -s "$home/real-sigma" "$clone"

  out=$(run_sync "$home")

  assert_contains "$out" "sigma: synced" "a symlinked clone must still fast-forward"
  pass "the clone-root guard accepts a symlinked clone directory"
}

test_clone_root_named_by_another_spelling_still_syncs() {
  local home clone fakebin alias out
  home=$(new_home)
  clone=$(build_pair "$home" tau)
  advance_origin "$home" tau C1
  fakebin="$home/fb-rootalias"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  # git reports the clone's own root through an alias that is the same directory
  # but a different string, as it does on a case-insensitive volume when the home
  # was recorded with other casing. A symlink stands in for the case difference so
  # the test also holds on a case-sensitive filesystem.
  alias="$home/root-alias"
  ln -s "$clone" "$alias"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
case " $* " in
  *" rev-parse --show-toplevel "*) printf '%s\n' "${ROOT_ALIAS_FOR_TEST:?}"; exit 0 ;;
esac
exec "$real" "$@"
SH
  chmod +x "$fakebin/git"
  out="$home/out"; err="$home/err"

  ROOT_ALIAS_FOR_TEST="$alias" run_sync_guarded "$home" "$fakebin" "$out" "$err" tau || true

  assert_contains "$(cat "$out")" "tau: synced" \
    "a clone root that git names with another spelling must still fast-forward"
  assert_not_contains "$(cat "$out")" "not a clone root" \
    "the guard must compare the directory itself, not the spelling of its path"
  pass "the clone-root guard accepts a root named by a different spelling of the same directory"
}

test_non_signature_fetch_failure_is_not_retried() {
  local home fakebin clone out err
  home=$(new_home)
  fakebin="$home/fb-locknonsig"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_pair "$home" locknonsig)
  advance_origin "$home" locknonsig C1
  git -C "$clone" remote set-url origin "file://$home/remotes/does-not-exist.git"
  out="$home/out-locknonsig"; err="$home/err-locknonsig"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locknonsig
  set -e

  assert_contains "$(cat "$out")" "locknonsig: skipped: fetch failed" "non-signature: fleet-sync did not report the fetch failure"
  assert_no_grep "waiting" "$err" "non-signature: a non-lock failure was wrongly retried"
  assert_no_grep "packed-refs lock" "$err" "non-signature: a non-lock failure entered the lock guard"
  pass "a non-packed-refs.lock fetch failure keeps today's behavior (no retry)"
}

# --- landed-branch prune fixtures --------------------------------------------

# push_task_branch <home> <name> <branch> <file> <content>: the no-mistakes shape.
# The task branch is created in a separate worktree of the clone and pushed from
# there without -u, so the clone's local branch has NO upstream and can never read
# "[gone]". The worktree is then removed, as teardown does after a merge, leaving
# only the local branch. Echoes the pushed tip.
push_task_branch() {
  local home=$1 name=$2 branch=$3 file=$4 content=$5 clone wt tip
  clone="$home/projects/$name"
  wt="$home/wt-$name-${branch//\//-}"
  git -C "$clone" worktree add -q --no-track -b "$branch" "$wt" origin/main
  commit_file "$wt" "$file" "$content" "task $branch"
  git -C "$wt" push -q origin "$branch"
  tip=$(git -C "$wt" rev-parse HEAD)
  git -C "$clone" worktree remove "$wt"
  printf '%s\n' "$tip"
}

# squash_merge_and_delete <home> <name> <branch> <file> <content>: land the task as
# a squash merge on origin/main (one new commit, not the branch's own) and delete
# the remote branch, as a forge does when the PR merges.
squash_merge_and_delete() {
  local home=$1 name=$2 branch=$3 file=$4 content=$5 work
  work="$home/work-$name"
  git -C "$work" pull -q --ff-only origin main
  commit_file "$work" "$file" "$content" "squash $branch"
  git -C "$work" push -q origin main
  git -C "$work" push -q origin --delete "$branch"
}

# prune_fakebin <home> <tag> [merged-pr-head] [merged-pr-base]: gh and gh-axi
# stubs. With no head, every lookup fails, as with no forge or a network error.
# With a head, PR 7 for any branch is merged into <merged-pr-base> (default main)
# with that head. Every PR lookup appends "<cmd> <args>
# <local main sha>" to <fakebin>/pr-calls.log, run from the clone it queries.
prune_fakebin() {
  local home=$1 tag=$2 head=${3:-} base=${4:-main} fakebin log
  fakebin="$home/fb-$tag"
  log="$fakebin/pr-calls.log"
  rm -rf "$fakebin"; mkdir -p "$fakebin"
  if [ -z "$head" ]; then
    printf '#!/usr/bin/env bash\n%s\necho "error: unavailable" >&2\nexit 1\n' "$(pr_call_logger gh-axi "$log")" > "$fakebin/gh-axi"
    printf '#!/usr/bin/env bash\n%s\necho "error: unavailable" >&2\nexit 1\n' "$(pr_call_logger gh "$log")" > "$fakebin/gh"
  else
    {
      printf '#!/usr/bin/env bash\n%s\n' "$(pr_call_logger gh-axi "$log")"
      cat <<'SH'
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
esac
exit 1
SH
    } > "$fakebin/gh-axi"
    {
      printf '#!/usr/bin/env bash\n%s\n' "$(pr_call_logger gh "$log")"
      cat <<SH
case "\${1:-} \${2:-}" in
  "pr view") printf '%s\t%s\t%s\t%s\n' 'MERGED' '$head' 'https://github.com/example/repo/pull/7' '$base' ; exit 0 ;;
esac
exit 1
SH
    } > "$fakebin/gh"
  fi
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

# pr_call_logger <cmd> <log>: the stub line that records a PR lookup. Bootstrap
# runs `gh auth status` itself, so only `pr` calls count.
pr_call_logger() {
  local cmd=$1 log=$2
  cat <<SH
[ "\${1:-}" != pr ] || printf '%s\\n' "$cmd \$* \$(git rev-parse --verify -q refs/heads/main)" >> '$log'
SH
}

# run_sync_prune <home> <fakebin> [args...]: run fleet-sync with the stubs first on
# PATH, stdout only. Callers set FM_FLEET_PRUNE / FM_FLEET_PRUNE_MERGED.
run_sync_prune() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>/dev/null
}

branch_exists() { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }

# --- landed-branch prune tests -------------------------------------------------

test_gone_upstream_branch_still_pruned_by_default() {
  local home clone fakebin out
  home=$(new_home)
  clone=$(build_pair "$home" gone)
  fakebin=$(prune_fakebin "$home" gone)
  git -C "$clone" checkout -q -b fm/tracked
  commit_file "$clone" t.txt t "tracked work"
  git -C "$clone" push -q -u origin fm/tracked
  git -C "$clone" checkout -q main
  squash_merge_and_delete "$home" gone fm/tracked t.txt t

  out=$(run_sync_prune "$home" "$fakebin" "$clone")

  assert_contains "$out" "gone: pruned fm/tracked" "gone-upstream prune should still run by default"
  if branch_exists "$clone" fm/tracked; then fail "gone-upstream branch should have been pruned"; fi
  pass "a branch whose upstream is gone is still pruned by default"
}

test_landed_no_upstream_branch_kept_without_opt_in() {
  local home clone fakebin out
  home=$(new_home)
  clone=$(build_pair "$home" optout)
  fakebin=$(prune_fakebin "$home" optout)
  push_task_branch "$home" optout fm/task a.txt a >/dev/null
  squash_merge_and_delete "$home" optout fm/task a.txt a
  [ -z "$(git -C "$clone" for-each-ref --format='%(upstream)' refs/heads/fm/task)" ] \
    || fail "fixture: the task branch must have no upstream"

  out=$(run_sync_prune "$home" "$fakebin" "$clone")

  assert_not_contains "$out" "pruned fm/task" "the landed-branch prune must be opt-in"
  branch_exists "$clone" fm/task || fail "without FM_FLEET_PRUNE_MERGED=1 the branch must survive"
  pass "a landed branch with no upstream is kept when the landed-branch prune is not opted in"
}

test_squash_merged_no_upstream_branch_pruned_when_opted_in() {
  local home clone fakebin out
  home=$(new_home)
  clone=$(build_pair "$home" squash)
  fakebin=$(prune_fakebin "$home" squash)
  push_task_branch "$home" squash fm/task a.txt a >/dev/null
  squash_merge_and_delete "$home" squash fm/task a.txt a

  out=$(FM_FLEET_PRUNE_MERGED=1 run_sync_prune "$home" "$fakebin" "$clone")

  assert_contains "$out" "squash: pruned fm/task (landed, no upstream)" "opted-in prune should report the landed branch"
  if branch_exists "$clone" fm/task; then fail "a squash-merged branch with no upstream should be pruned when opted in"; fi
  [ "$(git -C "$clone" symbolic-ref --short HEAD)" = main ] || fail "the clone should stay on main"
  pass "a squash-merged branch with no upstream is pruned when opted in (content proof)"
}

test_merged_pr_no_upstream_branch_pruned_when_opted_in() {
  local home clone fakebin out tip
  home=$(new_home)
  clone=$(build_pair "$home" mergedpr)
  tip=$(push_task_branch "$home" mergedpr fm/task file.txt task-edit)
  squash_merge_and_delete "$home" mergedpr fm/task file.txt task-edit
  # A later main commit rewrites the same line, so the content proof conflicts and
  # only the merged-PR proof can show the branch landed.
  advance_origin "$home" mergedpr later-edit
  git -C "$clone" fetch -q origin
  if git -C "$clone" merge-tree --write-tree origin/main fm/task >/dev/null 2>&1; then
    fail "fixture: the content proof must conflict so only the merged-PR proof applies"
  fi
  fakebin=$(prune_fakebin "$home" mergedpr "$tip")

  out=$(FM_FLEET_PRUNE_MERGED=1 run_sync_prune "$home" "$fakebin" "$clone")

  assert_contains "$out" "mergedpr: pruned fm/task (landed, no upstream)" "merged-PR proof should prune the branch"
  if branch_exists "$clone" fm/task; then fail "a branch contained in a merged PR head should be pruned when opted in"; fi
  [ -s "$fakebin/pr-calls.log" ] || fail "fixture: the merged-PR proof should have looked up the PR"
  if grep -vq " $(git -C "$clone" rev-parse origin/main)\$" "$fakebin/pr-calls.log"; then
    fail "every PR lookup should run after main is fast-forwarded: $(cat "$fakebin/pr-calls.log")"
  fi
  pass "a branch contained in a merged PR head is pruned when opted in (merged-PR proof)"
}

test_bootstrap_refresh_prunes_on_content_proof_without_pr_lookups() {
  local home clone fakebin out tip
  home=$(new_home)
  clone=$(build_pair "$home" bootprune)
  push_task_branch "$home" bootprune fm/squashed a.txt a >/dev/null
  squash_merge_and_delete "$home" bootprune fm/squashed a.txt a
  # Only the merged-PR proof covers this branch, because a later main commit makes
  # its content proof conflict.
  tip=$(push_task_branch "$home" bootprune fm/viapr file.txt task-edit)
  squash_merge_and_delete "$home" bootprune fm/viapr file.txt task-edit
  advance_origin "$home" bootprune later-edit
  fakebin=$(prune_fakebin "$home" bootprune "$tip")

  out=$(PATH="$fakebin:$PATH" FM_FLEET_PRUNE_MERGED=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_not_contains "$out" "bootstrap refresh timed out" "the bounded refresh should finish"
  if [ -s "$fakebin/pr-calls.log" ]; then
    fail "bootstrap's bounded refresh must make no PR lookups: $(cat "$fakebin/pr-calls.log")"
  fi
  if branch_exists "$clone" fm/squashed; then fail "the content proof should still prune under bootstrap"; fi
  branch_exists "$clone" fm/viapr || fail "a branch only the merged-PR proof covers must survive bootstrap"
  [ "$(git -C "$clone" rev-parse main)" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "bootstrap should still fast-forward the clone"
  pass "bootstrap's bounded refresh prunes on the content proof and makes no PR lookups"
}

test_pr_merged_into_non_default_base_keeps_branch() {
  local home clone fakebin out tip
  home=$(new_home)
  clone=$(build_pair "$home" stacked)
  # A stacked task PR merged into its parent task branch, whose own PR never
  # merged, so the work never reached main and the content proof fails.
  tip=$(push_task_branch "$home" stacked fm/child b.txt child)
  fakebin=$(prune_fakebin "$home" stacked "$tip" fm/parent)

  out=$(FM_FLEET_PRUNE_MERGED=1 run_sync_prune "$home" "$fakebin" "$clone")

  [ -s "$fakebin/pr-calls.log" ] || fail "fixture: the merged-PR proof should have looked up the PR"
  assert_not_contains "$out" "pruned fm/child" "a PR merged into a non-default base must not prune"
  branch_exists "$clone" fm/child || fail "a branch whose PR merged into another task branch must survive"
  pass "a branch whose PR merged into a non-default base survives the opted-in prune"
}

test_unpushed_commit_without_worktree_survives() {
  local home clone fakebin out tip wt
  home=$(new_home)
  clone=$(build_pair "$home" parked)
  # A parked task: its pushed work merged, then it gained one more commit that was
  # never pushed, and its worktree was recycled. The merged PR still reports the
  # old head, so neither proof covers the new commit.
  tip=$(push_task_branch "$home" parked fm/task a.txt a)
  squash_merge_and_delete "$home" parked fm/task a.txt a
  wt="$home/wt-parked-again"
  git -C "$clone" worktree add -q "$wt" fm/task
  commit_file "$wt" b.txt unpushed "unpushed parked work"
  git -C "$clone" worktree remove "$wt"
  # A never-pushed branch with no PR at all, too.
  git -C "$clone" branch fm/local main
  wt="$home/wt-parked-local"
  git -C "$clone" worktree add -q "$wt" fm/local
  commit_file "$wt" c.txt local "local-only work"
  git -C "$clone" worktree remove "$wt"
  fakebin=$(prune_fakebin "$home" parked "$tip")

  out=$(FM_FLEET_PRUNE_MERGED=1 run_sync_prune "$home" "$fakebin" "$clone")

  assert_not_contains "$out" "pruned" "no branch holding unpushed work may be pruned"
  branch_exists "$clone" fm/task || fail "a merged branch with a later unpushed commit must survive"
  branch_exists "$clone" fm/local || fail "a never-pushed branch with no PR must survive"
  pass "a branch with an unpushed commit and no worktree survives the opted-in prune"
}

test_checked_out_landed_branch_survives() {
  local home clone fakebin out
  home=$(new_home)
  clone=$(build_pair "$home" checkedout)
  fakebin=$(prune_fakebin "$home" checkedout)
  push_task_branch "$home" checkedout fm/task a.txt a >/dev/null
  squash_merge_and_delete "$home" checkedout fm/task a.txt a
  git -C "$clone" checkout -q fm/task

  out=$(FM_FLEET_PRUNE_MERGED=1 run_sync_prune "$home" "$fakebin" "$clone")

  assert_not_contains "$out" "pruned fm/task" "the checked-out branch must never be pruned"
  branch_exists "$clone" fm/task || fail "the checked-out landed branch must survive"
  pass "the checked-out branch survives the opted-in prune"
}

test_landed_branch_with_worktree_survives() {
  local home clone fakebin out wt
  home=$(new_home)
  clone=$(build_pair "$home" withwt)
  fakebin=$(prune_fakebin "$home" withwt)
  push_task_branch "$home" withwt fm/task a.txt a >/dev/null
  squash_merge_and_delete "$home" withwt fm/task a.txt a
  wt="$home/wt-withwt-live"
  git -C "$clone" worktree add -q "$wt" fm/task

  out=$(FM_FLEET_PRUNE_MERGED=1 run_sync_prune "$home" "$fakebin" "$clone")

  assert_not_contains "$out" "pruned fm/task" "a branch with a worktree must never be pruned"
  branch_exists "$clone" fm/task || fail "a landed branch that still has a worktree must survive"
  pass "a branch that still has a worktree survives the opted-in prune"
}

test_default_branch_without_upstream_survives() {
  local home clone fakebin out
  home=$(new_home)
  clone=$(build_pair "$home" defaultnoup)
  fakebin=$(prune_fakebin "$home" defaultnoup)
  advance_origin "$home" defaultnoup C1
  git -C "$clone" branch --unset-upstream main
  git -C "$clone" checkout -q --detach

  out=$(FM_FLEET_PRUNE_MERGED=1 run_sync_prune "$home" "$fakebin" "$clone")

  assert_not_contains "$out" "pruned main" "the default branch must never be pruned"
  branch_exists "$clone" main || fail "the default branch must survive even with no upstream"
  assert_contains "$out" "defaultnoup: recovered: re-attached main, synced" "the detached clone should still re-attach main"
  pass "the default branch with no upstream survives the opted-in prune"
}

test_prune_disabled_keeps_every_branch() {
  local home clone fakebin out
  home=$(new_home)
  clone=$(build_pair "$home" disabled)
  fakebin=$(prune_fakebin "$home" disabled)
  push_task_branch "$home" disabled fm/task a.txt a >/dev/null
  squash_merge_and_delete "$home" disabled fm/task a.txt a
  git -C "$clone" checkout -q -b fm/tracked
  commit_file "$clone" t.txt t "tracked work"
  git -C "$clone" push -q -u origin fm/tracked
  git -C "$clone" checkout -q main
  squash_merge_and_delete "$home" disabled fm/tracked t.txt t

  out=$(FM_FLEET_PRUNE=0 FM_FLEET_PRUNE_MERGED=1 run_sync_prune "$home" "$fakebin" "$clone")

  assert_not_contains "$out" "pruned" "FM_FLEET_PRUNE=0 must disable every prune"
  branch_exists "$clone" fm/task || fail "FM_FLEET_PRUNE=0 must keep the landed no-upstream branch"
  branch_exists "$clone" fm/tracked || fail "FM_FLEET_PRUNE=0 must keep the gone-upstream branch"
  pass "FM_FLEET_PRUNE=0 disables both prunes even when the landed-branch prune is opted in"
}

test_detached_clean_ancestor_recovers
test_detached_unique_commit_is_stuck_untouched
test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched
test_dirty_is_stuck_untouched
test_non_default_branch_is_stuck_untouched
test_diverged_is_stuck_untouched
test_on_default_clean_behind_fast_forwards
test_already_current_unchanged
test_no_origin_skipped
test_local_only_skipped
test_unresolvable_registry_posture_skipped
test_single_project_by_bare_name_resolves
test_single_project_by_bare_name_ignores_cwd_shadow
test_single_project_by_projects_relative_name_resolves
test_single_project_by_projects_relative_name_ignores_cwd_shadow
test_single_project_unresolvable_name_still_skips
test_whole_fleet_form
test_bootstrap_relays_recovered_and_stuck
test_orphaned_stale_packed_refs_lock_recovers
test_live_packed_refs_lock_is_never_removed
test_live_git_cwd_in_clone_dir_blocks_removal
test_transient_packed_refs_lock_self_clears
test_non_signature_fetch_failure_is_not_retried
test_non_clone_dir_never_syncs_the_enclosing_repo
test_non_clone_dir_named_directly_never_syncs_the_enclosing_repo
test_symlinked_clone_still_syncs
test_clone_root_named_by_another_spelling_still_syncs
test_gone_upstream_branch_still_pruned_by_default
test_landed_no_upstream_branch_kept_without_opt_in
test_squash_merged_no_upstream_branch_pruned_when_opted_in
test_merged_pr_no_upstream_branch_pruned_when_opted_in
test_bootstrap_refresh_prunes_on_content_proof_without_pr_lookups
test_pr_merged_into_non_default_base_keeps_branch
test_unpushed_commit_without_worktree_survives
test_checked_out_landed_branch_survives
test_landed_branch_with_worktree_survives
test_default_branch_without_upstream_survives
test_prune_disabled_keeps_every_branch
