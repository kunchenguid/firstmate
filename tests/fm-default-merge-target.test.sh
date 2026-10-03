#!/usr/bin/env bash
# Branch-mutating entrypoints resolve origin's current default independently of
# a cached origin/HEAD. Exercise real refs, remote failures and resulting tips.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-default-merge-target)

make_case() {
  local dir=$1
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data"
  touch "$dir/home/state/.last-watcher-beat"
  git init -q -b main "$dir/seed"
  printf 'base\n' > "$dir/seed/file"
  git -C "$dir/seed" add file
  git -C "$dir/seed" commit -qm base
  git -C "$dir/seed" branch trunk
  git clone -q --bare "$dir/seed" "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/project"
  git -C "$dir/project" branch trunk origin/trunk >/dev/null
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/trunk
  # The switch itself is at the same commit. Subsequent work provides an
  # observable advance, while the project still records origin/HEAD as main.
  git -C "$dir/seed" checkout -q trunk
  printf 'shipped\n' > "$dir/seed/file"
  git -C "$dir/seed" commit -qam shipped
  git -C "$dir/seed" push -q "$dir/origin.git" trunk
  git -C "$dir/project" fetch -q origin
  git -C "$dir/project" branch fm/task origin/trunk >/dev/null
  printf 'project=%s\nmode=local-only\nbranch=fm/task\n' "$dir/project" > "$dir/home/state/task.meta"
}

run_action() {
  local action=$1 dir=$2
  case "$action" in
    local-merge)
      FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-merge-local.sh" task ;;
    fleet)
      FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$dir/project" ;;
    origin-sync|local-sync)
      FM_HOME="$dir/home" FM_ROOT="$ROOT" bash -c '
        . "$1/bin/fm-ff-lib.sh"
        base=origin
        [ "$3" != local-sync ] || base=$(git -C "$2" rev-parse fm/task)
        ff_target "$2" fixture "$base" yes
      ' _ "$ROOT" "$dir/project" "$action" ;;
  esac
}

for action in local-merge fleet origin-sync local-sync; do
  for state in main trunk unresolved unreachable; do
    dir="$TMP_ROOT/$action-$state"
    make_case "$dir"
    base=$(git -C "$dir/project" rev-parse main)
    target=$(git -C "$dir/project" rev-parse fm/task)
    case "$state" in
      trunk) git -C "$dir/project" checkout -q trunk ;;
      unresolved) git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/missing ;;
      unreachable) git -C "$dir/project" remote set-url origin "$dir/missing.git" ;;
    esac
    status=0
    out=$(run_action "$action" "$dir" 2>&1) || status=$?
    [ "$(git -C "$dir/project" rev-parse main)" = "$base" ] \
      || fail "$action/$state advanced cached main: $out"
    if [ "$state" = trunk ]; then
      expect_code 0 "$status" "$action should update trunk: $out"
      [ "$(git -C "$dir/project" rev-parse trunk)" = "$target" ] \
        || fail "$action failed to update the current default: $out"
      [ "$(git -C "$dir/project" symbolic-ref refs/remotes/origin/HEAD)" = refs/remotes/origin/trunk ] \
        || fail "$action failed to refresh origin/HEAD"
    else
      [ "$(git -C "$dir/project" rev-parse trunk)" = "$base" ] \
        || fail "$action/$state mutated trunk despite refusal: $out"
      if [ "$action" = local-merge ]; then
        [ "$status" -ne 0 ] || fail "local merge should refuse $state: $out"
      fi
    fi
    pass "$action/$state never updates a cached default"
  done
done

# Fleet's detached recovery also selects a branch to mutate.
dir="$TMP_ROOT/fleet-detached"
make_case "$dir"
base=$(git -C "$dir/project" rev-parse main)
git -C "$dir/project" checkout -q --detach
out=$(run_action fleet "$dir" 2>&1)
[ "$(git -C "$dir/project" symbolic-ref --short HEAD)" = trunk ] \
  || fail "fleet recovered to the cached default: $out"
[ "$(git -C "$dir/project" rev-parse HEAD)" = "$(git -C "$dir/project" rev-parse fm/task)" ] \
  || fail "fleet did not advance recovered trunk"
[ "$(git -C "$dir/project" rev-parse main)" = "$base" ] || fail "fleet recovery moved main"
pass "fleet detached recovery selects the freshly resolved default"

# A detached local-commit sync mutates no named branch and needs no origin.
dir="$TMP_ROOT/local-sync-detached"
make_case "$dir"
base=$(git -C "$dir/project" rev-parse main)
git -C "$dir/project" checkout -q --detach
git -C "$dir/project" remote set-url origin "$dir/missing.git"
out=$(run_action local-sync "$dir" 2>&1)
[ "$(git -C "$dir/project" rev-parse HEAD)" = "$(git -C "$dir/project" rev-parse fm/task)" ] \
  || fail "detached local sync lost its offline path: $out"
[ "$(git -C "$dir/project" rev-parse main)" = "$base" ] || fail "detached sync moved main"
pass "detached local sync remains origin-independent"
