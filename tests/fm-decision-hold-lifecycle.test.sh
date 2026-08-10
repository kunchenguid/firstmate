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

  if run_decisions "$home" complete "$id" route access --no-ideas > "$home/early-complete.out" 2> "$home/early-complete.err"; then
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
  if run_decisions "$home" complete "$id" route access --no-ideas > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
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

  run_decisions "$home" complete "$id" route access --no-ideas >/dev/null \
    || fail "shared investigation completion gate failed"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  assert_grep "ideas_reviewed=1" "$home/state/$id.meta" "no-idea attestation missing"
  run_decisions "$home" complete "$id" route --no-ideas >/dev/null \
    || fail "idempotent completion retry failed"
  [ "$(grep '^decision_keys=' "$home/state/$id.meta" | tail -1)" = "decision_keys=access,route" ] \
    || fail "completion retry did not preserve the unioned decision inventory"
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
  if run_decisions "$home" complete ../escaped-origin --none --no-ideas \
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
  run_decisions "$home" complete "$id" --none --no-ideas >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout --no-ideas >/dev/null \
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
  run_decisions "$home" complete "$id" --none --no-ideas >/dev/null \
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
  run_decisions "$home" complete "$id" --none --no-ideas >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none --no-ideas \
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
  run_decisions "$mate" complete "$origin" release --no-ideas >/dev/null \
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

test_product_idea_attestation_contract() {
  local home origin grandfather absent wrong matching shapes private private_origin private_mode private_dir_mode
  home=$(make_home idea-attestation)
  origin=sample-idea-review
  mkdir -p "$home/data/$origin"
  write_origin_meta "$home" "$origin"
  printf '# Sample idea review\n\n## Ideas\nA useful product idea.\n' > "$home/data/$origin/report.md"

  if run_decisions "$home" complete "$origin" --none > "$home/missing.out" 2> "$home/missing.err"; then
    fail "completion succeeded without the required idea attestation"
  fi
  assert_grep "idea attestation is required" "$home/missing.err" \
    "missing idea attestation did not name the requirement"
  if run_decisions "$home" complete "$origin" --none route --no-ideas \
    > "$home/decision-combo.out" 2> "$home/decision-combo.err"; then
    fail "--none combined with a decision key"
  fi
  assert_grep "--none cannot be combined" "$home/decision-combo.err" \
    "invalid decision combination was not explained"
  if run_decisions "$home" complete "$origin" --none --no-ideas PI-001 \
    > "$home/idea-combo.out" 2> "$home/idea-combo.err"; then
    fail "--no-ideas accepted an idea id"
  fi
  assert_grep "--no-ideas must follow" "$home/idea-combo.err" \
    "invalid idea combination was not explained"
  if run_decisions "$home" complete "$origin" --none --ideas \
    > "$home/empty-ideas.out" 2> "$home/empty-ideas.err"; then
    fail "--ideas accepted an empty id inventory"
  fi
  assert_grep "--ideas requires at least one" "$home/empty-ideas.err" \
    "empty --ideas inventory was not explained"
  if run_decisions "$home" complete "$origin" --none --ideas PI-001 --no-ideas \
    > "$home/mixed-ideas.out" 2> "$home/mixed-ideas.err"; then
    fail "--ideas combined with --no-ideas"
  fi
  assert_grep "--ideas cannot be combined with --no-ideas" "$home/mixed-ideas.err" \
    "mixed idea attestations were not explained"

  run_decisions "$home" complete "$origin" --none --no-ideas >/dev/null \
    || fail "explicit no-idea attestation failed"
  assert_present "$home/data/product-ideas.md" "no-idea completion did not create the ledger lazily"
  assert_grep "Status: unscheduled | parked (captain <date>) | scheduled -> <task-id>" \
    "$home/data/product-ideas.md" "lazy ledger template did not define the status contract"
  assert_grep "ideas_reviewed=1" "$home/state/$origin.meta" "idea review marker was not persisted"
  assert_grep "idea_ids=" "$home/state/$origin.meta" "empty idea id inventory was not persisted"
  run_decisions "$home" verify "$origin" >/dev/null || fail "no-idea completion did not verify"

  private=$(make_home private-idea-ledger)
  private_origin='private-ledger-review'
  rm -rf "$private/data"
  write_origin_meta "$private" "$private_origin"
  ( umask 000
    run_decisions "$private" complete "$private_origin" --none --no-ideas >/dev/null
  ) || fail "private ledger creation failed under a permissive caller umask"
  # Platform-detect stat(1): GNU treats -f as --file-system and can emit a dump
  # before failing, so never use the `stat -f || stat -c` fallback here.
  if [ "$(uname)" = Darwin ]; then
    private_mode=$(stat -f %Lp "$private/data/product-ideas.md")
    private_dir_mode=$(stat -f %Lp "$private/data")
  else
    private_mode=$(stat -c %a "$private/data/product-ideas.md")
    private_dir_mode=$(stat -c %a "$private/data")
  fi
  [ "$private_mode" = 600 ] \
    || fail "lazy ledger was not private under permissive umask: $private_mode"
  [ "$private_dir_mode" = 700 ] \
    || fail "lazy data dir was not private under permissive umask: $private_dir_mode"

  cat >> "$home/data/product-ideas.md" <<EOF
| PI-001 | Add a sample route preview | unscheduled | data/$origin/report.md#Ideas |
| PI-002 | Add a sample route comparison | parked (captain 2026-08-10) | data/$origin/report.md#Ideas |
EOF
  run_decisions "$home" complete "$origin" --none --ideas PI-001 >/dev/null \
    || fail "matching idea row did not pass completion"
  run_decisions "$home" complete "$origin" --none --ideas PI-002 >/dev/null \
    || fail "idempotent idea re-completion failed"
  [ "$(grep '^idea_ids=' "$home/state/$origin.meta" | tail -1)" = "idea_ids=PI-001,PI-002" ] \
    || fail "idea re-completion did not preserve the unioned inventory"
  run_decisions "$home" verify "$origin" >/dev/null || fail "persisted idea inventory did not verify"

  absent=$(make_home absent-idea-ledger)
  mkdir -p "$absent/data/$origin"
  write_origin_meta "$absent" "$origin"
  printf '# Report\n\n## Ideas\nMissing ledger.\n' > "$absent/data/$origin/report.md"
  if run_decisions "$absent" complete "$origin" --none --ideas PI-001 \
    > "$absent/absent.out" 2> "$absent/absent.err"; then
    fail "named idea passed with no ledger"
  fi
  assert_grep "product idea ledger is absent" "$absent/absent.err" \
    "absent ledger failure did not name the requirement"

  matching=$(make_home missing-idea-row)
  mkdir -p "$matching/data/$origin"
  write_origin_meta "$matching" "$origin"
  printf '# Report\n\n## Ideas\nMissing row.\n' > "$matching/data/$origin/report.md"
  run_decisions "$matching" complete "$origin" --none --no-ideas >/dev/null
  if run_decisions "$matching" complete "$origin" --none --ideas PI-009 \
    > "$matching/missing-row.out" 2> "$matching/missing-row.err"; then
    fail "named idea passed without its row"
  fi
  assert_grep "product idea PI-009 is missing" "$matching/missing-row.err" \
    "missing idea row failure was not explicit"

  wrong=$(make_home wrong-idea-source)
  mkdir -p "$wrong/data/$origin"
  write_origin_meta "$wrong" "$origin"
  printf '# Report\n\n## Ideas\nWrong source.\n' > "$wrong/data/$origin/report.md"
  run_decisions "$wrong" complete "$origin" --none --no-ideas >/dev/null
  printf '| PI-001 | Wrongly sourced idea | unscheduled | data/another-review/report.md#Ideas |\n' \
    >> "$wrong/data/product-ideas.md"
  if run_decisions "$wrong" complete "$origin" --none --ideas PI-001 \
    > "$wrong/wrong-source.out" 2> "$wrong/wrong-source.err"; then
    fail "idea row citing another origin passed"
  fi
  assert_grep "must have one well-formed row whose Source cites data/$origin/report.md" "$wrong/wrong-source.err" \
    "wrong idea source failure did not name the origin-bound requirement"

  shapes=$(make_home invalid-idea-shapes)
  mkdir -p "$shapes/data/$origin"
  write_origin_meta "$shapes" "$origin"
  printf '# Report\n\n## Ideas\nShape cases.\n' > "$shapes/data/$origin/report.md"
  run_decisions "$shapes" complete "$origin" --none --no-ideas >/dev/null
  cp "$shapes/data/product-ideas.md" "$shapes/ledger-template.md"
  printf '| PI-001 |  | unscheduled | data/%s/report.md#Ideas |\n' "$origin" \
    >> "$shapes/data/product-ideas.md"
  if run_decisions "$shapes" complete "$origin" --none --ideas PI-001 \
    > "$shapes/empty-idea.out" 2> "$shapes/empty-idea.err"; then
    fail "empty idea text passed completion"
  fi
  assert_grep "must have one well-formed row" "$shapes/empty-idea.err" \
    "empty idea text failure was not explicit"
  cp "$shapes/ledger-template.md" "$shapes/data/product-ideas.md"
  printf '| PI-001 | Idea with bad status | pending | data/%s/report.md#Ideas |\n' "$origin" \
    >> "$shapes/data/product-ideas.md"
  if run_decisions "$shapes" complete "$origin" --none --ideas PI-001 \
    > "$shapes/bad-status.out" 2> "$shapes/bad-status.err"; then
    fail "non-contract status passed completion"
  fi
  assert_grep "must have one well-formed row" "$shapes/bad-status.err" \
    "invalid status failure was not explicit"
  cp "$shapes/ledger-template.md" "$shapes/data/product-ideas.md"
  printf '| PI-001 | Idea with spaced heading | unscheduled | data/%s/report.md# Ideas |\n' "$origin" \
    >> "$shapes/data/product-ideas.md"
  if run_decisions "$shapes" complete "$origin" --none --ideas PI-001 \
    > "$shapes/bad-source.out" 2> "$shapes/bad-source.err"; then
    fail "source with space after # passed completion"
  fi
  assert_grep "must have one well-formed row" "$shapes/bad-source.err" \
    "invalid source shape failure was not explicit"
  cp "$shapes/ledger-template.md" "$shapes/data/product-ideas.md"
  printf '| PI-001 | Idea with GitHub line pointer | unscheduled | data/%s/report.md#L12 |\n' "$origin" \
    >> "$shapes/data/product-ideas.md"
  if run_decisions "$shapes" complete "$origin" --none --ideas PI-001 \
    > "$shapes/line-source.out" 2> "$shapes/line-source.err"; then
    fail "source with #L12 line pointer passed completion"
  fi
  assert_grep "must have one well-formed row" "$shapes/line-source.err" \
    "line-number source failure was not explicit"
  cp "$shapes/ledger-template.md" "$shapes/data/product-ideas.md"
  printf '| PI-001 | Idea with bare numeric pointer | unscheduled | data/%s/report.md#12 |\n' "$origin" \
    >> "$shapes/data/product-ideas.md"
  if run_decisions "$shapes" complete "$origin" --none --ideas PI-001 \
    > "$shapes/bare-line-source.out" 2> "$shapes/bare-line-source.err"; then
    fail "source with bare #12 line pointer passed completion"
  fi
  assert_grep "must have one well-formed row" "$shapes/bare-line-source.err" \
    "bare line-number source failure was not explicit"
  cp "$shapes/ledger-template.md" "$shapes/data/product-ideas.md"
  printf '| PI-001 | Idea with line range pointer | unscheduled | data/%s/report.md#L12-L20 |\n' "$origin" \
    >> "$shapes/data/product-ideas.md"
  if run_decisions "$shapes" complete "$origin" --none --ideas PI-001 \
    > "$shapes/line-range-source.out" 2> "$shapes/line-range-source.err"; then
    fail "source with #L12-L20 line range passed completion"
  fi
  assert_grep "must have one well-formed row" "$shapes/line-range-source.err" \
    "line-range source failure was not explicit"
  cp "$shapes/ledger-template.md" "$shapes/data/product-ideas.md"
  printf '| PI-001 | Idea with terminal colon line pointer | unscheduled | data/%s/report.md#Ideas:12 |\n' "$origin" \
    >> "$shapes/data/product-ideas.md"
  if run_decisions "$shapes" complete "$origin" --none --ideas PI-001 \
    > "$shapes/colon-line-source.out" 2> "$shapes/colon-line-source.err"; then
    fail "source with terminal #Ideas:12 line pointer passed completion"
  fi
  assert_grep "must have one well-formed row" "$shapes/colon-line-source.err" \
    "terminal colon line-number source failure was not explicit"
  cp "$shapes/ledger-template.md" "$shapes/data/product-ideas.md"
  printf '| PI-001 | Idea under quarterly heading | unscheduled | data/%s/report.md#Q2:2026-plan |\n' "$origin" \
    >> "$shapes/data/product-ideas.md"
  run_decisions "$shapes" complete "$origin" --none --ideas PI-001 >/dev/null \
    || fail "origin-bound source with #Q2:2026-plan heading was refused"
  cp "$shapes/ledger-template.md" "$shapes/data/product-ideas.md"
  printf '| PI-001 | Idea under phased heading | unscheduled | data/%s/report.md#Phase:1-rollout |\n' "$origin" \
    >> "$shapes/data/product-ideas.md"
  run_decisions "$shapes" complete "$origin" --none --ideas PI-001 >/dev/null \
    || fail "origin-bound source with #Phase:1-rollout heading was refused"
  cp "$shapes/ledger-template.md" "$shapes/data/product-ideas.md"
  printf '| PI-001 | Good target idea | unscheduled | data/%s/report.md#Ideas |\n' "$origin" \
    >> "$shapes/data/product-ideas.md"
  printf '| PI-002 | Sibling with bad status | pending | data/%s/report.md#Ideas |\n' "$origin" \
    >> "$shapes/data/product-ideas.md"
  if run_decisions "$shapes" complete "$origin" --none --ideas PI-001 \
    > "$shapes/sibling-bad.out" 2> "$shapes/sibling-bad.err"; then
    fail "well-formed target row hid a malformed sibling"
  fi
  assert_grep "must have one well-formed row" "$shapes/sibling-bad.err" \
    "malformed sibling failure was not explicit"
  cp "$shapes/ledger-template.md" "$shapes/data/product-ideas.md"
  printf '| PI-001 | Good target idea | unscheduled | data/%s/report.md#Ideas |\n' "$origin" \
    >> "$shapes/data/product-ideas.md"
  printf 'not a table row\n' >> "$shapes/data/product-ideas.md"
  if run_decisions "$shapes" complete "$origin" --none --ideas PI-001 \
    > "$shapes/junk-line.out" 2> "$shapes/junk-line.err"; then
    fail "well-formed target row hid non-table junk"
  fi
  assert_grep "must have one well-formed row" "$shapes/junk-line.err" \
    "junk-line ledger failure was not explicit"
  printf '# Product ideas\n\n| PI-001 | Headerless good idea | unscheduled | data/%s/report.md#Ideas |\n' \
    "$origin" > "$shapes/data/product-ideas.md"
  if run_decisions "$shapes" complete "$origin" --none --ideas PI-001 \
    > "$shapes/headerless.out" 2> "$shapes/headerless.err"; then
    fail "headerless ledger with a good target row passed completion"
  fi
  assert_grep "must have one well-formed row" "$shapes/headerless.err" \
    "headerless ledger failure was not explicit"

  grandfather=$(make_home grandfathered-idea-gate)
  write_origin_meta "$grandfather" pre-upgrade-review
  printf 'decisions_reviewed=1\ndecision_keys=\n' >> "$grandfather/state/pre-upgrade-review.meta"
  run_decisions "$grandfather" verify pre-upgrade-review >/dev/null \
    || fail "pre-upgrade decision completion was not grandfathered"
  assert_absent "$grandfather/data/product-ideas.md" \
    "grandfathered verification unexpectedly created a ledger"

  pass "product idea attestations are origin-bound, persisted, idempotent, lazy, and grandfather-safe"
}

test_secondmate_idea_inventory_and_bearings_count() {
  local main mate origin json template
  main=$(make_home idea-count-main)
  mate=$(make_home idea-count-mate)
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  origin=sample-mate-ideas
  mkdir -p "$mate/data/$origin"
  write_origin_meta "$mate" "$origin"
  printf '# Mate report\n\n## Product ideas\nMate idea detail.\n' > "$mate/data/$origin/report.md"
  run_decisions "$mate" complete "$origin" --none --no-ideas >/dev/null
  printf '| PI-003 | Mate-only sample idea | unscheduled | data/%s/report.md#Product-ideas |\n' "$origin" \
    >> "$mate/data/product-ideas.md"
  run_decisions "$mate" complete "$origin" --none --ideas PI-003 >/dev/null \
    || fail "secondmate-home idea did not verify against its own ledger"
  assert_absent "$main/data/product-ideas.md" "secondmate idea leaked into the main ledger"

  mkdir -p "$main/data/main-idea-review"
  write_origin_meta "$main" main-idea-review
  printf '# Main report\n\n## Ideas\nMain idea detail.\n' > "$main/data/main-idea-review/report.md"
  run_decisions "$main" complete main-idea-review --none --no-ideas >/dev/null
  printf '| PI-001 | Main sample idea | unscheduled | data/main-idea-review/report.md#Ideas |\n' \
    >> "$main/data/product-ideas.md"
  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$main/data/secondmates.md"
  fm_write_secondmate_meta "$main/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample

  json=$(run_bearings "$main") || fail "Bearings could not count home idea ledgers"
  printf '%s' "$json" | jq -e '.ideas_unscheduled == 2 and (.ideas_warnings | length) == 0' >/dev/null \
    || fail "Bearings did not combine readable home idea counts: $json"

  template="$main/product-ideas-template.md"
  cp "$main/data/product-ideas.md" "$template"
  printf 'not a product idea ledger\n' > "$main/data/product-ideas.md"
  json=$(run_bearings "$main") || fail "Bearings crashed on a malformed idea ledger"
  printf '%s' "$json" | jq -e '
    .ideas_unscheduled == 1
      and (.ideas_warnings | any(.home == "(main)" and .reason == "ledger is malformed"))
  ' >/dev/null || fail "Bearings silently counted a malformed ledger as zero: $json"

  cp "$template" "$main/data/product-ideas.md"
  chmod 000 "$mate/data/product-ideas.md"
  json=$(run_bearings "$main") || fail "Bearings crashed on an unreadable idea ledger"
  printf '%s' "$json" | jq -e '
    .ideas_unscheduled == 1
      and (.ideas_warnings | any(.home == "sample-mate" and .reason == "ledger is unreadable"))
  ' >/dev/null || fail "Bearings silently counted an unreadable ledger as zero: $json"
  chmod 600 "$mate/data/product-ideas.md"

  chmod 000 "$main/data/secondmates.md"
  json=$(run_bearings "$main") || fail "Bearings crashed when the secondmate registry was unreadable"
  printf '%s' "$json" | jq -e '
    (.ideas_warnings | any(.home == "(registry)" and (.reason | startswith("registry unavailable:"))))
  ' >/dev/null || fail "Bearings hid an unavailable registry from ideas_warnings: $json"
  chmod 600 "$main/data/secondmates.md"

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$main/data/secondmates.md"
  printf -- '- extra-mate - synthetic scope (home: %s; scope: more reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" >> "$main/data/secondmates.md"
  json=$(FM_SNAPSHOT_REGISTRY_RECORDS=1 PATH="$main/fakebin:$PATH" FM_HOME="$main" \
    FM_BEARINGS_NOW=2026-07-14T12:00:00Z "$BEARINGS" --json) \
    || fail "Bearings crashed when registry records were truncated"
  printf '%s' "$json" | jq -e '
    (.ideas_warnings | any(.home == "(registry)" and .reason == "registry records were truncated"))
  ' >/dev/null || fail "Bearings hid truncated registry records from ideas_warnings: $json"

  json=$(FM_SNAPSHOT_REGISTRY_LINES=1 PATH="$main/fakebin:$PATH" FM_HOME="$main" \
    FM_BEARINGS_NOW=2026-07-14T12:00:00Z "$BEARINGS" --json) \
    || fail "Bearings crashed when registry input was truncated"
  printf '%s' "$json" | jq -e '
    (.ideas_warnings | any(.home == "(registry)" and .reason == "registry input was truncated"))
  ' >/dev/null || fail "Bearings hid truncated registry input from ideas_warnings: $json"

  override=$(make_home idea-data-override)
  alt_data="$override/alt-data"
  mkdir -p "$alt_data" "$override/data"
  cat > "$alt_data/product-ideas.md" <<'EOF'
# Product ideas

| ID | Idea | Status | Source |
| --- | --- | --- | --- |
| PI-007 | Override-only idea | unscheduled | data/main-idea-review/report.md#Ideas |
EOF
  cat > "$override/data/product-ideas.md" <<'EOF'
# Product ideas

| ID | Idea | Status | Source |
| --- | --- | --- | --- |
| PI-008 | Default-path decoy | unscheduled | data/main-idea-review/report.md#Ideas |
| PI-009 | Second default-path decoy | unscheduled | data/main-idea-review/report.md#Ideas |
EOF
  json=$(PATH="$override/fakebin:$PATH" FM_HOME="$override" FM_DATA_OVERRIDE="$alt_data" \
    FM_BEARINGS_NOW=2026-07-14T12:00:00Z "$BEARINGS" --json) \
    || fail "Bearings crashed with FM_DATA_OVERRIDE for the main idea ledger"
  printf '%s' "$json" | jq -e '.ideas_unscheduled == 1' >/dev/null \
    || fail "Bearings ignored roots.data for the main idea ledger: $json"

  pass "secondmate ideas stay home-local and Bearings discloses complete and incomplete counts"
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
test_product_idea_attestation_contract
test_secondmate_idea_inventory_and_bearings_count
