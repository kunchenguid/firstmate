#!/usr/bin/env bash
# Behavioral regression tests for bin/fm-teardown.sh's scoped task-workspace
# lifecycle.
#
#   (a) A Treehouse-backed task whose record carries workspace_root=<root> is
#       returned to that exact root and then destroyed (zero idle retention):
#         treehouse --root <root> return --force [--if-lease-holder <h>] <wt>
#         treehouse --root <root> destroy <wt> --yes
#       A failed destroy aborts teardown with the task record intact, and a
#       retry completes it.
#   (b) A record with workspace_state=released owns no local worktree, even
#       though it still names the old slot path. Treehouse may have handed that
#       exact path to another task. Tearing the released task down must leave
#       that path - its checkout, branch, and slot-owner claim - untouched while
#       still finishing the released task's own record cleanup; and the live
#       task now in the slot must still tear down normally while the released
#       record keeps naming the same path.
#
# Every case runs the real bin/fm-teardown.sh against a real git project, a real
# linked worktree laid out as a Treehouse pool slot (<pool>/<n>/<repo> beside
# <pool>/treehouse-state.json), and fake treehouse/tmux/gh/no-mistakes binaries
# that record their invocations.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-workspace)

# Build one sandbox:
#   $dir/home/{state,data,config}   firstmate home
#   $dir/origin.git                 bare origin with main
#   $dir/project                    clone of origin (the recorded project)
#   $dir/wsroot                     the scoped workspace root (workspace_root=)
#   $dir/wsroot/pool/1/repo         pool slot 1: a real linked worktree of project
#   $dir/wsroot/pool/treehouse-state.json
#   $dir/fakebin                    fake treehouse/tmux/gh/gh-axi/no-mistakes
#   $dir/treehouse.log              one line per fake treehouse invocation
# The fake treehouse logs every call. `return` succeeds. `destroy` fails while
# $dir/destroy-fails exists; otherwise it really removes the linked worktree and
# its slot directory, like the real destroy does.
make_case() {  # <name> <branch>
  local name=$1 branch=$2 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin" \
    "$dir/wsroot/pool/1"
  : > "$dir/treehouse.log"
  : > "$dir/runtime.log"

  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
{
  printf 'treehouse'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${FM_CASE_DIR:?}/treehouse.log"
args=("$@")
if [ "${args[0]:-}" = --root ]; then
  args=("${args[@]:2}")
fi
if [ "${args[0]:-}" = destroy ]; then
  if [ -e "$FM_CASE_DIR/destroy-fails" ]; then
    echo "error: simulated destroy failure" >&2
    exit 1
  fi
  wt=${args[1]:-}
  git -C "$FM_CASE_DIR/project" worktree remove --force "$wt" >/dev/null 2>&1 || exit 1
  # The real destroy removes the whole <pool>/<n> slot directory, not only the
  # checkout inside it (verified against treehouse itself), so anything beside
  # the checkout goes with it.
  rm -rf -- "$(dirname "$wt")"
fi
exit 0
SH
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
{
  printf 'tmux'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${FM_CASE_DIR:?}/runtime.log"
exit 0
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/treehouse" "$dir/fakebin/tmux" "$dir/fakebin/gh-axi" \
    "$dir/fakebin/gh" "$dir/fakebin/no-mistakes"

  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/_seed" 2>/dev/null
  git -C "$dir/_seed" checkout -q -b main 2>/dev/null || true
  git -C "$dir/_seed" commit -q --allow-empty -m "origin baseline"
  git -C "$dir/_seed" push -q origin main
  rm -rf "$dir/_seed"
  git clone -q "$dir/origin.git" "$dir/project"
  git -C "$dir/project" remote set-head origin main 2>/dev/null || true

  # Pool slot 1: a linked worktree of the project on the live task's branch,
  # carrying one real commit that is pushed to origin (landed by reachability).
  git -C "$dir/project" worktree add -q -b "$branch" "$dir/wsroot/pool/1/repo" main
  printf 'work\n' > "$dir/wsroot/pool/1/repo/work.txt"
  git -C "$dir/wsroot/pool/1/repo" add work.txt
  git -C "$dir/wsroot/pool/1/repo" commit -q -m "task work"
  git -C "$dir/wsroot/pool/1/repo" push -q origin "$branch"
  git -C "$dir/project" fetch -q origin
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
    "$dir/wsroot/pool/1/repo" > "$dir/wsroot/pool/treehouse-state.json"

  touch "$dir/home/state/.last-watcher-beat"
  printf '%s\n' "$dir"
}

write_task_meta() {  # <case> <id> <workspace_state> [extra kv...]
  local dir=$1 id=$2 ws_state=$3
  shift 3
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wsroot/pool/1/repo" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=teardown-workspace-test-$id" \
    "workspace_root=$dir/wsroot" \
    "workspace_state=$ws_state" \
    "$@"
}

claim_slot() {  # <case> <task-id>
  printf 'task=%s\nhome=%s\n' "$2" "$1/home" > "$1/wsroot/pool/1/.fm-slot-owner"
}

# Run the real teardown. Output lands in $dir/stdout and $dir/stderr; the exit
# status is echoed so callers can assert on it without tripping `set -e`.
run_teardown() {  # <case> <id> [args...]
  local dir=$1 id=$2 rc=0
  shift 2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_CASE_DIR="$dir" \
  PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@" > "$dir/stdout" 2> "$dir/stderr" || rc=$?
  printf '%s\n' "$rc"
}

case_output() {  # <case>
  printf -- '--- stdout ---\n%s\n--- stderr ---\n%s\n--- treehouse.log ---\n%s\n' \
    "$(cat "$1/stdout")" "$(cat "$1/stderr")" "$(cat "$1/treehouse.log")"
}

# The line number of the first treehouse.log line equal to <line>, or empty.
log_line_number() {  # <case> <line>
  grep -n -F -x -- "$2" "$1/treehouse.log" | head -1 | cut -d: -f1
}

assert_return_then_destroy() {  # <case> <return-line> <destroy-line> <label>
  local dir=$1 ret=$2 des=$3 label=$4 ret_n des_n
  ret_n=$(log_line_number "$dir" "$ret")
  des_n=$(log_line_number "$dir" "$des")
  [ -n "$ret_n" ] || fail "$label: scoped return was not run as: $ret"$'\n'"$(case_output "$dir")"
  [ -n "$des_n" ] || fail "$label: scoped destroy was not run as: $des"$'\n'"$(case_output "$dir")"
  [ "$ret_n" -lt "$des_n" ] || fail "$label: destroy ran before return"$'\n'"$(case_output "$dir")"
}

# The slot must be exactly as its live owner left it.
assert_slot_untouched() {  # <case> <branch> <head> <label>
  local dir=$1 branch=$2 head=$3 label=$4 wt="$1/wsroot/pool/1/repo"
  [ -d "$wt" ] || fail "$label: the live task's worktree was removed"$'\n'"$(case_output "$dir")"
  assert_equals "$branch" "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
    "$label: the live task's checked-out branch changed"
  assert_equals "$head" "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" \
    "$label: the live task's HEAD moved"
  assert_equals "$head" "$(git -C "$dir/project" rev-parse --verify "refs/heads/$branch" 2>/dev/null)" \
    "$label: the live task's branch ref was deleted or moved"
  assert_equals "" "$(git -C "$wt" status --porcelain 2>/dev/null)" \
    "$label: the live task's worktree was dirtied"
  assert_present "$wt/work.txt" "$label: the live task's files were removed"
  [ ! -s "$dir/treehouse.log" ] \
    || fail "$label: treehouse was invoked against a slot the released task no longer owns: $(cat "$dir/treehouse.log")"
}

# --- (a) scoped return then destroy -----------------------------------------

test_scoped_return_then_destroy_with_lease_holder() {
  local dir id=task-a rc wt holder='firstmate:abc123def456:task-a'
  dir=$(make_case scoped-holder fm/task-a)
  wt="$dir/wsroot/pool/1/repo"
  write_task_meta "$dir" "$id" active "workspace_lease_holder=$holder"
  claim_slot "$dir" "$id"

  rc=$(run_teardown "$dir" "$id")
  assert_equals 0 "$rc" "scoped teardown failed: $(case_output "$dir")"
  assert_return_then_destroy "$dir" \
    "treehouse <--root> <$dir/wsroot> <return> <--force> <--if-lease-holder> <$holder> <$wt>" \
    "treehouse <--root> <$dir/wsroot> <destroy> <$wt> <--yes>" \
    "scoped teardown with lease holder"
  assert_equals 2 "$(wc -l < "$dir/treehouse.log" | tr -d ' ')" \
    "scoped teardown ran unexpected treehouse commands: $(cat "$dir/treehouse.log")"
  assert_absent "$wt" "scoped teardown left an idle worktree behind"
  assert_absent "$dir/home/state/$id.meta" "scoped teardown left the task record"
  assert_absent "$dir/wsroot/pool/1/.fm-slot-owner" "scoped teardown left its spent slot claim"
  assert_contains "$(cat "$dir/stdout")" "teardown $id complete" "scoped teardown did not report completion"
  pass "fm-teardown: a scoped task is returned to its exact root under its lease holder, then destroyed"
}

test_scoped_return_then_destroy_without_lease_holder() {
  local dir id=task-a rc wt
  dir=$(make_case scoped-no-holder fm/task-a)
  wt="$dir/wsroot/pool/1/repo"
  write_task_meta "$dir" "$id" active
  claim_slot "$dir" "$id"

  rc=$(run_teardown "$dir" "$id")
  assert_equals 0 "$rc" "scoped teardown without a holder failed: $(case_output "$dir")"
  assert_return_then_destroy "$dir" \
    "treehouse <--root> <$dir/wsroot> <return> <--force> <$wt>" \
    "treehouse <--root> <$dir/wsroot> <destroy> <$wt> <--yes>" \
    "scoped teardown without lease holder"
  assert_no_grep "--if-lease-holder" "$dir/treehouse.log" \
    "a record with no lease holder must not pass --if-lease-holder"
  assert_absent "$wt" "scoped teardown without a holder left an idle worktree behind"
  assert_absent "$dir/home/state/$id.meta" "scoped teardown without a holder left the task record"
  pass "fm-teardown: a scoped task with no recorded lease holder is returned without one, then destroyed"
}

test_destroy_failure_aborts_with_record_intact_then_retry_succeeds() {
  local dir id=task-a rc wt
  dir=$(make_case destroy-fails fm/task-a)
  wt="$dir/wsroot/pool/1/repo"
  write_task_meta "$dir" "$id" active
  claim_slot "$dir" "$id"
  : > "$dir/destroy-fails"

  rc=$(run_teardown "$dir" "$id")
  assert_equals 1 "$rc" "teardown must exit 1 when exact destroy fails: $(case_output "$dir")"
  assert_contains "$(cat "$dir/stderr")" \
    "returned but exact idle-workspace destruction failed; teardown aborted for a safe retry" \
    "destroy failure was not reported as a retryable abort"
  assert_return_then_destroy "$dir" \
    "treehouse <--root> <$dir/wsroot> <return> <--force> <$wt>" \
    "treehouse <--root> <$dir/wsroot> <destroy> <$wt> <--yes>" \
    "failed destroy attempt"
  assert_no_grep "--include-unlanded" "$dir/treehouse.log" \
    "a failed exact destroy must never be broadened"
  assert_present "$dir/home/state/$id.meta" "a failed destroy erased the task record"
  assert_grep "workspace_root=$dir/wsroot" "$dir/home/state/$id.meta" \
    "a failed destroy lost the record's workspace root"
  assert_absent "$dir/wsroot/pool/1/.fm-slot-owner" \
    "a slot already returned to the pool still carried this task's spent claim"
  [ -d "$wt" ] || fail "fixture: the fake destroy failure should leave the worktree in place"
  assert_not_contains "$(cat "$dir/stdout")" "teardown $id complete" \
    "a failed destroy still reported completion"

  # Retry once destroy can succeed.
  rm -f "$dir/destroy-fails"
  : > "$dir/treehouse.log"
  rc=$(run_teardown "$dir" "$id")
  assert_equals 0 "$rc" "retry after a failed destroy did not succeed: $(case_output "$dir")"
  assert_return_then_destroy "$dir" \
    "treehouse <--root> <$dir/wsroot> <return> <--force> <$wt>" \
    "treehouse <--root> <$dir/wsroot> <destroy> <$wt> <--yes>" \
    "retry after failed destroy"
  assert_absent "$wt" "retry left an idle worktree behind"
  assert_absent "$dir/home/state/$id.meta" "retry left the task record"
  assert_absent "$dir/wsroot/pool/1/.fm-slot-owner" "retry left the spent slot claim"
  assert_contains "$(cat "$dir/stdout")" "teardown $id complete" "retry did not report completion"
  pass "fm-teardown: a failed exact destroy aborts with the record intact, and a retry completes"
}

# --- (b) released record sharing a reused slot path ---------------------------

# Z released its workspace early; Treehouse reused <pool>/1/repo for X.
# Args: <case-name> <claim: x|absent> <x-state> [teardown args for Z...]
released_record_case() {
  local name=$1 claim=$2 x_state=$3 dir rc wt head label
  shift 3
  label="released teardown ($name${1:+ $1})"
  dir=$(make_case "$name" fm/x)
  wt="$dir/wsroot/pool/1/repo"
  head=$(git -C "$wt" rev-parse HEAD)
  write_task_meta "$dir" z released "pr=https://github.com/example/repo/pull/7"
  write_task_meta "$dir" x "$x_state"
  [ "$claim" = absent ] || claim_slot "$dir" x

  rc=$(run_teardown "$dir" z "$@")
  assert_equals 0 "$rc" "$label: refused or failed: $(case_output "$dir")"
  assert_slot_untouched "$dir" fm/x "$head" "$label"
  if [ "$claim" = absent ]; then
    assert_absent "$dir/wsroot/pool/1/.fm-slot-owner" "$label: a slot claim appeared from nowhere"
  else
    assert_equals "task=x" "$(sed -n 1p "$dir/wsroot/pool/1/.fm-slot-owner")" \
      "$label: the live task's slot claim was changed"
    assert_equals "home=$dir/home" "$(sed -n 2p "$dir/wsroot/pool/1/.fm-slot-owner")" \
      "$label: the live task's slot claim home was changed"
  fi
  assert_absent "$dir/home/state/z.meta" "$label: the released task's record was not cleaned up"
  assert_present "$dir/home/state/x.meta" "$label: the live task's record was removed"
  assert_contains "$(cat "$dir/stdout")" "teardown z complete (" "$label: completion was not reported"
  assert_contains "$(cat "$dir/stdout")" "workspace already released, no local worktree to remove)" \
    "$label: completion did not say the workspace was already released"
  assert_not_contains "$(cat "$dir/stderr")" "REFUSED" "$label: printed a refusal"
  printf '%s\n' "$dir"
}

test_released_record_leaves_reused_claimed_slot_untouched() {
  released_record_case released-claimed x restored >/dev/null
  released_record_case released-claimed-active x active >/dev/null
  pass "fm-teardown: a released record finishes its own cleanup and leaves the task now holding its old slot path untouched"
}

test_released_record_leaves_reused_unclaimed_slot_untouched() {
  # Restore without a claim: nothing in the slot names X, which used to make the
  # released record look like the slot's owner.
  released_record_case released-unclaimed absent restored >/dev/null
  pass "fm-teardown: a released record leaves a reused slot untouched even when that slot carries no claim"
}

test_released_record_force_still_leaves_reused_slot_untouched() {
  released_record_case released-claimed-force x restored --force >/dev/null
  released_record_case released-unclaimed-force absent restored --force >/dev/null
  pass "fm-teardown: --force on a released record still never touches the reused slot"
}

test_live_task_tears_down_while_released_record_names_its_slot() {
  local dir rc wt claim
  for claim in x absent; do
    dir="$TMP_ROOT/live-beside-released-$claim"
    dir=$(make_case "live-beside-released-$claim" fm/x)
    wt="$dir/wsroot/pool/1/repo"
    write_task_meta "$dir" z released "pr=https://github.com/example/repo/pull/7"
    write_task_meta "$dir" x restored
    [ "$claim" = absent ] || claim_slot "$dir" x

    rc=$(run_teardown "$dir" x)
    assert_equals 0 "$rc" "live task ($claim claim) could not tear down beside a released record: $(case_output "$dir")"
    assert_not_contains "$(cat "$dir/stderr")" "REFUSED" \
      "live task ($claim claim) teardown printed a refusal"
    assert_return_then_destroy "$dir" \
      "treehouse <--root> <$dir/wsroot> <return> <--force> <$wt>" \
      "treehouse <--root> <$dir/wsroot> <destroy> <$wt> <--yes>" \
      "live task ($claim claim) beside a released record"
    assert_absent "$wt" "live task ($claim claim) teardown left an idle worktree"
    assert_absent "$dir/home/state/x.meta" "live task ($claim claim) teardown left its record"
    assert_absent "$dir/wsroot/pool/1/.fm-slot-owner" "live task ($claim claim) teardown left a slot claim"
    assert_present "$dir/home/state/z.meta" "live task ($claim claim) teardown removed the released task's record"
    assert_contains "$(cat "$dir/stdout")" "teardown x complete" \
      "live task ($claim claim) teardown did not report completion"
  done
  pass "fm-teardown: the live task in a reused slot tears down normally while a released record still names that path"
}

test_released_then_live_teardown_in_sequence() {
  local dir rc wt
  dir=$(released_record_case sequence x restored) \
    || fail "released teardown failed before the live task's teardown could run"
  wt="$dir/wsroot/pool/1/repo"
  rc=$(run_teardown "$dir" x)
  assert_equals 0 "$rc" "live task could not tear down after the released record was cleaned up: $(case_output "$dir")"
  assert_return_then_destroy "$dir" \
    "treehouse <--root> <$dir/wsroot> <return> <--force> <$wt>" \
    "treehouse <--root> <$dir/wsroot> <destroy> <$wt> <--yes>" \
    "live task after released teardown"
  assert_absent "$wt" "live task teardown left an idle worktree"
  assert_absent "$dir/home/state/x.meta" "live task teardown left its record"
  assert_absent "$dir/wsroot/pool/1/.fm-slot-owner" "live task teardown left its slot claim"
  pass "fm-teardown: released teardown then live teardown both complete, return and destroy run once for the live task only"
}

test_scoped_return_then_destroy_with_lease_holder
test_scoped_return_then_destroy_without_lease_holder
test_destroy_failure_aborts_with_record_intact_then_retry_succeeds
test_released_record_leaves_reused_claimed_slot_untouched
test_released_record_leaves_reused_unclaimed_slot_untouched
test_released_record_force_still_leaves_reused_slot_untouched
test_live_task_tears_down_while_released_record_names_its_slot
test_released_then_live_teardown_in_sequence
