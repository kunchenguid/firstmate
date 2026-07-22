#!/usr/bin/env bash
# Behavior tests for the Lavish fleet dashboard generator.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-dashboard)
DASH="$ROOT/bin/fm-fleet-dashboard.sh"

test_dashboard_renders_required_surfaces() {
  local home snapshot out html markdown pointer
  home="$TMP_ROOT/home"
  mkdir -p "$home/data" "$home/.lavish"
  home=$(cd "$home" && pwd -P)
  snapshot="$TMP_ROOT/snapshot.json"
  html="$home/.lavish/fleet-dashboard.html"
  markdown="$home/.lavish/fleet-dashboard.md"
  pointer="$home/data/dashboard.md"
  cat > "$snapshot" <<'JSON'
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-07-20T18:00:00Z",
  "fm_home": "/tmp/fm-home",
  "backlog": {
    "records": [
      {"state":"in_flight","structured":true,"id":"lane-a","title":"Merge the thing","repo":"example-app","kind":"ship","since":"2026-07-18","blocked_by":"base-pr","blocked_reason":"depends on base PR","pr_url":"https://github.com/example-org/example-app/pull/1","completion":{"verb":null,"date":null}},
      {"state":"queued","structured":true,"id":"lane-b","title":"Queue cleanup","repo":"example-app","kind":"ship","since":"2026-07-10","blocked_reason":"MQ serialization was avoidable","completion":{"verb":null,"date":null}},
      {"state":"queued","structured":true,"id":"captain-call","title":"Pick rollout","repo":"example-app","kind":"captain","hold_kind":"captain","hold_reason":"choose staged or full rollout","since":"2026-07-20","completion":{"verb":null,"date":null}},
      {"state":"done","structured":true,"id":"landed-a","title":"Finished fix","repo":"example-app","kind":"ship","pr_url":"https://github.com/example-org/example-app/pull/2","completion":{"verb":"merged","date":"2026-07-19"}},
      {"state":"done","structured":true,"id":"landed-b","title":"Hostile pr url","repo":"example-app","kind":"ship","pr_url":"javascript:alert(1)","completion":{"verb":"merged","date":"2026-07-19"}}
    ]
  },
  "tasks": [
    {"id":"lane-a","kind":"ship","project":"example-app","current_state":{"state":"working","detail":"ci running"},"hints":{"open_decisions":[{"key":"rollout","verb":"needs-decision","summary":"choose rollout size"}],"last_event_text":"working"},"pr":{"url":"https://github.com/example-org/example-app/pull/1"}},
    {"id":"lane-c","kind":"scout","project":"firstmate","current_state":{"state":"blocked","detail":"needs credential"},"hints":{"open_decisions":[],"last_event_text":"blocked"},"pr":{"url":null}}
  ],
  "secondmate_current": {
    "records": [
      {"id":"domain","home":"/tmp/domain","current":{"state":"active_child_work","reason":null},"counts":{"active_children":1,"decisions_open":1,"queued":2},"decisions_open":[{"id":"child","verb":"needs-decision","summary":"pick option"}]}
    ]
  },
  "secondmate_landed": {
    "records": [
      {"id":"sm-landed","title":"Secondmate done","home_id":"domain","pr_url":"https://github.com/example-org/example-app/pull/3","completion":{"date":"2026-07-18"}}
    ]
  }
}
JSON

  out=$(FM_HOME="$home" "$DASH" --snapshot-json "$snapshot" --html "$html" --markdown "$markdown" --pointer "$pointer")

  assert_contains "$out" "dashboard html: $html" "dashboard command should print the HTML path"
  assert_present "$html" "dashboard HTML was not written"
  assert_present "$markdown" "dashboard Markdown was not written"
  assert_present "$pointer" "dashboard pointer was not written"
  assert_grep "Lavish is the read surface; ask-tool remains the decision input." "$html" \
    "dashboard HTML must keep Lavish read-only and ask-tool as decision input"
  assert_grep "PR Decided Vs Actual" "$html" "dashboard HTML lost the PR decided-vs-actual surface"
  assert_grep "dependency-forced" "$html" "dashboard HTML lost dependency-forced MQ classification"
  assert_grep "avoidable" "$html" "dashboard HTML lost avoidable MQ classification"
  assert_grep "SLA And Rot Clocks" "$markdown" "dashboard Markdown lost the SLA/rot section"
  assert_grep "example-app/pull/2" "$html" "dashboard HTML lost its real PR links"
  assert_no_grep "href=\"javascript:" "$html" \
    "a worker-reported PR url with a non-web scheme must never become a clickable link"
  assert_no_grep "](javascript:" "$markdown" \
    "a worker-reported PR url with a non-web scheme must never become a Markdown link"
  assert_grep "This file is a pointer, not the dashboard source of truth." "$pointer" \
    "data/dashboard.md should be a pointer, not a duplicate dashboard"
  assert_grep "bin/fm-fleet-dashboard-refresh.sh" "$pointer" \
    "dashboard pointer should name the refresh command"
  pass "fleet dashboard renders Lavish HTML, generated Markdown, and pointer surfaces"
}

test_dashboard_renders_required_surfaces
