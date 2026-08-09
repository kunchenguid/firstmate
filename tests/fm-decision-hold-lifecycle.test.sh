#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions, whether an investigation or
# visual review discovered them or they were filed against an existing work item.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

# Filing a captain decision requires each context dimension to be addressed. The
# cases below are about identity, routing, retraction, and teardown rather than
# about context, so they pass one standard synthetic set and leave the bar itself
# to test_decision_context_* below.
SAMPLE_CONTEXT=(
  --why "The sample review cannot proceed until this is chosen."
  --affects "The sample surface named in the report."
  --recommendation "Take the first sample option."
  --no-surface "Synthetic sample decision with nothing built to look at."
)

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
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample "${SAMPLE_CONTEXT[@]}") \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample "${SAMPLE_CONTEXT[@]}" >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample "${SAMPLE_CONTEXT[@]}") \
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
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample "${SAMPLE_CONTEXT[@]}") \
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
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample "${SAMPLE_CONTEXT[@]}") \
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
    --title "First edge decision" --reason "captain first pending" --repo sample "${SAMPLE_CONTEXT[@]}") \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample "${SAMPLE_CONTEXT[@]}") \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample "${SAMPLE_CONTEXT[@]}") \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample "${SAMPLE_CONTEXT[@]}") \
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

# Reproduces the live portfolio-dashboard-visual-calibration shape: a correctly
# filed and correctly resolved captain decision that tasks-axi Done retention has
# pruned out of the live backlog. The gate used to see only data/backlog.md, report
# the decision absent, and refuse completion and teardown for finished work.
test_archived_resolved_decision_satisfies_the_gate() {
  local home origin hold out
  home=$(make_home archived-resolved-decision)
  origin=sample-retention-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Investigate sample retention" --kind scout --repo sample --start >/dev/null \
    || fail "could not create retention-review origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report and visual review complete\n' > "$home/state/$origin.status"
  printf '# Sample retention review\n\nOne captain choice was made several rounds ago.\n' \
    > "$home/data/$origin/report.md"

  hold=$(run_decisions "$home" hold "$origin" anchors \
    --title "Choose the sample evidence anchors" --reason "captain anchor choice pending" --repo sample "${SAMPLE_CONTEXT[@]}") \
    || fail "could not register the retention hold"
  run_decisions "$home" complete "$origin" anchors >/dev/null \
    || fail "completion failed while the hold was still live"
  tasks_in "$home" add sample-anchor-followup "Apply the selected sample anchors" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use the clean sample anchors.\n' > "$home/anchor-decision.txt"
  run_decisions "$home" resolve "$origin" anchors --decision-file "$home/anchor-decision.txt" \
    --routed-to sample-anchor-followup >/dev/null \
    || fail "could not resolve the retention hold"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "verification failed while the resolved hold was still in the live backlog"

  # Done retention prunes the resolved record out of the live backlog.
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null || fail "could not archive the resolved hold"
  assert_no_grep "$hold" "$home/data/backlog.md" "retention fixture left the hold in the live backlog"
  assert_grep "- [x] $hold" "$home/data/done-archive.md" "retention fixture did not archive the resolved hold"

  run_decisions "$home" verify "$origin" > "$home/archived-verify.out" 2> "$home/archived-verify.err" \
    || fail "gate refused an archived resolved decision: $(cat "$home/archived-verify.err")"
  run_decisions "$home" complete "$origin" anchors >/dev/null \
    || fail "completion refused an archived resolved decision"
  run_teardown "$home" "$origin" >/dev/null 2> "$home/archived-teardown.err" \
    || fail "teardown refused finished work whose decision was archived: $(cat "$home/archived-teardown.err")"

  # The archive is evidence, never a source to write back to or restore from.
  assert_no_grep "$hold" "$home/data/backlog.md" "the gate restored an archived record into the live backlog"

  # An exact resolve retry that straddles retention stays idempotent, and a
  # different decision or routed set is still rejected against the archived record.
  run_decisions "$home" resolve "$origin" anchors --decision-file "$home/anchor-decision.txt" \
    --routed-to sample-anchor-followup >/dev/null \
    || fail "exact resolve retry failed once the hold was archived"
  printf 'Use different sample anchors.\n' > "$home/changed-anchor-decision.txt"
  if run_decisions "$home" resolve "$origin" anchors --decision-file "$home/changed-anchor-decision.txt" \
    --routed-to sample-anchor-followup > "$home/archived-drift.out" 2> "$home/archived-drift.err"; then
    fail "resolve retry accepted a different captain decision against the archived record"
  fi
  tasks_in "$home" add sample-anchor-extra "Extra sample anchor work" --kind ship --repo sample >/dev/null
  if run_decisions "$home" resolve "$origin" anchors --decision-file "$home/anchor-decision.txt" \
    --routed-to sample-anchor-followup --routed-to sample-anchor-extra \
    > "$home/archived-routes.out" 2> "$home/archived-routes.err"; then
    fail "resolve retry accepted a different routed task set against the archived record"
  fi

  out=$(cat "$home/archived-verify.out")
  assert_contains "$out" "verified: $origin" "archived-decision verification lost its summary"
  pass "an archived resolved captain decision satisfies the completion gate"
}

# The safety property the archive lookup must not weaken: only a genuinely resolved
# archived record counts. Every other archive shape keeps today's refusal.
test_archive_lookup_refuses_every_unresolved_shape() {
  local home origin hold err
  home=$(make_home archive-refusals)
  origin=sample-refusal-review
  mkdir -p "$home/data/$origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Sample refusal review\n\nSynthetic archive shapes.\n' > "$home/data/$origin/report.md"
  hold="$origin-decision-choice"
  printf 'decisions_reviewed=1\ndecision_keys=choice\n' >> "$home/state/$origin.meta"

  # 1. Absent from both sources: never filed at all. The refusal must say so.
  assert_absent "$home/data/done-archive.md" "fixture must start with no archive"
  if run_decisions "$home" verify "$origin" > "$home/no-archive.out" 2> "$home/no-archive.err"; then
    fail "a never-filed decision passed with no archive present"
  fi
  assert_grep "was never filed" "$home/no-archive.err" \
    "a missing archive must still report the decision as never filed"

  # 2. An unreadable archive must refuse without crashing, and must not claim the
  #    decision was never filed - that is the one case the gate cannot rule out.
  printf '## Archived 2026-08-05\n- [x] %s - Choice (repo: sample) (kind: captain) (done 2026-08-05)\n  Resolution recorded by fm-decision-hold.\n  Routed work:- dep\n' \
    "$hold" > "$home/data/done-archive.md"
  chmod 000 "$home/data/done-archive.md"
  if [ -r "$home/data/done-archive.md" ]; then
    chmod 644 "$home/data/done-archive.md"
  else
    if run_decisions "$home" verify "$origin" > "$home/unreadable.out" 2> "$home/unreadable.err"; then
      fail "an unreadable archive satisfied the gate"
    fi
    assert_grep "could not be read" "$home/unreadable.err" "an unreadable archive must refuse, not crash"
    assert_no_grep "was never filed" "$home/unreadable.err" \
      "an unreadable archive must not be reported as a decision that was never filed"
    chmod 644 "$home/data/done-archive.md"
  fi

  # 3. Malformed archive content refuses exactly as an absent record does.
  printf 'not a backlog file at all\n\x00\n- [x\n## \n' > "$home/data/done-archive.md"
  if run_decisions "$home" verify "$origin" > "$home/malformed.out" 2> "$home/malformed.err"; then
    fail "a malformed archive satisfied the gate"
  fi
  assert_grep "was never filed" "$home/malformed.err" "a malformed archive must refuse, not crash"

  # 4. Archived but not marked done: the record exists and is not resolved.
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-08-05
- [ ] $hold - Choice (repo: sample) (kind: captain)
  Resolution recorded by fm-decision-hold.
  Routed work:- sample-dep
EOF
  if run_decisions "$home" verify "$origin" > "$home/not-done.out" 2> "$home/not-done.err"; then
    fail "an archived record that is not marked done satisfied the gate"
  fi
  assert_grep "without a durable resolution record" "$home/not-done.err" \
    "an unresolved archived record must be named as archived, not as never filed"

  # 5. Archived and done, but with no durable resolution record.
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-08-05
- [x] $hold - Choice (repo: sample) (kind: captain) (done 2026-08-05)
  Origin: $origin
  State: awaiting captain decision.
EOF
  if run_decisions "$home" verify "$origin" > "$home/no-record.out" 2> "$home/no-record.err"; then
    fail "an archived record without a resolution record satisfied the gate"
  fi
  assert_grep "without a durable resolution record" "$home/no-record.err" \
    "an archived record missing its resolution record must refuse"

  # 6. Archived, done, resolved-looking, but not a captain identity.
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-08-05
- [x] $hold - Choice (repo: sample) (kind: ship) (done 2026-08-05)
  Resolution recorded by fm-decision-hold.
  Routed work:- sample-dep
EOF
  if run_decisions "$home" verify "$origin" > "$home/wrong-kind.out" 2> "$home/wrong-kind.err"; then
    fail "an archived non-captain identity satisfied the captain-decision gate"
  fi

  # 7. A longer archived id that merely shares this identity's prefix must not
  #    satisfy the gate for the shorter key.
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-08-05
- [x] ${hold}-extended - Extended choice (repo: sample) (kind: captain) (done 2026-08-05)
  Resolution recorded by fm-decision-hold.
  Routed work:- sample-dep
EOF
  if run_decisions "$home" verify "$origin" > "$home/prefix.out" 2> "$home/prefix.err"; then
    fail "a prefix-colliding archived id satisfied the gate for a different decision"
  fi
  assert_grep "was never filed" "$home/prefix.err" \
    "a prefix-colliding archived id must count as never filed for this decision"

  # 8. The body of a neighbouring archived record must not leak into this one.
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-08-05
- [x] $hold - Choice (repo: sample) (kind: captain) (done 2026-08-05)
  Origin: $origin
  State: awaiting captain decision.
- [x] sample-other-decision - Other (repo: sample) (kind: captain) (done 2026-08-05)
  Resolution recorded by fm-decision-hold.
  Routed work:- sample-dep
EOF
  if run_decisions "$home" verify "$origin" > "$home/leak.out" 2> "$home/leak.err"; then
    fail "a neighbouring archived record's resolution satisfied this decision"
  fi

  err=$(cat "$home/leak.err")
  assert_contains "$err" "$hold" "refusal must name the decision identity it checked"
  pass "only a genuinely resolved archived captain decision satisfies the gate"
}

# Two keys were filed for one question, so the duplicate is removed with
# `tasks-axi rm` - the correct de-duplication action. That left the key in the
# recorded union and absent from both durability sources, so `verify` and
# `complete` refused forever and scout teardown could never clean the source up.
# The retraction that repairs it must not become a way to drop a key out of the
# gate, so every negative below is asserted while the strand is still live.
test_duplicate_decision_key_retraction_unstrands_teardown() {
  local home id survivor duplicate distinct unreviewed rc open recorded show
  home=$(make_home duplicate-decision-key)
  id=sample-dedup-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample deduplication" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route-choice]: choose route north or route south
needs-decision [key=routing-direction]: choose route north or route south
needs-decision [key=access-level]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample deduplication review

Two genuine choices remain: the sample route and the sample access level.
An early review pass filed the route question twice under two different keys.
EOF

  survivor=$(run_decisions "$home" hold "$id" route-choice \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample "${SAMPLE_CONTEXT[@]}") \
    || fail "could not register the surviving hold"
  duplicate=$(run_decisions "$home" hold "$id" routing-direction \
    --title "Choose the sample routing direction" --reason "captain route choice pending" --repo sample "${SAMPLE_CONTEXT[@]}") \
    || fail "could not register the duplicate hold"
  distinct=$(run_decisions "$home" hold "$id" access-level \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample "${SAMPLE_CONTEXT[@]}") \
    || fail "could not register the second distinct hold"
  run_decisions "$home" complete "$id" route-choice routing-direction access-level >/dev/null \
    || fail "completion gate failed while all three keys were held"
  recorded=$(grep '^decision_keys=' "$home/state/$id.meta" | tail -1)
  [ "$recorded" = "decision_keys=access-level,route-choice,routing-direction" ] \
    || fail "completion did not record the full inventory: $recorded"

  # De-duplication, exactly as an operator performs it on a duplicate hold.
  tasks_in "$home" rm "$duplicate" >/dev/null || fail "could not remove the duplicate hold"

  # The strand, reproduced: both gates refuse and the scout cannot be cleaned up.
  if run_decisions "$home" verify "$id" > "$home/stranded-verify.out" 2> "$home/stranded-verify.err"; then
    fail "verification passed while a recorded key was absent from both durability sources"
  fi
  assert_grep "$duplicate" "$home/stranded-verify.err" "the refusal must name the stranded identity"
  if run_decisions "$home" complete "$id" route-choice > "$home/stranded-complete.out" 2> "$home/stranded-complete.err"; then
    fail "completion retry passed while a recorded key was absent from both durability sources"
  fi
  set +e
  run_teardown "$home" "$id" > "$home/stranded-teardown.out" 2> "$home/stranded-teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the duplicate-key strand was not reproduced: teardown already succeeded"
  assert_present "$home/state/$id.meta" "the stranded refusal must preserve investigation metadata"

  # Retraction always needs a surviving key that is in this inventory and durable.
  if run_decisions "$home" retract "$id" routing-direction \
    > "$home/no-anchor.out" 2> "$home/no-anchor.err"; then
    fail "retraction dropped a key without naming a superseding decision"
  fi
  if run_decisions "$home" retract "$id" routing-direction --superseded-by routing-direction \
    > "$home/self-anchor.out" 2> "$home/self-anchor.err"; then
    fail "a decision key superseded itself"
  fi
  if run_decisions "$home" retract "$id" routing-direction --superseded-by sample-unfiled \
    > "$home/foreign-anchor.out" 2> "$home/foreign-anchor.err"; then
    fail "retraction accepted a superseding key outside the reviewed inventory"
  fi
  # The removed key is still in the inventory but is no longer durable, so it can
  # never be used to justify dropping a decision that is still genuinely held.
  if run_decisions "$home" retract "$id" route-choice --superseded-by routing-direction \
    > "$home/dead-anchor.out" 2> "$home/dead-anchor.err"; then
    fail "retraction accepted a superseding key that is not itself durable"
  fi
  assert_grep "$survivor" "$home/data/backlog.md" "a refused retraction removed the surviving hold"

  unreviewed=$(run_decisions "$home" hold "$id" later-question \
    --title "Choose a later sample option" --reason "later captain choice pending" --repo sample "${SAMPLE_CONTEXT[@]}") \
    || fail "could not register an uninventoried hold"
  printf 'needs-decision [key=later-question]: choose a later sample option\n' \
    >> "$home/state/$id.status"
  cp "$home/state/$id.status" "$home/status-before-uninventoried-retract"
  run_decisions "$home" retract "$id" later-question --superseded-by route-choice \
    > "$home/uninventoried-retract.out" 2>&1 \
    || fail "an uninventoried live hold did not take the no-op path"
  assert_grep "already outside the reviewed inventory" "$home/uninventoried-retract.out" \
    "an uninventoried live hold did not report the no-op path"
  assert_grep "$unreviewed" "$home/data/backlog.md" \
    "the no-op path removed an uninventoried live hold"
  cmp -s "$home/status-before-uninventoried-retract" "$home/state/$id.status" \
    || fail "the no-op path appended a status transfer for an uninventoried hold"

  cp "$home/data/backlog.md" "$home/backlog-before-absent-retract"
  cp "$home/state/$id.status" "$home/status-before-absent-retract"
  cp "$home/state/$id.meta" "$home/meta-before-absent-retract"
  run_decisions "$home" retract "$id" mistyped-question --superseded-by route-choice \
    > "$home/absent-retract.out" 2>&1 \
    || fail "an absent decision key did not take the no-op path"
  assert_grep "already outside the reviewed inventory" "$home/absent-retract.out" \
    "an absent decision key did not report the no-op path"
  cmp -s "$home/backlog-before-absent-retract" "$home/data/backlog.md" \
    || fail "the no-op path mutated the backlog for an absent decision key"
  cmp -s "$home/status-before-absent-retract" "$home/state/$id.status" \
    || fail "the no-op path mutated status for an absent decision key"
  cmp -s "$home/meta-before-absent-retract" "$home/state/$id.meta" \
    || fail "the no-op path mutated metadata for an absent decision key"
  tasks_in "$home" rm "$unreviewed" >/dev/null \
    || fail "could not clean up the preserved uninventoried hold fixture"
  printf 'captain-held [key=later-question]: fixture cleanup\n' >> "$home/state/$id.status"

  run_decisions "$home" retract "$id" routing-direction --superseded-by route-choice >/dev/null \
    || fail "retracting a duplicate key failed"
  recorded=$(grep '^decision_keys=' "$home/state/$id.meta" | tail -1)
  [ "$recorded" = "decision_keys=access-level,route-choice" ] \
    || fail "retraction did not update the recorded inventory: $recorded"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "retraction left the duplicate key open in the live status fold: $open"
  run_decisions "$home" retract "$id" routing-direction --superseded-by route-choice \
    > "$home/retract-retry.out" 2>&1 || fail "an identical retraction retry was not idempotent"
  assert_grep "already outside the reviewed inventory" "$home/retract-retry.out" \
    "a retry that removed nothing still reported a completed retraction"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "verification still refused after the duplicate key was retracted"
  run_decisions "$home" complete "$id" route-choice access-level >/dev/null \
    || fail "completion still refused after the duplicate key was retracted"

  # A recorded captain decision is never retractable, including after `resolve`
  # writes its body and routes dependents but is interrupted before the final Done.
  tasks_in "$home" add sample-route-work "Apply the selected sample route" \
    --kind ship --repo sample --blocked-by "$survivor" >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = done ] && [ "\${2:-}" = "$survivor" ]; then
  exit 1
fi
exec "\$REAL_TASKS_AXI" "\$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route-choice --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-work > "$home/interrupted-resolve.out" 2> "$home/interrupted-resolve.err"; then
    fail "resolution succeeded when its final Done transition was interrupted"
  fi
  if run_decisions "$home" retract "$id" route-choice --superseded-by access-level \
    > "$home/interrupted-retract.out" 2> "$home/interrupted-retract.err"; then
    fail "an interrupted recorded captain decision was retractable"
  fi
  assert_grep "$survivor" "$home/interrupted-retract.err" \
    "interrupted-resolution refusal did not name the captain decision"
  assert_grep "recorded captain decision that must not be deleted" "$home/interrupted-retract.err" \
    "interrupted-resolution refusal did not explain the deletion boundary"
  show=$(tasks_in "$home" show "$survivor" --full) \
    || fail "interrupted-resolution refusal removed the captain hold"
  assert_contains "$show" "state: queued" "interrupted resolution unexpectedly closed the captain hold"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" \
    "interrupted-resolution refusal lost the captain decision record"
  assert_contains "$show" "Routed work:" \
    "interrupted-resolution refusal lost the routed-work record"
  rm "$home/fakebin/tasks-axi"

  # A durably resolved decision already satisfies the gate, live or archived, so it
  # is never retractable and the surviving distinct decision stays gated.
  run_decisions "$home" resolve "$id" route-choice --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-work >/dev/null || fail "could not resolve the surviving hold"
  if run_decisions "$home" retract "$id" route-choice --superseded-by access-level \
    > "$home/resolved-retract.out" 2> "$home/resolved-retract.err"; then
    fail "a durably resolved captain decision was retractable"
  fi
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null || fail "could not archive the resolved hold"
  if run_decisions "$home" retract "$id" route-choice --superseded-by access-level \
    > "$home/archived-retract.out" 2> "$home/archived-retract.err"; then
    fail "an archived resolved captain decision was retractable"
  fi

  # The acceptance criterion: an ordinary de-duplication no longer strands teardown.
  run_teardown "$home" "$id" >/dev/null 2> "$home/repaired-teardown.err" \
    || fail "de-duplicated investigation teardown still refused: $(cat "$home/repaired-teardown.err")"
  assert_grep "$distinct" "$home/data/backlog.md" \
    "teardown after retraction lost the second distinct captain decision"
  pass "a de-duplicated decision key is retractable and no longer strands teardown"
}

test_decision_question_and_private_link_use_the_supported_hold_interface() {
  local home origin hold out question summary show bad_url good_url
  home=$(make_home decision-context)
  origin=sample-context-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review sample decision context" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$origin"
  printf '# Sample context review\n' > "$home/data/$origin/report.md"
  printf 'done: review complete\n' > "$home/state/$origin.status"

  question='Should the sample preserve literal \n and \t text?'
  hold=$(run_decisions "$home" hold "$origin" emphasis \
    --title "Choose the sample emphasis" \
    --reason "captain emphasis choice pending" \
    --question "$question" \
    --why "The sample emphasis blocks the next sample pass." \
    --affects "Every sample row that renders emphasis." \
    --recommendation "Keep the literal text." \
    --decision-url "https://sample.tailnet.invalid/decision-aid" \
    --repo sample) || fail "the supported hold interface could not record decision context"

  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$out" | jq -e --arg hold "$hold" --arg question "$question" '
    .backlog.records[] | select(.id == $hold)
    | .decision_question == $question
      and .decision_url == "https://sample.tailnet.invalid/decision-aid"
  ' >/dev/null || fail "main-home decision context did not reach the canonical snapshot: $out"

  summary=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary)
  printf '%s' "$summary" | jq -e --arg hold "$hold" --arg question "$question" '
    .decisions_open[] | select(.id == $hold)
    | .question == $question
      and .decision_url == "https://sample.tailnet.invalid/decision-aid"
  ' >/dev/null || fail "decision context did not reach the secondmate-home projection: $summary"

  run_decisions "$home" link "$origin" emphasis \
    --url "https://sample.tailnet.invalid/revised-aid" >/dev/null \
    || fail "the supported link backfill could not update an existing hold"
  show=$(tasks_in "$home" show "$hold" --full)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$out" | jq -e --arg hold "$hold" --arg question "$question" '
    .backlog.records[] | select(.id == $hold) | .decision_question == $question
  ' >/dev/null || fail "link backfill overwrote the exact question"
  assert_contains "$show" 'Decision URL: https://sample.tailnet.invalid/revised-aid' \
    "link backfill did not replace the structured URL"
  if run_decisions "$home" link "$origin" emphasis --url "http://public.invalid/not-private" \
    > "$home/http-link.out" 2> "$home/http-link.err"; then
    fail "the decision link interface accepted a non-HTTPS URL"
  fi
  for bad_url in \
    'https://[::::]/aid' \
    'https://captain:secret@sample.invalid/aid' \
    'https://sample.invalid:99999/aid'
  do
    if run_decisions "$home" link "$origin" emphasis --url "$bad_url" \
      > "$home/malformed-link.out" 2> "$home/malformed-link.err"; then
      fail "the decision link interface accepted malformed URL $bad_url"
    fi
  done
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" 'Decision URL: https://sample.tailnet.invalid/revised-aid' \
    "a refused link changed the existing private URL"
  for good_url in \
    'https://decision.example.com./aid' \
    'https://192.0.2.1/aid' \
    'https://[fd00::1]/aid'
  do
    run_decisions "$home" link "$origin" emphasis --url "$good_url" >/dev/null \
      || fail "the decision link interface rejected valid URL $good_url"
  done
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" 'Decision URL: https://[fd00::1]/aid' \
    "valid decision URLs were not preserved exactly"
  pass "exact questions and private HTTPS links use one supported hold interface across homes"
}

# The whole point of separate fields is that a dimension cannot be skipped inside
# a reason blob, so every refusal below is the feature rather than an edge case.
# The surface choice is asserted hardest: an omitted optional flag is exactly what
# produced decisions the captain could not act on.
test_structured_context_is_required_and_stored_separately() {
  local home origin base show out body
  home=$(make_home structured-context)
  origin=sample-structured-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review sample structure" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$origin"
  printf '# Sample structured review\n' > "$home/data/$origin/report.md"
  printf 'done: review complete\n' > "$home/state/$origin.status"
  base=(hold "$origin" shape --title "Choose the sample shape" \
    --reason "captain shape choice pending" --repo sample)

  # Each dimension refuses on its own, and nothing is created by a refusal: a
  # half-made identity would make the honest retry look like a title collision.
  if run_decisions "$home" "${base[@]}" > "$home/no-why.out" 2> "$home/no-why.err"; then
    fail "a decision with no stated reason for needing a call was filed"
  fi
  assert_grep "--why" "$home/no-why.err" "the refusal did not name the missing dimension"
  assert_no_grep "$origin-decision-shape" "$home/data/backlog.md" \
    "a refused filing left a partial backlog identity behind"
  if run_decisions "$home" "${base[@]}" --why "w" \
    > "$home/no-affects.out" 2> "$home/no-affects.err"; then
    fail "a decision with no stated blast radius was filed"
  fi
  assert_grep "--affects" "$home/no-affects.err" "the refusal did not name the missing dimension"
  if run_decisions "$home" "${base[@]}" --why "w" --affects "a" \
    > "$home/no-rec.out" 2> "$home/no-rec.err"; then
    fail "a decision with no recommendation was filed"
  fi
  assert_grep "--recommendation" "$home/no-rec.err" "the refusal did not name the missing dimension"

  # A supplied field must survive the same trimming used by the snapshot and
  # board, or it has not actually addressed its dimension.
  if run_decisions "$home" "${base[@]}" --question " " --why "w" --affects "a" \
    --recommendation "r" --no-surface "none applies" \
    > "$home/blank-question.out" 2> "$home/blank-question.err"; then
    fail "a whitespace-only question was accepted"
  fi
  assert_grep "--question" "$home/blank-question.err" \
    "the whitespace refusal did not name the question flag"
  if run_decisions "$home" "${base[@]}" --why " " --affects "a" \
    --recommendation "r" --no-surface "none applies" \
    > "$home/blank-why.out" 2> "$home/blank-why.err"; then
    fail "a whitespace-only why value was accepted"
  fi
  assert_grep "--why" "$home/blank-why.err" \
    "the whitespace refusal did not name the why flag"
  if run_decisions "$home" "${base[@]}" --why "w" --affects " " \
    --recommendation "r" --no-surface "none applies" \
    > "$home/blank-affects.out" 2> "$home/blank-affects.err"; then
    fail "a whitespace-only affects value was accepted"
  fi
  assert_grep "--affects" "$home/blank-affects.err" \
    "the whitespace refusal did not name the affects flag"
  if run_decisions "$home" "${base[@]}" --why "w" --affects "a" \
    --recommendation " " --no-surface "none applies" \
    > "$home/blank-recommendation.out" 2> "$home/blank-recommendation.err"; then
    fail "a whitespace-only recommendation was accepted"
  fi
  assert_grep "--recommendation" "$home/blank-recommendation.err" \
    "the whitespace refusal did not name the recommendation flag"
  if run_decisions "$home" "${base[@]}" --why "w" --affects "a" \
    --recommendation "r" --no-surface " " \
    > "$home/blank-no-surface.out" 2> "$home/blank-no-surface.err"; then
    fail "a whitespace-only no-surface acknowledgment was accepted"
  fi
  assert_grep "--no-surface" "$home/blank-no-surface.err" \
    "the whitespace refusal did not name the no-surface flag"

  # The surface choice must be conscious, so silence refuses and claiming both
  # refuses. Only an explicit answer either way gets through.
  if run_decisions "$home" "${base[@]}" --why "w" --affects "a" --recommendation "r" \
    > "$home/no-surface.out" 2> "$home/no-surface.err"; then
    fail "the surface choice was silently skippable"
  fi
  assert_grep "--no-surface" "$home/no-surface.err" \
    "the refusal did not offer the explicit no-built-surface acknowledgment"
  if run_decisions "$home" "${base[@]}" --why "w" --affects "a" --recommendation "r" \
    --decision-url "https://sample.tailnet.invalid/aid" --no-surface "none applies" \
    > "$home/both-surface.out" 2> "$home/both-surface.err"; then
    fail "a decision claimed both a built surface and no built surface"
  fi

  run_decisions "$home" "${base[@]}" \
    --why "The sample build stops until the shape is chosen." \
    --affects "The sample header and every sample card under it." \
    --recommendation "Take the compact shape; it survives a narrow screen." \
    --no-surface "Both shapes are text-only, so there is nothing built to compare." \
    >/dev/null || fail "a complete filing was refused"

  # Stored and retrievable as separate fields, not concatenated into the reason.
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$out" | jq -e --arg id "$origin-decision-shape" '
    .backlog.records[] | select(.id == $id)
    | .decision_why == "The sample build stops until the shape is chosen."
      and .decision_affects == "The sample header and every sample card under it."
      and .decision_recommendation == "Take the compact shape; it survives a narrow screen."
      and .decision_no_surface == "Both shapes are text-only, so there is nothing built to compare."
      and .decision_url == null
      and .hold_reason == "captain shape choice pending"
  ' >/dev/null || fail "structured dimensions did not reach the snapshot as separate fields: $out"

  # An idempotent retry supplying nothing must keep the recorded context rather
  # than demanding it be retyped or, worse, blanking it.
  run_decisions "$home" "${base[@]}" >/dev/null \
    || fail "an idempotent retry was refused after the context was already recorded"
  show=$(tasks_in "$home" show "$origin-decision-shape" --full)
  assert_contains "$show" 'Why now: The sample build stops until the shape is chosen.' \
    "an idempotent retry lost the recorded context"

  tasks_in "$home" update "$origin-decision-shape" --body $'Why now:  \t\nWhat it affects: The sample header and every sample card under it.\nRecommendation: Take the compact shape; it survives a narrow screen.\nNo decision surface: Both shapes are text-only, so there is nothing built to compare.' >/dev/null
  if run_decisions "$home" "${base[@]}" \
    > "$home/stored-blank.out" 2> "$home/stored-blank.err"; then
    fail "a whitespace-only stored context field satisfied the presence bar"
  fi
  assert_grep "--why" "$home/stored-blank.err" \
    "the stored whitespace refusal did not name the missing dimension"
  run_decisions "$home" "${base[@]}" \
    --why "The sample build stops until the shape is chosen." >/dev/null \
    || fail "a supplied value could not repair whitespace-only stored context"

  tasks_in "$home" update "$origin-decision-shape" --body $'Why now: The sample build stops until the shape is chosen.\nWhat it affects: The sample header and every sample card under it.\nRecommendation: Take the compact shape; it survives a narrow screen.\nDecision URL: https://sample.tailnet.invalid/stale-aid\nNo decision surface: Both shapes are text-only, so there is nothing built to compare.' >/dev/null
  if run_decisions "$home" "${base[@]}" \
    > "$home/stored-surface-conflict.out" 2> "$home/stored-surface-conflict.err"; then
    fail "contradictory stored surface choices were accepted without settlement"
  fi
  assert_grep "both Decision URL and No decision surface" "$home/stored-surface-conflict.err" \
    "the stored surface conflict was not named"
  assert_grep "--decision-url or --no-surface" "$home/stored-surface-conflict.err" \
    "the stored surface conflict did not explain how to settle it"

  # A decision that gains a built surface must stop claiming it has none, through
  # either supported path, or the board would show a link and a denial together.
  run_decisions "$home" "${base[@]}" --decision-url "https://sample.tailnet.invalid/shape-aid" \
    >/dev/null || fail "a later surface could not be recorded on an existing decision"
  show=$(tasks_in "$home" show "$origin-decision-shape" --full)
  assert_contains "$show" 'Decision URL: https://sample.tailnet.invalid/shape-aid' \
    "the built surface was not recorded"
  assert_not_contains "$show" 'No decision surface:' \
    "a decision kept claiming no built surface after gaining one"
  run_decisions "$home" hold "$origin" shape --title "Choose the sample shape" \
    --reason "captain shape choice pending" --repo sample \
    --no-surface "The surface was withdrawn, so there is nothing to look at again." \
    >/dev/null || fail "a withdrawn surface could not be recorded"
  show=$(tasks_in "$home" show "$origin-decision-shape" --full)
  assert_not_contains "$show" 'Decision URL:' \
    "a decision kept a stale link after declaring no built surface"

  body=$(tasks_in "$home" show "$origin-decision-shape" --full | sed -n 's/^  body: //p')
  case "$body" in
    *'Why now'*'What it affects'*'Recommendation'*) : ;;
    *) fail "the stored dimensions were not written in reading order: $body" ;;
  esac
  pass "each decision dimension is separately required, stored, and retrievable"
}

# A captain-gated thread filed by hand against an existing work item used to skip
# the bar entirely. One owner now covers it, whatever kind the item carries.
test_hold_item_gates_an_existing_work_item_under_the_same_bar() {
  local home show out
  home=$(make_home hold-item)
  tasks_in "$home" add sample-thread "Choose the sample vendor" --kind captain --repo sample >/dev/null
  tasks_in "$home" add sample-queued-ship "Sample ship awaiting a call" --kind ship --repo sample >/dev/null
  tasks_in "$home" add sample-live-ship "Sample ship under way" --kind ship --repo sample --start >/dev/null

  if run_decisions "$home" hold-item sample-thread --reason "captain vendor choice pending" \
    > "$home/bare.out" 2> "$home/bare.err"; then
    fail "the ad-hoc captain-hold path still skipped the due-diligence bar"
  fi
  assert_grep "--why" "$home/bare.err" "the ad-hoc path refused without naming the bar"
  if run_decisions "$home" hold-item sample-absent --reason "captain call" \
    --why w --affects a --recommendation r --no-surface n \
    > "$home/absent.out" 2> "$home/absent.err"; then
    fail "hold-item invented a backlog item that did not exist"
  fi
  # A captain hold leaves an in-flight row in flight, where it never reads as a
  # decision waiting on the captain, so filing one there is refused rather than
  # quietly producing a decision that never reaches the board.
  if run_decisions "$home" hold-item sample-live-ship --reason "captain call" \
    --why w --affects a --recommendation r --no-surface n \
    > "$home/live.out" 2> "$home/live.err"; then
    fail "hold-item filed a decision that could never reach the captain"
  fi

  run_decisions "$home" hold-item sample-thread --reason "captain vendor choice pending" \
    --why "The current vendor stops publishing on 2026-09-01." \
    --affects "Every sample quote and the sample nightly digest." \
    --recommendation "Move to the second vendor; the shapes already match." \
    --decision-url "https://sample.tailnet.invalid/vendor-aid" >/dev/null \
    || fail "hold-item could not gate a standalone captain thread"
  # The HOLD kind, never the kind the item carries itself, is what marks a
  # captain decision, so an ordinary queued ship gates the same way.
  run_decisions "$home" hold-item sample-queued-ship --reason "captain scope choice pending" \
    --why "The sample scope decides how much of the sample ships this week." \
    --affects "The sample checkout path." \
    --recommendation "Ship the narrow scope first." \
    --no-surface "Nothing is built yet; that is what the decision is about." >/dev/null \
    || fail "hold-item could not gate a queued item of another kind"

  show=$(tasks_in "$home" show sample-queued-ship --full)
  assert_contains "$show" "kind: ship" "hold-item rewrote the kind the item already carried"
  assert_contains "$show" "hold_kind: captain" "hold-item did not activate the captain hold"
  assert_contains "$show" "title: Sample ship awaiting a call" "hold-item rewrote the item title"

  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$out" | jq -e '
    ([ .backlog.records[] | select(.captain_actionable == true) ] | length) == 2
    and ([ .backlog.records[] | select(.id == "sample-queued-ship")
           | .kind == "ship"
             and .decision_why == "The sample scope decides how much of the sample ships this week."
             and .decision_no_surface == "Nothing is built yet; that is what the decision is about." ]
         | all)
    and ([ .backlog.records[] | select(.id == "sample-thread")
           | .decision_url == "https://sample.tailnet.invalid/vendor-aid" ] | all)
  ' >/dev/null || fail "a gated item of another kind did not reach the snapshot as a decision: $out"

  # hold-item records context and the hold, nothing else. The inventory that
  # `complete`, `verify`, and scout teardown read stays untouched, so gating an
  # ordinary work item can never be mistaken for a completed review pass.
  assert_no_grep "decisions_reviewed" "$home/data/backlog.md" \
    "hold-item wrote inventory attestation into the backlog"
  [ ! -f "$home/state/sample-thread.meta" ] \
    || fail "hold-item created originating task metadata for a plain backlog item"
  pass "an existing work item of any kind is gated under the same due-diligence bar"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_archived_resolved_decision_satisfies_the_gate
test_archive_lookup_refuses_every_unresolved_shape
test_structured_holds_survive_teardown_and_route_resolution
test_decision_question_and_private_link_use_the_supported_hold_interface
test_structured_context_is_required_and_stored_separately
test_hold_item_gates_an_existing_work_item_under_the_same_bar
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_duplicate_decision_key_retraction_unstrands_teardown
