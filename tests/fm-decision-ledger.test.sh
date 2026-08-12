#!/usr/bin/env bash
# Behavior tests for the decision-coverage ledger.
# Reproduces the reporting failure it exists to prevent - raw decision EVENTS being
# reported as open captain decisions - and pins the two mechanical guarantees:
# the open-decision figure is always the length of an enumerated key list, and
# every distinct live key carries a disposition with no hidden remainder.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER="$ROOT/bin/fm-decision-ledger.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-ledger)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

run_ledger() {  # <home> [args...]
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_LEDGER_NOW=2026-08-06T12:00:00Z "$LEDGER" "$@"
}

run_bearings() {  # <home> [script-override]
  local home=$1 script=${2:-$BEARINGS}
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-08-06T12:00:00Z \
    "$script" --json
}

lane_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-ship}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

# The count the authoritative fold itself returns, so the ledger is pinned to
# fm-classify-lib.sh rather than to a number typed into this test.
authoritative_open_count() {  # <home>
  bash -c '. "$1"; scan_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$1/state" \
    | grep -c . || true
}

# One home carrying every disposition at once, with far more raw decision events
# than open keys - the exact shape that produced "183 open captain decisions" from
# a fold that returned six.
build_coverage_home() {  # <name>
  local home hold
  home=$(make_home "$1")

  # Noise lane: many opening events, all of them since closed. Contributes heavily
  # to the raw counts and nothing at all to the open set.
  lane_meta "$home" lane-noise
  {
    for k in alpha beta gamma delta; do
      printf 'needs-decision [key=%s]: choose something for %s\n' "$k" "$k"
      printf 'blocked [key=%s]: waiting on %s\n' "$k" "$k"
      printf 'resolved [key=%s]: settled %s\n' "$k" "$k"
    done
    printf 'working: back under way\n'
  } > "$home/state/lane-noise.status"

  # A live lane whose decision is durably held for the captain.
  lane_meta "$home" lane-held
  printf 'needs-decision [key=route]: choose north or south\nworking: continuing\n' \
    > "$home/state/lane-held.status"
  run_decisions "$home" hold lane-held route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "could not register the held-lane hold"

  # A lane whose decision was answered and then archived out of the live backlog.
  lane_meta "$home" lane-archived scout
  mkdir -p "$home/data/lane-archived"
  printf '# Archived answer\n' > "$home/data/lane-archived/report.md"
  printf 'needs-decision [key=redirect]: fix now or accept as documented\nworking: continuing\n' \
    > "$home/state/lane-archived.status"
  hold=$(run_decisions "$home" hold lane-archived redirect \
    --title "Fix the sample redirect now or defer it" \
    --reason "captain call on a public sample route" --repo sample) \
    || fail "could not register the archived-lane hold"
  tasks_in "$home" add sample-redirect-fix "Apply the sample redirect fix" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the routed dependent"
  printf 'Fix it now.\n' > "$home/redirect-decision.txt"
  run_decisions "$home" resolve lane-archived redirect \
    --decision-file "$home/redirect-decision.txt" --routed-to sample-redirect-fix >/dev/null \
    || fail "could not answer the archived-lane decision"
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not archive the answer"

  # A finished lane that left an open key behind, and a live lane still owed an answer.
  lane_meta "$home" lane-terminal
  printf 'needs-decision [key=scope]: pick the narrow or wide scope\ndone: shipped anyway\n' \
    > "$home/state/lane-terminal.status"
  lane_meta "$home" lane-live
  printf 'blocked [key=creds]: need a sample credential\nworking: still going\n' \
    > "$home/state/lane-live.status"

  printf '%s\n' "$home"
}

# The fold decides what a decision transition IS, and that rule grows: a reserved
# key namespace only transitions when the note speaks its own vocabulary. A ledger
# that counted lines by its own reading of the key grammar would report a decision
# opened, and then silently superseded, that never existed. Both directions are
# pinned here so the ledger cannot pass by ignoring reserved keys wholesale.
test_only_fold_recognized_lines_become_figures() {
  local home before after opened folded
  home=$(build_coverage_home reserved-keys)
  before=$(run_ledger "$home") || fail "ledger failed on the coverage home"

  printf 'blocked [key=pending-reply-42]: waiting on something unrelated\n' \
    >> "$home/state/lane-live.status"
  folded=$(authoritative_open_count "$home")
  [ "$folded" = "$(printf '%s' "$before" | jq -r '.open_decision_keys')" ] \
    || fail "the fixture line was supposed to be invisible to the authoritative fold"
  after=$(run_ledger "$home") || fail "ledger failed after the ignored line"
  printf '%s' "$after" | jq -e --argjson b "$before" '
    .raw_decision_events == $b.raw_decision_events
    and .keys_opened_distinct == $b.keys_opened_distinct
    and .keys_superseded == $b.keys_superseded
    and .open_decision_keys == $b.open_decision_keys
  ' >/dev/null || fail "a line the fold ignores still moved a ledger figure: $after"

  printf 'blocked [key=pending-reply-42]: pending-reply-42: waiting on the mate\n' \
    >> "$home/state/lane-live.status"
  opened=$(run_ledger "$home") || fail "ledger failed after the recognized line"
  printf '%s' "$opened" | jq -e --argjson b "$before" '
    .raw_decision_events.blocked == ($b.raw_decision_events.blocked + 1)
    and .keys_opened_distinct == ($b.keys_opened_distinct + 1)
    and .open_decision_keys == ($b.open_decision_keys + 1)
    and (.open_decisions | any(.key == "pending-reply-42" and .disposition != ""))
  ' >/dev/null || fail "a line the fold does act on was not counted: $opened"
  pass "only the lines the authoritative fold acts on become ledger figures"
}

test_raw_events_never_become_the_open_decision_count() {
  local home json open_keys rows raw authoritative
  home=$(build_coverage_home raw-vs-folded)
  json=$(run_ledger "$home") || fail "ledger failed on the coverage home"

  authoritative=$(authoritative_open_count "$home")
  open_keys=$(printf '%s' "$json" | jq '.open_decision_keys')
  rows=$(printf '%s' "$json" | jq '.open_decisions | length')
  raw=$(printf '%s' "$json" | jq '.raw_decision_events.opening_total')

  [ "$open_keys" = "$authoritative" ] \
    || fail "the ledger open count $open_keys left the authoritative fold at $authoritative"
  [ "$open_keys" = "$rows" ] \
    || fail "the open count $open_keys is not backed by $rows enumerated key rows"
  [ "$raw" -gt "$open_keys" ] \
    || fail "the fixture must carry more raw events ($raw) than open keys ($open_keys)"

  # The raw figures exist, but only under raw_decision_events, and no field outside
  # that object carries their value as if it were a decision count.
  printf '%s' "$json" | jq -e '
    (.raw_decision_events.opening_total == (.raw_decision_events.needs_decision + .raw_decision_events.blocked))
    and (.raw_decision_events.closing_total == (.raw_decision_events.resolved + .raw_decision_events.captain_held))
    and (.open_decision_keys != .raw_decision_events.opening_total)
    and (.keys_opened_distinct <= .raw_decision_events.opening_total)
    and (.keys_superseded == (.keys_opened_distinct - .open_decision_keys))
    and (.definitions.raw_decision_events | test("not open decisions"))
  ' >/dev/null || fail "raw event figures were not kept distinct from the open count: $json"
  pass "raw decision events stay distinct and can never stand in for the open-key count"
}

test_every_live_key_carries_a_disposition() {
  local home json expected
  home=$(build_coverage_home dispositions)
  json=$(run_ledger "$home") || fail "ledger failed on the coverage home"

  printf '%s' "$json" | jq -e '
    (.open_decisions | length) == 4
    and (.open_decisions | all(.disposition != null and .disposition != ""))
    and (.open_decisions | all(.task != "" and .key != ""))
    and (.complete == true)
    and (.keys_stale == 1)
    and (.status_open_decision_keys ==
         ([.open_decisions[] | select(.current_sources | index("folded-status-key"))] | length))
    and (.captain_holds_active ==
         ([.open_decisions[] | select(.current_sources | index("captain-hold"))] | length))
    and (.keys_stale ==
         ([.open_decisions[] | select((.current_sources | index("folded-status-key"))
           and .disposition == "orphaned-terminal-lane")] | length))
  ' >/dev/null || fail "live keys were not fully accounted for: $json"

  expected='["awaiting-answer","captain-hold-active","captain-hold-archived","orphaned-terminal-lane"]'
  printf '%s' "$json" | jq -e --argjson want "$expected" '
    ([.open_decisions[].disposition] | sort) == $want
  ' >/dev/null || fail "the four constructed dispositions were not all produced: $json"

  printf '%s' "$json" | jq -e '
    (.open_decisions | any(.task == "lane-held" and .disposition == "captain-hold-active"))
    and (.open_decisions | any(.task == "lane-archived" and .disposition == "captain-hold-archived"))
    and (.open_decisions | any(.task == "lane-terminal" and .disposition == "orphaned-terminal-lane"))
    and (.open_decisions | any(.task == "lane-live" and .disposition == "awaiting-answer"))
    and (.open_decisions | any(.task == "lane-noise") | not)
  ' >/dev/null || fail "dispositions were not attributed to the right lanes: $json"
  pass "every distinct live key carries its own disposition and closed keys stay out"
}

test_active_hold_transferred_out_of_status_fold_stays_enumerated() {
  local home json hold
  home=$(make_home transferred-hold)
  lane_meta "$home" lane-held
  printf 'needs-decision [key=route]: choose north or south\nworking: continuing\n' \
    > "$home/state/lane-held.status"
  hold=$(run_decisions "$home" hold lane-held route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register the transferable captain hold"
  [ "$hold" = "lane-held-decision-route" ] || fail "the transferable hold identity was not deterministic"
  run_decisions "$home" complete lane-held route >/dev/null \
    || fail "could not transfer the held status key to its captain hold"
  json=$(run_ledger "$home") || fail "ledger failed after transferring a key to its captain hold"

  printf '%s' "$json" | jq -e '
    .status_open_decision_keys == 0
    and .captain_holds_active == 1
    and .open_decision_keys == 1
    and (.open_decisions | length) == 1
    and (.open_decisions | any(
      .task == "lane-held" and .key == "route"
      and .disposition == "captain-hold-active"
      and (.origins | sort) == ["captain-hold", "folded-status-key"]
      and .current_sources == ["captain-hold"]
    ))
  ' >/dev/null || fail "a transferred active captain hold was omitted or lost its status-key lineage: $json"
  pass "an active captain hold remains an origin-labelled ledger row after status closure"
}

test_active_hold_without_status_key_stays_enumerated() {
  local home json hold
  home=$(make_home hold-without-status)
  lane_meta "$home" backlog-only
  printf 'working: hold created before a status decision was recorded\n' > "$home/state/backlog-only.status"
  hold=$(run_decisions "$home" hold backlog-only route \
    --title "Choose the backlog-only route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register a backlog-only captain hold"
  [ "$hold" = "backlog-only-decision-route" ] || fail "the backlog-only hold identity was not deterministic"
  json=$(run_ledger "$home") || fail "ledger rejected an active captain hold without a status key"

  printf '%s' "$json" | jq -e '
    .keys_opened_distinct == 0
    and .status_open_decision_keys == 0
    and .captain_holds_active == 1
    and .open_decision_keys == 1
    and (.open_decisions | length) == 1
    and (.open_decisions[0] | .task == "backlog-only" and .key == "route"
      and .disposition == "captain-hold-active" and .origins == ["captain-hold"]
      and .current_sources == ["captain-hold"])
  ' >/dev/null || fail "a backlog-only active captain hold was not separately enumerated: $json"
  pass "an active captain hold without a status key remains an origin-labelled ledger row"
}

test_unclassifiable_state_is_disclosed_not_hidden() {
  local home json bjson
  home=$(build_coverage_home undetermined)
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  json=$(run_ledger "$home") || fail "ledger refused instead of disclosing an unclassifiable state"
  printf '%s' "$json" | jq -e '
    .complete == false
    and (.open_decisions | length) == .open_decision_keys
    and ([.open_decisions[] | select(.disposition == "undetermined")] | length) == 3
    and (.open_decisions | all(
      .disposition == "undetermined" or .disposition == "captain-hold-active"
    ))
    and (.open_decisions | all(
      if .disposition == "undetermined" then .detail != "" else .detail == "" end
    ))
    and (.open_decisions | any(.task == "lane-held" and .disposition == "captain-hold-active"))
  ' >/dev/null || fail "an unclassifiable hold state was not disclosed per key: $json"

  bjson=$(run_bearings "$home") || fail "bearings failed with an incomplete ledger"
  printf '%s' "$bjson" | jq -e '
    (.decision_keys | length) == 4
    and (.omitted | any(.surface | test("could not be classified")))
  ' >/dev/null || fail "bearings hid the unclassified keys instead of disclosing them: $bjson"
  pass "an unclassifiable hold state is disclosed per key and never silently dropped"
}

test_bearings_publishes_the_ledger_and_refuses_an_unbacked_count() {
  local home json shadow
  home=$(build_coverage_home bearings-surface)
  json=$(run_bearings "$home") || fail "bearings failed on the coverage home"
  printf '%s' "$json" | jq -e '
    (.decision_ledger | any(.figure == "open_decision_keys" and .count == 4))
    and (.decision_ledger | any(.figure == "raw_opening_events" and .count > 4))
    and (.decision_ledger | all(.means != null and .means != ""))
    and (.decision_keys | length) == 4
    and (.decision_keys | all(.disposition != ""))
  ' >/dev/null || fail "bearings did not publish the coverage ledger: $json"

  # An open-decision count with no rows behind it must not reach a reader, however
  # it is produced. Shadow the ledger with one that claims the reporting error.
  shadow="$home/shadow"
  cp -R "$ROOT/bin" "$shadow"
  cat > "$shadow/fm-decision-ledger.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"schema":"fm-decision-ledger.v1","complete":true,
 "raw_decision_events":{"needs_decision":100,"blocked":83,"opening_total":183,"resolved":0,"captain_held":0,"closing_total":0},
 "keys_opened_distinct":183,"keys_superseded":0,"keys_stale":0,
 "open_decision_keys":183,"open_decisions":[],
 "definitions":{"raw_decision_events":"x","keys_opened_distinct":"x","keys_superseded":"x","keys_stale":"x","open_decision_keys":"x","open_decisions":"x","complete":"x"}}
JSON
EOF
  chmod +x "$shadow/fm-decision-ledger.sh"
  if run_bearings "$home" "$shadow/fm-bearings-snapshot.sh" > "$home/unbacked.out" 2> "$home/unbacked.err"; then
    fail "bearings published an open-decision count with no key rows behind it: $(cat "$home/unbacked.out")"
  fi
  assert_no_grep "183" "$home/unbacked.out" "an unbacked open-decision count reached the output"
  pass "bearings publishes the ledger and refuses a count that no enumerated key backs"
}

test_only_fold_recognized_lines_become_figures
test_raw_events_never_become_the_open_decision_count
test_every_live_key_carries_a_disposition
test_active_hold_transferred_out_of_status_fold_stays_enumerated
test_active_hold_without_status_key_stays_enumerated
test_unclassifiable_state_is_disclosed_not_hidden
test_bearings_publishes_the_ledger_and_refuses_an_unbacked_count
