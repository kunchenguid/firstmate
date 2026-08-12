#!/usr/bin/env bash
# Regression test for the identity a retiring secondmate home owns
# (bin/fm-teardown.sh's remove_firstmate_home).
#
# A leased firstmate home keeps its directory across `treehouse return`, and
# every artifact that makes it a HOME rather than a checkout - the
# .fm-secondmate-home and .fm-secondmate-parent markers and the data/, state/,
# config/ and projects/ directories - is gitignored, so the pool's own
# clean-and-reset leaves all of it in place. Confirmed against treehouse v2.1.1
# by the cases below, which lease a real worktree, seed it, retire it, and read
# what the pool hands back. Without retirement clearing that identity, the next
# task is handed a worktree still wearing a retired secondmate's identity, which
# the spawn-time isolation guard then refuses (that end of the contract is
# tests/fm-spawn-worktree-identity.test.sh) - a pool slot lost until someone
# deletes a file by hand.
#
# The cleanup is transactional, exactly like the process-event state beside it:
# staged aside while the lease is still exclusively held and every ownership and
# safety check has passed, deleted only after the return succeeds, and put back
# unchanged when it fails, so a home is never left half cleared while its route
# is still registered.
#
# Isolation: every case builds a throwaway repository whose treehouse.toml sets
# root = "./", so the pool and its lease state live under that repository's own
# .treehouse/ and nothing resolves into the live fleet pool. Leases are taken
# non-interactively with `treehouse get --lease`. The whole tree is removed on
# exit. Without the real treehouse binary the pooled lifecycle cannot be driven
# at all, so this file reports itself as not run rather than passing vacuously.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
MARKER=.fm-secondmate-home
PARENT_MARKER=.fm-secondmate-parent

if ! command -v treehouse >/dev/null 2>&1; then
  echo "# fm-teardown-home-identity tests not run: driving a pooled home lifecycle needs the real treehouse binary"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-teardown-home-identity)
# Every path here is physically resolved: treehouse records a leased worktree
# under the pool root it was configured with, while teardown asks it to return
# the physically resolved home, and on macOS a /var temp root differs from its
# /private/var reality. A logical fixture would make the pool disown its own
# worktree before the code under test was reached.
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
fm_git_identity

# A tmux that answers the endpoint questions teardown asks and logs the window
# operations, so a case can tell a refusal that stopped before any runtime
# action from one that ran the whole retirement.
make_teardown_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  printf '❯\n' > "$dir/pane.txt"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|new-window|send-keys|kill-window)
    printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
    exit 0
    ;;
  list-windows)
    printf '%s\n' "${FM_FAKE_TMUX_WINDOW:-}"
    exit 0
    ;;
  capture-pane)
    cat "${FM_FAKE_TMUX_CAPTURE:?}"
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# A treehouse that is the real one for every subcommand except `return`, which
# fails the way a still-held lease or a wedged worktree does. Only the
# failed-return case installs it, so every other case exercises the real pool.
install_failing_return_treehouse() {
  local fakebin=$1 real
  real=$(command -v treehouse)
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = return ]; then
  echo "treehouse: refusing to return worktree (simulated)" >&2
  exit 1
fi
exec $(printf '%q' "$real") "\$@"
SH
  chmod +x "$fakebin/treehouse"
}

# make_pool_case <name>: a throwaway firstmate-shaped repository with its own
# treehouse pool, plus the fleet home that runs the retirement.
make_pool_case() {
  local name=$1
  CASE_DIR="$TMP_ROOT/$name"
  CASE_REPO="$CASE_DIR/repo"
  CASE_FLEET="$CASE_DIR/fleet"
  CASE_FAKEBIN=$(make_teardown_fakebin "$CASE_DIR/fake")
  CASE_LOG="$CASE_DIR/fake/tmux.log"
  : > "$CASE_LOG"

  mkdir -p "$CASE_REPO/bin" "$CASE_DIR/pool"
  git -C "$CASE_REPO" init -q -b main .
  printf 'throwaway firstmate home material\n' > "$CASE_REPO/AGENTS.md"
  printf '#!/usr/bin/env bash\n' > "$CASE_REPO/bin/placeholder.sh"
  # A real firstmate checkout gitignores exactly these, which is why the pool's
  # clean-and-reset cannot remove them and retirement has to.
  printf '%s\n' 'data/' 'state/' 'config/' 'projects/' "$MARKER" "$PARENT_MARKER" 'treehouse.toml' \
    > "$CASE_REPO/.gitignore"
  # The pool sits inside this case's throwaway tree but OUTSIDE the repository,
  # which is where a real fleet keeps it: a home under FM_ROOT is refused as a
  # removal target long before any of this. The config stays untracked so the
  # leased worktrees are clean checkouts of the repository alone.
  printf 'max_trees = 4\nroot = "%s"\n' "$CASE_DIR/pool" > "$CASE_REPO/treehouse.toml"
  git -C "$CASE_REPO" add -A
  git -C "$CASE_REPO" commit -qm "throwaway firstmate repo"

  mkdir -p "$CASE_FLEET/state" "$CASE_FLEET/data" "$CASE_FLEET/config" "$CASE_FLEET/projects"
}

lease_pool_worktree() {  # <holder>
  ( cd "$CASE_REPO" && treehouse get --lease --lease-holder "$1" )
}

# seed_pool_home <home> <id>: the identity and operational state bin/fm-home-seed.sh
# leaves on a leased home, with recognizable content so a case can prove the
# restore path put back what it took rather than a fresh empty shell.
seed_pool_home() {
  local home=$1 id=$2
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
  printf 'backlog for %s\n' "$id" > "$home/projects/notes.md"
  printf 'codex\n' > "$home/config/crew-harness"
  printf '%s\n' "$id" > "$home/$MARKER"
  printf 'route=local\nhome=%s\n' "$CASE_FLEET" > "$home/$PARENT_MARKER"
}

# register_secondmate <id> <home>: the task metadata and registry route that make
# this home a retirable secondmate of the fleet home.
register_secondmate() {
  local id=$1 home=$2
  cat > "$CASE_FLEET/state/$id.meta" <<EOF
window=firstmate:fm-$id
worktree=$home
project=$home
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$home
projects=alpha
EOF
  printf '%s\n' "- $id - design domain (home: $home; scope: design domain; projects: alpha; added 2026-06-22)" \
    > "$CASE_FLEET/data/secondmates.md"
}

run_teardown() {  # <id> [extra args...]
  local id=$1
  shift
  FM_ROOT_OVERRIDE="$CASE_REPO" FM_HOME="$CASE_FLEET" \
    FM_FAKE_TMUX_LOG="$CASE_LOG" FM_FAKE_TMUX_CAPTURE="$CASE_DIR/fake/pane.txt" \
    FM_FAKE_TMUX_WINDOW="fm-$id" \
    FM_TEARDOWN_GUARD_DONE=1 \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$TEARDOWN" "$id" "$@" 2>&1
}

# assert_home_identity_intact <home> <id> <msg>: every owned artifact is present
# with the content the seeding put there.
assert_home_identity_intact() {
  local home=$1 id=$2 msg=$3 name
  for name in "$MARKER" "$PARENT_MARKER" data state config projects; do
    [ -e "$home/$name" ] || fail "$msg (missing $name)"
  done
  assert_grep "$id" "$home/$MARKER" "$msg (marker no longer names $id)"
  assert_grep "charter for $id" "$home/data/charter.md" "$msg (charter content lost)"
  assert_grep "backlog for $id" "$home/projects/notes.md" "$msg (projects content lost)"
}

# assert_home_identity_cleared <home> <msg>: what the pool hands back is a
# checkout, carrying none of the retired home's identity.
assert_home_identity_cleared() {
  local home=$1 msg=$2 name
  for name in "$MARKER" "$PARENT_MARKER" data state config projects; do
    if [ -e "$home/$name" ] || [ -L "$home/$name" ]; then
      fail "$msg ($name survived retirement at $home/$name)"
    fi
  done
}

# No staging directory may outlive the retirement in either direction: a leftover
# one is identity sitting outside any home, which is what the transaction exists
# to prevent.
assert_no_identity_staging() {
  local msg=$1 leftover
  leftover=$(find "$CASE_DIR" -maxdepth 6 -name '.fm-home-identity.*' -print -quit 2>/dev/null || true)
  [ -z "$leftover" ] || fail "$msg (staged identity left behind at $leftover)"
}

# 1. Identity is never cleared early or speculatively: a home in service keeps
# everything it owns while the fleet does ordinary work around it, including a
# retirement of a DIFFERENT secondmate in the same pool.
test_seeded_identity_survives_ordinary_use() {
  local id other_id home other_home out status
  id=identity-keep-t1
  other_id=identity-other-t1
  make_pool_case teardown-identity-keep
  home=$(lease_pool_worktree "$id")
  other_home=$(lease_pool_worktree "$other_id")
  seed_pool_home "$home" "$id"
  seed_pool_home "$other_home" "$other_id"
  register_secondmate "$other_id" "$other_home"

  out=$(run_teardown "$other_id")
  status=$?
  expect_code 0 "$status" "retiring one secondmate should succeed"$'\n'"--- output ---"$'\n'"$out"
  assert_home_identity_intact "$home" "$id" "an in-service home lost identity while another secondmate retired"
  assert_no_identity_staging "an in-service home's identity was staged"
  pass "a seeded home in service keeps its identity and operational state"
}

# 2. The reported failure, driven end to end: after a successful retirement the
# pool's checkout carries none of the retired home's identity.
test_retirement_returns_a_clean_checkout() {
  local id home out status
  id=identity-clean-t2
  make_pool_case teardown-identity-clean
  home=$(lease_pool_worktree "$id")
  seed_pool_home "$home" "$id"
  register_secondmate "$id" "$home"

  out=$(run_teardown "$id")
  status=$?
  expect_code 0 "$status" "retiring a leased secondmate home should succeed"$'\n'"--- output ---"$'\n'"$out"
  [ -d "$home" ] || fail "the pool no longer holds the returned checkout at $home"
  assert_home_identity_cleared "$home" "the returned pool checkout still wears the retired home's identity"
  assert_no_identity_staging "retirement left its staged identity behind"
  assert_absent "$CASE_FLEET/state/$id.meta" "retirement kept the task metadata"
  pass "a successful retirement returns a reusable checkout with no home residue"
}

# 3. The transaction's failure direction: FirstMate preserves a home whose lease
# could not be released, so a failed return must put back everything it staged
# and leave the route registered.
test_failed_return_restores_the_home() {
  local id home out status
  id=identity-failed-return-t3
  make_pool_case teardown-identity-failed-return
  home=$(lease_pool_worktree "$id")
  seed_pool_home "$home" "$id"
  register_secondmate "$id" "$home"
  install_failing_return_treehouse "$CASE_FAKEBIN"

  out=$(run_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "teardown reported success after the treehouse return failed"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "treehouse return failed" "teardown did not report the failed return"
  assert_home_identity_intact "$home" "$id" "a home whose return failed did not get its identity back"
  assert_no_identity_staging "a failed return left the staged identity outside the home"
  assert_present "$CASE_FLEET/state/$id.meta" \
    "teardown cleared the task metadata of a home whose return failed"
  assert_grep "$id" "$CASE_FLEET/data/secondmates.md" \
    "teardown dropped the registry route of a home whose return failed"
  pass "a failed return restores the complete home and keeps its registration"
}

# 4. Malformed identity is a refusal, not a guess: an operational path that is a
# symlink cannot be cleared without reaching outside the home, so retirement
# stops and changes nothing.
test_symlinked_identity_artifact_refuses() {
  local id home out status
  id=identity-symlink-t4
  make_pool_case teardown-identity-symlink
  home=$(lease_pool_worktree "$id")
  seed_pool_home "$home" "$id"
  register_secondmate "$id" "$home"
  mkdir -p "$home/real-state"
  rm -rf "${home:?}/state"
  ln -s "$home/real-state" "$home/state"

  out=$(run_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "teardown retired a home whose state directory is a symlink"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "symlinked identity artifact" \
    "teardown did not explain the refusal of a symlinked identity artifact"
  [ -L "$home/state" ] || fail "teardown removed the symlinked state directory it refused to clear"
  [ -d "$home/real-state" ] || fail "teardown removed what the symlinked state directory pointed at"
  assert_grep "$id" "$home/$MARKER" "teardown cleared the marker of a home it refused to retire"
  assert_no_identity_staging "a refused retirement staged identity anyway"
  assert_present "$CASE_FLEET/state/$id.meta" \
    "teardown cleared the task metadata of a home it refused to retire"
  pass "a symlinked identity artifact refuses retirement instead of guessing"
}

# 5. Resemblance is not ownership: another leased checkout in the same pool, with
# the same shape and no route to this fleet, is not touched by a retirement.
test_unrelated_checkout_is_untouched() {
  local id home bystander out status
  id=identity-bystander-t5
  make_pool_case teardown-identity-bystander
  home=$(lease_pool_worktree "$id")
  bystander=$(lease_pool_worktree bystander)
  seed_pool_home "$home" "$id"
  mkdir -p "$bystander/data"
  printf 'unrelated work\n' > "$bystander/data/work.md"
  printf '%s\n' 'unrelated-secondmate' > "$bystander/$MARKER"
  register_secondmate "$id" "$home"

  out=$(run_teardown "$id")
  status=$?
  expect_code 0 "$status" "retiring the registered home should succeed"$'\n'"--- output ---"$'\n'"$out"
  assert_home_identity_cleared "$home" "the retired home's own identity survived"
  assert_grep "unrelated work" "$bystander/data/work.md" \
    "retirement removed an unrelated leased checkout's content"
  assert_grep "unrelated-secondmate" "$bystander/$MARKER" \
    "retirement cleared an unrelated leased checkout's marker"
  pass "an unrelated reusable checkout in the same pool is untouched"
}

# 6. Ownership is proved before anything is moved: a home marked for a different
# secondmate is refused with its identity and route completely intact, and
# before any runtime endpoint is touched.
test_ownership_check_precedes_cleanup() {
  local id home out status
  id=identity-ownership-t6
  make_pool_case teardown-identity-ownership
  home=$(lease_pool_worktree "$id")
  seed_pool_home "$home" "$id"
  register_secondmate "$id" "$home"
  printf '%s\n' 'someone-else' > "$home/$MARKER"

  out=$(run_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "teardown retired a home marked for another secondmate"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "marked for secondmate someone-else" \
    "teardown did not explain the ownership mismatch"
  assert_grep "someone-else" "$home/$MARKER" "teardown cleared the marker it could not prove it owned"
  assert_grep "charter for $id" "$home/data/charter.md" \
    "teardown cleared operational state it could not prove it owned"
  assert_no_identity_staging "an unproven target was staged anyway"
  assert_present "$CASE_FLEET/state/$id.meta" \
    "teardown cleared the task metadata of a home it could not prove it owned"
  pass "no identity is cleared before the ownership check passes"
}

# 7. The point of clearing identity at retirement: the slot goes back to the pool
# reusable, and the next lease gets a checkout a task can actually run in.
test_next_lease_is_reusable() {
  local id home out status next
  id=identity-release-t7
  make_pool_case teardown-identity-release
  home=$(lease_pool_worktree "$id")
  seed_pool_home "$home" "$id"
  register_secondmate "$id" "$home"

  out=$(run_teardown "$id")
  status=$?
  expect_code 0 "$status" "retiring a leased secondmate home should succeed"$'\n'"--- output ---"$'\n'"$out"
  next=$(lease_pool_worktree "next-holder")
  [ -n "$next" ] || fail "the pool refused a lease after the retirement"
  assert_home_identity_cleared "$next" "the next lease was handed a checkout still wearing a retired identity"
  pass "the next lease after a retirement is accepted and carries no home residue"
}

test_seeded_identity_survives_ordinary_use
test_retirement_returns_a_clean_checkout
test_failed_return_restores_the_home
test_symlinked_identity_artifact_refuses
test_unrelated_checkout_is_untouched
test_ownership_check_precedes_cleanup
test_next_lease_is_reusable

echo "# all fm-teardown-home-identity tests passed"
