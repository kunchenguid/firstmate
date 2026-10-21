#!/usr/bin/env bash
# Behavioral coverage for the structured ask a captain-held decision carries:
# the hold intake that stores it, the field rule that refuses a malformed one, its binding to the hold lifecycle, and its
# publication as decisions_open[].ask through the real home-summary refresh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REFRESH="$ROOT/bin/fm-home-summary-refresh.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-ask)
trap fm_test_cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# Publishes the home's ledger through the real producer and prints it.
published() {  # <home> [refresh-script]
  local home=$1 refresh=${2:-$REFRESH}
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" "$refresh" \
    || fail "home summary refresh failed for $home"
  cat "$home/state/home-summary.json"
}

ask_of() {  # <ledger-json> <task-id>
  jq -c --arg id "$2" '.decisions_open[] | select(.id == $id) | .ask' <<<"$1"
}

write_ask() {  # <path> <json>
  printf '%s\n' "$2" > "$1"
}

test_hold_publishes_its_ask_with_the_recommended_option_first() {
  local home ledger
  home=$(make_home publish)
  write_ask "$home/ask.json" '{"question":"  Which export format should the report use? ",
    "options":[{"label":"CSV"},{"label":"Spreadsheet","id":"sheet"},{"label":"JSON","recommended":true},{"label":"Budget 2000000"},{"label":"Use GPT-4"}],
    "free_text_allowed":true,"link":"https://example.test/board"}'
  run_captain "$home" hold pick-format --title "Pick the export format" \
    --reason "format choice pending" --repo sample --ask-file "$home/ask.json" >/dev/null \
    || fail "hold refused a valid ask"
  run_captain "$home" hold pick-name --title "Pick the release name" \
    --reason "name choice pending" --repo sample >/dev/null \
    || fail "hold without an ask failed"
  ledger=$(published "$home")
  assert_equals '{"question":"Which export format should the report use?","options":[{"id":"3","label":"JSON","recommended":true},{"id":"1","label":"CSV","recommended":false},{"id":"sheet","label":"Spreadsheet","recommended":false},{"id":"4","label":"Budget 2000000","recommended":false},{"id":"5","label":"Use GPT-4","recommended":false}],"free_text_allowed":true,"link":"https://example.test/board"}' \
    "$(ask_of "$ledger" pick-format)" "the held decision did not publish its normalized ask"
  assert_equals 'null' "$(ask_of "$ledger" pick-name)" \
    "a decision without an ask did not publish a null ask"
  assert_equals 'Pick the release name|name choice pending' \
    "$(jq -r '.decisions_open[] | select(.id == "pick-name") | "\(.summary)|\(.reason)"' <<<"$ledger")" \
    "a decision without an ask lost its existing prose"
  assert_equals '[]' "$(jq -c '.omitted' <<<"$ledger")" "valid asks were reported as withheld"
  pass "a held decision publishes its ask, recommended first, beside unchanged prose-only decisions"
}

test_malformed_asks_are_refused_before_anything_is_written() {
  local home bad i=0 seven before
  home=$(make_home refuse)
  seven='[{"label":"a"},{"label":"b"},{"label":"c"},{"label":"d"},{"label":"e"},{"label":"f"},{"label":"g"}]'
  for bad in \
    '{"options":[{"label":"Yes"}]}' \
    '{"question":"   "}' \
    "{\"question\":\"Pick one\",\"options\":$seven}" \
    '{"question":"Pick one","options":[{"label":"A","recommended":true},{"label":"B","recommended":true}]}' \
    '{"question":"Pick one","priority":"high"}' \
    '{"question":"Pick one","options":[{"label":"A","note":"x"}]}' \
    '{"question":"Pick one","options":[{"id":"1","label":"A"},{"label":"B","id":"1"}]}' \
    '{"question":"Pick one","options":[{"id":"bad id","label":"A"}]}' \
    '{"question":"Pick one","link":"javascript:alert(1)"}' \
    '{"question":"Pick one","free_text_allowed":"yes"}' \
    '["Pick one"]' \
    '{"question":"Pick one"} {"question":"Pick two"}' \
    'not json'; do
    i=$((i + 1))
    write_ask "$home/bad-$i.json" "$bad"
    before=$(cat "$home/data/backlog.md")
    if run_captain "$home" hold refused-$i --title "Refused call $i" --reason "pending" \
      --repo sample --ask-file "$home/bad-$i.json" >/dev/null 2>"$home/bad-$i.err"; then
      fail "hold accepted malformed ask $i: $bad"
    fi
    assert_contains "$(cat "$home/bad-$i.err")" "fm-captain-hold: ask" "malformed ask $i was refused without naming the ask"
    assert_equals "$before" "$(cat "$home/data/backlog.md")" "a refused ask $i still changed the backlog"
  done
  : > "$home/empty.json"
  if run_captain "$home" hold refused-empty --title "Refused empty" --reason "pending" \
    --repo sample --ask-file "$home/empty.json" >/dev/null 2>&1; then
    fail "hold accepted an empty ask file"
  fi
  if run_captain "$home" hold refused-missing --title "Refused missing" --reason "pending" \
    --repo sample --ask-file "$home/absent.json" >/dev/null 2>&1; then
    fail "hold accepted an absent ask file"
  fi
  assert_absent "$home/data/captain-asks" "a refused ask left a stored ask behind"
  pass "malformed asks are refused with their problem named and nothing written"
}

test_rerunning_hold_replaces_the_ask_on_a_held_decision() {
  local home ledger
  home=$(make_home replace)
  write_ask "$home/first.json" '{"question":"Which region should host the service?","options":[{"label":"Frankfurt","recommended":true},{"label":"Virginia"}]}'
  run_captain "$home" hold pick-region --title "Pick the hosting region" \
    --reason "region choice pending" --repo sample --ask-file "$home/first.json" >/dev/null || fail "hold failed"
  write_ask "$home/second.json" '{"question":"Which region should host the service now?","options":[{"label":"Virginia","recommended":true}]}'
  run_captain "$home" hold pick-region --reason "region choice pending" \
    --ask-file "$home/second.json" >/dev/null || fail "re-running hold could not replace the stored ask"
  write_ask "$home/bad.json" '{"question":"Which region?","options":[{"label":"A","recommended":"yes"}]}'
  if run_captain "$home" hold pick-region --reason "region choice pending" \
    --ask-file "$home/bad.json" >/dev/null 2>&1; then
    fail "re-running hold accepted a malformed replacement"
  fi
  ledger=$(published "$home")
  assert_equals 'Which region should host the service now?|Virginia' \
    "$(jq -r '.decisions_open[0].ask | "\(.question)|\(.options[0].label)"' <<<"$ledger")" \
    "a refused replacement disturbed the stored ask"
  pass "re-running hold with an ask replaces the stored ask and a refused one leaves it"
}

test_ask_follows_the_hold_lifecycle() {
  local home ledger record
  home=$(make_home lifecycle)
  write_ask "$home/ask.json" '{"question":"Which retention period should apply?","options":[{"label":"30 days","recommended":true},{"label":"90 days"}]}'
  FM_CAPTAIN_HOLD_NOW=2026-10-01T10:00:00Z run_captain "$home" hold pick-retention \
    --title "Pick the retention period" --reason "retention pending" --repo sample \
    --ask-file "$home/ask.json" >/dev/null || fail "hold with ask failed"
  FM_CAPTAIN_HOLD_NOW=2026-10-02T10:00:00Z run_captain "$home" hold pick-retention \
    --reason "retention still pending" >/dev/null || fail "repeated hold failed"
  ledger=$(published "$home")
  assert_equals '30 days' "$(jq -r '.decisions_open[0].ask.options[0].label' <<<"$ledger")" \
    "repeating an active hold dropped its ask"
  record=$(cat "$home/data/captain-asks/pick-retention.json")

  printf 'Keep thirty days.\n' > "$home/decision.txt"
  run_captain "$home" answer pick-retention --decision-file "$home/decision.txt" --release >/dev/null \
    || fail "release answer failed"
  assert_absent "$home/data/captain-asks/pick-retention.json" "a resolved decision kept its ask"

  FM_CAPTAIN_HOLD_NOW=2026-10-03T10:00:00Z run_captain "$home" hold pick-retention \
    --reason "retention reopened" >/dev/null || fail "re-hold failed"
  ledger=$(published "$home")
  assert_equals 'null' "$(ask_of "$ledger" pick-retention)" "a new hold lifecycle inherited the previous ask"
  # A record left over from an earlier lifecycle never matches the new one.
  printf '%s\n' "$record" > "$home/data/captain-asks/pick-retention.json"
  ledger=$(published "$home")
  assert_equals 'null' "$(ask_of "$ledger" pick-retention)" "an earlier lifecycle's ask was published"
  assert_equals '[]' "$(jq -c '.omitted' <<<"$ledger")" "an earlier lifecycle's ask was reported as malformed"
  FM_CAPTAIN_HOLD_NOW=2026-10-04T10:00:00Z run_captain "$home" hold pick-retention \
    --reason "retention reopened" >/dev/null || fail "repeated re-hold failed"
  assert_present "$home/data/captain-asks/pick-retention.json" \
    "repeating an active hold removed a stored record"
  pass "an ask lives exactly as long as the hold lifecycle it was written for"
}

test_tampered_ask_is_withheld_and_disclosed() {
  local home ledger good
  home=$(make_home tampered)
  write_ask "$home/ask.json" '{"question":"Which plan tier should the account use?","options":[{"label":"Team","recommended":true}]}'
  run_captain "$home" hold pick-tier --title "Pick the plan tier" --reason "tier pending" \
    --repo sample --ask-file "$home/ask.json" >/dev/null || fail "hold with ask failed"
  good=$(cat "$home/data/captain-asks/pick-tier.json")
  jq '.ask.options += [{"id":"2","label":"Enterprise","recommended":true}]' <<<"$good" \
    > "$home/data/captain-asks/pick-tier.json"
  ledger=$(published "$home")
  assert_equals 'null' "$(ask_of "$ledger" pick-tier)" "an ask with two recommended options was published"
  assert_equals '[{"surface":"decision_asks","count":1}]' "$(jq -c '.omitted' <<<"$ledger")" \
    "a withheld ask was not disclosed"
  printf 'not json\n' > "$home/data/captain-asks/pick-tier.json"
  ledger=$(published "$home")
  assert_equals 'null' "$(ask_of "$ledger" pick-tier)" "an unreadable ask was published"
  assert_equals '[{"surface":"decision_asks","count":1}]' "$(jq -c '.omitted' <<<"$ledger")" \
    "an unreadable ask was not disclosed"
  assert_equals 'Pick the plan tier' "$(jq -r '.decisions_open[0].summary' <<<"$ledger")" \
    "a withheld ask hid its decision"
  pass "a stored ask that breaks the rule is withheld and disclosed, never published"
}

test_hold_publishes_its_ask_with_the_recommended_option_first
test_malformed_asks_are_refused_before_anything_is_written
test_rerunning_hold_replaces_the_ask_on_a_held_decision
test_ask_follows_the_hold_lifecycle
test_tampered_ask_is_withheld_and_disclosed
