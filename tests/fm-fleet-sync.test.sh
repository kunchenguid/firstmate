#!/usr/bin/env bash
# Behavior tests for fm-fleet-sync.sh drift handling.
#
# fm-fleet-sync fast-forwards a clone that is cleanly on its default branch. This
# suite pins its narrowly guarded recoveries on top of that:
#   - a clean, detached HEAD that holds no unique commits (it is an ancestor of
#     origin/<default>) and whose <default> is free to check out is re-attached and
#     then fast-forwarded ("recovered:");
#   - a clean, checked-out default with genuine local/remote divergence but the
#     exact same root tree preserves its old head at a deterministic direct ref
#     before an expected-old atomic update to the freshly fetched remote commit.
# Every other off-default or diverged state is left untouched and reported as a
# loud, quantified "STUCK: ... N commits behind ... - needs attention" warning.
# The pre-existing fast-forward / already-current / local-only / no-origin paths
# must be unchanged, and bootstrap must relay the new outcomes as FLEET_SYNC lines.
#
# It also pins configured fetch mappings and pruning through isolated staged
# fetches, compatibility with Git versions that predate fetch --porcelain, one
# remote fetch session per project, and tag auto-follow behavior.
#
# The orphaned .git/packed-refs.lock recovery in fetched-ref publication
# (fetch_with_packed_refs_lock_guard, backed by bin/fm-lock-lib.sh's shared
# staleness proof): a provably-stale lock is retried then removed and the clone
# syncs (with a "recovered:" summary on stdout so a session-start refresh, which
# discards stderr, still surfaces it); a live lock (fake lsof holder) is never
# removed and the sync fails loudly; a live process merely holding the clone
# worktree dir as its cwd also blocks removal (the clone-dir liveness check); a
# transient lock that self-clears is retried without a force-remove; and any
# non-packed-refs.lock fetch failure keeps today's behavior with no retry.
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

# build_tree_identical_squash_pair <home> <name>: create the motivating graph:
# common C0; local main gains a two-commit chain; origin/main gains one squash
# commit from C0 whose exact root tree equals the local chain's final tree.
build_tree_identical_squash_pair() {
  local home=$1 name=$2 clone work
  clone=$(build_pair "$home" "$name")
  work="$home/work-$name"

  commit_file "$clone" file.txt final-local L1
  commit_file "$clone" final.txt same-tree L2

  printf '%s\n' final-local > "$work/file.txt"
  printf '%s\n' same-tree > "$work/final.txt"
  git -C "$work" add file.txt final.txt
  git -C "$work" commit -qm "squash L1 and L2"
  git -C "$work" push -q origin main
  printf '%s\n' "$clone"
}

head_sha() { git -C "$1" rev-parse HEAD; }
root_tree() { git -C "$1" rev-parse "$2^{tree}"; }
preservation_ref_for() {
  local clone=$1 branch=${2:-main} old=${3:-}
  [ -n "$old" ] || old=$(git -C "$clone" rev-parse "refs/heads/$branch")
  printf 'refs/fm-fleet-sync/squash-preserved/%s/%s\n' "$branch" "$old"
}
preservation_refs() {
  git -C "$1" for-each-ref --format='%(refname)' refs/fm-fleet-sync/squash-preserved
}
git_operation_marker_path() {
  local clone=$1 marker=$2 path
  path=$(git -C "$clone" rev-parse --git-path "$marker")
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$clone" "$path" ;;
  esac
}
install_git_operation_marker() {
  local clone=$1 marker=$2 kind=$3 path
  path=$(git_operation_marker_path "$clone" "$marker")
  if [ "$kind" = directory ]; then
    mkdir -p "$path"
  else
    git -C "$clone" rev-parse HEAD > "$path"
  fi
}

# run_sync <home> [args...]: run fleet-sync against an isolated home, stdout only.
run_sync() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>/dev/null
}

# --- packed-refs.lock fixtures ----------------------------------------------

# build_packed_prunable <home> <name>: like build_pair, but the clone has PACKED
# refs plus a local `feature` branch tracking a since-deleted origin/feature, so
# safe fetched-ref publication must rewrite packed-refs, which an orphaned
# .git/packed-refs.lock blocks with Git's "Unable to create
# '...packed-refs.lock': File exists". origin/main is advanced by one commit so a
# successful sync fast-forwards. Echoes the clone path.
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

git_symbolic_remote_after_staged_fetch() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
is_fetch=0; has_empty_refmap=0
for a in "$@"; do
  [ "$a" = fetch ] && is_fetch=1
  [ "$a" = --refmap= ] && has_empty_refmap=1
done
if [ "$is_fetch" = 1 ] && [ "$has_empty_refmap" = 1 ]; then
  "$real" "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    oid=$("$real" -C "${GIT_RACE_CLONE:?}" rev-parse --verify refs/remotes/origin/main)
    "$real" -C "$GIT_RACE_CLONE" update-ref --no-deref \
      -d refs/remotes/origin/main "$oid"
    "$real" -C "$GIT_RACE_CLONE" symbolic-ref \
      refs/remotes/origin/main refs/heads/main
  fi
  exit "$rc"
fi
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

git_staged_fetch_compatibility_audit() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
is_fetch=0
for a in "$@"; do
  [ "$a" = --porcelain ] && {
    echo "fetch --porcelain is unavailable" >&2
    exit 129
  }
  [ "$a" = ls-remote ] && {
    echo "ls-remote adds an unexpected remote session" >&2
    exit 129
  }
  [ "$a" = fetch ] && is_fetch=1
done
if [ "$is_fetch" = 1 ]; then
  kind=local
  for a in "$@"; do
    [ "$a" = origin ] && kind=remote
  done
  printf 'fetch\t%s\t%s\n' "$kind" "$*" >> "${GIT_FETCH_AUDIT_LOG:?}"
fi
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

git_signal_during_staged_fetch() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
is_fetch=0
stage=
for a in "$@"; do
  [ "$a" = fetch ] && is_fetch=1
  case "$a" in
    --git-dir=*/fm-fleet-sync-fetch.*/repository.git)
      stage=${a#--git-dir=}
      stage=${stage%/repository.git}
      ;;
  esac
done
if [ "$is_fetch" = 1 ] && [ -n "$stage" ]; then
  [ -d "$stage" ] || exit 99
  printf '%s\n' "$stage" >"${GIT_STAGED_FETCH_SIGNAL_MARKER:?}"
  kill "-${GIT_STAGED_FETCH_SIGNAL:?}" "${FLEET_SYNC_SIGNAL_TARGET:?}"
  case "$GIT_STAGED_FETCH_SIGNAL" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
  esac
fi
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

# Refuse the multi-ref expected-old transaction while recording its exact input.
# All other git commands, including preservation-ref creation, delegate unchanged.
git_ref_transaction_refusal() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
is_update=0; is_stdin=0
for a in "$@"; do
  [ "$a" = update-ref ] && is_update=1
  [ "$a" = --stdin ] && is_stdin=1
done
if [ "$is_update" = 1 ] && [ "$is_stdin" = 1 ]; then
  n=$(cat "${GIT_REF_TRANSACTION_COUNTER:?}" 2>/dev/null || echo 0)
  n=$(( n + 1 ))
  printf '%s\n' "$n" > "$GIT_REF_TRANSACTION_COUNTER"
  if [ "$n" -le 2 ]; then
    exec "$real" "$@"
  fi
  : > "${GIT_REF_TRANSACTION_LOG:?}"
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$GIT_REF_TRANSACTION_LOG"
    [ "$line" = prepare ] && break
  done
  echo "simulated expected-old ref transaction refusal" >&2
  exit 1
fi
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

git_ref_transaction_ack_loss() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
is_update=0; is_stdin=0
for a in "$@"; do
  [ "$a" = update-ref ] && is_update=1
  [ "$a" = --stdin ] && is_stdin=1
done
if [ "$is_update" = 1 ] && [ "$is_stdin" = 1 ]; then
  transaction=$(mktemp)
  while IFS= read -r line; do
    [ "$line" = prepare ] && break
    printf '%s\n' "$line" >> "$transaction"
  done
  printf 'prepare: ok\n'
  IFS= read -r command
  [ "$command" = commit ] || { rm -f "$transaction"; exit 1; }
  if grep -F 'update refs/heads/main ' "$transaction" >/dev/null; then
    if [ "${GIT_ACK_LOSS_MODE:?}" = committed ]; then
      "$real" "$@" <"$transaction" >/dev/null 2>&1 \
        || { rc=$?; rm -f "$transaction"; exit "$rc"; }
    fi
    rm -f "$transaction"
    exit 1
  fi
  if "$real" "$@" <"$transaction" >/dev/null 2>&1; then
    rm -f "$transaction"
    printf 'commit: ok\n'
    exit 0
  else
    rc=$?
    rm -f "$transaction"
    exit "$rc"
  fi
fi
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

git_operation_after_preservation() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
is_anchor_check=0
prev=
for a in "$@"; do
  [ "$prev" = cat-file ] && [ "$a" = -e ] && is_anchor_check=1
  prev=$a
done
if [ "$is_anchor_check" = 1 ] && printf '%s\n' "$*" | grep -F 'refs/fm-fleet-sync/squash-preserved/' >/dev/null; then
  "$real" "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    marker=$("$real" -C "${GIT_RACE_CLONE:?}" rev-parse --git-path MERGE_HEAD)
    case "$marker" in /*) ;; *) marker="${GIT_RACE_CLONE:?}/$marker" ;; esac
    "$real" -C "${GIT_RACE_CLONE:?}" rev-parse HEAD > "$marker"
  fi
  exit "$rc"
fi
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

git_symbolic_ref_before_preservation() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
is_check=0
for a in "$@"; do [ "$a" = check-ref-format ] && is_check=1; done
if [ "$is_check" = 1 ]; then
  "$real" "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    oid=$("$real" -C "${GIT_RACE_CLONE:?}" rev-parse --verify "${GIT_SYMBOLIC_RACE_REF:?}^{commit}")
    "$real" -C "$GIT_RACE_CLONE" update-ref --no-deref "$GIT_SYMBOLIC_RACE_TARGET" "$oid" ""
    "$real" -C "$GIT_RACE_CLONE" update-ref --no-deref -d "$GIT_SYMBOLIC_RACE_REF" "$oid"
    "$real" -C "$GIT_RACE_CLONE" symbolic-ref "$GIT_SYMBOLIC_RACE_REF" "$GIT_SYMBOLIC_RACE_TARGET"
  fi
  exit "$rc"
fi
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

git_symbolic_preservation_creation_race() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
is_anchor_check=0
for a in "$@"; do [ "$a" = show-ref ] && is_anchor_check=1; done
if [ "$is_anchor_check" = 1 ] \
    && printf '%s\n' "$*" | grep -F 'refs/fm-fleet-sync/squash-preserved/' >/dev/null; then
  "$real" "$@"
  rc=$?
  "$real" -C "${GIT_RACE_CLONE:?}" symbolic-ref "${GIT_SYMBOLIC_RACE_REF:?}" "${GIT_SYMBOLIC_RACE_TARGET:?}"
  exit "$rc"
fi
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

git_symbolic_ref_transaction_race() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
replace_ref() {
  oid=$("$real" -C "${GIT_RACE_CLONE:?}" rev-parse --verify "${GIT_SYMBOLIC_RACE_REF:?}^{commit}")
  "$real" -C "$GIT_RACE_CLONE" update-ref --no-deref "${GIT_SYMBOLIC_RACE_TARGET:?}" "$oid" ""
  "$real" -C "$GIT_RACE_CLONE" update-ref --no-deref -d "$GIT_SYMBOLIC_RACE_REF" "$oid"
  "$real" -C "$GIT_RACE_CLONE" symbolic-ref "$GIT_SYMBOLIC_RACE_REF" "$GIT_SYMBOLIC_RACE_TARGET"
}

if [ "${GIT_SYMBOLIC_RACE_PHASE:?}" = before ] \
    && printf '%s\n' "$*" | grep -F 'rev-parse --git-path sequencer' >/dev/null; then
  output=$("$real" "$@")
  rc=$?
  n=$(cat "${GIT_SYMBOLIC_RACE_COUNTER:?}" 2>/dev/null || echo 0)
  n=$(( n + 1 ))
  printf '%s\n' "$n" > "$GIT_SYMBOLIC_RACE_COUNTER"
  if [ "$n" -eq 2 ]; then
    replace_ref
  fi
  [ -z "$output" ] || printf '%s\n' "$output"
  exit "$rc"
fi

if [ "$GIT_SYMBOLIC_RACE_PHASE" = after ] \
    && printf '%s\n' "$*" | grep -F 'symbolic-ref --quiet --no-recurse HEAD' >/dev/null; then
  n=$(cat "${GIT_SYMBOLIC_RACE_COUNTER:?}" 2>/dev/null || echo 0)
  n=$(( n + 1 ))
  printf '%s\n' "$n" > "$GIT_SYMBOLIC_RACE_COUNTER"
  if [ "$n" -eq 2 ]; then
    replace_ref
  fi
  exec "$real" "$@"
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
  [ -z "$(preservation_refs "$clone")" ] || fail "unequal divergence created a preservation ref"
  pass "diverged default branch is reported STUCK and left untouched"
}

test_tree_identical_squash_divergence_reconciles_and_converges() {
  local home clone out again old remote tree anchor
  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" squash-equivalent)
  old=$(git -C "$clone" rev-parse main)
  tree=$(root_tree "$clone" "$old")
  anchor=$(preservation_ref_for "$clone" main "$old")

  out=$(run_sync "$home" "$clone")
  remote=$(git -C "$clone" rev-parse origin/main)

  assert_contains "$out" "squash-equivalent: recovered: reconciled tree-identical squash" \
    "tree-identical squash reports recovery"
  assert_contains "$out" "preserved $anchor" "recovery outcome names the preservation ref"
  [ "$(git -C "$clone" rev-parse "$anchor")" = "$old" ] \
    || fail "preservation ref does not resolve exactly to the old local head"
  [ "$(git -C "$clone" rev-parse main)" = "$remote" ] \
    || fail "default branch does not equal the freshly fetched remote head"
  [ "$(head_sha "$clone")" = "$remote" ] || fail "HEAD does not equal the remote head"
  [ "$(root_tree "$clone" HEAD)" = "$tree" ] || fail "recovery changed the root tree identity"
  [ -z "$(git -C "$clone" status --porcelain)" ] || fail "reconciled clone is dirty"

  again=$(run_sync "$home" "$clone")
  assert_contains "$again" "squash-equivalent: already current" "repeated sync converges harmlessly"
  [ "$(git -C "$clone" rev-parse "$anchor")" = "$old" ] \
    || fail "repeated sync changed the preservation ref"
  [ "$(head_sha "$clone")" = "$remote" ] || fail "repeated sync moved the default branch"
  [ -z "$(git -C "$clone" status --porcelain)" ] || fail "repeated sync dirtied the clone"
  pass "tree-identical squash divergence is anchored, reconciled, and idempotent"
}

test_unrelated_equal_tree_is_not_normalized() {
  local home clone work remote out before remote_head
  home=$(new_home)
  clone=$(build_pair "$home" unrelated-equal)
  work="$home/work-unrelated-equal"
  remote="$home/remotes/unrelated-equal.git"
  commit_file "$clone" file.txt final-unrelated "local final tree"
  before=$(head_sha "$clone")

  git -C "$work" checkout --orphan remote-root -q
  git -C "$work" rm -rfq .
  printf '%s\n' final-unrelated > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -qm "unrelated remote root with equal tree"
  remote_head=$(git -C "$work" rev-parse HEAD)
  git -C "$remote" fetch -q "$work" remote-root:refs/fm-test/unrelated
  git -C "$remote" update-ref refs/heads/main "$remote_head"
  git -C "$remote" update-ref -d refs/fm-test/unrelated
  [ "$(root_tree "$clone" main)" = "$(root_tree "$work" remote-root)" ] \
    || fail "unrelated-equal fixture does not have equal trees"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "unrelated-equal: STUCK:" "unrelated equal trees remain STUCK"
  [ "$(head_sha "$clone")" = "$before" ] || fail "unrelated history was normalized"
  [ -z "$(preservation_refs "$clone")" ] || fail "unrelated history created a preservation ref"
  pass "equal trees without one unambiguous common base are preserved"
}

test_unpublished_ahead_equal_tree_is_not_normalized() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" ahead-equal)
  commit_file "$clone" temporary.txt temporary "add temporary file"
  git -C "$clone" rm -q temporary.txt
  git -C "$clone" commit -qm "remove temporary file"
  before=$(head_sha "$clone")
  [ "$(root_tree "$clone" main)" = "$(root_tree "$clone" origin/main)" ] \
    || fail "ahead-equal fixture does not have equal net trees"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "ahead-equal: STUCK:" "unpublished-ahead branch remains STUCK"
  [ "$(head_sha "$clone")" = "$before" ] || fail "unpublished-ahead history was normalized"
  [ -z "$(preservation_refs "$clone")" ] || fail "unpublished-ahead history created a preservation ref"
  pass "clean unpublished-ahead history with an equal net tree is preserved"
}

test_tree_identical_conflicting_anchor_refuses() {
  local home clone out old anchor conflict
  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" anchor-conflict)
  old=$(git -C "$clone" rev-parse main)
  anchor=$(preservation_ref_for "$clone" main "$old")
  conflict=$(git -C "$clone" rev-parse main^^)
  git -C "$clone" update-ref "$anchor" "$conflict"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "anchor-conflict: STUCK:" "conflicting anchor reports STUCK"
  assert_contains "$out" "preservation ref conflict" "conflicting anchor explains the refusal"
  [ "$(head_sha "$clone")" = "$old" ] || fail "conflicting anchor path moved the default branch"
  [ "$(git -C "$clone" rev-parse "$anchor")" = "$conflict" ] \
    || fail "conflicting preservation ref was overwritten"
  pass "a conflicting preservation ref is never overwritten and blocks reconciliation"
}

test_active_git_operations_refuse_before_preservation() {
  local spec operation marker kind home clone out old status
  for spec in \
      "merge MERGE_HEAD file" \
      "cherry-pick CHERRY_PICK_HEAD file" \
      "revert REVERT_HEAD file" \
      "rebase rebase-merge directory" \
      "rebase rebase-apply directory" \
      "sequencer sequencer directory"; do
    set -- $spec
    operation=$1 marker=$2 kind=$3
    home=$(new_home)
    clone=$(build_tree_identical_squash_pair "$home" "operation-$marker")
    old=$(head_sha "$clone")
    install_git_operation_marker "$clone" "$marker" "$kind"
    status=$(git -C "$clone" status --porcelain 2>/dev/null) \
      || fail "$marker fixture does not expose readable porcelain"
    [ -z "$status" ] || fail "$marker fixture is not porcelain-clean"

    out=$(run_sync "$home" "$clone")

    assert_contains "$out" "STUCK:" "$marker operation did not report STUCK"
    assert_contains "$out" "active $operation operation" "$marker operation did not explain the refusal"
    [ "$(head_sha "$clone")" = "$old" ] || fail "$marker operation moved the default branch"
    [ -z "$(preservation_refs "$clone")" ] || fail "$marker operation created a preservation ref"
  done
  pass "all active Git operation states refuse before preservation"
}

test_operation_starting_after_preservation_refuses_before_transaction() {
  local home clone fakebin out err old anchor
  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" operation-race)
  old=$(head_sha "$clone")
  anchor=$(preservation_ref_for "$clone" main "$old")
  fakebin="$home/fb-operation-race"; mkdir -p "$fakebin"
  git_operation_after_preservation "$fakebin"
  out="$home/out-operation-race"; err="$home/err-operation-race"
  export GIT_RACE_CLONE="$clone"
  run_sync_guarded "$home" "$fakebin" "$out" "$err" operation-race
  unset GIT_RACE_CLONE

  assert_contains "$(cat "$out")" "active merge operation appeared before atomic update" \
    "operation race did not explain the pre-transaction refusal"
  [ "$(head_sha "$clone")" = "$old" ] || fail "operation race moved the default branch"
  [ "$(git -C "$clone" rev-parse "$anchor")" = "$old" ] \
    || fail "operation race lost the preservation ref"
  pass "an operation starting after preservation still blocks the transaction"
}

test_prefetch_symbolic_remote_tracking_ref_does_not_write_through() {
  local home clone out old remote tracking
  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" prefetch-symbolic-remote)
  old=$(head_sha "$clone")
  remote=$(git -C "$home/work-prefetch-symbolic-remote" rev-parse main)
  tracking=$(git -C "$clone" rev-parse refs/remotes/origin/main)
  git -C "$clone" update-ref --no-deref -d refs/remotes/origin/main "$tracking"
  git -C "$clone" symbolic-ref refs/remotes/origin/main refs/heads/main

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "symbolic remote-tracking ref refs/remotes/origin/main" \
    "pre-fetch symbolic remote-tracking ref was not refused"
  [ "$(head_sha "$clone")" = "$old" ] \
    || fail "isolated staged fetch wrote through the symbolic remote-tracking ref"
  [ "$(git -C "$clone" symbolic-ref refs/remotes/origin/main)" = refs/heads/main ] \
    || fail "symbolic remote-tracking ref was replaced"
  [ "$(git -C "$clone" rev-parse refs/heads/main)" != "$remote" ] \
    || fail "symbolic remote-tracking fetch destination moved the checked-out branch"
  [ -z "$(preservation_refs "$clone")" ] \
    || fail "prefetch symbolic remote-tracking refusal created a preservation ref"
  pass "fetch never writes through a pre-existing symbolic remote-tracking ref"
}

test_staged_fetch_symbolic_destination_race_does_not_write_through() {
  local home clone fakebin out err old remote
  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" staged-fetch-symbolic-race)
  old=$(head_sha "$clone")
  remote=$(git -C "$home/work-staged-fetch-symbolic-race" rev-parse main)
  fakebin="$home/fb-staged-fetch-symbolic-race"; mkdir -p "$fakebin"
  git_symbolic_remote_after_staged_fetch "$fakebin"
  out="$home/out-staged-fetch-symbolic-race"
  err="$home/err-staged-fetch-symbolic-race"
  export GIT_RACE_CLONE="$clone"
  run_sync_guarded "$home" "$fakebin" "$out" "$err" staged-fetch-symbolic-race
  unset GIT_RACE_CLONE

  assert_contains "$(cat "$out")" "symbolic remote-tracking ref refs/remotes/origin/main" \
    "symbolic destination race after staged fetch was not refused"
  [ "$(head_sha "$clone")" = "$old" ] \
    || fail "staged fetch destination race moved the checked-out branch"
  [ "$(git -C "$clone" symbolic-ref refs/remotes/origin/main)" = refs/heads/main ] \
    || fail "staged fetch destination race replaced the symbolic ref"
  [ "$(git -C "$clone" rev-parse refs/heads/main)" != "$remote" ] \
    || fail "staged fetch destination race wrote through to the checked-out branch"
  [ -z "$(preservation_refs "$clone")" ] \
    || fail "staged fetch destination race created a preservation ref"
  pass "staged fetch refuses a raced symbolic destination without write-through"
}

test_symbolic_reconciliation_refs_are_refused() {
  local home clone out old remote anchor target fakebin err

  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" symbolic-local)
  old=$(head_sha "$clone")
  target=refs/fm-test/symbolic-local-target
  git -C "$clone" update-ref --no-deref "$target" "$old" ""
  git -C "$clone" update-ref --no-deref -d refs/heads/main "$old"
  git -C "$clone" symbolic-ref refs/heads/main "$target"
  out=$(run_sync "$home" "$clone")
  assert_contains "$out" "symbolic local default ref" "symbolic local ref was not explicitly refused"
  [ "$(head_sha "$clone")" = "$old" ] || fail "symbolic local ref moved its referent"
  [ -z "$(preservation_refs "$clone")" ] || fail "symbolic local ref created a preservation ref"

  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" symbolic-remote)
  old=$(head_sha "$clone")
  fakebin="$home/fb-symbolic-remote"; mkdir -p "$fakebin"
  git_symbolic_ref_before_preservation "$fakebin"
  out="$home/out-symbolic-remote"; err="$home/err-symbolic-remote"
  target=refs/fm-test/symbolic-remote-target
  export GIT_RACE_CLONE="$clone"
  export GIT_SYMBOLIC_RACE_REF=refs/remotes/origin/main
  export GIT_SYMBOLIC_RACE_TARGET="$target"
  run_sync_guarded "$home" "$fakebin" "$out" "$err" symbolic-remote
  unset GIT_RACE_CLONE GIT_SYMBOLIC_RACE_REF GIT_SYMBOLIC_RACE_TARGET
  assert_contains "$(cat "$out")" "symbolic remote-tracking ref" \
    "symbolic remote-tracking ref was not explicitly refused"
  [ "$(head_sha "$clone")" = "$old" ] || fail "symbolic remote-tracking ref moved the local branch"
  [ -z "$(preservation_refs "$clone")" ] || fail "symbolic remote-tracking ref created a preservation ref"

  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" symbolic-preservation)
  old=$(head_sha "$clone")
  anchor=$(preservation_ref_for "$clone" main "$old")
  target=refs/fm-test/symbolic-preservation-target
  git -C "$clone" update-ref --no-deref "$target" "$old" ""
  git -C "$clone" symbolic-ref "$anchor" "$target"
  out=$(run_sync "$home" "$clone")
  assert_contains "$out" "symbolic preservation ref" "symbolic preservation ref was not explicitly refused"
  [ "$(head_sha "$clone")" = "$old" ] || fail "symbolic preservation ref moved the default branch"
  [ "$(git -C "$clone" symbolic-ref "$anchor")" = "$target" ] \
    || fail "symbolic preservation ref was overwritten"
  [ "$(git -C "$clone" rev-parse "$target")" = "$old" ] \
    || fail "symbolic preservation referent was moved"

  remote=$(git -C "$clone" rev-parse origin/main)
  [ "$remote" != "$old" ] || fail "symbolic-ref fixtures lost their divergence"
  pass "symbolic local, remote-tracking, and preservation refs are refused"
}

test_preservation_creation_symbolic_race_does_not_write_through() {
  local home clone fakebin out err old anchor target
  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" preservation-symbolic-race)
  old=$(head_sha "$clone")
  anchor=$(preservation_ref_for "$clone" main "$old")
  target=refs/fm-test/dangling-preservation-target
  ! git -C "$clone" show-ref --verify --quiet "$target" \
    || fail "symbolic preservation race target is not dangling"
  fakebin="$home/fb-preservation-symbolic-race"; mkdir -p "$fakebin"
  git_symbolic_preservation_creation_race "$fakebin"
  out="$home/out-preservation-symbolic-race"; err="$home/err-preservation-symbolic-race"
  export GIT_RACE_CLONE="$clone"
  export GIT_SYMBOLIC_RACE_REF="$anchor"
  export GIT_SYMBOLIC_RACE_TARGET="$target"
  run_sync_guarded "$home" "$fakebin" "$out" "$err" preservation-symbolic-race
  unset GIT_RACE_CLONE GIT_SYMBOLIC_RACE_REF GIT_SYMBOLIC_RACE_TARGET

  assert_contains "$(cat "$out")" "symbolic preservation ref appeared before creation" \
    "symbolic preservation creation race did not refuse"
  [ "$(head_sha "$clone")" = "$old" ] || fail "symbolic preservation creation race moved the branch"
  [ "$(git -C "$clone" symbolic-ref "$anchor")" = "$target" ] \
    || fail "symbolic preservation creation race replaced the named ref"
  ! git -C "$clone" show-ref --verify --quiet "$target" \
    || fail "preservation creation wrote through the dangling symbolic ref"
  pass "preservation creation cannot write through a symbolic race"
}

test_resolving_preservation_creation_symbolic_race_refuses() {
  local home clone fakebin out err old anchor target
  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" preservation-resolving-symbolic-race)
  old=$(head_sha "$clone")
  anchor=$(preservation_ref_for "$clone" main "$old")
  target=refs/fm-test/resolving-preservation-target
  git -C "$clone" update-ref --no-deref "$target" "$old" ""
  fakebin="$home/fb-preservation-resolving-symbolic-race"; mkdir -p "$fakebin"
  git_symbolic_preservation_creation_race "$fakebin"
  out="$home/out-preservation-resolving-symbolic-race"
  err="$home/err-preservation-resolving-symbolic-race"
  export GIT_RACE_CLONE="$clone"
  export GIT_SYMBOLIC_RACE_REF="$anchor"
  export GIT_SYMBOLIC_RACE_TARGET="$target"
  run_sync_guarded "$home" "$fakebin" "$out" "$err" preservation-resolving-symbolic-race
  unset GIT_RACE_CLONE GIT_SYMBOLIC_RACE_REF GIT_SYMBOLIC_RACE_TARGET

  assert_contains "$(cat "$out")" "cannot create preservation ref" \
    "resolving symbolic preservation creation race did not refuse during preparation"
  [ "$(head_sha "$clone")" = "$old" ] || fail "resolving symbolic preservation race moved the branch"
  [ "$(git -C "$clone" symbolic-ref "$anchor")" = "$target" ] \
    || fail "resolving symbolic preservation race replaced the named ref"
  [ "$(git -C "$clone" rev-parse "$target")" = "$old" ] \
    || fail "resolving symbolic preservation race moved its referent"
  pass "resolving symbolic preservation creation refuses during preparation"
}

test_tree_identical_expected_old_transaction_refusal() {
  local home clone fakebin out err log counter old remote anchor
  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" ref-race)
  old=$(git -C "$clone" rev-parse main)
  anchor=$(preservation_ref_for "$clone" main "$old")
  fakebin="$home/fb-ref-race"; mkdir -p "$fakebin"
  git_ref_transaction_refusal "$fakebin"
  out="$home/out-ref-race"; err="$home/err-ref-race"; log="$home/ref-transaction"
  counter="$home/ref-transaction-count"
  export GIT_REF_TRANSACTION_LOG="$log"
  export GIT_REF_TRANSACTION_COUNTER="$counter"
  run_sync_guarded "$home" "$fakebin" "$out" "$err" ref-race
  unset GIT_REF_TRANSACTION_LOG GIT_REF_TRANSACTION_COUNTER
  remote=$(git -C "$clone" rev-parse origin/main)

  assert_grep "verify $anchor $old" "$log" "atomic transaction did not verify the preservation ref"
  assert_grep "verify refs/remotes/origin/main $remote" "$log" \
    "atomic transaction did not verify the freshly observed remote ref"
  assert_grep "update refs/heads/main $remote $old" "$log" \
    "atomic branch update did not carry its expected old object"
  [ "$(grep -Fc 'option no-deref' "$log")" -eq 3 ] \
    || fail "atomic transaction did not apply no-deref to all three named refs"
  assert_contains "$(cat "$out")" "ref-race: STUCK:" "expected-old refusal reports STUCK"
  assert_contains "$(cat "$out")" "atomic update rejected" "expected-old refusal explains the atomic rejection"
  [ "$(head_sha "$clone")" = "$old" ] || fail "ref transaction refusal moved the default branch"
  [ "$(git -C "$clone" rev-parse "$anchor")" = "$old" ] \
    || fail "ref transaction refusal lost the anchored old head"
  pass "an expected-old ref transaction refusal leaves the default branch unmoved"
}

test_committed_transaction_with_lost_ack_is_verified() {
  local home clone fakebin out err old remote anchor
  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" committed-lost-ack)
  old=$(head_sha "$clone")
  remote=$(git -C "$home/work-committed-lost-ack" rev-parse main)
  anchor=$(preservation_ref_for "$clone" main "$old")
  fakebin="$home/fb-committed-lost-ack"; mkdir -p "$fakebin"
  git_ref_transaction_ack_loss "$fakebin"
  out="$home/out-committed-lost-ack"; err="$home/err-committed-lost-ack"
  export GIT_ACK_LOSS_MODE=committed
  run_sync_guarded "$home" "$fakebin" "$out" "$err" committed-lost-ack
  unset GIT_ACK_LOSS_MODE

  assert_contains "$(cat "$out")" "committed-lost-ack: recovered:" \
    "committed transaction with a lost acknowledgement was not verified"
  [ "$(head_sha "$clone")" = "$remote" ] \
    || fail "committed transaction with a lost acknowledgement left HEAD unverified"
  [ "$(git -C "$clone" rev-parse "$anchor")" = "$old" ] \
    || fail "committed transaction with a lost acknowledgement lost its preservation ref"
  [ -z "$(git -C "$clone" status --porcelain)" ] \
    || fail "committed transaction with a lost acknowledgement dirtied the clone"
  pass "a committed transaction survives lost acknowledgement after full verification"
}

test_uncommitted_transaction_with_lost_ack_is_reconciled() {
  local home clone fakebin out err old remote anchor
  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" uncommitted-lost-ack)
  old=$(head_sha "$clone")
  remote=$(git -C "$home/work-uncommitted-lost-ack" rev-parse main)
  anchor=$(preservation_ref_for "$clone" main "$old")
  fakebin="$home/fb-uncommitted-lost-ack"; mkdir -p "$fakebin"
  git_ref_transaction_ack_loss "$fakebin"
  out="$home/out-uncommitted-lost-ack"; err="$home/err-uncommitted-lost-ack"
  export GIT_ACK_LOSS_MODE=uncommitted
  run_sync_guarded "$home" "$fakebin" "$out" "$err" uncommitted-lost-ack
  unset GIT_ACK_LOSS_MODE

  assert_contains "$(cat "$out")" "atomic update did not commit after acknowledgement loss" \
    "uncommitted transaction with a lost acknowledgement was not distinguished"
  [ "$(head_sha "$clone")" = "$old" ] \
    || fail "uncommitted transaction with a lost acknowledgement moved HEAD"
  [ "$(git -C "$clone" rev-parse refs/remotes/origin/main)" = "$remote" ] \
    || fail "uncommitted transaction lost the freshly published remote head"
  [ "$(git -C "$clone" rev-parse "$anchor")" = "$old" ] \
    || fail "uncommitted transaction with a lost acknowledgement lost its preservation ref"
  [ -z "$(git -C "$clone" status --porcelain)" ] \
    || fail "uncommitted transaction with a lost acknowledgement dirtied the clone"
  pass "an uncommitted transaction is identified safely after lost acknowledgement"
}

test_symbolic_transaction_races_do_not_write_through() {
  local kind home clone fakebin out err counter old remote anchor race_ref target expected
  for kind in preservation remote local; do
    home=$(new_home)
    clone=$(build_tree_identical_squash_pair "$home" "transaction-symbolic-$kind")
    old=$(head_sha "$clone")
    anchor=$(preservation_ref_for "$clone" main "$old")
    remote=$(git -C "$home/work-transaction-symbolic-$kind" rev-parse main)
    case "$kind" in
      preservation) race_ref=$anchor; expected=$old ;;
      remote) race_ref=refs/remotes/origin/main; expected=$remote ;;
      local) race_ref=refs/heads/main; expected=$old ;;
    esac
    target="refs/fm-test/transaction-symbolic-$kind-target"
    fakebin="$home/fb-transaction-symbolic-$kind"; mkdir -p "$fakebin"
    git_symbolic_ref_transaction_race "$fakebin"
    out="$home/out-transaction-symbolic-$kind"
    err="$home/err-transaction-symbolic-$kind"
    counter="$home/count-transaction-symbolic-$kind"
    export GIT_RACE_CLONE="$clone"
    export GIT_SYMBOLIC_RACE_REF="$race_ref"
    export GIT_SYMBOLIC_RACE_TARGET="$target"
    export GIT_SYMBOLIC_RACE_PHASE=before
    export GIT_SYMBOLIC_RACE_COUNTER="$counter"
    run_sync_guarded "$home" "$fakebin" "$out" "$err" "transaction-symbolic-$kind"
    unset GIT_RACE_CLONE GIT_SYMBOLIC_RACE_REF GIT_SYMBOLIC_RACE_TARGET
    unset GIT_SYMBOLIC_RACE_PHASE GIT_SYMBOLIC_RACE_COUNTER

    assert_contains "$(cat "$out")" "atomic update rejected" \
      "$kind symbolic transaction race did not reject"
    [ "$(head_sha "$clone")" = "$old" ] || fail "$kind symbolic transaction race moved HEAD"
    [ "$(git -C "$clone" symbolic-ref "$race_ref")" = "$target" ] \
      || fail "$kind symbolic transaction race replaced the raced named ref"
    [ "$(git -C "$clone" rev-parse "$target")" = "$expected" ] \
      || fail "$kind symbolic transaction race wrote through its referent"
  done
  pass "atomic ref checks reject symbolic substitutions without write-through"
}

test_symbolic_rollback_race_does_not_write_through() {
  local home clone fakebin out err counter old remote anchor target
  home=$(new_home)
  clone=$(build_tree_identical_squash_pair "$home" rollback-symbolic-race)
  old=$(head_sha "$clone")
  anchor=$(preservation_ref_for "$clone" main "$old")
  remote=$(git -C "$home/work-rollback-symbolic-race" rev-parse main)
  target=refs/fm-test/rollback-symbolic-target
  fakebin="$home/fb-rollback-symbolic-race"; mkdir -p "$fakebin"
  git_symbolic_ref_transaction_race "$fakebin"
  out="$home/out-rollback-symbolic-race"; err="$home/err-rollback-symbolic-race"
  counter="$home/count-rollback-symbolic-race"
  export GIT_RACE_CLONE="$clone"
  export GIT_SYMBOLIC_RACE_REF=refs/heads/main
  export GIT_SYMBOLIC_RACE_TARGET="$target"
  export GIT_SYMBOLIC_RACE_PHASE=after
  export GIT_SYMBOLIC_RACE_COUNTER="$counter"
  run_sync_guarded "$home" "$fakebin" "$out" "$err" rollback-symbolic-race
  unset GIT_RACE_CLONE GIT_SYMBOLIC_RACE_REF GIT_SYMBOLIC_RACE_TARGET
  unset GIT_SYMBOLIC_RACE_PHASE GIT_SYMBOLIC_RACE_COUNTER

  assert_contains "$(cat "$out")" "local branch was restored" \
    "symbolic rollback race did not restore the named local ref"
  ! git -C "$clone" symbolic-ref --quiet refs/heads/main >/dev/null 2>&1 \
    || fail "symbolic rollback race left the local ref symbolic"
  [ "$(head_sha "$clone")" = "$old" ] || fail "symbolic rollback race did not restore the old local head"
  [ "$(git -C "$clone" rev-parse "$target")" = "$remote" ] \
    || fail "rollback wrote the old local head through the symbolic ref"
  [ "$(git -C "$clone" rev-parse "$anchor")" = "$old" ] \
    || fail "symbolic rollback race lost the preservation ref"
  pass "rollback cannot write through a symbolic local ref race"
}

test_prunes_gone_branch_during_ordinary_sync() {
  local home clone out
  home=$(new_home)
  clone=$(build_packed_prunable "$home" prune-ordinary)

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "prune-ordinary: pruned feature" "ordinary sync still reports pruning"
  ! git -C "$clone" show-ref --verify --quiet refs/heads/feature \
    || fail "ordinary sync did not prune a gone branch"
  [ "$(head_sha "$clone")" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "ordinary pruning path did not retain fast-forward behavior"
  pass "ordinary gone-branch pruning still works"
}

test_single_branch_refspec_preserves_out_of_scope_tracking_refs() {
  local home clone work out
  home=$(new_home)
  clone=$(build_pair "$home" single-branch-refspec)
  work="$home/work-single-branch-refspec"
  git -C "$work" push -q origin main:refs/heads/feature
  git -C "$clone" fetch -q origin
  git -C "$clone" branch -q --track retained-feature origin/feature
  git -C "$clone" config --unset-all remote.origin.fetch
  git -C "$clone" config --add remote.origin.fetch \
    '+refs/heads/main:refs/remotes/origin/main'
  git -C "$work" push -q origin --delete feature
  advance_origin "$home" single-branch-refspec C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "single-branch-refspec: synced" \
    "single-branch configured fetch did not update main"
  git -C "$clone" show-ref --verify --quiet refs/remotes/origin/feature \
    || fail "single-branch fetch pruned an out-of-scope remote-tracking ref"
  git -C "$clone" show-ref --verify --quiet refs/heads/retained-feature \
    || fail "single-branch fetch pruned a branch whose upstream was out of scope"
  pass "single-branch refspecs preserve out-of-scope tracking refs"
}

test_negative_refspec_preserves_excluded_tracking_refs() {
  local home clone work out
  home=$(new_home)
  clone=$(build_pair "$home" negative-refspec)
  work="$home/work-negative-refspec"
  git -C "$work" push -q origin main:refs/heads/private
  git -C "$clone" fetch -q origin
  git -C "$clone" branch -q --track retained-private origin/private
  git -C "$clone" config --unset-all remote.origin.fetch
  git -C "$clone" config --add remote.origin.fetch \
    '+refs/heads/*:refs/remotes/origin/*'
  git -C "$clone" config --add remote.origin.fetch '^refs/heads/private'
  git -C "$work" push -q origin --delete private
  advance_origin "$home" negative-refspec C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "negative-refspec: synced" \
    "negative configured fetch did not update included refs"
  git -C "$clone" show-ref --verify --quiet refs/remotes/origin/private \
    || fail "negative refspec did not protect its excluded remote-tracking ref"
  git -C "$clone" show-ref --verify --quiet refs/heads/retained-private \
    || fail "negative refspec allowed an excluded upstream branch to be pruned"
  pass "negative refspecs protect excluded tracking refs from pruning"
}

test_custom_refspec_updates_and_prunes_only_its_destinations() {
  local home clone work remote out first
  home=$(new_home)
  clone=$(build_pair "$home" custom-refspec)
  work="$home/work-custom-refspec"
  remote="$home/remotes/custom-refspec.git"
  first=$(git -C "$work" rev-parse main)
  git -C "$remote" update-ref refs/pull/1/head "$first"
  git -C "$clone" config --add remote.origin.fetch \
    '+refs/pull/*/head:refs/remotes/origin/pr/*'

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "custom-refspec: already current" \
    "custom refspec fetch changed the default-branch outcome"
  [ "$(git -C "$clone" rev-parse refs/remotes/origin/pr/1)" = "$first" ] \
    || fail "custom pull-request refspec was not published"
  git -C "$clone" branch -q --track pr-one origin/pr/1
  git -C "$remote" update-ref -d refs/pull/1/head
  advance_origin "$home" custom-refspec C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "custom-refspec: pruned pr-one" \
    "custom refspec deletion did not drive ordinary gone-upstream pruning"
  ! git -C "$clone" show-ref --verify --quiet refs/remotes/origin/pr/1 \
    || fail "custom refspec destination was not pruned"
  ! git -C "$clone" show-ref --verify --quiet refs/heads/pr-one \
    || fail "branch tracking a pruned custom destination was retained"
  pass "custom refspec destinations update and prune with configured semantics"
}

test_auto_follow_tags_are_preserved() {
  local home clone work out tag_oid
  home=$(new_home)
  clone=$(build_pair "$home" auto-follow-tags)
  work="$home/work-auto-follow-tags"
  advance_origin "$home" auto-follow-tags C1
  git -C "$work" tag release
  git -C "$work" push -q origin refs/tags/release
  tag_oid=$(git -C "$work" rev-parse refs/tags/release)

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "auto-follow-tags: synced" \
    "tag auto-follow fixture did not sync its default branch"
  [ "$(git -C "$clone" rev-parse refs/tags/release)" = "$tag_oid" ] \
    || fail "configured fetch lost ordinary tag auto-follow behavior"
  git -C "$work" push -q origin --delete refs/tags/release

  run_sync "$home" "$clone" >/dev/null

  git -C "$clone" show-ref --verify --quiet refs/tags/release \
    || fail "ordinary --prune unexpectedly pruned an auto-followed tag"
  pass "staged fetch preserves ordinary tag auto-follow and prune behavior"
}

test_staged_fetch_is_git_240_compatible_and_uses_one_remote_session() {
  local home clone fakebin out err log
  home=$(new_home)
  clone=$(build_pair "$home" git-240-fetch)
  advance_origin "$home" git-240-fetch C1
  fakebin="$home/fb-git-240-fetch"; mkdir -p "$fakebin"
  git_staged_fetch_compatibility_audit "$fakebin"
  out="$home/out-git-240-fetch"
  err="$home/err-git-240-fetch"
  log="$home/git-fetch-audit"
  : >"$log"

  GIT_FETCH_AUDIT_LOG="$log" \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" git-240-fetch

  assert_contains "$(cat "$out")" "git-240-fetch: synced" \
    "Git 2.40-compatible staged fetch did not fast-forward"
  [ "$(grep -c $'^fetch\tremote\t' "$log")" -eq 1 ] \
    || fail "staged fetch did not use exactly one origin fetch session"
  [ "$(grep -c $'^fetch\tlocal\t' "$log")" -eq 1 ] \
    || fail "staged fetch object transfer was not one local fetch"
  pass "staged fetch avoids newer porcelain and uses one remote session"
}

test_staged_fetch_signals_clean_scope_and_preserve_caller_traps() {
  local signal signal_status home clone fakebin out err marker trap_log stage rc realgit
  for signal in TERM INT; do
    case "$signal" in
      TERM) signal_status=143 ;;
      INT) signal_status=130 ;;
    esac
    home=$(new_home)
    clone=$(build_pair "$home" "staged-fetch-signal-$signal")
    advance_origin "$home" "staged-fetch-signal-$signal" C1
    fakebin="$home/fb-staged-fetch-signal"; mkdir -p "$fakebin"
    git_signal_during_staged_fetch "$fakebin"
    out="$home/out-staged-fetch-signal"
    err="$home/err-staged-fetch-signal"
    marker="$home/staged-fetch-path"
    trap_log="$home/caller-traps"
    realgit=$(command -v git)

    set +e
    PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$realgit" \
    GIT_STAGED_FETCH_SIGNAL="$signal" \
    GIT_STAGED_FETCH_SIGNAL_MARKER="$marker" \
    CALLER_TRAP_LOG="$trap_log" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      bash -c '
        export FLEET_SYNC_SIGNAL_TARGET=$$
        sleep 1 &
        caller_child=$!
        trap '"'"'printf "TERM\n" >>"$CALLER_TRAP_LOG"; exit 143'"'"' TERM
        trap '"'"'printf "INT\n" >>"$CALLER_TRAP_LOG"; exit 130'"'"' INT
        trap '"'"'
          printf "STATUS:%s\n" "$?" >>"$CALLER_TRAP_LOG"
          if wait "$caller_child"; then
            printf "WAITED\n" >>"$CALLER_TRAP_LOG"
          else
            printf "WAIT-FAILED\n" >>"$CALLER_TRAP_LOG"
          fi
          printf "EXIT\n" >>"$CALLER_TRAP_LOG"
          exit 77
        '"'"' EXIT
        . "$1" "$2"
      ' _ "$ROOT/bin/fm-fleet-sync.sh" "$clone" >"$out" 2>"$err"
    rc=$?
    set -e

    [ "$rc" -eq 77 ] \
      || fail "$signal during staged fetch discarded caller EXIT status 77 (got $rc)"
    assert_present "$marker" "$signal staged fetch did not expose its scoped directory"
    stage=$(cat "$marker")
    [ ! -e "$stage" ] || fail "$signal left staged fetch directory $stage"
    assert_grep "$signal" "$trap_log" \
      "$signal staged cleanup replaced the caller's signal trap"
    assert_grep "STATUS:$signal_status" "$trap_log" \
      "$signal staged cleanup changed caller EXIT status input"
    assert_grep "WAITED" "$trap_log" \
      "$signal caller EXIT trap could not wait on its current-shell child"
    assert_no_grep "WAIT-FAILED" "$trap_log" \
      "$signal caller EXIT trap ran outside the current shell"
    assert_grep "EXIT" "$trap_log" \
      "$signal staged cleanup replaced the caller's EXIT trap"
  done
  pass "TERM and INT clean staged fetch scope and preserve caller traps"
}

test_staged_fetch_default_signals_clean_scope() {
  local signal expected home clone fakebin out err marker stage rc realgit
  for signal in TERM INT; do
    case "$signal" in
      TERM) expected=143 ;;
      INT) expected=130 ;;
    esac
    home=$(new_home)
    clone=$(build_pair "$home" "staged-fetch-default-signal-$signal")
    advance_origin "$home" "staged-fetch-default-signal-$signal" C1
    fakebin="$home/fb-staged-fetch-default-signal"; mkdir -p "$fakebin"
    git_signal_during_staged_fetch "$fakebin"
    out="$home/out-staged-fetch-default-signal"
    err="$home/err-staged-fetch-default-signal"
    marker="$home/staged-fetch-default-path"
    realgit=$(command -v git)

    set +e
    PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$realgit" \
    GIT_STAGED_FETCH_SIGNAL="$signal" \
    GIT_STAGED_FETCH_SIGNAL_MARKER="$marker" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      bash -c '
        export FLEET_SYNC_SIGNAL_TARGET=$$
        . "$1" "$2"
      ' _ "$ROOT/bin/fm-fleet-sync.sh" "$clone" >"$out" 2>"$err"
    rc=$?
    set -e

    [ "$rc" -eq "$expected" ] \
      || fail "default $signal during staged fetch exited $rc instead of $expected"
    assert_present "$marker" "default $signal did not expose its scoped directory"
    stage=$(cat "$marker")
    [ ! -e "$stage" ] || fail "default $signal left staged fetch directory $stage"
  done
  pass "default TERM and INT clean the exact staged fetch scope"
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

test_missing_remote_default_skipped() {
  local home clone remote out before
  home=$(new_home)
  clone=$(build_pair "$home" missing-default)
  remote="$home/remotes/missing-default.git"
  before=$(head_sha "$clone")
  git -C "$remote" update-ref -d refs/heads/main

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "missing-default: skipped: origin/main does not exist" \
    "missing remote default is skipped as before"
  [ "$(head_sha "$clone")" = "$before" ] || fail "missing remote default moved the local branch"
  [ -z "$(preservation_refs "$clone")" ] || fail "missing remote default created a preservation ref"
  pass "a missing remote default remains a benign skip"
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

test_detached_clean_ancestor_recovers
test_detached_unique_commit_is_stuck_untouched
test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched
test_dirty_is_stuck_untouched
test_non_default_branch_is_stuck_untouched
test_diverged_is_stuck_untouched
test_tree_identical_squash_divergence_reconciles_and_converges
test_unrelated_equal_tree_is_not_normalized
test_unpublished_ahead_equal_tree_is_not_normalized
test_tree_identical_conflicting_anchor_refuses
test_active_git_operations_refuse_before_preservation
test_operation_starting_after_preservation_refuses_before_transaction
test_prefetch_symbolic_remote_tracking_ref_does_not_write_through
test_staged_fetch_symbolic_destination_race_does_not_write_through
test_symbolic_reconciliation_refs_are_refused
test_preservation_creation_symbolic_race_does_not_write_through
test_resolving_preservation_creation_symbolic_race_refuses
test_tree_identical_expected_old_transaction_refusal
test_committed_transaction_with_lost_ack_is_verified
test_uncommitted_transaction_with_lost_ack_is_reconciled
test_symbolic_transaction_races_do_not_write_through
test_symbolic_rollback_race_does_not_write_through
test_prunes_gone_branch_during_ordinary_sync
test_single_branch_refspec_preserves_out_of_scope_tracking_refs
test_negative_refspec_preserves_excluded_tracking_refs
test_custom_refspec_updates_and_prunes_only_its_destinations
test_auto_follow_tags_are_preserved
test_staged_fetch_is_git_240_compatible_and_uses_one_remote_session
test_staged_fetch_signals_clean_scope_and_preserve_caller_traps
test_staged_fetch_default_signals_clean_scope
test_on_default_clean_behind_fast_forwards
test_already_current_unchanged
test_no_origin_skipped
test_missing_remote_default_skipped
test_local_only_skipped
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
