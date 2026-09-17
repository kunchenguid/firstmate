#!/usr/bin/env bash
# Regression tests for the Treehouse allocation ownership guard and canonical
# repository identity (bin/fm-wake-lib.sh).
#
# The guard must refuse a fresh allocation over a retained pool slot that has no
# durable reservation, and must leave every ambiguous pool entry unavailable
# until an operator has reconciled it. These cases drive the guard and identity
# helpers directly against real Git worktrees and a fixture pool layout, never
# against a live treehouse.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-ownership)

# --- fixture ----------------------------------------------------------------

# make_pool_fixture <case-dir>
# Builds a project checkout plus a Treehouse-shaped pool slot at
# <case-dir>/pool/1/project (a linked worktree of the project) with the pool's
# state file. Sets PROJECT, POOL, SLOT, CLAIM.
make_pool_fixture() {
  local dir=$1
  PROJECT="$dir/project"
  POOL="$dir/pool"
  SLOT="$POOL/1/project"
  CLAIM="$POOL/1/.fm-slot-owner"
  mkdir -p "$POOL/1"
  git init --quiet -b main "$PROJECT"
  printf 'base\n' > "$PROJECT/README.md"
  git -C "$PROJECT" add README.md
  git -C "$PROJECT" -c user.name=T -c user.email=t@example.invalid commit -qm init
  git -C "$PROJECT" worktree add --quiet --detach "$SLOT" HEAD
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$POOL/treehouse-state.json"
}

# make_home <case-dir> -> home path with a state dir and no secondmate registry.
make_home() {
  local home="$1/home"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# write_meta <home> <id> [key=val ...]
write_meta() {
  local home=$1 id=$2
  shift 2
  {
    for pair in "$@"; do printf '%s\n' "$pair"; done
  } > "$home/state/$id.meta"
}

# run_guard <home> <project> -> "rc|refusal"
run_guard() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    fm_treehouse_preacquire_guard "$2"
    rc=$?
    printf "%s|%s" "$rc" "${FM_TREEHOUSE_PREACQUIRE_REFUSAL:-}"
  ' _ "$ROOT" "$2"
}

# run_lock_path <home> <path> -> lock path (or empty on failure)
run_lock_path() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    fm_treehouse_project_lock_path "$2" || true
  ' _ "$ROOT" "$2"
}

# run_conditional_return <fakebin> -> "0" or "1"
run_conditional_return() {
  PATH="$1:$PATH" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    if treehouse_supports_conditional_return; then printf 0; else printf 1; fi
  ' _ "$ROOT"
}

# --- canonical identity -----------------------------------------------------

test_local_only_linked_root_shares_one_lock() {
  local dir home project slot lock1 lock2
  dir="$TMP_ROOT/identity-linked"
  make_pool_fixture "$dir"
  home=$(make_home "$dir")
  project="$dir/project"
  slot="$dir/pool/1/project"

  lock1=$(run_lock_path "$home" "$project")
  lock2=$(run_lock_path "$home" "$slot")
  [ -n "$lock1" ] || fail "primary root of an origin-less project did not resolve a lock"
  [ "$lock1" = "$lock2" ] \
    || fail "a linked worktree of an origin-less project resolved a different lock (primary '$lock1', linked '$lock2')"
  pass "an origin-less project and its linked worktree resolve to one canonical lock"
}

test_origin_shared_clones_share_one_lock() {
  local dir home proja projb origin locka lockb
  dir="$TMP_ROOT/identity-origin"
  home=$(make_home "$dir")
  proja="$dir/proja"
  projb="$dir/projb"
  origin="$dir/origin.git"
  git init --quiet -b main "$proja"
  printf 'base\n' > "$proja/README.md"
  git -C "$proja" add README.md
  git -C "$proja" -c user.name=T -c user.email=t@example.invalid commit -qm init
  git clone --quiet --bare "$proja" "$origin"
  git -C "$proja" remote add origin "file://$origin"
  git clone --quiet "file://$origin" "$projb"

  locka=$(run_lock_path "$home" "$proja")
  lockb=$(run_lock_path "$home" "$projb")
  [ -n "$locka" ] || fail "origin-shared clone did not resolve a lock"
  [ "$locka" = "$lockb" ] \
    || fail "two clones of one origin resolved different locks ('$locka' vs '$lockb')"
  pass "two clones of one origin resolve to the one shared lock"
}

# --- conditional-return capability -------------------------------------------

test_conditional_return_capability_detection() {
  local dir fb rc
  dir="$TMP_ROOT/capability"
  fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_HAVE_COND_RETURN:-0}" = 1 ]; then
    printf 'Usage: treehouse return [--force] [--if-lease-holder <holder>]\n'
  else
    printf 'Usage: treehouse return [--force]\n'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fb/treehouse"

  rc=$(FM_FAKE_HAVE_COND_RETURN=0 run_conditional_return "$fb")
  [ "$rc" = 1 ] || fail "treehouse without --if-lease-holder was reported as supporting conditional return"
  rc=$(FM_FAKE_HAVE_COND_RETURN=1 run_conditional_return "$fb")
  [ "$rc" = 0 ] || fail "treehouse advertising --if-lease-holder was not recognized"
  pass "conditional-return capability is detected from treehouse return --help"
}

# --- guard refusals ---------------------------------------------------------

test_fresh_pool_without_retained_records_passes() {
  local dir home project out rc refusal
  dir="$TMP_ROOT/guard-fresh"
  make_pool_fixture "$dir"
  home=$(make_home "$dir")
  project="$dir/project"

  out=$(run_guard "$home" "$project")
  rc=${out%%|*}
  [ "$rc" = 0 ] || fail "a pool with no retained records was refused: ${out#*|}"
  pass "a pool with no retained records allocates freely"
}

test_retained_record_without_reservation_refuses() {
  local dir home project out rc refusal
  dir="$TMP_ROOT/guard-retained"
  make_pool_fixture "$dir"
  home=$(make_home "$dir")
  project="$dir/project"
  write_meta "$home" task-retained "worktree=$SLOT"
  printf 'task=task-retained\nhome=%s\n' "$home" > "$CLAIM"

  out=$(run_guard "$home" "$project")
  rc=${out%%|*}
  refusal=${out#*|}
  [ "$rc" -ne 0 ] || fail "a retained record without a durable reservation was not refused"
  assert_contains "$refusal" "no durable allocation reservation" \
    "the refusal did not name the missing durable reservation"
  pass "a retained slot without a durable reservation refuses the allocation"
}

test_retained_record_with_matching_reservation_passes() {
  local dir home project out rc
  dir="$TMP_ROOT/guard-reserved"
  make_pool_fixture "$dir"
  home=$(make_home "$dir")
  project="$dir/project"
  write_meta "$home" task-reserved "worktree=$SLOT" "allocation_id=alloc-123"
  printf 'task=task-reserved\nhome=%s\nallocation_id=alloc-123\n' "$home" > "$CLAIM"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"alloc-123"}]}\n' "$SLOT" > "$POOL/treehouse-state.json"

  out=$(run_guard "$home" "$project")
  rc=${out%%|*}
  [ "$rc" = 0 ] || fail "a retained record with a durable reservation and matching claim was refused: ${out#*|}"
  pass "a retained slot with a durable reservation and matching claim is protected, not blocked"
}

test_missing_claim_refuses() {
  local dir home project out rc refusal
  dir="$TMP_ROOT/guard-missing-marker"
  make_pool_fixture "$dir"
  home=$(make_home "$dir")
  project="$dir/project"
  write_meta "$home" task-nomarker "worktree=$SLOT"

  out=$(run_guard "$home" "$project")
  rc=${out%%|*}
  refusal=${out#*|}
  [ "$rc" -ne 0 ] || fail "a retained record whose slot has no owner claim was not refused"
  assert_contains "$refusal" "no owner claim" \
    "the refusal did not name the missing legacy marker"
  pass "a retained slot with no owner claim refuses the allocation"
}

test_reassigned_claim_refuses() {
  local dir home project out rc refusal
  dir="$TMP_ROOT/guard-reassigned"
  make_pool_fixture "$dir"
  home=$(make_home "$dir")
  project="$dir/project"
  write_meta "$home" task-stale "worktree=$SLOT"
  printf 'task=task-successor\nhome=%s\n' "$home" > "$CLAIM"

  out=$(run_guard "$home" "$project")
  rc=${out%%|*}
  refusal=${out#*|}
  [ "$rc" -ne 0 ] || fail "a retained record whose slot is claimed by another task was not refused"
  assert_contains "$refusal" "task-successor" \
    "the refusal did not name the successor claimant"
  pass "a slot claimed by a different task than its retained record refuses the allocation"
}

test_unreadable_claim_refuses() {
  local dir home project out rc refusal
  dir="$TMP_ROOT/guard-unreadable"
  make_pool_fixture "$dir"
  home=$(make_home "$dir")
  project="$dir/project"
  write_meta "$home" task-unsafe "worktree=$SLOT"
  mkdir -p "$CLAIM"

  out=$(run_guard "$home" "$project")
  rc=${out%%|*}
  refusal=${out#*|}
  [ "$rc" -ne 0 ] || fail "a slot whose claim cannot be read was not refused"
  assert_contains "$refusal" "unsafe inventory file" \
    "the refusal did not name the unreadable claim"
  pass "an unreadable slot claim refuses the allocation"
}

test_duplicate_records_name_one_slot_refuse() {
  local dir home project out rc refusal
  dir="$TMP_ROOT/guard-duplicate"
  make_pool_fixture "$dir"
  home=$(make_home "$dir")
  project="$dir/project"
  write_meta "$home" task-a "worktree=$SLOT"
  write_meta "$home" task-b "worktree=$SLOT"
  printf 'task=task-a\nhome=%s\n' "$home" > "$CLAIM"

  out=$(run_guard "$home" "$project")
  rc=${out%%|*}
  refusal=${out#*|}
  [ "$rc" -ne 0 ] || fail "two records naming one slot were not refused"
  assert_contains "$refusal" "multiple retained task records" \
    "the refusal did not name the duplicate ownership"
  pass "two retained records naming one slot refuse the allocation"
}

test_originless_source_and_local_clone_share_one_lock() {
  local dir home source clone lock1 lock2
  dir="$TMP_ROOT/identity-clone"
  home=$(make_home "$dir")
  source="$dir/source"
  clone="$dir/clone"
  git init --quiet -b main "$source"
  printf 'base\n' > "$source/README.md"
  git -C "$source" add README.md
  git -C "$source" -c user.name=T -c user.email=t@example.invalid commit -qm init
  # A local clone records its source path as origin: the source is origin-less,
  # so its lock identity must still match the clone's local-path origin.
  git clone --quiet "$source" "$clone"

  lock1=$(run_lock_path "$home" "$source")
  lock2=$(run_lock_path "$home" "$clone")
  [ -n "$lock1" ] || fail "an origin-less source did not resolve a lock"
  [ "$lock1" = "$lock2" ] \
    || fail "an origin-less source and its local clone resolved different locks ('$lock1' vs '$lock2')"
  pass "an origin-less source and its local-path-origin clone share one lock"
}

test_local_only_linked_root_shares_one_lock
test_originless_source_and_local_clone_share_one_lock
test_origin_shared_clones_share_one_lock

test_conditional_return_capability_detection
test_fresh_pool_without_retained_records_passes
test_retained_record_without_reservation_refuses
test_retained_record_with_matching_reservation_passes
test_missing_claim_refuses
test_reassigned_claim_refuses
test_unreadable_claim_refuses
test_duplicate_records_name_one_slot_refuse

fixture_digest() {
  python3 - "$1" <<'PYTHON'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
h = hashlib.sha256()
for path in sorted(root.rglob('*')):
    h.update(str(path.relative_to(root)).encode())
    if path.is_symlink():
        h.update(str(path.readlink()).encode())
    elif path.is_file():
        h.update(path.read_bytes())
print(h.hexdigest())
PYTHON
}

# Each refusal must preserve the complete private fixture, including ignored
# payload, Git objects, allocator state and ownership claims.
test_inventory_refuses_ambiguous_ownership() {
  local mode dir home out before after
  for mode in orphan dead-pid false-token stale-token wrong-home malformed missing-entry foreign unsafe-meta missing-state; do
    dir="$TMP_ROOT/matrix-$mode"
    make_pool_fixture "$dir"
    home=$(make_home "$dir")
    printf 'secret fixture bytes\n' > "$SLOT/ignored-payload"
    printf 'ignored-payload\n' >> "$PROJECT/.git/info/exclude"
    case "$mode" in
      orphan) printf 'task=old\nhome=%s\n' "$home" > "$CLAIM" ;;
      dead-pid) printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":99999999}]}' "$SLOT" > "$POOL/treehouse-state.json" ;;
      false-token|stale-token|wrong-home)
        write_meta "$home" task "worktree=$SLOT" "allocation_id=alloc-1"
        printf 'task=task\nhome=%s\nallocation_id=alloc-1\n' "$home" > "$CLAIM"
        if [ "$mode" = stale-token ]; then
          printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"alloc-2"}]}' "$SLOT" > "$POOL/treehouse-state.json"
        elif [ "$mode" = wrong-home ]; then
          printf 'task=task\nhome=/unrelated\nallocation_id=alloc-1\n' > "$CLAIM"
        fi
        ;;
      malformed) printf '{' > "$POOL/treehouse-state.json" ;;
      missing-entry) printf '{"worktrees":[]}' > "$POOL/treehouse-state.json" ;;
      foreign)
        git init --quiet -b main "$dir/foreign"
        git -C "$dir/foreign" -c user.name=T -c user.email=t@example.invalid commit --allow-empty -qm init
        git -C "$dir/foreign" worktree add --quiet --detach "$POOL/2/foreign" HEAD
        printf '{"worktrees":[{"name":"1","path":"%s"},{"name":"2","path":"%s"}]}' "$SLOT" "$POOL/2/foreign" > "$POOL/treehouse-state.json"
        ;;
      unsafe-meta) ln -s "$dir/nonexistent" "$home/state/task.meta" ;;
      missing-state)
        # The configured prospective pool must be checked even without a
        # state file or a usable Git worktree to discover it through.
        rm "$POOL/treehouse-state.json"
        printf 'root = "%s"\n' "$dir" > "$PROJECT/treehouse.toml"
        python3 - "$PROJECT" "$dir" <<'PY'
import hashlib, pathlib, sys
project, root = sys.argv[1:]
pool = pathlib.Path(root)/'.treehouse'/('project-'+hashlib.sha256(project.encode()).hexdigest()[:6])
(pool/'1').mkdir(parents=True)
(pool/'1'/'payload').write_text('must survive')
PY
        ;;
    esac
    before=$(fixture_digest "$dir")
    out=$(run_guard "$home" "$PROJECT")
    [ "${out%%|*}" != 0 ] || fail "$mode inventory was accepted"
    after=$(fixture_digest "$dir")
    [ "$before" = "$after" ] || fail "$mode refusal changed fixture bytes"
    pass "$mode ownership refuses without changing any fixture bytes"
  done
}

test_claim_never_replaces_prior_owner() {
  local dir home out before
  dir="$TMP_ROOT/claim-publication"
  make_pool_fixture "$dir"
  home=$(make_home "$dir")
  printf 'task=old\nhome=%s\n' "$home" > "$CLAIM"
  before=$(cat "$CLAIM")
  out=$(FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_slot_owner_claim "$2" new "$3"; printf "%s" "$?"' _ "$ROOT" "$SLOT" "$home")
  [ "$out" != 0 ] || fail "claim replaced prior ownership"
  [ "$(cat "$CLAIM")" = "$before" ] || fail "refused claim changed prior owner"
  pass "claim publication never replaces prior ownership"
}

test_inventory_refuses_ambiguous_ownership
test_claim_never_replaces_prior_owner
