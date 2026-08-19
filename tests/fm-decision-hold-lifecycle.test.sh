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

# The same invocation as run_decisions, from a chosen working directory and with
# a chosen TMPDIR, so a caller whose TMPDIR is relative to its own cwd is
# reproduced exactly as the script would meet it.
run_decisions_in() {  # <cwd> <tmpdir> <home> <command args...>
  local cwd=$1 tmpdir=$2 home=$3
  shift 3
  (cd "$cwd" && PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    TMPDIR="$tmpdir" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@")
}

# An origin whose single captain decision is answered and then archived out of the
# live backlog, which is the state every archived-read case starts from. The
# resulting hold identity is <origin-id>-decision-<decision-key>.
archive_one_resolved_decision() {  # <home> <origin-id> <decision-key>
  local home=$1 id=$2 key=$3 hold="$2-decision-$3"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate a sample archive read" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the archive-read origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample archive read\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  [ "$(run_decisions "$home" hold "$id" "$key" \
    --title "Choose the sample archive option" --reason "captain archive choice pending" --repo sample)" \
    = "$hold" ] || fail "could not register the archive-read hold as $hold"
  run_decisions "$home" complete "$id" "$key" >/dev/null || fail "completion failed before the close"
  printf 'Use the sample archive option.\n' > "$home/archive-decision.txt"
  run_decisions "$home" answer "$id" "$key" --decision-file "$home/archive-decision.txt" >/dev/null \
    || fail "could not answer the archive-read decision"
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not archive the resolved decision"
  if tasks_in "$home" show "$hold" --full >/dev/null 2>&1; then
    fail "the resolved decision was not archived out of the live backlog"
  fi
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
  local home id sid artifact result out show key rc
  home=$(make_home lavish-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the Lavish-review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nFour captain choices remain.\n' > "$home/data/$id/report.md"
  for key in diversified-membership precision-headline fp-approve-merge eval-holdout routed-phase forged-choice; do
    run_decisions "$home" hold "$id" "$key" \
      --title "Captain call: $key" --reason "captain $key choice pending" --repo sample >/dev/null \
      || fail "could not register the $key hold"
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

# An any-origin bound source carries answers whose keys are FULL hold identities,
# so one aggregation surface (the bearings board) can close decisions across
# origins - including identities longer than the old 64-character adapter cap -
# while a key with no -decision- separator (a merge or dispatch instruction)
# feeds nothing, a routed hold stays skipped for the routed close path, and the
# runner's feed seam carries the whole flow with no runner change.
test_any_origin_binding_closes_across_origins() {
  local home alpha beta origin feedback out show long_key long_id overlong_key rc
  home=$(make_home any-origin-board)
  alpha=sample-alpha-review
  beta=sample-instruction-layer-refinement-review
  for origin in "$alpha" "$beta"; do
    mkdir -p "$home/data/$origin"
    tasks_in "$home" add "$origin" "Review $origin" --kind scout --repo sample --start >/dev/null \
      || fail "could not create origin $origin"
    write_origin_meta "$home" "$origin"
    printf 'done: deck ready\n' > "$home/state/$origin.status"
    printf '# %s\n\nDecisions remain.\n' "$origin" > "$home/data/$origin/report.md"
  done
  run_decisions "$home" hold "$alpha" route-choice \
    --title "Captain call: route-choice" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "could not register the alpha hold"
  run_decisions "$home" hold "$alpha" routed-phase \
    --title "Captain call: routed-phase" --reason "captain routed phase pending" --repo sample >/dev/null \
    || fail "could not register the alpha routed hold"
  long_key=perishable-first-admission-choice
  long_id="$beta-decision-$long_key"
  [ "${#long_id}" -ge 81 ] \
    || fail "fixture regression: the full identity must exceed the old 64-char cap (got ${#long_id})"
  run_decisions "$home" hold "$beta" "$long_key" \
    --title "Captain call: $long_key" --reason "captain admission choice pending" --repo sample >/dev/null \
    || fail "could not register the beta hold"
  run_decisions "$home" complete "$alpha" route-choice routed-phase >/dev/null \
    || fail "completion failed for alpha"
  run_decisions "$home" complete "$beta" "$long_key" >/dev/null \
    || fail "completion failed for beta"
  tasks_in "$home" add sample-routed-work "Apply the routed phase" \
    --kind ship --repo sample --blocked-by "$alpha-decision-routed-phase" >/dev/null \
    || fail "could not route work behind the alpha routed hold"

  run_decisions "$home" bind board-src --any-origin >/dev/null \
    || fail "could not record the any-origin binding"
  [ "$(run_decisions "$home" binding board-src)" = "(any)" ] \
    || fail "the any-origin binding did not resolve to its marker"

  # The captured board answer: two cross-origin full-identity answers, a merge
  # instruction with no -decision- separator, a nonexistent identity, an answer
  # for the routed hold, a 129-char key over the adapter cap, and a non-slug key.
  overlong_key=$(printf 'x%.0s' {1..129})
  feedback="$home/board-feedback.txt"
  cat > "$feedback" <<EOF
session:
  file: /bearings-board.html
  status: feedback
prompts[7]{uid,prompt,selector,tag,text}:
  "2","Route: north\\n\\nContext data:\\n{\\n  \\"question\\": \\"$alpha-decision-route-choice\\",\\n  \\"answer\\": \\"north\\"\\n}","form",choice,"Route: north"
  "3","Admission: perishable-first\\n\\nContext data:\\n{\\n  \\"question\\": \\"$long_id\\",\\n  \\"answer\\": \\"perishable-first\\"\\n}","form",choice,"Admission: perishable-first"
  "4","Merge order\\n\\nContext data:\\n{\\n  \\"question\\": \\"merge.sample-task\\",\\n  \\"answer\\": \\"merge\\"\\n}","form",choice,"Merge: sample-task"
  "5","Ghost\\n\\nContext data:\\n{\\n  \\"question\\": \\"$alpha-decision-ghost\\",\\n  \\"answer\\": \\"yes\\"\\n}","form",choice,"Ghost: yes"
  "6","Routed phase: phase-a\\n\\nContext data:\\n{\\n  \\"question\\": \\"$alpha-decision-routed-phase\\",\\n  \\"answer\\": \\"phase-a\\"\\n}","form",choice,"Routed phase: phase-a"
  "7","Overlong\\n\\nContext data:\\n{\\n  \\"question\\": \\"$overlong_key\\",\\n  \\"answer\\": \\"yes\\"\\n}","form",choice,"Overlong: yes"
  "8","Bad shape\\n\\nContext data:\\n{\\n  \\"question\\": \\"bad key\\",\\n  \\"answer\\": \\"yes\\"\\n}","form",choice,"Bad shape: yes"
EOF

  # The adapter admits a full identity past the old 64-char cap and still
  # refuses shape violations - both proven through its executable interface.
  out=$(run_lavish "$home" answers "$feedback") || fail "could not read the captured answers"
  assert_contains "$out" "$long_id	perishable-first" \
    "an 81-char full hold identity did not survive the adapter"
  assert_not_contains "$out" "$overlong_key" "a 129-char question key passed the adapter cap"
  assert_not_contains "$out" "bad key" "a non-slug question key passed the adapter"

  # Fed through the real runner seam: `binding` prints the marker and the feed
  # pipes it into the one intake unchanged, exactly as production does.
  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-boardchan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-boardchan.sh"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register boardchan board-src -- cat "$feedback" >/dev/null \
    || fail "could not register the board fixture source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start board-src >/dev/null 2>&1
  assert_present "$home/state/procevent-inbox/board-src.1.result" \
    "the board fixture channel captured no result to feed"
  assert_absent "$home/state/procevent-inbox/board-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"

  show=$(tasks_in "$home" show "$alpha-decision-route-choice" --full)
  assert_contains "$show" "state: done" "the alpha hold stayed open after an any-origin feed"
  assert_contains "$show" "Resolution mode: answered" "the alpha hold did not record its close path"
  assert_contains "$show" "Decision key: route-choice" \
    "the recorded key is not the hold's own short decision key"
  show=$(tasks_in "$home" show "$long_id" --full)
  assert_contains "$show" "state: done" "the cross-origin long-identity hold stayed open"
  assert_contains "$show" "Answer: perishable-first" \
    "the long-identity hold did not record the captain's actual answer"
  show=$(tasks_in "$home" show "$alpha-decision-routed-phase" --full)
  assert_contains "$show" "state: queued" "any-origin closure closed a hold that still blocks routed work"
  assert_contains "$show" "held: yes" "any-origin closure released a hold that still blocks routed work"

  # Replay through the intake directly: idempotent for closed holds, `skipped:`
  # diagnostics for everything the feed must leave alone, nonzero because keys
  # were skipped.
  set +e
  out=$(run_lavish "$home" answers "$feedback" \
    | run_decisions "$home" answers --any-origin \
        --source "the captured result board-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an any-origin run that skipped keys reported success"
  assert_contains "$out" "closed: $alpha-decision-route-choice" \
    "replaying an identical any-origin capture was not idempotent: $out"
  assert_contains "$out" "closed: $long_id" \
    "replaying the long-identity answer was not idempotent: $out"
  assert_contains "$out" "skipped: merge.sample-task (not a full hold identity)" \
    "a merge instruction key was not skipped as a non-identity: $out"
  assert_contains "$out" "skipped: $alpha-decision-ghost" \
    "a nonexistent identity was not reported skipped: $out"
  assert_contains "$out" "skipped: $alpha-decision-routed-phase" \
    "the routed hold was not reported skipped: $out"
  assert_contains "$out" "origin=(any)" "the summary line did not name the any-origin marker: $out"

  printf 'Captain chose the routed phase.\n' > "$home/routed-phase-decision.txt"
  run_decisions "$home" resolve "$alpha" routed-phase \
    --decision-file "$home/routed-phase-decision.txt" --routed-to sample-routed-work >/dev/null \
    || fail "the routed close path stopped working after any-origin closure"
  run_decisions "$home" verify "$alpha" >/dev/null \
    || fail "alpha's answered decisions did not satisfy the completion gate"
  run_decisions "$home" verify "$beta" >/dev/null \
    || fail "beta's answered decision did not satisfy the completion gate"
  pass "an any-origin bound source closes full-identity holds across origins"
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

# The retention incident: closing a hold runs tasks-axi's ordinary Done pruning,
# so once more than `done_keep` captain decisions had been answered the earliest
# resolved records left data/backlog.md for the done archive, and closing the
# scout pruned more. Teardown then refused because the completion gate could no
# longer find records that still existed, unchanged, in the archive. Raising
# `done_keep` was the incident's workaround and is not the fix: the gate reads
# archived resolved records itself, and every close path stays idempotent and
# reopen-safe against them.
test_resolved_decisions_survive_done_pruning_before_the_completion_gate() {
  local home id archive key hold routed_hold before after json err
  home=$(make_home retention-prune)
  archive="$home/data/done-archive.md"
  assert_grep "done_keep = 10" "$home/.tasks.toml" \
    "the retention regression must run at the tracked done_keep, never a raised one"
  id=sample-retention-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample retention" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the retention origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample retention review\n\nTwelve captain choices remain.\n' > "$home/data/$id/report.md"

  for key in 01 02 03 04 05 06 07 08 09 10 11 12; do
    hold=$(run_decisions "$home" hold "$id" "choice-$key" \
      --title "Choose sample option $key" --reason "captain choice $key pending" --repo sample) \
      || fail "could not register retention hold choice-$key"
    [ "$hold" = "$id-decision-choice-$key" ] || fail "retention hold identity drifted: $hold"
    printf 'Use sample option %s.\n' "$key" > "$home/decision-$key.txt"
  done
  run_decisions "$home" complete "$id" \
    choice-01 choice-02 choice-03 choice-04 choice-05 choice-06 \
    choice-07 choice-08 choice-09 choice-10 choice-11 choice-12 >/dev/null \
    || fail "completion failed while every retention hold was still active"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "verification failed while every retention hold was still active"

  # The oldest record is the first one pruning reaches, so make it the routed
  # close so the routed path's record is proven to survive too.
  routed_hold="$id-decision-choice-01"
  tasks_in "$home" add sample-retention-work "Apply sample option 01" \
    --kind ship --repo sample --blocked-by "$routed_hold" >/dev/null \
    || fail "could not route work behind the first retention hold"
  run_decisions "$home" resolve "$id" choice-01 --decision-file "$home/decision-01.txt" \
    --routed-to sample-retention-work >/dev/null \
    || fail "could not resolve the routed retention decision"
  run_decisions "$home" decline "$id" choice-02 --decision-file "$home/decision-02.txt" >/dev/null \
    || fail "could not decline the second retention decision"
  for key in 03 04 05 06 07 08 09 10 11 12; do
    run_decisions "$home" answer "$id" "choice-$key" --decision-file "$home/decision-$key.txt" >/dev/null \
      || fail "could not answer retention decision choice-$key"
  done

  # The incident shape: more answered decisions than done_keep, so the earliest
  # resolved records are already gone from the live backlog and sit in the archive.
  if tasks_in "$home" show "$routed_hold" --full >/dev/null 2>&1; then
    fail "ordinary Done pruning did not evict the oldest resolved decision from the live backlog"
  fi
  assert_no_grep "$id-decision-choice-02 -" "$home/data/backlog.md" \
    "the second oldest resolved decision must be pruned by the twelfth close"
  assert_grep "- [x] $routed_hold -" "$archive" \
    "the pruned routed decision must be archived, never deleted"
  assert_grep "Use sample option 01." "$archive" \
    "the archived routed decision must keep the captain decision it recorded"
  assert_grep "- [x] $id-decision-choice-02 -" "$archive" \
    "the pruned declined decision must be archived, never deleted"
  # Closing the scout itself, as firstmate does when it records completion,
  # prunes one more.
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" >/dev/null \
    || fail "could not close the retention scout in the backlog"
  assert_grep "- [x] $id-decision-choice-03 -" "$archive" \
    "closing the scout must prune the third oldest resolved decision into the archive"
  assert_no_grep "$id-decision-choice-03 -" "$home/data/backlog.md" \
    "closing the scout must prune the third oldest resolved decision from the live backlog"

  before=$(shasum -a 256 "$archive" | awk '{print $1}')
  run_decisions "$home" verify "$id" > "$home/pruned-verify.out" 2> "$home/pruned-verify.err" \
    || fail "the completion gate lost resolved decisions to ordinary Done pruning: $(cat "$home/pruned-verify.err")"
  run_decisions "$home" complete "$id" choice-01 choice-02 choice-03 >/dev/null \
    || fail "a later review pass could not re-verify archived resolved decisions"

  # Every close path stays idempotent against an archived record and still
  # refuses a drifted retry, and an archived identity can never be reopened.
  run_decisions "$home" resolve "$id" choice-01 --decision-file "$home/decision-01.txt" \
    --routed-to sample-retention-work >/dev/null \
    || fail "an exact resolve retry against an archived record was not idempotent"
  run_decisions "$home" decline "$id" choice-02 --decision-file "$home/decision-02.txt" >/dev/null \
    || fail "an exact decline retry against an archived record was not idempotent"
  run_decisions "$home" answer "$id" choice-03 --decision-file "$home/decision-03.txt" >/dev/null \
    || fail "an exact answer retry against an archived record was not idempotent"
  run_decisions "$home" repair "$id" choice-03 --decision-file "$home/decision-03.txt" >/dev/null \
    || fail "repair did not recognize an archived record that already carries its resolution"
  printf 'Use a different sample option.\n' > "$home/drifted-decision.txt"
  if run_decisions "$home" answer "$id" choice-03 --decision-file "$home/drifted-decision.txt" \
    > "$home/archived-drift.out" 2> "$home/archived-drift.err"; then
    fail "an archived record accepted a different captain decision on retry"
  fi
  assert_grep "different captain decision" "$home/archived-drift.err" \
    "a drifted retry against an archived record must be refused for that reason"
  if run_decisions "$home" hold "$id" choice-01 \
    --title "Choose sample option 01" --reason "captain choice 01 pending" --repo sample \
    > "$home/archived-hold.out" 2> "$home/archived-hold.err"; then
    fail "an archived resolved identity was reopened as a fresh captain hold"
  fi
  assert_grep "new decision key" "$home/archived-hold.err" \
    "reopening an archived identity must point at a new decision key"
  assert_no_grep "- [ ] $routed_hold -" "$home/data/backlog.md" \
    "a refused reopen created a duplicate live identity"

  # An explicit prune of everything is the same durable tier as the implicit one.
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not archive the whole Done section"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "the completion gate lost resolved decisions to an explicit prune"
  after=$(shasum -a 256 "$archive" | awk '{print $1}')
  [ "$before" != "$after" ] || fail "the explicit prune fixture did not change the archive"
  before=$after
  run_teardown "$home" "$id" >/dev/null 2> "$home/pruned-teardown.err" \
    || fail "teardown refused a scout whose decisions were all answered and archived: $(cat "$home/pruned-teardown.err")"
  assert_absent "$home/state/$id.meta" "successful teardown left the origin metadata behind"
  after=$(shasum -a 256 "$archive" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "reading archived decisions rewrote the archive"
  for key in 01 02 03 04 05 06 07 08 09 10 11 12; do
    assert_grep "- [x] $id-decision-choice-$key -" "$archive" \
      "archived decision choice-$key did not survive the whole lifecycle"
  done
  json=$(run_bearings "$home") || fail "Bearings failed after archived resolutions"
  printf '%s' "$json" | jq -e --arg id "$id" '
    (.decisions_open | any(.id | startswith($id)) | not)
  ' >/dev/null || fail "an archived resolved decision resurfaced as an open Captain's Call: $json"
  err=$(cat "$home/pruned-verify.err")
  [ -z "$err" ] || fail "verification of archived decisions printed diagnostics: $err"
  pass "resolved decisions survive ordinary Done pruning for the completion gate"
}

# The routed close path can fail transiently after it has already recorded the
# captain decision and cleared the routing edge, and by the time it is retried its
# routed work can itself have been completed and pruned into the archive. Once the
# resolution body is recorded no other path can close the hold, so a routed task
# that is gone from the live backlog but durably present in the archive must not
# strand the origin. The absent-routed-task and drift guards must survive that.
test_resolve_retry_survives_a_routed_task_pruned_after_routing() {
  local home id hold dep archive pad show
  home=$(make_home routed-dep-pruned)
  archive="$home/data/done-archive.md"
  assert_grep "done_keep = 10" "$home/.tasks.toml" \
    "the routed-retry regression must run at the tracked done_keep, never a raised one"
  id=sample-routed-prune-review
  dep=sample-routed-prune-work
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample routed pruning" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the routed-prune origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample routed prune review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample routed option" --reason "captain routed choice pending" --repo sample) \
    || fail "could not register the routed-prune hold"
  run_decisions "$home" complete "$id" route >/dev/null \
    || fail "completion failed while the routed-prune hold was still active"
  tasks_in "$home" add "$dep" "Apply the sample routed option" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not route work behind the routed-prune hold"
  printf 'Use the sample routed option.\n' > "$home/routed-decision.txt"

  # The transient failure from the incident: the decision is recorded and the
  # routing edge is cleared, and only the final close of the hold fails.
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = done ] && [ "\${2:-}" = "$hold" ] && [ ! -f "\$FM_HOME/close-failed-once" ]; then
  : > "\$FM_HOME/close-failed-once"
  exit 1
fi
exec "\${REAL_TASKS_AXI:?}" "\$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/routed-decision.txt" \
    --routed-to "$dep" > "$home/transient.out" 2> "$home/transient.err"; then
    fail "resolve reported success although the close of the captain hold failed"
  fi
  rm -f "$home/fakebin/tasks-axi"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "the failed close still closed the hold"
  assert_contains "$show" "held: yes" "the failed close released the captain hold"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" \
    "the failed close lost the durable resolution record it had already written"
  show=$(tasks_in "$home" show "$dep" --full)
  assert_contains "$show" "blocked: no" "the failed close left the routing edge in place"

  # The routed work is completed and then pruned out of the live backlog by later
  # closes, exactly as ordinary Done retention does it.
  tasks_in "$home" "done" "$dep" >/dev/null || fail "could not complete the routed work"
  for pad in 01 02 03 04 05 06 07 08 09 10; do
    tasks_in "$home" add "sample-prune-pad-$pad" "Sample pad $pad" --kind ship --repo sample >/dev/null \
      || fail "could not create pad task $pad"
    tasks_in "$home" "done" "sample-prune-pad-$pad" >/dev/null || fail "could not close pad task $pad"
  done
  if tasks_in "$home" show "$dep" --full >/dev/null 2>&1; then
    fail "ordinary Done pruning did not evict the completed routed work from the live backlog"
  fi
  assert_grep "- [x] $dep -" "$archive" "the completed routed work must be archived, never deleted"

  printf 'Use a different sample routed option.\n' > "$home/drifted-routed-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/drifted-routed-decision.txt" \
    --routed-to "$dep" > "$home/drifted-retry.out" 2> "$home/drifted-retry.err"; then
    fail "the retry accepted a different captain decision once its routed work was archived"
  fi
  assert_grep "different captain decision" "$home/drifted-retry.err" \
    "a drifted decision retry must still be refused for that reason"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/routed-decision.txt" \
    --routed-to "$dep" --routed-to sample-prune-pad-10 \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "the retry accepted a different routed task set once its routed work was archived"
  fi
  assert_grep "different routed work" "$home/drifted-routes.err" \
    "a drifted routed set must still be refused for that reason"

  run_decisions "$home" resolve "$id" route --decision-file "$home/routed-decision.txt" \
    --routed-to "$dep" > "$home/retry.out" 2> "$home/retry.err" \
    || fail "the exact resolve retry failed after its routed work was pruned: $(cat "$home/retry.err")"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the successful retry did not close the captain hold"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "verification failed after a retry whose routed work was archived"

  # A routed task in neither tier is still refused, and the refusal still leaves
  # its own hold open.
  run_decisions "$home" hold "$id" ghost \
    --title "Choose the sample ghost option" --reason "captain ghost choice pending" --repo sample >/dev/null \
    || fail "could not register the absent-routed-task control hold"
  run_decisions "$home" complete "$id" route ghost >/dev/null \
    || fail "completion failed for the absent-routed-task control"
  if run_decisions "$home" resolve "$id" ghost --decision-file "$home/routed-decision.txt" \
    --routed-to sample-never-created-work > "$home/ghost.out" 2> "$home/ghost.err"; then
    fail "resolve routed a decision to work that is in neither the live backlog nor the archive"
  fi
  assert_grep "does not exist in the active home" "$home/ghost.err" \
    "a routed task in neither tier must still be refused as absent"
  show=$(tasks_in "$home" show "$id-decision-ghost" --full)
  assert_contains "$show" "state: queued" "the refused absent-routed-task resolve closed its hold"
  assert_contains "$show" "held: yes" "the refused absent-routed-task resolve released its hold"
  pass "a resolve retry survives routed work that Done pruning archived after routing"
}

# Reading the archive must not weaken the gate. A hold closed outside the script
# and then pruned still has no recorded captain decision, so verification and
# teardown keep refusing, no close path can invent the answer, repair reaches only
# live records, and nothing ever writes the archive.
test_archived_out_of_band_close_still_blocks_the_gate() {
  local home id hold archive pad before after
  home=$(make_home archived-out-of-band)
  archive="$home/data/done-archive.md"
  id=sample-archived-gap-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate an archived sample gap" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the archived-gap origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample archived gap review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" gap \
    --title "Choose the sample gap" --reason "captain gap choice pending" --repo sample) \
    || fail "could not register the archived-gap hold"
  run_decisions "$home" complete "$id" gap >/dev/null || fail "completion failed before the out-of-band close"
  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not reproduce the direct out-of-band close"
  for pad in 01 02 03 04 05 06 07 08 09 10; do
    tasks_in "$home" add "sample-pad-$pad" "Sample pad $pad" --kind ship --repo sample >/dev/null \
      || fail "could not create pad task $pad"
    tasks_in "$home" "done" "sample-pad-$pad" >/dev/null || fail "could not close pad task $pad"
  done
  if tasks_in "$home" show "$hold" --full >/dev/null 2>&1; then
    fail "the out-of-band closed hold was not pruned into the archive"
  fi
  assert_grep "- [x] $hold -" "$archive" "the out-of-band closed hold must be archived"
  assert_no_grep "Resolution recorded by fm-decision-hold" "$archive" \
    "the archived out-of-band close must carry no resolution record"
  before=$(shasum -a 256 "$archive" | awk '{print $1}')

  if run_decisions "$home" verify "$id" > "$home/gap-verify.out" 2> "$home/gap-verify.err"; then
    fail "verification accepted an archived captain decision that was never answered"
  fi
  assert_grep "without a recorded captain decision" "$home/gap-verify.err" \
    "verification must say the archived record has no recorded captain decision"
  if run_teardown "$home" "$id" > "$home/gap-teardown.out" 2> "$home/gap-teardown.err"; then
    fail "teardown proceeded while an archived captain decision had no recorded answer"
  fi
  assert_grep "REFUSED" "$home/gap-teardown.err" "teardown refusal must be explicit"
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"
  printf 'An answer recorded after the fact.\n' > "$home/late-decision.txt"
  if run_decisions "$home" repair "$id" gap --decision-file "$home/late-decision.txt" \
    > "$home/gap-repair.out" 2> "$home/gap-repair.err"; then
    fail "repair recorded a captain decision onto an archived record"
  fi
  assert_grep "repair reaches only" "$home/gap-repair.err" \
    "repair must say it cannot reach an archived record"
  if run_decisions "$home" answer "$id" gap --decision-file "$home/late-decision.txt" \
    > "$home/gap-answer.out" 2> "$home/gap-answer.err"; then
    fail "answer closed an archived record that fm-decision-hold never closed"
  fi
  if run_decisions "$home" decline "$id" gap --decision-file "$home/late-decision.txt" \
    > "$home/gap-decline.out" 2> "$home/gap-decline.err"; then
    fail "decline closed an archived record that fm-decision-hold never closed"
  fi
  if run_decisions "$home" resolve "$id" gap --decision-file "$home/late-decision.txt" \
    --routed-to "sample-pad-01" > "$home/gap-resolve.out" 2> "$home/gap-resolve.err"; then
    fail "resolve routed work through an archived record that fm-decision-hold never closed"
  fi
  if run_decisions "$home" hold "$id" gap \
    --title "Choose the sample gap" --reason "captain gap choice pending" --repo sample \
    > "$home/gap-hold.out" 2> "$home/gap-hold.err"; then
    fail "an archived closed identity was reopened as a fresh captain hold"
  fi
  assert_grep "closed outside fm-decision-hold" "$home/gap-hold.err" \
    "the refusal must name the out-of-band close that archived this identity"
  assert_grep "nothing was decided" "$home/gap-hold.err" \
    "the refusal must say no captain decision was ever recorded for this identity"
  assert_grep "teardown --force" "$home/gap-hold.err" \
    "the refusal must name the discard authority that is its actual remedy"
  assert_no_grep "new decision key" "$home/gap-hold.err" \
    "an unresolved archived identity must not be sent to a new decision key it cannot clear"
  after=$(shasum -a 256 "$archive" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "a refused path wrote the done archive"
  assert_no_grep "Resolution recorded by fm-decision-hold" "$home/data/backlog.md" \
    "a refused path wrote a resolution record into the live backlog"
  pass "an archived record without a recorded captain decision still blocks the gate"
}

# The archive view is staged under TMPDIR by the caller's process and then read by
# tasks-axi, which runs from FM_HOME. A relative TMPDIR therefore names two
# different directories across that move, and the read used to come back empty and
# be reported as an absent decision. An archived resolved decision must verify
# whatever TMPDIR the caller exports, from whatever directory the caller runs in.
test_archived_decision_verifies_under_a_relative_tmpdir() {
  local home id hold cwd leaked
  home=$(make_home relative-tmpdir)
  id=sample-relative-tmpdir-review
  hold="$id-decision-choice"
  archive_one_resolved_decision "$home" "$id" choice
  cwd="$TMP_ROOT/relative-tmpdir-cwd"
  mkdir -p "$cwd/view-tmp"

  run_decisions_in "$cwd" ./view-tmp "$home" verify "$id" > "$home/rel-verify.out" 2> "$home/rel-verify.err" \
    || fail "an archived resolved decision failed to verify under a relative TMPDIR: $(cat "$home/rel-verify.err")"
  [ ! -s "$home/rel-verify.err" ] \
    || fail "verifying under a relative TMPDIR printed diagnostics: $(cat "$home/rel-verify.err")"
  run_decisions_in "$cwd" ./view-tmp "$home" answer "$id" choice \
    --decision-file "$home/archive-decision.txt" >/dev/null 2> "$home/rel-answer.err" \
    || fail "an exact retry against an archived record failed under a relative TMPDIR: $(cat "$home/rel-answer.err")"
  if run_decisions_in "$cwd" ./view-tmp "$home" hold "$id" choice \
    --title "Choose the sample archive option" --reason "captain archive choice pending" --repo sample \
    > "$home/rel-hold.out" 2> "$home/rel-hold.err"; then
    fail "a relative TMPDIR let an archived resolved identity be reopened as a fresh hold"
  fi
  assert_grep "new decision key" "$home/rel-hold.err" \
    "reopening an archived identity must still point at a new decision key under a relative TMPDIR"
  assert_no_grep "- [ ] $hold -" "$home/data/backlog.md" \
    "a refused reopen created a duplicate live identity"

  leaked=$(find "$cwd/view-tmp" -name 'fm-decision-archive.*' | wc -l | tr -d ' ')
  [ "$leaked" = 0 ] || fail "the archive view leaked $leaked temp files into TMPDIR"
  run_teardown "$home" "$id" >/dev/null 2> "$home/rel-teardown.err" \
    || fail "teardown refused a scout whose only decision was answered and archived: $(cat "$home/rel-teardown.err")"
  pass "an archived resolved decision verifies under a relative TMPDIR"
}

# The archive is only readable while its dated block headings are the ones this
# reader rewrites into the Done section they were pruned from. An archive that
# holds records under some other heading is a read fault, not an empty archive, so
# it must be reported as one and must never let any path treat the decision as
# absent - or, worse, as satisfied.
test_unrecognized_archive_heading_never_reads_as_an_absent_decision() {
  local home id hold archive before after
  home=$(make_home unrecognized-archive-heading)
  archive="$home/data/done-archive.md"
  id=sample-unrecognized-heading-review
  hold="$id-decision-choice"
  archive_one_resolved_decision "$home" "$id" choice
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "the archived fixture did not verify before its heading was mangled"

  # Same bytes, same done task line, one heading this reader does not know.
  sed 's/^## Archived/## Vaulted/' "$archive" > "$archive.rewritten" \
    || fail "could not stage the unrecognized archive heading"
  mv "$archive.rewritten" "$archive" || fail "could not install the unrecognized archive heading"
  assert_grep "- [x] $hold -" "$archive" "the mangled archive must still hold the done task line"
  assert_no_grep "## Archived" "$archive" "the mangled archive must carry no recognized block heading"
  before=$(shasum -a 256 "$archive" | awk '{print $1}')

  if run_decisions "$home" verify "$id" > "$home/unrec-verify.out" 2> "$home/unrec-verify.err"; then
    fail "verification passed while the done archive could not be read"
  fi
  assert_grep "no recognized archive block heading" "$home/unrec-verify.err" \
    "an unreadable archive must name why it could not be read"
  assert_grep "cannot read $archive while verifying" "$home/unrec-verify.err" \
    "an unreadable archive must fail verification as a read fault"
  assert_no_grep "is absent from" "$home/unrec-verify.err" \
    "an unreadable archive must never be reported as an absent decision"
  assert_no_grep "verified:" "$home/unrec-verify.out" \
    "an unreadable archive must not print a verified inventory"

  if run_teardown "$home" "$id" > "$home/unrec-teardown.out" 2> "$home/unrec-teardown.err"; then
    fail "teardown proceeded while the done archive could not be read"
  fi
  assert_grep "REFUSED" "$home/unrec-teardown.err" "teardown refusal must be explicit"
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"
  if run_decisions "$home" repair "$id" choice --decision-file "$home/archive-decision.txt" \
    > "$home/unrec-repair.out" 2> "$home/unrec-repair.err"; then
    fail "repair recorded a captain decision while the done archive could not be read"
  fi
  assert_grep "cannot read $archive while repairing" "$home/unrec-repair.err" \
    "repair must report an unreadable archive as a read fault"
  if run_decisions "$home" hold "$id" choice \
    --title "Choose the sample archive option" --reason "captain archive choice pending" --repo sample \
    > "$home/unrec-hold.out" 2> "$home/unrec-hold.err"; then
    fail "an unreadable archive let a closed identity be reopened as a fresh captain hold"
  fi
  assert_grep "cannot read $archive to check" "$home/unrec-hold.err" \
    "hold must report an unreadable archive as a read fault"
  after=$(shasum -a 256 "$archive" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "a refused path wrote the done archive"
  assert_no_grep "Resolution recorded by fm-decision-hold" "$home/data/backlog.md" \
    "a refused path wrote a resolution record into the live backlog"
  pass "an unreadable done archive is never read as an absent decision"
}

# A post-teardown re-review reaches an origin whose metadata and report are both
# gone, so only the durable record still answers for which home owns it. An
# archive that cannot be read must be reported as that read fault, never as an
# origin this home does not own.
test_unreadable_archive_is_not_reported_as_a_foreign_origin() {
  local home id archive
  home=$(make_home unreadable-archive-origin)
  archive="$home/data/done-archive.md"
  id=sample-unreadable-origin-review
  archive_one_resolved_decision "$home" "$id" choice
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" >/dev/null \
    || fail "could not close the origin scout"
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not archive the origin scout"
  rm -f "$home/state/$id.meta" "$home/state/$id.status"
  rm -rf "${home:?}/data/$id"

  # Control: while the archive reads, the archived origin record answers for it.
  run_decisions "$home" hold "$id" late \
    --title "A late sample choice" --reason "late captain choice pending" --repo sample >/dev/null \
    || fail "a readable archive did not answer for the origin's ownership"

  sed 's/^## Archived/## Vaulted/' "$archive" > "$archive.rewritten" \
    || fail "could not stage the unrecognized archive heading"
  mv "$archive.rewritten" "$archive" || fail "could not install the unrecognized archive heading"
  if run_decisions "$home" hold "$id" later \
    --title "Another late sample choice" --reason "later captain choice pending" --repo sample \
    > "$home/origin-hold.out" 2> "$home/origin-hold.err"; then
    fail "hold accepted an origin whose ownership could not be read"
  fi
  assert_grep "while checking whether origin $id is owned by this home" "$home/origin-hold.err" \
    "hold must name the archive read fault"
  assert_no_grep "is not owned by the active home" "$home/origin-hold.err" \
    "an unreadable archive must never be reported as a foreign origin"
  if run_decisions "$home" complete "$id" --none \
    > "$home/origin-complete.out" 2> "$home/origin-complete.err"; then
    fail "completion accepted an origin whose ownership could not be read"
  fi
  assert_grep "while checking whether origin $id is owned by this home" "$home/origin-complete.err" \
    "completion must name the archive read fault"
  assert_no_grep "is not owned by the active home" "$home/origin-complete.err" \
    "an unreadable archive must never be reported as a foreign origin"
  assert_absent "$home/state/$id.meta" "a refused completion recreated origin metadata"
  pass "an unreadable archive is reported as a read fault, not as a foreign origin"
}

# The read-only view holds a full copy of the done archive, captain decision text
# included, so it must not outlive the lookup that staged it. A signal that kills
# the run mid-lookup must still take the view with it.
test_a_killed_archive_lookup_leaves_no_view_behind() {
  local home id viewdir marker job waited staged leaked
  home=$(make_home archive-view-signal)
  id=sample-archive-signal-review
  archive_one_resolved_decision "$home" "$id" choice
  viewdir="$home/view-tmp"
  mkdir -p "$viewdir"
  marker="$home/lookup-reached-the-view"

  # A tasks-axi that stalls only on the staged view, so the lookup can be killed
  # while the view exists; every other call is the real binary.
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *fm-decision-archive.*)
      : > "$marker"
      sleep 30
      exit 0
      ;;
  esac
done
exec "\${REAL_TASKS_AXI:?}" "\$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  set -m
  run_decisions_in "$home" "$viewdir" "$home" verify "$id" >/dev/null 2>&1 &
  job=$!
  set +m
  waited=0
  while [ ! -f "$marker" ] && [ "$waited" -lt 400 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -f "$marker" ] || fail "the archived lookup never reached its staged view"
  staged=$(find "$viewdir" -name 'fm-decision-archive.*' | wc -l | tr -d ' ')
  [ "$staged" = 1 ] || fail "expected exactly one staged archive view, found $staged"

  kill -TERM -"$job" 2>/dev/null || kill -TERM "$job" 2>/dev/null || true
  wait "$job" 2>/dev/null || true
  waited=0
  while [ "$(find "$viewdir" -name 'fm-decision-archive.*' | wc -l | tr -d ' ')" != 0 ] \
    && [ "$waited" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  leaked=$(find "$viewdir" -name 'fm-decision-archive.*' | wc -l | tr -d ' ')
  [ "$leaked" = 0 ] || fail "a killed archive lookup left $leaked read-only archive view(s) behind"
  pass "a killed archive lookup leaves no read-only view behind"
}

test_uninventoried_report_decision_refuses_completion

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
test_any_origin_binding_closes_across_origins
test_answer_preserves_every_unrouted_close_guard
test_chat_channel_feeds_the_same_keyed_answer_intake
test_resolved_decisions_survive_done_pruning_before_the_completion_gate
test_resolve_retry_survives_a_routed_task_pruned_after_routing
test_archived_out_of_band_close_still_blocks_the_gate
test_archived_decision_verifies_under_a_relative_tmpdir
test_unrecognized_archive_heading_never_reads_as_an_absent_decision
test_unreadable_archive_is_not_reported_as_a_foreign_origin
test_a_killed_archive_lookup_leaves_no_view_behind
