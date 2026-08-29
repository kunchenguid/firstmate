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
# root to a directory inside that case's own temporary tree and outside the
# repository, so the pool and its lease state live at <case>/pool/.treehouse/ and
# nothing resolves into the live fleet pool. Leases are taken non-interactively
# with `treehouse get --lease`. The whole tree is removed on exit. Without the
# real treehouse binary the pooled lifecycle cannot be driven at all, so this
# file reports itself as not run rather than passing vacuously.
#
# Both lifecycle paths that return a leased home are driven here, in both
# directions: retirement through bin/fm-teardown.sh and failed-seed rollback
# through bin/fm-home-seed.sh, each with a successful return and with a return
# that fails.
#
# Which refusals may release a lease is its own boundary, and the seed path
# drives both sides of it: a refusal that stops with this run's identity still on
# the slot keeps the lease, because returning it there hands the pool a worktree
# the spawn-time guard refuses; proven foreign ownership, the one refusal that
# wrote nothing on the slot, hands the lease back untouched.
#
# What makes a home retirable is one boundary, so the parity cases drive each
# layout through the pooled path AND through the standalone path where the home
# is a plain directory removed outright. Supported layouts retire on both;
# unsafe ones refuse on both with the same reason. A layout that only one path
# accepts would leave a pooled home unretirable and its lease never released,
# which is the same pool-slot leak in a new shape.
#
# The lease-identity comparison in the reuse case needs a JSON reader; without
# one that case says so and asserts slot reuse by path alone rather than failing.
#
# Two cases drive the recovery path's own failure modes: a staging that still
# holds content its manifest never named is kept and reported rather than
# deleted, and the double fault where the identity could not be put back names
# every location holding part of the home without rebuilding anything under it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
MARKER=.fm-secondmate-home
PARENT_MARKER=.fm-secondmate-parent
UNRECORDED=unrecorded-content
PROCEVENT_SOURCE=wait.source

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

# The same failing return, but it also drops a file into the identity staging
# first. That is the shape of a staging whose manifest cannot account for
# everything the staging holds - the state a partial manifest write would leave -
# reached at the one moment the staging exists and the transaction is about to
# recover it.
install_staging_polluting_treehouse() {
  local fakebin=$1 real
  real=$(command -v treehouse)
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = return ]; then
  for tree in "\${FM_FAKE_STAGING_PARENT:?}"/.fm-home-identity.*/tree; do
    [ -d "\$tree" ] || continue
    printf 'content no manifest names\n' > "\$tree/$UNRECORDED"
  done
  echo "treehouse: refusing to return worktree (simulated)" >&2
  exit 1
fi
exec $(printf '%q' "$real") "\$@"
SH
  chmod +x "$fakebin/treehouse"
}

# Process-event registrations on the home, which is what makes the double-fault
# branch reachable: without them teardown has nothing to snapshot and nothing to
# rearm. bin/fm-procevent.sh in the leased checkout is the sweep the cleanup step
# requires, and it is tracked so every worktree of the throwaway repo has it.
seed_procevent_state() {
  local home=$1
  mkdir -p "$home/state/procevent"
  printf 'registration\n' > "$home/state/procevent/$PROCEVENT_SOURCE"
}

# make_pool_case <name> [<max-trees>]: a throwaway firstmate-shaped repository
# with its own treehouse pool, plus the fleet home that runs the retirement.
# <max-trees> caps the pool: a case that must prove a slot was REUSED sets it to
# 1, so the pool has no fresh tree to hand out instead.
make_pool_case() {
  local name=$1 max_trees=${2:-4}
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
  # The sweep teardown requires of a home that carries process-event state. It is
  # tracked, so every leased worktree of this repository has it, and it only ever
  # touches the home it is pointed at.
  cat > "$CASE_REPO/bin/fm-procevent.sh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  sweep-home)
    [ "${2:-}" = --preflight ] || rm -f "${FM_HOME:?}/state/procevent"/*.source
    ;;
esac
exit 0
SH
  chmod +x "$CASE_REPO/bin/fm-procevent.sh"
  # A real firstmate checkout gitignores exactly these, which is why the pool's
  # clean-and-reset cannot remove them and retirement has to. The parity layouts'
  # symlink targets are ignored for the same reason: an untracked target would be
  # swept by the pool's own clean, and then a case asserting the target came off
  # the returned checkout would pass whether or not staging ever took it.
  printf '%s\n' 'data/' 'state/' 'config/' 'projects/' "$MARKER" "$PARENT_MARKER" 'treehouse.toml' \
    'internal-data' 'internal-config' 'internal-projects' 'identity-store' 'my store*co' \
    > "$CASE_REPO/.gitignore"
  # The pool sits inside this case's throwaway tree but OUTSIDE the repository,
  # which is where a real fleet keeps it: a home under FM_ROOT is refused as a
  # removal target long before any of this. The config stays untracked so the
  # leased worktrees are clean checkouts of the repository alone.
  printf 'max_trees = %s\nroot = "%s"\n' "$max_trees" "$CASE_DIR/pool" > "$CASE_REPO/treehouse.toml"
  git -C "$CASE_REPO" add -A
  git -C "$CASE_REPO" commit -qm "throwaway firstmate repo"

  mkdir -p "$CASE_FLEET/state" "$CASE_FLEET/data" "$CASE_FLEET/config" "$CASE_FLEET/projects"
}

lease_pool_worktree() {  # <holder>
  ( cd "$CASE_REPO" && treehouse get --lease --lease-holder "$1" )
}

# The lease allocation as treehouse's own --json record, which is where the pool
# publishes the identity of a lease (its path, id, and holder) for exactly this
# kind of non-interactive use. Reading it needs a JSON reader, so a machine
# without one still leases by path and says which assertion it had to drop.
lease_reader_available() {
  command -v python3 >/dev/null 2>&1
}

lease_pool_worktree_json() {  # <holder>
  ( cd "$CASE_REPO" && treehouse get --lease --lease-holder "$1" --json )
}

lease_json_field() {  # <json> <field>
  lease_reader_available || return 0
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$2" 2>/dev/null || true
}

return_pool_worktree() {  # <path>
  [ -n "$1" ] || return 0
  ( cd "$CASE_REPO" && treehouse return --force "$1" >/dev/null 2>&1 ) || true
}

# The one worktree a max_trees=1 pool holds, whatever treehouse named it.
sole_pool_worktree() {
  local wt
  for wt in "$CASE_DIR/pool/.treehouse"/*/*/repo; do
    [ -d "$wt" ] || continue
    printf '%s\n' "$wt"
    return 0
  done
  return 1
}

# A date that fails once the leased home carries its identity marker, i.e. only
# after bin/fm-home-seed.sh has written both markers and reached its registry
# write. That is the reported sequence - a seed that fails after seeding the
# identity - injected at a command the seeder shells out to rather than by
# reaching into it.
install_failing_date() {
  local fakebin=$1 real
  real=$(command -v date)
  cat > "$fakebin/date" <<SH
#!/usr/bin/env bash
set -u
for marker in "\${FM_FAKE_SEED_POOL:?}"/.treehouse/*/*/repo/$MARKER; do
  if [ -f "\$marker" ]; then
    echo "date: injected seed failure after the identity was written" >&2
    exit 1
  fi
done
exec $(printf '%q' "$real") "\$@"
SH
  chmod +x "$fakebin/date"
}

# An mktemp that fails for the identity staging alone, leaving every other
# temporary directory the seeder makes untouched. That is the shape of a staging
# that cannot be created at all - a read-only or full pool root - reached at the
# one moment the rollback holds a lease whose slot already carries the identity
# this run wrote and has moved nothing aside.
install_failing_identity_mktemp() {
  local fakebin=$1 real
  real=$(command -v mktemp)
  cat > "$fakebin/mktemp" <<SH
#!/usr/bin/env bash
set -u
for arg in "\$@"; do
  case "\$arg" in
    *.fm-home-identity.*)
      echo "mktemp: injected identity staging failure" >&2
      exit 1
      ;;
  esac
done
exec $(printf '%q' "$real") "\$@"
SH
  chmod +x "$fakebin/mktemp"
}

# A date that stamps ANOTHER secondmate's id onto the leased slot's marker before
# failing the seed, so the rollback meets proven foreign ownership: the slot
# carries an identity this run did not write. Injected at the same command as
# install_failing_date, i.e. only once both markers are already on disk.
install_marker_stealing_date() {
  local fakebin=$1 thief=$2 real
  real=$(command -v date)
  cat > "$fakebin/date" <<SH
#!/usr/bin/env bash
set -u
for marker in "\${FM_FAKE_SEED_POOL:?}"/.treehouse/*/*/repo/$MARKER; do
  if [ -f "\$marker" ]; then
    printf '%s\n' $(printf '%q' "$thief") > "\$marker"
    echo "date: injected seed failure after the identity was written" >&2
    exit 1
  fi
done
exec $(printf '%q' "$real") "\$@"
SH
  chmod +x "$fakebin/date"
}

# Whether the pool still refuses to hand out its one worktree, which is how a
# lease that was never released is observed from outside: a max_trees=1 pool with
# a released slot answers the next get with that same slot.
pool_lease_is_still_held() {
  local next
  next=$( ( cd "$CASE_REPO" && treehouse get --lease --lease-holder next-holder ) 2>/dev/null ) || return 0
  [ -n "$next" ] || return 0
  return_pool_worktree "$next"
  return 1
}

# A project-less seed of a pooled home. The charter brief is provided already
# filled so the seeder takes its ordinary path instead of scaffolding one, which
# is what puts the identity on the leased slot before the registry step fails.
run_home_seed() {  # <id>
  local id=$1
  mkdir -p "$CASE_FLEET/data/$id"
  cat > "$CASE_FLEET/data/$id/brief.md" <<EOF
# Charter
throwaway charter for $id

# Routing scope
throwaway scope

# Project clones
None. This is a project-less domain.
EOF
  FM_ROOT_OVERRIDE="$CASE_REPO" FM_HOME="$CASE_FLEET" \
    FM_SECONDMATE_CHARTER="throwaway charter for $id" \
    FM_SECONDMATE_SCOPE="throwaway scope" \
    FM_FAKE_SEED_POOL="$CASE_DIR/pool" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$ROOT/bin/fm-home-seed.sh" "$id" - --no-projects 2>&1
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
    FM_PROCEVENT_CLAIM_ROOT="$CASE_DIR/procevent-claims" \
    FM_FAKE_STAGING_PARENT="${FM_FAKE_STAGING_PARENT:-$CASE_DIR/pool}" \
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

# 4. Removability is one boundary, and these cases hold both sides of it to it.
# The same home layout is driven through the POOLED path, where retirement clears
# the identity and hands the checkout back, and through the STANDALONE path,
# where the home is a plain directory that retirement removes outright. A layout
# accepted by one and refused by the other would mean a pooled home could be
# permanently unretirable - its lease never released - purely for a shape the
# plain-directory path removes without complaint.
#
# build_parity_home <home> <id> <layout>: a seeded home wearing one layout.
# PARITY_TARGETS collects the home-relative paths that layout owns beyond the
# fixed artifact names, so a retired case can prove the resolved targets came off
# the returned checkout rather than only the links that pointed at them.
build_parity_home() {
  local home=$1 id=$2 layout=$3 opdir
  PARITY_TARGETS=""
  seed_pool_home "$home" "$id"
  case "$layout" in
    internal-symlink)
      for opdir in data config projects; do
        rm -rf "${home:?}/$opdir"
        mkdir -p "$home/internal-$opdir"
        printf 'owned %s\n' "$opdir" > "$home/internal-$opdir/keep.md"
        ln -s "$home/internal-$opdir" "$home/$opdir"
        PARITY_TARGETS="$PARITY_TARGETS
internal-$opdir"
      done
      ;;
    nested-owned-target)
      rm -rf "${home:?}/projects"
      mkdir -p "$home/data/projects-store"
      printf 'nested under another owned path\n' > "$home/data/projects-store/keep.md"
      ln -s "$home/data/projects-store" "$home/projects"
      PARITY_TARGETS="
data/projects-store"
      ;;
    # A resolved target whose name carries a space and a glob character. Nothing
    # about the layout is unusual to the removable-home contract, but an
    # inventory that word-split or glob-expanded its own entries would invent a
    # path that does not exist, fail staging, and strand the lease on the pooled
    # path while the standalone path removed the same home without complaint.
    shell-hostile-target)
      rm -rf "${home:?}/projects"
      mkdir -p "$home/my store*co"
      printf 'owned through an awkward name\n' > "$home/my store*co/keep.md"
      ln -s "$home/my store*co" "$home/projects"
      PARITY_TARGETS="
my store*co"
      ;;
    symlinked-marker)
      rm -f "${home:?}/$MARKER"
      printf '%s\n' "$id" > "$home/identity-store"
      ln -s "$home/identity-store" "$home/$MARKER"
      PARITY_TARGETS="
identity-store"
      ;;
    escaping-target)
      rm -rf "${home:?}/data"
      mkdir -p "$CASE_DIR/escaped-target"
      printf 'not the home\n' > "$CASE_DIR/escaped-target/keep.md"
      ln -s "$CASE_DIR/escaped-target" "$home/data"
      ;;
    dangling-link)
      rm -rf "${home:?}/data"
      ln -s "$home/never-created" "$home/data"
      ;;
    resolution-cycle)
      rm -rf "${home:?}/data"
      ln -s data "$home/data"
      ;;
    ancestor-target)
      rm -rf "${home:?}/data"
      ln -s "$home" "$home/data"
      ;;
    *) fail "unknown parity layout $layout" ;;
  esac
}

# run_parity_layout <layout> retired|refused [<shared-refusal-reason>]
run_parity_layout() {
  local layout=$1 expect=$2 reason=${3:-}
  local pooled_id standalone_id pooled standalone out status target pooled_targets
  make_pool_case "parity-$layout" 2
  pooled_id="parity-pooled-$layout"
  standalone_id="parity-alone-$layout"
  pooled=$(lease_pool_worktree "$pooled_id")
  standalone="$CASE_DIR/standalone-home"
  mkdir -p "$standalone"
  build_parity_home "$pooled" "$pooled_id" "$layout"
  pooled_targets=$PARITY_TARGETS
  build_parity_home "$standalone" "$standalone_id" "$layout"

  register_secondmate "$pooled_id" "$pooled"
  out=$(run_teardown "$pooled_id")
  status=$?
  if [ "$expect" = retired ]; then
    expect_code 0 "$status" "the pooled path refused the $layout layout"$'\n'"--- output ---"$'\n'"$out"
    assert_home_identity_cleared "$pooled" "the pooled $layout retirement left identity on the returned checkout"
    # The links coming off is only half of it: whatever they resolved to inside
    # the home has to come off too, or the next lease inherits the retired
    # secondmate's own content under another name.
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      if [ -e "$pooled/$target" ] || [ -L "$pooled/$target" ]; then
        fail "the pooled $layout retirement left the resolved target $target on the returned checkout"
      fi
    done <<EOF
$pooled_targets
EOF
    assert_no_identity_staging "the pooled $layout retirement left its staging behind"
  else
    [ "$status" -ne 0 ] || fail "the pooled path retired the $layout layout"$'\n'"--- output ---"$'\n'"$out"
    assert_contains "$out" "$reason" "the pooled $layout refusal did not give the shared reason"
    assert_present "$pooled/$MARKER" "the pooled $layout refusal cleared the marker anyway"
    assert_no_identity_staging "the pooled $layout refusal staged identity anyway"
  fi

  register_secondmate "$standalone_id" "$standalone"
  out=$(run_teardown "$standalone_id")
  status=$?
  if [ "$expect" = retired ]; then
    expect_code 0 "$status" "the standalone path refused the $layout layout the pooled path retired"$'\n'"--- output ---"$'\n'"$out"
    [ ! -e "$standalone" ] || fail "the standalone path left the $layout home behind"
  else
    [ "$status" -ne 0 ] || fail "the standalone path retired the $layout layout the pooled path refused"$'\n'"--- output ---"$'\n'"$out"
    assert_contains "$out" "$reason" "the standalone $layout refusal did not give the same reason as the pooled one"
    assert_present "$standalone/$MARKER" "the standalone $layout refusal removed the home anyway"
  fi
}

# The supported layouts: both paths retire them, and the pooled path takes each
# resolved in-home target with the link that named it. An operational directory
# symlinked inside the home, a target nested under another owned path, a target
# whose name is hostile to shell splitting, and an identity marker that is a link
# to a regular file, which the standalone gate accepts because its test follows
# links.
test_supported_layouts_retire_on_both_paths() {
  run_parity_layout internal-symlink retired
  run_parity_layout nested-owned-target retired
  run_parity_layout shell-hostile-target retired
  run_parity_layout symlinked-marker retired
  pass "supported home layouts retire through the pooled and the standalone path alike"
}

# The rejected layouts: both paths refuse them, for the same stated reason,
# because one validator owns that answer for both. An escape, a dangling link, a
# link that resolves nowhere because it points at itself, and a target that is an
# ancestor of the home.
test_rejected_layouts_refuse_on_both_paths() {
  local reason="resolves outside the secondmate home"
  run_parity_layout escaping-target refused "$reason"
  run_parity_layout dangling-link refused "$reason"
  run_parity_layout resolution-cycle refused "$reason"
  run_parity_layout ancestor-target refused "$reason"
  pass "unsafe home layouts refuse on both paths with the same reason"
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

# 7. The point of clearing identity at retirement: the RETIRED slot goes back to
# the pool reusable. The pool is capped at one tree here, so treehouse has no
# fresh worktree to hand out instead, and the case compares both the leased path
# and the lease identity: the same path under a NEW lease id is the slot being
# released and reacquired, not a lease that was never returned.
test_next_lease_is_reusable() {
  local id home out status next next_id first_id lease
  id=identity-release-t7
  make_pool_case teardown-identity-release 1
  if lease_reader_available; then
    lease=$(lease_pool_worktree_json "$id")
    first_id=$(lease_json_field "$lease" lease_id)
    home=$(lease_json_field "$lease" path)
  else
    first_id=
    home=$(lease_pool_worktree "$id")
  fi
  [ -n "$home" ] || fail "the throwaway pool did not report a leased worktree path"
  seed_pool_home "$home" "$id"
  register_secondmate "$id" "$home"

  out=$(run_teardown "$id")
  status=$?
  expect_code 0 "$status" "retiring a leased secondmate home should succeed"$'\n'"--- output ---"$'\n'"$out"
  if lease_reader_available; then
    lease=$(lease_pool_worktree_json "next-holder")
    next_id=$(lease_json_field "$lease" lease_id)
    next=$(lease_json_field "$lease" path)
  else
    next_id=
    next=$(lease_pool_worktree "next-holder")
  fi
  [ -n "$next" ] || fail "the pool refused a lease after the retirement"
  [ "$next" = "$home" ] || { return_pool_worktree "$next"; fail "the pool handed out $next instead of reusing the retired slot $home"; }
  if [ -n "$first_id" ] && [ -n "$next_id" ]; then
    [ "$next_id" != "$first_id" ] || { return_pool_worktree "$next"; fail "the pool reported the same lease id, so the retired lease was never released"; }
  else
    echo "# lease-id comparison not run: no JSON reader available, slot reuse asserted by path alone"
  fi
  assert_home_identity_cleared "$next" "the next lease was handed a checkout still wearing a retired identity"
  return_pool_worktree "$next"
  pass "the next lease after a retirement reuses the retired slot and carries no home residue"
}

# 8. Retirement is not the only path that hands a leased home back. A seed whose
# registry step fails rolls back and returns the lease it just acquired, after
# having already written that home's identity onto the slot, so it has to clear
# the same artifacts through the same transaction. Driven end to end through the
# real seeder against the real pool, with the failure injected at a command the
# seeder runs only after both markers are on disk.
test_seed_rollback_returns_a_clean_checkout() {
  local id out status leased
  id=identity-seedroll-t8
  make_pool_case teardown-identity-seedroll 1
  install_failing_date "$CASE_FAKEBIN"

  out=$(run_home_seed "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "the seed reported success although its registry step was made to fail"$'\n'"--- output ---"$'\n'"$out"
  # Without this the case could pass on a seed that aborted before it ever wrote
  # an identity, which would prove nothing about clearing one.
  assert_contains "$out" "injected seed failure after the identity was written" \
    "the seed failed before it wrote the identity, so the rollback had nothing to clear"$'\n'"--- output ---"$'\n'"$out"
  leased=$(sole_pool_worktree)
  [ -n "$leased" ] || fail "the throwaway pool holds no worktree after the rolled-back seed"
  assert_home_identity_cleared "$leased" "the rolled-back seed returned a slot still wearing the identity it wrote"
  assert_no_identity_staging "the rolled-back seed left its staged identity behind"
  pass "a rolled-back seed returns its lease with no seeded identity on the slot"
}

# 9. The same transaction's failure direction on the seed path: when the return
# itself fails, the identity this run wrote is put back rather than lost, and the
# operator is told the lease may still be held.
test_seed_rollback_failed_return_keeps_identity() {
  local id out status leased
  id=identity-seedroll-fail-t9
  make_pool_case teardown-identity-seedroll-fail 1
  install_failing_date "$CASE_FAKEBIN"
  install_failing_return_treehouse "$CASE_FAKEBIN"

  out=$(run_home_seed "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "the seed reported success although its registry step was made to fail"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "injected seed failure after the identity was written" \
    "the seed failed before it wrote the identity, so the rollback had nothing to restore"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "lease may still be held" \
    "the rolled-back seed did not report that the lease may still be held"
  leased=$(sole_pool_worktree)
  [ -n "$leased" ] || fail "the throwaway pool holds no worktree after the rolled-back seed"
  assert_grep "$id" "$leased/$MARKER" \
    "a rolled-back seed whose return failed did not put its identity marker back"
  assert_present "$leased/$PARENT_MARKER" \
    "a rolled-back seed whose return failed did not put its parent binding back"
  assert_no_identity_staging "a failed seed-rollback return left the staged identity outside the home"
  pass "a seed rollback whose return fails restores the identity it staged"
}

# 10. Releasing a lease is not the conservative answer on the seed path, it is
# the destructive one. Every refusal except proven foreign ownership stops with
# THIS run's markers still on the slot, so returning it there hands the pool a
# worktree the spawn-time isolation guard refuses for every task dispatched into
# it, until a human deletes a gitignored file. The lease is kept instead. Driven
# through the real seeder with the identity staging made impossible to create,
# which is the mktemp failure a read-only or full pool root produces.
test_seed_rollback_unstageable_identity_keeps_the_lease() {
  local id out status leased
  id=identity-seedroll-keep-ta
  make_pool_case teardown-identity-seedroll-keep 1
  install_failing_date "$CASE_FAKEBIN"
  install_failing_identity_mktemp "$CASE_FAKEBIN"

  out=$(run_home_seed "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "the seed reported success although its registry step was made to fail"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "injected seed failure after the identity was written" \
    "the seed failed before it wrote the identity, so the rollback had nothing to keep"$'\n'"--- output ---"$'\n'"$out"
  # Without this the case could pass on a rollback that cleared the identity
  # successfully and released the lease for the right reason.
  assert_contains "$out" "injected identity staging failure" \
    "the identity staging was never attempted, so no refusal cause fired"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "its lease is kept" \
    "the rollback did not report that it kept the lease it could not clear"$'\n'"--- output ---"$'\n'"$out"
  leased=$(sole_pool_worktree)
  [ -n "$leased" ] || fail "the throwaway pool holds no worktree after the rolled-back seed"
  assert_grep "$id" "$leased/$MARKER" \
    "the rollback removed the marker it had just reported it could not clear"
  assert_no_identity_staging "a refused staging left something behind in the pool"
  pool_lease_is_still_held \
    || fail "the pool handed its one slot out again, so a rollback that could not clear this run's identity released the lease anyway"
  pass "a seed rollback that cannot clear its own identity keeps the lease instead of poisoning the slot"
}

# 11. The one refusal that does release it, and the reason the distinction is
# worth having: a slot marked for a DIFFERENT secondmate carries nothing this
# rollback wrote, so holding its lease hostage would strand a slot this run has
# no claim on. It goes back untouched, marker and all.
test_seed_rollback_foreign_identity_returns_the_lease() {
  local id out status leased next
  id=identity-seedroll-foreign-tb
  make_pool_case teardown-identity-seedroll-foreign 1
  install_marker_stealing_date "$CASE_FAKEBIN" someone-else

  out=$(run_home_seed "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "the seed reported success although its registry step was made to fail"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "marked for secondmate someone-else" \
    "the rollback did not explain the ownership mismatch"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "returning its lease unchanged" \
    "the rollback did not report handing the lease back untouched"$'\n'"--- output ---"$'\n'"$out"
  leased=$(sole_pool_worktree)
  [ -n "$leased" ] || fail "the throwaway pool holds no worktree after the rolled-back seed"
  assert_grep "someone-else" "$leased/$MARKER" \
    "the rollback cleared an identity it could not prove it owned"
  assert_no_identity_staging "an unproven target was staged anyway"
  # The pool is capped at one tree, so a lease granted at all is that slot having
  # been released rather than a fresh worktree being handed out.
  next=$(lease_pool_worktree next-holder) \
    || fail "the pool refused a lease, so a rollback that owned nothing on the slot never released it"
  [ -n "$next" ] || fail "the pool reported no path for the lease after the rollback released the slot"
  assert_grep "someone-else" "$next/$MARKER" \
    "the released slot no longer carries the identity the rollback said it left untouched"
  return_pool_worktree "$next"
  pass "a seed rollback that owns nothing on the slot hands its lease back untouched"
}

# The recovery path's own safety: what the staging holds is not decided by its
# manifest alone. If the staging still carries content the manifest never named,
# deleting the staging would destroy the only copy of it, so retirement keeps the
# staging, says what it could not account for, and reports the failure rather
# than a success it cannot stand behind.
test_unaccounted_staging_is_kept_not_deleted() {
  local id home out status staging
  id=identity-unaccounted-t11
  make_pool_case teardown-identity-unaccounted
  home=$(lease_pool_worktree "$id")
  seed_pool_home "$home" "$id"
  register_secondmate "$id" "$home"
  FM_FAKE_STAGING_PARENT=$(dirname "$home")
  install_staging_polluting_treehouse "$CASE_FAKEBIN"

  out=$(run_teardown "$id")
  status=$?
  FM_FAKE_STAGING_PARENT=
  [ "$status" -ne 0 ] || fail "teardown reported success after leaving staged content unaccounted for"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "does not account for" \
    "teardown did not report that the staging held content its manifest never named"
  assert_contains "$out" "$UNRECORDED" "the refusal did not name the unaccounted content"
  staging=$(find "$(dirname "$home")" -maxdepth 1 -name '.fm-home-identity.*' -print -quit 2>/dev/null || true)
  [ -n "$staging" ] || fail "the staging was deleted although it still held unaccounted content"
  assert_present "$staging/tree/$UNRECORDED" "the unaccounted content was destroyed with the staging"
  assert_home_identity_intact "$home" "$id" "the home did not get back everything the manifest named"
  assert_present "$CASE_FLEET/state/$id.meta" \
    "teardown cleared the task metadata of a home it could not finish restoring"
  pass "a staging holding unaccounted content is kept and reported, never deleted"
}

# The double fault, where the return failed and the identity could not be fully
# restored: the home's real state/ is sitting in the staging, so its process
# events are not rearmed underneath it, and the diagnostic names every location
# that holds part of the home.
test_double_fault_names_every_recovery_location() {
  local id home out status
  id=identity-doublefault-t12
  make_pool_case teardown-identity-doublefault
  home=$(lease_pool_worktree "$id")
  seed_pool_home "$home" "$id"
  seed_procevent_state "$home"
  register_secondmate "$id" "$home"
  FM_FAKE_STAGING_PARENT=$(dirname "$home")
  install_staging_polluting_treehouse "$CASE_FAKEBIN"

  out=$(run_teardown "$id")
  status=$?
  FM_FAKE_STAGING_PARENT=
  [ "$status" -ne 0 ] || fail "teardown reported success on the double-fault path"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" ".fm-home-identity." "the diagnostic did not name the identity staging"
  assert_contains "$out" ".fm-procevent-restore." "the diagnostic did not name the process-event staging"
  assert_contains "$out" "stay retired" "the diagnostic did not say the waits were left retired"
  assert_absent "$home/state/procevent/$PROCEVENT_SOURCE" \
    "teardown rearmed process events into a home whose state was still staged"
  pass "the double-fault path names every location holding the home and rearms nothing under it"
}

test_seeded_identity_survives_ordinary_use
test_retirement_returns_a_clean_checkout
test_failed_return_restores_the_home
test_unaccounted_staging_is_kept_not_deleted
test_double_fault_names_every_recovery_location
test_supported_layouts_retire_on_both_paths
test_rejected_layouts_refuse_on_both_paths
test_unrelated_checkout_is_untouched
test_ownership_check_precedes_cleanup
test_next_lease_is_reusable
test_seed_rollback_returns_a_clean_checkout
test_seed_rollback_failed_return_keeps_identity
test_seed_rollback_unstageable_identity_keeps_the_lease
test_seed_rollback_foreign_identity_returns_the_lease

echo "# all fm-teardown-home-identity tests passed"
