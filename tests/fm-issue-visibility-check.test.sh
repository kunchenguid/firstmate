#!/usr/bin/env bash
# Daily issue visibility through the real snapshot and watcher in disposable homes.
# Forge envelopes match the synthetic projection fixtures; no network is used.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CHECK="$ROOT/bin/fm-issue-visibility-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-issue-visibility-check)

make_home() {
  local home="$TMP_ROOT/$1" repo tool
  mkdir -p "$home"/{state,data,config,projects,fakebin}
  printf 'manual\n' > "$home/config/backlog-backend"
  printf '## In flight\n## Queued\n## Done\n' > "$home/data/backlog.md"
  for repo in alpha beta; do
    mkdir -p "$home/projects/$repo"
    git -C "$home/projects/$repo" init -q
    git -C "$home/projects/$repo" remote add origin "https://github.com/example-org/$repo.git"
    printf -- '- %s [direct-PR] - Synthetic project (added 2026-01-01)\n' "$repo" >> "$home/data/projects.md"
  done
  for tool in no-mistakes tmux gh curl; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$home/fakebin/$tool"
    chmod +x "$home/fakebin/$tool"
  done
  cat > "$home/fakebin/gh-axi" <<'STUB'
#!/usr/bin/env bash
printf 'read\n' >> "$FM_HOME/forge-calls"
case "${ISSUE_FAILURE:-}" in
  auth|rate|permission) printf '%s\n' "$ISSUE_FAILURE" >&2; exit 1 ;;
  slow) sleep 60 ;;
esac
case "$*" in *'name:"alpha"'*) repo=example-org/alpha ;; *) repo=example-org/beta ;; esac
body=$(jq -nc --arg repo "$repo" --arg failure "${ISSUE_FAILURE:-}" \
  --arg label "${ISSUE_LABEL:-ready-to-build}" --argjson count "${ISSUE_COUNT:-1}" '
  def conn($nodes): {nodes:$nodes,totalCount:($nodes|length),pageInfo:{hasNextPage:false}};
  def issue($n): {number:$n,url:("https://github.com/"+$repo+"/issues/"+($n|tostring)),title:("Synthetic issue "+($n|tostring)),
    state:"OPEN",updatedAt:"2026-01-02T00:00:00Z",parent:null,subIssuesSummary:{total:0,completed:0},
    labels:conn([{name:$label}]),assignees:conn([]),timelineItems:conn([]),closedByPullRequestsReferences:conn([])};
  {data:{repository:{nameWithOwner:$repo,issues:conn([range(1;$count+1)|issue(.)])}}}
  | if $failure=="truncated" then .data.repository.issues.pageInfo.hasNextPage=true else . end
  | if $failure=="partial" then .errors=[{message:"permission denied"}] else . end
  | @base64')
printf 'api_response:\n  body: %s\n  truncated: false\n' "${body//\"/}"
STUB
  chmod +x "$home/fakebin/gh-axi"
  printf '%s\n' "$home"
}

in_home() {
  local home=$1
  shift
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$home/fakebin:$PATH" \
    FM_CHECK_TIMEOUT=30 FM_ISSUE_VISIBILITY_INTERVAL=0 FM_BEARINGS_NOW=2026-01-03T00:00:00Z "$@"
}
check() { in_home "$1" "$CHECK" check; }
assert_json() { jq -e "$2" "$1" >/dev/null || fail "$3"; }

# Each call is a new process, including the identical retry after the first alert.
test_history_and_live_report() {
  local home out before
  home=$(make_home history)
  cp "$home/data/backlog.md" "$home/backlog-before"
  printf 'sentinel\n' > "$home/state/fixture.status"
  out=$(check "$home")
  assert_contains "$out" '2 uncertain issues (2 new)' 'first report includes both repo-qualified identities'
  assert_contains "$out" 'see Bearings --include-issues' 'alert points to the complete report'
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail 'alert is not one line'
  [ -z "$(check "$home")" ] || fail 'identical fresh-process check repeated the alert'
  in_home "$home" bash "$ROOT/bin/fm-bearings-snapshot.sh" --json --include-issues > "$home/snapshot"
  assert_json "$home/snapshot" '.issue_visibility.rows|length==2 and all(.[];.classification=="uncertain")' 'alert history hid unresolved snapshot rows'
  # Build the actual report payload from the next fresh snapshot. A refusing
  # presentation stub leaves the generated board available for rendering while
  # proving this test never starts a listener or uses a live Lavish session.
  jq '{schema:"fm-bearings-board.v1",home:"synthetic",generated:.generated,prs_live:false,
    captains_call:[],underway:[],landed:[],issue_counts:.issue_visibility.counts,
    charted:[.issue_visibility.rows[]|select(.classification=="uncertain")|
      {id,repo,title,reason:"Coverage uncertain",kind:"issue",issue_url:.url,
       issue_class:.classification,dispatchable:false}]}' "$home/snapshot" > "$home/payload"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/lavish-axi"
  chmod +x "$home/fakebin/lavish-axi"
  local board_rc=0
  in_home "$home" "$ROOT/bin/fm-bearings-board.sh" build "$home/payload" > "$home/board-out" 2>&1 || board_rc=$?
  expect_code 1 "$board_rc" 'presentation stub refuses serving'
  assert_contains "$(cat "$home/board-out")" 'cannot establish the board Lavish session' 'board did not reach presentation after building'
  node "$ROOT/tests/assets/board-render-harness.mjs" "$home/.lavish/bearings-board.html" --pick-all > "$home/rendered"
  assert_json "$home/rendered" '.error=="" and (.charted|length)==2 and all(.charted[];.pickable==false and .badges[0].text=="coverage uncertain") and (.queuedPrompts|length)==0' 'alerted issues disappeared or became dispatchable in Bearings'
  out=$(ISSUE_COUNT=2 check "$home")
  assert_contains "$out" '4 uncertain issues (2 new)' 'new report counts every unresolved issue'
  before=$(cat "$home/state/.issue-visibility-check")
  [ -z "$(ISSUE_COUNT=2 ISSUE_LABEL=do-not-build check "$home")" ] || fail 'label changed report classification'
  [ "$(jq -c '.uncertain' "$home/state/.issue-visibility-check")" = "$(printf '%s' "$before" | jq -c '.uncertain')" ] || fail 'labels changed identity history'
  cmp "$home/data/backlog.md" "$home/backlog-before" || fail 'check changed backlog'
  [ "$(cat "$home/state/fixture.status")" = sentinel ] || fail 'check changed task record'
  pass 'first alert, restart suppression, new issues, labels, report persistence and read-only task records'
}

test_coverage_then_uncertainty_returns() {
  local home out
  home=$(make_home returning)
  check "$home" >/dev/null
  cat >> "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] linked - Synthetic scope https://github.com/example-org/alpha/issues/1 (repo: alpha) (kind: ship)
EOF
  [ -z "$(check "$home")" ] || fail 'linking work emitted a new alert'
  assert_json "$home/state/.issue-visibility-check" '.uncertain==["example-org/beta#1"]' 'covered issue stayed in alert history'
  in_home "$home" bash "$ROOT/bin/fm-bearings-snapshot.sh" --json --include-issues > "$home/snapshot"
  assert_json "$home/snapshot" '.issue_visibility.rows|any(.id=="example-org/alpha#1" and .classification=="covered")' 'covered unfinished row vanished'
  printf '## In flight\n## Queued\n## Done\n' > "$home/data/backlog.md"
  out=$(check "$home")
  assert_contains "$out" '2 uncertain issues (1 new)' 'returning uncertainty did not alert'
  pass 'linked work stays in the report and returning uncertainty alerts again'
}

test_incomplete_history() {
  local home failure out
  for failure in auth rate permission truncated partial bytes rows budget; do
    home=$(make_home "failure-$failure")
    check "$home" >/dev/null
    case "$failure" in
      bytes) out=$(in_home "$home" env FM_BEARINGS_ISSUE_MAX_BYTES=10 "$CHECK") ;;
      rows) out=$(in_home "$home" env FM_BEARINGS_ISSUE_ROWS=1 "$CHECK") ;;
      budget) out=$(in_home "$home" env FM_BEARINGS_ISSUE_BUDGET=1 ISSUE_FAILURE=slow "$CHECK") ;;
      *) out=$(ISSUE_FAILURE="$failure" check "$home") ;;
    esac
    assert_contains "$out" 'unmeasured' "$failure was not unmeasured"
    assert_contains "$out" 'incomplete, counts are lower bounds' "$failure claimed complete coverage"
    assert_json "$home/state/.issue-visibility-check" '.uncertain==["example-org/alpha#1","example-org/beta#1"]' "$failure erased identity history"
  done
  home=$(make_home changed-reason)
  out=$(ISSUE_FAILURE=auth check "$home")
  [ -n "$out" ] || fail 'first unmeasured source was silent'
  [ -z "$(ISSUE_FAILURE=auth check "$home")" ] || fail 'identical unmeasured source alerted again'
  out=$(ISSUE_FAILURE=truncated check "$home")
  assert_contains "$out" '(2 new)' 'changed reason did not alert'
  out=$(ISSUE_FAILURE=auth check "$home")
  assert_contains "$out" '(2 new)' 'returning changed reason did not alert'
  assert_json "$home/state/.issue-visibility-check" '(.unmeasured|length)==2' 'history kept superseded reasons for the same sources'
  pass 'auth, rate limit, permission, truncation, byte/row/budget bounds retain history; new reasons alert'
}

test_cadence_and_input() {
  local home out before rc=0
  home=$(make_home cadence)
  out=$(in_home "$home" env FM_ISSUE_VISIBILITY_INTERVAL=86400 FM_ISSUE_VISIBILITY_NOW=100000 "$CHECK")
  [ -n "$out" ] || fail 'first daily check was silent'
  before=$(wc -l < "$home/forge-calls")
  out=$(in_home "$home" env FM_ISSUE_VISIBILITY_INTERVAL=86400 FM_ISSUE_VISIBILITY_NOW=186399 ISSUE_COUNT=2 "$CHECK")
  [ -z "$out" ] || fail 'cadence gate emitted inside interval'
  [ "$(wc -l < "$home/forge-calls")" = "$before" ] || fail 'cadence gate read forge inside interval'
  out=$(in_home "$home" env FM_ISSUE_VISIBILITY_INTERVAL=86400 FM_ISSUE_VISIBILITY_NOW=186400 ISSUE_COUNT=2 "$CHECK")
  assert_contains "$out" '4 uncertain issues (2 new)' 'daily check did not resume at interval'
  in_home "$home" env FM_ISSUE_VISIBILITY_INTERVAL=59 "$CHECK" > "$home/invalid" 2>&1 || rc=$?
  expect_code 2 "$rc" 'interval lower bound'
  assert_contains "$("$CHECK" --help)" 'not completed work' 'help conflates coverage with completion'
  pass 'daily cadence is gated without polling and coverage wording does not imply completed work'
}

test_snapshot_failure_and_timeout() {
  local home out started bin rc
  home=$(make_home timeout)
  check "$home" >/dev/null
  started=$SECONDS
  out=$(in_home "$home" env FM_CHECK_TIMEOUT=5 ISSUE_FAILURE=slow "$CHECK")
  [ "$((SECONDS-started))" -lt 5 ] || fail 'snapshot timeout missed watcher deadline'
  assert_contains "$out" 'unmeasured' 'snapshot timeout was silent'
  assert_json "$home/state/.issue-visibility-check" 'any(.unmeasured[];.reason=="snapshot timeout") and (.uncertain|length)==2' 'timeout erased history or lost reason'
  out=$(in_home "$home" env FM_BEARINGS_ISSUE_LIMIT=101 "$CHECK")
  assert_contains "$out" 'unmeasured' 'snapshot nonzero exit was silent'
  assert_json "$home/state/.issue-visibility-check" 'any(.unmeasured[];.reason=="snapshot failed (exit 2)") and (.uncertain|length)==2' 'nonzero exit lost history'
  # A sibling snapshot executable that emits invalid JSON simulates a damaged
  # installation through the same executable interface, not a production seam.
  bin="$home/copy"
  mkdir -p "$bin"
  cp "$CHECK" "$bin/"
  for lib in fm-timeout-lib.sh fm-pr-lib.sh fm-check-lib.sh; do ln -s "$ROOT/bin/$lib" "$bin/$lib"; done
  printf '#!/usr/bin/env bash\nprintf "invalid\\n"\n' > "$bin/fm-bearings-snapshot.sh"
  chmod +x "$bin/fm-bearings-snapshot.sh"
  out=$(in_home "$home" "$bin/fm-issue-visibility-check.sh")
  assert_contains "$out" 'unmeasured' 'invalid snapshot output was silent'
  assert_json "$home/state/.issue-visibility-check" '(.uncertain|length)==2' 'invalid snapshot erased history'
  # A parseable projection with a mistyped field the extraction consumes (a
  # non-string home owner) must take the same unmeasured path, not crash silently.
  home=$(make_home mistyped-owner)
  check "$home" >/dev/null
  bin="$home/copy"
  mkdir -p "$bin"
  cp "$CHECK" "$bin/"
  for lib in fm-timeout-lib.sh fm-pr-lib.sh fm-check-lib.sh; do ln -s "$ROOT/bin/$lib" "$bin/$lib"; done
  cat > "$bin/fm-bearings-snapshot.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"issue_visibility":{"schema":"fm-issue-visibility.v1","complete":true,"rows":[],"rows_omitted":0,"repos":[],"homes":[{"owner":42,"measured":false}],"omitted":[],"counts":{"uncertain":0,"unmeasured":0}}}'
STUB
  chmod +x "$bin/fm-bearings-snapshot.sh"
  rc=0
  out=$(in_home "$home" "$bin/fm-issue-visibility-check.sh") || rc=$?
  expect_code 0 "$rc" 'mistyped home owner crashed the check instead of alerting'
  assert_contains "$out" 'unmeasured' 'mistyped home owner silenced the alert'
  assert_json "$home/state/.issue-visibility-check" '(.uncertain|length)==2' 'mistyped home owner erased identity history'
  pass 'whole-snapshot timeout, nonzero exit, malformed output and mistyped fields alert without erasing history'
}

watch() {
  local home=$1 seconds=$2
  shift 2
  in_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$@" \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds "$seconds"
}

# A stopped watcher re-announces pending recovery on its next cycle. Each
# lifecycle proof therefore uses one watcher cycle in its own disposable home.
test_watcher_lifecycle() {
  local home out before rc
  home=$(make_home watcher)
  in_home "$home" "$CHECK" arm >/dev/null
  assert_present "$home/state/issue-visibility.check.sh" 'arm did not write shim'
  assert_present "$home/state/issue-visibility.check-trust" 'arm did not bind shim'
  out=$(watch "$home" 12)
  assert_contains "$out" 'check:' 'watcher did not produce check wake'
  assert_contains "$out" '2 uncertain issues (2 new)' 'watcher lost issue report'
  in_home "$home" "$CHECK" arm >/dev/null
  assert_present "$home/state/.issue-visibility-check" 're-arm of an armed home dropped alert history'
  in_home "$home" "$CHECK" disarm >/dev/null

  home=$(make_home tampered)
  in_home "$home" "$CHECK" arm >/dev/null
  printf '\n# tampered\n' >> "$home/state/issue-visibility.check.sh"
  out=$(watch "$home" 8)
  assert_contains "$out" 'rejected unauthenticated state checks' 'watcher trusted tampered shim'
  assert_absent "$home/forge-calls" 'tampered shim executed'
  in_home "$home" "$CHECK" disarm >/dev/null

  home=$(make_home disarmed)
  in_home "$home" "$CHECK" arm >/dev/null
  check "$home" >/dev/null
  before=$(wc -l < "$home/forge-calls")
  in_home "$home" "$CHECK" disarm >/dev/null
  assert_absent "$home/state/issue-visibility.check.sh" 'disarm left shim'
  assert_absent "$home/state/issue-visibility.check-trust" 'disarm left binding'
  assert_absent "$home/state/.issue-visibility-check" 'disarm left history'
  rc=0
  out=$(watch "$home" 3) || rc=$?
  expect_code 124 "$rc" 'disarmed watcher should have no actionable wake'
  [ "$(wc -l < "$home/forge-calls")" = "$before" ] || fail 'disarmed watcher dispatched check'

  home=$(make_home rearmed)
  in_home "$home" "$CHECK" arm >/dev/null
  check "$home" >/dev/null
  cp "$home/state/.issue-visibility-check" "$home/straggler"
  in_home "$home" "$CHECK" disarm >/dev/null
  # A check that straddled the disarm can rewrite the record disarm removed;
  # the next fresh arm must still start with empty alert history.
  cp "$home/straggler" "$home/state/.issue-visibility-check"
  in_home "$home" "$CHECK" arm >/dev/null
  assert_absent "$home/state/.issue-visibility-check" 'arm kept history a straddling check left after disarm'
  out=$(watch "$home" 12)
  assert_contains "$out" '2 uncertain issues (2 new)' 're-arm did not start fresh'
  in_home "$home" "$CHECK" disarm >/dev/null
  pass 'real watcher dispatch, trust rejection, complete removal and fresh re-arm'
}

test_default_bounds_slow_forge() {
  local home out started
  home=$(make_home default-slow)
  in_home "$home" "$CHECK" arm >/dev/null
  started=$SECONDS
  out=$(watch "$home" 35 ISSUE_FAILURE=slow)
  [ "$((SECONDS-started))" -lt 30 ] || fail 'default issue bounds exceeded watcher deadline'
  assert_contains "$out" 'check:' 'slow forge failed to wake through real watcher'
  assert_contains "$out" 'unmeasured' 'slow forge produced silence instead of unmeasured'
  assert_contains "$out" 'incomplete' 'slow forge claimed coverage accounted for'
  in_home "$home" "$CHECK" disarm >/dev/null
  pass 'default snapshot issue bounds with slow forge alert within the 30-second watcher deadline'
}

test_history_and_live_report
test_coverage_then_uncertainty_returns
test_incomplete_history
test_cadence_and_input
test_snapshot_failure_and_timeout
test_watcher_lifecycle
test_default_bounds_slow_forge
