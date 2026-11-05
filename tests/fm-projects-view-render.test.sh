#!/usr/bin/env bash
# Behavior tests for the shipped Projects view page
# (.agents/skills/bearings/assets/projects-template.html), built through a real
# `fm-projects-view.sh build` and then executed under the minimal DOM shim in
# tests/assets/projects-render-harness.mjs. Assertions are on what the page
# renders and on the answers it queues, never on the template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VIEW="$ROOT/bin/fm-projects-view.sh"
HARNESS="$ROOT/tests/assets/projects-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-projects-view-render)
NOW=2026-11-05T12:00:00Z

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

# One project with a decision, live work, done work, and queued work; one empty
# project; and one item no project claims.
build_page() {  # <name>
  local home="$TMP_ROOT/$1" reason
  mkdir -p "$home/state" "$home/data" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/config/projects.json" <<'JSON'
{"schema":"fm-projects.v1","projects":[
  {"id":"store","name":"Store launch","match":["store-*"]},
  {"id":"quiet","name":"Quiet project","match":["quiet-*"]}]}
JSON
  reason=$(printf '%s' 'The listing is ready' | base64 | tr -d '\n')
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] store-build - Build the store package (kind: ship) (since 2026-11-01)
## Queued
- [ ] store-ask - Submit to the store? (kind: captain) (since 2026-11-04) (hold: fm-hold-v1:$reason) (hold-kind: captain)
  Captain hold set: 2026-11-04T10:00:00Z
- [ ] store-next - Announce the launch (since 2026-11-02)
- [ ] stray - Nobody claims this (since 2026-11-02)
## Done
- [x] store-done - Shipped the popup (kind: ship) (done 2026-11-03)
  local main
EOF
  fm_write_meta "$home/state/store-build.meta" "window=x:fm-store-build" "kind=ship"
  FM_HOME="$home" FM_SNAPSHOT_NOW="$NOW" bash "$VIEW" build >/dev/null || fail "build failed"
  FM_HOME="$home" bash "$VIEW" path
}

test_overview_shows_every_project_with_its_counter() {
  local page out
  page=$(build_page overview)
  out=$(node "$HARNESS" "$page" store)
  printf '%s' "$out" | jq -e '
    .error == ""
    and .totals == ["1need you", "1in progress", "1done · 30 days"]
    and .cards == [
      {name: "Store launch", counter: "1", now: "Build the store package"},
      {name: "Quiet project", counter: "0", now: "Nothing yet. Add the first task"}]
    and (.tray | startswith("Not in a project"))
  ' >/dev/null || fail "overview rendered wrong: $out"
  pass "the overview shows each project in config order with its needs-you counter"
}

test_detail_orders_needs_then_progress_then_done_then_left() {
  local page out
  page=$(build_page detail)
  out=$(node "$HARNESS" "$page" store)
  printf '%s' "$out" | jq -e '
    .error == ""
    and .detail.name == "Store launch"
    and .detail.counter == "1"
    and .detail.groups == ["Needs you", "In progress", "Done", "Left"]
    and .detail.calls == ["Submit to the store?"]
    and .detail.callComposers == 0
    and .detail.callNotes == ["Answer in chat"]
    and .detail.fixable == ["Build the store package"]
  ' >/dev/null || fail "detail rendered wrong: $out"
  pass "a project opens with needs-you first (read-only, answered in chat), then in progress, done, and left"
}

test_actions_queue_the_routed_answer_keys() {
  local page out
  page=$(build_page actions)
  out=$(node "$HARNESS" "$page" store)
  printf '%s' "$out" | jq -e '
    .error == ""
    and .sent == [
      {schema: "fm-bearings-answer.v1", question: "pv.add.store", selection: "", note: "Add the dark icon"},
      {schema: "fm-bearings-answer.v1", question: "pv.fix.store-build", selection: "", note: "Use the brand color"}]
  ' >/dev/null || fail "actions queued the wrong answers: $out"
  pass "add and correct are the only page actions and queue the add. and fix. answer keys"
}

test_open_project_survives_a_reload_without_the_hash() {
  local page out
  page=$(build_page reload)
  out=$(node "$HARNESS" "$page" store)
  printf '%s' "$out" | jq -e '
    .error == ""
    and .reloaded == {name: "Store launch", cards: 0}
    and .reloadedAfterBack == {cards: 2}
  ' >/dev/null || fail "reload lost the open project: $out"
  pass "the open project survives an automatic redraw that drops the hash, and so does going back"
}

test_withheld_actions_and_unread_homes_render() {
  local home page snap out
  page=$(build_page notices)
  home=${page%/.lavish/projects.html}
  snap="$home/snapshot.json"
  jq -n --arg now "$NOW" '{
    schema: "fm-fleet-snapshot.v1", generated: $now, tasks: [],
    backlog: {records: [{structured: true, id: "pv.add.quiet", title: "Collides", state: "queued", order: 1,
      body_lines: [], unresolved_blocker_ids: [], hold_bucket: null}]},
    secondmate_current: {records: [
      {id: "mate-pc", provenance: {selected: "parent-status"}, current: {state: "unknown", reason: "remote ledger unreachable"},
       freshness: {status: "observed", age_seconds: 0}, active_children: [], queued: [], landed: [], decisions_open: [], omitted: []},
      {id: "mate-mac", provenance: {selected: "structured-home", trust: "complete"}, current: {state: "no_active_work"},
       freshness: {status: "cached", age_seconds: 7200}, active_children: [], queued: [], landed: [], decisions_open: [],
       omitted: [{surface: "queued", count: 3}]}]}
  }' > "$snap"
  FM_HOME="$home" bash "$VIEW" build --snapshot "$snap" >/dev/null || fail "build failed"
  out=$(node "$HARNESS" "$page" store)
  printf '%s' "$out" | jq -e '
    .error == ""
    and .notices == ["mate-pc not read: remote ledger unreachable", "mate-mac last read 2 h ago · 3 not shown"]
    and .addable == ["Store launch"]
  ' >/dev/null || fail "notices or withheld actions rendered wrong: $out"
  pass "an unread or old second mate is shown as such, and a withheld add key hides its button"
}

fm_test_run \
  test_overview_shows_every_project_with_its_counter \
  test_detail_orders_needs_then_progress_then_done_then_left \
  test_actions_queue_the_routed_answer_keys \
  test_open_project_survives_a_reload_without_the_hash \
  test_withheld_actions_and_unread_homes_render
