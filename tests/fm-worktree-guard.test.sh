#!/usr/bin/env bash
# Behavior tests for bin/fm-worktree-guard.sh - the pre-allocation pool guard.
#
# The defect (upstream kunchenguid/firstmate#1441): `treehouse status` reports a
# pool slot "available" when it has no lease, no live process, and a clean
# working tree. It does NOT consider whether HEAD carries commits unreachable
# from the default branch, so a slot holding a finished-but-unlanded branch is
# allocatable and the next `treehouse get` detaches it. Uncommitted content is
# separately protected by treehouse itself, so the exposure closed here is
# specifically: clean working tree + commits not on the default branch.
#
# These cases pin every branch of the guard over real throwaway git worktrees
# with a fake `treehouse` on PATH emitting canned `status --json`:
#   (a) unlanded branch, no owner record                 -> refuse, names evidence
#   (b) unlanded branch, owner identity MATCHES live pid -> refuse, owner alive
#   (c) unlanded branch, live pid but identity MISMATCH  -> refuse, owner DEAD
#       (the reboot pid-reuse case: a recorded pre-reboot pid resolving to an
#       unrelated live process must never read as falsely alive)
#   (d) unlanded branch, owner record with no identity   -> refuse, UNRESOLVED
#       (an absent record is never a released slot)
#   (e) demonstrably empty slot                          -> pass, silent
#   (f) dirty slot reported available                    -> refuse
#   (g) zero-ahead named branch                          -> pass, silent
#   (h) in-use slot holding unlanded work                -> pass (normal fleet
#       operation must not wedge: every live crewmate holds unlanded work)
#   (i) unparseable / failed treehouse output            -> refuse, fail closed
#   (j) missing jq                                       -> refuse, fail closed
#   (k) explicit operator authority                      -> exact path only
#   (l) owner-fields on an unoccupied worktree           -> empty, never invented
#   (m) the guard never mutates the slot it refuses
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-worktree-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-guard)
fm_git_identity

FAKE_PIDS=()
cleanup_pids() {
  local p
  for p in "${FAKE_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  fm_test_cleanup
}
trap cleanup_pids EXIT

# --- fixtures ---------------------------------------------------------------

# A project repo plus <n> pool-slot worktrees, mimicking a treehouse pool.
# Echoes the project dir; slots land at <proj>/../slots/<n>.
make_pool() {  # <case-name> <slot-count>
  local name=$1 count=$2 base proj i
  base="$TMP_ROOT/$name"
  proj="$base/proj"
  mkdir -p "$proj"
  git -C "$proj" init -q -b main
  printf 'base\n' > "$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" commit -qm initial
  for i in $(seq 1 "$count"); do
    git -C "$proj" worktree add --quiet --detach "$base/slots/$i" main
  done
  printf '%s\n' "$proj"
}

slot_path() {  # <proj> <n>
  printf '%s/slots/%s\n' "$(dirname "$1")" "$2"
}

# Put <slot> on a branch carrying <n> commits that are not on main.
give_unlanded_branch() {  # <slot> <branch> [n]
  local slot=$1 branch=$2 n=${3:-1} i
  git -C "$slot" checkout -q -b "$branch" main
  for i in $(seq 1 "$n"); do
    printf 'work %s\n' "$i" > "$slot/work-$i.txt"
    git -C "$slot" add "work-$i.txt"
    git -C "$slot" commit -qm "unlanded $i"
  done
}

# A fake `treehouse` whose `status --json` echoes the fixture, on a PATH shim.
# Any other subcommand fails loudly: the guard must never invoke one.
install_fake_treehouse() {  # <fakebin> <json>
  local fakebin=$1 json=$2
  printf '%s' "$json" > "$fakebin/../treehouse-status.json"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  cat "$(dirname "$0")/../treehouse-status.json"
  exit 0
fi
echo "fake treehouse: unexpected invocation: $*" >&2
exit 3
SH
  chmod +x "$fakebin/treehouse"
}

slot_json() {  # <name> <status> <path> ...
  local out="" name status path
  while [ $# -gt 0 ]; do
    name=$1 status=$2 path=$3
    shift 3
    [ -z "$out" ] || out="$out,"
    out="$out{\"name\":\"$name\",\"status\":\"$status\",\"path\":\"$path\",\"processes\":[]}"
  done
  printf '[%s]' "$out"
}

# Run the guard for <proj> with a canned pool and an optional state dir.
run_guard() {  # <proj> <json> [state-dir]
  local proj=$1 json=$2 state=${3:-} fakebin
  fakebin=$(fm_fakebin "$(dirname "$proj")")
  install_fake_treehouse "$fakebin" "$json"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="${state:-$(dirname "$proj")/state}" \
    "$GUARD" check "$proj" 2>&1
}

# A real live process to own a slot. Its output is detached because this is
# called from a command substitution, which would otherwise block until the
# background job's stdout closed.
live_pid() {
  sleep 300 >/dev/null 2>&1 &
  local p=$!
  FAKE_PIDS+=("$p")
  printf '%s\n' "$p"
}

identity_of() {  # <pid>
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$1" )
}

# --- (a) unlanded branch, no owner record -----------------------------------

proj=$(make_pool unowned 1)
slot=$(slot_path "$proj" 1)
give_unlanded_branch "$slot" fm/composer-nbsp-fix 2
out=$(run_guard "$proj" "$(slot_json 1 available "$slot")") && fail "(a) guard accepted a slot holding an unlanded branch"
assert_contains "$out" "still holds live work" "(a) refusal headline"
assert_contains "$out" "slot 1: $slot" "(a) names the exact slot"
assert_contains "$out" "branch fm/composer-nbsp-fix with 2 commits not on heads/main" "(a) names the exact evidence"
assert_contains "$out" "no firstmate task records this slot" "(a) reports unclaimed ownership"
assert_contains "$out" "Nothing was reset, cleaned, or discarded" "(a) states it destroyed nothing"
pass "(a) unlanded branch with no owner record is refused, with slot and evidence named"

# --- (m) the refusal is inert: nothing in the slot changed -------------------

head_after=$(git -C "$slot" rev-parse HEAD)
branch_after=$(git -C "$slot" symbolic-ref --short HEAD)
[ "$branch_after" = fm/composer-nbsp-fix ] || fail "(m) guard moved the slot off its branch"
[ -n "$head_after" ] || fail "(m) guard lost the slot's HEAD"
[ -z "$(git -C "$slot" status --porcelain)" ] || fail "(m) guard dirtied the slot"
pass "(m) refusing leaves the slot's branch, HEAD and working tree untouched"

# --- (b) owner identity matches a live process ------------------------------

proj=$(make_pool owner-alive 1)
slot=$(slot_path "$proj" 1)
give_unlanded_branch "$slot" fm/live-work
state="$(dirname "$proj")/state"
mkdir -p "$state"
pid=$(live_pid)
fm_write_meta "$state/live-task.meta" "worktree=$slot" \
  "worktree_owner_pid=$pid" "worktree_owner_identity=$(identity_of "$pid")"
out=$(run_guard "$proj" "$(slot_json 1 available "$slot")" "$state") && fail "(b) guard accepted a slot owned by a live task"
assert_contains "$out" "task live-task is still working here" "(b) names the live owning task"
assert_contains "$out" "fm-teardown.sh live-task" "(b) points at the only releaser"
pass "(b) a slot whose recorded owner identity matches a live process is refused as still-owned"

# --- (c) live pid, mismatched identity: the reboot pid-reuse case ------------

proj=$(make_pool owner-reused-pid 1)
slot=$(slot_path "$proj" 1)
give_unlanded_branch "$slot" fm/pre-reboot-work
state="$(dirname "$proj")/state"
mkdir -p "$state"
pid=$(live_pid)
# The pid is alive, but it is a DIFFERENT process than the one recorded - what a
# reboot produces when the kernel reissues pid numbers. A bare `kill -0` would
# read this as alive; the recorded identity must not.
fm_write_meta "$state/rebooted-task.meta" "worktree=$slot" \
  "worktree_owner_pid=$pid" \
  "worktree_owner_identity=linux-starttime=1 cmdline-hex=6e6f742d7468652d73616d6500"
out=$(run_guard "$proj" "$(slot_json 1 available "$slot")" "$state") && fail "(c) guard accepted a slot after a pid-reuse mismatch"
assert_contains "$out" "its worker is gone" "(c) a reused pid reads dead, not alive"
assert_not_contains "$out" "is still working here" "(c) must not report a reused pid as a live owner"
pass "(c) a live-but-reused pid whose recorded identity no longer matches reads dead, never falsely alive"

# --- (d) owner record with no identity is UNRESOLVED, never released ---------

proj=$(make_pool owner-unresolved 1)
slot=$(slot_path "$proj" 1)
give_unlanded_branch "$slot" fm/no-identity
state="$(dirname "$proj")/state"
mkdir -p "$state"
fm_write_meta "$state/old-task.meta" "worktree=$slot"
out=$(run_guard "$proj" "$(slot_json 1 available "$slot")" "$state") && fail "(d) guard accepted a slot with an unresolved owner"
assert_contains "$out" "ownership is unresolved" "(d) absent identity reads unresolved"
assert_not_contains "$out" "its worker is gone" "(d) absent identity must not read as dead"
pass "(d) an owner record with no recorded identity reads unresolved, never dead or released"

# --- (e) a demonstrably empty slot passes silently --------------------------

proj=$(make_pool empty 1)
slot=$(slot_path "$proj" 1)
out=$(run_guard "$proj" "$(slot_json 1 available "$slot")") || fail "(e) guard refused a demonstrably empty slot: $out"
[ -z "$out" ] || fail "(e) guard was not silent on a clean pool: $out"
pass "(e) a clean, detached slot with nothing unlanded passes silently"

# --- (f) a dirty slot reported available is still refused -------------------

proj=$(make_pool dirty 1)
slot=$(slot_path "$proj" 1)
printf 'uncommitted\n' > "$slot/scratch.txt"
out=$(run_guard "$proj" "$(slot_json 1 available "$slot")") && fail "(f) guard accepted a dirty slot"
assert_contains "$out" "uncommitted or untracked entries" "(f) names uncommitted evidence"
pass "(f) a dirty slot is refused even if treehouse were to report it available"

# --- (g) a zero-ahead named branch passes silently --------------------------

proj=$(make_pool named-branch 1)
slot=$(slot_path "$proj" 1)
git -C "$slot" checkout -q -b fm/landed main
out=$(run_guard "$proj" "$(slot_json 1 available "$slot")") \
  || fail "(g) guard refused a clean named branch with zero commits ahead: $out"
[ -z "$out" ] || fail "(g) guard was not silent for a zero-ahead named branch: $out"
pass "(g) a clean named branch with zero commits ahead passes silently"

# --- (h) in-use slots holding unlanded work must NOT wedge the fleet --------

proj=$(make_pool in-use 2)
busy=$(slot_path "$proj" 1)
free=$(slot_path "$proj" 2)
give_unlanded_branch "$busy" fm/normal-crewmate 3
out=$(run_guard "$proj" "$(slot_json 1 in-use "$busy" 2 available "$free")") \
  || fail "(h) guard refused while the only at-risk work sat in an in-use slot: $out"
[ -z "$out" ] || fail "(h) guard was not silent during normal fleet operation: $out"
pass "(h) unlanded work in an in-use slot is normal operation and does not block a spawn"

# --- (i) unreadable treehouse output fails closed ---------------------------

proj=$(make_pool drift 1)
out=$(run_guard "$proj" 'not json at all') && fail "(i) guard passed on unparseable treehouse output"
assert_contains "$out" "could not parse" "(i) reports the parse failure"
assert_contains "$out" "refusing rather than allocating blind" "(i) fails closed"
pass "(i) output the guard cannot parse refuses the spawn instead of allocating blind"

proj=$(make_pool empty-pool 1)
out=$(run_guard "$proj" '[]') || fail "(i2) guard refused an empty pool: $out"
pass "(i2) an empty pool is safe: treehouse creates a fresh slot"

# A relative slot path is refused from inside the row loop. This also pins that
# the refusal actually leaves the function: were that loop ever run in a
# subshell, the return would exit only the subshell and the guard would fall
# through to success.
proj=$(make_pool relpath 1)
out=$(run_guard "$proj" '[{"name":"1","status":"available","path":"slots/1","processes":[]}]') \
  && fail "(i3) guard passed on a non-absolute slot path"
assert_contains "$out" "non-absolute slot path" "(i3) names the malformed path"
pass "(i3) a non-absolute slot path refuses the spawn instead of being resolved against the cwd"

proj=$(make_pool empty-path 1)
out=$(run_guard "$proj" '[{"name":"1","status":"available","path":null,"processes":[]}]') \
  && fail "(i4) guard passed on an empty slot path"
assert_contains "$out" "non-absolute slot path ('')" "(i4) names the malformed empty path"
assert_contains "$out" "Refusing rather than allocating blind" "(i4) fails closed"
pass "(i4) an empty available-slot path refuses the spawn instead of being skipped"

# --- (j) missing jq fails closed --------------------------------------------

proj=$(make_pool nojq 1)
slot=$(slot_path "$proj" 1)
fakebin=$(fm_fakebin "$(dirname "$proj")")
install_fake_treehouse "$fakebin" "$(slot_json 1 available "$slot")"
# Model true absence: a PATH holding only the fake treehouse plus the utilities
# the guard needs before its jq check. Stubbing jq would not test this - the
# real /usr/bin/jq would still satisfy the lookup through the inherited PATH.
nojq_bin="$(dirname "$proj")/nojq-bin"
mkdir -p "$nojq_bin"
for tool in bash env sh uname mkdir cat dirname basename sed grep cut tail tr wc od stat date git readlink; do
  resolved=$(command -v "$tool" 2>/dev/null) || continue
  ln -sf "$resolved" "$nojq_bin/$tool"
done
ln -sf "$fakebin/treehouse" "$nojq_bin/treehouse"
command -v jq >/dev/null 2>&1 || fail "(j) precondition: jq must exist on the real PATH for this case to mean anything"
PATH="$nojq_bin" command -v jq >/dev/null 2>&1 && fail "(j) setup failed: jq is still reachable on the trimmed PATH"
out=$(PATH="$nojq_bin" FM_STATE_OVERRIDE="$(dirname "$proj")/state" "$GUARD" check "$proj" 2>&1) \
  && fail "(j) guard passed without jq"
assert_contains "$out" "jq is not on PATH" "(j) names the missing dependency"
pass "(j) a guard that cannot inspect the pool refuses rather than letting the spawn proceed"

# --- (k) explicit operator authority is exact-path scoped -------------------

proj=$(make_pool authority 1)
slot=$(slot_path "$proj" 1)
give_unlanded_branch "$slot" fm/authorized
fakebin=$(fm_fakebin "$(dirname "$proj")")
install_fake_treehouse "$fakebin" "$(slot_json 1 available "$slot")"
out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$(dirname "$proj")/state" \
  FM_WORKTREE_RECLAIM_OK="$slot" "$GUARD" check "$proj" 2>&1) \
  || fail "(k) guard refused despite explicit authority for that exact path: $out"
assert_contains "$out" "under explicit operator authority" "(k) announces the override"
out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$(dirname "$proj")/state" \
  FM_WORKTREE_RECLAIM_OK="$slot-other" "$GUARD" check "$proj" 2>&1) \
  && fail "(k) authority for a different path released this slot"
assert_contains "$out" "still holds live work" "(k) other-path authority does not carry over"
pass "(k) operator authority releases exactly the named worktree and no other"

# --- (l) owner-fields never invents an owner --------------------------------

proj=$(make_pool ownerfields 1)
slot=$(slot_path "$proj" 1)
out=$(FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-such-proc" "$GUARD" owner-fields "$slot")
assert_contains "$out" "worktree_owner_pid=" "(l) emits the pid field"
assert_contains "$out" "worktree_owner_identity=" "(l) emits the identity field"
[ "$(printf '%s\n' "$out" | grep -c '=$')" = 2 ] \
  || fail "(l) owner-fields invented an owner with no resolvable occupant: $out"
pass "(l) owner-fields records empty fields rather than fabricating ownership"

printf '\nall fm-worktree-guard tests passed\n'
