#!/usr/bin/env bash
# Behavior tests for the mission control board renderer.
#
# The board is rendered end to end from a real fixture home for the main path,
# and from captured snapshot payloads (the public --snapshot flag) for the
# cross-home and hostile-input cases that a local fixture cannot produce.
#
# Every case that renders a time pins TZ and FM_MISSION_CONTROL_NOW_EPOCH, and
# commits its fixture clones at explicit epochs, so the relative wording the
# board prints is a property of the board rather than of the day it runs.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-mission-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-mission-control)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# 2026-01-02T15:00:00Z, with TZ=UTC pinned by every case that renders a time.
NOW_EPOCH=1767366000
TODAY_0905=1767344700    # 2026-01-02T09:05:00Z
YESTERDAY_2335=1767310500  # 2026-01-01T23:35:00Z
LAST_JULY=1753178400     # 2025-07-22T10:00:00Z

export TZ=UTC

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  fm_fake_exit0 "$fb" no-mistakes
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
      *) printf '%%1\n' ;;
    esac ;;
  capture-pane) printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# A clone whose single commit lands on an exact epoch, so the board's relative
# wording is checked against a time this test chose rather than the clock.
make_clone() {  # <home> <name> <commit-epoch>
  local dir=$1/projects/$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  : > "$dir/README.md"
  git -C "$dir" add README.md
  GIT_AUTHOR_DATE="@$3 +0000" GIT_COMMITTER_DATE="@$3 +0000" \
    git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'fixture commit'
}

# A complete home: registry, backlog with a captain hold and an item landed on
# the board's own "today", one live ship task, a recorded PR, and a real clone
# for one of the two registered projects.
write_fixture() {  # <home>
  local home=$1 fixture_gen
  mkdir -p "$home/projects/alpha-worktree"
  make_clone "$home" alpha "$TODAY_0905"
  cat > "$home/data/projects.md" <<'EOF'
# Project registry

- alpha [direct-PR +yolo] - Alpha service (added 2026-01-01)
- beta [no-mistakes] - Beta site (added 2026-01-02)
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Rebuild the alpha intake form (repo: alpha) (kind: ship) (since 2026-01-03)

## Queued
- [ ] alpha-decision - Choose the alpha rollout window (repo: alpha) (kind: captain) (hold: Two rollout windows both cost money) (hold-kind: captain) (since 2026-01-03)

## Done
- [x] alpha-landed - Ship the alpha health check https://github.com/example/alpha/pull/7 (repo: alpha) (kind: ship) (merged 2026-01-02)
EOF
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=claude" \
    "model=claude-opus-5" \
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=on" \
    "pr=https://github.com/example/alpha/pull/9"
  printf 'working: intake form wired up\n' > "$home/state/ship-task.status"
  # A task that is actually working proves it through its own semantic busy-state
  # record (bin/fm-busy-lib.sh), which is what the current-state read consults;
  # rendered pane text is not a state source. Without this the task reads
  # unknown, and the live fixture would never exercise a real ladder rung.
  fixture_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ship-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" ship-task busy --gen "$fixture_gen" \
    --source claude-hook --event user-prompt-submit
}

# A minimal but schema-shaped snapshot, so a case can drive fields no local
# fixture produces (another home's decisions, hostile prose, path-form repos).
snapshot_json() {  # <records-json> <secondmate-records-json> [<tasks-json>]
  jq -n --argjson records "$1" --argjson sm "$2" --argjson tasks "${3:-[]}" '{
    schema: "fm-fleet-snapshot.v1",
    generated: "2026-01-04T00:00:00Z",
    fm_home: "/fixture/home",
    roots: {state: "/fixture/home/state", data: "/fixture/home/data",
            projects: "/fixture/home/projects"},
    backlog: {path: "/fixture/home/data/backlog.md", present: true, records: $records},
    tasks: $tasks,
    secondmate_current: {registry: {
      present: false, available: true, complete: true,
      input_truncated: false, records_truncated: false, records: []
    }, records: $sm}
  }'
}

# One live task exactly as the snapshot reports it. The stage is given as the
# derived object the snapshot attaches, because that is what the board consumes;
# bin/fm-fleet-snapshot.sh owns deriving it from live state and tests/fm-fleet-
# snapshot-view.test.sh pins that half.
live_task() {  # <id> <title> <repo> <model> <ordinal> <label> <motion>
  jq -n --arg id "$1" --arg title "$2" --arg repo "$3" --arg model "$4" \
        --argjson ordinal "$5" --arg label "$6" --arg motion "$7" '{
    id: $id, kind: "ship", harness: "claude", model: $model,
    project: $repo, backend: "tmux",
    current_state: {state: "working", source: "pane", detail: "", raw: "",
      stage: {ordinal: $ordinal, of: 5, label: $label, motion: $motion}},
    endpoint: {target: ("firstmate:fm-" + $id), exists: true},
    pr: {url: null, source: "absent"},
    hints: {pending_decision: false, blocked_event: false, open_decisions: []},
    backlog: {id: $id, title: $title, repo: $repo, state: "in_flight",
              kind: "ship", structured: true}
  }'
}

in_flight_record() {  # <id> <title> <repo>
  jq -n --arg id "$1" --arg title "$2" --arg repo "$3" '{
    id: $id, title: $title, raw: $title, repo: $repo, state: "in_flight",
    kind: "ship", structured: true, captain_actionable: false,
    captain_deferred: false, unresolved_blocker_ids: [], completion: {date: null}}'
}

# A count tells the captain something is happening without telling them what, so
# each in-progress item names itself and carries the two facts the count hides:
# how far it has travelled and which model is on it.
test_in_progress_items_are_listed_with_stage_and_model() {
  local snap board
  snap=$TMP_ROOT/items.json
  board=$TMP_ROOT/items.html
  snapshot_json "[$(in_flight_record early 'Rebuild the intake form' alpha),
                  $(in_flight_record mid 'Fix search ranking' alpha),
                  $(in_flight_record late 'Migrate the billing webhooks' alpha)]" '[]' \
    "[$(live_task early 'Rebuild the intake form' alpha claude-opus-5 2 Building live),
      $(live_task mid 'Fix search ranking' alpha claude-sonnet-5 3 Validating live),
      $(live_task late 'Migrate the billing webhooks' alpha claude-opus-5 4 'Checks running' live)]" \
    > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a board with in-progress items must render"

  assert_grep 'Rebuild the intake form' "$board" "an in-progress item must be named, not just counted"
  assert_grep 'Fix search ranking' "$board" "every in-progress item must be named"
  assert_grep 'Migrate the billing webhooks' "$board" "every in-progress item must be named"
  assert_grep '3 tasks under way' "$board" "the count above the list must survive"

  # The rung a bar fills and the rung its label claims are two renderings of one
  # fact. They are asserted together because a bar that drifted from its label is
  # exactly the silent overstatement the ladder exists to avoid.
  assert_grep 'aria-label="Stage 2 of 5: Building"' "$board" \
    "a bar must state its position in words for anyone who cannot see it"
  assert_grep '<i class="on"></i><i class="on"></i><i></i><i></i><i></i>' "$board" \
    "rung 2 of 5 must fill exactly two rungs"
  assert_grep '<i class="on"></i><i class="on"></i><i class="on"></i><i></i><i></i>' "$board" \
    "rung 3 of 5 must fill exactly three rungs"
  assert_grep '<i class="on"></i><i class="on"></i><i class="on"></i><i class="on"></i><i></i>' "$board" \
    "rung 4 of 5 must fill exactly four rungs"
  assert_grep '>Building</span>' "$board" "the stage must be named beside its bar"
  assert_grep '>Checks running</span>' "$board" "the stage must be named beside its bar"

  assert_grep '>Opus 5</span>' "$board" "the model on an item must be shown readably"
  assert_grep '>Sonnet 5</span>' "$board" "the model on an item must be shown readably"

  # The whole point of a stage ladder is that it is not a completion estimate.
  assert_no_grep '% complete' "$board" "a stage must never be dressed up as a percentage"
  assert_no_grep 'ETA' "$board" "a stage must never be dressed up as an ETA"
  pass "each in-progress item is listed with its stage and its model"
}

# Colour says whether an item is MOVING, which is a different question from how
# far it has come. An item stopped at rung four is still stopped, and a board
# that painted it as live progress would be actively misleading.
test_stalled_items_do_not_read_as_progress() {
  local snap board
  snap=$TMP_ROOT/motion.json
  board=$TMP_ROOT/motion.html
  snapshot_json "[$(in_flight_record held 'Replace the session cookie' alpha),
                  $(in_flight_record stuck 'Speed up the import job' alpha)]" '[]' \
    "[$(live_task held 'Replace the session cookie' alpha claude-opus-5 3 'Waiting on a decision' waiting),
      $(live_task stuck 'Speed up the import job' alpha claude-opus-5 2 Blocked stopped)]" \
    > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a board with stalled items must render"
  assert_grep 'class="wi-bar m-waiting"' "$board" \
    "an item waiting on the captain must be toned apart from one that is moving"
  assert_grep 'class="wi-bar m-stopped"' "$board" \
    "a blocked item must be toned apart from one that is moving"
  assert_grep 'class="wi-stage m-stopped">Blocked</span>' "$board" \
    "a blocked item must say so in words, not only in colour"
  assert_grep 'aria-label="Stage 3 of 5: Waiting on a decision"' "$board" \
    "a stalled item must keep the rung it reached rather than falling back to zero"
  pass "a stalled item keeps its rung but never reads as progress"
}

test_setup_uses_neutral_tone() {
  local snap board
  snap=$TMP_ROOT/setup-tone.json
  board=$TMP_ROOT/setup-tone.html
  snapshot_json "[$(in_flight_record setup 'Start the worker endpoint' alpha)]" '[]' \
    "[$(live_task setup 'Start the worker endpoint' alpha claude-opus-5 1 'Setup: endpoint present' quiet)]" \
    > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a Setup item must render"
  assert_grep 'class="wi-bar m-quiet" role="img" aria-label="Stage 1 of 5: Setup: endpoint present"' "$board" \
    "Setup must use its bounded neutral motion"
  assert_grep 'class="wi-stage m-quiet">Setup: endpoint present</span>' "$board" \
    "the Setup label must use the same neutral tone as its ladder"
  assert_grep '.wi-bar.m-quiet i.on{background:var(--slate);}' "$board" \
    "the Setup ladder must use the board's slate tone"
  assert_no_grep 'class="wi-bar m-live"' "$board" \
    "Setup must not claim observed live movement"
  pass "Setup uses one neutral slate tone"
}

# Ready has reached the top rung but still awaits the captain, while Done is
# terminal. Position alone cannot distinguish them, so their tones must.
test_ready_and_done_use_distinct_tones() {
  local snap board
  snap=$TMP_ROOT/ready-done.json
  board=$TMP_ROOT/ready-done.html
  snapshot_json "[$(in_flight_record ready 'Review the green PR' alpha),
                  $(in_flight_record 'done' 'Merged delivery' alpha)]" '[]' \
    "[$(live_task ready 'Review the green PR' alpha claude-opus-5 5 'Checks green' ready),
      $(live_task 'done' 'Merged delivery' alpha claude-opus-5 5 Done 'done')]" \
    > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "ready and done stages must render"
  assert_grep 'class="wi-bar m-ready" role="img" aria-label="Stage 5 of 5: Checks green"' "$board" \
    "green checks awaiting the captain must use the ready tone"
  assert_grep 'class="wi-stage m-ready">Checks green</span>' "$board" \
    "the ready label must use the same bounded tone as its ladder"
  assert_grep 'class="wi-bar m-done" role="img" aria-label="Stage 5 of 5: Done"' "$board" \
    "terminal work must retain the done tone"
  pass "ready work is toned apart from completed work"
}

# A model id is a dispatch identifier. The captain reads a name.
test_model_ids_are_shown_as_readable_names() {
  local snap board
  snap=$TMP_ROOT/models.json
  board=$TMP_ROOT/models.html
  snapshot_json "[$(in_flight_record m1 'Vendor prefixed' alpha),
                  $(in_flight_record m2 'Namespaced provider' alpha),
                  $(in_flight_record m3 'Tagged local model' alpha),
                  $(in_flight_record m4 'Dated release' alpha),
                  $(in_flight_record m5 'Single word' alpha)]" '[]' \
    "[$(live_task m1 'Vendor prefixed' alpha claude-opus-5 2 Building live),
      $(live_task m2 'Namespaced provider' alpha openai-codex/gpt-5.6-terra 2 Building live),
      $(live_task m3 'Tagged local model' alpha ollama/qwen3.6:35b-fm 2 Building live),
      $(live_task m4 'Dated release' alpha claude-haiku-4-5-20251001 2 Building live),
      $(live_task m5 'Single word' alpha sonnet 2 Building live)]" \
    > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a board with varied model ids must render"
  assert_grep '>Opus 5</span>' "$board" "a vendor prefix must be dropped from the name"
  assert_grep '>GPT-5.6 Terra</span>' "$board" \
    "a namespaced provider must be dropped and the model read as a name"
  assert_grep '>qwen3.6:35b-fm</span>' "$board" \
    "a tagged local model must keep the exact tag it is addressed by"
  assert_grep '>Haiku 4.5</span>' "$board" \
    "a release stamp must be dropped and a split version rejoined"
  assert_grep '>Sonnet</span>' "$board" "a single-word model must still read as a name"
  assert_no_grep 'claude-opus-5' "$board" "a raw dispatch id must not reach the card"
  assert_no_grep '20251001' "$board" "a release stamp must not reach the card"
  pass "recorded model ids are shown as names the captain reads"
}

# An older secondmate home reports a routed task without the title, model, or
# stage this board wants. Absent is not the same as empty, and a blank where a
# fact belongs reads as a fact.
test_unrecorded_item_facts_are_disclosed_rather_than_blanked() {
  local snap board
  snap=$TMP_ROOT/unrecorded.json
  board=$TMP_ROOT/unrecorded.html
  snapshot_json '[]' '[{
    "id": "docsmate", "registered": true, "provenance": {"selected": "structured-home"},
    "current": {"state": "active_child_work", "reason": ""},
    "active_children": [
      {"id": "docs-legacy", "kind": "ship", "state": "working", "source": "pane"},
      {"id": "docs-new", "kind": "ship", "state": "working", "source": "run-step",
       "title": "Refresh the operator guide", "model": "claude-opus-5",
       "stage": {"ordinal": 3, "of": 5, "label": "Validating", "motion": "live"}}
    ],
    "decisions_open": [], "holds": [], "queued": [],
    "counts": {"active_children": 2, "decisions_open": 0, "holds": 0, "queued": 0},
    "omitted": []
  }]' > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a secondmate reporting partial item facts must render"
  assert_grep 'Refresh the operator guide' "$board" "a routed task must be named on the card"
  assert_grep '>Opus 5</span>' "$board" "a routed task must show the model running it"
  assert_grep 'aria-label="Stage 3 of 5: Validating"' "$board" \
    "a routed task must carry its stage onto the card"
  assert_grep 'docs-legacy' "$board" \
    "a task reported without a title must fall back to its id rather than vanish"
  assert_grep 'model not recorded' "$board" \
    "an unrecorded model must be stated, never shown as a blank"
  assert_grep 'Stage unavailable' "$board" \
    "an unreported stage must be stated, never drawn as an honest-looking empty bar"
  assert_grep 'class="wi-bar m-unknown"' "$board" \
    "an unreported stage must not fill a rung it cannot prove"
  pass "an item fact the fleet did not record is disclosed rather than blanked"
}

# A stage on a routed task crosses a home boundary, and for a remote second mate
# a host boundary, so its numbers are another producer's. An out-of-range rung, a
# huge scale, or a motion this board has no rule for must not be drawn as given:
# the failure mode is a bar and its own label disagreeing, which is precisely
# what the ladder exists to prevent.
test_out_of_range_stage_values_are_bounded_before_they_are_drawn() {
  local snap board
  snap=$TMP_ROOT/hostile-stage.json
  board=$TMP_ROOT/hostile-stage.html
  snapshot_json '[]' '[{
    "id": "oddmate", "registered": true, "provenance": {"selected": "structured-home"},
    "current": {"state": "active_child_work", "reason": ""},
    "active_children": [
      {"id": "huge", "kind": "ship", "state": "working", "source": "pane",
       "title": "Scale far beyond the ladder", "model": "claude-opus-5",
       "stage": {"ordinal": 99, "of": 5000, "label": "Validating", "motion": "live"}},
      {"id": "unknown-motion", "kind": "ship", "state": "working", "source": "pane",
       "title": "Motion this board has no rule for", "model": "claude-opus-5",
       "stage": {"ordinal": 3, "of": 5, "label": "Validating", "motion": "sideways"}}
    ],
    "decisions_open": [], "holds": [], "queued": [],
    "counts": {"active_children": 2, "decisions_open": 0, "holds": 0, "queued": 0},
    "omitted": []
  }]' > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "an out-of-range stage must render rather than break the board"
  assert_no_grep 'Stage 99 of 5000' "$board" \
    "a rung and a scale from another home must be bounded before they are claimed"
  assert_grep 'aria-label="Stage 5 of 5: Validating"' "$board" \
    "an over-range rung must be clamped to the top of the ladder it is drawn on"
  # Five rungs drawn and five filled: the bar and its label still agree.
  assert_grep '<i class="on"></i><i class="on"></i><i class="on"></i><i class="on"></i><i class="on"></i>' "$board" \
    "a clamped rung must fill exactly the rungs its label claims"
  assert_no_grep 'm-sideways' "$board" \
    "a motion with no rule behind it must never reach the page as a class"
  assert_grep 'class="wi-bar m-unknown"' "$board" \
    "an unrecognised motion must fall back to the tone that claims nothing"
  pass "stage values from another home are bounded before the ladder is drawn"
}

# A card keeps its common case open at a glance but must retain every received
# row. Overflow therefore belongs in the board's expandable shelf idiom.
test_long_item_list_keeps_every_item_in_an_expandable_shelf() {
  local snap board records tasks i bar_count model_count
  snap=$TMP_ROOT/many.json
  board=$TMP_ROOT/many.html
  records=""
  tasks=""
  for i in 1 2 3 4 5 6 7 8; do
    [ -z "$records" ] || { records="$records,"; tasks="$tasks,"; }
    records="$records$(in_flight_record "t$i" "Task number $i" alpha)"
    tasks="$tasks$(live_task "t$i" "Task number $i" alpha claude-opus-5 2 Building live)"
  done
  snapshot_json "[$records]" '[]' "[$tasks]" > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a card with many in-progress items must render"
  assert_grep '8 tasks under way' "$board" "the full count must never be capped"
  assert_grep 'Task number 6' "$board" "the open item list must reach the shelf boundary"
  assert_grep '<details class="shelf"><summary>' "$board" \
    "overflow must reuse the board's expandable shelf"
  assert_no_grep '<details class="shelf" id="deferred-shelf">' "$board" \
    "a project overflow shelf must not identify itself as Deferred"
  assert_grep '<span class="stitle">More in progress</span><span class="scount">2 more</span>' "$board" \
    "the shelf summary must state how many received rows it contains"
  assert_grep 'Task number 7' "$board" "the first shelved item must remain in the page"
  assert_grep 'Task number 8' "$board" "every received item must remain in the page"
  bar_count=$(grep -o 'aria-label="Stage 2 of 5: Building"' "$board" | wc -l | tr -d ' ')
  [ "$bar_count" = 8 ] || fail "every received item must retain its stage ladder, got $bar_count"
  model_count=$(grep -o '<span class="wi-model">Opus 5</span>' "$board" | wc -l | tr -d ' ')
  [ "$model_count" = 8 ] || fail "every received item must retain its model label, got $model_count"
  assert_no_grep 'not listed here' "$board" "received rows must never be described as unlisted"
  pass "a long item list keeps every received row in an expandable shelf"
}

# A second mate home can bound its children before the board sees them. Those
# unavailable rows are distinct from received rows placed in the local shelf.
test_upstream_omissions_stay_distinct_from_shelved_items() {
  local snap board children i
  snap=$TMP_ROOT/stacked.json
  board=$TMP_ROOT/stacked.html
  children=""
  for i in 1 2 3 4 5 6 7 8; do
    [ -z "$children" ] || children="$children,"
    children="$children{\"id\": \"c$i\", \"kind\": \"ship\", \"state\": \"working\",
      \"source\": \"pane\", \"title\": \"Routed task $i\", \"model\": \"claude-opus-5\",
      \"stage\": {\"ordinal\": 2, \"of\": 5, \"label\": \"Building\", \"motion\": \"live\"}}"
  done
  # The home reports 20 active children and hands over only 8 of them.
  snapshot_json '[]' "[{
    \"id\": \"busymate\", \"registered\": true, \"provenance\": {\"selected\": \"structured-home\"},
    \"current\": {\"state\": \"active_child_work\", \"reason\": \"\"},
    \"active_children\": [$children],
    \"decisions_open\": [], \"holds\": [], \"queued\": [],
    \"counts\": {\"active_children\": 20, \"decisions_open\": 0, \"holds\": 0, \"queued\": 0},
    \"omitted\": [{\"surface\": \"active_children\", \"count\": 12}]
  }]" > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a card whose home already bounded its children must render"
  assert_grep '<span class="stitle">More in progress</span><span class="scount">2 more</span>' "$board" \
    "the shelf must count only the received rows it contains"
  assert_grep 'Routed task 8' "$board" \
    "every child row received from the second mate must remain available"
  assert_grep '12 more active tasks were not included in this snapshot.' "$board" \
    "the upstream omission must be disclosed without mixing it into the shelf count"
  assert_grep '20 active tasks (8 shown)' "$board" \
    "the home bound must stay separately disclosed on the card"
  pass "upstream omissions stay distinct from received rows in the shelf"
}

test_renders_live_fixture_home() {
  local home fakebin out board
  home=$(make_home live)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "rendering a populated home must succeed"
  board="$home/state/mission-control.html"
  [ "$out" = "$board" ] || fail "default output path must be <state>/mission-control.html, got $out"
  assert_present "$board" "the board file must be written"

  assert_grep 'Awaiting your decision' "$board" "the board must carry a decisions-awaiting section"
  assert_grep 'Choose the alpha rollout window' "$board" "a captain-held item must be surfaced"
  assert_grep 'Two rollout windows both cost money' "$board" "the captain-held reason must be shown"
  assert_grep 'https://github.com/example/alpha/pull/9' "$board" "a recorded PR must be surfaced as a call"

  # End to end from the task metadata through the snapshot to the card. Every
  # other item case injects a stage object, so this is the only place that proves
  # the board reads the stage at the path the snapshot writes it: a field-name
  # drift between the two would quietly degrade every card to "Stage unavailable"
  # while leaving the injected cases green.
  assert_grep '1 task under way' "$board" "the live count must survive on the card"
  assert_grep 'Rebuild the alpha intake form' "$board" \
    "the live task must name itself on its project card"
  assert_grep '>Opus 5</span>' "$board" \
    "the model recorded for the live task must reach its card as a name"
  assert_grep 'aria-label="Stage 2 of 5: Building"' "$board" \
    "a task working before validation must reach its card at the rung it earned"
  assert_no_grep 'Stage unavailable' "$board" \
    "a stage the snapshot derived must never read as unavailable on the card"
  assert_grep '1 decision and 1 PR await you' "$board" \
    "a project card must total the calls waiting on the captain"
  assert_grep 'class="proj-name">alpha' "$board" "each registered project must get a card"
  assert_grep 'direct-PR +yolo' "$board" "a project card must show its delivery posture"

  assert_grep 'Ship the alpha health check' "$board" "an item landed today must appear as shipped"
  assert_grep 'https://github.com/example/alpha/pull/7' "$board" "a landed item must keep its link"

  # No completion percentage or ETA is ever invented for active work.
  assert_no_grep 'ETA' "$board" "the board must not invent an ETA"
  assert_no_grep '% complete' "$board" "the board must not invent a completion percentage"

  # The board is renamed into place, so a browser never reads a partial file.
  [ -z "$(find "$home/state" -name '.mission-control.html.*' -print -quit)" ] \
    || fail "no temporary board file may survive a successful render"
  pass "a populated home renders every section from live state"
}

test_project_last_change_comes_from_the_clone() {
  local home fakebin board
  home=$(make_home updated)
  cat > "$home/data/projects.md" <<'EOF'
# Project registry

- today-proj [direct-PR] - Changed this morning
- yesterday-proj [direct-PR] - Changed last night
- older-proj [direct-PR] - Changed last July
EOF
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  make_clone "$home" today-proj "$TODAY_0905"
  make_clone "$home" yesterday-proj "$YESTERDAY_2335"
  make_clone "$home" older-proj "$LAST_JULY"
  fakebin=$(make_fakebin "$home")

  board=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "a home with clones must render"

  # Wording is relative to the board's own NOW, never to a second clock read,
  # so the same snapshot renders identically every time.
  assert_grep 'Updated 9:05am today' "$board" \
    "a clone committed today must read as a time today"
  assert_grep 'Updated 11:35pm yesterday' "$board" \
    "a clone committed yesterday must read as a time yesterday"
  assert_grep 'Updated 22 Jul' "$board" \
    "an older clone must fall back to its calendar date"
  pass "each project card is dated from its own clone, relative to the board's NOW"
}

test_yesterday_uses_local_calendar_arithmetic() {
  local home fakebin board
  home=$(make_home dst-yesterday)
  printf -- '- fallback-proj [direct-PR] - Changed before fallback\n' > "$home/data/projects.md"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  make_clone "$home" fallback-proj 1792881000
  fakebin=$(make_fakebin "$home")
  board=$(TZ=Europe/London PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_MISSION_CONTROL_NOW_EPOCH=1792971000 "$BOARD" --no-quota) \
    || fail "a render across the autumn clock change must succeed"
  assert_grep 'Updated 11:30pm yesterday' "$board" \
    "the previous local calendar day must remain yesterday across DST fallback"
  pass "yesterday follows the local calendar across DST fallback"
}

test_missing_change_time_degrades_to_a_dash() {
  local home fakebin board dashes
  home=$(make_home nodate)
  cat > "$home/data/projects.md" <<'EOF'
# Project registry

- no-clone [direct-PR] - Never cloned here
- not-a-repo [direct-PR] - A directory that is not a git repo
- empty-repo [direct-PR] - A git repo with no commits
EOF
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  mkdir -p "$home/projects/not-a-repo"
  : > "$home/projects/not-a-repo/README.md"
  mkdir -p "$home/projects/empty-repo"
  git -C "$home/projects/empty-repo" init -q
  fakebin=$(make_fakebin "$home")

  board=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "projects with no readable history must still render"

  # An absent clone, a directory that is not a repo, and a repo with no commits
  # are three different gaps, and all three must read as "no time recorded"
  # rather than as a plausible-looking time.
  dashes=$(grep -c 'Updated &mdash;' "$board")
  [ "$dashes" = 3 ] || fail "every project with no readable history must show a dash, got $dashes"
  assert_no_grep 'Updated today' "$board" "a missing history must not be rendered as today"
  assert_no_grep 'Updated just now' "$board" "a missing history must not be rendered as recent"
  pass "an absent, non-git, or empty clone degrades to a dash instead of a guessed time"
}

test_render_writes_nothing_into_the_project_clones() {
  local home fakebin marker touched
  home=$(make_home readonly)
  cat > "$home/data/projects.md" <<'EOF'
# Project registry

- probe [direct-PR] - Read-only probe
EOF
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  make_clone "$home" probe "$TODAY_0905"
  fakebin=$(make_fakebin "$home")
  marker=$TMP_ROOT/readonly.marker
  : > "$marker"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota --out "$TMP_ROOT/readonly.html" >/dev/null \
    || fail "the read-only probe render must succeed"

  # Reading a clone's history is the only thing the board does to a project.
  touched=$(find "$home/projects" -newer "$marker" -print | head -5)
  [ -z "$touched" ] || fail "the board must not write inside a project clone, touched: $touched"
  pass "rendering reads project history without writing into any clone"
}

test_absent_sources_render_empty_sections() {
  local home fakebin out board
  home=$(make_home empty)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "an empty home must still render"
  board=$out
  assert_grep 'Nothing needs your decision right now.' "$board" \
    "an empty home must say nothing is waiting"
  assert_grep '<div class="n">0</div><div class="l">In progress</div>' "$board" \
    "an empty home must report no work under way"
  assert_grep 'Nothing landed yet today.' "$board" "an empty home must report nothing landed today"
  assert_grep 'Nothing blocked or failed.' "$board" "an empty home must report clear fleet health"
  assert_grep 'No project registry found' "$board" "an absent registry must be reported, not crash"
  assert_grep 'No second mates registered.' "$board" "an absent secondmate registry must be reported"
  assert_grep 'Allowance unavailable' "$board" "a skipped allowance read must be disclosed"
  pass "absent sources render as explicit empty sections instead of failing"
}

test_hostile_text_is_escaped() {
  local snap board out script_tags
  snap=$TMP_ROOT/hostile.json
  board=$TMP_ROOT/hostile.html
  cat > "$snap" <<'EOF'
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "</script><script>alert(3)</script>",
  "fm_home": "/fixture/home",
  "roots": {"state": "/fixture/home/state", "data": "/fixture/home/data",
            "projects": "/fixture/home/projects"},
  "backlog": {"present": true, "records": [{
    "state": "queued", "id": "x1", "captain_actionable": true,
    "title": "<script>alert(1)</script> & \"quoted\"",
    "hold_reason": "<img src=x onerror=alert(2)>",
    "repo": "alpha"
  }]},
  "tasks": [],
  "secondmate_current": {"registry": {
    "present": false, "available": true, "complete": true,
    "input_truncated": false, "records_truncated": false, "records": []
  }, "records": []}
}
EOF
  out=$("$BOARD" --snapshot "$snap" --no-quota --out "$board") \
    || fail "hostile prose must still render"
  assert_no_grep '<script>alert(1)</script>' "$board" "markup in fleet prose must not reach the page as markup"
  assert_no_grep '<img src=x' "$board" "an injected tag must not reach the page as markup"
  assert_grep '&lt;script&gt;alert(1)&lt;/script&gt;' "$board" "markup must be escaped and still readable"
  assert_grep '&quot;quoted&quot;' "$board" "quotes in fleet prose must be escaped"
  assert_no_grep '<script>alert(3)</script>' "$board" \
    "a generated timestamp with a literal JSON unicode closing tag must not break out of the inline script"
  # Checked directly, not only by counting scripts: the payload has to be on the
  # page in escaped form, which is what proves it was neutralized rather than
  # dropped or silently rewritten.
  assert_grep '&lt;/script&gt;&lt;script&gt;alert(3)&lt;/script&gt;' "$board" \
    "the closing-tag payload must reach the page escaped and readable"
  # The board renders exactly two of its own scripts: the tab chosen in <head>
  # before first paint, and the age ticker plus tab wiring at the end of the
  # body. A third means hostile prose opened one of its own.
  script_tags=$(grep -o '<script>' "$board" | wc -l | tr -d ' ')
  [ "$script_tags" = 2 ] || fail "the rendered page must contain only its own two scripts, got $script_tags"
  pass "prose from fleet state is escaped before it reaches the page"
}

test_missing_backlog_is_disclosed_as_unavailable() {
  local snap board
  snap=$TMP_ROOT/no-backlog.json
  board=$TMP_ROOT/no-backlog.html
  snapshot_json '[]' '[]' | jq '.backlog.present = false' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a snapshot with an absent backlog must render"
  assert_grep 'waiting status incomplete' "$board" \
    "waiting status must be incomplete when main-home decisions cannot be read"
  assert_grep 'Main backlog is unavailable' "$board" "the missing decision source must be named"
  assert_grep '<div class="n">?</div><div class="l">Shipped today</div>' "$board" \
    "landed work must read as unknown, not as zero"
  assert_grep 'backlog unavailable' "$board" "the unreadable source must be named on the summary tile"
  assert_grep 'Shipped today is unavailable' "$board" "shipped work must not render as empty"
  assert_grep 'Backlog health is unavailable' "$board" "backlog health must not render as clear"
  assert_grep 'Fleet health cannot be confirmed' "$board" \
    "unconfirmable health must be raised above the board, not buried in a panel"
  assert_no_grep 'Nothing needs your decision right now.' "$board" \
    "an absent backlog must not produce an authoritative all-clear"
  assert_no_grep 'Nothing landed yet today.' "$board" \
    "an absent backlog must not produce an authoritative shipped zero"
  assert_no_grep 'Nothing blocked or failed.' "$board" \
    "an absent backlog must not produce an authoritative health all-clear"
  # An unreadable backlog cannot prove that nothing was set aside either, so the
  # shelf stays away rather than asserting a count it did not read.
  assert_no_grep 'set aside' "$board" \
    "an absent backlog must not produce an authoritative deferred count"
  pass "an absent backlog marks every backlog-derived conclusion unavailable"
}

# A decision the captain sets aside must leave the primary view completely -
# the list, the section count, and the "Awaiting you" tile - and reappear only
# in the quiet shelf. Dropping it from the list while still counting it, or
# counting it while still listing it, are separate failures, so both are pinned
# to literal numbers rather than to the absence of the title alone.
test_deferred_decision_leaves_the_primary_view() {
  local home fakebin board
  home=$(make_home deferred)
  make_clone "$home" alpha "$TODAY_0905"
  printf -- '- alpha [direct-PR] - Alpha service\n' > "$home/data/projects.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] alpha-window - Choose the alpha rollout window (repo: alpha) (kind: captain) (hold: Two rollout windows both cost money) (hold-kind: captain)
- [ ] pushcut-sub - Approve the Pushcut Pro subscription (repo: alpha) (kind: captain) (hold: The subscription renews yearly) (hold-kind: parked)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  board=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "a home with a deferred decision must render"

  assert_grep '<div class="n">1</div><div class="l">Awaiting you</div>' "$board" \
    "a deferred decision must not be counted in the awaiting tile"
  assert_grep '<span class="count">1 item' "$board" \
    "a deferred decision must not be counted in the awaiting section header"
  assert_grep 'Choose the alpha rollout window' "$board" \
    "the decision still awaiting the captain must stay in view"

  # Present once, in the shelf, with the reason that identifies it.
  [ "$(grep -c 'Approve the Pushcut Pro subscription' "$board")" = 1 ] \
    || fail "a deferred decision must appear exactly once, in the shelf"
  assert_grep 'class="shelf" id="deferred-shelf"' "$board" \
    "a deferred decision must render the uniquely identified deferred shelf"
  assert_grep '1 set aside' "$board" "the shelf must say how many decisions are set aside"
  assert_grep 'class="defer"' "$board" "the deferred decision must render as a deferred row"
  assert_grep 'The subscription renews yearly' "$board" \
    "a deferred decision must keep the reason that identifies it"

  # Setting a decision aside is a choice, not a gap in the data, and it is not a
  # blocker either.
  assert_no_grep 'waiting status incomplete' "$board" \
    "deferring a decision must not mark the waiting status incomplete"
  assert_no_grep 'some sources unavailable' "$board" \
    "deferring a decision must not read as an unavailable source"
  assert_grep 'Nothing blocked or failed.' "$board" \
    "a deferred decision must not surface as blocked or failed work"
  assert_grep '1 decision awaits you' "$board" \
    "a project card must count only the decisions still awaiting the captain"
  pass "a deferred decision leaves the awaiting list, the awaiting count, and health"
}

# The shelf is fed by whatever the snapshot could read. A secondmate home reports
# its queued rows bounded, so the shelf says when a decision set aside there may
# be outside the window rather than implying the list is complete.
test_deferred_shelf_reaches_a_secondmate_and_discloses_its_bound() {
  local snap board
  snap=$TMP_ROOT/deferred-sm.json
  board=$TMP_ROOT/deferred-sm.html
  snapshot_json '[]' '[{
    "id": "homemux", "registered": true,
    "provenance": {"selected": "structured-home"},
    "current": {"state": "no_active_work"},
    "decisions_open": [], "holds": [], "active_children": [],
    "queued": [
      {"id": "hm-tariff", "title": "Approve the HomeMux tariff switch",
       "hold_reason": "The switch locks in for a year", "hold_kind": "parked",
       "captain_actionable": false, "captain_deferred": true, "repo": "homemux"}
    ],
    "counts": {"decisions_open": 0, "holds": 0, "active_children": 0, "queued": 4},
    "omitted": [{"surface": "queued", "count": 3}]
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a snapshot carrying a deferred secondmate decision must render"
  assert_grep 'Approve the HomeMux tariff switch' "$board" \
    "a decision set aside in a secondmate home must reach the shelf"
  assert_grep 'homemux' "$board" "a deferred row must name where the decision lives"
  assert_grep '3 queued second mate rows were not read' "$board" \
    "a bounded queued read must be disclosed instead of implying a complete shelf"
  assert_no_grep 'class="hstate' "$board" \
    "a deferred decision must not be reported as held or blocked fleet health"
  pass "a deferred secondmate decision reaches the shelf with its bound disclosed"
}

# The header, the stat strip and the attention bar answer "is anything on fire,
# and how much awaits me", so they must never be tabbed away; everything else is
# grouped behind one of four tabs.
test_navigation_tabs_group_the_board() {
  local snap board section
  snap=$TMP_ROOT/tabs.json
  board=$TMP_ROOT/tabs.html
  snapshot_json '[{"state": "queued", "id": "d1", "captain_actionable": true,
    "title": "Choose something", "hold_reason": "because", "repo": "alpha"}]' '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "the board must render with its navigation tabs"

  assert_grep 'role="tablist"' "$board" "the board must expose a tablist"
  for section in decisions projects activity system; do
    assert_grep "id=\"tab-$section\" role=\"tab\"" "$board" "the $section tab must render"
    assert_grep "id=\"panel-$section\" role=\"tabpanel\"" "$board" "the $section panel must render"
    assert_grep "aria-controls=\"panel-$section\"" "$board" \
      "the $section tab must name the panel it controls"
  done
  assert_grep 'aria-labelledby="tab-decisions"' "$board" \
    "each panel must name the tab that labels it"
  # The tab has to be chosen before the body paints, or the default panel
  # flashes on every one of the board's own reloads.
  sed -n '1,/<body>/p' "$board" | grep -q '<script>' \
    || fail "the board must choose its tab before the body paints"

  # Always in view, outside every panel.
  section=$(sed -n '/<div class="wrap">/,/<div class="panel"/p' "$board")
  printf '%s' "$section" | grep -q '<h1>Mission Control</h1>' \
    || fail "the header must sit above the tabs"
  printf '%s' "$section" | grep -q 'class="l">Awaiting you</div>' \
    || fail "the stat strip must sit above the tabs"
  printf '%s' "$section" | grep -q 'class="tabs"' \
    || fail "the tab strip must sit above every panel"

  # The tab is remembered rather than carried in the URL, because the board's
  # own reload navigates without the fragment.
  assert_grep 'localStorage.setItem("fm-mission-control-tab"' "$board" \
    "the selected tab must be remembered across the board's own reload"
  assert_grep 'http-equiv="refresh"' "$board" \
    "the board must keep reloading itself with tabs in place"
  # An opened shelf snapping shut mid-read is the same reset the tabs avoid.
  assert_grep 'localStorage.setItem("fm-mission-control-deferred"' "$board" \
    "an opened deferred shelf must survive the board's own reload"
  assert_grep 'document.getElementById("deferred-shelf")' "$board" \
    "deferred persistence must target only the deferred shelf"
  assert_no_grep 'document.querySelector("details.shelf")' "$board" \
    "project overflow shelves must not share deferred persistence"
  assert_no_grep 'src="http' "$board" "the tabs must not depend on a network asset"
  pass "the board groups its sections behind keyboard-reachable navigation tabs"
}

# A fragment is only present on the entry load because the board's meta refresh
# drops it. Execute the rendered head script twice against one browser-shaped
# storage area to prove that the fragment-selected tab becomes the remembered
# tab before the fragment disappears.
test_fragment_selected_tab_survives_reload() {
  local snap board
  snap=$TMP_ROOT/fragment-tab.json
  board=$TMP_ROOT/fragment-tab.html
  snapshot_json '[]' '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "the fragment tab behavior fixture must render"
  command -v node >/dev/null 2>&1 \
    || fail "node is required to execute the rendered board's head script"
  node - "$board" <<'JS' \
    || fail "a fragment-selected tab must survive the next fragmentless load"
const fs = require("node:fs");
const vm = require("node:vm");
const html = fs.readFileSync(process.argv[2], "utf8");
const head = html.slice(0, html.indexOf("<body>"));
const script = head.match(/<script>([\s\S]*?)<\/script>/)?.[1];
if (!script) process.exit(1);

const values = new Map();
const storage = {
  getItem(key) { return values.has(key) ? values.get(key) : null; },
  setItem(key, value) { values.set(key, value); }
};

function load(hash, localStorage) {
  const document = {documentElement: {className: ""}};
  const window = {location: {hash}, localStorage};
  vm.runInNewContext(script, {document, window});
  return document.documentElement.className;
}

if (load("#tab=system", storage) !== "js t-system") process.exit(1);
if (load("", storage) !== "js t-system") process.exit(1);

const refused = {
  getItem() { throw new Error("storage refused"); },
  setItem() { throw new Error("storage refused"); }
};
if (load("#tab=system", refused) !== "js t-decisions") process.exit(1);
JS
  pass "a fragment-selected tab is remembered before the fragment disappears"
}

# An attention bar the captain cannot follow is worse than none: clicking it has
# to reach fleet health wherever health now lives.
test_attention_bar_reaches_health_across_tabs() {
  local snap board
  snap=$TMP_ROOT/attn-tabs.json
  board=$TMP_ROOT/attn-tabs.html
  snapshot_json '[{"state": "queued", "id": "b1", "structured": true,
    "title": "Blocked item", "unresolved_blocker_ids": ["dep-1"], "repo": "alpha"}]' '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a board with blocked work must render"
  assert_grep 'class="attnbar" href="#health" data-tab="system"' "$board" \
    "the attention bar must open the tab that carries fleet health"
  assert_grep 'id="health"' "$board" \
    "fleet health must keep an anchor so the bar still lands with no script"
  pass "the attention bar reaches fleet health once health sits behind a tab"
}

test_unreadable_backlog_does_not_leave_projects_looking_calm() {
  local snap board data
  snap=$TMP_ROOT/no-backlog-registry.json
  board=$TMP_ROOT/no-backlog-registry.html
  data=$TMP_ROOT/no-backlog-registry-data
  mkdir -p "$data"
  printf -- '- alpha [direct-PR] - Alpha service\n- beta [no-mistakes] - Beta site\n' \
    > "$data/projects.md"
  snapshot_json '[]' '[]' \
    | jq --arg d "$data" '.backlog.present = false | .roots.data = $d' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a readable registry with an unreadable backlog must render"

  # Every quiet signal on a project card - no decisions, nothing queued,
  # nothing in flight - is read from the backlog, so with the backlog gone a
  # calm-looking card would be asserting a fact the board cannot know.
  assert_grep 'class="proj-name">alpha' "$board" "registered projects must still get cards"
  assert_grep 'Unconfirmed' "$board" "a project whose state cannot be read must say so on the card"
  assert_grep 'Your decisions here cannot be counted.' "$board" \
    "the card must name the missing source"
  assert_no_grep '>Idle</span>' "$board" \
    "a project must never read as idle while its backlog cannot be read"
  assert_no_grep 'Nothing in flight.' "$board" \
    "a project must never claim an empty queue it cannot see"
  pass "an unreadable backlog never leaves a project card looking calm"
}

test_blocked_work_is_raised_above_the_board() {
  local snap board
  snap=$TMP_ROOT/blocked.json
  board=$TMP_ROOT/blocked.html
  snapshot_json '[
    {"state": "queued", "id": "b1", "title": "Waits on the licence call",
     "repo": "alpha", "unresolved_blocker_ids": ["licence-call"]}
  ]' '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "blocked work must render"
  # Health sits below the three primary sections, so anything blocked or failed
  # is announced at the top rather than left for the captain to scroll to.
  assert_grep '1 item is blocked or failed' "$board" \
    "blocked work must be announced above the primary sections"
  assert_grep 'blocked by licence-call' "$board" "the blocker must be named in fleet health"
  assert_grep 'Waits on the licence call' "$board" "the blocked item must be named"
  assert_no_grep 'Nothing blocked or failed.' "$board" \
    "a board with blocked work must not also claim to be clear"
  pass "blocked work is raised above the board instead of hidden in a panel"
}

test_duplicate_main_health_sources_are_normalized() {
  local snap board matches
  snap=$TMP_ROOT/duplicate-health.json
  board=$TMP_ROOT/duplicate-health.html
  snapshot_json '[{
    "state": "in_flight", "id": "dup-task", "title": "Blocked duplicate",
    "repo": "alpha", "unresolved_blocker_ids": ["access"]
  }]' '[]' | jq '.tasks = [{
    id: "dup-task", kind: "ship", project: "alpha",
    current_state: {state: "blocked"}, hints: {blocked_event: true},
    backlog: {title: "Blocked duplicate", repo: "alpha"},
    paths: {status_log: {last_event: {raw: "blocked: access"}}},
    pr: {url: null}
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "duplicate task and backlog health evidence must render"
  assert_grep '1 item is blocked or failed' "$board" \
    "one blocked task must be counted once across health sources"
  assert_no_grep '2 items are blocked or failed' "$board" \
    "duplicate health evidence must not inflate the attention count"
  assert_grep 'blocked by access' "$board" \
    "normalized task health must retain the backlog blocker"
  matches=$(grep -o '>dup-task<' "$board" | wc -l | tr -d ' ')
  [ "$matches" = 1 ] || fail "normalized health must render dup-task once, got $matches"
  pass "main task health is normalized by task identity"
}

test_secondmate_captain_decision_is_surfaced() {
  local snap board
  snap=$TMP_ROOT/secondmate.json
  board=$TMP_ROOT/secondmate.html
  snapshot_json '[]' '[{
    "id": "brain",
    "home": "/fixture/brain",
    "current": {"state": "captain_decision"},
    "active_children": [],
    "decisions_open": [{
      "id": "brain-cost", "key": "brain-cost", "verb": "captain-hold",
      "summary": "Approve the paid notification tier",
      "reason": "The two-way leg needs the paid tier"
    }],
    "holds": [{
      "id": "brain-cost", "source": "backlog", "unresolved_blocker_ids": [],
      "reason": "The two-way leg needs the paid tier"
    }],
    "counts": {"active_children": 0, "decisions_open": 1, "holds": 1}
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a secondmate-only decision must render"
  # This decision lives in the secondmate's own backlog, never in this home's,
  # so building the section from the main backlog alone would silently drop it.
  assert_grep 'Approve the paid notification tier' "$board" \
    "a captain decision held inside a secondmate home must reach the board"
  assert_grep '<span class="tag">brain</span>' "$board" "the owning home must be named on the row"
  assert_grep '<div class="n">1</div><div class="l">Awaiting you</div>' "$board" \
    "a secondmate decision must be counted as waiting"
  assert_grep 'Routed work is waiting for your decision.' "$board" \
    "the card must reflect the authoritative captain-decision state"
  assert_grep 'Nothing blocked or failed.' "$board" \
    "a captain decision must stay out of fleet health"
  assert_no_grep '>Blocked</span>' "$board" \
    "a captain decision must keep the needs-you pill"
  assert_grep 'second mate' "$board" "a secondmate card must say what it is"
  pass "a captain decision inside a secondmate home is surfaced and counted"
}

test_secondmate_mixed_decision_and_child_hold_stay_distinct() {
  local snap board
  snap=$TMP_ROOT/secondmate-mixed-holds.json
  board=$TMP_ROOT/secondmate-mixed-holds.html
  snapshot_json '[]' '[{
    "id": "brain", "current": {"state": "captain_decision"},
    "active_children": [],
    "decisions_open": [{
      "id": "brain-cost", "key": "brain-cost", "verb": "captain-hold",
      "summary": "Approve the paid notification tier"
    }],
    "holds": [{
      "id": "brain-cost", "source": "backlog", "unresolved_blocker_ids": [],
      "reason": "Captain pricing choice"
    }, {
      "id": "vendor-window", "source": "child-state", "unresolved_blocker_ids": [],
      "reason": "Paused for the vendor maintenance window"
    }],
    "counts": {"active_children": 0, "decisions_open": 1, "holds": 2}
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "mixed secondmate decisions and child holds must render"
  assert_grep '<div class="n">1</div><div class="l">Awaiting you</div>' "$board" \
    "the captain decision must remain in the waiting count"
  assert_grep '1 fleet health item needs attention' "$board" \
    "only the child-state hold must reach the health count"
  assert_grep '>vendor-window<' "$board" \
    "the child-state hold must appear in fleet health"
  assert_grep 'Paused for the vendor maintenance window' "$board" \
    "child-state health must render its own wait reason"
  assert_no_grep 'blocked or failed' "$board" \
    "the captain decision must not be counted as unhealthy"
  assert_no_grep 'blocked by vendor-window' "$board" \
    "a paused child-state hold must not be relabelled as a blocker"
  pass "mixed secondmate decisions and child holds remain distinct"
}

test_secondmate_change_time_comes_from_its_own_reporting() {
  local home fakebin board
  home=$(make_home smtime)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf -- '- brain - Knowledge OS (home: %s; scope: brain; projects: brain; added 2026-01-01)\n' \
    "$home/secondmate" > "$home/data/secondmates.md"
  mkdir -p "$home/secondmate/state" "$home/secondmate/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/secondmate/data/backlog.md"
  fm_write_meta "$home/state/brain.meta" \
    "window=firstmate:fm-brain" \
    "kind=secondmate" \
    "home=$home/secondmate"
  printf 'working: routed work picked up\n' > "$home/state/brain.status"
  # A second mate is dated by when it last reported, not by a clone it may not
  # have fast-forwarded: a plausible but stale time is worse than no time.
  touch -t 202601020905.00 "$home/state/brain.status"
  fakebin=$(make_fakebin "$home")

  board=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --no-quota) || fail "a home with a secondmate must render"
  assert_grep 'Updated 9:05am today' "$board" \
    "a secondmate card must be dated from when it last reported"
  pass "a second mate is dated by its own last report"
}

test_bounded_secondmate_decisions_are_disclosed() {
  local snap board
  snap=$TMP_ROOT/bounded-secondmates.json
  board=$TMP_ROOT/bounded-secondmates.html
  snapshot_json '[]' '[{
    "id": "brain",
    "home": "/fixture/brain",
    "current": {"state": "captain_decision"},
    "active_children": [],
    "decisions_open": [{
      "id": "brain-visible", "key": "brain-visible", "verb": "captain-hold",
      "summary": "Visible captain decision", "reason": "Visible bounded record"
    }],
    "counts": {"decisions_open": 3},
    "omitted": [{"surface": "decisions_open", "count": 2}]
  }]' | jq '.secondmate_current += {total: 2, shown: 1, truncated: 1}' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "bounded secondmate state must render"
  assert_grep '<div class="n">3+</div><div class="l">Awaiting you</div>' "$board" \
    "the count must include per-home omitted decisions and mark omitted homes unknown"
  assert_grep 'Additional captain decisions are not shown' "$board" \
    "per-home bounded decisions must produce an actionable disclosure"
  assert_grep 'Snapshot shows 1 of 3 decisions.' "$board" \
    "the per-home disclosure must state the bounded count"
  assert_grep 'Snapshot omitted 1 secondmate record(s).' "$board" \
    "top-level secondmate truncation must produce an incomplete-state disclosure"
  assert_grep '3 decisions await you (1 shown)' "$board" \
    "the secondmate card must use the authoritative decision count"
  pass "bounded secondmate decisions remain visible as incomplete captain work"
}

test_unreadable_secondmate_sources_are_disclosed() {
  local snap board
  snap=$TMP_ROOT/unavailable-registry.json
  board=$TMP_ROOT/unavailable-registry.html
  snapshot_json '[]' '[]' | jq '.secondmate_current.registry = {
    present: true, available: false, complete: false,
    reason: "registered secondmate table is unreadable",
    input_truncated: false, records_truncated: false, records: []
  }' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "an unavailable secondmate registry must render"
  assert_grep 'waiting status incomplete' "$board" \
    "an unavailable registry must make the captain waiting status incomplete"
  assert_grep 'Secondmate registry scan is incomplete' "$board" \
    "an unavailable registry must produce an actionable disclosure"
  assert_grep 'registered secondmate table is unreadable' "$board" \
    "the registry disclosure must preserve the unavailable reason"
  assert_grep 'second mate list incomplete' "$board" \
    "an unavailable registry must mark the project count incomplete too"
  assert_no_grep '<div class="n">0</div><div class="l">Awaiting you</div>' "$board" \
    "an unavailable registry must not produce an authoritative zero"

  snap=$TMP_ROOT/bounded-registry.json
  board=$TMP_ROOT/bounded-registry.html
  snapshot_json '[]' '[]' | jq '.secondmate_current.registry = {
    present: true, available: true, complete: false,
    reason: null, reasons: ["record_limit"],
    input_truncated: false, records_truncated: true, records: []
  }' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a bounded secondmate registry must render"
  assert_grep 'waiting status incomplete' "$board" \
    "a bounded registry must make the captain waiting status incomplete"
  assert_grep 'record_limit' "$board" "the registry disclosure must preserve its truncation reason"
  assert_no_grep '<div class="n">0</div><div class="l">Awaiting you</div>' "$board" \
    "a bounded registry must not produce an authoritative zero"

  snap=$TMP_ROOT/unavailable-secondmate-home.json
  board=$TMP_ROOT/unavailable-secondmate-home.html
  snapshot_json '[]' '[{
    "id": "brain",
    "home": "/fixture/brain",
    "registered": true,
    "current": {"state": "unknown", "reason": "structured home snapshot failed"},
    "provenance": {"selected": "unknown"},
    "active_children": [], "decisions_open": [],
    "counts": {"decisions_open": 0}, "omitted": []
  }]' | jq '.secondmate_current.registry.records = [{
    id: "brain", home: "/fixture/brain", registered: true
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a registered secondmate with unreadable decisions must render"
  assert_grep 'waiting status incomplete' "$board" \
    "an unreadable registered home must make the captain waiting status incomplete"
  assert_grep 'Registered secondmate decisions are unavailable' "$board" \
    "an unreadable registered home must produce an actionable disclosure"
  assert_grep 'structured home snapshot failed' "$board" \
    "the registered-home disclosure must preserve the read failure reason"
  assert_grep 'Your decisions here cannot be read.' "$board" \
    "the secondmate card must not relabel an unreadable decision source as empty"
  assert_no_grep '<div class="n">0</div><div class="l">Awaiting you</div>' "$board" \
    "an unreadable registered home must not produce an authoritative zero"
  pass "unreadable and bounded secondmate sources prevent a false all-clear"
}

test_path_form_repo_folds_into_the_project_rollup() {
  local snap board
  snap=$TMP_ROOT/rollup.json
  board=$TMP_ROOT/rollup.html
  # tasks-axi records a repo as a bare name or as a full clone path; both name
  # the same project and must land on the same card.
  snapshot_json '[
    {"state": "queued", "id": "p1", "captain_actionable": true, "title": "Classify the cash movements",
     "repo": "/fixture/home/projects/alpha"},
    {"state": "queued", "id": "p2", "captain_actionable": false, "title": "Queued alpha work", "repo": "alpha"}
  ]' '[]' > "$snap"
  mkdir -p "$TMP_ROOT/rollup-data"
  printf -- '- alpha [direct-PR] - Alpha service\n' > "$TMP_ROOT/rollup-data/projects.md"
  jq --arg d "$TMP_ROOT/rollup-data" '.roots.data = $d' "$snap" > "$snap.tmp" && mv "$snap.tmp" "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a path-form repo must render"
  assert_no_grep '/fixture/home/projects/alpha' "$board" \
    "a clone path must be shown as its project name, not a full path"
  assert_grep 'class="proj-name">alpha' "$board" "the project must appear once under its registry name"
  assert_grep '1 decision awaits you' "$board" \
    "a path-form captain hold must be counted on its project card"
  assert_grep '2 queued, nothing under way' "$board" \
    "both rows must fold onto the same project card"
  pass "path-form and bare-name repos fold onto the same project"
}

test_live_work_outside_the_registry_stays_visible() {
  local snap board
  snap=$TMP_ROOT/unregistered.json
  board=$TMP_ROOT/unregistered.html
  snapshot_json '[]' '[]' | jq '.tasks = [{
    id: "orphan-task", kind: "ship", project: "/somewhere/gamma",
    current_state: {state: "working"},
    backlog: {title: "Rework the gamma importer", repo: "gamma"},
    pr: {url: null}, paths: {status_log: {last_event: {raw: "working: started"}}}
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "work on an unregistered project must render"
  # A task the captain can see running must never be invisible just because its
  # project was never registered.
  assert_grep '<div class="n">1</div><div class="l">In progress</div>' "$board" \
    "work under way must be counted"
  assert_grep 'Rework the gamma importer' "$board" \
    "work on an unregistered project must still name itself"
  # This row also arrives with no model and no stage, which is what a task row
  # from an older producer looks like: it stays listed, and says what it lacks.
  assert_grep 'Stage unavailable' "$board" \
    "a task row carrying no stage must be listed with the gap stated"
  assert_grep 'unregistered' "$board" "an unregistered project card must say so"
  pass "live work outside the registry is shown rather than silently dropped"
}

test_unregistered_live_project_uses_clone_change_time() {
  local home snap board
  home=$(make_home unregistered-updated)
  snap=$TMP_ROOT/unregistered-updated.json
  board=$TMP_ROOT/unregistered-updated.html
  make_clone "$home" gamma "$TODAY_0905"
  snapshot_json '[]' '[]' | jq --arg home "$home" '
    .roots.projects = ($home + "/projects") |
    .roots.data = ($home + "/data") |
    .tasks = [{
      id: "gamma-task", kind: "ship", project: "gamma",
      current_state: {state: "working"},
      backlog: {title: "Rework gamma", repo: "gamma"},
      pr: {url: null}
    }]' > "$snap"
  FM_MISSION_CONTROL_NOW_EPOCH="$NOW_EPOCH" \
    "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "an unregistered live project with a clone must render"
  assert_grep 'class="proj-name">gamma' "$board" \
    "the live unregistered project must get a card"
  assert_grep 'Updated 9:05am today' "$board" \
    "an unregistered project card must read its clone history"
  pass "unregistered live project cards read their clone change time"
}

test_secondmate_health_and_activity_use_authoritative_counts() {
  local snap board
  snap=$TMP_ROOT/secondmate-health.json
  board=$TMP_ROOT/secondmate-health.html
  snapshot_json '[]' '[{
    "id": "brain", "current": {"state": "externally_held"},
    "active_children": [], "decisions_open": [],
    "holds": [{
      "id": "vendor-sync", "source": "child-state",
      "unresolved_blocker_ids": [], "reason": "Waiting for vendor access"
    }],
    "counts": {"active_children": 0, "decisions_open": 0, "holds": 3}
  }, {
    "id": "ops", "current": {"state": "active_child_work"},
    "active_children": [{"id": "visible-child"}], "decisions_open": [], "holds": [],
    "counts": {"active_children": 4, "decisions_open": 0, "holds": 0},
    "omitted": [{"surface": "active_children", "count": 3}]
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "bounded secondmate health and activity must render"
  assert_grep '<div class="n">4</div><div class="l">In progress</div>' "$board" \
    "the in-progress stat must include authoritative secondmate child counts"
  assert_grep '3 active task details omitted' "$board" \
    "the stat must disclose bounded secondmate activity details"
  assert_grep '4 tasks routed and under way' "$board" \
    "the secondmate card must use its authoritative active count"
  assert_grep '4 active tasks (1 shown)' "$board" \
    "the secondmate card must disclose omitted active children"
  assert_grep '>Blocked</span>' "$board" \
    "an externally held secondmate must not render as ready"
  assert_grep 'Waiting for vendor access' "$board" \
    "the secondmate card and health surface must preserve the hold reason"
  assert_grep '1 fleet health item needs attention; health details are incomplete' "$board" \
    "the attention bar must count classified secondmate holds without guessing omitted types"
  assert_grep '2 additional holds could not be classified' "$board" \
    "fleet health must disclose bounded hold details it cannot classify"
  assert_no_grep 'Nothing blocked or failed.' "$board" \
    "held secondmate work must prevent a fleet-health all-clear"
  pass "secondmate health and activity remain authoritative when bounded"
}

# The active-child count crosses a home boundary and can therefore be absent or
# malformed independently of the child rows it describes. The board must keep
# both count consumers numeric without turning arbitrary prose into a count.
test_secondmate_child_count_shapes_render_safely() {
  local snap board
  snap=$TMP_ROOT/secondmate-child-count-shapes.json
  board=$TMP_ROOT/secondmate-child-count-shapes.html
  snapshot_json '[]' '[{
    "id": "numeric", "current": {"state": "active_child_work"},
    "active_children": [{"id": "numeric-visible"}],
    "decisions_open": [], "holds": [],
    "counts": {"active_children": 4, "decisions_open": 0, "holds": 0},
    "omitted": [{"surface": "active_children", "count": 3}]
  }, {
    "id": "zero", "current": {"state": "no_active_work"},
    "active_children": [], "decisions_open": [], "holds": [],
    "counts": {"active_children": 0, "decisions_open": 0, "holds": 0},
    "omitted": []
  }, {
    "id": "legacy", "current": {"state": "active_child_work"},
    "active_children": [{"id": "legacy-visible"}],
    "decisions_open": [], "holds": [],
    "counts": {"decisions_open": 0, "holds": 0}, "omitted": []
  }, {
    "id": "text-count", "current": {"state": "active_child_work"},
    "active_children": [{"id": "text-visible"}],
    "decisions_open": [], "holds": [],
    "counts": {"active_children": "many", "decisions_open": 0, "holds": 0},
    "omitted": []
  }, {
    "id": "text-count-no-rows", "current": {"state": "active_child_work"},
    "active_children": [], "decisions_open": [], "holds": [],
    "counts": {"active_children": "several", "decisions_open": 0, "holds": 0},
    "omitted": []
  }]' > "$snap"

  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "numeric, zero, missing, and non-numeric child counts must all render"
  assert_grep '<div class="n">6+</div><div class="l">In progress</div>' "$board" \
    "the in-progress tile must show the proven lower bound and disclose malformed counts"
  assert_grep '4 tasks routed and under way' "$board" \
    "a valid numeric count must retain its authoritative card total"
  assert_grep '4 active tasks (1 shown)' "$board" \
    "a valid numeric count must retain its omission semantics"
  assert_grep 'Idle and healthy, awaiting routed work.' "$board" \
    "a valid zero must retain the ready secondmate state"
  assert_grep '<div class="proj-state">1 task routed and under way</div>' "$board" \
    "a missing count must fall back to the complete rows an older producer supplied"
  assert_grep '<div class="proj-state">At least 1 task routed and under way</div>' "$board" \
    "a malformed count with one row must make the card state a lower bound"
  assert_grep 'Active task count unavailable (1 shown)' "$board" \
    "a malformed count must disclose that its visible row is not an authoritative total"
  assert_grep 'Routed work is under way; active task count unavailable.' "$board" \
    "a malformed count with no rows must not relabel active work as zero"
  assert_no_grep 'many' "$board" \
    "arbitrary count text must never be displayed as if it were a number"
  assert_no_grep 'several' "$board" \
    "another arbitrary count string must never leak into a count consumer"
  pass "secondmate child counts stay honest across numeric, zero, missing, and malformed inputs"
}

test_unmeasurable_allowance_is_not_a_zero_gauge() {
  local snap quota board
  snap=$TMP_ROOT/quota-snap.json
  quota=$TMP_ROOT/quota.json
  board=$TMP_ROOT/quota.html
  snapshot_json '[]' '[]' > "$snap"
  cat > "$quota" <<'EOF'
{"providers": [
  {"provider": "claude", "label": "Claude", "windows": [],
   "state": {"status": "auth_required", "error": "Claude sign-in required"}},
  {"provider": "codex", "label": "Codex", "windows": [
    {"id": "weekly", "label": "week", "percentRemaining": 68, "resetsAt": "2026-01-09T21:10:04.000Z"}]}
]}
EOF
  FM_MISSION_CONTROL_QUOTA_JSON="$quota" "$BOARD" --snapshot "$snap" --out "$board" >/dev/null \
    || fail "an allowance reading must render"
  assert_grep '68%' "$board" "a measured allowance window must render as a gauge"
  assert_grep 'Claude sign-in required' "$board" "an unavailable provider must state why"
  # A sign-in gap is not an exhausted allowance, so it must never draw as 0%.
  assert_no_grep '>0%<' "$board" "an unmeasurable provider must not render as a zero gauge"
  pass "an unmeasurable allowance reports its reason instead of an empty gauge"
}

test_usage_errors_refuse() {
  local code snap
  snap=$TMP_ROOT/usage.json
  snapshot_json '[]' '[]' > "$snap"
  "$BOARD" --nonsense >/dev/null 2>&1; code=$?
  expect_code 2 "$code" "an unknown flag"
  "$BOARD" --refresh 0 >/dev/null 2>&1; code=$?
  expect_code 2 "$code" "a zero refresh interval"
  "$BOARD" --snapshot "$TMP_ROOT/does-not-exist.json" >/dev/null 2>&1; code=$?
  expect_code 1 "$code" "an unreadable snapshot file"
  pass "invalid invocations refuse instead of writing a board"
}

test_self_reload_is_wired() {
  local snap board
  snap=$TMP_ROOT/reload.json
  board=$TMP_ROOT/reload.html
  snapshot_json '[]' '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --refresh 30 --out "$board" >/dev/null \
    || fail "the board must render with an explicit refresh interval"
  assert_grep 'http-equiv="refresh" content="30"' "$board" \
    "the board must reload itself so a regenerated file is picked up"
  assert_no_grep 'src="http' "$board" "the board must not depend on a network asset"
  assert_no_grep 'href="http://' "$board" "the board must not load a remote stylesheet"
  pass "the board self-reloads and stays self-contained"
}

# A snapshot carrying one of every row the reply layer has to decide about: a
# main captain decision, a secondmate decision that IS a backlog hold, a
# secondmate decision that is only a task-level open decision, and a PR row.
controls_snapshot() {
  snapshot_json '[{"state": "queued", "id": "d1", "captain_actionable": true,
      "title": "Choose the rollout window", "hold_reason": "Both windows cost money",
      "repo": "alpha"}]' \
    '[{"id": "ios", "registered": true, "provenance": {"selected": "structured-home"},
       "current": {"state": "captain_decision"},
       "decisions_open": [
         {"id": "b7", "key": "b7", "verb": "captain-hold", "summary": "Pick the signing route",
          "reason": "two routes", "source": "backlog"},
         {"id": "t9", "key": "api-shape", "verb": "needs-decision", "summary": "Which API shape",
          "reason": null, "source": "status"}],
       "holds": [], "queued": [], "counts": {}, "omitted": []}]' \
  | jq '.tasks = [{id: "t1", kind: "ship", project: "alpha", model: "claude-opus-5",
        backlog: {title: "Wire the intake form", repo: "alpha"},
        pr: {url: "https://github.com/example/alpha/pull/9"},
        current_state: {state: "working",
          stage: {ordinal: 4, of: 5, label: "Checks running", motion: "live"}}}]'
}

# The reply layer must never appear unless it was asked for, because the same
# file is what gets served read-only.
test_controls_are_absent_unless_asked_for() {
  local snap board
  snap=$TMP_ROOT/nocontrols.json
  board=$TMP_ROOT/nocontrols.html
  controls_snapshot > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "the board must still render without the controls flag"
  assert_no_grep 'class="rc"' "$board" "a board rendered without --controls carries no reply layer"
  assert_no_grep 'FM-BOARD-REQUEST' "$board" "a board rendered without --controls queues nothing"
  assert_no_grep 'data-open=' "$board" "a board rendered without --controls has no control markup"
  assert_grep 'http-equiv="refresh" content="25"' "$board" \
    "a board rendered without --controls keeps its own meta refresh untouched"
  pass "the default board is unchanged by the existence of the reply layer"
}

# The reply layer one row carries: everything from that row's control block up
# to the next one, so an assertion cannot accidentally read a neighbour.
control_block() {  # <board> <home> <id>
  FM_CB_HOME=$2 FM_CB_ID=$3 perl -0777 -ne '
    my $open = "<div class=\"rc\" data-home=\"$ENV{FM_CB_HOME}\" data-id=\"$ENV{FM_CB_ID}\"";
    my $at = index($_, $open);
    exit 1 if $at < 0;
    my $rest = substr($_, $at + length($open));
    my $next = index($rest, "<div class=\"rc\"");
    print $next < 0 ? $rest : substr($rest, 0, $next);
  ' "$1"
}

# Which controls a row gets is the safety-relevant decision: a task-level
# decision has no backlog row behind it, so it has no hold kind to change and
# must not offer to be set aside.
test_controls_match_what_each_row_can_actually_resolve() {
  local snap board block
  snap=$TMP_ROOT/controls.json
  board=$TMP_ROOT/controls.html
  controls_snapshot > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --controls --out "$board" >/dev/null \
    || fail "the board must render with the controls flag"

  # A main captain decision is a backlog hold: answerable and deferrable.
  block=$(control_block "$board" "main" "d1")
  assert_contains "$block" 'data-open="answer"' "a main captain decision must offer an answer"
  assert_contains "$block" 'data-open="defer"' "a main captain decision must offer to be set aside"

  # A secondmate decision that is a backlog hold behaves the same, in its home.
  block=$(control_block "$board" "ios" "b7")
  assert_contains "$block" 'data-open="answer"' "a secondmate backlog decision must offer an answer"
  assert_contains "$block" 'data-open="defer"' "a secondmate backlog decision must offer to be set aside"

  # A task-level open decision has no backlog row, so setting it aside would
  # name nothing. It carries its decision key so two on one task stay distinct.
  block=$(control_block "$board" "ios" "t9")
  assert_contains "$block" 'data-key="api-shape"' \
    "a task-level decision must carry its decision key, not just its task"
  assert_contains "$block" 'data-open="answer"' "a task-level decision must offer an answer"
  case "$block" in
    *'data-open="defer"'*)
      fail "a task-level decision has no backlog hold to change and must not offer to be set aside" ;;
  esac

  block=$(control_block "$board" "main" "t1")
  assert_contains "$block" 'data-open="merge"' "a PR awaiting the captain must offer a merge request"
  assert_contains "$block" 'data-open="reply"' "a PR awaiting the captain must offer a reply"

  assert_grep 'data-intent="ask"' "$board" "the board must offer one composer for a new ask"

  # The item rows are read-only display and carry no control of their own, so the
  # reply layer must be unchanged by their presence: this snapshot renders a full
  # item row on the alpha card, and every control assertion above still holds.
  assert_grep 'aria-label="Stage 4 of 5: Checks running"' "$board" \
    "an item row must still render with the reply layer on"
  assert_grep '>Opus 5</span>' "$board" \
    "an item row must still name its model with the reply layer on"

  # Every control that can hold the refresh has to say so. The composer is
  # always open, so text left in it holds the board with no form to close.
  holds=$(grep -o 'class="rc-hold"' "$board" | wc -l | tr -d ' ')
  opens=$(grep -o 'class="rc-f" data-toggle' "$board" | wc -l | tr -d ' ')
  [ "$holds" = "$((opens + 1))" ] \
    || fail "each toggled control and the always-open composer must say the refresh is held, got $holds notes for $opens forms"
  pass "each row offers only the controls it can actually resolve"
}

# The whole safety model rests on a control being unable to do anything itself.
test_controls_can_only_queue_a_request() {
  local snap board
  snap=$TMP_ROOT/inert.json
  board=$TMP_ROOT/inert.html
  controls_snapshot > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --controls --out "$board" >/dev/null \
    || fail "the controls board must render"

  # No way out of the page other than the Lavish bridge.
  assert_no_grep 'fetch(' "$board" "a control must not call out over the network"
  assert_no_grep 'XMLHttpRequest' "$board" "a control must not call out over the network"
  assert_no_grep 'WebSocket' "$board" "a control must not open a socket"
  assert_no_grep 'method="post"' "$board" "a control must not post anywhere"
  ! grep -Eq '<form[^>]*action=' "$board" || fail "a control must not post anywhere"
  assert_grep 'queuePrompt' "$board" "a control queues its request through the Lavish bridge"
  assert_grep 'FM-BOARD-REQUEST' "$board" "a queued request carries the request marker"

  # Hidden by CSS, revealed only once the bridge is proved present, so a
  # statically served copy of this same file shows no control at all.
  assert_grep '.rc{display:none' "$board" "the reply layer must be hidden by default"
  assert_grep 'body.lavish .rc{display:block' "$board" \
    "the reply layer must be revealed only for a page carrying the Lavish bridge"
  assert_grep 'classList.add("lavish")' "$board" \
    "the reveal must be gated on the bridge being present"
  # An explicit display beats [hidden], so without this a closed control stands
  # open and every form on the board shows at once.
  assert_grep '.rc-f[hidden]{display:none' "$board" \
    "a closed control must stay closed against the layer own display rule"

  # With controls the reload is managed so it can hold while a control is open.
  # The meta refresh must survive ONLY for a page that runs no script, so every
  # occurrence of it has to be the one inside noscript.
  local all inert
  all=$(grep -o '<meta http-equiv="refresh"' "$board" | wc -l | tr -d ' ')
  inert=$(grep -o '<noscript><meta http-equiv="refresh"' "$board" | wc -l | tr -d ' ')
  [ "$inert" = 1 ] \
    || fail "the meta refresh must move into noscript once the reload is managed, got $inert"
  [ "$all" = "$inert" ] \
    || fail "a managed reload must not race a live meta refresh ($all refresh tags, $inert in noscript)"
  pass "a control can only queue a request; it reaches nothing else"
}

test_control_targets_are_escaped() {
  local snap board
  snap=$TMP_ROOT/hostile-controls.json
  board=$TMP_ROOT/hostile-controls.html
  snapshot_json '[{"state": "queued", "id": "d1", "captain_actionable": true,
      "title": "Ship \"><script>alert(1)</script> now", "hold_reason": "x", "repo": "alpha"}]' \
    '[]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --controls --out "$board" >/dev/null \
    || fail "hostile prose must still render with controls"
  assert_no_grep '<script>alert(1)</script>' "$board" \
    "hostile prose must not reach the page as markup through a control attribute"
  assert_grep 'data-what="Ship &quot;&gt;' "$board" \
    "hostile prose must be escaped inside the control attribute that carries it"
  pass "fleet prose stays escaped where a control carries it"
}

test_in_progress_items_are_listed_with_stage_and_model
test_stalled_items_do_not_read_as_progress
test_setup_uses_neutral_tone
test_ready_and_done_use_distinct_tones
test_model_ids_are_shown_as_readable_names
test_unrecorded_item_facts_are_disclosed_rather_than_blanked
test_out_of_range_stage_values_are_bounded_before_they_are_drawn
test_long_item_list_keeps_every_item_in_an_expandable_shelf
test_upstream_omissions_stay_distinct_from_shelved_items
test_renders_live_fixture_home
test_project_last_change_comes_from_the_clone
test_yesterday_uses_local_calendar_arithmetic
test_missing_change_time_degrades_to_a_dash
test_render_writes_nothing_into_the_project_clones
test_absent_sources_render_empty_sections
test_hostile_text_is_escaped
test_missing_backlog_is_disclosed_as_unavailable
test_deferred_decision_leaves_the_primary_view
test_deferred_shelf_reaches_a_secondmate_and_discloses_its_bound
test_navigation_tabs_group_the_board
test_fragment_selected_tab_survives_reload
test_attention_bar_reaches_health_across_tabs
test_unreadable_backlog_does_not_leave_projects_looking_calm
test_blocked_work_is_raised_above_the_board
test_duplicate_main_health_sources_are_normalized
test_secondmate_captain_decision_is_surfaced
test_secondmate_mixed_decision_and_child_hold_stay_distinct
test_secondmate_change_time_comes_from_its_own_reporting
test_bounded_secondmate_decisions_are_disclosed
test_unreadable_secondmate_sources_are_disclosed
test_path_form_repo_folds_into_the_project_rollup
test_live_work_outside_the_registry_stays_visible
test_unregistered_live_project_uses_clone_change_time
test_secondmate_health_and_activity_use_authoritative_counts
test_secondmate_child_count_shapes_render_safely
test_unmeasurable_allowance_is_not_a_zero_gauge
test_usage_errors_refuse
test_self_reload_is_wired
test_controls_are_absent_unless_asked_for
test_controls_match_what_each_row_can_actually_resolve
test_controls_can_only_queue_a_request
test_control_targets_are_escaped
