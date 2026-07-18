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

test_archived_resolved_captain_decision_satisfies_inventory_union() {
  local home origin old_hold new_hold i item archive_show
  home=$(make_home archived-resolved-decision)
  sed -i.bak 's|archive = "data/done-archive.md"|archive = "data/decisions#done.md" # retained decisions|' "$home/.tasks.toml"
  rm "$home/.tasks.toml.bak"
  origin=sample-archive-ship
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Ship archive-sensitive work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create active ship origin"
  write_origin_meta "$home" "$origin" ship
  printf 'needs-decision [key=scope]: choose the original scope\ndone: original review pass complete\n' \
    > "$home/state/$origin.status"
  old_hold=$(run_decisions "$home" hold "$origin" scope \
    --title "Choose the original scope" --reason "captain original scope pending" --repo sample) \
    || fail "could not register original decision hold"
  run_decisions "$home" complete "$origin" scope >/dev/null \
    || fail "could not complete the original decision inventory"
  tasks_in "$home" add sample-scope-work "Apply the original scope" --kind ship --repo sample >/dev/null \
    || fail "could not create routed work"
  tasks_in "$home" block sample-scope-work --by "$old_hold" >/dev/null \
    || fail "could not block routed work by the original hold"
  printf 'Use the narrower sample scope.\n' > "$home/scope-decision.txt"
  run_decisions "$home" resolve "$origin" scope --decision-file "$home/scope-decision.txt" \
    --routed-to sample-scope-work >/dev/null \
    || fail "could not resolve the original decision"

  i=1
  while [ "$i" -le 10 ]; do
    item=$(printf 'sample-archive-pad-%02d' "$i")
    tasks_in "$home" add "$item" "Archive padding $i" --kind ship --repo sample >/dev/null \
      || fail "could not create archive padding item $i"
    tasks_in "$home" "done" "$item" >/dev/null \
      || fail "could not complete archive padding item $i"
    i=$((i + 1))
  done
  ! grep -E "^- \[[ x]\] $old_hold -" "$home/data/backlog.md" >/dev/null \
    || fail "resolved captain decision remained in the active backlog"
  archive_show=$(cat "$home/data/decisions#done.md") \
    || fail "configured archive lost the exact resolved captain decision"
  assert_contains "$archive_show" "- [x] $old_hold -" "archived decision is not done"
  assert_contains "$archive_show" "(kind: captain)" "archived decision is not kind captain"
  assert_contains "$archive_show" "Resolution recorded by fm-decision-hold" \
    "archived decision lost the structured resolution record"
  assert_contains "$archive_show" "Routed identities: sample-scope-work" \
    "archived decision lost routed identity"

  printf 'needs-decision [key=catalog]: choose the catalog completeness scope\n' \
    >> "$home/state/$origin.status"
  new_hold=$(run_decisions "$home" hold "$origin" catalog \
    --title "Choose the catalog completeness scope" \
    --reason "captain catalog completeness pending" --repo sample) \
    || fail "could not register the new decision hold"
  [ "$new_hold" = "$origin-decision-catalog" ] \
    || fail "new decision identity was not deterministic: $new_hold"
  run_decisions "$home" complete "$origin" catalog >/dev/null \
    || fail "archived resolved decision did not satisfy inventory completion"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "archived resolved decision did not satisfy inventory verification"
  assert_grep "decision_keys=catalog,scope" "$home/state/$origin.meta" \
    "metadata union dropped an earlier reviewed decision"
  pass "archived resolved captain decision satisfies later inventory completion and verification"
}

test_archived_resolved_decision_accepts_all_completion_verbs() {
  local verb home origin hold route title i item archive_line
  for verb in merged reported; do
    home=$(make_home "archived-$verb-decision")
    origin="sample-$verb-archive"
    route="sample-$verb-work"
    case "$verb" in
      merged) title="Choose https://github.com/example/sample/pull/42" ;;
      reported) title="Choose data/$origin/report.md" ;;
    esac
    tasks_in "$home" add "$origin" "Ship $verb archive-sensitive work" \
      --kind ship --repo sample --start >/dev/null \
      || fail "could not create $verb archive origin"
    write_origin_meta "$home" "$origin" ship
    hold=$(run_decisions "$home" hold "$origin" scope \
      --title "$title" --reason "captain $verb scope pending" --repo sample) \
      || fail "could not register $verb decision hold"
    run_decisions "$home" complete "$origin" scope >/dev/null \
      || fail "could not complete $verb decision inventory"
    tasks_in "$home" add "$route" "Apply the $verb decision" --kind ship --repo sample >/dev/null \
      || fail "could not create $verb routed work"
    tasks_in "$home" block "$route" --by "$hold" >/dev/null \
      || fail "could not block $verb routed work"
    printf 'Use the recorded sample scope.\n' > "$home/$verb-decision.txt"
    run_decisions "$home" resolve "$origin" scope \
      --decision-file "$home/$verb-decision.txt" --routed-to "$route" >/dev/null \
      || fail "could not resolve $verb captain decision"

    i=1
    while [ "$i" -le 10 ]; do
      item=$(printf 'sample-%s-pad-%02d' "$verb" "$i")
      tasks_in "$home" add "$item" "$verb archive padding $i" --kind ship --repo sample >/dev/null \
        || fail "could not create $verb archive padding item $i"
      tasks_in "$home" "done" "$item" >/dev/null \
        || fail "could not complete $verb archive padding item $i"
      i=$((i + 1))
    done

    archive_line=$(grep -F -- "- [x] $hold -" "$home/data/done-archive.md") \
      || fail "$verb captain decision was not archived"
    assert_contains "$archive_line" "($verb " "$verb closure metadata was not archived"
    run_decisions "$home" complete "$origin" scope >/dev/null \
      || fail "archived $verb decision did not satisfy inventory completion"
    run_decisions "$home" verify "$origin" >/dev/null \
      || fail "archived $verb decision did not satisfy inventory verification"
  done
  pass "archived resolved captain decisions accept every completion verb"
}

test_archived_completion_verb_still_requires_done_state() {
  local home origin hold
  home=$(make_home archived-noncompleted-decision)
  origin=sample-noncompleted-archive
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [ ] $hold - Choose https://github.com/example/sample/pull/42 (repo: sample) (kind: captain) (merged 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  if run_decisions "$home" complete "$origin" scope \
    > "$home/noncompleted-complete.out" 2> "$home/noncompleted-complete.err"; then
    fail "noncompleted archived decision satisfied inventory completion"
  fi
  if run_decisions "$home" verify "$origin" \
    > "$home/noncompleted-verify.out" 2> "$home/noncompleted-verify.err"; then
    fail "noncompleted archived decision satisfied inventory verification"
  fi
  pass "archived completion verbs still require a done task state"
}

test_archived_resolved_decision_accepts_priority_and_legacy_closed_metadata() {
  local home origin hold
  home=$(make_home archived-priority-closed-decision)
  origin=sample-priority-closed-archive
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Priority decision (repo: sample) (kind: captain) (priority: 2) (closed 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  run_decisions "$home" complete "$origin" scope >/dev/null \
    || fail "archived priority and legacy closed metadata did not satisfy inventory completion"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "archived priority and legacy closed metadata did not satisfy inventory verification"
  pass "archived decisions accept priority and legacy closed metadata"
}

test_active_and_archived_identity_collision_fails_closed() {
  local home origin hold
  home=$(make_home active-archived-identity-collision)
  origin=sample-active-archive-collision
  write_origin_meta "$home" "$origin" ship
  hold=$(run_decisions "$home" hold "$origin" scope \
    --title "Choose the sample scope" --reason "captain sample scope pending" --repo sample) \
    || fail "could not create active collision fixture"
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Older resolved scope (repo: sample) (kind: captain) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the older sample scope.

  Routed work:
  - sample-work
EOF
  if run_decisions "$home" complete "$origin" scope \
    > "$home/collision-complete.out" 2> "$home/collision-complete.err"; then
    fail "active identity masked conflicting archived history during completion"
  fi
  if run_decisions "$home" verify "$origin" \
    > "$home/collision-verify.out" 2> "$home/collision-verify.err"; then
    fail "active identity masked conflicting archived history during verification"
  fi
  assert_grep "exists in both the active backlog and decision archive" "$home/collision-complete.err" \
    "completion did not report the stable identity collision"
  assert_grep "exists in both the active backlog and decision archive" "$home/collision-verify.err" \
    "verification did not report the stable identity collision"
  pass "active and archived stable identity collisions fail closed"
}

test_malformed_archive_decision_does_not_satisfy_inventory() {
  local home origin hold blank_hold i item
  home=$(make_home malformed-archived-decision)
  origin=sample-malformed-archive
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Ship with malformed archived decision" --kind ship --repo sample --start >/dev/null \
    || fail "could not create malformed archive origin"
  write_origin_meta "$home" "$origin" ship
  hold="$origin-decision-scope"
  tasks_in "$home" add "$hold" "Incomplete archived decision" --kind captain --repo sample \
    --body $'Resolution recorded by fm-decision-hold.\n\nCaptain decision:\nUse the sample scope.\n\nRouted work:\n- sample-work' >/dev/null \
    || fail "could not create malformed captain item"
  tasks_in "$home" "done" "$hold" >/dev/null \
    || fail "could not close malformed captain item"
  blank_hold="$origin-decision-blank"
  tasks_in "$home" add "$blank_hold" "Blank archived decision" --kind captain --repo sample \
    --body $'Resolution recorded by fm-decision-hold.\nDecision digest: 0000000000000000000000000000000000000000000000000000000000000000\nRouted identities: sample-work\n\nCaptain decision:\n\nRouted work:\n- sample-work' >/dev/null \
    || fail "could not create blank captain decision item"
  tasks_in "$home" "done" "$blank_hold" >/dev/null \
    || fail "could not close blank captain decision item"
  i=1
  while [ "$i" -le 10 ]; do
    item=$(printf 'sample-malformed-pad-%02d' "$i")
    tasks_in "$home" add "$item" "Malformed padding $i" --kind ship --repo sample >/dev/null \
      || fail "could not create malformed archive padding item $i"
    tasks_in "$home" "done" "$item" >/dev/null \
      || fail "could not complete malformed archive padding item $i"
    i=$((i + 1))
  done
  fm_write_meta "$home/state/$origin.meta" \
    "window=firstmate:fm-$origin" \
    "worktree=$home/projects/missing-$origin" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "decisions_reviewed=1" \
    "decision_keys=scope"
  if run_decisions "$home" verify "$origin" > "$home/malformed-verify.out" 2> "$home/malformed-verify.err"; then
    fail "malformed archived captain prose satisfied decision verification"
  fi
  fm_write_meta "$home/state/$origin.meta" \
    "window=firstmate:fm-$origin" \
    "worktree=$home/projects/missing-$origin" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "decisions_reviewed=1" \
    "decision_keys=blank"
  if run_decisions "$home" verify "$origin" > "$home/blank-verify.out" 2> "$home/blank-verify.err"; then
    fail "blank archived captain decision satisfied decision verification"
  fi
  pass "malformed archived captain records do not satisfy decision verification"
}

test_archived_ship_title_cannot_impersonate_captain_kind() {
  local home origin hold
  home=$(make_home archived-ship-title-kind)
  origin=sample-title-kind
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Misleading (kind: captain) title (repo: sample) (kind: ship) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  if run_decisions "$home" verify "$origin" > "$home/title-kind.out" 2> "$home/title-kind.err"; then
    fail "ship title metadata impersonated an archived captain decision"
  fi
  pass "archived task kind comes from structured metadata, not title text"
}

test_archived_resolution_requires_sha256_digest() {
  local home origin hold
  home=$(make_home archived-invalid-digest)
  origin=sample-invalid-digest
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Invalid digest (repo: sample) (kind: captain) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: x
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  if run_decisions "$home" verify "$origin" > "$home/invalid-digest.out" 2> "$home/invalid-digest.err"; then
    fail "archived resolution accepted a non-SHA-256 digest"
  fi
  pass "archived resolution requires a SHA-256 decision digest"
}

test_archived_resolution_requires_matching_routed_identities() {
  local home origin hold
  home=$(make_home archived-routed-mismatch)
  origin=sample-routed-mismatch
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Mismatched routed work (repo: sample) (kind: captain) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work-a

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work-b
EOF
  if run_decisions "$home" verify "$origin" > "$home/routed-mismatch.out" 2> "$home/routed-mismatch.err"; then
    fail "archived resolution accepted mismatched routed identities"
  fi
  pass "archived routed identities match the canonical routed-work list"
}

test_archived_resolution_preserves_literal_backslash_markers() {
  local home origin hold
  home=$(make_home archived-literal-backslash)
  origin=sample-literal-backslash
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Literal marker decision (repo: sample) (kind: captain) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 92ec27db26b55fc98687089e6172c8df29d62e00cc5c0e937ead277d5d250817
  Routed identities: sample-work

  Captain decision:
  \nRouted work: keep this literal.

  Routed work:
  - sample-work
EOF
  printf '%s\n' '\nRouted work: keep this literal.' > "$home/literal-decision.txt"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "literal backslash marker corrupted archived decision verification"
  run_decisions "$home" resolve "$origin" scope --decision-file "$home/literal-decision.txt" \
    --routed-to sample-work >/dev/null \
    || fail "literal backslash marker corrupted archived decision retry identity"
  pass "archived resolution preserves literal backslash marker text"
}

test_archived_identity_collision_refuses_hold_recreation() {
  local home origin hold
  home=$(make_home archived-identity-collision)
  origin=sample-archived-collision
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Corrupted archived identity (repo: sample) (kind: ship) (done 2026-07-18)
  Incomplete archived record.
EOF
  if run_decisions "$home" hold "$origin" scope \
    --title "Choose the sample scope" --reason "captain sample scope pending" --repo sample \
    > "$home/collision-hold.out" 2> "$home/collision-hold.err"; then
    fail "invalid archived identity collision allowed hold recreation"
  fi
  assert_no_grep "^- \[ \] $hold -" "$home/data/backlog.md" \
    "invalid archived identity collision created a replacement active hold"
  pass "archived identity collisions cannot be replaced by active holds"
}

test_durable_lookup_preserves_active_store_failures() {
  local home origin hold
  home=$(make_home durable-active-store-failure)
  origin=sample-store-failure
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Valid archived decision (repo: sample) (kind: captain) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = sample-store-failure-decision-scope ]; then
  printf '%s\n' 'error: active backlog is malformed' 'code: INVALID_BACKLOG' >&2
  exit 2
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" verify "$origin" > "$home/store-failure.out" 2> "$home/store-failure.err"; then
    fail "active store failure fell back to an archived decision"
  fi
  assert_grep "code: INVALID_BACKLOG" "$home/store-failure.err" \
    "durable lookup discarded the authoritative active-store failure"
  pass "durable lookup falls back only after an explicit not-found result"
}

test_archived_resolution_ignores_trailing_blank_formatting() {
  local home origin hold
  home=$(make_home archived-trailing-blanks)
  origin=sample-trailing-blanks
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Archived decision with separator (repo: sample) (kind: captain) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work


- [x] sample-trailing-format - Formatting sentinel (repo: sample) (kind: ship) (done 2026-07-18)
EOF
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "trailing archive formatting invalidated a resolved captain decision"
  pass "trailing archive formatting is excluded from the archived task body"
}

test_archived_resolution_obeys_task_body_boundaries() {
  local home origin raw_hold blank_hold
  home=$(make_home archived-body-boundaries)
  origin=sample-body-boundaries
  raw_hold="$origin-decision-raw"
  blank_hold="$origin-decision-blank"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=raw\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $raw_hold - Raw prose boundary (repo: sample) (kind: captain) (done 2026-07-18)
Resolution recorded by fm-decision-hold.
Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
Routed identities: sample-work

Captain decision:
Use the sample scope.

Routed work:
- sample-work

- [x] $blank_hold - Leading blank body (repo: sample) (kind: captain) (done 2026-07-18)

  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  if run_decisions "$home" verify "$origin" > "$home/raw-boundary.out" 2> "$home/raw-boundary.err"; then
    fail "column-zero archive prose was treated as task body"
  fi
  printf 'decisions_reviewed=1\ndecision_keys=blank\n' >> "$home/state/$origin.meta"
  if run_decisions "$home" verify "$origin" > "$home/blank-boundary.out" 2> "$home/blank-boundary.err"; then
    fail "leading archived body blank was discarded"
  fi
  pass "archived resolutions obey tasks-axi task body boundaries"
}

test_unreadable_archive_refuses_identity_recreation() {
  local home origin hold
  home=$(make_home unreadable-decision-archive)
  origin=sample-unreadable-archive
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  mkdir "$home/data/done-archive.md"
  if run_decisions "$home" hold "$origin" scope \
    --title "Choose the sample scope" --reason "captain sample scope pending" --repo sample \
    > "$home/unreadable-hold.out" 2> "$home/unreadable-hold.err"; then
    fail "unreadable archive allowed stable hold recreation"
  fi
  assert_no_grep "^- \[ \] $hold -" "$home/data/backlog.md" \
    "unreadable archive created a replacement active hold"
  assert_grep "could not read archived backlog identity $hold" "$home/unreadable-hold.err" \
    "hold creation treated an unreadable archive as an absent identity"
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  if run_decisions "$home" verify "$origin" \
    > "$home/unreadable-verify.out" 2> "$home/unreadable-verify.err"; then
    fail "unreadable archive satisfied durable verification"
  fi
  assert_grep "could not read captain decision $hold" "$home/unreadable-verify.err" \
    "durable verification treated an unreadable archive as an absent identity"
  pass "unreadable archives cannot be mistaken for absent identities"
}

test_archived_resolution_requires_routed_work_newline() {
  local home origin hold
  home=$(make_home archived-routed-newline)
  origin=sample-routed-newline
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Missing routed newline (repo: sample) (kind: captain) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:- sample-work
EOF
  if run_decisions "$home" verify "$origin" > "$home/routed-newline.out" 2> "$home/routed-newline.err"; then
    fail "archived resolution accepted routed work without a structural newline"
  fi
  pass "archived routed work requires its structural newline"
}

test_archived_resolution_requires_tasks_axi_ids() {
  local home origin dot_hold dash_hold
  home=$(make_home archived-invalid-routed-ids)
  origin=sample-invalid-routed-ids
  dot_hold="$origin-decision-dot"
  dash_hold="$origin-decision-dash"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=dot\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $dot_hold - Leading dot route (repo: sample) (kind: captain) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: .sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - .sample-work

- [x] $dash_hold - Leading dash route (repo: sample) (kind: captain) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: -sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - -sample-work
EOF
  if run_decisions "$home" verify "$origin" > "$home/dot-route.out" 2> "$home/dot-route.err"; then
    fail "archived resolution accepted a routed id beginning with a dot"
  fi
  printf 'decisions_reviewed=1\ndecision_keys=dash\n' >> "$home/state/$origin.meta"
  if run_decisions "$home" verify "$origin" > "$home/dash-route.out" 2> "$home/dash-route.err"; then
    fail "archived resolution accepted a routed id beginning with a dash"
  fi
  pass "archived routed identities use the tasks-axi id grammar"
}

test_archive_config_accepts_no_space_assignment() {
  local home origin hold
  home=$(make_home archive-config-no-space)
  origin=sample-config-no-space
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  sed -i.bak 's|archive = "data/done-archive.md"|archive="data/no-space-archive.md"|' "$home/.tasks.toml"
  rm "$home/.tasks.toml.bak"
  cat > "$home/data/no-space-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - No-space archive config (repo: sample) (kind: captain) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "archive config rejected an assignment without spaces around equals"
  pass "archive config accepts tasks-axi optional assignment whitespace"
}

test_archived_conflicting_kind_tags_fail_closed() {
  local home origin hold
  home=$(make_home archived-conflicting-kind-tags)
  origin=sample-conflicting-kind-tags
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Conflicting kind metadata (repo: sample) (kind: captain) (kind: ship) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  if run_decisions "$home" verify "$origin" > "$home/conflicting-kind.out" 2> "$home/conflicting-kind.err"; then
    fail "conflicting archived kind tags satisfied decision verification"
  fi
  pass "conflicting archived kind tags fail closed"
}

test_archived_rightmost_empty_kind_fails_closed() {
  local home origin hold
  home=$(make_home archived-empty-kind-tag)
  origin=sample-empty-kind-tag
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Empty kind metadata (repo: sample) (kind: captain) (kind:  ) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  if run_decisions "$home" verify "$origin" > "$home/empty-kind.out" 2> "$home/empty-kind.err"; then
    fail "an earlier captain kind overrode the rightmost empty kind tag"
  fi
  pass "rightmost empty archived kind metadata fails closed"
}

test_archived_kind_tag_spacing_fails_closed() {
  local home origin hold
  home=$(make_home archived-kind-tag-spacing)
  origin=sample-kind-tag-spacing
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Conflicting kind spacing (repo: sample) (kind: captain)  (kind:ship) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  if run_decisions "$home" verify "$origin" > "$home/kind-spacing.out" 2> "$home/kind-spacing.err"; then
    fail "alternate archived kind spacing satisfied decision verification"
  fi
  pass "alternate archived kind spacing fails closed"
}

test_archived_kind_requires_contiguous_trailing_metadata() {
  local home origin hold
  home=$(make_home archived-kind-trailing-metadata)
  origin=sample-kind-trailing-metadata
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Interrupted kind metadata (repo: sample) (kind: captain) trailing prose (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  if run_decisions "$home" verify "$origin" > "$home/trailing-metadata.out" 2> "$home/trailing-metadata.err"; then
    fail "non-metadata prose left an archived captain kind valid"
  fi
  pass "archived kind requires contiguous trailing metadata"
}

test_duplicate_archived_identity_fails_closed() {
  local home origin hold
  home=$(make_home duplicate-archived-identity)
  origin=sample-duplicate-identity
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - First archived identity (repo: sample) (kind: captain) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work

- [x] $hold - Conflicting archived identity (repo: sample) (kind: ship) (done 2026-07-18)
  Conflicting duplicate record.
EOF
  if run_decisions "$home" verify "$origin" > "$home/duplicate.out" 2> "$home/duplicate.err"; then
    fail "duplicate archived identity satisfied decision verification"
  fi
  pass "duplicate archived identities fail closed"
}

test_archive_config_accepts_spaced_markdown_section() {
  local home origin hold
  home=$(make_home archive-config-spaced-section)
  origin=sample-config-spaced-section
  hold="$origin-decision-scope"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  sed -i.bak -e 's/^\[markdown\]$/[ markdown ]/' \
    -e 's|archive = "data/done-archive.md"|archive = "data/spaced-section-archive.md"|' \
    "$home/.tasks.toml"
  rm "$home/.tasks.toml.bak"
  cat > "$home/data/spaced-section-archive.md" <<EOF
## Archived 2026-07-18
- [x] $hold - Spaced markdown section (repo: sample) (kind: captain) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "archive config rejected a whitespace-trimmed markdown section"
  pass "archive config accepts whitespace-trimmed markdown sections"
}

test_archived_resolution_normalizes_semantic_lines() {
  local home origin hold archive
  home=$(make_home archived-semantic-lines)
  origin=sample-semantic-lines
  hold="$origin-decision-scope"
  archive="$home/data/done-archive.md"
  write_origin_meta "$home" "$origin" ship
  printf 'decisions_reviewed=1\ndecision_keys=scope\n' >> "$home/state/$origin.meta"
  printf '%s\r\n' \
    '## Archived 2026-07-18' \
    "- [x] $hold - CRLF archived decision (repo: sample) (kind: captain) (done 2026-07-18)" \
    '  Resolution recorded by fm-decision-hold.' \
    '  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000' \
    '  Routed identities: sample-work' \
    '  ' \
    '  Captain decision:' \
    '  Use the sample scope.' \
    '  ' \
    '  Routed work:' \
    '  - sample-work' \
    '  ' > "$archive"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "CRLF or whitespace-only archive lines invalidated a resolved captain decision"
  pass "archive parsing normalizes CRLF and whitespace-only lines"
}

test_archived_resolution_accepts_dependency_metadata() {
  local home origin
  home=$(make_home archived-dependency-metadata)
  origin=sample-dependency-metadata
  write_origin_meta "$home" "$origin" ship
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-07-18
- [x] $origin-decision-blocked - Blocked dependency metadata (repo: sample) (kind: captain) (done 2026-07-18) blocked-by: sample-blocker - waits for sample blocker
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work

- [x] $origin-decision-parent - Parent dependency metadata (repo: sample) (kind: captain) (done 2026-07-18) parent: sample-parent - grouped under sample parent
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work

- [x] $origin-decision-discovered - Discovery dependency metadata (repo: sample) (kind: captain) (done 2026-07-18) discovered-from: sample-source - found during sample review
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  run_decisions "$home" complete "$origin" blocked parent discovered >/dev/null \
    || fail "tasks-axi dependency metadata invalidated archived decisions"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "archived dependency metadata did not survive durable verification"
  pass "archived resolutions accept tasks-axi dependency metadata"
}

test_archive_config_matches_tasks_axi_quote_state() {
  local home origin hold archive
  home=$(make_home archive-config-quote-state)
  origin=sample-config-quote-state
  hold="$origin-decision-scope"
  archive="$home/data/escaped\\"
  write_origin_meta "$home" "$origin" ship
  sed -i.bak 's|archive = "data/done-archive.md"|archive = "data/escaped\\"#ignored.md"|' \
    "$home/.tasks.toml"
  rm "$home/.tasks.toml.bak"
  tasks_in "$home" list >/dev/null \
    || fail "tasks-axi rejected the escaped-quote config fixture"
  cat > "$archive" <<EOF
## Archived 2026-07-18
- [x] $hold - Escaped quote archive config (repo: sample) (kind: captain) (done 2026-07-18)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Routed identities: sample-work

  Captain decision:
  Use the sample scope.

  Routed work:
  - sample-work
EOF
  run_decisions "$home" complete "$origin" scope >/dev/null \
    || fail "archive config did not match tasks-axi quote-state behavior"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "escaped-quote archive config did not survive durable verification"
  pass "archive config matches tasks-axi quote-state behavior"
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

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_archived_resolved_captain_decision_satisfies_inventory_union
test_archived_resolved_decision_accepts_all_completion_verbs
test_archived_completion_verb_still_requires_done_state
test_archived_resolved_decision_accepts_priority_and_legacy_closed_metadata
test_active_and_archived_identity_collision_fails_closed
test_malformed_archive_decision_does_not_satisfy_inventory
test_archived_ship_title_cannot_impersonate_captain_kind
test_archived_resolution_requires_matching_routed_identities
test_archived_resolution_requires_sha256_digest
test_archived_resolution_preserves_literal_backslash_markers
test_archived_identity_collision_refuses_hold_recreation
test_durable_lookup_preserves_active_store_failures
test_archived_resolution_ignores_trailing_blank_formatting
test_archived_resolution_obeys_task_body_boundaries
test_unreadable_archive_refuses_identity_recreation
test_archived_resolution_requires_routed_work_newline
test_archived_resolution_requires_tasks_axi_ids
test_archive_config_accepts_no_space_assignment
test_archived_conflicting_kind_tags_fail_closed
test_archived_rightmost_empty_kind_fails_closed
test_archived_kind_tag_spacing_fails_closed
test_archived_kind_requires_contiguous_trailing_metadata
test_duplicate_archived_identity_fails_closed
test_archive_config_accepts_spaced_markdown_section
test_archived_resolution_normalizes_semantic_lines
test_archived_resolution_accepts_dependency_metadata
test_archive_config_matches_tasks_axi_quote_state
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
