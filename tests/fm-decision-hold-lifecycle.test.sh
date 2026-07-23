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
SHASUM_BIN=$(command -v shasum || true)

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
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" REAL_SHASUM="$SHASUM_BIN" \
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
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
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
    --title "Middle edge decision" --reason "captain mid pending" --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample) \
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

clone_home() {  # <source-home> <name>
  local source=$1 destination="$TMP_ROOT/$2"
  cp -R "$source" "$destination"
  printf '%s\n' "$destination"
}

rewrite_once() {  # <file> <old> <new>
  local file=$1 old=$2 new=$3 content
  content=$(cat "$file")
  case "$content" in
    *"$old"*) : ;;
    *) fail "archive fixture text was not found in $file: $old" ;;
  esac
  content=${content/"$old"/"$new"}
  printf '%s\n' "$content" > "$file"
}

archive_record() {  # <archive> <id>
  local archive=$1 id=$2
  awk -v id="$id" '
    capturing {
      if ($0 ~ /^- \[[ x]\] / || $0 ~ /^## /) exit
      if ($0 == "" || substr($0, 1, 2) == "  ") {
        print
        next
      }
      exit
    }
    index($0, "- [x] " id " - ") == 1 {
      capturing = 1
      print
    }
  ' "$archive"
}

assert_archive_verify_fails() {  # <home> <origin> <case>
  local home=$1 origin=$2 case_name=$3
  if run_decisions "$home" verify "$origin" \
    > "$home/$case_name.out" 2> "$home/$case_name.err"; then
    fail "archive verification accepted $case_name"
  fi
}

install_late_archive_mutator() {  # <home>
  local home=$1
  cat > "$home/fakebin/shasum" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [ "$1" = -a ] && [ "$2" = 256 ] \
  && [ ! -f "$FM_HOME/late-archive-mutated" ]; then
  : > "$FM_HOME/late-archive-mutated"
  cat "$FM_HOME/late-archive-append" >> "$FM_HOME/data/done-archive.md"
fi
exec "$REAL_SHASUM" "$@"
EOF
  chmod +x "$home/fakebin/shasum"
}

install_late_active_mutator() {  # <home>
  local home=$1
  cat > "$home/fakebin/shasum" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [ "$1" = -a ] && [ "$2" = 256 ] \
  && [ ! -f "$FM_HOME/late-active-mutated" ]; then
  : > "$FM_HOME/late-active-mutated"
  cat "$FM_HOME/late-active-append" >> "$FM_HOME/data/backlog.md"
fi
exec "$REAL_SHASUM" "$@"
EOF
  chmod +x "$home/fakebin/shasum"
}

test_retained_decisions_are_strictly_archive_aware() {
  local home origin older_hold newer_hold archive record unresolved_record heading digest closed variant before after show
  local separator_label separator_code separator
  local decision_case decision_bytes decision_path encoding_case
  local dependent=sample-retained-dependent
  home=$(make_home retained-decisions)
  origin=sample-retained-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review retained decisions" --kind scout --repo sample --start >/dev/null \
    || fail "could not create retained-decision origin"
  write_origin_meta "$home" "$origin"
  printf 'done: retained-decision report complete\n' > "$home/state/$origin.status"
  printf '# Retained decision review\n\nOne historical decision is resolved.\n' > "$home/data/$origin/report.md"

  older_hold=$(run_decisions "$home" hold "$origin" older \
    --title "Choose the retained route" --reason "captain retained route pending" --repo sample) \
    || fail "could not create the decision that will be retained"
  run_decisions "$home" complete "$origin" older >/dev/null \
    || fail "could not inventory the decision before retention"
  tasks_in "$home" add "$dependent" "Apply the retained route" --kind ship --repo sample >/dev/null \
    || fail "could not create retained-decision dependent work"
  tasks_in "$home" block "$dependent" --by "$older_hold" >/dev/null \
    || fail "could not block retained-decision dependent work"
  printf 'Use the retained route.\r\n' > "$home/crlf-retained-decision.txt"
  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  if run_decisions "$home" resolve "$origin" older \
    --decision-file "$home/crlf-retained-decision.txt" --routed-to "$dependent" \
    > "$home/crlf-decision.out" 2> "$home/crlf-decision.err"; then
    fail "resolve accepted a CRLF captain decision"
  fi
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "CRLF rejection mutated the backlog"
  assert_grep "decision file must use LF line endings" "$home/crlf-decision.err" \
    "CRLF rejection did not report the canonical decision-file requirement"

  for encoding_case in lone-continuation truncated overlong surrogate out-of-range; do
    decision_path="$home/$encoding_case-decision.txt"
    case "$encoding_case" in
      lone-continuation) printf '%s' $'\x80' > "$decision_path" ;;
      truncated) printf '%s' $'\xe2\x82' > "$decision_path" ;;
      overlong) printf '%s' $'\xc0\xaf' > "$decision_path" ;;
      surrogate) printf '%s' $'\xed\xa0\x80' > "$decision_path" ;;
      out-of-range) printf '%s' $'\xf4\x90\x80\x80' > "$decision_path" ;;
    esac
    if run_decisions "$home" resolve "$origin" older \
      --decision-file "$decision_path" --routed-to "$dependent" \
      > "$home/$encoding_case-decision.out" 2> "$home/$encoding_case-decision.err"; then
      fail "resolve accepted the $encoding_case malformed UTF-8 fixture"
    fi
    after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
    [ "$before" = "$after" ] || fail "$encoding_case rejection mutated the backlog"
    assert_grep "decision file must contain valid UTF-8" \
      "$home/$encoding_case-decision.err" \
      "$encoding_case rejection did not report the strict UTF-8 requirement"
  done

  printf '%s' $'\xef\xbb\xbfUse the retained route.\n' > "$home/bom-decision.txt"
  if run_decisions "$home" resolve "$origin" older \
    --decision-file "$home/bom-decision.txt" --routed-to "$dependent" \
    > "$home/bom-decision.out" 2> "$home/bom-decision.err"; then
    fail "resolve accepted a UTF-8 BOM"
  fi
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "UTF-8 BOM rejection mutated the backlog"
  assert_grep "decision file must not start with a UTF-8 BOM" "$home/bom-decision.err" \
    "UTF-8 BOM rejection did not report the canonical byte requirement"

  printf 'Use the retained route.\0' > "$home/nul-decision.txt"
  if run_decisions "$home" resolve "$origin" older \
    --decision-file "$home/nul-decision.txt" --routed-to "$dependent" \
    > "$home/nul-decision.out" 2> "$home/nul-decision.err"; then
    fail "resolve accepted a NUL byte"
  fi
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "NUL-byte rejection mutated the backlog"
  assert_grep "decision file must not contain NUL bytes" "$home/nul-decision.err" \
    "NUL-byte rejection did not report the shell-safe byte requirement"

  for decision_case in internal-space internal-tab internal-mixed all-space all-tab all-mixed; do
    case "$decision_case" in
      internal-space) decision_bytes=$'Use the retained route.\n   \nKeep the fallback available.\n' ;;
      internal-tab) decision_bytes=$'Use the retained route.\n\t\t\nKeep the fallback available.\n' ;;
      internal-mixed) decision_bytes=$'Use the retained route.\n \t \nKeep the fallback available.\n' ;;
      all-space) decision_bytes=$'   \n' ;;
      all-tab) decision_bytes=$'\t\t\n' ;;
      all-mixed) decision_bytes=$' \t \n' ;;
    esac
    decision_path="$home/$decision_case-decision.txt"
    printf '%s' "$decision_bytes" > "$decision_path"
    if run_decisions "$home" resolve "$origin" older \
      --decision-file "$decision_path" --routed-to "$dependent" \
      > "$home/$decision_case-decision.out" 2> "$home/$decision_case-decision.err"; then
      fail "resolve accepted the $decision_case whitespace-only decision line fixture"
    fi
    after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
    [ "$before" = "$after" ] || fail "$decision_case rejection mutated the backlog"
    assert_grep "decision file contains a whitespace-only line" \
      "$home/$decision_case-decision.err" \
      "$decision_case rejection did not report how to make the decision canonical"
  done

  printf '%b' 'Use the retained route. \344\270\255\346\226\207\n\nCombining: e\314\201\nNon-BMP: \360\237\232\200\n' > "$home/retained-decision.txt"
  run_decisions "$home" resolve "$origin" older --decision-file "$home/retained-decision.txt" \
    --routed-to "$dependent" >/dev/null \
    || fail "could not resolve the decision before retention"

  for number in 01 02 03 04 05 06 07 08 09 10 11; do
    tasks_in "$home" add "sample-retention-$number" "Retention filler $number" \
      --kind ship --repo sample >/dev/null \
      || fail "could not create retention filler $number"
    tasks_in "$home" "done" "sample-retention-$number" >/dev/null \
      || fail "could not complete retention filler $number"
  done
  archive="$home/data/done-archive.md"
  assert_present "$archive" "done_keep retention did not create an archive"
  assert_no_grep "- [x] $older_hold -" "$home/data/backlog.md" \
    "retained decision remained active instead of entering the archive"
  assert_grep "- [x] $older_hold -" "$archive" \
    "retained decision was not archived"

  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
previous=''
view=''
for argument in "$@"; do
  if [ "$previous" = --file ]; then view=$argument; fi
  previous=$argument
done
if [ -n "$view" ]; then
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$view")
  else
    mode=$(stat -c %a "$view")
  fi
  [ "$mode" = 600 ] || exit 91
  grep -F -- '- [x] sample-retained-review-decision-older -' "$view" >/dev/null || exit 92
  [ "$(grep -c '^- \[' "$view")" = 1 ] || exit 93
  ! grep -F -- 'sample-retention-01' "$view" >/dev/null || exit 94
  : > "$FM_HOME/private-parser-view-checked"
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"

  newer_hold=$(run_decisions "$home" hold "$origin" newer \
    --title "Choose the current route" --reason "captain current route pending" --repo sample) \
    || fail "could not create the current decision after retention"
  run_decisions "$home" complete "$origin" older newer >/dev/null \
    || fail "completion could not verify a retained historical decision"
  run_decisions "$home" complete "$origin" older newer >/dev/null \
    || fail "repeated completion was not idempotent after retention"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "verification could not read the retained decision"
  assert_present "$home/private-parser-view-checked" \
    "archive verification did not use a private exact-record parser view"
  run_decisions "$home" resolve "$origin" older --decision-file "$home/retained-decision.txt" \
    --routed-to "$dependent" >/dev/null \
    || fail "identical resolution retry could not read the retained decision"
  printf 'Use a different retained route.\n' > "$home/changed-retained-decision.txt"
  if run_decisions "$home" resolve "$origin" older \
    --decision-file "$home/changed-retained-decision.txt" --routed-to "$dependent" \
    > "$home/archived-changed-decision.out" 2> "$home/archived-changed-decision.err"; then
    fail "archived resolution retry accepted a different captain decision"
  fi
  if run_decisions "$home" resolve "$origin" older \
    --decision-file "$home/retained-decision.txt" --routed-to sample-retained-other \
    > "$home/archived-changed-routes.out" 2> "$home/archived-changed-routes.err"; then
    fail "archived resolution retry accepted different routed work"
  fi
  if run_decisions "$home" hold "$origin" older \
    --title "Choose the retained route" --reason "captain retained route pending" --repo sample \
    > "$home/archived-hold.out" 2> "$home/archived-hold.err"; then
    fail "hold reopened a retained resolved identity"
  fi
  assert_no_grep "- [ ] $older_hold -" "$home/data/backlog.md" \
    "hold created an active duplicate of a retained identity"
  assert_grep "decision_keys=newer,older" "$home/state/$origin.meta" \
    "retained and current decisions were not unioned deterministically"
  assert_grep "- [ ] $newer_hold -" "$home/data/backlog.md" \
    "the current active decision did not survive retained verification"

  record=$(archive_record "$archive" "$older_hold")
  [ -n "$record" ] || fail "could not extract the retained synthetic record"
  unresolved_record=${record/"- [x] $older_hold -"/"- [ ] $older_hold -"}
  [ "$unresolved_record" != "$record" ] || fail "could not build the unresolved duplicate fixture"
  heading=$(sed -n '/^## Archived /{p;q;}' "$archive")
  [ -n "$heading" ] || fail "retained archive has no canonical section heading"
  digest=$(printf '%s\n' "$record" | sed -n 's/^  Decision digest: //p' | head -1)
  [ -n "$digest" ] || fail "retained record has no decision digest"
  closed=$(printf '%s\n' "$record" | sed -n 's/.*(done \([0-9][0-9-]*\)).*/\1/p' | head -1)
  [ -n "$closed" ] || fail "retained record has no closure date"

  variant=$(clone_home "$home" retained-single-canonical)
  run_decisions "$variant" verify "$origin" >/dev/null \
    || fail "a single canonical archived decision did not verify"

  variant=$(clone_home "$home" retained-truncated)
  rewrite_once "$variant/data/done-archive.md" \
    "  Routed work:- $dependent" "  Routed work:"
  assert_archive_verify_fails "$variant" "$origin" truncated-record

  variant=$(clone_home "$home" retained-forged)
  rewrite_once "$variant/data/done-archive.md" \
    "  Decision digest: $digest" \
    "  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000"
  assert_archive_verify_fails "$variant" "$origin" forged-record

  variant=$(clone_home "$home" retained-invalid-utf8)
  node - "$variant/data/done-archive.md" "$variant/retained-decision.txt" "$digest" <<'NODE' \
    || fail "could not build the invalid UTF-8 archive fixture"
const crypto = require("crypto");
const fs = require("fs");

const [archivePath, decisionPath, oldDigest] = process.argv.slice(2);
const archive = fs.readFileSync(archivePath);
const decision = fs.readFileSync(decisionPath);
const decisionLine = Buffer.from("  Use the retained route.");
const decisionIndex = archive.indexOf(decisionLine);
const digestBytes = Buffer.from(oldDigest);
const digestIndex = archive.indexOf(digestBytes);
if (decisionIndex === -1 || digestIndex === -1 || archive.indexOf(digestBytes, digestIndex + 1) !== -1) {
  process.exit(1);
}
archive[decisionIndex + 2] = 0x80;
decision[0] = 0x80;
const lossyDecision = decision.toString("utf8").replace(/\n+$/, "");
const lossyDigest = crypto.createHash("sha256").update(lossyDecision).digest("hex");
Buffer.from(lossyDigest).copy(archive, digestIndex);
fs.writeFileSync(archivePath, archive);
NODE
  assert_archive_verify_fails "$variant" "$origin" invalid-utf8-record

  variant=$(clone_home "$home" retained-wrong-kind)
  rewrite_once "$variant/data/done-archive.md" "(kind: captain)" "(kind: ship)"
  assert_archive_verify_fails "$variant" "$origin" wrong-kind-record

  variant=$(clone_home "$home" retained-wrong-hold-kind)
  rewrite_once "$variant/data/done-archive.md" "(hold-kind: captain)" "(hold-kind: ship)"
  assert_archive_verify_fails "$variant" "$origin" wrong-hold-kind-record

  variant=$(clone_home "$home" retained-empty-hold-reason)
  rewrite_once "$variant/data/done-archive.md" "(hold: captain retained route pending)" "(hold: )"
  assert_archive_verify_fails "$variant" "$origin" empty-hold-reason
  assert_grep "has no hold reason" "$variant/empty-hold-reason.err" \
    "an encoded empty hold reason passed archived validation"

  variant=$(clone_home "$home" retained-invalid-closure)
  rewrite_once "$variant/data/done-archive.md" "(done $closed)" "(done 2026-02-31)"
  assert_archive_verify_fails "$variant" "$origin" invalid-closure-record

  variant=$(clone_home "$home" retained-duplicate-routes)
  rewrite_once "$variant/data/done-archive.md" \
    "  Routed identities: $dependent" "  Routed identities: $dependent,$dependent"
  assert_archive_verify_fails "$variant" "$origin" duplicate-routed-identities

  variant=$(clone_home "$home" retained-empty-decision)
  rewrite_once "$variant/data/done-archive.md" \
    "  Decision digest: $digest" \
    "  Decision digest: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  rewrite_once "$variant/data/done-archive.md" "  Use the retained route." "  "
  assert_archive_verify_fails "$variant" "$origin" empty-decision-record

  variant=$(clone_home "$home" retained-lossy-blank-line)
  rewrite_once "$variant/data/done-archive.md" \
    $'\n\n  Combining: ' $'\n \t\n  Combining: '
  assert_archive_verify_fails "$variant" "$origin" lossy-blank-line

  variant=$(clone_home "$home" retained-unresolved)
  rewrite_once "$variant/data/done-archive.md" \
    "- [x] $older_hold -" "- [ ] $older_hold -"
  assert_archive_verify_fails "$variant" "$origin" unresolved-record

  variant=$(clone_home "$home" retained-arbitrary-id)
  rewrite_once "$variant/data/done-archive.md" \
    "- [x] $older_hold -" "- [x] $older_hold-unrelated -"
  assert_archive_verify_fails "$variant" "$origin" arbitrary-id-record

  variant=$(clone_home "$home" retained-duplicate)
  printf '\n## Archived 2026-07-24\n%s\n' "$record" >> "$variant/data/done-archive.md"
  assert_archive_verify_fails "$variant" "$origin" duplicate-record

  variant=$(clone_home "$home" retained-canonical-malformed-duplicate)
  printf '\n%s extra\n%s\n' "$heading" "$record" >> "$variant/data/done-archive.md"
  assert_archive_verify_fails "$variant" "$origin" canonical-malformed-duplicate
  assert_grep "appears outside a canonical archive section" \
    "$variant/canonical-malformed-duplicate.err" \
    "a malformed duplicate was hidden from exact identity counting"

  variant=$(clone_home "$home" retained-canonical-unresolved-duplicate)
  printf '\n%s\n%s\n' "$heading" "$unresolved_record" >> "$variant/data/done-archive.md"
  assert_archive_verify_fails "$variant" "$origin" canonical-unresolved-duplicate
  assert_grep "appears outside a canonical archive section" \
    "$variant/canonical-unresolved-duplicate.err" \
    "an unresolved duplicate was hidden from exact identity counting"

  variant=$(clone_home "$home" retained-duplicate-invalid)
  rewrite_once "$variant/data/done-archive.md" "$heading" "$heading extra"
  printf '\n## Unknown\n%s\n' "$record" >> "$variant/data/done-archive.md"
  assert_archive_verify_fails "$variant" "$origin" duplicate-invalid-records
  assert_grep "appears outside a canonical archive section" \
    "$variant/duplicate-invalid-records.err" \
    "duplicate invalid identities were hidden from exact identity counting"

  variant=$(clone_home "$home" retained-malformed-section)
  rewrite_once "$variant/data/done-archive.md" "$heading" "$heading extra"
  assert_archive_verify_fails "$variant" "$origin" malformed-section

  while IFS=' ' read -r separator_label separator_code; do
    separator=$(node -e \
      'process.stdout.write(String.fromCodePoint(Number.parseInt(process.argv[1], 16)))' \
      "$separator_code") || fail "could not build $separator_label heading separator"
    variant=$(clone_home "$home" "retained-heading-$separator_label")
    rewrite_once "$variant/data/done-archive.md" "$heading" \
      "${heading}"$'\n\n##'"${separator}Done"
    assert_archive_verify_fails "$variant" "$origin" "$separator_label-heading-section-escape"
  done <<'EOF'
tab 0009
vertical-tab 000B
form-feed 000C
carriage-return 000D
space 0020
no-break-space 00A0
ogham-space 1680
en-quad 2000
em-quad 2001
en-space 2002
em-space 2003
three-per-em-space 2004
four-per-em-space 2005
six-per-em-space 2006
figure-space 2007
punctuation-space 2008
thin-space 2009
hair-space 200A
line-separator 2028
paragraph-separator 2029
narrow-no-break-space 202F
medium-mathematical-space 205F
ideographic-space 3000
byte-order-mark FEFF
EOF

  separator=$(node -e 'process.stdout.write(String.fromCodePoint(0x85))') \
    || fail "could not build non-ECMAScript whitespace control"
  variant=$(clone_home "$home" retained-heading-nel-control)
  rewrite_once "$variant/data/done-archive.md" "$heading" \
    "${heading}"$'\n\n##'"${separator}Done"
  run_decisions "$variant" verify "$origin" >/dev/null \
    || fail "archive verification treated non-ECMAScript whitespace as a heading"

  variant=$(clone_home "$home" retained-bold-neighbor)
  printf '\n## In flight\n\n- **%s-neighbor** - Nearby active identity (repo: sample) (kind: captain)\n' \
    "$older_hold" >> "$variant/data/backlog.md"
  show=$(tasks_in "$variant" show "$older_hold-neighbor" --full) \
    || fail "bold near-identity positive control was not tasks-axi-readable"
  assert_contains "$show" "state: in_flight" \
    "bold near-identity positive control was not in flight"
  run_decisions "$variant" verify "$origin" >/dev/null \
    || fail "bold near-identity positive control collided with the archived decision"

  variant=$(clone_home "$home" retained-bold-collision)
  printf '\n## In flight\n\n- **%s** - Colliding active identity (repo: sample) (kind: captain)\n' \
    "$older_hold" >> "$variant/data/backlog.md"
  show=$(tasks_in "$variant" show "$older_hold" --full) \
    || fail "bold collision fixture was not tasks-axi-readable"
  assert_contains "$show" "state: in_flight" "bold collision fixture was not in flight"
  assert_archive_verify_fails "$variant" "$origin" bold-active-archive-collision
  assert_grep "exists in both active backlog and archive" \
    "$variant/bold-active-archive-collision.err" \
    "bold active/archive collision did not report the exact identity conflict"

  variant=$(clone_home "$home" retained-active-hash-failure)
  rewrite_once "$variant/state/$origin.meta" "decision_keys=newer,older" "decision_keys=newer"
  cat > "$variant/fakebin/shasum" <<'EOF'
#!/usr/bin/env bash
exit 73
EOF
  chmod +x "$variant/fakebin/shasum"
  assert_archive_verify_fails "$variant" "$origin" active-hash-command-failure
  assert_grep "could not fingerprint decision archive" \
    "$variant/active-hash-command-failure.err" \
    "active lookup did not reject a failed archive hash command"

  variant=$(clone_home "$home" retained-archive-hash-malformed)
  rewrite_once "$variant/state/$origin.meta" "decision_keys=newer,older" "decision_keys=older"
  cat > "$variant/fakebin/shasum" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'not-a-sha256  archive'
EOF
  chmod +x "$variant/fakebin/shasum"
  assert_archive_verify_fails "$variant" "$origin" archived-hash-malformed
  assert_grep "could not fingerprint decision archive" \
    "$variant/archived-hash-malformed.err" \
    "archived lookup did not reject malformed hash output"

  variant=$(clone_home "$home" retained-symlink)
  mv "$variant/data/done-archive.md" "$variant/data/archive-target.md"
  ln -s archive-target.md "$variant/data/done-archive.md"
  assert_archive_verify_fails "$variant" "$origin" symlink-archive

  variant=$(clone_home "$home" retained-directory)
  mv "$variant/data/done-archive.md" "$variant/data/archive-target.md"
  mkdir "$variant/data/done-archive.md"
  assert_archive_verify_fails "$variant" "$origin" non-regular-archive

  variant=$(clone_home "$home" retained-unreadable)
  chmod 000 "$variant/data/done-archive.md"
  assert_archive_verify_fails "$variant" "$origin" unreadable-archive
  chmod 600 "$variant/data/done-archive.md"

  variant=$(clone_home "$home" retained-absent-active-store)
  rewrite_once "$variant/state/$origin.meta" "decision_keys=newer,older" "decision_keys=older"
  rm "$variant/data/backlog.md"
  run_decisions "$variant" verify "$origin" >/dev/null \
    || fail "an absent active store was not treated as empty"

  variant=$(clone_home "$home" retained-symlink-active-store)
  rewrite_once "$variant/state/$origin.meta" "decision_keys=newer,older" "decision_keys=older"
  mv "$variant/data/backlog.md" "$variant/data/backlog-target.md"
  ln -s backlog-target.md "$variant/data/backlog.md"
  assert_archive_verify_fails "$variant" "$origin" symlink-active-store

  variant=$(clone_home "$home" retained-broken-symlink-active-store)
  rewrite_once "$variant/state/$origin.meta" "decision_keys=newer,older" "decision_keys=older"
  rm "$variant/data/backlog.md"
  ln -s missing-backlog.md "$variant/data/backlog.md"
  assert_archive_verify_fails "$variant" "$origin" broken-symlink-active-store

  variant=$(clone_home "$home" retained-directory-active-store)
  rewrite_once "$variant/state/$origin.meta" "decision_keys=newer,older" "decision_keys=older"
  mv "$variant/data/backlog.md" "$variant/data/backlog-target.md"
  mkdir "$variant/data/backlog.md"
  assert_archive_verify_fails "$variant" "$origin" directory-active-store

  variant=$(clone_home "$home" retained-fifo-active-store)
  rewrite_once "$variant/state/$origin.meta" "decision_keys=newer,older" "decision_keys=older"
  mv "$variant/data/backlog.md" "$variant/data/backlog-target.md"
  mkfifo "$variant/data/backlog.md"
  assert_archive_verify_fails "$variant" "$origin" fifo-active-store

  variant=$(clone_home "$home" retained-unreadable-active-store)
  rewrite_once "$variant/state/$origin.meta" "decision_keys=newer,older" "decision_keys=older"
  chmod 000 "$variant/data/backlog.md"
  assert_archive_verify_fails "$variant" "$origin" unreadable-active-store
  chmod 600 "$variant/data/backlog.md"

  variant=$(clone_home "$home" retained-concurrent-change)
  cat > "$variant/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" show "*" --file "*)
    if [ ! -f "$FM_HOME/archive-changed-once" ]; then
      : > "$FM_HOME/archive-changed-once"
      printf '\n# concurrent archive change\n' >> "$FM_HOME/data/done-archive.md"
    fi
    ;;
esac
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$variant/fakebin/tasks-axi"
  assert_archive_verify_fails "$variant" "$origin" concurrent-change

  variant=$(clone_home "$home" retained-late-duplicate-change)
  printf '\n%s\n%s\n' "$heading" "$record" > "$variant/late-archive-append"
  install_late_archive_mutator "$variant"
  assert_archive_verify_fails "$variant" "$origin" late-duplicate-change
  assert_grep "decision archive changed during verification" \
    "$variant/late-duplicate-change.err" \
    "a duplicate appended during structured validation escaped the final archive recheck"

  variant=$(clone_home "$home" retained-late-nonidentity-change)
  printf '\n# late non-identity archive mutation\n' > "$variant/late-archive-append"
  install_late_archive_mutator "$variant"
  assert_archive_verify_fails "$variant" "$origin" late-nonidentity-change
  assert_grep "decision archive changed during verification" \
    "$variant/late-nonidentity-change.err" \
    "a non-identity mutation during structured validation escaped the final archive recheck"

  variant=$(clone_home "$home" retained-late-active-collision)
  rewrite_once "$variant/state/$origin.meta" "decision_keys=newer,older" "decision_keys=older"
  printf '\n## Queued\n\n- [ ] %s - Late active collision (repo: sample) (kind: captain) (hold: captain collision pending) (hold-kind: captain)\n' \
    "$older_hold" > "$variant/late-active-append"
  install_late_active_mutator "$variant"
  assert_archive_verify_fails "$variant" "$origin" late-active-collision
  assert_grep "appeared in the active backlog during verification" \
    "$variant/late-active-collision.err" \
    "an active identity inserted during structured validation escaped the final recheck"

  variant=$(clone_home "$home" retained-active-archive-collision)
  printf '\n%s\n' "$record" >> "$variant/data/backlog.md"
  assert_archive_verify_fails "$variant" "$origin" active-archive-collision

  pass "canonical Unicode survives retention while malformed bytes, lossy text, late collisions, duplicates, and unsafe stores are rejected"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_retained_decisions_are_strictly_archive_aware
