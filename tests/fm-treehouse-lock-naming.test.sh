#!/usr/bin/env bash
# tests/fm-treehouse-lock-naming.test.sh - every failure exit of
# fm_treehouse_project_lock_path (bin/fm-wake-lib.sh) must name the one thing it
# could not resolve.
#
# The function has eight failure exits and every caller collapses all eight into
# the same sentence, "could not resolve the shared Treehouse project lock for
# <project>", which is true of all eight and diagnostic of none - and which
# points the reader at the PROJECT even when the missing thing is in the HOME.
# An investigation lost time to that and had to hand-patch the function to learn
# which exit fired. These cases drive each exit through the library's public
# shell interface and assert the message names its own cause and path.
#
# Each case is written to go red if the naming is removed: with the diagnostics
# deleted the refusals fall back to silence, and every assertion below reads an
# empty stderr. The success case is the other half of that pin - it asserts the
# naming never leaks onto the path that resolves, so a message emitted
# unconditionally cannot satisfy the file either.
#
# Only the messages are under test. What each exit REFUSES is unchanged and
# deliberately so: the root state directory is named, not created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-lock-naming)
fm_git_identity

# chmod-000 fixtures are restored on the way out: a mode-000 directory inside
# TMP_ROOT would otherwise defeat the library's own recursive cleanup.
UNREADABLE=
cleanup_unreadable() {
  local dir
  for dir in $UNREADABLE; do chmod 755 "$dir" 2>/dev/null || true; done
}
trap 'cleanup_unreadable; fm_test_cleanup' EXIT INT TERM

make_case() {  # <name> -> echoes a fresh case dir with a usable home
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/elsewhere"
  printf '%s\n' "$dir"
}

# resolve_lock <home> <state-override> <project> [path-prefix]
# Sources the library in a child shell exactly as the production callers do -
# stdout captured through command substitution, stderr passed through - and
# echoes the combined output. FM_STATE_OVERRIDE is always pointed away from
# <home>/state so the library's own unconditional `mkdir -p "$STATE"` cannot
# create the very directory a case is about to prove missing.
resolve_lock() {
  local home=$1 state=$2 project=$3 prefix=${4-}
  PATH="${prefix:+$prefix:}$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ "$LIB" "$project" 2>&1
}

# make_unenterable <dir>: chmod 000 and PROVE the construction actually blocks
# entry. Running as root (or on a filesystem that ignores the mode) would leave
# the case asserting a refusal that never fires, which is coverage that reports
# safety it does not have, so it fails loudly instead of passing vacuously.
make_unenterable() {
  local dir=$1
  chmod 000 "$dir"
  UNREADABLE="$UNREADABLE $dir"
  if (CDPATH='' cd -- "$dir" 2>/dev/null); then
    fail "fixture is not blocking: $dir is still enterable at mode 000 (running as root?)"
  fi
}

# git_shim <dir> <body>: a PATH-front `git` that answers the queries this case
# needs and delegates everything else to the real binary. Two exits can only be
# reached when git answers one call and fails a later one, which no on-disk
# fixture can arrange.
git_shim() {
  local dir=$1 body=$2 real
  real=$(command -v git)
  mkdir -p "$dir"
  cat > "$dir/git" <<EOF
#!/usr/bin/env bash
$body
exec "$real" "\$@"
EOF
  chmod +x "$dir/git"
  printf '%s\n' "$dir"
}


test_missing_project_directory_is_named() {
  local dir out
  dir=$(make_case project-absent)
  out=$(resolve_lock "$dir/home" "$dir/elsewhere" "$dir/no-such-project")
  expect_code 1 "$?" "an absent project directory should still refuse"
  assert_contains "$out" "project directory does not exist: $dir/no-such-project" \
    "the refusal did not name the absent project directory"
  pass "an absent project directory is named in the refusal"
}

test_unresolvable_root_home_is_named() {
  local dir out
  dir=$(make_case root-home-absent)
  fm_git_init_commit "$dir/project"
  out=$(resolve_lock "$dir/no-such-home" "$dir/elsewhere" "$dir/project")
  expect_code 1 "$?" "an absent firstmate home should still refuse"
  assert_contains "$out" "cannot resolve the root firstmate home from FM_HOME: $dir/no-such-home" \
    "the refusal did not name the home it could not resolve"
  assert_not_contains "$out" "$dir/project" \
    "the refusal blamed the project for a home that could not be resolved"
  pass "an unresolvable root firstmate home is named, and the project is not blamed"
}

test_broken_secondmate_parent_chain_names_the_home() {
  local dir out
  dir=$(make_case secondmate-chain)
  fm_git_init_commit "$dir/project"
  printf 'route=not-a-real-route\n' > "$dir/home/.fm-secondmate-parent"
  out=$(resolve_lock "$dir/home" "$dir/elsewhere" "$dir/project")
  expect_code 1 "$?" "an unparseable secondmate parent record should still refuse"
  assert_contains "$out" "cannot resolve the root firstmate home from FM_HOME: $dir/home" \
    "a broken secondmate parent chain did not name the home whose chain broke"
  pass "a broken secondmate parent chain names the home, not the project"
}

test_missing_recorded_parent_home_is_named() {
  local dir out depth parent record_home
  for depth in 1 2; do
    dir=$(make_case "missing-parent-$depth")
    fm_git_init_commit "$dir/project"
    parent="$dir/absent parent"
    record_home="$dir/home"
    if [ "$depth" -eq 2 ]; then
      record_home="$dir/intermediate"
      mkdir -p "$record_home"
      printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' \
        "$record_home" > "$dir/home/.fm-secondmate-parent"
    fi
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' \
      "$parent" > "$record_home/.fm-secondmate-parent"

    out=$(resolve_lock "$dir/home" "$dir/elsewhere" "$dir/project")
    expect_code 1 "$?" "a missing recorded parent home should still refuse"
    assert_contains "$out" "cannot resolve the recorded parent firstmate home: $parent" \
      "the refusal did not name the missing recorded parent home at depth $depth"
    assert_not_contains "$out" "$dir/home" \
      "the refusal named the existing child home instead of the missing parent"
    assert_absent "$parent" "the refusal created the missing parent home"

    out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/elsewhere" \
      bash -c '. "$1"; fm_firstmate_root_home "$FM_HOME"' _ "$LIB" 2>&1)
    expect_code 1 "$?" "root resolution without diagnostics should still refuse"
    [ -z "$out" ] || fail "root resolution without diagnostics should stay silent: $out"

    mkdir -p "$parent"
    out=$(resolve_lock "$dir/home" "$dir/elsewhere" "$dir/project")
    expect_code 1 "$?" "the resolved parent with no state directory should still refuse"
    assert_contains "$out" "the root firstmate home has no state directory: $parent/state" \
      "the refusal did not advance to the parent's missing state directory"
    assert_absent "$parent/state" "the refusal created the parent's missing state directory"

    mkdir -p "$parent/state"
    out=$(resolve_lock "$dir/home" "$dir/elsewhere" "$dir/project")
    expect_code 0 "$?" "the parent chain with a root state directory should resolve"
    case "$out" in
      "$parent/state/.treehouse-project-"*.lock) ;;
      *) fail "the resolved lock path did not name the parent root: $out" ;;
    esac
    assert_not_contains "$out" "fm_treehouse_project_lock_path:" \
      "the resolved parent chain emitted a refusal diagnostic"
    pass "a missing recorded parent at depth $depth is named until its root state exists"
  done
}

test_unenterable_absolute_origin_is_named() {
  local dir out
  dir=$(make_case origin-absolute)
  fm_git_init_commit "$dir/project"
  fm_git_init_commit "$dir/origin"
  git -C "$dir/project" remote add origin "$dir/origin"
  make_unenterable "$dir/origin"
  out=$(resolve_lock "$dir/home" "$dir/elsewhere" "$dir/project")
  expect_code 1 "$?" "an unenterable absolute origin directory should still refuse"
  assert_contains "$out" "project origin directory cannot be entered: $dir/origin" \
    "the refusal did not name the origin directory it could not enter"
  pass "an unenterable absolute origin directory is named in the refusal"
}

test_unenterable_relative_origin_is_named() {
  local dir out
  dir=$(make_case origin-relative)
  fm_git_init_commit "$dir/project"
  fm_git_init_commit "$dir/project/sibling"
  git -C "$dir/project" remote add origin sibling
  make_unenterable "$dir/project/sibling"
  out=$(resolve_lock "$dir/home" "$dir/elsewhere" "$dir/project")
  expect_code 1 "$?" "an unenterable relative origin directory should still refuse"
  assert_contains "$out" "project origin directory cannot be entered: $dir/project/sibling" \
    "the refusal did not name the relative origin directory it could not enter"
  pass "an unenterable relative origin directory is named in the refusal"
}

test_originless_non_git_project_is_named() {
  local dir out
  dir=$(make_case originless-non-git)
  mkdir -p "$dir/project"
  out=$(resolve_lock "$dir/home" "$dir/elsewhere" "$dir/project")
  expect_code 1 "$?" "a project outside any git worktree should still refuse"
  assert_contains "$out" "project has no origin and is not inside a git worktree: $dir/project" \
    "the refusal did not say the project has no origin and no worktree"
  pass "an origin-less non-git project is named in the refusal"
}

test_unenterable_worktree_top_is_named() {
  local dir out shim
  dir=$(make_case worktree-top)
  mkdir -p "$dir/project"
  # git reports a toplevel that is not there by the time it is entered: the
  # shape a checkout removed underneath a running spawn produces.
  shim=$(git_shim "$dir/shim" '
for a in "$@"; do
  [ "$a" = "--show-toplevel" ] && { echo "'"$dir"'/vanished"; exit 0; }
  [ "$a" = "get-url" ] && exit 1
done')
  out=$(resolve_lock "$dir/home" "$dir/elsewhere" "$dir/project" "$shim")
  expect_code 1 "$?" "a vanished worktree top should still refuse"
  assert_contains "$out" "project worktree top cannot be entered: $dir/vanished" \
    "the refusal did not name the worktree top it could not enter"
  pass "an unenterable worktree top is named in the refusal"
}

test_unhashable_identity_is_named() {
  local dir out shim
  dir=$(make_case identity-hash)
  mkdir -p "$dir/project"
  shim=$(git_shim "$dir/shim" '
for a in "$@"; do
  [ "$a" = "get-url" ] && { echo "https://example.invalid/x.git"; exit 0; }
  [ "$a" = "hash-object" ] && exit 1
done')
  out=$(resolve_lock "$dir/home" "$dir/elsewhere" "$dir/project" "$shim")
  expect_code 1 "$?" "an unusable git should still refuse"
  assert_contains "$out" "cannot hash the project lock identity" \
    "the refusal did not say the project identity could not be hashed"
  assert_contains "$out" "https://example.invalid/x.git" \
    "the refusal did not name the identity it failed to hash"
  pass "an identity that cannot be hashed is named in the refusal"
}

# The exit the investigation actually hit: a directory the same library creates
# unconditionally at bin/fm-wake-lib.sh:16, absent here because the state root
# was pointed elsewhere. The refusal must name the HOME's missing directory and
# must not read as a fault in the project.
test_missing_root_state_directory_is_named() {
  local dir out
  dir=$(make_case root-state-missing)
  fm_git_init_commit "$dir/project"
  rmdir "$dir/home/state"
  out=$(resolve_lock "$dir/home" "$dir/elsewhere" "$dir/project")
  expect_code 1 "$?" "a root home with no state directory should still refuse"
  assert_contains "$out" "the root firstmate home has no state directory: $dir/home/state" \
    "the refusal did not name the home's missing state directory"
  assert_not_contains "$out" "project directory does not exist" \
    "the refusal blamed the project for a directory missing in the home"
  assert_absent "$dir/home/state" \
    "the refusal created the state directory instead of naming it"
  pass "a missing root state directory is named, not created, and the project is not blamed"
}

# The other half of the mutation pin: a diagnostic printed unconditionally would
# satisfy every case above, so the resolving path must stay silent.
test_resolved_lock_path_stays_silent() {
  local dir out
  dir=$(make_case resolves)
  fm_git_init_commit "$dir/project"
  out=$(resolve_lock "$dir/home" "$dir/elsewhere" "$dir/project")
  expect_code 0 "$?" "a resolvable project lock should not refuse"
  assert_not_contains "$out" "fm_treehouse_project_lock_path:" \
    "a resolved lock path emitted a refusal diagnostic"
  case "$out" in
    "$dir/home/state/.treehouse-project-"*.lock) ;;
    *) fail "the resolved lock path was not the root home's project lock: $out" ;;
  esac
  pass "a resolved lock path is printed alone, with no diagnostic"
}

# End to end: the named cause has to survive the production call shape, where
# stdout is captured by command substitution and only stderr reaches the
# operator. It arrives alongside the caller's own line, not instead of it.
test_spawn_refusal_carries_the_named_cause() {
  local dir home fakebin out status
  dir=$(make_case spawn-e2e)
  home="$dir/spawn-home"
  fm_test_spawn_home "$home"
  fm_test_spawn_brief "$home" lock-naming-e2e
  fm_git_init_commit "$dir/project"
  fakebin=$(make_spawn_fakebin "$dir" orca)
  # The divergence that produced the original defect: the state root points away
  # from the home, so the library creates that directory and not the home's.
  mkdir -p "$dir/state-elsewhere"
  rmdir "$home/state" 2>/dev/null || rm -rf "$home/state"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$dir/user-home" \
    CLAUDE_CONFIG_DIR='' FM_BACKEND=orca \
    FM_STATE_OVERRIDE="$dir/state-elsewhere" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$dir/pane" TMUX="${TMUX:-fake,1,0}" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" lock-naming-e2e "$dir/project" --scout --backend tmux 2>&1)
  status=$?
  expect_code 1 "$status" "the spawn should refuse when the home has no state directory"$'\n'"$out"
  assert_contains "$out" "the root firstmate home has no state directory: $home/state" \
    "the spawn refusal did not carry the named cause to the operator"
  assert_contains "$out" "could not resolve the shared Treehouse project lock" \
    "the spawn refusal lost its own context line"
  pass "a spawn refusal carries the named cause alongside its context line"
}

test_missing_project_directory_is_named
test_unresolvable_root_home_is_named
test_broken_secondmate_parent_chain_names_the_home
test_missing_recorded_parent_home_is_named
test_unenterable_absolute_origin_is_named
test_unenterable_relative_origin_is_named
test_originless_non_git_project_is_named
test_unenterable_worktree_top_is_named
test_unhashable_identity_is_named
test_missing_root_state_directory_is_named
test_resolved_lock_path_stays_silent
test_spawn_refusal_carries_the_named_cause

echo "# all fm-treehouse-lock-naming tests passed"
