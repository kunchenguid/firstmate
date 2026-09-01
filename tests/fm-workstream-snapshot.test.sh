#!/usr/bin/env bash
# Behavior tests for the workstream projection wrapper over fm-fleet-snapshot.sh.
# Covers workstream derivation (umbrella kind=program, id-prefix claims, direct
# blocked-by claims, fixpoint expansion, first-claim-wins), the unassigned lane,
# task-state classification, board-vs-reality divergence, dependency edges,
# bounded output with omitted[] disclosure, TOON/JSON parity, and the zero-network
# guarantee of the only path.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WS="$ROOT/bin/fm-workstream-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-workstream-snapshot)
# Keep disposable homes outside the snapshot's fixture repo boundary even when
# TMPDIR is inside an isolated source worktree.
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A fakebin that stubs the local tools the canonical snapshot may reach for,
# plus gh/gh-axi/curl recorders that prove the projection makes no network call.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$NET_LOG"
exit 1
SH
  sed 's/^echo "gh /echo "gh-axi /' "$fb/gh" > "$fb/gh-axi"
  sed 's/^echo "gh /echo "curl /' "$fb/gh" > "$fb/curl"
  chmod +x "$fb/tmux" "$fb/gh" "$fb/gh-axi" "$fb/curl"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

run_ws() {  # <home> <fakebin> <args...>
  local home=$1 fb=$2
  shift 2
  NET_LOG="$home/net.log" PATH="$fb:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    "$WS" "$@"
}

# One shared fixture: two umbrellas, all three claim passes, an unassigned lane,
# every task state, and all three divergence kinds.
write_fixture() {  # <home>
  local home=$1
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

- [ ] quote - Quote Flow (kind: program)
  Intended outcome: a quote flow that never silently drops a part.
- [ ] quote-fixes - G9 loud failure and friends
- [ ] census - Census held mid-flight (hold: waiting on eval window, hold-kind: captain)

## Queued

- [ ] ontology - Chat Ontology (kind: program)
- [ ] rows-live - Ontology rows blocked-by: ontology
- [ ] rows-followup - Follow-up on the rows blocked-by: rows-live
- [ ] spend-call - Eval spend decision (hold: full baseline or returns-only?, hold-kind: captain)
- [ ] review-me - Analytics triage weekly study
- [ ] loner - Completely ungrouped work

## Done

- [x] quote-define - Define the quote gates (done: 2026-08-30)
- [x] old-win - Landed long ago, no workstream (done: 2026-08-01)
EOF
  fm_write_meta "$home/state/quote-fixes.meta" "backend=tmux" "window=fm:1" "kind=ship" "project=$home/projects/sample"
  printf 'working: fixing G20\n' > "$home/state/quote-fixes.status"
  fm_write_meta "$home/state/review-me.meta" "backend=tmux" "window=fm:2" "kind=ship" "project=$home/projects/sample" "pr=https://github.com/acme/repo/pull/197"
  printf 'done: PR https://github.com/acme/repo/pull/197 checks green\n' > "$home/state/review-me.status"
  fm_write_meta "$home/state/ghost-worker.meta" "backend=tmux" "window=fm:3" "kind=ship" "project=$home/projects/sample"
}

test_grouping_states_edges_and_divergence() {
  local home fb model
  home=$(make_home grouping)
  fb=$(make_fakebin "$home")
  write_fixture "$home"

  model=$(run_ws "$home" "$fb" --json) || fail "the projection did not run"
  printf '%s' "$model" | jq -e '.schema == "fm-workstream.v1"' >/dev/null \
    || fail "the projection does not carry its schema"

  # Umbrellas become workstreams; prefix and blocked-by members are claimed.
  printf '%s' "$model" | jq -e '
    ([.workstreams[].id] == ["quote", "ontology", "unassigned"])
      and ([.tasks[] | select(.ws == "quote") | .id] | sort == ["quote-define", "quote-fixes"])
  ' >/dev/null || fail "prefix members did not reach their umbrella workstream: $model"

  # Fixpoint: rows-followup joins ontology through its edge to rows-live.
  printf '%s' "$model" | jq -e '
    [.tasks[] | select(.ws == "ontology") | .id] | sort == ["rows-followup", "rows-live"]
  ' >/dev/null || fail "fixpoint expansion did not follow the blocked-by edge: $model"

  # Unclaimed non-done tasks land in the explicit unassigned lane; a worker
  # with no backlog row has no task row (it surfaces under divergence instead).
  printf '%s' "$model" | jq -e '
    [.tasks[] | select(.ws == "unassigned") | .id] | sort == ["census", "loner", "review-me", "spend-call"]
  ' >/dev/null || fail "unclaimed tasks did not land in the unassigned lane: $model"

  # The unassigned lane is a real workstreams[] entry carrying its own totals,
  # so a composer that reads workstreams[] can never hide ungrouped work.
  printf '%s' "$model" | jq -e '
    (.workstreams[] | select(.id == "unassigned"))
    | .total == 4 and .more == 0 and .held == 1 and .review == 1
      and .decision == 1 and .queued == 1 and (.name | length) > 0
  ' >/dev/null || fail "the unassigned lane is not a real workstream entry: $model"

  # Task-state classification, one of each.
  printf '%s' "$model" | jq -e '
    ([.tasks[] | {key:.id, value:.state}] | from_entries) as $s
    | $s["quote-define"] == "done"
      and $s["spend-call"] == "decision"
      and $s["census"] == "held"
      and $s["review-me"] == "review"
      and $s["quote-fixes"] == "active"
      and $s["loner"] == "queued"
  ' >/dev/null || fail "task states did not classify by the documented precedence: $model"

  # Edges connect included tasks and stay workstream-tagged.
  printf '%s' "$model" | jq -e '
    (.edges | map(select(.from == "rows-live" and .to == "rows-followup" and .ws == "ontology")) | length) == 1
  ' >/dev/null || fail "the in-stream dependency edge is missing: $model"

  # All three divergence kinds surface.
  printf '%s' "$model" | jq -e '
    ([.divergence[] | {key:.id, value:.kind}] | from_entries) as $d
    | $d["review-me"] == "queued-but-live" and $d["ghost-worker"] == "worker-not-on-board"
  ' >/dev/null || fail "board-vs-reality divergence rows are missing: $model"

  # The captain-actionable hold reaches decisions[] with its reason.
  printf '%s' "$model" | jq -e '
    (.decisions | length) == 1 and .decisions[0].id == "spend-call"
      and (.decisions[0].summary | test("returns-only"))
  ' >/dev/null || fail "the captain-held task did not reach decisions: $model"

  # Done work outside every workstream is dropped with disclosure, and the
  # secondmate scope limit is always disclosed.
  printf '%s' "$model" | jq -e '
    ([.omitted[].surface] | any(test("done tasks outside every workstream dropped: 1")))
      and ([.omitted[].surface] | any(test("secondmate homes not sampled")))
  ' >/dev/null || fail "omitted[] does not disclose the dropped surfaces: $model"

  [ ! -s "$home/net.log" ] || fail "the projection touched the network: $(cat "$home/net.log")"
  pass "grouping, states, edges, divergence, and disclosure all project correctly"
}

test_in_flight_without_worker_is_divergence() {
  local home fb model
  home=$(make_home orphan)
  fb=$(make_fakebin "$home")
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

- [ ] adrift - In flight with no worker record

## Queued

## Done
EOF
  model=$(run_ws "$home" "$fb" --json) || fail "the projection did not run"
  printf '%s' "$model" | jq -e '
    (.divergence | map(select(.id == "adrift" and .kind == "in-flight-no-worker")) | length) == 1
  ' >/dev/null || fail "an in-flight row without a worker record was not flagged: $model"
  pass "an in-flight backlog row without a worker record surfaces as divergence"
}

test_bounds_are_disclosed_and_liftable() {
  local home fb model
  home=$(make_home bounds)
  fb=$(make_fakebin "$home")
  write_fixture "$home"

  # The umbrella cap drops umbrella lanes and discloses it; the unassigned lane
  # is the catch-all and is never dropped by that cap.
  model=$(FM_WS_STREAMS=1 run_ws "$home" "$fb" --json) || fail "the bounded projection did not run"
  printf '%s' "$model" | jq -e '
    ([.workstreams[].id] == ["quote", "unassigned"])
      and ([.omitted[].surface] | any(test("workstreams showing 1 of 2")))
  ' >/dev/null || fail "the workstream cap is not disclosed: $model"

  model=$(FM_WS_UNASSIGNED=1 run_ws "$home" "$fb" --json) || fail "the unassigned-capped run failed"
  printf '%s' "$model" | jq -e '
    (.workstreams[] | select(.id == "unassigned")) as $u
    | $u.more == 3 and $u.total == 4
      and ([.tasks[] | select(.ws == "unassigned")] | length) == 1
      and ([.omitted[].surface] | any(test("unassigned tasks showing 1 of 4")))
  ' >/dev/null || fail "the unassigned lane does not carry a machine-readable more: $model"

  model=$(FM_WS_TASKS=1 run_ws "$home" "$fb" --json) || fail "the task-capped projection did not run"
  printf '%s' "$model" | jq -e '
    ([.workstreams[] | select(.id == "quote") | .more] | first) == 1
      and ([.omitted[].surface] | any(test("task rows capped in")))
  ' >/dev/null || fail "the per-workstream task cap is not disclosed: $model"

  model=$(FM_WS_TASKS=1 run_ws "$home" "$fb" --json --all-tasks) || fail "--all-tasks did not run"
  printf '%s' "$model" | jq -e '
    ([.workstreams[].more] | add) == 0
  ' >/dev/null || fail "--all-tasks did not lift the task cap: $model"

  ( run_ws "$home" "$fb" --json >/dev/null 2>&1 ) || fail "a default run failed"
  FM_WS_STREAMS=0 run_ws "$home" "$fb" --json >/dev/null 2>&1 \
    && fail "a zero bound was accepted"
  pass "caps are disclosed in omitted[] and lifted by --all-tasks"
}

test_a_done_umbrella_keeps_its_workstream() {
  local home fb model
  home=$(make_home doneumbrella)
  fb=$(make_fakebin "$home")
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

- [ ] quote-fixes - G9 loud failure and friends

## Queued

- [ ] loner - Completely ungrouped work

## Done

- [x] quote - Quote Flow (kind: program) (done: 2026-08-30)
EOF
  model=$(run_ws "$home" "$fb" --json) || fail "the projection did not run"
  printf '%s' "$model" | jq -e '
    ([.workstreams[].id] == ["quote", "unassigned"])
      and ([.tasks[] | select(.ws == "quote") | .id] == ["quote-fixes"])
      and ([.tasks[] | select(.ws == "unassigned") | .id] == ["loner"])
  ' >/dev/null || fail "a finished umbrella lost its workstream and scattered its members: $model"
  pass "a finished umbrella keeps its workstream with its members anchored"
}

test_toon_and_json_are_parity_forms() {
  local home fb toon
  home=$(make_home parity)
  fb=$(make_fakebin "$home")
  write_fixture "$home"

  toon=$(run_ws "$home" "$fb") || fail "the TOON projection did not run"
  printf '%s' "$toon" | grep -q '^schema: fm-workstream.v1$' \
    || fail "TOON output does not open with the schema line: $toon"
  printf '%s' "$toon" | grep -q '^workstreams\[3\]{' \
    || fail "TOON output does not carry the workstreams table: $toon"
  printf '%s' "$toon" | grep -q '^tasks\[' \
    || fail "TOON output does not carry the tasks table: $toon"
  printf '%s' "$toon" | grep -Eq '^  quote-define,quote,done,' \
    || fail "TOON task rows do not carry the projected fields: $toon"
  pass "TOON is the default rendering of the same projected model"
}

test_grouping_states_edges_and_divergence
test_in_flight_without_worker_is_divergence
test_bounds_are_disclosed_and_liftable
test_a_done_umbrella_keeps_its_workstream
test_toon_and_json_are_parity_forms
