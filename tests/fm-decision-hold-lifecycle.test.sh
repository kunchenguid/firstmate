#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions discovered by investigations
# and visual reviews.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample --distinct) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-route-implementation ] \
  && [ ! -f "$FM_HOME/unblock-failed-once" ]; then
  : > "$FM_HOME/unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-route.out" 2> "$home/partial-route.err"; then
    fail "resolution succeeded after a partial dependent-routing failure"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "partial routing failure closed the hold"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "partial routing fixture did not release its first dependent"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: yes" "partial routing fixture unexpectedly released its second dependent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-followup > "$home/reduced-retry.out" 2> "$home/reduced-retry.err"; then
    fail "partial resolution retry accepted a reduced routed task set"
  fi
  printf 'Use route south for the sample system.\n' > "$home/changed-route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-drifted-decision.out" 2> "$home/partial-drifted-decision.err"; then
    fail "partial resolution retry accepted a different captain decision"
  fi
  tasks_in "$home" "done" sample-route-followup >/dev/null \
    || fail "could not complete already-routed dependent work"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "could not resume and complete partial decision routing"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "resolution retry accepted a different routed task set"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample --distinct) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample --distinct) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample --distinct) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  printf 'Decide first edge.\n' > "$home/d-first.txt"
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/d-first.txt" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/d-mid.txt"
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/d-mid.txt" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/d-last.txt"
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/d-last.txt" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/d-absent.txt"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/d-absent.txt" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}

# A second review pass of the same subject reaches the same question under a
# different key. That is how the queue compounds, so registering the duplicate
# must not be possible without the open set being seen first, and folding must
# leave exactly one captain decision behind.
test_second_pass_cannot_silently_duplicate_an_open_decision() {
  local home first second rc out show open_out
  home=$(make_home duplicate-guard)
  first=sample-compliance-review
  second=sample-fleet-survey
  mkdir -p "$home/data/$first" "$home/data/$second"
  printf '# first pass\n' > "$home/data/$first/report.md"
  printf '# second pass\n' > "$home/data/$second/report.md"
  write_origin_meta "$home" "$first"
  write_origin_meta "$home" "$second"

  run_decisions "$home" hold "$first" rules-authority \
    --title "Which document is authoritative for the rules" \
    --reason "standing policy choice" --repo sample >/dev/null \
    || fail "could not register the first-pass decision"

  # The second pass asks the same question under its own key.
  set +e
  run_decisions "$home" hold "$second" canonical-text \
    --title "Which text is canonical for the rules" \
    --reason "same authority question" --repo sample \
    > "$home/dup.out" 2> "$home/dup.err"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a same-subject duplicate registered without review (exit $rc)"
  assert_grep "$first-decision-rules-authority" "$home/dup.err" \
    "the refusal must put the open decision set in front of the agent"
  assert_grep "fold" "$home/dup.err" "the refusal must offer folding as the first-class alternative"
  ! grep -F -- "$second-decision-canonical-text" "$home/data/backlog.md" >/dev/null \
    || fail "the refused duplicate still reached the backlog"

  # Folding records the finding on the decision that already owns the question.
  run_decisions "$home" fold "$second" --into "$first-decision-rules-authority" \
    --note "the fleet survey reaches the same question" >/dev/null \
    || fail "could not fold the second pass into the open decision"
  run_decisions "$home" fold "$second" --into "$first-decision-rules-authority" \
    --note "the fleet survey reaches the same question" >/dev/null \
    || fail "folding the same finding twice must be idempotent"
  [ "$(grep -cE "^- \[ \] .*-decision-.* -" "$home/data/backlog.md")" = 1 ] \
    || fail "folding created a second captain decision"
  show=$(tasks_in "$home" show "$first-decision-rules-authority" --full)
  assert_contains "$show" "Also raised by $second" \
    "the folded finding must be durable on the decision that owns the question"
  assert_grep "decision_folds=$first-decision-rules-authority" "$home/state/$second.meta" \
    "the fold must be recorded against the origin that found it"

  # The completion gate stays intact: --none would be a false attestation.
  if run_decisions "$home" complete "$second" --none > "$home/none.out" 2> "$home/none.err"; then
    fail "--none passed while the origin had folded a real unresolved decision"
  fi
  assert_grep "use --folded" "$home/none.err" "the refusal must name the honest attestation"
  run_decisions "$home" complete "$second" --folded >/dev/null \
    || fail "--folded must satisfy the gate for a fully folded review pass"
  run_decisions "$home" verify "$second" >/dev/null \
    || fail "teardown verification must accept a folded inventory"

  # A genuinely different question still gets through, once attested.
  out=$(run_decisions "$home" hold "$second" rollout-window \
    --title "When should the rollout window open" \
    --reason "schedule choice" --repo sample --distinct) \
    || fail "--distinct must let a genuinely distinct decision through"
  [ "$out" = "$second-decision-rollout-window" ] || fail "distinct decision identity was wrong: $out"
  show=$(tasks_in "$home" show "$out" --full)
  assert_contains "$show" "Distinct-from-open: attested" \
    "the distinctness attestation must be durable"

  # Repeating an existing identity is a retry, never a new registration.
  run_decisions "$home" hold "$first" rules-authority \
    --title "Which document is authoritative for the rules" \
    --reason "standing policy choice" --repo sample >/dev/null \
    || fail "an exact-key retry must stay idempotent and ungated"

  open_out=$(run_decisions "$home" open) || fail "open listing failed"
  assert_contains "$open_out" "open captain decisions in" "open must report the current set"
  assert_contains "$open_out" "$first-decision-rules-authority" "open must list the folded-into decision"
  pass "a second pass cannot silently duplicate an open decision and can fold into it"
}

# An answer must be recordable in the turn it arrives. The ceremony that made
# answers go unrecorded - write a file, invent a dependent task, block it - must
# survive only where dependent work genuinely exists.
test_answer_is_recorded_without_inventing_dependent_work() {
  local home origin hold show
  home=$(make_home light-resolve)
  origin=sample-sequencing-review
  mkdir -p "$home/data/$origin"
  printf '# sequencing\n' > "$home/data/$origin/report.md"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" accepted-risk \
    --title "Accept the known gap to ship sooner" --reason "risk the captain owns" --repo sample) \
    || fail "could not register the decision"

  run_decisions "$home" resolve "$origin" accepted-risk \
    --decision "Captain accepted the gap and asked to ship." --no-routed-work >/dev/null \
    || fail "an answer with no dependent work must be recordable in one call"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the answered decision must be closed"
  assert_contains "$show" "Captain accepted the gap and asked to ship." \
    "the captain's exact words must be preserved durably"
  assert_contains "$show" "Origin record:" \
    "closing must not erase the registration record"
  run_decisions "$home" resolve "$origin" accepted-risk \
    --decision "Captain accepted the gap and asked to ship." --no-routed-work >/dev/null \
    || fail "recording the same answer twice must be idempotent"

  # Where dependent work genuinely exists, routing is still mandatory.
  hold=$(run_decisions "$home" hold "$origin" split-or-fix \
    --title "Split the change or fix in place" --reason "captain scope call" --repo sample --distinct) \
    || fail "could not register the routed-work decision"
  tasks_in "$home" add sample-followup "Apply the chosen shape" --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work"
  tasks_in "$home" block sample-followup --by "$hold" >/dev/null \
    || fail "could not block dependent work by the decision"
  if run_decisions "$home" resolve "$origin" split-or-fix \
    --decision "Split it." --no-routed-work > "$home/skip.out" 2> "$home/skip.err"; then
    fail "--no-routed-work bypassed genuinely existing dependent work"
  fi
  assert_grep "sample-followup" "$home/skip.err" "the refusal must name the work that must be routed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "a refused resolve must leave the decision open"
  run_decisions "$home" resolve "$origin" split-or-fix \
    --decision "Split it." --routed-to sample-followup >/dev/null \
    || fail "routing the answer to real dependent work must still work"
  show=$(tasks_in "$home" show sample-followup --full)
  assert_contains "$show" "blocked: no" "routing must clear the dependency edge"
  pass "an answer is recorded in one call and routing survives where dependent work exists"
}

# Decisions closed outside this script - firstmate decided them, or an earlier
# captain answer already settled them - carry a real decision record but not this
# script's formatting, and Done retention rotates older ones into the archive.
# Neither may strand a finished investigation at the completion gate, and a
# decision closed with no record at all must still be refused.
test_externally_closed_decisions_are_durably_resolved() {
  local home origin hold
  home=$(make_home external-closure)
  origin=sample-answered-review
  mkdir -p "$home/data/$origin"
  printf '# answered\n' > "$home/data/$origin/report.md"
  write_origin_meta "$home" "$origin"

  # Closed by hand with a decision record, exactly as a bulk close does it.
  hold=$(run_decisions "$home" hold "$origin" already-answered \
    --title "Log verbatim quotes or redact them" --reason "captain data-policy call" --repo sample) \
    || fail "could not register the decision"
  tasks_in "$home" update "$hold" --body \
    "CLOSED as ALREADY ANSWERED - the captain settled this on 2026-07-29 under key logs-policy." >/dev/null \
    || fail "could not record the external decision record"
  tasks_in "$home" unhold "$hold" >/dev/null || fail "could not release the hold"
  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not close the decision"
  run_decisions "$home" complete "$origin" already-answered >/dev/null \
    || fail "a decision closed with a real record must pass the completion gate"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "a decision closed with a real record must pass the teardown gate"

  # Retention rotates the closed decision out of the live backlog.
  tasks_in "$home" prune --keep 0 >/dev/null 2>&1 || tasks_in "$home" "done" "$hold" --keep 0 >/dev/null 2>&1 || true
  if ! grep -F -- "- [x] $hold - " "$home/data/backlog.md" >/dev/null 2>&1; then
    assert_present "$home/data/done-archive.md" "retention must archive the closed decision"
    run_decisions "$home" verify "$origin" >/dev/null \
      || fail "Done retention alone must not make a reviewed inventory unverifiable"
  fi

  # Closure with no record at all is still the loss this gate prevents.
  hold=$(run_decisions "$home" hold "$origin" no-record \
    --title "Closed with nothing written down" --reason "captain call" --repo sample --distinct) \
    || fail "could not register the second decision"
  tasks_in "$home" unhold "$hold" >/dev/null || fail "could not release the second hold"
  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not close the second decision"
  if run_decisions "$home" complete "$origin" already-answered no-record \
    > "$home/norec.out" 2> "$home/norec.err"; then
    fail "a decision closed with no record at all passed the gate"
  fi
  assert_grep "no decision record" "$home/norec.err" \
    "the refusal must name the missing record rather than the formatting"

  # Ordinary Done retention must not launder that refusal into an acceptance: the
  # archive keeps the untouched registration body, so the archived shape is held
  # to the same record test as the live one.
  tasks_in "$home" prune --keep 0 >/dev/null 2>&1 || true
  if ! grep -F -- "- [x] $hold - " "$home/data/backlog.md" >/dev/null 2>&1; then
    assert_grep "State: awaiting captain decision." "$home/data/done-archive.md" \
      "the archive must preserve the untouched registration body"
    if run_decisions "$home" complete "$origin" already-answered no-record \
      > "$home/archived-norec.out" 2> "$home/archived-norec.err"; then
      fail "retention turned a refused recordless closure into an accepted one"
    fi
    assert_grep "no decision record" "$home/archived-norec.err" \
      "the archived refusal must name the missing record too"
  fi
  pass "externally closed and archived decisions are durably resolved, recordless closure is not"
}

# A fold that cannot be recorded must not report success: the origin would then
# fail `complete --folded` and could attest `--none` over a live decision.
test_unrecordable_fold_refuses_rather_than_reporting_success() {
  local home origin other hold show
  home=$(make_home unrecordable-fold)
  origin=sample-owning-review
  other=sample-later-review
  mkdir -p "$home/data/$origin" "$home/data/$other"
  printf '# owning\n' > "$home/data/$origin/report.md"
  printf '# later\n' > "$home/data/$other/report.md"
  write_origin_meta "$home" "$origin"

  hold=$(run_decisions "$home" hold "$origin" scope \
    --title "Choose the sample scope" --reason "captain scope call" --repo sample) \
    || fail "could not register the decision to fold into"

  # The later review is known only by its report - the post-teardown shape - so no
  # state/<origin>.meta exists to record the fold in.
  [ ! -f "$home/state/$other.meta" ] || fail "fixture must have no runtime metadata"
  if run_decisions "$home" fold "$other" --into "$hold" --note "the same scope question" \
    > "$home/fold.out" 2> "$home/fold.err"; then
    fail "fold reported success while it could not record the fold: $(cat "$home/fold.out")"
  fi
  assert_grep "no runtime metadata" "$home/fold.err" \
    "the refusal must name the missing origin metadata"
  show=$(tasks_in "$home" show "$hold" --full)
  case "$show" in
    *"Also raised by $other"*) fail "a refused fold still mutated the target body" ;;
  esac
  pass "a fold that cannot be recorded refuses instead of reporting success"
}

# A question that turns out to be firstmate's own call must be closable as such,
# without pretending the captain answered it.
test_firstmate_decided_closure_is_first_class() {
  local home origin hold show
  home=$(make_home firstmate-decided)
  origin=sample-sequencing
  mkdir -p "$home/data/$origin"
  printf '# sequencing\n' > "$home/data/$origin/report.md"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" merge-order \
    --title "Which of the two changes lands first" --reason "sequencing" --repo sample) \
    || fail "could not register the decision"
  run_decisions "$home" resolve "$origin" merge-order \
    --decision "Firstmate decided: land the schema change first; the evidence settles it." \
    --decided-by firstmate --no-routed-work >/dev/null \
    || fail "a firstmate-decided closure must be a first-class resolve"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the firstmate-decided closure must close the decision"
  assert_contains "$show" "Decided by: firstmate" \
    "the record must not attribute a firstmate decision to the captain"
  run_decisions "$home" resolve "$origin" merge-order \
    --decision "Firstmate decided: land the schema change first; the evidence settles it." \
    --decided-by firstmate --no-routed-work >/dev/null \
    || fail "a firstmate-decided closure must stay idempotent on retry"
  run_decisions "$home" complete "$origin" merge-order >/dev/null \
    || fail "a firstmate-decided closure must satisfy the completion gate"
  pass "a firstmate-decided closure is first-class and attributed honestly"
}

test_uninventoried_report_decision_refuses_completion
test_externally_closed_decisions_are_durably_resolved
test_unrecordable_fold_refuses_rather_than_reporting_success
test_firstmate_decided_closure_is_first_class
test_second_pass_cannot_silently_duplicate_an_open_decision
test_answer_is_recorded_without_inventing_dependent_work

test_scout_teardown_always_requires_inventory_verification
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
