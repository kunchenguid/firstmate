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

# The Lavish review adapter, run against this suite's isolated home. The
# machine-wide process-event claim root is redirected into the fixture so arming
# a review here can never contend with a real one on this machine.
run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
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

run_decisions_now() {  # <home> <today> <command args...>
  local home=$1 now=$2
  shift 2
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DECISION_NOW="$now" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# Backdate one queued row's registration date, which is what tasks-axi reports as
# its created date and what the ageing threshold is measured from.
set_since() {  # <home> <id> <date>
  local home=$1 id=$2 date=$3
  sed "/^- \[ \] $id - /s/(since [0-9][0-9-]*)/(since $date)/" \
    "$home/data/backlog.md" > "$home/backlog.since"
  mv "$home/backlog.since" "$home/data/backlog.md"
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

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    sig=$(fm_wake_signal_sig "$3") || exit 1
    printf "%s" "$sig" > "$(fm_wake_signal_seen_path "$2" "$3")"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
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
  first=sample-handbook-review
  second=sample-handbook-audit
  mkdir -p "$home/data/$first" "$home/data/$second"
  printf '# first pass\n' > "$home/data/$first/report.md"
  printf '# second pass\n' > "$home/data/$second/report.md"
  write_origin_meta "$home" "$first"
  write_origin_meta "$home" "$second"

  run_decisions "$home" hold "$first" handbook-authority \
    --title "Which handbook is authoritative for the coding rules" \
    --reason "standing policy choice" --repo sample >/dev/null \
    || fail "could not register the first-pass decision"

  # The second pass asks the same question under its own key.
  set +e
  run_decisions "$home" hold "$second" canonical-handbook \
    --title "Which text is canonical for the coding rules" \
    --reason "same authority question" --repo sample \
    > "$home/dup.out" 2> "$home/dup.err"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a same-subject duplicate registered without review (exit $rc)"
  assert_grep "$first-decision-handbook-authority" "$home/dup.err" \
    "the refusal must put the open decision set in front of the agent"
  assert_grep "fold" "$home/dup.err" "the refusal must offer folding as the first-class alternative"
  ! grep -F -- "$second-decision-canonical-handbook" "$home/data/backlog.md" >/dev/null \
    || fail "the refused duplicate still reached the backlog"

  # Folding records the finding on the decision that already owns the question.
  run_decisions "$home" fold "$second" --into "$first-decision-handbook-authority" \
    --note "the audit pass reaches the same question" >/dev/null \
    || fail "could not fold the second pass into the open decision"
  run_decisions "$home" fold "$second" --into "$first-decision-handbook-authority" \
    --note "the audit pass reaches the same question" >/dev/null \
    || fail "folding the same finding twice must be idempotent"
  [ "$(grep -cE "^- \[ \] .*-decision-.* -" "$home/data/backlog.md")" = 1 ] \
    || fail "folding created a second captain decision"
  show=$(tasks_in "$home" show "$first-decision-handbook-authority" --full)
  assert_contains "$show" "Also raised by $second" \
    "the folded finding must be durable on the decision that owns the question"
  assert_grep "decision_folds=$first-decision-handbook-authority" "$home/state/$second.meta" \
    "the fold must be recorded against the origin that found it"

  # The completion gate stays intact: --none would be a false attestation.
  if run_decisions "$home" complete "$second" --none > "$home/none.out" 2> "$home/none.err"; then
    fail "--none passed while the origin had folded a real unresolved decision"
  fi
  assert_grep "contradicts the folds" "$home/none.err" \
    "the refusal must name the folds it contradicts"
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
  run_decisions "$home" hold "$first" handbook-authority \
    --title "Which handbook is authoritative for the coding rules" \
    --reason "standing policy choice" --repo sample >/dev/null \
    || fail "an exact-key retry must stay idempotent and ungated"

  open_out=$(run_decisions "$home" open) || fail "open listing failed"
  assert_contains "$open_out" "open captain decisions in" "open must report the current set"
  assert_contains "$open_out" "$first-decision-handbook-authority" "open must list the folded-into decision"

  # The listing must cite only decisions the captain can actually see, so an
  # unresolved blocker removes a decision here exactly as it does in Bearings.
  tasks_in "$home" add sample-prerequisite "Land the prerequisite first" --kind ship --repo sample >/dev/null \
    || fail "could not create the blocking prerequisite"
  tasks_in "$home" block "$first-decision-handbook-authority" --by sample-prerequisite >/dev/null \
    || fail "could not block the decision by its prerequisite"
  open_out=$(run_decisions "$home" open) || fail "open listing failed while a decision was blocked"
  case "$open_out" in
    *"$first-decision-handbook-authority"*)
      fail "open listed a blocked decision the fleet view does not show as actionable" ;;
  esac
  tasks_in "$home" unblock "$first-decision-handbook-authority" --by sample-prerequisite >/dev/null \
    || fail "could not clear the prerequisite edge"
  open_out=$(run_decisions "$home" open) || fail "open listing failed after unblocking"
  assert_contains "$open_out" "$first-decision-handbook-authority" \
    "clearing the blocker must return the decision to the actionable listing"
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
    --title "Bound the retry budget or fail fast" --reason "captain policy call" --repo sample) \
    || fail "could not register the decision"
  tasks_in "$home" update "$hold" --body \
    "CLOSED as ALREADY ANSWERED - the captain settled this on 2026-01-05 under key retry-budget." >/dev/null \
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
  if run_decisions "$home" resolve "$origin" merge-order \
    --decision "Firstmate decided: land the schema change first; the evidence settles it." \
    --decided-by captain --no-routed-work > "$home/attr.out" 2> "$home/attr.err"; then
    fail "a retry reattributing the same answer to the captain reported success"
  fi
  assert_grep "different decider" "$home/attr.err" \
    "attribution must be part of the retry identity, not outside it"
  run_decisions "$home" complete "$origin" merge-order >/dev/null \
    || fail "a firstmate-decided closure must satisfy the completion gate"
  pass "a firstmate-decided closure is first-class and attributed honestly"
}

# Folding records a finding against the decision that already owns the question and
# says nothing about the live status log. Sign-off is the single owner of that
# accounting: every open entry must be named, either by its own key or as carried by
# a recorded fold, and the mixed pass - one genuinely new question plus one folded
# duplicate - must be expressible without inverting the documented order.
test_status_accounting_is_owned_by_sign_off() {
  local home owner origin hold
  home=$(make_home folded-status)
  owner=sample-policy-review
  origin=sample-policy-audit
  mkdir -p "$home/data/$owner" "$home/data/$origin"
  printf '# owner\n' > "$home/data/$owner/report.md"
  printf '# audit\n' > "$home/data/$origin/report.md"
  write_origin_meta "$home" "$owner"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$owner" retention-window \
    --title "How long should sample records be retained" \
    --reason "policy the captain owns" --repo sample) \
    || fail "could not register the owning decision"

  # The audit's crewmate left two live questions: one this pass judges a duplicate
  # of the open decision, one that is genuinely its own new captain question.
  printf 'working: auditing retention\n' > "$home/state/$origin.status"
  printf 'needs-decision [key=retention-span]: how long are sample records retained\n' \
    >> "$home/state/$origin.status"
  printf 'needs-decision [key=export-shape]: which export shape is authoritative\n' \
    >> "$home/state/$origin.status"

  run_decisions "$home" fold "$origin" --into "$hold" \
    --note "the audit pass reaches the same retention question" >/dev/null \
    || fail "could not fold the duplicate finding into the owning decision"
  assert_no_grep "captain-held" "$home/state/$origin.status" \
    "folding must not touch the origin status log"
  assert_grep "decision_folds=$hold" "$home/state/$origin.meta" \
    "the fold must be recorded in the origin metadata"
  run_decisions "$home" fold "$origin" --into "$hold" \
    --note "the audit pass reaches the same retention question" >/dev/null \
    || fail "repeating the fold must stay idempotent"
  [ "$(grep -cF "decision_folds=$hold" "$home/state/$origin.meta")" = 1 ] \
    || fail "repeating the fold recorded the same fold twice"

  # The genuinely new question gets its own captain decision.
  run_decisions "$home" hold "$origin" export-shape \
    --title "Which export shape is authoritative" \
    --reason "format the captain owns" --repo sample --distinct >/dev/null \
    || fail "could not register the genuinely new question"

  # Sign-off that leaves either entry unnamed is refused, whatever else it names.
  if run_decisions "$home" complete "$origin" --folded \
    > "$home/unnamed.out" 2> "$home/unnamed.err"; then
    fail "a fold attestation alone accounted for entries the caller never named"
  fi
  assert_grep "unaccounted for" "$home/unnamed.err" \
    "the refusal must say the entry is unaccounted for"
  if run_decisions "$home" complete "$origin" export-shape \
    > "$home/half.out" 2> "$home/half.err"; then
    fail "an entry carried only by a fold passed without being named"
  fi
  assert_grep "retention-span" "$home/half.err" "the refusal must name the unaccounted entry"
  if run_decisions "$home" complete "$origin" --none \
    > "$home/none.out" 2> "$home/none.err"; then
    fail "--none passed while a fold was recorded"
  fi
  assert_grep "contradicts the folds" "$home/none.err" \
    "--none must stay refused while any fold is recorded"
  if run_decisions "$home" complete "$origin" --folded-key not-a-live-question \
    > "$home/ghost.out" 2> "$home/ghost.err"; then
    fail "a key that was never open was attested away as folded"
  fi
  assert_grep "no open structured decision under key not-a-live-question" \
    "$home/ghost.err" "the refusal must name the key that was never open"
  assert_no_grep "captain-held" "$home/state/$origin.status" \
    "a refused sign-off must not transfer any status decision"

  # The mixed pass in one call: own key for the new question, --folded-key for the
  # entry the recorded fold carries.
  run_decisions "$home" complete "$origin" export-shape --folded-key retention-span >/dev/null \
    || fail "the mixed pass must be expressible in one sign-off"
  assert_grep "captain-held [key=export-shape]: tracked by $origin-decision-export-shape" \
    "$home/state/$origin.status" "a supplied key must be transferred to this origin's own hold"
  assert_grep "captain-held [key=retention-span]: tracked by $hold" \
    "$home/state/$origin.status" "a folded key must be transferred to the decision that carries it"
  assert_grep "decision_folded_keys=retention-span" "$home/state/$origin.meta" \
    "sign-off must record which entries a fold accounted for"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "teardown verification must accept the accounted-for inventory"
  run_decisions "$home" complete "$origin" export-shape --folded-key retention-span >/dev/null \
    || fail "re-running the same sign-off must stay idempotent"
  [ "$(grep -cF "captain-held [key=retention-span]: tracked by $hold" "$home/state/$origin.status")" = 1 ] \
    || fail "re-running sign-off duplicated the folded transfer"
  [ "$(grep -cE '^- \[ \] .*-decision-.* -' "$home/data/backlog.md")" = 2 ] \
    || fail "accounting for the folded entry created an extra captain decision"
  pass "sign-off owns status accounting and the mixed fold-and-register pass works"
}

# The shape this policy is most often invoked on: the investigation has finished, so
# its status stream ends in a terminal event and no entry is open. Folding must work
# there with nothing to name, and sign-off must accept the fold attestation alone.
test_fold_on_a_finished_investigation_needs_no_accounting() {
  local home owner origin hold
  home=$(make_home finished-fold)
  owner=sample-owning-pass
  origin=sample-finished-pass
  mkdir -p "$home/data/$owner" "$home/data/$origin"
  printf '# owner\n' > "$home/data/$owner/report.md"
  printf '# finished\n' > "$home/data/$origin/report.md"
  write_origin_meta "$home" "$owner"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$owner" ordering-rule \
    --title "Which ordering rule is authoritative" \
    --reason "policy the captain owns" --repo sample) \
    || fail "could not register the owning decision"
  printf 'needs-decision: which ordering rule is authoritative\ndone: report complete\n' \
    > "$home/state/$origin.status"

  run_decisions "$home" fold "$origin" --into "$hold" \
    --note "the finished pass reaches the same ordering question" >/dev/null \
    || fail "folding on a finished investigation must not require anything to name"
  run_decisions "$home" complete "$origin" --folded >/dev/null \
    || fail "a fold attestation must satisfy sign-off when no entry is open"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "teardown verification must accept a finished folded pass"
  assert_no_grep "captain-held" "$home/state/$origin.status" \
    "nothing was open, so nothing may be transferred"
  pass "folding a finished investigation needs no status accounting"
}

# The threshold is inclusive, and both day-boundary reads are anchored at midnight,
# so a decision at exactly FM_DECISION_AGING_DAYS cannot lose a day and drop out of
# the set that resurfaces on its own.
test_decision_at_exactly_the_ageing_threshold_is_ageing() {
  local home origin at_threshold below out
  home=$(make_home ageing-threshold)
  origin=sample-threshold-review
  mkdir -p "$home/data/$origin"
  printf '# threshold\n' > "$home/data/$origin/report.md"
  write_origin_meta "$home" "$origin"
  at_threshold=$(run_decisions "$home" hold "$origin" cutover-date \
    --title "Which cutover date is authoritative" \
    --reason "schedule the captain owns" --repo sample) \
    || fail "could not register the threshold decision"
  below=$(run_decisions "$home" hold "$origin" rollout-shape \
    --title "Which rollout shape should be used" \
    --reason "shape the captain owns" --repo sample --distinct) \
    || fail "could not register the younger decision"
  set_since "$home" "$at_threshold" 2026-07-23
  set_since "$home" "$below" 2026-07-24

  out=$(run_decisions_now "$home" 2026-07-26 open --aging-only) \
    || fail "the ageing listing failed"
  assert_contains "$out" "$at_threshold" \
    "a decision at exactly the threshold must be reported as ageing"
  assert_contains "$out" "waiting 3 days" \
    "the age at the threshold must be reported as the whole days waited"
  case "$out" in
    *"$below"*) fail "a decision below the threshold leaked into the ageing set" ;;
  esac

  out=$(run_decisions_now "$home" 2026-07-25 open --aging-only) \
    || fail "the ageing listing failed one day earlier"
  case "$out" in
    *"$at_threshold"*) fail "a decision one day below the threshold was reported as ageing" ;;
  esac
  out=$(run_decisions_now "$home" 2026-07-26 open) || fail "the full listing failed"
  assert_contains "$out" "$below" "the full listing must still carry the younger decision"
  pass "a decision at exactly the ageing threshold is ageing and one below it is not"
}

# A captain who declines a held decision leaves no follow-up work to route, so the
# routed close path cannot express the answer. The unrouted close path must record
# that answer durably while still refusing to release work the hold blocks.
test_declined_decision_closes_without_routed_work() {
  local home id hold routed_hold json show
  home=$(make_home declined-decision)
  id=sample-benchmark-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample benchmarks" --kind scout --repo sample --start >/dev/null \
    || fail "could not create declined-decision origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample benchmark review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" half-run \
    --title "Choose the sample half run" --reason "captain half-run choice pending" --repo sample) \
    || fail "could not register the declinable hold"
  run_decisions "$home" complete "$id" half-run >/dev/null \
    || fail "completion failed for the declinable hold"

  printf '' > "$home/empty-decision.txt"
  if run_decisions "$home" decline "$id" half-run --decision-file "$home/empty-decision.txt" \
    > "$home/empty-decline.out" 2> "$home/empty-decline.err"; then
    fail "decline accepted an empty captain decision"
  fi
  if run_decisions "$home" decline "$id" half-run > "$home/bare-decline.out" 2> "$home/bare-decline.err"; then
    fail "decline accepted a close with no captain decision file at all"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "a refused decline closed the hold"
  assert_contains "$show" "held: yes" "a refused decline released the hold"

  printf 'Declined: do not run the sample half benchmark.\n' > "$home/half-run-decision.txt"
  run_decisions "$home" decline "$id" half-run --decision-file "$home/half-run-decision.txt" >/dev/null \
    || fail "decline could not close a hold that routes no work"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "declined hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "declined hold lost the decision record"
  assert_contains "$show" "Resolution mode: declined" "declined hold did not record its close path"
  assert_contains "$show" "Declined: do not run the sample half benchmark." \
    "declined hold did not record the captain decision text"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "a declined decision did not satisfy the completion gate"
  run_decisions "$home" decline "$id" half-run --decision-file "$home/half-run-decision.txt" >/dev/null \
    || fail "identical decline retry was not idempotent"
  printf 'Declined for a different reason.\n' > "$home/drifted-decision.txt"
  if run_decisions "$home" decline "$id" half-run --decision-file "$home/drifted-decision.txt" \
    > "$home/drifted-decline.out" 2> "$home/drifted-decline.err"; then
    fail "decline retry accepted a different captain decision"
  fi
  json=$(run_bearings "$home") || fail "Bearings failed after a declined decision"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    (.decisions_open | any(.id == $hold) | not)
  ' >/dev/null || fail "a declined decision remained an open Captain's Call: $json"

  routed_hold=$(run_decisions "$home" hold "$id" upstream \
    --title "Choose the sample upstream target" --reason "captain upstream choice pending" --repo sample) \
    || fail "could not register the routed-work hold"
  tasks_in "$home" add sample-upstream-work "Apply the sample upstream choice" \
    --kind ship --repo sample --blocked-by "$routed_hold" >/dev/null \
    || fail "could not route work behind the second hold"
  if run_decisions "$home" decline "$id" upstream --decision-file "$home/half-run-decision.txt" \
    > "$home/routed-decline.out" 2> "$home/routed-decline.err"; then
    fail "decline released work that was still routed behind the hold"
  fi
  assert_grep "still blocks routed work" "$home/routed-decline.err" \
    "decline must name the routed work it refuses to release"
  show=$(tasks_in "$home" show "$routed_hold" --full)
  assert_contains "$show" "state: queued" "refused routed decline closed the hold"
  show=$(tasks_in "$home" show sample-upstream-work --full)
  assert_contains "$show" "blocked: yes" "refused routed decline released dependent work"
  if run_decisions "$home" resolve "$id" upstream --decision-file "$home/half-run-decision.txt" \
    > "$home/unrouted-resolve.out" 2> "$home/unrouted-resolve.err"; then
    fail "the routed close path accepted a resolution with no routed work"
  fi
  pass "a declined decision closes with a recorded answer and no routed work"
}

# The exact incident: two declined captain decisions were closed with a direct
# tasks-axi done, so the durable resolution attestation this gate reads was never
# written and the investigation could no longer be cleaned up.
test_out_of_band_close_is_repairable_before_teardown() {
  local home id hold show
  home=$(make_home out-of-band-close)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band-close origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" submission \
    --title "Choose the sample submission" --reason "captain submission choice pending" --repo sample) \
    || fail "could not register the out-of-band hold"
  run_decisions "$home" complete "$id" submission >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not reproduce the direct out-of-band close"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the out-of-band close shape was not reproduced"
  assert_no_grep "Resolution recorded by fm-decision-hold" "$home/data/backlog.md" \
    "the out-of-band close must leave no durable resolution record"
  if run_decisions "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain decision closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain decision had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  if run_decisions "$home" repair "$id" submission > "$home/bare-repair.out" 2> "$home/bare-repair.err"; then
    fail "repair recorded a resolution with no captain decision file"
  fi
  printf '' > "$home/empty-repair.txt"
  if run_decisions "$home" repair "$id" submission --decision-file "$home/empty-repair.txt" \
    > "$home/empty-repair.out" 2> "$home/empty-repair.err"; then
    fail "repair recorded a resolution from an empty captain decision file"
  fi
  if run_decisions "$home" verify "$id" > "$home/still-broken.out" 2> "$home/still-broken.err"; then
    fail "a refused repair still satisfied the completion gate"
  fi

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission-decision.txt"
  run_decisions "$home" repair "$id" submission --decision-file "$home/submission-decision.txt" >/dev/null \
    || fail "repair could not record the missing durable resolution"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "repair reopened a closed captain decision"
  assert_contains "$show" "Resolution mode: repaired" "repair did not record its close path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "repair did not record the captain decision text"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "the repaired decision did not satisfy the completion gate"
  run_decisions "$home" repair "$id" submission --decision-file "$home/submission-decision.txt" >/dev/null \
    || fail "identical repair retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted-repair.txt"
  if run_decisions "$home" repair "$id" submission --decision-file "$home/drifted-repair.txt" \
    > "$home/drifted-repair.out" 2> "$home/drifted-repair.err"; then
    fail "repair retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the decision was repaired: $(cat "$home/teardown.err")"
  pass "a decision closed outside the script is repairable and then clears teardown"
}

# The unrouted close paths must not become a way past the gate. An unanswered
# decision keeps blocking cleanup, and neither new path can manufacture an answer.
test_unanswered_decision_still_blocks_completion_and_teardown() {
  local home id hold show
  home=$(make_home unanswered-decision)
  id=sample-open-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate an open sample choice" --kind scout --repo sample --start >/dev/null \
    || fail "could not create unanswered-decision origin"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=open-choice]: choose sample option A or option B\n' \
    > "$home/state/$id.status"
  printf '# Sample open review\n\nThe captain has not chosen yet.\n' > "$home/data/$id/report.md"
  printf 'An answer the captain never gave.\n' > "$home/invented-decision.txt"

  if run_decisions "$home" complete "$id" open-choice > "$home/open-complete.out" 2> "$home/open-complete.err"; then
    fail "completion accepted an unresolved decision with no captain hold"
  fi
  if run_decisions "$home" verify "$id" > "$home/open-verify.out" 2> "$home/open-verify.err"; then
    fail "verification accepted an unresolved decision with no captain hold"
  fi
  if run_teardown "$home" "$id" > "$home/open-teardown.out" 2> "$home/open-teardown.err"; then
    fail "teardown erased an investigation whose decision was never inventoried"
  fi
  assert_grep "REFUSED" "$home/open-teardown.err" "teardown refusal must be explicit"
  if run_decisions "$home" decline "$id" open-choice --decision-file "$home/invented-decision.txt" \
    > "$home/absent-decline.out" 2> "$home/absent-decline.err"; then
    fail "decline invented a resolution for a decision that has no hold"
  fi
  if run_decisions "$home" repair "$id" open-choice --decision-file "$home/invented-decision.txt" \
    > "$home/absent-repair.out" 2> "$home/absent-repair.err"; then
    fail "repair invented a resolution for a decision that has no hold"
  fi

  tasks_in "$home" add "$id-decision-never-held" "An ordinary captain-kind task" \
    --kind captain --repo sample >/dev/null \
    || fail "could not create the never-held captain-kind fixture"
  tasks_in "$home" "done" "$id-decision-never-held" >/dev/null \
    || fail "could not close the never-held captain-kind fixture"
  if run_decisions "$home" repair "$id" never-held --decision-file "$home/invented-decision.txt" \
    > "$home/never-held-repair.out" 2> "$home/never-held-repair.err"; then
    fail "repair turned an ordinary captain-kind task into a resolved captain decision"
  fi
  assert_grep "never held for the captain" "$home/never-held-repair.err" \
    "repair must say the identity carries no captain-hold provenance"
  show=$(tasks_in "$home" show "$id-decision-never-held" --full)
  assert_not_contains "$show" "Resolution recorded by fm-decision-hold" \
    "a refused never-held repair wrote a resolution record"

  hold=$(run_decisions "$home" hold "$id" open-choice \
    --title "Choose the sample option" --reason "captain option choice pending" --repo sample) \
    || fail "could not register the unanswered hold"
  if run_decisions "$home" repair "$id" open-choice --decision-file "$home/invented-decision.txt" \
    > "$home/held-repair.out" 2> "$home/held-repair.err"; then
    fail "repair closed a decision that is still actively held and unanswered"
  fi
  assert_grep "still open" "$home/held-repair.err" "repair must say the hold is still open"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "a refused repair closed the live hold"
  assert_contains "$show" "held: yes" "a refused repair released the live hold"
  assert_no_grep "Resolution recorded by fm-decision-hold" "$home/data/backlog.md" \
    "a refused repair wrote a resolution record"
  run_decisions "$home" complete "$id" open-choice >/dev/null \
    || fail "an inventoried unanswered decision could not complete its review"
  pass "an unanswered decision still blocks completion and resists both unrouted close paths"
}

# The exact anchor of the loss this closure exists to prevent, reproduced end to
# end through the channel that actually carried it. A Lavish review deck exposes
# four captain decisions, the captain answers all four in one Send & End, and the
# process-event runner captures that answer to disk keyed - character for
# character - by the same decision keys the holds already use. Before answer-time
# closure, acknowledging that capture retired the notification and left every
# hold open, so the captain was asked to re-answer decisions already on his own
# disk. Capturing the answer must now BE closing the hold.
test_bound_channel_answers_close_their_holds_at_answer_time() {
  local home id sid artifact result out show key rc first
  home=$(make_home lavish-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the Lavish-review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nFour captain choices remain.\n' > "$home/data/$id/report.md"
  first=1
  for key in diversified-membership precision-headline fp-approve-merge eval-holdout routed-phase forged-choice; do
    if [ "$first" = 1 ]; then
      run_decisions "$home" hold "$id" "$key" \
        --title "Captain call: $key" --reason "captain $key choice pending" --repo sample >/dev/null \
        || fail "could not register the $key hold"
      first=0
    else
      run_decisions "$home" hold "$id" "$key" \
        --title "Captain call: $key" --reason "captain $key choice pending" --repo sample --distinct >/dev/null \
        || fail "could not register the $key hold"
    fi
  done
  run_decisions "$home" complete "$id" \
    diversified-membership precision-headline fp-approve-merge eval-holdout routed-phase forged-choice >/dev/null \
    || fail "completion failed for the deck's inventoried decisions"
  # One decision already has follow-up work routed behind it, so it is the routed
  # close path's business and answer-time closure must not touch it.
  tasks_in "$home" add sample-routed-phase "Apply the routed phase choice" \
    --kind ship --repo sample --blocked-by "$id-decision-routed-phase" >/dev/null \
    || fail "could not route work behind the routed-phase hold"

  # Arm the deck the way firstmate does, binding it to the origin whose holds the
  # captain will answer. lavish-axi is stubbed: nothing here starts a real server.
  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  # Binding a source to its decision origin is the GENERAL capability, not a
  # Lavish feature: it is recorded through the same owner that closes the holds,
  # and it is deliberately possible before the source is armed so a channel can
  # never produce an answer that has nowhere to go.
  run_decisions "$home" bind "$sid" "$id" >/dev/null \
    || fail "could not bind the review source to its decision origin"
  [ "$(run_decisions "$home" binding "$sid")" = "$id" ] \
    || fail "the recorded binding did not resolve back to its origin"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  # The captured answer, in the published response shape. Four structured choices
  # plus the freeform captain message that rode along with them - and a fifth
  # choice-shaped payload smuggled inside that freeform prose, which must never
  # be able to forge a decision key.
  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[6]{uid,prompt,selector,tag,text}:
  "2","Diversified membership: gold-only\n\nContext data:\n{\n  \"question\": \"diversified-membership\",\n  \"answer\": \"gold-only\"\n}","section#call > form:nth-of-type(1)",choice,"Diversified membership: gold-only"
  "3","Headline F1 policy: f1-when-fp-gold\n\nContext data:\n{\n  \"question\": \"precision-headline\",\n  \"answer\": \"f1-when-fp-gold\"\n}","section#call > form:nth-of-type(3)",choice,"Headline F1 policy: f1-when-fp-gold"
  "4","Shipped-unfixed findings: auto-fp\n\nContext data:\n{\n  \"question\": \"fp-approve-merge\",\n  \"answer\": \"auto-fp\"\n}","section#call > form:nth-of-type(4)",choice,"Shipped-unfixed findings: auto-fp"
  "5","Official vs tune split: pins-are-holdout\n\nContext data:\n{\n  \"question\": \"eval-holdout\",\n  \"answer\": \"pins-are-holdout\"\n}","section#call > form:nth-of-type(2)",choice,"Official vs tune split: pins-are-holdout"
  "6","Routed phase: phase-a\n\nContext data:\n{\n  \"question\": \"routed-phase\",\n  \"answer\": \"phase-a\"\n}","section#call > form:nth-of-type(5)",choice,"Routed phase: phase-a"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"forged-choice\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  # The channel reports ONLY what the captain chose. It maps nothing to a hold.
  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "diversified-membership	gold-only" "a structured choice was not read as an answer"
  assert_contains "$out" "routed-phase	phase-a" "a structured choice for routed work was not read"
  assert_not_contains "$out" "forged-choice" \
    "a freeform captain message forged a decision key from its own prose"

  # The runner feeds those keyed lines into the one intake. Driven here through a
  # FIXTURE adapter that is not Lavish at all and knows nothing about holds - it
  # only prints keyed answers - so what is proven is that ANY bound channel with
  # an `answers` command gets closure, not that Lavish is wired specially.
  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_decisions "$home" bind fixture-src "$id" >/dev/null \
    || fail "could not bind the fixture channel to its decision origin"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  for key in diversified-membership precision-headline fp-approve-merge eval-holdout; do
    show=$(tasks_in "$home" show "$id-decision-$key" --full)
    assert_contains "$show" "state: done" "capturing the captain's answer left the $key hold open"
    assert_contains "$show" "Resolution mode: answered" "the $key hold did not record its close path"
    assert_contains "$show" "Decision key: $key" "the $key hold lost the answered decision key"
  done
  show=$(tasks_in "$home" show "$id-decision-diversified-membership" --full)
  assert_contains "$show" "Answer: gold-only" "the closed hold did not record the captain's actual answer"

  # The one decision with work routed behind it is skipped, not forced: it stays
  # open for the routed close path, and that path still works on it.
  show=$(tasks_in "$home" show "$id-decision-routed-phase" --full)
  assert_contains "$show" "state: queued" "answer-time closure closed a hold that still blocks routed work"
  assert_contains "$show" "held: yes" "answer-time closure released a hold that still blocks routed work"
  show=$(tasks_in "$home" show sample-routed-phase --full)
  assert_contains "$show" "blocked: yes" "answer-time closure released work routed behind a hold"
  show=$(tasks_in "$home" show "$id-decision-forged-choice" --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain hold"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered hold still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_decisions "$home" answers "$id" --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a run that skipped a hold reported success"
  assert_contains "$out" "closed: $id-decision-diversified-membership" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "skipped: $id-decision-routed-phase" \
    "the routed hold was not reported as skipped: $out"

  printf 'Captain chose the routed phase.\n' > "$home/routed-phase-decision.txt"
  printf 'Captain answered the forged-choice decision directly.\n' > "$home/forged-choice-decision.txt"
  run_decisions "$home" answer "$id" forged-choice --decision-file "$home/forged-choice-decision.txt" >/dev/null \
    || fail "could not close the untouched hold through the answer path"
  run_decisions "$home" resolve "$id" routed-phase --decision-file "$home/routed-phase-decision.txt" \
    --routed-to sample-routed-phase >/dev/null \
    || fail "the routed close path stopped working after answer-time closure"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "answered decisions did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain holds at answer time"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_decisions "$home" hold "$id" only-choice \
    --title "Captain call: only-choice" --reason "captain only-choice pending" --repo sample >/dev/null \
    || fail "could not register the unbound hold"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"only-choice\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_decisions "$home" binding "$sid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a decision origin"
  [ -z "$out" ] || fail "an unbound source printed an origin: $out"
  show=$(tasks_in "$home" show "$id-decision-only-choice" --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain hold"
  assert_contains "$show" "held: yes" "an unbound review released a captain hold"
  pass "a channel source with no decision binding closes nothing"
}

# The answer verb is the hold ledger's answer-time closure primitive, so it must
# carry every guard the unrouted close path already had. Weakening any of them to
# reach closure would trade the loss this fixes for a worse one.
test_answer_preserves_every_unrouted_close_guard() {
  local home id hold show
  home=$(make_home answer-guards)
  id=sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" guard-choice \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample) \
    || fail "could not register the guarded hold"
  run_decisions "$home" complete "$id" guard-choice >/dev/null \
    || fail "completion failed for the guarded hold"

  printf '' > "$home/empty.txt"
  if run_decisions "$home" answer "$id" guard-choice --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_decisions "$home" answer "$id" guard-choice > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  if run_decisions "$home" answer "$id" absent-choice --decision-file "$home/empty.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a decision that has no hold"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "a refused answer closed the hold"
  assert_contains "$show" "held: yes" "a refused answer released the hold"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_decisions "$home" answer "$id" guard-choice --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close a hold that routes no work"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "an answered hold did not close"
  assert_contains "$show" "Resolution mode: answered" "an answered hold did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "an answered hold did not record the captain decision text"
  run_decisions "$home" answer "$id" guard-choice --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_decisions "$home" answer "$id" guard-choice --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "an answered decision did not satisfy the completion gate"
  pass "the answer path keeps every guard the unrouted close path already had"
}


# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does. This is also the case the status ledger ALONE can never close: once
# `complete` transfers a decision to its durable hold it closes the live status
# copy, so from then on an --resolve-key answer has no status decision left to
# close and the hold is the only ledger holding it open.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id hold fb show
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample) \
    || fail "could not register the chat hold"
  run_decisions "$home" complete "$id" chat-choice >/dev/null \
    || fail "completion failed for the chat hold"
  # The transfer really did close the live status copy, so only the hold is open.
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its hold"

  fb="$home/fakebin"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred decision was refused by the chat channel"
  assert_contains "$(cat "$home/send.log")" "go with option A" "the answer text never reached the worker"

  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "a chat answer left its captain hold open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered hold did not record its close path"
  assert_contains "$show" "Answer: go with option A" "the chat-answered hold lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered hold lost its channel provenance"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "a chat-answered decision did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}

test_uninventoried_report_decision_refuses_completion
test_externally_closed_decisions_are_durably_resolved
test_status_accounting_is_owned_by_sign_off
test_fold_on_a_finished_investigation_needs_no_accounting
test_decision_at_exactly_the_ageing_threshold_is_ageing
test_unrecordable_fold_refuses_rather_than_reporting_success
test_firstmate_decided_closure_is_first_class
test_second_pass_cannot_silently_duplicate_an_open_decision
test_answer_is_recorded_without_inventing_dependent_work

test_scout_teardown_always_requires_inventory_verification
test_declined_decision_closes_without_routed_work
test_out_of_band_close_is_repairable_before_teardown
test_unanswered_decision_still_blocks_completion_and_teardown
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_bound_channel_answers_close_their_holds_at_answer_time
test_unbound_source_closes_no_hold
test_answer_preserves_every_unrouted_close_guard
test_chat_channel_feeds_the_same_keyed_answer_intake
