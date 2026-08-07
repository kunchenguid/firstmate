#!/usr/bin/env bash
# Behavior tests for the phase-1 mission control board renderer.
#
# The board is rendered end to end from a real fixture home for the main path,
# and from captured snapshot payloads (the public --snapshot flag) for the
# cross-home and hostile-input cases that a local fixture cannot produce.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-mission-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-mission-control)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

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

mtime_of() {  # <path>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%m' "$1" 2>/dev/null
  else
    stat -c '%Y' "$1" 2>/dev/null
  fi
}

# A complete home: registry, backlog with a captain hold and a landed item, one
# live ship task, and a recorded PR.
write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/alpha-worktree"
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
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=on" \
    "pr=https://github.com/example/alpha/pull/9"
  printf 'working: intake form wired up\n' > "$home/state/ship-task.status"
  touch -r "$home/state/ship-task.meta" "$home/state/ship-task.status"
}

# A minimal but schema-shaped snapshot, so a case can drive fields no local
# fixture produces (another home's decisions, hostile prose, path-form repos).
snapshot_json() {  # <records-json> <secondmate-records-json>
  jq -n --argjson records "$1" --argjson sm "$2" '{
    schema: "fm-fleet-snapshot.v1",
    generated: "2026-01-04T00:00:00Z",
    fm_home: "/fixture/home",
    roots: {state: "/fixture/home/state", data: "/fixture/home/data"},
    backlog: {path: "/fixture/home/data/backlog.md", present: true, records: $records},
    tasks: [],
    secondmate_current: {registry: {
      present: false, available: true, complete: true,
      input_truncated: false, records_truncated: false, records: []
    }, records: $sm}
  }'
}

test_renders_live_fixture_home() {
  local home fakebin out board meta_mtime now
  home=$(make_home live)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  meta_mtime=$(mtime_of "$home/state/ship-task.meta")
  now=$((meta_mtime + 7200))

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MISSION_CONTROL_NOW_EPOCH="$now" \
    "$BOARD" --no-quota) || fail "rendering a populated home must succeed"
  board="$home/state/mission-control.html"
  [ "$out" = "$board" ] || fail "default output path must be <state>/mission-control.html, got $out"
  assert_present "$board" "the board file must be written"

  assert_grep 'Waiting on you' "$board" "the board must carry a waiting-on-you section"
  assert_grep 'Choose the alpha rollout window' "$board" "a captain-held item must be surfaced"
  assert_grep 'Two rollout windows both cost money' "$board" "the captain-held reason must be shown"
  assert_grep 'https://github.com/example/alpha/pull/9' "$board" "a recorded PR must be surfaced as a call"

  assert_grep 'Rebuild the alpha intake form' "$board" "the live task must appear in progress"
  assert_grep 'task record age</dt><dd>2h 0m' "$board" \
    "the mutable metadata timestamp must be labelled as task-record age"
  assert_grep 'working: intake form wired up' "$board" "the last status event must be shown"
  assert_grep 'progress note - populated by firstmate in phase 2' "$board" \
    "the phase-2 progress slot must be rendered and labelled"

  assert_grep 'Ship the alpha health check' "$board" "a landed item must appear as shipped"
  assert_grep 'https://github.com/example/alpha/pull/7' "$board" "a landed item must keep its link"
  assert_grep '+yolo' "$board" "the project rollup must show delivery posture"

  # No completion percentage or ETA is ever invented for an active task.
  assert_no_grep 'ETA' "$board" "the board must not invent an ETA"

  # The board is renamed into place, so a browser never reads a partial file.
  [ -z "$(find "$home/state" -name '.mission-control.html.*' -print -quit)" ] \
    || fail "no temporary board file may survive a successful render"
  pass "a populated home renders every section from live state"
}

test_absent_sources_render_empty_sections() {
  local home fakebin out board
  home=$(make_home empty)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$BOARD" --no-quota) \
    || fail "an empty home must still render"
  board=$out
  assert_grep 'Nothing waiting on you' "$board" "an empty home must say nothing is waiting"
  assert_grep 'No work under way.' "$board" "an empty home must report no work under way"
  assert_grep 'Nothing landed yet.' "$board" "an empty home must report nothing landed"
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
  "generated": "\u003c/script\u003e\u003cscript\u003ealert(3)\u003c/script\u003e",
  "fm_home": "/fixture/home",
  "roots": {"state": "/fixture/home/state", "data": "/fixture/home/data"},
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
  script_tags=$(grep -o '<script>' "$board" | wc -l | tr -d ' ')
  [ "$script_tags" = 1 ] || fail "the rendered page must contain only its single intended script, got $script_tags"
  pass "prose from fleet state is escaped before it reaches the page"
}

test_missing_backlog_is_disclosed_as_unavailable() {
  local snap board
  snap=$TMP_ROOT/no-backlog.json
  board=$TMP_ROOT/no-backlog.html
  snapshot_json '[]' '[]' | jq '.backlog.present = false' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a snapshot with an absent backlog must render"
  assert_grep 'Waiting status incomplete' "$board" \
    "waiting status must be incomplete when main-home decisions cannot be read"
  assert_grep 'Main backlog is unavailable' "$board" "the missing decision source must be named"
  assert_grep 'queued - backlog unavailable' "$board" "queued work must not render as zero"
  assert_grep 'Recently shipped is unavailable' "$board" "shipped work must not render as empty"
  assert_grep 'Backlog health is unavailable' "$board" "backlog health must not render as clear"
  assert_no_grep 'No decisions, reviews, or merges need the captain right now.' "$board" \
    "an absent backlog must not produce an authoritative all-clear"
  assert_no_grep 'Nothing landed yet.' "$board" "an absent backlog must not produce an authoritative shipped zero"
  pass "an absent backlog marks every backlog-derived conclusion unavailable"
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
    }]
  }]' > "$snap"
  "$BOARD" --snapshot "$snap" --no-quota --out "$board" >/dev/null \
    || fail "a secondmate-only decision must render"
  # This decision lives in the secondmate's own backlog, never in this home's,
  # so building the section from the main backlog alone would silently drop it.
  assert_grep 'Approve the paid notification tier' "$board" \
    "a captain decision held inside a secondmate home must reach the board"
  assert_grep '>brain</span>' "$board" "the owning home must be named on the card"
  assert_grep '<b>1</b> waiting on you' "$board" "a secondmate decision must be counted as waiting"
  assert_grep 'none - idle is healthy' "$board" "an idle secondmate must read as healthy, not alarming"
  pass "a captain decision inside a secondmate home is surfaced and counted"
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
  assert_grep '<b>3+</b> waiting known' "$board" \
    "the count must include per-home omitted decisions and mark omitted homes unknown"
  assert_grep 'Additional captain decisions are not shown' "$board" \
    "per-home bounded decisions must produce an actionable disclosure"
  assert_grep 'Snapshot shows 1 of 3 decisions.' "$board" \
    "the per-home disclosure must state the bounded count"
  assert_grep 'Snapshot omitted 1 secondmate record(s).' "$board" \
    "top-level secondmate truncation must produce an incomplete-state disclosure"
  assert_grep '3 waiting (1 shown)' "$board" \
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
  assert_grep 'Waiting status incomplete' "$board" \
    "an unavailable registry must make the captain waiting status incomplete"
  assert_grep 'Secondmate registry scan is incomplete' "$board" \
    "an unavailable registry must produce an actionable disclosure"
  assert_grep 'registered secondmate table is unreadable' "$board" \
    "the registry disclosure must preserve the unavailable reason"
  assert_no_grep '<b>0</b> waiting on you' "$board" \
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
  assert_grep 'Waiting status incomplete' "$board" \
    "a bounded registry must make the captain waiting status incomplete"
  assert_grep 'record_limit' "$board" "the registry disclosure must preserve its truncation reason"
  assert_no_grep '<b>0</b> waiting on you' "$board" \
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
  assert_grep 'Waiting status incomplete' "$board" \
    "an unreadable registered home must make the captain waiting status incomplete"
  assert_grep 'Registered secondmate decisions are unavailable' "$board" \
    "an unreadable registered home must produce an actionable disclosure"
  assert_grep 'structured home snapshot failed' "$board" \
    "the registered-home disclosure must preserve the read failure reason"
  assert_grep 'your decisions</dt><dd>unavailable' "$board" \
    "the secondmate card must not relabel an unreadable decision source as empty"
  assert_no_grep '<b>0</b> waiting on you' "$board" \
    "an unreadable registered home must not produce an authoritative zero"
  pass "unreadable and bounded secondmate sources prevent a false all-clear"
}

test_path_form_repo_folds_into_the_project_rollup() {
  local snap board
  snap=$TMP_ROOT/rollup.json
  board=$TMP_ROOT/rollup.html
  # tasks-axi records a repo as a bare name or as a full clone path; both name
  # the same project and must land on the same rollup row.
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
  assert_grep '>alpha</span>' "$board" "the project must appear once under its registry name"
  assert_grep 'class="num hot">1</td>' "$board" \
    "a path-form captain hold must be counted on its project rollup row"
  pass "path-form and bare-name repos fold onto the same project"
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

test_renders_live_fixture_home
test_absent_sources_render_empty_sections
test_hostile_text_is_escaped
test_missing_backlog_is_disclosed_as_unavailable
test_secondmate_captain_decision_is_surfaced
test_bounded_secondmate_decisions_are_disclosed
test_unreadable_secondmate_sources_are_disclosed
test_path_form_repo_folds_into_the_project_rollup
test_unmeasurable_allowance_is_not_a_zero_gauge
test_usage_errors_refuse
test_self_reload_is_wired
