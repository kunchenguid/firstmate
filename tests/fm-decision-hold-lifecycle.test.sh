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
TASKS_AXI_PUBLIC="$ROOT/bin/tasks-axi"

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
  (cd "$home" && "$TASKS_AXI_BIN" "$@")
}

retention_tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && FM_HOME="$home" FM_TASKS_AXI_REAL="$TASKS_AXI_BIN" "$TASKS_AXI_PUBLIC" "$@")
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

write_legacy_identity_authorization() {  # <path> <hold-id> <origin-id> <decision-key> <body>
  local path=$1 id=$2 origin=$3 key=$4 body=$5 record_digest
  record_digest=$(printf '%s' "$body" | shasum -a 256 | awk '{print $1}')
  printf 'schema=fm-decision-legacy-identity.v1\nhold_id=%s\norigin=%s\ndecision_key=%s\nrecord_digest=%s\n' \
    "$id" "$origin" "$key" "$record_digest" > "$path"
}

archived_record_digest() {  # <archive> <hold-id>
  node - "$1" "$2" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const archive = fs.readFileSync(process.argv[2], "utf8");
const id = process.argv[3];
const lines = archive.split("\n");
let archived = false;
let current = null;
let found = null;
function finish() {
  if (!current) return;
  while (current.body.length && current.body[current.body.length - 1] === "") current.body.pop();
  if (current.header.startsWith(`- [x] ${id} - `)) {
    if (found !== null) process.exit(2);
    found = `${current.header}\n${current.body.join("\n")}`;
  }
  current = null;
}
for (const line of lines) {
  if (/^## Archived \d{4}-\d{2}-\d{2}$/.test(line)) { finish(); archived = true; continue; }
  if (/^## /.test(line)) { finish(); archived = false; continue; }
  if (/^- \[[ x]\] /.test(line)) { finish(); current = archived ? { header: line, body: [] } : null; continue; }
  if (current) {
    if (line === "") current.body.push("");
    else if (line.startsWith("  ")) current.body.push(line.slice(2));
    else finish();
  }
}
finish();
if (found === null) process.exit(1);
process.stdout.write(crypto.createHash("sha256").update(found).digest("hex"));
NODE
}

write_retention_authorization() {  # <path> <home> <hold-id> <origin-id> <decision-key> <archive>
  local path=$1 home=$2 id=$3 origin=$4 key=$5 archive=$6 owner_file owner backlog configured_archive digest
  owner_file=$(find "$home/data/decision-retention-provenance" -type f -name '*.owner' | head -1)
  [ -n "$owner_file" ] || fail "retention owner was not established before migration"
  owner=$(sed -n 's/^owner=//p' "$owner_file")
  backlog=$(sed -n 's/^backlog=//p' "$owner_file")
  configured_archive=$(sed -n 's/^archive=//p' "$owner_file")
  digest=$(archived_record_digest "$archive" "$id") \
    || fail "could not derive the serialized archived-record contract for $id"
  printf 'schema=fm-decision-retention-migration.v1\nowner=%s\nbacklog=%s\narchive=%s\nhold_id=%s\norigin=%s\ndecision_key=%s\nrecord_digest=%s\n' \
    "$owner" "$backlog" "$configured_archive" "$id" "$origin" "$key" "$digest" > "$path"
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

# A live origin can receive later review passes after older resolved decisions
# leave tasks-axi's bounded Done window. Archived resolution records remain the
# structured proof of those historical answers; completion must read that proof
# without restoring rows and displacing other retained history.
test_pruned_resolved_history_does_not_block_later_review() {
  local home id old_a old_b later before after done_count n show archive decision digest body
  home=$(make_home pruned-resolved-history)
  archive="$home/data/history/done.md"
  # Either failed step must invoke fail.
  # shellcheck disable=SC2015
  awk '{ if ($0 == "archive = \"data/done-archive.md\"") print "archive = \"data/history/done.md\""; else print }' \
    "$home/.tasks.toml" > "$home/.tasks.toml.tmp" && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not configure the retained-history archive"
  id=sample-long-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a long-lived sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create long-review origin"
  write_origin_meta "$home" "$id"
  printf 'done: first review pass complete\n' > "$home/state/$id.status"
  printf '# Long sample review\n\nLater passes may expose new decisions.\n' > "$home/data/$id/report.md"

  old_a=$(run_decisions "$home" hold "$id" old-a \
    --title "Choose old sample A" --reason "captain old a pending" --repo sample) \
    || fail "could not register old-a hold"
  old_b=$(run_decisions "$home" hold "$id" old-b \
    --title "Choose old sample B" --reason "captain old b pending" --repo sample) \
    || fail "could not register old-b hold"
  run_decisions "$home" complete "$id" old-a old-b >/dev/null \
    || fail "initial review could not record its decisions"
  printf 'Captain resolved old A.\n' > "$home/old-a.txt"
  printf 'Captain resolved old B.\n' > "$home/old-b.txt"
  run_decisions "$home" answer "$id" old-a --decision-file "$home/old-a.txt" >/dev/null \
    || fail "could not resolve old-a"
  run_decisions "$home" answer "$id" old-b --decision-file "$home/old-b.txt" >/dev/null \
    || fail "could not resolve old-b"
  decision='Captain resolved old A.'
  digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: (none)\nResolution mode: answered\n\nCaptain decision:\n%s\n\nRouted work:\n(none)' \
    "$digest" "$decision")
  tasks_in "$home" update "$old_a" --body "$body" >/dev/null \
    || fail "could not preserve a released-version resolution record"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "existing released-version metadata did not verify"

  # The tracked configuration retains ten Done rows. Twelve newer completions move
  # both historical decisions into the configured archive through public
  # tasks-axi behavior, reproducing the later-review failure without changing
  # the retention limit.
  for n in $(seq 1 12); do
    tasks_in "$home" add "sample-filler-$n" "Sample filler $n" --kind ship --repo sample >/dev/null \
      || fail "could not create retention filler $n"
    if [ "$n" -eq 12 ]; then
      retention_tasks_in "$home" "done" "sample-filler-$n" >/dev/null \
        || fail "could not complete retention filler $n through the public retention boundary"
    else
      tasks_in "$home" "done" "sample-filler-$n" --no-prune >/dev/null \
        || fail "could not retain filler $n before the retention transition"
    fi
  done
  assert_no_grep "- [x] $old_a -" "$home/data/backlog.md" \
    "old-a unexpectedly remained in the retained Done window"
  assert_no_grep "- [x] $old_b -" "$home/data/backlog.md" \
    "old-b unexpectedly remained in the retained Done window"
  assert_grep "- [x] $old_a -" "$archive" \
    "old-a was not pruned through normal configured retention"
  assert_grep "- [x] $old_b -" "$archive" \
    "old-b was not pruned through normal configured retention"
  if run_decisions "$home" hold "$id" old-a \
    --title "Choose old sample A" --reason "captain old a pending" --repo sample \
    > "$home/reused-key.out" 2> "$home/reused-key.err"; then
    fail "a pruned historical decision key was reused for a new hold"
  fi
  assert_grep "already durably resolved" "$home/reused-key.err" \
    "pruned historical identity did not remain reserved"

  body=$(printf 'Origin: %s\nDecision key: old-a\nState: awaiting captain decision.' "$id")
  tasks_in "$home" add "$old_a" "Choose old sample A" \
    --kind captain --repo sample --body "$body" >/dev/null \
    || fail "could not reproduce a pre-upgrade reused decision identity"
  tasks_in "$home" hold "$old_a" --reason "captain reused key pending" --kind captain >/dev/null \
    || fail "could not activate the pre-upgrade reused decision identity"
  if run_decisions "$home" complete "$id" old-a \
    > "$home/reused-generation.out" 2> "$home/reused-generation.err"; then
    fail "completion accepted an active decision with an older archived generation"
  fi
  assert_grep "both backlog and archived generations" "$home/reused-generation.err" \
    "active ownership did not reject a reused archived decision identity"
  if run_decisions "$home" verify "$id" \
    > "$home/reused-generation-verify.out" 2> "$home/reused-generation-verify.err"; then
    fail "verification accepted an active decision with an older archived generation"
  fi
  assert_grep "both backlog and archived generations" "$home/reused-generation-verify.err" \
    "durable ownership did not reject a reused archived decision identity"
  tasks_in "$home" rm "$old_a" >/dev/null \
    || fail "could not remove the pre-upgrade reused decision fixture"

  printf 'needs-decision [key=old-a]: choose old sample A again\ndone: later review pass complete\n' \
    > "$home/state/$id.status"
  if run_decisions "$home" complete "$id" old-a > "$home/reopened-old.out" 2> "$home/reopened-old.err"; then
    fail "archived history masked a currently open decision with no active hold"
  fi
  assert_grep "captain hold $old_a is absent" "$home/reopened-old.err" \
    "an open key did not require its current active owner"
  assert_no_grep "captain-held [key=old-a]" "$home/state/$id.status" \
    "failed active ownership check transferred the terminal decision"
  printf 'done: historical ownership guard verified\n' > "$home/state/$id.status"
  if run_decisions "$home" complete "$id" old-a \
    > "$home/no-status-current.out" 2> "$home/no-status-current.err"; then
    fail "explicit unresolved inventory accepted archive proof without an active hold"
  fi
  assert_grep "captain hold $old_a is absent" "$home/no-status-current.err" \
    "explicit unresolved ownership depended on status text"

  cp "$home/.tasks.toml" "$home/.tasks.toml.safe"
  awk '{ if ($0 == "backend = \"markdown\"") print "backend = \"unavailable\""; else print }' \
    "$home/.tasks.toml.safe" > "$home/.tasks.toml"
  if run_decisions "$home" verify "$id" > "$home/backend-error.out" 2> "$home/backend-error.err"; then
    fail "a tasks-axi read error was treated as pruned absence"
  fi
  assert_grep "could not read backlog item $old_a" "$home/backend-error.err" \
    "the active backend error was not distinguished from exact absence"
  mv "$home/.tasks.toml.safe" "$home/.tasks.toml"

  later=$(run_decisions "$home" hold "$id" later-choice \
    --title "Choose the later sample" --reason "captain later choice pending" --repo sample) \
    || fail "could not register the later decision"
  before=$(shasum -a 256 "$home/data/backlog.md" "$archive")
  run_decisions "$home" complete "$id" later-choice >/dev/null \
    || fail "later review was blocked by normally pruned resolved history"
  run_decisions "$home" complete "$id" later-choice >/dev/null \
    || fail "repeated later-review completion was not idempotent"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "later review did not verify against archived resolved history"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "repeated archived-history verification was not idempotent"
  after=$(shasum -a 256 "$home/data/backlog.md" "$archive")
  [ "$before" = "$after" ] \
    || fail "completion or verification restored and oscillated bounded Done history"
  done_count=$(grep -cE '^- \[x\] ' "$home/data/backlog.md")
  [ "$done_count" = 10 ] || fail "retained Done history changed its configured bound: $done_count"
  show=$(tasks_in "$home" show "$later" --full)
  assert_contains "$show" "state: queued" "later unresolved decision lost its active owner"
  assert_contains "$show" "held: yes" "later unresolved decision was released during completion"
  if run_decisions "$home" complete "$id" --none --resolved later-choice \
    > "$home/unresolved-as-resolved.out" 2> "$home/unresolved-as-resolved.err"; then
    fail "resolved inventory accepted an unresolved current decision"
  fi
  assert_grep "captain decision $later is not durably resolved" "$home/unresolved-as-resolved.err" \
    "resolved inventory did not require the current generation to be resolved"

  printf 'Captain resolved the later choice.\n' > "$home/later.txt"
  run_decisions "$home" answer "$id" later-choice --decision-file "$home/later.txt" >/dev/null \
    || fail "could not resolve the later decision"
  run_decisions "$home" complete "$id" later-choice >/dev/null \
    || fail "exact completion retry lost its previously verified current generation"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "completed later decision did not coexist with pruned history"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "resolved later decision did not verify"

  assert_grep 'decision_keys=later-choice,old-a,old-b' "$home/state/$id.meta" \
    "existing metadata inventory was not preserved compatibly"
  assert_grep 'decision_inventory_schema=fm-decision-completion.v1' "$home/state/$id.meta" \
    "completion metadata did not retain generation provenance"
  assert_grep 'decision_current_keys=later-choice,old-a,old-b' "$home/state/$id.meta" \
    "current decision generations were not persisted deterministically"
  run_teardown "$home" "$id" >/dev/null 2> "$home/legacy-teardown.err" \
    || fail "legacy history did not survive normal teardown: $(cat "$home/legacy-teardown.err")"
  assert_absent "$home/state/$id.meta" "normal teardown retained ephemeral origin metadata"
  rm -rf "$home/data/decision-resolution-attestations"
  before=$(shasum -a 256 "$home/data/backlog.md" "$archive")
  run_decisions "$home" complete "$id" --none --resolved old-a >/dev/null \
    || fail "post-teardown review could not verify the pruned released-version decision"
  run_decisions "$home" complete "$id" --none --resolved old-a >/dev/null \
    || fail "repeated post-teardown legacy verification was not idempotent"
  if run_decisions "$home" hold "$id" old-a \
    --title "Choose old sample A" --reason "captain old a pending" --repo sample \
    > "$home/post-teardown-reuse.out" 2> "$home/post-teardown-reuse.err"; then
    fail "post-teardown retry recreated a pruned released-version decision"
  fi
  assert_grep "already durably resolved" "$home/post-teardown-reuse.err" \
    "durable legacy identity did not reserve its key after origin teardown"
  after=$(shasum -a 256 "$home/data/backlog.md" "$archive")
  [ "$before" = "$after" ] \
    || fail "post-teardown compatibility changed the backlog or configured archive"
  pass "pruned resolved history permits later decisions without retention oscillation"
}

test_pre_boundary_retention_requires_exact_migration() {
  local home origin key hold n archive authorization wrong before after
  home=$(make_home pre-boundary-retention)
  origin=sample-pre-boundary-review
  key=historical-choice
  archive="$home/data/done-archive.md"
  tasks_in "$home" add "$origin" "Review pre-boundary history" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create pre-boundary origin"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the historical option" \
    --reason "captain historical option pending" --repo sample) \
    || fail "could not create pre-boundary hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not inventory pre-boundary hold"
  printf 'Captain resolved the historical option.\n' > "$home/historical-answer.txt"
  run_decisions "$home" answer "$origin" "$key" \
    --decision-file "$home/historical-answer.txt" >/dev/null \
    || fail "could not resolve pre-boundary hold"
  for n in $(seq 1 10); do
    tasks_in "$home" add "pre-boundary-filler-$n" "Pre-boundary filler $n" \
      --kind ship --repo sample >/dev/null \
      || fail "could not create pre-boundary filler $n"
    tasks_in "$home" "done" "pre-boundary-filler-$n" --no-prune >/dev/null \
      || fail "could not retain pre-boundary filler $n"
  done
  (cd "$home" && "$TASKS_AXI_BIN" prune --state "done" >/dev/null) \
    || fail "could not reproduce retention from before the shared transition boundary"
  assert_grep "- [x] $hold -" "$archive" \
    "pre-boundary decision was not moved into configured retention history"
  if run_decisions "$home" verify "$origin" \
    > "$home/unmigrated.out" 2> "$home/unmigrated.err"; then
    fail "unproven pre-boundary history bypassed explicit compatibility migration"
  fi
  assert_grep "lacks provenance from its configured Done retention transition" \
    "$home/unmigrated.err" "pre-boundary history did not fail closed"
  authorization="$home/pre-boundary-retention.authorization"
  wrong="$home/wrong-retention.authorization"
  write_retention_authorization "$authorization" "$home" "$hold" "$origin" "$key" "$archive"
  awk '
    /^record_digest=/ { print "record_digest=0000000000000000000000000000000000000000000000000000000000000000"; next }
    { print }
  ' "$authorization" > "$wrong"
  before=$(shasum -a 256 "$archive")
  if run_decisions "$home" migrate-retention "$origin" "$key" \
    --authorization-file "$wrong" > "$home/wrong-migration.out" 2> "$home/wrong-migration.err"; then
    fail "mismatched pre-boundary authorization migrated retained history"
  fi
  after=$(shasum -a 256 "$archive")
  [ "$before" = "$after" ] || fail "rejected retention migration changed the configured archive"
  run_decisions "$home" migrate-retention "$origin" "$key" \
    --authorization-file "$authorization" >/dev/null \
    || fail "exact pre-boundary retention authorization did not migrate"
  run_decisions "$home" migrate-retention "$origin" "$key" \
    --authorization-file "$authorization" >/dev/null \
    || fail "pre-boundary retention migration was not idempotent"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "explicitly migrated pre-boundary history did not verify"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "migrated pre-boundary verification was not idempotent"
  pass "pre-boundary retention history requires exact explicit migration"
}

test_legacy_completion_inventory_requires_explicit_provenance() {
  local home origin key hold body n
  home=$(make_home legacy-completion-provenance)
  origin=sample-generation-review
  key=reused-answer
  tasks_in "$home" add "$origin" "Review a legacy completion generation" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create legacy-generation origin"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the generation answer" \
    --reason "captain generation answer pending" --repo sample) \
    || fail "could not create the historical generation"
  printf 'Captain resolved the historical generation.\n' > "$home/generation-answer.txt"
  run_decisions "$home" answer "$origin" "$key" \
    --decision-file "$home/generation-answer.txt" >/dev/null \
    || fail "could not resolve the historical generation"
  for n in $(seq 1 10); do
    tasks_in "$home" add "generation-filler-$n" "Generation filler $n" \
      --kind ship --repo sample >/dev/null \
      || fail "could not create generation filler $n"
    tasks_in "$home" "done" "generation-filler-$n" --no-prune >/dev/null \
      || fail "could not retain generation filler $n before pruning"
  done
  run_decisions "$home" retention-prune >/dev/null \
    || fail "could not prune the historical generation through the public retention boundary"
  assert_grep "- [x] $hold -" "$home/data/done-archive.md" \
    "historical generation was not pruned through normal retention"

  body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
  tasks_in "$home" add "$hold" "Choose the replacement generation" \
    --kind captain --repo sample --body "$body" >/dev/null \
    || fail "could not reproduce a pre-upgrade replacement generation"
  tasks_in "$home" hold "$hold" --reason "captain replacement pending" --kind captain >/dev/null \
    || fail "could not activate the pre-upgrade replacement generation"
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$key" >> "$home/state/$origin.meta"
  tasks_in "$home" rm "$hold" >/dev/null \
    || fail "could not reproduce loss of the inventoried replacement generation"

  if run_decisions "$home" verify "$origin" \
    > "$home/legacy-verify.out" 2> "$home/legacy-verify.err"; then
    fail "legacy metadata inferred a missing current generation from older history"
  fi
  assert_grep "legacy decision inventory" "$home/legacy-verify.err" \
    "ambiguous legacy inventory did not require explicit provenance migration"
  if run_decisions "$home" complete "$origin" "$key" \
    > "$home/missing-current.out" 2> "$home/missing-current.err"; then
    fail "explicit current migration accepted an older archived generation"
  fi
  assert_grep "captain hold $hold is absent" "$home/missing-current.err" \
    "current migration did not require the missing active owner"

  run_decisions "$home" complete "$origin" --none --resolved "$key" >/dev/null \
    || fail "explicit historical migration did not preserve existing metadata"
  assert_grep 'decision_inventory_schema=fm-decision-completion.v1' "$home/state/$origin.meta" \
    "legacy inventory migration did not persist its schema"
  [ "$(grep '^decision_current_keys=' "$home/state/$origin.meta" | tail -1)" = 'decision_current_keys=' ] \
    || fail "historical migration falsely classified the key as current"
  assert_grep "decision_historical_keys=$key" "$home/state/$origin.meta" \
    "historical migration did not persist exact provenance"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "explicitly migrated historical inventory did not verify"
  pass "completion provenance distinguishes missing current and historical generations"
}

test_current_generation_rejects_an_older_archive_owner() {
  local home origin key hold n
  home=$(make_home archive-owner-generation)
  origin=sample-owner-review
  key=route-choice
  tasks_in "$home" add "$origin" "Review archive-owner generations" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create archive-owner origin"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the old route" --reason "captain old route pending" --repo sample) \
    || fail "could not create the old archive-owner generation"
  printf 'Captain resolved the old route.\n' > "$home/old-owner-answer.txt"
  run_decisions "$home" answer "$origin" "$key" \
    --decision-file "$home/old-owner-answer.txt" >/dev/null \
    || fail "could not resolve the old archive-owner generation"
  for n in $(seq 1 10); do
    tasks_in "$home" add "owner-filler-$n" "Owner filler $n" --kind ship --repo sample >/dev/null \
      || fail "could not add archive-owner filler $n"
    tasks_in "$home" "done" "owner-filler-$n" --no-prune >/dev/null \
      || fail "could not retain archive-owner filler $n"
  done
  run_decisions "$home" retention-prune >/dev/null \
    || fail "could not prune the old archive-owner generation"
  assert_grep "- [x] $hold -" "$home/data/done-archive.md" \
    "old archive-owner generation was not normally retained"

  awk '{ if ($0 == "archive = \"data/done-archive.md\"") print "archive = \"data/other-history.md\""; else print }' \
    "$home/.tasks.toml" > "$home/.tasks.toml.tmp" && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the new route" --reason "captain new route pending" --repo sample >/dev/null \
    || fail "could not create the replacement generation under its new retention owner"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not inventory the replacement generation"
  tasks_in "$home" rm "$hold" >/dev/null \
    || fail "could not reproduce loss of the replacement generation"
  awk '{ if ($0 == "archive = \"data/other-history.md\"") print "archive = \"data/done-archive.md\""; else print }' \
    "$home/.tasks.toml" > "$home/.tasks.toml.tmp" && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml"

  if run_decisions "$home" verify "$origin" > "$home/owner-verify.out" 2> "$home/owner-verify.err"; then
    fail "an older archive owner substituted for the missing current generation"
  fi
  assert_grep "different retention generation" "$home/owner-verify.err" \
    "missing current generation did not report its archive-owner mismatch"
  if run_decisions "$home" complete "$origin" --none --resolved "$key" \
    > "$home/owner-resolved.out" 2> "$home/owner-resolved.err"; then
    fail "--resolved let an older archive owner replace the missing current generation"
  fi
  assert_grep "different retention generation" "$home/owner-resolved.err" \
    "--resolved did not enforce the current generation archive owner"
  pass "current generations cannot fall back to older archive owners"
}

test_current_generation_rejects_an_older_retained_done_owner() {
  local home origin key hold
  home=$(make_home retained-owner-generation)
  origin=sample-retained-owner-review
  key=route-choice
  tasks_in "$home" add "$origin" "Review retained-owner generations" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create retained-owner origin"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the old retained route" --reason "captain old route pending" --repo sample) \
    || fail "could not create the old retained generation"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not inventory the old retained generation"
  printf 'Captain resolved the old retained route.\n' > "$home/old-retained-answer.txt"
  run_decisions "$home" answer "$origin" "$key" \
    --decision-file "$home/old-retained-answer.txt" >/dev/null \
    || fail "could not resolve the old retained generation"

  : > "$home/data/replacement-backlog.md"
  # shellcheck disable=SC2015
  awk '
    $0 == "path = \"data/backlog.md\"" { print "path = \"data/replacement-backlog.md\""; next }
    $0 == "archive = \"data/done-archive.md\"" { print "archive = \"data/replacement-archive.md\""; next }
    { print }
  ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp" \
    && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not switch to the replacement retention owner"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the replacement route" --reason "captain replacement route pending" --repo sample >/dev/null \
    || fail "could not create the replacement retained generation"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not inventory the replacement retained generation"
  tasks_in "$home" rm "$hold" >/dev/null \
    || fail "could not reproduce loss of the replacement retained generation"
  # shellcheck disable=SC2015
  awk '
    $0 == "path = \"data/replacement-backlog.md\"" { print "path = \"data/backlog.md\""; next }
    $0 == "archive = \"data/replacement-archive.md\"" { print "archive = \"data/done-archive.md\""; next }
    { print }
  ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp" \
    && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not restore the old retention owner"

  if run_decisions "$home" complete "$origin" --none --resolved "$key" \
    > "$home/retained-owner.out" 2> "$home/retained-owner.err"; then
    fail "an older retained Done row replaced the missing current generation"
  fi
  assert_grep "different retention generation" "$home/retained-owner.err" \
    "retained Done generation mismatch was not reported"
  pass "current generations cannot fall back to older retained Done owners"
}

test_current_generation_rejects_an_older_queued_owner() {
  local home origin key hold
  home=$(make_home queued-owner-generation)
  origin=sample-queued-owner-review
  key=route-choice
  tasks_in "$home" add "$origin" "Review queued-owner generations" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create queued-owner origin"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the old queued route" --reason "captain old route pending" --repo sample) \
    || fail "could not create the old queued generation"

  : > "$home/data/replacement-backlog.md"
  # shellcheck disable=SC2015
  awk '
    $0 == "path = \"data/backlog.md\"" { print "path = \"data/replacement-backlog.md\""; next }
    $0 == "archive = \"data/done-archive.md\"" { print "archive = \"data/replacement-archive.md\""; next }
    { print }
  ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp" \
    && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not switch to the replacement queued owner"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the replacement queued route" \
    --reason "captain replacement route pending" --repo sample >/dev/null \
    || fail "could not create the replacement queued generation"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not inventory the replacement queued generation"
  tasks_in "$home" rm "$hold" >/dev/null \
    || fail "could not reproduce loss of the replacement queued generation"
  # shellcheck disable=SC2015
  awk '
    $0 == "path = \"data/replacement-backlog.md\"" { print "path = \"data/backlog.md\""; next }
    $0 == "archive = \"data/replacement-archive.md\"" { print "archive = \"data/done-archive.md\""; next }
    { print }
  ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp" \
    && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not restore the old queued owner"

  if run_decisions "$home" verify "$origin" \
    > "$home/queued-owner-verify.out" 2> "$home/queued-owner-verify.err"; then
    fail "an older queued row replaced the missing current generation during verification"
  fi
  assert_grep "different retention generation" "$home/queued-owner-verify.err" \
    "queued generation mismatch was not reported during verification"
  if run_decisions "$home" complete "$origin" "$key" \
    > "$home/queued-owner-complete.out" 2> "$home/queued-owner-complete.err"; then
    fail "an older queued row replaced the missing current generation during completion"
  fi
  assert_grep "different retention generation" "$home/queued-owner-complete.err" \
    "queued generation mismatch was not reported during completion"
  pass "current generations cannot fall back to older queued owners"
}

test_source_verifiable_legacy_inventories_migrate_automatically() {
  local home origin active retained first second hold decision digest body token inventory later later_hold
  home=$(make_home source-verifiable-legacy-inventory)
  origin=sample-upgraded-review
  active="active-choice"
  retained="retained-choice"
  tasks_in "$home" add "$origin" "Review an upgraded inventory" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create upgraded-inventory origin"
  write_origin_meta "$home" "$origin"
  run_decisions "$home" hold "$origin" "$active" \
    --title "Choose the active option" --reason "captain active option pending" --repo sample >/dev/null \
    || fail "could not create source-verifiable active hold"
  hold=$(run_decisions "$home" hold "$origin" "$retained" \
    --title "Choose the retained option" --reason "captain retained option pending" --repo sample) \
    || fail "could not create source-verifiable retained hold"
  printf 'Captain resolved the retained option.\n' > "$home/retained-answer.txt"
  run_decisions "$home" answer "$origin" "$retained" \
    --decision-file "$home/retained-answer.txt" >/dev/null \
    || fail "could not resolve source-verifiable retained hold"
  printf 'decisions_reviewed=1\ndecision_keys=%s,%s\n' "$active" "$retained" \
    >> "$home/state/$origin.meta"

  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "source-verifiable released-version inventory did not migrate automatically"
  assert_grep 'decision_inventory_schema=fm-decision-completion.v1' "$home/state/$origin.meta" \
    "automatic inventory migration did not persist its schema"
  assert_grep "decision_current_keys=$active,$retained" "$home/state/$origin.meta" \
    "automatic inventory migration did not classify active and retained Done records"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "repeated verification of an automatically migrated inventory failed"
  run_decisions "$home" complete "$origin" "$active" "$retained" >/dev/null \
    || fail "the released-version completion retry was not idempotent after retained resolution"

  home=$(make_home multipass-legacy-inventory)
  origin=sample-multipass-review
  first="first-choice"
  second="second-choice"
  tasks_in "$home" add "$origin" "Review a multipass legacy inventory" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create multipass legacy origin"
  write_origin_meta "$home" "$origin"
  run_decisions "$home" hold "$origin" "$first" \
    --title "Choose the first option" --reason "captain first option pending" --repo sample >/dev/null \
    || fail "could not create first multipass hold"
  printf 'Captain resolved the first multipass option.\n' > "$home/first-answer.txt"
  run_decisions "$home" answer "$origin" "$first" \
    --decision-file "$home/first-answer.txt" >/dev/null \
    || fail "could not resolve first multipass hold"
  run_decisions "$home" hold "$origin" "$second" \
    --title "Choose the second option" --reason "captain second option pending" --repo sample >/dev/null \
    || fail "could not create second multipass hold"
  printf 'Captain resolved the second multipass option.\n' > "$home/second-answer.txt"
  run_decisions "$home" answer "$origin" "$second" \
    --decision-file "$home/second-answer.txt" >/dev/null \
    || fail "could not resolve second multipass hold"
  printf 'decisions_reviewed=1\ndecision_keys=%s,%s\n' "$first" "$second" \
    >> "$home/state/$origin.meta"

  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "multipass released-version inventory did not migrate automatically"
  assert_grep 'decision_last_inventory_known=0' "$home/state/$origin.meta" \
    "legacy union migration invented an exact last completion"
  [ "$(grep '^decision_last_current_keys=' "$home/state/$origin.meta" | tail -1)" = 'decision_last_current_keys=' ] \
    || fail "legacy union migration grouped all retained keys into the last completion"
  run_decisions "$home" complete "$origin" "$second" >/dev/null \
    || fail "actual last released-version completion could not establish its retry inventory"
  assert_grep 'decision_last_inventory_known=1' "$home/state/$origin.meta" \
    "successful post-upgrade completion did not establish its exact inventory"
  assert_grep "decision_last_current_keys=$second" "$home/state/$origin.meta" \
    "post-upgrade completion did not preserve the actual last key list"
  run_decisions "$home" complete "$origin" "$second" >/dev/null \
    || fail "actual last released-version completion was not idempotent"

  home=$(make_home live-legacy-historical-reclassification)
  origin=sample-live-legacy-review
  retained=old-choice
  tasks_in "$home" add "$origin" "Review a live legacy inventory" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create live legacy origin"
  write_origin_meta "$home" "$origin"
  run_decisions "$home" hold "$origin" "$retained" \
    --title "Choose the old option" --reason "captain old option pending" --repo sample >/dev/null \
    || fail "could not create live legacy hold"
  printf 'Captain resolved the old option.\n' > "$home/old-answer.txt"
  run_decisions "$home" answer "$origin" "$retained" \
    --decision-file "$home/old-answer.txt" >/dev/null \
    || fail "could not resolve live legacy hold"
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$retained" >> "$home/state/$origin.meta"
  run_decisions "$home" complete "$origin" --none --resolved "$retained" >/dev/null \
    || fail "explicit historical reclassification with surviving legacy metadata failed"
  [ "$(grep '^decision_current_keys=' "$home/state/$origin.meta" | tail -1)" = 'decision_current_keys=' ] \
    || fail "explicit live reclassification retained a false current generation"
  assert_grep "decision_historical_keys=$retained" "$home/state/$origin.meta" \
    "explicit live reclassification did not persist historical provenance"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "explicitly reclassified live legacy metadata did not verify"

  home=$(make_home legacy-verify-durable-inventory)
  origin=sample-legacy-verify-review
  active=missing-choice
  later="later-choice"
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review legacy verification provenance" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create legacy-verification origin"
  write_origin_meta "$home" "$origin"
  printf 'done: legacy verification complete\n' > "$home/state/$origin.status"
  printf '# Legacy verification provenance\n' > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" "$active" \
    --title "Choose the legacy option" --reason "captain legacy option pending" --repo sample) \
    || fail "could not create legacy-verification hold"
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$active" >> "$home/state/$origin.meta"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "legacy verification did not classify its active generation"
  token=$(printf '%s' "$origin" | shasum -a 256 | awk '{print $1}')
  inventory="$home/data/decision-completion-inventories/$token.inventory"
  assert_present "$inventory" "legacy verification did not persist durable provenance"
  assert_grep "decision_current_keys=$active" "$inventory" \
    "legacy verification omitted its active generation from durable provenance"
  run_teardown "$home" "$origin" >/dev/null 2> "$home/legacy-verify-teardown.err" \
    || fail "legacy-verification teardown failed: $(cat "$home/legacy-verify-teardown.err")"
  tasks_in "$home" rm "$hold" >/dev/null \
    || fail "could not reproduce loss of the legacy-verified hold"
  later_hold=$(run_decisions "$home" hold "$origin" "$later" \
    --title "Choose the later option" --reason "captain later option pending" --repo sample) \
    || fail "could not create later hold after legacy verification"
  if run_decisions "$home" complete "$origin" "$later" \
    > "$home/legacy-verify-missing.out" 2> "$home/legacy-verify-missing.err"; then
    fail "later completion forgot a legacy-verified active decision"
  fi
  assert_grep "captain decision $hold is absent" "$home/legacy-verify-missing.err" \
    "durable legacy verification did not enforce the missing active owner"
  assert_contains "$(tasks_in "$home" show "$later_hold" --full)" "held: yes" \
    "refused later completion changed the later active hold"

  home=$(make_home trailing-marker-legacy-identity)
  origin=sample-trailing-review
  retained=route-decision-
  tasks_in "$home" add "$origin" "Review a trailing-marker legacy identity" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create trailing-marker origin"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" "$retained" \
    --title "Choose the trailing-marker route" \
    --reason "captain trailing route pending" --repo sample) \
    || fail "could not create trailing-marker hold"
  decision='Captain resolved the trailing-marker route.'
  printf '%s\n' "$decision" > "$home/trailing-answer.txt"
  run_decisions "$home" answer "$origin" "$retained" \
    --decision-file "$home/trailing-answer.txt" >/dev/null \
    || fail "could not resolve trailing-marker hold"
  digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: (none)\nResolution mode: answered\n\nCaptain decision:\n%s\n\nRouted work:\n(none)' \
    "$digest" "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not preserve trailing-marker released-version resolution"
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$retained" >> "$home/state/$origin.meta"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "an invalid empty-key split made a unique legacy identity ambiguous"
  pass "source-verifiable legacy inventories migrate without weakening archive generations"
}

test_metadata_free_completion_retries_remain_idempotent() {
  local home origin key hold token inventory linked
  home=$(make_home metadata-free-completion-retry)
  origin=sample-post-teardown-review
  key="later-choice"
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review metadata-free completion" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create metadata-free origin"
  write_origin_meta "$home" "$origin"
  printf 'done: initial review complete\n' > "$home/state/$origin.status"
  printf '# Metadata-free completion review\n' > "$home/data/$origin/report.md"
  run_decisions "$home" complete "$origin" --none >/dev/null \
    || fail "initial completion before teardown failed"
  run_teardown "$home" "$origin" >/dev/null 2> "$home/metadata-free-teardown.err" \
    || fail "could not tear down metadata-free origin: $(cat "$home/metadata-free-teardown.err")"
  tasks_in "$home" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null \
    || fail "could not archive metadata-free origin"
  assert_absent "$home/state/$origin.meta" "teardown retained metadata-free origin metadata"

  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the later option" --reason "captain later option pending" --repo sample) \
    || fail "could not create post-teardown decision"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "first metadata-free completion failed"
  token=$(printf '%s' "$origin" | shasum -a 256 | awk '{print $1}')
  inventory="$home/data/decision-completion-inventories/$token.inventory"
  assert_present "$inventory" "metadata-free completion provenance was not persisted"
  assert_grep "decision_current_keys=$key" "$inventory" \
    "metadata-free completion did not preserve its current generation"
  printf 'Captain resolved the later post-teardown option.\n' > "$home/later-post-teardown.txt"
  run_decisions "$home" answer "$origin" "$key" \
    --decision-file "$home/later-post-teardown.txt" >/dev/null \
    || fail "could not resolve metadata-free decision"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "exact metadata-free completion retry lost its resolved current generation"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "repeated metadata-free completion retry was not idempotent"
  assert_contains "$(tasks_in "$home" show "$hold" --full)" "state: done" \
    "metadata-free completion retry changed the resolved hold"

  linked="$home/data/decision-completion-inventories/linked.inventory"
  ln "$inventory" "$linked" || fail "could not create completion-inventory hardlink fixture"
  if run_decisions "$home" complete "$origin" "$key" \
    > "$home/hardlinked-inventory.out" 2> "$home/hardlinked-inventory.err"; then
    fail "metadata-free completion followed a hardlinked provenance record"
  fi
  assert_grep "decision completion inventory is hardlinked" "$home/hardlinked-inventory.err" \
    "hardlinked metadata-free provenance did not fail safely"
  rm -f "$linked"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "removing the hardlink did not restore metadata-free completion"
  pass "metadata-free completion provenance makes resolved retries idempotent"
}

test_live_completion_provenance_survives_teardown() {
  local home origin key hold token inventory later later_hold before after
  home=$(make_home live-completion-retry)
  origin=sample-live-completion-review
  key="first-choice"
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review live completion provenance" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create live-completion origin"
  write_origin_meta "$home" "$origin"
  printf 'done: live completion review complete\n' > "$home/state/$origin.status"
  printf '# Live completion provenance review\n' > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the first option" --reason "captain first option pending" --repo sample) \
    || fail "could not create live-completion hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "live completion failed"
  token=$(printf '%s' "$origin" | shasum -a 256 | awk '{print $1}')
  inventory="$home/data/decision-completion-inventories/$token.inventory"
  assert_present "$inventory" "live completion did not persist durable provenance"
  assert_grep "decision_current_keys=$key" "$inventory" \
    "live completion provenance omitted its current generation"
  run_teardown "$home" "$origin" >/dev/null 2> "$home/live-teardown.err" \
    || fail "live completion teardown failed: $(cat "$home/live-teardown.err")"
  tasks_in "$home" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null \
    || fail "could not archive live-completion origin"
  assert_absent "$home/state/$origin.meta" "teardown retained live-completion metadata"
  printf 'Captain resolved the first option.\n' > "$home/first-choice.txt"
  run_decisions "$home" answer "$origin" "$key" --decision-file "$home/first-choice.txt" >/dev/null \
    || fail "could not resolve the post-teardown live decision"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "live completion retry lost durable provenance after teardown"
  assert_contains "$(tasks_in "$home" show "$hold" --full)" "state: done" \
    "post-teardown live completion retry changed the resolved hold"

  home=$(make_home live-completion-missing-owner)
  origin=sample-live-missing-review
  key=missing-choice
  later="later-choice"
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review missing live ownership" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create missing-owner origin"
  write_origin_meta "$home" "$origin"
  printf 'done: missing-owner review complete\n' > "$home/state/$origin.status"
  printf '# Missing live ownership review\n' > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the missing option" --reason "captain missing option pending" --repo sample) \
    || fail "could not create missing-owner hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not persist missing-owner completion provenance"
  run_teardown "$home" "$origin" >/dev/null 2> "$home/missing-owner-teardown.err" \
    || fail "missing-owner teardown failed: $(cat "$home/missing-owner-teardown.err")"
  tasks_in "$home" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null \
    || fail "could not archive missing-owner origin"
  tasks_in "$home" rm "$hold" >/dev/null \
    || fail "could not reproduce loss of the inventoried active hold"
  later_hold=$(run_decisions "$home" hold "$origin" "$later" \
    --title "Choose the later option" --reason "captain later option pending" --repo sample) \
    || fail "could not create the later post-teardown hold"
  if run_decisions "$home" complete "$origin" "$later" \
    > "$home/missing-owner.out" 2> "$home/missing-owner.err"; then
    fail "later completion forgot a live decision whose metadata was removed"
  fi
  assert_grep "captain decision $hold is absent" "$home/missing-owner.err" \
    "later completion did not enforce durable ownership of the missing hold"
  assert_contains "$(tasks_in "$home" show "$later_hold" --full)" "held: yes" \
    "refused later completion changed its active hold"

  home=$(make_home completion-persist-failure)
  origin=sample-persist-failure-review
  key=durable-choice
  tasks_in "$home" add "$origin" "Review completion persistence" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create persistence-failure origin"
  write_origin_meta "$home" "$origin"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the durable option" --reason "captain durable option pending" --repo sample >/dev/null \
    || fail "could not create persistence-failure hold"
  before=$(shasum -a 256 "$home/state/$origin.meta" | awk '{print $1}')
  cat > "$home/fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=''
for arg in "$@"; do last=$arg; done
case "$last" in
  */decision-completion-inventories/*.inventory) exit 1 ;;
  *) exec /bin/mv "$@" ;;
esac
SH
  chmod +x "$home/fakebin/mv"
  if run_decisions "$home" complete "$origin" "$key" \
    > "$home/persist-failure.out" 2> "$home/persist-failure.err"; then
    fail "completion succeeded without durable provenance persistence"
  fi
  assert_grep "could not persist decision completion inventory" "$home/persist-failure.err" \
    "durable provenance persistence failure was not explicit"
  after=$(shasum -a 256 "$home/state/$origin.meta" | awk '{print $1}')
  [ "$before" = "$after" ] \
    || fail "failed durable persistence published ephemeral completion metadata"
  rm -f "$home/fakebin/mv"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "completion did not recover after durable persistence was restored"
  pass "live completion provenance survives teardown and enforces ownership"
}

test_queued_legacy_resolution_is_attested_before_teardown() {
  local home id hold decision digest body show
  home=$(make_home queued-legacy-resolution)
  id=sample-partial-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a partial legacy resolution" --kind scout --repo sample --start >/dev/null \
    || fail "could not create partial legacy origin"
  write_origin_meta "$home" "$id"
  printf 'done: partial legacy review complete\n' > "$home/state/$id.status"
  printf '# Partial legacy review\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" partial-answer \
    --title "Choose the partial answer" --reason "captain partial answer pending" --repo sample) \
    || fail "could not create partial legacy hold"
  run_decisions "$home" complete "$id" partial-answer >/dev/null \
    || fail "could not inventory partial legacy hold"
  decision='Captain recorded the partial legacy answer.'
  printf '%s\n' "$decision" > "$home/partial-answer.txt"
  digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: (none)\nResolution mode: answered\n\nCaptain decision:\n%s\n\nRouted work:\n(none)' \
    "$digest" "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not reproduce a queued released-version resolution"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "partial legacy fixture did not remain queued"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "queued legacy resolution blocked teardown: $(cat "$home/teardown.err")"
  assert_absent "$home/state/$id.meta" "teardown retained partial legacy metadata"
  run_decisions "$home" answer "$id" partial-answer --decision-file "$home/partial-answer.txt" >/dev/null \
    || fail "post-teardown partial resolution retry lost its legacy identity"
  run_decisions "$home" answer "$id" partial-answer --decision-file "$home/partial-answer.txt" >/dev/null \
    || fail "repeated partial resolution retry was not idempotent"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "partial legacy retry did not close the hold"
  assert_contains "$show" "Origin: $id" "partial legacy retry did not retain its exact origin"
  pass "queued legacy resolution identity survives teardown and retry"
}

test_legacy_migration_rejects_missing_conflicting_or_foreign_owners() {
  local home source victim collision decision digest body foreign id hold n attestation_token
  home=$(make_home ambiguous-legacy-history)
  source=sample
  victim=sample-decision-route
  tasks_in "$home" add "$victim" "Review an ambiguous claimant" --kind scout --repo sample --start >/dev/null \
    || fail "could not create ambiguous legacy claimant"
  write_origin_meta "$home" "$source"
  write_origin_meta "$home" "$victim"
  collision=$(run_decisions "$home" hold "$source" route-decision-later \
    --title "Choose the old ambiguous route" --reason "captain ambiguous route pending" --repo sample) \
    || fail "could not create ambiguous legacy hold"
  run_decisions "$home" complete "$source" route-decision-later >/dev/null \
    || fail "could not inventory ambiguous legacy source"
  decision='Captain resolved the old ambiguous route.'
  printf '%s\n' "$decision" > "$home/ambiguous.txt"
  run_decisions "$home" answer "$source" route-decision-later --decision-file "$home/ambiguous.txt" >/dev/null \
    || fail "could not resolve ambiguous legacy source"
  digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: (none)\nResolution mode: answered\n\nCaptain decision:\n%s\n\nRouted work:\n(none)' \
    "$digest" "$decision")
  tasks_in "$home" update "$collision" --body "$body" >/dev/null \
    || fail "could not preserve ambiguous released-version history"
  printf 'decisions_reviewed=1\ndecision_keys=later\n' >> "$home/state/$victim.meta"
  rm -f "$home/state/$source.meta"
  for n in $(seq 1 10); do
    tasks_in "$home" add "ambiguous-filler-$n" "Ambiguous filler $n" --kind ship --repo sample >/dev/null \
      || fail "could not create ambiguous filler $n"
    tasks_in "$home" "done" "ambiguous-filler-$n" --no-prune >/dev/null \
      || fail "could not retain ambiguous filler $n before pruning"
  done
  run_decisions "$home" retention-prune >/dev/null \
    || fail "could not prune ambiguous history through the public retention boundary"
  assert_grep "- [x] $collision -" "$home/data/done-archive.md" \
    "ambiguous legacy record was not pruned normally"
  if run_decisions "$home" complete "$victim" --none --resolved later \
    > "$home/ambiguous.out" 2> "$home/ambiguous.err"; then
    fail "claimant metadata rebound ambiguous legacy history"
  fi
  attestation_token=$(printf '%s' "$collision" | shasum -a 256 | awk '{print $1}')
  assert_absent "$home/data/decision-resolution-attestations/$attestation_token.attestation" \
    "ambiguous claimant created a durable legacy attestation"
  if run_decisions "$home" migrate-legacy "$victim" later \
    --decision-file "$home/ambiguous.txt" \
    > "$home/claimant-migration.out" 2> "$home/claimant-migration.err"; then
    fail "claimant metadata and a replayed answer migrated another owner's legacy history"
  fi
  assert_grep "requires an independent --identity-file authorization" "$home/claimant-migration.err" \
    "ambiguous claimant migration did not require independent authorization"
  assert_absent "$home/data/decision-resolution-attestations/$attestation_token.attestation" \
    "refused claimant migration created a durable legacy attestation"

  home=$(make_home foreign-legacy-state)
  id=sample-state-review
  tasks_in "$home" add "$id" "Review legacy state ownership" --kind scout --repo sample --start >/dev/null \
    || fail "could not create state-bound legacy origin"
  write_origin_meta "$home" "$id"
  hold=$(run_decisions "$home" hold "$id" old-answer \
    --title "Choose the state-bound answer" --reason "captain state answer pending" --repo sample) \
    || fail "could not create state-bound legacy hold"
  run_decisions "$home" complete "$id" old-answer >/dev/null \
    || fail "could not inventory state-bound legacy hold"
  decision='Captain resolved the state-bound answer.'
  printf '%s\n' "$decision" > "$home/state-answer.txt"
  run_decisions "$home" answer "$id" old-answer --decision-file "$home/state-answer.txt" >/dev/null \
    || fail "could not resolve state-bound legacy hold"
  digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: (none)\nResolution mode: answered\n\nCaptain decision:\n%s\n\nRouted work:\n(none)' \
    "$digest" "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not preserve state-bound released-version history"
  foreign=$(make_home foreign-legacy-state-claimant)
  write_origin_meta "$foreign" "$id"
  printf 'decisions_reviewed=1\ndecision_keys=old-answer\n' >> "$foreign/state/$id.meta"
  if PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$foreign/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" complete "$id" --none --resolved old-answer \
    > "$foreign/state-override.out" 2> "$foreign/state-override.err"; then
    fail "foreign state metadata authorized legacy migration"
  fi
  assert_grep "configured state directory is outside the active home" "$foreign/state-override.err" \
    "foreign state metadata did not fail the home boundary"
  mv "$home/state" "$home/state-real"
  ln -s "$foreign/state" "$home/state"
  if PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" complete "$id" --none --resolved old-answer \
    > "$foreign/state-symlink.out" 2> "$foreign/state-symlink.err"; then
    fail "symlinked state metadata authorized legacy migration"
  fi
  assert_grep "authoritative state directory is unsafe" "$foreign/state-symlink.err" \
    "symlinked state metadata did not fail safely"
  pass "legacy migration rejects missing, conflicting, and foreign ownership"
}

test_legacy_identity_compatibility_is_bounded_and_authorized() {
  local home origin key hold decision digest body attestation stage stage_name alternate token unrelated n
  local authorization wrong_authorization
  home=$(make_home compatible-unambiguous-legacy)
  origin=sample-compatible-review
  key=old-answer
  tasks_in "$home" add "$origin" "Review compatible legacy identity" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create compatible legacy origin"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the compatible legacy answer" \
    --reason "captain compatible answer pending" --repo sample) \
    || fail "could not create compatible legacy hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not inventory compatible legacy hold"
  decision='Captain resolved the compatible legacy identity.'
  printf '%s\n' "$decision" > "$home/compatible-answer.txt"
  run_decisions "$home" answer "$origin" "$key" \
    --decision-file "$home/compatible-answer.txt" >/dev/null \
    || fail "could not resolve compatible legacy hold"
  digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: (none)\nResolution mode: answered\n\nCaptain decision:\n%s\n\nRouted work:\n(none)' \
    "$digest" "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not preserve unambiguous released-version history"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "unambiguous released-version identity required ephemeral proof"
  token=$(printf '%s' "$hold" | shasum -a 256 | awk '{print $1}')
  attestation="$home/data/decision-resolution-attestations/$token.attestation"
  assert_present "$attestation" "compatible legacy verification did not persist exact identity"

  stage_name=.attestation.A1b2C3
  stage="$home/data/decision-resolution-attestations/$stage_name"
  printf 'publication_stage=%s\n' "$stage_name" >> "$attestation"
  ln "$attestation" "$stage" \
    || fail "could not reproduce authenticated interrupted attestation publication"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "authenticated interrupted attestation publication was not recoverable"
  assert_absent "$stage" "attestation retry retained its authenticated staging link"

  unrelated="$home/data/decision-resolution-attestations/.attestation.interrupted"
  ln "$attestation" "$unrelated" || fail "could not reproduce an unrelated attestation hardlink"
  if run_decisions "$home" verify "$origin" > "$home/unrelated-link.out" 2> "$home/unrelated-link.err"; then
    fail "an unrelated hardlink was treated as an interrupted attestation publication"
  fi
  assert_present "$unrelated" "verification removed an unauthenticated attestation hardlink"
  assert_grep "is hardlinked" "$home/unrelated-link.err" \
    "an unrelated attestation hardlink did not fail safely"
  rm -f "$unrelated"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "removing the unrelated hardlink did not restore verification"

  rm -f "$home/state/$origin.meta" "$attestation"
  run_decisions "$home" complete "$origin" --none --resolved "$key" >/dev/null \
    || fail "unambiguous legacy identity depended on metadata or attestation"

  home=$(make_home compatible-reviewed-ambiguous-legacy)
  origin=sample
  key=route-decision-later
  alternate=sample-decision-route
  tasks_in "$home" add "$origin" "Review ambiguous legacy identity" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create ambiguous legacy origin"
  tasks_in "$home" add "$alternate" "Review unrelated alternate identity" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create alternate legacy origin"
  mkdir -p "$home/data/$origin"
  printf '# Durable ambiguous legacy report\n' > "$home/data/$origin/report.md"
  write_origin_meta "$home" "$origin"
  write_origin_meta "$home" "$alternate"
  printf 'decisions_reviewed=1\ndecision_keys=other\n' >> "$home/state/$alternate.meta"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the ambiguous legacy answer" \
    --reason "captain ambiguous answer pending" --repo sample) \
    || fail "could not create ambiguous legacy hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not inventory ambiguous legacy hold"
  decision='Captain resolved the ambiguous legacy identity.'
  printf '%s\n' "$decision" > "$home/ambiguous-compatible-answer.txt"
  run_decisions "$home" answer "$origin" "$key" \
    --decision-file "$home/ambiguous-compatible-answer.txt" >/dev/null \
    || fail "could not resolve ambiguous legacy hold"
  digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: (none)\nResolution mode: answered\n\nCaptain decision:\n%s\n\nRouted work:\n(none)' \
    "$digest" "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not preserve ambiguous released-version history"
  if run_decisions "$home" verify "$origin" > "$home/ambiguous-compatible.out" 2> "$home/ambiguous-compatible.err"; then
    fail "mutable reviewed metadata automatically attested an ambiguous legacy identity"
  fi
  token=$(printf '%s' "$hold" | shasum -a 256 | awk '{print $1}')
  assert_absent "$home/data/decision-resolution-attestations/$token.attestation" \
    "ambiguous reviewed metadata automatically created a durable identity attestation"
  if run_decisions "$home" migrate-legacy "$origin" "$key" \
    --decision-file "$home/ambiguous-compatible-answer.txt" \
    > "$home/unattested-migration.out" 2> "$home/unattested-migration.err"; then
    fail "surviving metadata and a replayed answer established ambiguous legacy ownership"
  fi
  assert_grep "requires an independent --identity-file authorization" \
    "$home/unattested-migration.err" "ambiguous legacy migration did not request independent authorization"
  assert_absent "$home/data/decision-resolution-attestations/$token.attestation" \
    "unattested ambiguous migration persisted an identity attestation"

  wrong_authorization="$home/wrong-legacy-identity.txt"
  write_legacy_identity_authorization "$wrong_authorization" "$hold" "$alternate" later "$body"
  if run_decisions "$home" migrate-legacy "$origin" "$key" \
    --decision-file "$home/ambiguous-compatible-answer.txt" \
    --identity-file "$wrong_authorization" \
    > "$home/wrong-identity.out" 2> "$home/wrong-identity.err"; then
    fail "a mismatched independent mapping authorized ambiguous legacy history"
  fi
  assert_grep "does not match $origin/$key" "$home/wrong-identity.err" \
    "mismatched identity authorization did not fail against the requested owner"
  assert_absent "$home/data/decision-resolution-attestations/$token.attestation" \
    "mismatched identity authorization persisted an attestation"

  authorization="$home/legacy-identity.txt"
  write_legacy_identity_authorization "$authorization" "$hold" "$origin" "$key" "$body"
  tasks_in "$home" rm "$origin" >/dev/null \
    || fail "could not remove the migrated legacy origin task"
  rm -f "$home/state/$origin.meta"
  for n in $(seq 1 10); do
    tasks_in "$home" add "authorized-legacy-filler-$n" "Authorized legacy filler $n" \
      --kind ship --repo sample >/dev/null \
      || fail "could not create authorized legacy filler $n"
    tasks_in "$home" "done" "authorized-legacy-filler-$n" --no-prune >/dev/null \
      || fail "could not retain authorized legacy filler $n before pruning"
  done
  run_decisions "$home" retention-prune >/dev/null \
    || fail "could not prune authorized legacy history through the public retention boundary"
  assert_absent "$home/state/$origin.meta" \
    "post-teardown legacy migration unexpectedly retained origin metadata"
  assert_grep "- [x] $hold -" "$home/data/done-archive.md" \
    "authorized legacy record was not pruned through configured retention"
  run_decisions "$home" migrate-legacy "$origin" "$key" \
    --decision-file "$home/ambiguous-compatible-answer.txt" \
    --identity-file "$authorization" >/dev/null \
    || fail "post-teardown authorized ambiguous legacy identity did not migrate"
  run_decisions "$home" complete "$origin" --none --resolved "$key" >/dev/null \
    || fail "post-teardown migrated legacy identity did not complete from durable evidence"
  assert_present "$home/data/decision-resolution-attestations/$token.attestation" \
    "post-teardown authorized migration did not persist exact identity"
  printf 'decision_keys=later\n' >> "$home/state/$alternate.meta"
  if run_decisions "$home" complete "$alternate" --none --resolved later \
    > "$home/alternate-owner.out" 2> "$home/alternate-owner.err"; then
    fail "authorized legacy identity proved a colliding alternate owner"
  fi
  assert_grep "does not match $alternate/later" "$home/alternate-owner.err" \
    "authorized legacy identity was not bound to its exact origin and key"

  home=$(make_home compatible-long-legacy)
  origin=sample-
  key=
  n=0
  while [ "$n" -lt 180 ]; do origin="${origin}o"; n=$((n + 1)); done
  n=0
  while [ "$n" -lt 80 ]; do key="${key}k"; n=$((n + 1)); done
  tasks_in "$home" add "$origin" "Review a long legacy identity" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create long legacy origin"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the long legacy answer" \
    --reason "captain long answer pending" --repo sample) \
    || fail "could not create long legacy hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not inventory long legacy hold"
  decision='Captain resolved the long legacy identity.'
  printf '%s\n' "$decision" > "$home/long-answer.txt"
  run_decisions "$home" answer "$origin" "$key" --decision-file "$home/long-answer.txt" >/dev/null \
    || fail "could not resolve long legacy hold"
  digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: (none)\nResolution mode: answered\n\nCaptain decision:\n%s\n\nRouted work:\n(none)' \
    "$digest" "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not preserve long released-version history"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "a long released-version identity exceeded the attestation filename limit"
  token=$(printf '%s' "$hold" | shasum -a 256 | awk '{print $1}')
  assert_present "$home/data/decision-resolution-attestations/$token.attestation" \
    "long legacy verification did not use a bounded attestation filename"
  pass "legacy compatibility stays bounded and ambiguous migration requires independent authorization"
}

test_option_shaped_keys_and_jq_free_verification() {
  local home origin key hold show
  home=$(make_home option-shaped-jq-free)
  origin=sample-option-review
  key=--route
  tasks_in "$home" add "$origin" "Review option-shaped decision key" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create option-shaped origin"
  write_origin_meta "$home" "$origin"
  cat > "$home/fakebin/jq" <<'SH'
#!/usr/bin/env bash
exit 127
SH
  chmod +x "$home/fakebin/jq"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the option-shaped route" \
    --reason "captain option route pending" --repo sample) \
    || fail "could not create an option-shaped decision hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "option-shaped decision key was parsed as an unsupported option"
  printf 'Captain resolved the option-shaped route.\n' > "$home/option-answer.txt"
  run_decisions "$home" answer "$origin" "$key" \
    --decision-file "$home/option-answer.txt" >/dev/null \
    || fail "jq-free answer recording failed"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "jq-free retained decision verification failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "option-shaped decision did not close"
  pass "option-shaped keys and jq-free decision verification stay compatible"
}

test_nonarchive_rows_cannot_prove_pruned_history() {
  local home origin key hold n archive decision note_alias note_alias_created=0
  home=$(make_home nonarchive-history-row)
  origin=sample-nonarchive-review
  key=old-answer
  tasks_in "$home" add "$origin" "Review nonarchive history" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create nonarchive history origin"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the nonarchive answer" --reason "captain nonarchive answer pending" --repo sample) \
    || fail "could not create nonarchive history hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not inventory nonarchive history hold"
  printf 'Captain resolved the nonarchive fixture.\n' > "$home/nonarchive-answer.txt"
  run_decisions "$home" answer "$origin" "$key" --decision-file "$home/nonarchive-answer.txt" >/dev/null \
    || fail "could not resolve nonarchive history hold"
  for n in $(seq 1 10); do
    tasks_in "$home" add "nonarchive-filler-$n" "Nonarchive filler $n" \
      --kind ship --repo sample >/dev/null \
      || fail "could not create nonarchive filler $n"
    tasks_in "$home" "done" "nonarchive-filler-$n" --no-prune >/dev/null \
      || fail "could not retain nonarchive filler $n before pruning"
  done
  run_decisions "$home" retention-prune >/dev/null \
    || fail "could not prune the canonical fixture through the public retention boundary"
  archive="$home/data/done-archive.md"
  assert_no_grep "- [x] $hold -" "$home/data/backlog.md" \
    "nonarchive fixture did not leave the bounded Done window"
  assert_grep "- [x] $hold -" "$archive" \
    "nonarchive fixture was not pruned by configured retention"
  cp "$archive" "$archive.canonical" \
    || fail "could not preserve the canonical retention archive"
  # shellcheck disable=SC2015
  awk '
    /^## Archived [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
      print "## Notes"
      next
    }
    { print }
  ' "$archive" > "$archive.tmp" && mv "$archive.tmp" "$archive" \
    || fail "could not create nonarchive persisted-record counterfactual"
  if run_decisions "$home" verify "$origin" \
    > "$home/nonarchive.out" 2> "$home/nonarchive.err"; then
    fail "a resolution-shaped row outside a canonical archive section proved history"
  fi
  assert_grep "malformed archived record" "$home/nonarchive.err" \
    "nonarchive row and its transition marker did not fail outside canonical retention"

  cp "$archive.canonical" "$archive" \
    || fail "could not restore the canonical retention archive"
  # shellcheck disable=SC2015
  awk '
    /^## Archived [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && !inserted {
      print
      print "### Notes"
      inserted = 1
      next
    }
    { print }
  ' "$archive" > "$archive.tmp" && mv "$archive.tmp" "$archive" \
    || fail "could not create an archive subsection counterfactual"
  if run_decisions "$home" verify "$origin" \
    > "$home/subsection.out" 2> "$home/subsection.err"; then
    fail "a resolution-shaped row under an archive subsection proved retained history"
  fi
  assert_grep "malformed archived record" "$home/subsection.err" \
    "an archive subsection did not invalidate the following noncanonical row"

  home=$(make_home note-archive-history-row)
  origin=sample-note-archive-review
  key=old-answer
  # shellcheck disable=SC2015
  awk '
    $0 == "archive = \"data/done-archive.md\"" { print "archive = \"data/copied-history.md\""; next }
    { print }
  ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp" && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not configure the copied-history retention owner"
  tasks_in "$home" add "$origin" "Review note archive history" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create note-archive origin"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the note archive answer" \
    --reason "captain note archive answer pending" --repo sample) \
    || fail "could not create note-archive decision hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not inventory note-archive decision hold"
  decision="$home/note-archive-answer.txt"
  printf 'Captain resolved the note-archive fixture.\n' > "$decision"
  run_decisions "$home" answer "$origin" "$key" --decision-file "$decision" >/dev/null \
    || fail "could not resolve note-archive decision hold"
  tasks_in "$home" update "$hold" --body "Superseded decision snapshot." --archive-body >/dev/null \
    || fail "could not archive a superseded decision body"
  tasks_in "$home" rm "$hold" >/dev/null \
    || fail "could not remove the superseded live decision record"
  assert_grep "- [x] $hold -" "$home/data/note-archive.md" \
    "tasks-axi did not preserve the superseded Done snapshot in its note archive"
  note_alias="$home/data/NOTE-ARCHIVE.md"
  if [ ! -e "$note_alias" ]; then
    ln "$home/data/note-archive.md" "$note_alias" \
      || fail "could not create a physical note-archive alias"
    note_alias_created=1
  fi
  # shellcheck disable=SC2015
  awk '
    $0 == "archive = \"data/copied-history.md\"" { print "archive = \"data/NOTE-ARCHIVE.md\""; next }
    { print }
  ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp" && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not reproduce a physical note archive alias configured as Done retention"
  if run_decisions "$home" complete "$origin" --none --resolved "$key" \
    > "$home/note-archive.out" 2> "$home/note-archive.err"; then
    fail "a superseded note snapshot proved normal Done retention"
  fi
  assert_grep "aliases the tasks-axi note archive" "$home/note-archive.err" \
    "the configured note archive alias did not fail its retention boundary"
  [ "$note_alias_created" -eq 0 ] || rm -f "$note_alias"

  # shellcheck disable=SC2015
  awk '
    $0 == "archive = \"data/NOTE-ARCHIVE.md\"" { print "archive = \"data/copied-history.md\""; next }
    { print }
  ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp" && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not restore the copied-history retention owner"
  cp "$home/data/note-archive.md" "$home/data/copied-history.md" \
    || fail "could not copy the note snapshot into a configured history artifact"
  # shellcheck disable=SC2015
  awk -v id="$hold" '
    index($0, "- [x] " id " - ") == 1 { sub(" - ", " - Edited copied title ") }
    { print }
  ' "$home/data/copied-history.md" > "$home/data/copied-history.md.tmp" \
    && mv "$home/data/copied-history.md.tmp" "$home/data/copied-history.md" \
    || fail "could not edit the copied history title counterfactual"
  if run_decisions "$home" complete "$origin" --none --resolved "$key" \
    > "$home/copied-note.out" 2> "$home/copied-note.err"; then
    fail "an edited copied note snapshot substituted for configured Done retention"
  fi
  assert_grep "lacks provenance from its configured Done retention transition" "$home/copied-note.err" \
    "copied note history was not rejected at the retention transition boundary"
  pass "only canonical retention sections and owned archives prove historical decisions"
}

test_nested_public_retention_hook_prunes_once() {
  local home origin key hold n
  home=$(make_home nested-retention-hook)
  origin=sample-nested-retention-review
  key=old-choice
  tasks_in "$home" add "$origin" "Review nested retention" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create nested-retention origin"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the nested retention option" \
    --reason "captain nested retention option pending" --repo sample) \
    || fail "could not create nested-retention hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not inventory nested-retention hold"
  printf 'Captain resolved the nested retention option.\n' > "$home/nested-answer.txt"
  run_decisions "$home" answer "$origin" "$key" \
    --decision-file "$home/nested-answer.txt" >/dev/null \
    || fail "could not resolve nested-retention hold"
  for n in $(seq 1 10); do
    tasks_in "$home" add "nested-filler-$n" "Nested filler $n" \
      --kind ship --repo sample >/dev/null \
      || fail "could not create nested-retention filler $n"
    tasks_in "$home" "done" "nested-filler-$n" --no-prune >/dev/null \
      || fail "could not retain nested-retention filler $n"
  done
  if ! PATH="$home/fakebin:$ROOT/bin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-decision-hold.sh" retention-prune \
    > "$home/nested-prune.out" 2> "$home/nested-prune.err"; then
    fail "project-bin retention re-entry failed: $(cat "$home/nested-prune.err")"
  fi
  assert_no_grep "- [x] $hold -" "$home/data/backlog.md" \
    "nested public retention left the resolved decision in the Done window"
  assert_grep "- [x] $hold -" "$home/data/done-archive.md" \
    "nested public retention did not archive the resolved decision"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "nested public retention did not preserve usable provenance"
  pass "project-bin retention re-entry emits provenance exactly once"
}

test_dangling_note_archive_alias_is_rejected() {
  local home origin
  home=$(make_home dangling-note-archive-alias)
  origin=sample-dangling-alias-review
  # shellcheck disable=SC2015
  awk '
    $0 == "archive = \"data/done-archive.md\"" { print "archive = \"data/history.md\""; next }
    { print }
  ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp" && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not configure dangling-alias retention"
  tasks_in "$home" add "$origin" "Review dangling alias retention" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create dangling-alias origin"
  write_origin_meta "$home" "$origin"
  ln -s history.md "$home/data/note-archive.md" \
    || fail "could not create dangling note-archive alias"
  if run_decisions "$home" hold "$origin" route \
    --title "Choose the dangling alias route" \
    --reason "captain dangling alias route pending" --repo sample \
    > "$home/dangling-alias.out" 2> "$home/dangling-alias.err"; then
    fail "a dangling note-archive symlink was accepted as a distinct destination"
  fi
  assert_grep "aliases the tasks-axi note archive" "$home/dangling-alias.err" \
    "dangling note-archive alias did not fail before retention"
  [ -L "$home/data/note-archive.md" ] \
    || fail "alias preflight changed the dangling note-archive symlink"
  assert_absent "$home/data/history.md" \
    "alias preflight created the dangling symlink target"
  assert_no_grep "$origin-decision-route" "$home/data/backlog.md" \
    "rejected dangling alias still created a captain hold"
  pass "dangling note-archive aliases fail before retention"
}

test_absent_case_alias_is_rejected_before_retention() {
  local home origin probe alternate case_insensitive=0 hold
  home=$(make_home absent-case-alias)
  origin=sample-case-alias-review
  # shellcheck disable=SC2015
  awk '
    $0 == "archive = \"data/done-archive.md\"" { print "archive = \"data/NOTE-ARCHIVE.md\""; next }
    { print }
  ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp" && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not configure an absent case-variant archive destination"
  tasks_in "$home" add "$origin" "Review case-variant retention" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create case-variant origin"
  write_origin_meta "$home" "$origin"
  probe="$home/data/.fm-case-probe-Aa"
  alternate="$home/data/.fm-case-probe-aa"
  : > "$probe"
  if [ -e "$alternate" ] && [ "$probe" -ef "$alternate" ]; then case_insensitive=1; fi
  rm -f -- "$probe"
  if [ "$case_insensitive" -eq 1 ]; then
    if run_decisions "$home" hold "$origin" route \
      --title "Choose the case-variant route" \
      --reason "captain case route pending" --repo sample \
      > "$home/case-alias.out" 2> "$home/case-alias.err"; then
      fail "an absent case-variant note archive alias was accepted"
    fi
    assert_grep "aliases the tasks-axi note archive" "$home/case-alias.err" \
      "absent case-variant destinations were not compared on the active filesystem"
    assert_absent "$home/data/NOTE-ARCHIVE.md" \
      "alias validation created the future retention destination"
  else
    hold=$(run_decisions "$home" hold "$origin" route \
      --title "Choose the case-variant route" \
      --reason "captain case route pending" --repo sample) \
      || fail "case-sensitive distinct archive destinations were over-rejected"
    [ "$hold" = "$origin-decision-route" ] \
      || fail "case-sensitive archive validation changed hold identity"
  fi
  pass "future archive aliases follow filesystem case semantics"
}

test_queued_repaired_resolution_is_rejected() {
  local home origin key hold decision digest body
  home=$(make_home queued-repaired-resolution)
  origin=sample-queued-repair-review
  key=repair-shaped
  tasks_in "$home" add "$origin" "Review queued repair provenance" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create queued-repair origin"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the repair-shaped answer" \
    --reason "captain repair-shaped answer pending" --repo sample) \
    || fail "could not create queued-repair hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not inventory queued-repair hold"
  decision='Captain answer copied into an impossible queued repair.'
  digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  body=$(printf 'Resolution recorded by fm-decision-hold.\nOrigin: %s\nDecision key: %s\nDecision digest: %s\nRouted identities: (none)\nResolution mode: repaired\n\nCaptain decision:\n%s\n\nRouted work:\n(none)' \
    "$origin" "$key" "$digest" "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not create queued repaired-resolution fixture"
  if run_decisions "$home" complete "$origin" "$key" \
    > "$home/complete.out" 2> "$home/complete.err"; then
    fail "completion accepted a repaired resolution on a queued hold"
  fi
  assert_grep "malformed or mismatched active provenance" "$home/complete.err" \
    "queued repaired resolution did not fail active validation"
  if run_decisions "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
    fail "verification accepted a repaired resolution on a queued hold"
  fi
  assert_grep "malformed or mismatched active provenance" "$home/verify.err" \
    "queued repaired resolution did not fail durable validation"
  pass "queued holds reject the repair-only resolution mode"
}

test_retained_resolution_rejects_oversized_decision() {
  local home id hold decision digest body
  home=$(make_home oversized-retained-decision)
  id=sample-size-review
  tasks_in "$home" add "$id" "Review retained decision size" --kind scout --repo sample --start >/dev/null \
    || fail "could not create retained-size origin"
  write_origin_meta "$home" "$id"
  hold=$(run_decisions "$home" hold "$id" bounded-answer \
    --title "Choose the bounded answer" --reason "captain bounded answer pending" --repo sample) \
    || fail "could not create retained-size hold"
  run_decisions "$home" complete "$id" bounded-answer >/dev/null \
    || fail "could not inventory retained-size hold"
  decision=$(LC_ALL=C awk 'BEGIN { for (i = 0; i < 8193; i++) printf "x" }')
  digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  body=$(printf 'Resolution recorded by fm-decision-hold.\nOrigin: %s\nDecision key: bounded-answer\nDecision digest: %s\nRouted identities: (none)\nResolution mode: answered\n\nCaptain decision:\n%s\n\nRouted work:\n(none)' \
    "$id" "$digest" "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not create oversized retained resolution"
  tasks_in "$home" "done" "$hold" >/dev/null \
    || fail "could not retain oversized resolution"
  if run_decisions "$home" verify "$id" > "$home/oversized.out" 2> "$home/oversized.err"; then
    fail "verification accepted an oversized retained captain decision"
  fi
  assert_grep "neither actively held nor durably resolved" "$home/oversized.err" \
    "oversized retained decision did not fail as malformed"
  pass "retained resolutions enforce the captain decision size bound"
}

# Missing active ownership and malformed retained records remain hard failures.
# Archived absence alone is never interpreted as a resolution.
test_pruned_history_fallback_rejects_unproven_decisions() {
  local home id hold
  home=$(make_home pruned-history-guards)
  id=sample-guarded-history
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review guarded history" --kind scout --repo sample --start >/dev/null \
    || fail "could not create guarded-history origin"
  write_origin_meta "$home" "$id"
  printf 'done: guarded review pass complete\n' > "$home/state/$id.status"
  printf '# Guarded history\n' > "$home/data/$id/report.md"

  hold=$(run_decisions "$home" hold "$id" missing-active \
    --title "Missing active sample" --reason "captain active sample pending" --repo sample) \
    || fail "could not register missing-active hold"
  run_decisions "$home" complete "$id" missing-active >/dev/null \
    || fail "could not inventory missing-active hold"
  tasks_in "$home" rm "$hold" >/dev/null || fail "could not remove active hold fixture"
  if run_decisions "$home" complete "$id" --none > "$home/missing.out" 2> "$home/missing.err"; then
    fail "completion treated a missing active record as pruned resolved history"
  fi
  assert_grep "is absent" "$home/missing.err" "missing active record did not fail explicitly"

  home=$(make_home malformed-retained-history)
  id=sample-malformed-history
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review malformed history" --kind scout --repo sample --start >/dev/null \
    || fail "could not create malformed-history origin"
  write_origin_meta "$home" "$id"
  printf 'done: malformed review pass complete\n' > "$home/state/$id.status"
  printf '# Malformed history\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" malformed-active \
    --title "Malformed active sample" --reason "captain malformed sample pending" --repo sample) \
    || fail "could not register malformed-active hold"
  run_decisions "$home" complete "$id" malformed-active >/dev/null \
    || fail "could not inventory malformed-active hold"
  tasks_in "$home" update "$hold" --body "Origin: another-review\nDecision key: another-key\nState: awaiting captain decision." >/dev/null \
    || fail "could not create mismatched active record"
  if run_decisions "$home" complete "$id" malformed-active \
    > "$home/mismatched.out" 2> "$home/mismatched.err"; then
    fail "completion accepted a mismatched active decision record"
  fi
  assert_grep "malformed" "$home/mismatched.err" "mismatched active record did not fail explicitly"

  # A directly closed hold reaches Done without the owner's durable resolution
  # block. It remains malformed after normal pruning and cannot satisfy history.
  tasks_in "$home" update "$hold" \
    --body "Origin: $id\nDecision key: malformed-active\nState: awaiting captain decision." >/dev/null \
    || fail "could not restore active provenance fixture"
  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not close malformed retained fixture"
  for n in $(seq 1 10); do
    tasks_in "$home" add "malformed-filler-$n" "Malformed filler $n" --kind ship --repo sample >/dev/null \
      || fail "could not create malformed filler $n"
    tasks_in "$home" "done" "malformed-filler-$n" --no-prune >/dev/null \
      || fail "could not retain malformed filler $n before pruning"
  done
  run_decisions "$home" retention-prune >/dev/null \
    || fail "could not prune malformed history through the public retention boundary"
  assert_grep "- [x] $hold -" "$home/data/done-archive.md" \
    "malformed record was not pruned into the archive"
  if run_decisions "$home" verify "$id" > "$home/malformed.out" 2> "$home/malformed.err"; then
    fail "verification accepted a malformed archived decision record"
  fi
  assert_grep "malformed or mismatched archived resolution" "$home/malformed.err" \
    "malformed archived record did not fail as unproven"

  mv "$home/data/done-archive.md" "$home/data/safe-done-archive.md"
  ln -s safe-done-archive.md "$home/data/done-archive.md"
  if run_decisions "$home" verify "$id" > "$home/symlink.out" 2> "$home/symlink.err"; then
    fail "verification followed a symlinked decision archive"
  fi
  assert_grep "not an ordinary file" "$home/symlink.err" \
    "symlinked archive did not stop safely"
  rm "$home/data/done-archive.md"
  mv "$home/data/safe-done-archive.md" "$home/data/done-archive.md"
  ln "$home/data/done-archive.md" "$home/data/hardlinked-done-archive.md"
  if run_decisions "$home" verify "$id" > "$home/hardlink.out" 2> "$home/hardlink.err"; then
    fail "verification read a hardlinked decision archive"
  fi
  assert_grep "is hardlinked" "$home/hardlink.err" \
    "hardlinked archive did not stop safely"
  rm "$home/data/hardlinked-done-archive.md"
  pass "pruned-history fallback rejects missing, malformed, and mismatched decisions"
}

# Historical proof must remain bound to its structured owner and exact answer.
# Neither ambiguous ids, title text, cross-home archives, nor resolution-shaped
# bodies with false digests or routing lists can satisfy the public gate.
test_historical_resolution_proof_is_exact_and_home_bound() {
  local home digest_origin route_origin hold decision digest body source victim collision spoof_origin spoof
  local foreign symlink_home n show before after
  home=$(make_home exact-history-proof)

  digest_origin=sample-digest-review
  tasks_in "$home" add "$digest_origin" "Review digest proof" --kind scout --repo sample --start >/dev/null \
    || fail "could not create digest-proof origin"
  write_origin_meta "$home" "$digest_origin"
  hold=$(run_decisions "$home" hold "$digest_origin" exact-answer \
    --title "Choose the exact answer" --reason "captain exact answer pending" --repo sample) \
    || fail "could not create digest-proof hold"
  run_decisions "$home" complete "$digest_origin" exact-answer >/dev/null \
    || fail "could not inventory digest-proof hold"
  decision='Captain chose the exact answer.'
  printf '%s\n' "$decision" > "$home/exact-answer.txt"
  run_decisions "$home" answer "$digest_origin" exact-answer --decision-file "$home/exact-answer.txt" >/dev/null \
    || fail "could not resolve digest-proof hold"
  body=$(printf 'Resolution recorded by fm-decision-hold.\nOrigin: %s\nDecision key: exact-answer\nDecision digest: %064d\nRouted identities: (none)\nResolution mode: answered\n\nCaptain decision:\n%s\n\nRouted work:\n(none)' \
    "$digest_origin" 0 "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not create false-digest retained record"
  if run_decisions "$home" verify "$digest_origin" > "$home/false-digest.out" 2> "$home/false-digest.err"; then
    fail "verification accepted a retained record whose digest did not match its decision"
  fi

  route_origin=sample-route-proof
  tasks_in "$home" add "$route_origin" "Review route proof" --kind scout --repo sample --start >/dev/null \
    || fail "could not create route-proof origin"
  write_origin_meta "$home" "$route_origin"
  hold=$(run_decisions "$home" hold "$route_origin" exact-route \
    --title "Choose the exact route" --reason "captain exact route pending" --repo sample) \
    || fail "could not create route-proof hold"
  run_decisions "$home" complete "$route_origin" exact-route >/dev/null \
    || fail "could not inventory route-proof hold"
  decision='Captain chose route alpha.'
  digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  body=$(printf 'Resolution recorded by fm-decision-hold.\nOrigin: %s\nDecision key: exact-route\nDecision digest: %s\nRouted identities: sample-route-alpha\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-route-beta' \
    "$route_origin" "$digest" "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not create mismatched route record"
  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not retain mismatched route record"
  if run_decisions "$home" verify "$route_origin" > "$home/false-route.out" 2> "$home/false-route.err"; then
    fail "verification accepted routed identities that disagreed with routed work"
  fi
  body=$(printf 'Resolution recorded by fm-decision-hold.\nOrigin: %s\nDecision key: exact-route\nDecision digest: %s\nRouted identities: sample-route-alpha\nResolution mode: answered\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-route-alpha' \
    "$route_origin" "$digest" "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not create answered-with-routing record"
  if run_decisions "$home" verify "$route_origin" > "$home/answered-route.out" 2> "$home/answered-route.err"; then
    fail "verification accepted an unrouted mode with routed identities"
  fi
  body=$(printf 'Resolution recorded by fm-decision-hold.\nOrigin: %s\nDecision key: exact-route\nDecision digest: %s\nRouted identities: (none)\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n(none)' \
    "$route_origin" "$digest" "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not create routed-without-routing record"
  if run_decisions "$home" verify "$route_origin" > "$home/empty-route.out" 2> "$home/empty-route.err"; then
    fail "verification accepted routed mode without routed identities"
  fi
  body=$(printf 'Resolution recorded by fm-decision-hold.\nOrigin: %s\nDecision key: exact-route\nDecision digest: %s\nRouted identities: -ghost\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- -ghost' \
    "$route_origin" "$digest" "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not create invalid routed-identity record"
  if run_decisions "$home" verify "$route_origin" > "$home/invalid-route.out" 2> "$home/invalid-route.err"; then
    fail "verification accepted a routed identity that tasks-axi cannot own"
  fi
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: sample-route-alpha\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-route-alpha' \
    "$digest" "$decision")
  tasks_in "$home" update "$hold" --body "$body" >/dev/null \
    || fail "could not create legacy routed resolution record"
  run_decisions "$home" verify "$route_origin" >/dev/null \
    || fail "the explicitly supported legacy routed record was rejected"

  source=sample
  victim=sample-decision-route
  tasks_in "$home" add "$source" "Review source identity" --kind scout --repo sample --start >/dev/null \
    || fail "could not create source identity origin"
  tasks_in "$home" add "$victim" "Review colliding identity" --kind scout --repo sample --start >/dev/null \
    || fail "could not create colliding identity origin"
  write_origin_meta "$home" "$source"
  write_origin_meta "$home" "$victim"
  collision=$(run_decisions "$home" hold "$source" route-decision-later \
    --title "Choose the source route" --reason "captain source route pending" --repo sample) \
    || fail "could not create source collision hold"
  run_decisions "$home" complete "$source" route-decision-later >/dev/null \
    || fail "could not inventory source collision hold"
  if run_decisions "$home" hold "$victim" later \
    --title "Choose the source route" --reason "captain victim route pending" --repo sample \
    > "$home/active-collision.out" 2> "$home/active-collision.err"; then
    fail "a colliding origin reused another active hold"
  fi
  show=$(tasks_in "$home" show "$collision" --full)
  assert_contains "$show" "hold_reason: captain source route pending" \
    "a rejected identity collision mutated the active hold reason"
  assert_not_contains "$show" "captain victim route pending" \
    "a rejected identity collision retained the colliding reason"
  printf 'Captain chose the source route.\n' > "$home/source-route.txt"
  run_decisions "$home" answer "$source" route-decision-later --decision-file "$home/source-route.txt" >/dev/null \
    || fail "could not resolve source collision hold"
  before=$(shasum -a 256 "$home/data/backlog.md")
  if run_decisions "$home" repair "$victim" later --decision-file "$home/source-route.txt" \
    > "$home/repair-collision.out" 2> "$home/repair-collision.err"; then
    fail "repair rebound a resolved hold to a colliding origin and key"
  fi
  assert_grep "mismatched repair provenance" "$home/repair-collision.err" \
    "repair did not reject the colliding origin provenance"
  after=$(shasum -a 256 "$home/data/backlog.md")
  [ "$before" = "$after" ] || fail "rejected colliding repair mutated the resolved hold"
  show=$(tasks_in "$home" show "$collision" --full)
  assert_contains "$show" "Origin: $source" "rejected repair changed the resolved origin"
  assert_contains "$show" "Decision key: route-decision-later" \
    "rejected repair changed the resolved decision key"
  if run_decisions "$home" complete "$victim" --none --resolved later > "$home/retained-collision.out" 2> "$home/retained-collision.err"; then
    fail "a retained resolution proved a different origin and key with the same concatenated id"
  fi

  spoof_origin=sample-title-spoof
  tasks_in "$home" add "$spoof_origin" "Review title provenance" --kind scout --repo sample --start >/dev/null \
    || fail "could not create title-spoof origin"
  write_origin_meta "$home" "$spoof_origin"
  spoof="$spoof_origin-decision-fake"
  decision='Captain-shaped text on ordinary work.'
  digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  body=$(printf 'Resolution recorded by fm-decision-hold.\nOrigin: %s\nDecision key: fake\nDecision digest: %s\nRouted identities: (none)\nResolution mode: answered\n\nCaptain decision:\n%s\n\nRouted work:\n(none)' \
    "$spoof_origin" "$digest" "$decision")
  tasks_in "$home" add "$spoof" "Ordinary title" --kind captain --repo sample --body "$body" >/dev/null \
    || fail "could not create title-spoof ordinary task"
  tasks_in "$home" "done" "$spoof" >/dev/null || fail "could not close title-spoof ordinary task"
  # shellcheck disable=SC2015
  awk -v id="$spoof" '
    index($0, "- [x] " id " - Ordinary title ") == 1 {
      sub("Ordinary title", "Ordinary title (kind: captain) (hold-kind: captain)")
    }
    { print }
  ' "$home/data/backlog.md" > "$home/data/backlog.md.tmp" \
    && mv "$home/data/backlog.md.tmp" "$home/data/backlog.md" \
    || fail "could not preserve the legacy title-spoof fixture"

  for n in $(seq 1 12); do
    tasks_in "$home" add "exact-proof-filler-$n" "Exact proof filler $n" --kind ship --repo sample >/dev/null \
      || fail "could not create exact-proof filler $n"
    tasks_in "$home" "done" "exact-proof-filler-$n" --no-prune >/dev/null \
      || fail "could not retain exact-proof filler $n before pruning"
  done
  run_decisions "$home" retention-prune >/dev/null \
    || fail "could not prune exact history through the public retention boundary"
  assert_grep "- [x] $collision -" "$home/data/done-archive.md" \
    "collision record was not pruned into historical proof"
  assert_grep "- [x] $spoof -" "$home/data/done-archive.md" \
    "title-spoof record was not pruned into historical proof"
  if run_decisions "$home" complete "$victim" --none --resolved later > "$home/archived-collision.out" 2> "$home/archived-collision.err"; then
    fail "an archived resolution proved a different origin and key with the same concatenated id"
  fi
  if run_decisions "$home" complete "$spoof_origin" --none --resolved fake > "$home/title-spoof.out" 2> "$home/title-spoof.err"; then
    fail "captain metadata words in an ordinary archived title forged hold provenance"
  fi
  assert_grep "mismatched archived captain-hold provenance" "$home/title-spoof.err" \
    "title-spoof failure did not reject canonical kind and hold provenance"
  # shellcheck disable=SC2015
  awk -v id="$spoof" '
    index($0, "- [x] " id " - ") == 1 {
      print $0 " (hold:) (hold-kind: captain)"
      next
    }
    { print }
  ' "$home/data/done-archive.md" > "$home/data/done-archive.md.tmp" \
    && mv "$home/data/done-archive.md.tmp" "$home/data/done-archive.md" \
    || fail "could not create malformed archived hold provenance"
  if run_decisions "$home" complete "$spoof_origin" --none --resolved fake \
    > "$home/empty-hold-spoof.out" 2> "$home/empty-hold-spoof.err"; then
    fail "an empty hold token forged archived captain-hold provenance"
  fi
  assert_grep "malformed archived record" "$home/empty-hold-spoof.err" \
    "post-retention title edits did not invalidate transition provenance"

  foreign=$(make_home foreign-history-proof)
  write_origin_meta "$foreign" "$source"
  if PATH="$foreign/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$foreign" FM_STATE_OVERRIDE="$foreign/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$foreign/config" "$ROOT/bin/fm-decision-hold.sh" complete "$source" --none --resolved route-decision-later \
    > "$foreign/foreign.out" 2> "$foreign/foreign.err"; then
    fail "a foreign FM_DATA_OVERRIDE supplied another home's archived resolution"
  fi
  assert_grep "outside the active home" "$foreign/foreign.err" \
    "foreign archive failure did not enforce the active-home boundary"

  symlink_home=$(make_home symlinked-history-proof)
  write_origin_meta "$symlink_home" "$source"
  rm -rf "$symlink_home/data"
  ln -s "$home/data" "$symlink_home/data"
  if run_decisions "$symlink_home" complete "$source" --none --resolved route-decision-later \
    > "$symlink_home/symlink-parent.out" 2> "$symlink_home/symlink-parent.err"; then
    fail "a symlinked data parent supplied another home's archived resolution"
  fi
  assert_grep "authoritative data directory is unsafe" "$symlink_home/symlink-parent.err" \
    "symlinked archive parent did not stop at the home boundary"
  pass "historical resolution proof is exact, structured, and home-bound"
}

test_retained_history_rejects_unsafe_state_and_status() {
  local home foreign origin key hold n
  home=$(make_home retained-history-state-safety)
  origin=sample-state-safety-review
  key=old-answer
  tasks_in "$home" add "$origin" "Review retained state safety" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create retained state-safety origin"
  write_origin_meta "$home" "$origin"
  printf 'done: retained state-safety review complete\n' > "$home/state/$origin.status"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the retained state answer" \
    --reason "captain retained state answer pending" --repo sample) \
    || fail "could not create retained state-safety hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not inventory retained state-safety hold"
  printf 'Captain resolved the retained state answer.\n' > "$home/state-answer.txt"
  run_decisions "$home" answer "$origin" "$key" --decision-file "$home/state-answer.txt" >/dev/null \
    || fail "could not resolve retained state-safety hold"
  for n in $(seq 1 10); do
    tasks_in "$home" add "state-safety-filler-$n" "State safety filler $n" \
      --kind ship --repo sample >/dev/null \
      || fail "could not create state-safety filler $n"
    tasks_in "$home" "done" "state-safety-filler-$n" --no-prune >/dev/null \
      || fail "could not retain state-safety filler $n before pruning"
  done
  run_decisions "$home" retention-prune >/dev/null \
    || fail "could not prune state-safety history through the public retention boundary"
  assert_no_grep "- [x] $hold -" "$home/data/backlog.md" \
    "state-safety decision remained in the retained Done window"
  assert_grep "- [x] $hold -" "$home/data/done-archive.md" \
    "state-safety decision was not pruned through configured retention"

  foreign=$(make_home retained-history-foreign-state)
  write_origin_meta "$foreign" "$origin"
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$key" >> "$foreign/state/$origin.meta"
  printf 'done: foreign status\n' > "$foreign/state/$origin.status"
  if PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$foreign/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-decision-hold.sh" complete "$origin" --none --resolved "$key" \
    > "$home/foreign-state-complete.out" 2> "$home/foreign-state-complete.err"; then
    fail "current-format history accepted foreign completion state"
  fi
  assert_grep "configured state directory is outside the active home" \
    "$home/foreign-state-complete.err" "completion did not enforce its state-home boundary"
  if PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$foreign/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-decision-hold.sh" verify "$origin" \
    > "$home/foreign-state-verify.out" 2> "$home/foreign-state-verify.err"; then
    fail "current-format history accepted foreign verification state"
  fi
  assert_grep "configured state directory is outside the active home" \
    "$home/foreign-state-verify.err" "verification did not enforce its state-home boundary"

  mv "$home/state/$origin.meta" "$home/meta-target"
  ln -s "$home/meta-target" "$home/state/$origin.meta"
  if run_decisions "$home" complete "$origin" --none --resolved "$key" \
    > "$home/symlink-meta-complete.out" 2> "$home/symlink-meta-complete.err"; then
    fail "archived history accepted a symlinked origin metadata record"
  fi
  assert_grep "decision owner metadata is unsafe" "$home/symlink-meta-complete.err" \
    "completion did not reject symlinked origin metadata"
  rm "$home/state/$origin.meta"
  ln "$home/meta-target" "$home/state/$origin.meta"
  if run_decisions "$home" verify "$origin" \
    > "$home/hardlink-meta-verify.out" 2> "$home/hardlink-meta-verify.err"; then
    fail "archived history accepted a hardlinked origin metadata record"
  fi
  assert_grep "decision owner metadata is hardlinked" "$home/hardlink-meta-verify.err" \
    "verification did not reject hardlinked origin metadata"
  rm "$home/state/$origin.meta"
  mv "$home/meta-target" "$home/state/$origin.meta"

  mv "$home/state/$origin.status" "$home/status-target"
  ln -s "$home/status-target" "$home/state/$origin.status"
  if run_decisions "$home" complete "$origin" --none --resolved "$key" \
    > "$home/symlink-status-complete.out" 2> "$home/symlink-status-complete.err"; then
    fail "archived history hid a symlinked current status during completion"
  fi
  assert_grep "origin status is not an ordinary file" "$home/symlink-status-complete.err" \
    "completion did not reject a symlinked current status"
  if run_decisions "$home" verify "$origin" \
    > "$home/symlink-status-verify.out" 2> "$home/symlink-status-verify.err"; then
    fail "archived history hid a symlinked current status during verification"
  fi
  assert_grep "origin status is not an ordinary file" "$home/symlink-status-verify.err" \
    "verification did not reject a symlinked current status"
  rm "$home/state/$origin.status"
  ln "$home/status-target" "$home/state/$origin.status"
  if run_decisions "$home" verify "$origin" \
    > "$home/hardlink-status.out" 2> "$home/hardlink-status.err"; then
    fail "archived history hid a hardlinked current status"
  fi
  assert_grep "origin status is hardlinked" "$home/hardlink-status.err" \
    "verification did not reject a hardlinked current status"
  pass "retained history requires safe state records"
}

test_origin_ownership_rejects_linked_evidence() {
  local home origin hold show
  home=$(make_home unsafe-origin-ownership)
  origin=sample-linked-origin
  write_origin_meta "$home" "$origin"
  mv "$home/state/$origin.meta" "$home/origin-meta-target"
  ln -s "$home/origin-meta-target" "$home/state/$origin.meta"
  if run_decisions "$home" hold "$origin" route \
    --title "Choose linked route" --reason "captain linked route pending" --repo sample \
    > "$home/symlink-meta.out" 2> "$home/symlink-meta.err"; then
    fail "a symlinked metadata leaf established origin ownership"
  fi
  assert_grep "decision owner metadata is unsafe" "$home/symlink-meta.err" \
    "hold did not reject symlinked metadata ownership"
  assert_no_grep "$origin-decision-route" "$home/data/backlog.md" \
    "rejected symlinked metadata mutated the backlog"

  rm "$home/state/$origin.meta"
  ln "$home/origin-meta-target" "$home/state/$origin.meta"
  if run_decisions "$home" hold "$origin" route \
    --title "Choose linked route" --reason "captain linked route pending" --repo sample \
    > "$home/hardlink-meta.out" 2> "$home/hardlink-meta.err"; then
    fail "a hardlinked metadata leaf established origin ownership"
  fi
  assert_grep "decision owner metadata is hardlinked" "$home/hardlink-meta.err" \
    "hold did not reject hardlinked metadata ownership"
  assert_no_grep "$origin-decision-route" "$home/data/backlog.md" \
    "rejected hardlinked metadata mutated the backlog"

  rm -f "$home/state/$origin.meta" "$home/origin-meta-target"
  mkdir "$home/report-target"
  printf '# Linked report target\n' > "$home/report-target/report.md"
  ln -s "$home/report-target" "$home/data/$origin"
  if run_decisions "$home" hold "$origin" route \
    --title "Choose linked route" --reason "captain linked route pending" --repo sample \
    > "$home/symlink-report-parent.out" 2> "$home/symlink-report-parent.err"; then
    fail "a symlinked report parent established origin ownership"
  fi
  assert_grep "origin report directory is unsafe" "$home/symlink-report-parent.err" \
    "hold did not reject a symlinked report parent"
  rm "$home/data/$origin"
  mkdir "$home/data/$origin"
  ln -s "$home/report-target/report.md" "$home/data/$origin/report.md"
  if run_decisions "$home" hold "$origin" route \
    --title "Choose linked route" --reason "captain linked route pending" --repo sample \
    > "$home/symlink-report.out" 2> "$home/symlink-report.err"; then
    fail "a symlinked report leaf established origin ownership"
  fi
  assert_grep "origin report is not an ordinary readable file" "$home/symlink-report.err" \
    "hold did not reject a symlinked report leaf"
  assert_no_grep "$origin-decision-route" "$home/data/backlog.md" \
    "rejected report ownership mutated the backlog"

  home=$(make_home unsafe-post-teardown-origin)
  origin=sample-post-teardown-origin
  tasks_in "$home" add "$origin" "Review post-teardown ownership" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create post-teardown ownership origin"
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" route \
    --title "Choose post-teardown route" \
    --reason "captain post-teardown route pending" --repo sample) \
    || fail "could not create post-teardown ownership hold"
  tasks_in "$home" rm "$origin" >/dev/null \
    || fail "could not remove post-teardown origin fixture"
  rm -f "$home/state/$origin.meta"
  mkdir "$home/data/$origin"
  printf '# Hardlinked report target\n' > "$home/report-target.md"
  ln "$home/report-target.md" "$home/data/$origin/report.md"
  if run_decisions "$home" complete "$origin" route \
    > "$home/hardlink-report.out" 2> "$home/hardlink-report.err"; then
    fail "a hardlinked report leaf established post-teardown ownership"
  fi
  assert_grep "origin report is hardlinked" "$home/hardlink-report.err" \
    "completion did not reject hardlinked report ownership"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "rejected report ownership changed the active hold"
  assert_contains "$show" "held: yes" "rejected report ownership released the active hold"
  pass "origin ownership rejects linked metadata and report evidence"
}

test_contained_operational_overrides_remain_supported() {
  local home state data origin hold
  home=$(make_home contained-decision-overrides)
  state="$home/fixtures/state"
  data="$home/fixtures/data"
  mkdir -p "$state" "$data"
  mv "$home/data/backlog.md" "$data/backlog.md"
  # shellcheck disable=SC2015
  awk '
    $0 == "path = \"data/backlog.md\"" { print "path = \"fixtures/data/backlog.md\""; next }
    $0 == "archive = \"data/done-archive.md\"" { print "archive = \"fixtures/data/history/done.md\""; next }
    { print }
  ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp" \
    && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not configure contained operational overrides"
  origin=sample-contained-review
  tasks_in "$home" add "$origin" "Review contained override behavior" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create contained-override origin"
  fm_write_meta "$state/$origin.meta" \
    "window=firstmate:fm-$origin" \
    "worktree=$home/projects/missing-$origin" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: contained override review complete\n' > "$state/$origin.status"
  mkdir -p "$data/$origin"
  printf '# Contained override review\n' > "$data/$origin/report.md"
  hold=$(PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$ROOT/bin/fm-decision-hold.sh" hold "$origin" route \
    --title "Choose contained route" --reason "captain contained route pending" --repo sample) \
    || fail "contained operational overrides could not create a decision hold"
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$ROOT/bin/fm-decision-hold.sh" complete "$origin" route >/dev/null \
    || fail "contained operational overrides could not complete the inventory"
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$ROOT/bin/fm-decision-hold.sh" verify "$origin" >/dev/null \
    || fail "contained operational overrides could not verify the inventory"
  assert_grep "$hold" "$data/backlog.md" \
    "contained data override did not own the captain hold"
  assert_absent "$home/data/backlog.md" \
    "captain hold leaked into the default data directory"
  pass "contained operational overrides remain supported"
}

test_effective_root_backlog_retention_remains_supported() {
  local home origin key hold n
  home=$(make_home effective-root-backlog)
  mv "$home/data/backlog.md" "$home/backlog.md"
  # shellcheck disable=SC2015
  awk '
    $0 == "path = \"data/backlog.md\"" { print "path = \"backlog.md\""; next }
    $0 == "archive = \"data/done-archive.md\"" { print "archive = \"done-archive.md\""; next }
    { print }
  ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp" \
    && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not configure the effective root backlog"
  origin=sample-root-backlog-review
  key=old-choice
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review root backlog retention" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the root-backlog origin"
  write_origin_meta "$home" "$origin"
  printf 'done: root backlog review complete\n' > "$home/state/$origin.status"
  printf '# Root backlog review\n' > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the root backlog option" \
    --reason "captain root backlog option pending" --repo sample) \
    || fail "effective root backlog could not create a decision hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "effective root backlog could not complete its inventory"
  printf 'Captain resolved the root backlog option.\n' > "$home/root-answer.txt"
  run_decisions "$home" answer "$origin" "$key" \
    --decision-file "$home/root-answer.txt" >/dev/null \
    || fail "effective root backlog could not resolve its decision"
  # shellcheck disable=SC2015
  awk '
    $0 == "archive = \"done-archive.md\"" { print "archive = \"history/root-done.md\""; next }
    { print }
  ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp" \
    && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not migrate the effective root retention archive"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "retained Done proof could not migrate to a new contained retention owner"
  for n in $(seq 1 10); do
    tasks_in "$home" add "root-filler-$n" "Root filler $n" --kind ship --repo sample >/dev/null \
      || fail "could not create root-backlog filler $n"
    tasks_in "$home" "done" "root-filler-$n" --no-prune >/dev/null \
      || fail "could not retain root-backlog filler $n before explicit pruning"
  done
  run_decisions "$home" retention-prune >/dev/null \
    || fail "could not prune through the provenance-bound public retention interface"
  assert_no_grep "- [x] $hold -" "$home/backlog.md" \
    "effective root backlog retained the pruned decision"
  assert_grep "- [x] $hold -" "$home/history/root-done.md" \
    "effective root backlog did not use its migrated configured retention owner"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "effective root backlog could not verify normally pruned history"
  assert_absent "$home/done-archive.md" \
    "path migration wrote decision history to the prior retention owner"
  assert_absent "$home/data/done-archive.md" \
    "root-backlog retention leaked into FM_DATA_OVERRIDE"
  pass "effective contained backlog paths own their derived retention archives"
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

test_pruned_answer_retry_uses_proven_retention_history() {
  local home id hold show
  home=$(make_home pruned-answer-retry)
  id=sample-pruned-answer-review
  # shellcheck disable=SC2015
  sed 's/done_keep = 10/done_keep = 0/' "$home/.tasks.toml" > "$home/.tasks.toml.tmp" \
    && mv "$home/.tasks.toml.tmp" "$home/.tasks.toml" \
    || fail "could not configure immediate Done retention"
  tasks_in "$home" add "$id" "Review pruned answer retry" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the pruned-answer origin"
  write_origin_meta "$home" "$id"
  hold=$(run_decisions "$home" hold "$id" final-choice \
    --title "Choose the final option" --reason "captain final choice pending" --repo sample) \
    || fail "could not create the immediately pruned hold"
  run_decisions "$home" complete "$id" final-choice >/dev/null \
    || fail "could not inventory the immediately pruned hold"
  printf 'Captain chose the final option.\n' > "$home/final-choice.txt"
  run_decisions "$home" answer "$id" final-choice --decision-file "$home/final-choice.txt" >/dev/null \
    || fail "answer reported failure after its resolution was immediately pruned"
  if tasks_in "$home" show "$hold" --full > "$home/pruned-show.out" 2>&1; then
    fail "done_keep=0 retained the answered hold in the active backlog"
  fi
  assert_grep "- [x] $hold -" "$home/data/done-archive.md" \
    "the answered hold did not cross normal configured retention"
  run_decisions "$home" answer "$id" final-choice --decision-file "$home/final-choice.txt" >/dev/null \
    || fail "an exact answer retry did not accept proven retained history"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "proven retained history did not satisfy verification after answer retry"
  show=$(tasks_in "$home" list --state "done")
  assert_not_contains "$show" "$hold" "answer retry restored pruned history into the Done window"
  pass "immediately pruned answers and exact retries use proven retention history"
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

if ! command -v jq >/dev/null 2>&1; then
  test_option_shaped_keys_and_jq_free_verification
  echo "skip: jq not found; remaining decision lifecycle cases require jq"
  exit 0
fi

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_declined_decision_closes_without_routed_work
test_out_of_band_close_is_repairable_before_teardown
test_unanswered_decision_still_blocks_completion_and_teardown
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_pruned_resolved_history_does_not_block_later_review
test_pre_boundary_retention_requires_exact_migration
test_legacy_completion_inventory_requires_explicit_provenance
test_current_generation_rejects_an_older_archive_owner
test_current_generation_rejects_an_older_retained_done_owner
test_current_generation_rejects_an_older_queued_owner
test_source_verifiable_legacy_inventories_migrate_automatically
test_metadata_free_completion_retries_remain_idempotent
test_live_completion_provenance_survives_teardown
test_queued_legacy_resolution_is_attested_before_teardown
test_legacy_migration_rejects_missing_conflicting_or_foreign_owners
test_legacy_identity_compatibility_is_bounded_and_authorized
test_nonarchive_rows_cannot_prove_pruned_history
test_nested_public_retention_hook_prunes_once
test_dangling_note_archive_alias_is_rejected
test_absent_case_alias_is_rejected_before_retention
test_queued_repaired_resolution_is_rejected
test_retained_resolution_rejects_oversized_decision
test_pruned_history_fallback_rejects_unproven_decisions
test_historical_resolution_proof_is_exact_and_home_bound
test_retained_history_rejects_unsafe_state_and_status
test_origin_ownership_rejects_linked_evidence
test_contained_operational_overrides_remain_supported
test_effective_root_backlog_retention_remains_supported
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_bound_channel_answers_close_their_holds_at_answer_time
test_pruned_answer_retry_uses_proven_retention_history
test_unbound_source_closes_no_hold
test_answer_preserves_every_unrouted_close_guard
test_chat_channel_feeds_the_same_keyed_answer_intake
test_option_shaped_keys_and_jq_free_verification
