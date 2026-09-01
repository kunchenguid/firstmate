#!/usr/bin/env bash
# Behavior tests for the shipped workstream board renderer
# (.agents/skills/workstreams/assets/board-template.html), exercised through a
# real `fm-workstream-board.sh build` and then executed under the minimal DOM
# shim in tests/assets/workstream-render-harness.mjs. The assertions are on what
# the page renders - stat tiles, workstream cards, the dependency graph, the
# waiting rail, the divergence callout - never on the template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-workstream-board.sh"
HARNESS="$ROOT/tests/assets/workstream-render-harness.mjs"
TEMPLATE="$ROOT/.agents/skills/workstreams/assets/board-template.html"
TMP_ROOT=$(fm_test_tmproot fm-workstream-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

# Build the board from a full payload document and return what the renderer produced.
render() {  # <home> <payload-json>
  local home=$1 payload=$2 data="$1/payload.json"
  printf '%s\n' "$payload" > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/workstreams.html" \
    || fail "the built board could not be rendered"
}

base_payload() {
  cat <<'EOF'
{
  "schema": "fm-workstream-board.v1",
  "home": "render-home",
  "generated": "2026-09-01T00:00Z",
  "workstreams": [
    { "id": "quote-flow", "name": "Quote Flow",
      "outcome": "Never silently drop a part.",
      "tasks": [
        { "id": "quote-flow-fixes", "title": "G9 loud failure", "state": "held",
          "doing": "fix round 16", "agent": "claude · working", "agent_tone": "working" },
        { "id": "spend-call", "title": "Eval spend decision", "state": "decision" },
        { "id": "g6-define", "title": "Define G6", "state": "done" },
        { "id": "build-g6", "title": "Build G6", "state": "queued" },
        { "id": "island", "title": "No edges touch this row", "state": "queued" }
      ],
      "more_tasks": 3 }
  ],
  "edges": [
    { "from": "g6-define", "to": "build-g6" },
    { "from": "elsewhere", "to": "build-g6" }
  ],
  "waiting": [
    { "key": "spend-call", "title": "Eval baseline spend",
      "options": [
        { "value": "full", "label": "Full baseline" },
        { "value": "returns-only", "label": "Returns only" }
      ],
      "recommend_value": "returns-only", "allow_freeform": true, "close": "release" }
  ],
  "agents": [ { "id": "quote-flow-fixes", "tone": "working", "doing": "fix round 16" } ],
  "divergence": [ { "id": "analytics-triage", "note": "backlog queued, live PR open" } ]
}
EOF
}

test_the_full_board_renders_every_section() {
  local home out
  home=$(make_home full)
  out=$(render "$home" "$(base_payload)")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    ([.stats[] | {key:.label, value:.n}] | from_entries) as $s
    | $s["workstreams"] == 1 and $s["tasks on the board"] == 5
      and $s["agents live"] == 1 and $s["waiting on you"] == 1
      and $s["board ≠ reality"] == 1
  ' >/dev/null || fail "the stat tiles do not carry the board tallies: $out"
  printf '%s' "$out" | jq -e '
    (.stats[] | select(.label == "waiting on you") | .attn) == true
      and (.stats[] | select(.label == "board ≠ reality") | .warn) == true
      and ([.stats[].href] | index("#wb-waiting") != null)
  ' >/dev/null || fail "the attention tiles do not read as anchors: $out"
  printf '%s' "$out" | jq -e '
    (.streams | length) == 1 and (.streams[0].id == "ws-quote-flow")
      and (.streams[0].title == "Quote Flow")
      and (.streams[0].badges | any(test("1 needs your decision")))
      and (.streams[0].badges | any(test("1 held")))
  ' >/dev/null || fail "the workstream card head is not rendered: $out"
  printf '%s' "$out" | jq -e '
    (.streams[0].rows | length) == 5
      and (.streams[0].rows[] | select(.id == "quote-flow-fixes") | .held and .expandable and (.agent | test("working")))
      and (.streams[0].rows[] | select(.id == "spend-call") | .decision)
      and (.streams[0].more == ["+3 more - ask firstmate for the full list"])
  ' >/dev/null || fail "the task rows do not render their states: $out"
  printf '%s' "$out" | jq -e '
    (.waiting | length) == 1 and .waiting[0].question == "spend-call"
      and (.waiting[0].options == ["full", "returns-only"]) and .waiting[0].freeform
  ' >/dev/null || fail "the waiting rail form is not rendered: $out"
  printf '%s' "$out" | jq -e '
    .divergence.hidden == false
      and (.divergence.rows == [{"id":"analytics-triage","note":"backlog queued, live PR open"}])
  ' >/dev/null || fail "the board-vs-reality callout is not rendered: $out"
  pass "the full board renders stats, cards, rows, forms, and the callout"
}

test_the_dependency_graph_draws_only_edge_touched_local_nodes() {
  local home out
  home=$(make_home graph)
  out=$(render "$home" "$(base_payload)")
  # One local edge (g6-define -> build-g6); the edge to a task outside the
  # workstream is dropped, and the untouched rows stay out of the drawing.
  printf '%s' "$out" | jq -e '
    .streams[0].graph == {"nodes": 2, "edges": 1}
  ' >/dev/null || fail "the dependency graph did not draw the local edge set: $out"
  pass "the dependency graph draws exactly the edge-touched local nodes"
}

test_a_board_without_edges_or_divergence_stays_quiet() {
  local home out payload
  home=$(make_home quiet)
  payload=$(base_payload | jq '.edges = [] | .divergence = [] | .waiting = [] | .agents = []')
  out=$(render "$home" "$payload")
  printf '%s' "$out" | jq -e '
    (.streams[0].graph == null)
      and .divergence.hidden == true
      and ([.stats[].label] | index("board ≠ reality") == null)
      and (.waiting | length) == 0
  ' >/dev/null || fail "an edge-free, divergence-free board still drew those sections: $out"
  pass "a board without edges, divergence, or waiting items stays quiet"
}

test_unreadable_data_fails_closed() {
  local home board out
  home=$(make_home failclosed)
  board="$home/.lavish/workstreams.html"
  mkdir -p "$home/.lavish"
  # Corrupt the data block directly: the builder would refuse this payload, so
  # the template's own fail-closed path is exercised without it.
  perl -pe 's/^__FM_WORKSTREAM_BOARD_DATA__$/{"schema": "fm-workstream-board.v1", "broken": /' \
    "$TEMPLATE" > "$board"
  out=$(node "$HARNESS" "$board") || fail "the corrupted board crashed the harness"
  printf '%s' "$out" | jq -e '
    (.error | test("could not load")) and (.stats | length) == 0
  ' >/dev/null || fail "unreadable board data did not fail closed: $out"
  pass "unreadable board data renders the fail-closed notice, not an empty fleet"
}

test_the_full_board_renders_every_section
test_the_dependency_graph_draws_only_edge_touched_local_nodes
test_a_board_without_edges_or_divergence_stays_quiet
test_unreadable_data_fails_closed
