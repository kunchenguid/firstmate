#!/usr/bin/env bash
# Regression tests for Treehouse pool-slot recognition and the per-slot owner
# claim under both the default <pool>/<slot>/<repo> layout and a templated
# worktree_path such as "/srv/slots/{repo}-{slot}", whose pool state lives
# under ~/.treehouse rather than beside the slots.
#
# A templated slot used to go unrecognised, so spawn wrote no claim and
# teardown of a stale record still ran `treehouse return --force` on a slot
# Treehouse had since handed to another task. A fake treehouse lists the pool;
# nothing here touches a real pool or ~/.treehouse.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-templated-slot)

# <case>/project with a commit, a Firstmate home, and a fakebin whose treehouse
# answers `status --json` with <case>/listing.json and logs every other call.
make_case() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin"
  git init -q "$dir/project"
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm init
  printf '[]\n' > "$dir/listing.json"
  : > "$dir/runtime.log"
  cat > "$dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = status ]; then cat '$dir/listing.json'; exit 0; fi
printf 'treehouse %s\n' "\$*" >> '$dir/runtime.log'
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/tmux"
  chmod +x "$dir/fakebin/treehouse" "$dir/fakebin/tmux"
  printf '%s\n' "$dir"
}

list_slots() {  # <case> <slot-path>...
  local dir=$1
  shift
  jq -cn '$ARGS.positional | map({path: ., status: "in-use"})' --args "$@" > "$dir/listing.json"
}

# shellcheck disable=SC2016 # Positional parameters expand in the child shell.
lib() {  # <case> <function> [args...]
  local dir=$1
  shift
  FM_HOME="$dir/home" PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1"; shift; "$@"' _ "$ROOT/bin/fm-wake-lib.sh" "$@"
}

is_pool_slot() {  # <case> <worktree>
  if lib "$1" fm_treehouse_pool_slot "$1/project" "$2"; then echo yes; else echo no; fi
}

test_default_and_templated_layouts() {
  local dir a b
  dir=$(make_case default)
  mkdir -p "$dir/pool/1" "$dir/pool/2"
  : > "$dir/pool/treehouse-state.json"
  git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
  git -C "$dir/project" worktree add -q --detach "$dir/pool/2/project"
  assert_equals yes "$(is_pool_slot "$dir" "$dir/pool/1/project")" \
    "a default-layout slot was not recognised without a Treehouse listing"
  assert_equals "$dir/pool/1/.fm-slot-owner" "$(lib "$dir" fm_treehouse_slot_owner_marker "$dir/pool/1/project")" \
    "a default-layout slot's claim moved from <pool>/<slot>/.fm-slot-owner"

  dir=$(make_case templated)
  a="$dir/slots/project-1"
  b="$dir/slots/project-2"
  mkdir -p "$dir/slots"
  git -C "$dir/project" worktree add -q --detach "$a"
  git -C "$dir/project" worktree add -q --detach "$b"
  assert_equals no "$(is_pool_slot "$dir" "$a")" "a templated slot Treehouse does not list was recognised"
  list_slots "$dir" "$a" "$b"
  assert_equals yes "$(is_pool_slot "$dir" "$a")" "a templated slot Treehouse lists was not recognised"
  assert_equals yes "$(is_pool_slot "$dir" "$b")" "the second templated slot was not recognised"
  assert_not_equals "$(lib "$dir" fm_treehouse_slot_owner_marker "$a")" \
    "$(lib "$dir" fm_treehouse_slot_owner_marker "$b")" "two templated slots share one claim"
  case "$(lib "$dir" fm_treehouse_slot_owner_marker "$a")" in
    "$dir/home/state/"*) ;;
    *) fail "a templated slot's claim is not in the Firstmate home's state" ;;
  esac
  pass "default and templated Treehouse slots are recognised, each with its own claim"
}

# The reproduced hazard: a stale record names a templated slot Treehouse has
# since handed to another task, which claimed it. Teardown of the stale record
# must clean up only its own records and leave the slot untouched.
test_stale_record_leaves_a_reassigned_templated_slot() {
  local dir slot rc=0
  dir=$(make_case stale)
  slot="$dir/slots/project-1"
  mkdir -p "$dir/slots"
  git -C "$dir/project" worktree add -q --detach "$slot"
  : > "$slot/new-holder-work"
  list_slots "$dir" "$slot"
  lib "$dir" fm_treehouse_slot_owner_claim "$slot" new-holder "$dir/home" || fail "the new holder could not claim its slot"
  fm_write_meta "$dir/home/state/stale-task.meta" "window=firstmate:fm-stale-task" \
    "endpoint_task_id=stale-task" "worktree=$slot" "project=$dir/project" "kind=scout"

  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" stale-task --force > "$dir/stdout" 2> "$dir/stderr" || rc=$?
  assert_equals 0 "$rc" "teardown of the stale record failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/stale-task.meta" "the stale record was not cleaned up"
  ! grep -q '^treehouse return' "$dir/runtime.log" || fail "the stale record returned the new holder's slot"
  assert_present "$slot/new-holder-work" "the stale record reset the new holder's copy"
  assert_contains "$(cat "$dir/stderr")" "reassigned to task new-holder" "teardown did not name the new holder"
  pass "a stale record leaves a templated slot another task has claimed untouched"
}

test_default_and_templated_layouts
test_stale_record_leaves_a_reassigned_templated_slot
