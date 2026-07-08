#!/usr/bin/env bash
# tests/fm-board-daemon.test.sh - board-automation daemon behavior. Drives real
# --once cycles against JSON board fixtures (FM_BOARD_FIXTURE) in dry-run
# (FM_BOARD_DRY_RUN=1, so no Azure calls and no real spawns), asserting the
# guardrails: seed-without-spawn on first sight, act only on real transitions,
# per-card+stage dedupe, concurrency cap, repo resolution that flags-and-leaves,
# and the kill switch. Also unit-tests the pure classifier + resolver functions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DAEMON="$ROOT/bin/fm-board-daemon.sh"
COLFIELD="WEF_BABA3EEA87FD424E9CFBCA5DBD7D9953_Kanban.Column"
LANEFIELD="WEF_BABA3EEA87FD424E9CFBCA5DBD7D9953_Kanban.Lane"

# Source the daemon's pure functions (the sourcing guard skips the entrypoint).
if [ -z "${FM_BOARD_TEST_SOURCED:-}" ]; then
  export FM_BOARD_TEST_SOURCED=1
  # shellcheck source=bin/fm-board-daemon.sh
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-board-tests)

# make_home <name>: a fresh isolated FM_HOME with state/data/config/projects and
# an ai-knowledge-base clone dir, plus a backlog. Echoes the home path.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/ai-knowledge-base"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

# write_fixture <path> <colvalue> <lane> [id] [tags] [title]
# Emits a batch-workitems JSON with a single card.
write_fixture() {
  local path=$1 col=$2 lane=$3 id=${4:-999} tags=${5:-} title=${6:-Test item}
  COL="$col" LANE="$lane" ID="$id" TAGS="$tags" TITLE="$title" \
  CF="$COLFIELD" LF="$LANEFIELD" python3 - "$path" <<'PY'
import os, json, sys
card = {"fields": {
    "System.Id": int(os.environ["ID"]),
    "System.State": "Approved",
    os.environ["CF"]: os.environ["COL"],
    os.environ["LF"]: os.environ["LANE"] or None,
    "System.Tags": os.environ["TAGS"],
    "System.Title": os.environ["TITLE"],
}}
with open(sys.argv[1], "w") as fh:
    json.dump({"value": [card]}, fh)
PY
}

# run_once <home> <fixture> [extra env assignments...]: run one dry-run cycle.
run_once() {
  local home=$1 fixture=$2; shift 2
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
      FM_BOARD_DRY_RUN=1 FM_BOARD_FIXTURE="$fixture" \
      "$@" "$DAEMON" --once >/dev/null 2>&1
}

# --- unit: stage classifier -------------------------------------------------
test_stage_classifier() {
  [ "$(stage_for_transition Proposed 'Ready to plan')" = plan ] || fail "Proposed->Ready to plan should be plan"
  [ "$(stage_for_transition Planned 'In Progress')" = impl ] || fail "Planned->In Progress should be impl"
  [ "$(stage_for_transition Proposed 'In Progress')" = impl ] || fail "Proposed->In Progress should be impl"
  [ -z "$(stage_for_transition 'In Progress' PR)" ] || fail "In Progress->PR should not spawn"
  [ -z "$(stage_for_transition Planned Done)" ] || fail "Planned->Done should not spawn"
  [ -z "$(stage_for_transition PR Done)" ] || fail "PR->Done should not spawn"
  pass "stage classifier maps only the two trigger transitions"
}

# --- unit: repo resolution --------------------------------------------------
test_repo_resolution() {
  local home; home=$(make_home resolve)
  # shellcheck disable=SC2030,SC2031  # subshell env is intentional per-call scoping
  ( export FM_PROJECTS_OVERRIDE="$home/projects" CONFIG="$home/config" PROJECTS="$home/projects"
    r=$(resolve_repo "AI Knowledge Base" "" "some title") || true
    [ "$r" = ai-knowledge-base ] || { echo "lane default failed: '$r'"; exit 1; }
    r=$(resolve_repo "Unmapped Lane" "repo:ai-knowledge-base" "t") || true
    [ "$r" = ai-knowledge-base ] || { echo "repo: tag failed: '$r'"; exit 1; }
    resolve_repo "Churn Analysis" "" "t" && { echo "unmapped lane should be unresolvable"; exit 1; }
    resolve_repo "Any" "repo:does-not-exist" "t" && { echo "nonexistent project should be unresolvable"; exit 1; }
    exit 0
  ) || fail "repo resolution wrong"
  pass "repo resolution: lane map + repo: tag win, unmapped/missing flag as unresolvable"
}

# --- integration: seed without spawn on first sight -------------------------
test_seed_no_spawn_first_sight() {
  local home fx; home=$(make_home seed)
  fx="$home/f.json"
  # A card ALREADY in a trigger column on first sight must be seeded, not spawned.
  write_fixture "$fx" "Ready to plan" "AI Knowledge Base"
  run_once "$home" "$fx"
  [ "$(cat "$home/state/.board-seen-999" 2>/dev/null)" = "Ready to plan" ] || fail "first sight should seed the column"
  [ -e "$home/state/.board-spawned-999-plan" ] && fail "first sight must NOT spawn"
  pass "first sight seeds the marker without spawning (no mass-spawn on start)"
}

# --- integration: real transition triggers exactly one spawn, then dedupes ---
test_transition_spawn_then_dedupe() {
  local home fx; home=$(make_home transition)
  fx="$home/f.json"
  # Cycle 1: seed at Proposed.
  write_fixture "$fx" "Proposed" "AI Knowledge Base"
  run_once "$home" "$fx"
  [ "$(cat "$home/state/.board-seen-999")" = "Proposed" ] || fail "should seed Proposed"

  # Cycle 2: captain moves it to Ready to plan -> exactly one plan spawn (dry).
  write_fixture "$fx" "Ready to plan" "AI Knowledge Base"
  run_once "$home" "$fx"
  [ -e "$home/state/.board-spawned-999-plan" ] || fail "transition should spawn (dry marker)"
  [ -f "$home/data/board-999-plan/brief.md" ] || fail "brief should be written from template"
  grep -q "PLAN Azure work item #999" "$home/data/board-999-plan/brief.md" || fail "brief not templated for #999"
  grep -q '\[DRY\] would spawn scout board-999-plan' "$home/state/.board-daemon.log" || fail "log should show one dry spawn"
  local spawns; spawns=$(grep -c 'would spawn' "$home/state/.board-daemon.log")
  [ "$spawns" -eq 1 ] || fail "expected exactly one spawn, got $spawns"

  # Cycle 3: same fixture (no column change) -> no new spawn.
  run_once "$home" "$fx"
  spawns=$(grep -c 'would spawn' "$home/state/.board-daemon.log")
  [ "$spawns" -eq 1 ] || fail "idempotent cycle must not re-spawn (got $spawns)"

  # Cycle 4/5: drag away and back -> dedupe marker blocks the re-spawn.
  write_fixture "$fx" "Proposed" "AI Knowledge Base"; run_once "$home" "$fx"
  write_fixture "$fx" "Ready to plan" "AI Knowledge Base"; run_once "$home" "$fx"
  grep -q 'deduped: #999 plan' "$home/state/.board-daemon.log" || fail "re-entry should be deduped"
  spawns=$(grep -c 'would spawn' "$home/state/.board-daemon.log")
  [ "$spawns" -eq 1 ] || fail "dedupe must prevent a second spawn (got $spawns)"
  pass "one transition -> one spawn; re-entry is deduped"
}

# --- integration: kill switch halts all work --------------------------------
test_kill_switch() {
  local home fx; home=$(make_home killsw)
  fx="$home/f.json"
  write_fixture "$fx" "Proposed" "AI Knowledge Base"; run_once "$home" "$fx"   # seed
  : > "$home/state/.board-daemon.off"
  write_fixture "$fx" "Ready to plan" "AI Knowledge Base"; run_once "$home" "$fx"
  [ -e "$home/state/.board-spawned-999-plan" ] && fail "kill switch must prevent spawn"
  grep -q 'idle: kill switch present' "$home/state/.board-daemon.log" || fail "kill switch not logged"
  pass "kill switch halts the cycle (no spawn)"
}

# --- integration: concurrency cap queues instead of spawning ----------------
test_concurrency_cap() {
  local home fx; home=$(make_home cap)
  fx="$home/f.json"
  write_fixture "$fx" "Proposed" "AI Knowledge Base"; run_once "$home" "$fx"    # seed
  # Simulate one board task already in flight; cap of 1 -> next transition queues.
  : > "$home/state/board-existing-impl.meta"
  write_fixture "$fx" "Ready to plan" "AI Knowledge Base"
  run_once "$home" "$fx" FM_BOARD_MAX_INFLIGHT=1
  [ -e "$home/state/.board-spawned-999-plan" ] && fail "cap should have queued, not spawned"
  grep -q 'at cap' "$home/state/.board-daemon.log" || fail "cap not logged"
  # Transition NOT consumed: clearing the meta lets a later cycle act.
  rm -f "$home/state/board-existing-impl.meta"
  run_once "$home" "$fx"
  [ -e "$home/state/.board-spawned-999-plan" ] || fail "queued transition should act once cap clears"
  pass "concurrency cap queues excess transitions without dropping them"
}

# --- integration: unresolved repo flags and leaves the card -----------------
test_unresolved_flags_and_leaves() {
  local home fx; home=$(make_home unresolved)
  fx="$home/f.json"
  write_fixture "$fx" "Proposed" "Churn Analysis"; run_once "$home" "$fx"       # seed
  write_fixture "$fx" "Ready to plan" "Churn Analysis"; run_once "$home" "$fx"
  [ -e "$home/state/.board-spawned-999-plan" ] && fail "unresolved must not spawn"
  grep -q 'UNRESOLVED: #999' "$home/state/.board-daemon.log" || fail "unresolved not flagged"
  # Not consumed: seen marker stays at Proposed so a later fix retries.
  [ "$(cat "$home/state/.board-seen-999")" = "Proposed" ] || fail "unresolved transition must not be consumed"
  pass "unresolved repo flags once and leaves the card for retry"
}

test_stage_classifier
test_repo_resolution
test_seed_no_spawn_first_sight
test_transition_spawn_then_dedupe
test_kill_switch
test_concurrency_cap
test_unresolved_flags_and_leaves
