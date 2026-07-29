#!/usr/bin/env bash
# Regression test for fm-spawn.sh's metadata-verified worktree occupancy check
# (bin/fm-spawn.sh, worktree_meta_claim plus the bounded re-acquire loop around
# `treehouse get`).
#
# Treehouse decides a pooled worktree is free from live processes cwd'd inside
# it. That detection goes stale whenever a working crewmate's shell sits outside
# its own worktree, and a reboot clears it entirely while every recorded
# worktree= under state/ survives. Treehouse then hands a live task's checkout to
# a second crewmate, whose first branch switch hijacks the first worker's
# checkout and pipeline anchoring; teardown later refuses to clean up because the
# slot holds another task's unpushed commits.
#
# These cases cover the observed incident shapes: a slot claimed by a live task
# is refused, a retry lands on the next clean slot, a claim whose task is no
# longer running is named but never discarded by spawn, an unclaimed slot still
# spawns exactly as before, and a task's own record never blocks its respawn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-claim)

# make_claim_fakebin <dir> builds a fake tmux that models the treehouse pool as
# an ordered list of slots (FM_FAKE_SLOTS_FILE, one absolute path per line):
# `#{pane_current_path}` reports the slot matching how many `treehouse get`
# sends the pane has received, clamped to the last line. Clamping IS the
# pool-exhausted shape - a `treehouse get` with nothing left to hand out leaves
# the pane exactly where it was.
#
# The occupant's liveness comes from the same fake: FM_FAKE_WINDOWS lists the
# window names `list-windows` reports (an absent window is an authoritatively
# missing endpoint), and FM_FAKE_COMMAND is the foreground command
# `#{pane_current_command}` reports for a listed one.
make_claim_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
countfile="${FM_FAKE_GET_COUNTFILE:?FM_FAKE_GET_COUNTFILE unset}"
case "$*" in
  *"send-keys"*"treehouse get"*)
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    printf '%s\n' "$((n + 1))" > "$countfile"
    exit 0
    ;;
  *"#{pane_current_path}"*)
    n=1
    [ -f "$countfile" ] && n=$(cat "$countfile")
    [ "$n" -ge 1 ] || n=1
    total=$(grep -c . "${FM_FAKE_SLOTS_FILE:?}")
    [ "$n" -le "$total" ] || n=$total
    sed -n "${n}p" "$FM_FAKE_SLOTS_FILE"
    exit 0
    ;;
  *"#{pane_current_command}"*)
    printf '%s\n' "${FM_FAKE_COMMAND:-zsh}"
    exit 0
    ;;
  *"#{window_id}"*)
    printf '@7\n'
    exit 0
    ;;
esac
case "${1:-}" in
  list-windows)
    case "$*" in
      *" -a "*) exit 0 ;;
    esac
    printf '%s' "${FM_FAKE_WINDOWS:-}"
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_claim_case <name> <id> builds a home, a primary project, and two pooled
# worktrees of it (slot A and slot B). The caller decides which slots treehouse
# offers and which of them another task's record already claims.
make_claim_case() {
  local name=$1 id=$2 case_dir
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  SLOT_A="$CASE_DIR/slot-a"
  SLOT_B="$CASE_DIR/slot-b"
  SLOTS_FILE="$CASE_DIR/slots"
  COUNTFILE="$CASE_DIR/get-count"
  case_dir=$CASE_DIR
  FAKEBIN_DIR=$(make_claim_fakebin "$case_dir/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  fm_git_worktree "$PROJ_DIR" "$SLOT_A" "slot-a-$name"
  git -C "$PROJ_DIR" worktree add --quiet -b "slot-b-$name" "$SLOT_B"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
}

# offer_slots <path>...: the ordered slots treehouse hands out, one per
# `treehouse get`.
offer_slots() {
  : > "$SLOTS_FILE"
  printf '%s\n' "$@" >> "$SLOTS_FILE"
}

# claim_slot <task-id> <worktree> [backend]: record <worktree> as <task-id>'s
# worktree, exactly as a live spawn would have. An explicit backend covers the
# records whose runtime has no recovery-grade liveness classifier.
claim_slot() {
  local extra=()
  [ -z "${3:-}" ] || extra=("backend=$3")
  fm_write_meta "$HOME_DIR/state/$1.meta" \
    "window=firstmate:fm-$1" \
    "endpoint_task_id=$1" \
    "worktree=$2" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    ${extra+"${extra[@]}"}
}

run_claim_spawn() {  # <id> [windows] [command]
  local id=$1 windows=${2:-} command=${3:-zsh}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_SPAWN_WORKTREE_POLLS=3 FM_SPAWN_WORKTREE_POLL_INTERVAL=0.05 \
    FM_FAKE_SLOTS_FILE="$SLOTS_FILE" FM_FAKE_GET_COUNTFILE="$COUNTFILE" \
    FM_FAKE_WINDOWS="$windows" FM_FAKE_COMMAND="$command" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# Incident shape 1: the pool offers a slot a live task already records as its
# worktree. Metadata outranks treehouse's process detection, so the slot is
# refused; with nothing else to offer, the spawn fails naming the claimant
# instead of retargeting into the live worker's checkout.
test_live_claim_is_refused() {
  local id out status
  id=claim-live-z1
  make_claim_case claim-live "$id"
  offer_slots "$SLOT_A"
  claim_slot occupant-live "$SLOT_A"

  out=$(run_claim_spawn "$id" "fm-occupant-live" claude)
  status=$?
  expect_code 1 "$status" "spawn should refuse a worktree a live task already claims"
  assert_contains "$out" "refusing to launch $id" "refusal did not name the spawn it stopped"
  assert_contains "$out" "claimed by occupant-live" "refusal did not name the claiming task"
  assert_contains "$out" "live worker" "refusal did not report the claimant as live"
  assert_contains "$out" "$SLOT_A" "refusal did not name the claimed worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not record metadata"
  pass "a slot recorded by a live task is refused, naming the claimant"
}

# Incident shape 2: the first offered slot is claimed, the next one is clean.
# The re-acquire lands on the clean slot and the spawn proceeds normally,
# leaving the claimant's record untouched.
test_retry_lands_on_clean_slot() {
  local id out status
  id=claim-retry-z2
  make_claim_case claim-retry "$id"
  offer_slots "$SLOT_A" "$SLOT_B"
  claim_slot occupant-retry "$SLOT_A"

  out=$(run_claim_spawn "$id" "fm-occupant-retry" claude)
  status=$?
  expect_code 0 "$status" "spawn should succeed once a clean slot is offered"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_contains "$out" "already recorded as another task's worktree" \
    "the refused first slot was not reported"
  assert_grep "worktree=$SLOT_B" "$HOME_DIR/state/$id.meta" \
    "meta did not record the clean slot"
  assert_no_grep "worktree=$SLOT_A" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the claimed slot"
  assert_grep "worktree=$SLOT_A" "$HOME_DIR/state/occupant-retry.meta" \
    "the claimant's own record was modified"
  pass "a claimed slot is re-requested and the spawn takes the next clean one"
}

# Incident shape 3: the claiming task is genuinely gone (its endpoint is
# authoritatively absent), which is exactly the reboot-cleared ghost that
# treehouse recycles. Spawn still refuses the slot and names the record as
# unreconciled - releasing it is firstmate's job, because that record is what
# protects the unlanded work sitting in the slot.
test_ghost_claim_is_named_not_discarded() {
  local id out status before
  id=claim-ghost-z3
  make_claim_case claim-ghost "$id"
  offer_slots "$SLOT_A"
  claim_slot occupant-ghost "$SLOT_A"
  before=$(cat "$HOME_DIR/state/occupant-ghost.meta")
  printf 'unlanded work\n' > "$SLOT_A/unlanded.txt"

  out=$(run_claim_spawn "$id" "" zsh)
  status=$?
  expect_code 1 "$status" "spawn should refuse a slot claimed by an unreconciled record"
  assert_contains "$out" "claimed by occupant-ghost" "refusal did not name the ghost record"
  assert_contains "$out" "no live worker (missing)" \
    "refusal did not report the ghost record as having no live worker"
  assert_contains "$out" "unreconciled record" \
    "refusal did not mark the ghost record as needing reconciliation"
  assert_present "$HOME_DIR/state/occupant-ghost.meta" \
    "spawn discarded a ghost record it may only name"
  [ "$(cat "$HOME_DIR/state/occupant-ghost.meta")" = "$before" ] \
    || fail "spawn modified the ghost record it may only name"
  assert_present "$SLOT_A/unlanded.txt" "spawn touched the unlanded work in the claimed slot"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not record metadata"
  pass "a ghost claim is named as unreconciled and left intact for firstmate"
}

# The clean path is unchanged: an unclaimed slot spawns on the first attempt,
# with no refusal, even while other tasks hold unrelated worktrees.
test_unclaimed_slot_spawns_unchanged() {
  local id out status
  id=claim-clean-z4
  make_claim_case claim-clean "$id"
  offer_slots "$SLOT_B"
  claim_slot occupant-elsewhere "$SLOT_A"

  out=$(run_claim_spawn "$id" "fm-occupant-elsewhere" claude)
  status=$?
  expect_code 0 "$status" "spawn should succeed on an unclaimed slot"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_not_contains "$out" "already recorded as another task's worktree" \
    "an unclaimed slot must not report a refusal"
  assert_grep "worktree=$SLOT_B" "$HOME_DIR/state/$id.meta" \
    "meta did not record the unclaimed slot"
  [ "$(cat "$COUNTFILE")" = 1 ] || fail "an unclaimed slot took more than one treehouse get"
  pass "an unclaimed slot spawns on the first attempt, unchanged"
}

# A respawn of the SAME task re-claims the worktree its own record names: the
# check must refuse other tasks' records, never the task's own, or recovery
# could never put a crewmate back in its own checkout.
test_own_record_is_not_a_collision() {
  local id out status
  id=claim-self-z5
  make_claim_case claim-self "$id"
  offer_slots "$SLOT_A"
  claim_slot "$id" "$SLOT_A"

  out=$(run_claim_spawn "$id" "" zsh)
  status=$?
  expect_code 0 "$status" "a respawn should accept the worktree its own record names"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$SLOT_A" "$HOME_DIR/state/$id.meta" \
    "meta did not record the task's own worktree"
  pass "a task's own record is not treated as a collision"
}

# A record whose runtime has no recovery-grade liveness classifier cannot prove
# the claim is stale, so the slot is still refused. Occupancy comes from the
# record, never from a liveness read that came back inconclusive.
test_unclassifiable_claim_is_still_refused() {
  local id out status
  id=claim-unverified-z6
  make_claim_case claim-unverified "$id"
  offer_slots "$SLOT_A"
  claim_slot occupant-unverified "$SLOT_A" zellij

  out=$(run_claim_spawn "$id" "" zsh)
  status=$?
  expect_code 1 "$status" "spawn should refuse a claim whose liveness cannot be classified"
  assert_contains "$out" "claimed by occupant-unverified" "refusal did not name the claiming task"
  assert_contains "$out" "treated as claimed" "refusal did not report the inconclusive state as claimed"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not record metadata"
  pass "a claim with no classifiable liveness is refused, not assumed free"
}

test_live_claim_is_refused
test_retry_lands_on_clean_slot
test_ghost_claim_is_named_not_discarded
test_unclaimed_slot_spawns_unchanged
test_own_record_is_not_a_collision
test_unclassifiable_claim_is_still_refused

echo "# all fm-spawn-worktree-claim tests passed"
