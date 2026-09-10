#!/usr/bin/env bash
# Behavior tests for the bounded project-status projection and read-only snapshot mode.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT_STATUS="$ROOT/bin/fm-project-status.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-status)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_projection_runner() {  # <name> <fixture-file>
  local name=$1 fixture=$2 runner
  runner="$TMP_ROOT/$name/bin"
  mkdir -p "$runner"
  cp "$PROJECT_STATUS" "$ROOT/bin/fm-timeout-lib.sh" "$runner/"
  cat > "$runner/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${ARG_LOG:?}"
case "${FAKE_SNAPSHOT_MODE:-fixture}" in
  fixture) cat "${SNAPSHOT_FIXTURE:?}" ;;
  bad-schema) printf '{"schema":"fm-fleet-snapshot.v0"}\n' ;;
  oversized) awk 'BEGIN { printf "{\"schema\":\"fm-fleet-snapshot.v1\",\"padding\":\""; for (i=0;i<4200000;i++) printf "x"; printf "\"}\n" }' ;;
  timeout) sleep 30 ;;
  failure) exit 9 ;;
esac
SH
  chmod +x "$runner/fm-project-status.sh" "$runner/fm-fleet-snapshot.sh"
  printf '%s\n' "$runner/fm-project-status.sh"
}

write_projection_fixture() {  # <file>
  jq -n '
    {schema:"fm-fleet-snapshot.v1",generated:"2026-09-10T18:07:25Z",
     project_registry:{path:"/home/data/projects.md",present:true,available:true,reason:null,records:[{name:"AlphaProject"},{name:"BetaProject"},{name:"Collision"}]},
     backlog:{path:"/home/data/backlog.md",present:true,records:[
       {structured:true,id:"alpha-active",title:"Implement alpha",repo:"AlphaProject",kind:"ship",state:"in_flight",captain_actionable:false},
       {structured:true,id:"alpha-call",title:"Choose alpha route",repo:"AlphaProject",kind:"captain",state:"queued",captain_actionable:true,hold_reason:"choose route",hold_bucket:"live"},
       {structured:true,id:"alpha-next",title:"Queue alpha",repo:"AlphaProject",kind:"ship",state:"queued",captain_actionable:false,unresolved_blocker_ids:["alpha-active"]},
       {structured:true,id:"alpha-done",title:"Alpha delivered",repo:"AlphaProject",kind:"ship",state:"done",captain_actionable:false,completion:{verb:"merged",date:"2026-09-09"},pr_url:"https://example.test/pull/1"},
       {structured:true,id:"beta-orphan",title:"Beta orphan",repo:"BetaProject",kind:"ship",state:"in_flight",requires_child_metadata:true,captain_actionable:false}
     ]},
     main_inventory:{valid:true,reason:null,orphan_in_flight:[],unstructured_current_count:0},
     tasks:[
       {id:"alpha-active",kind:"ship",project:"/home/projects/AlphaProject",secondmate_projects:[],backlog:{structured:true,repo:"AlphaProject",title:"Implement alpha"},
        current_state:{state:"working",source:"run-step",detail:"tests"},pr:{url:null},paths:{report:{path:null}}},
       {id:"dofumax",kind:"secondmate",project:"/homes/dofumax",secondmate_projects:["DofuMax"],
        current_state:{state:"unknown"},pr:{url:null},paths:{report:{path:null}}},
       {id:"portfolio",kind:"secondmate",project:"/homes/portfolio",secondmate_projects:["AlphaMate","BetaMate"],
        current_state:{state:"unknown"},pr:{url:null},paths:{report:{path:null}}},
       {id:"mate-one",kind:"secondmate",project:"/homes/one",secondmate_projects:["Shared","Collision"],
        current_state:{state:"unknown"},pr:{url:null},paths:{report:{path:null}}},
       {id:"mate-two",kind:"secondmate",project:"/homes/two",secondmate_projects:["Shared"],
        current_state:{state:"unknown"},pr:{url:null},paths:{report:{path:null}}}
     ],
     secondmate_current:{records:[
       {id:"dofumax",current:{state:"unknown",reason:"child current state unavailable"},
        invalidity:{kind:"child_current_unavailable",ids:["dofumax-rpc-contract-v1"]},
        provenance:{selected:"structured-home",trust:"partial-structured"},
        freshness:{status:"fresh",observed_at:"2026-09-10T18:05:59Z",age_seconds:86},
        active_children:[],decisions_open:[],
        queued:[
          {id:"rpc-a",title:"RPC A",project:"DofuMax",kind:"ship",repo:"DofuMax",unresolved_blocker_ids:["dofumax-rpc-contract-v1"],blocked_reason:"blocked"},
          {id:"rpc-b",title:"RPC B",project:"DofuMax",kind:"ship",repo:"DofuMax",unresolved_blocker_ids:["dofumax-rpc-contract-v1"],blocked_reason:"blocked"}
        ],
        landed:[
          {id:"scout-new",title:"New scout",project:"DofuMax",kind:"scout",completion:{verb:"reported",date:"2026-09-10"}},
          {id:"scout-old",title:"Old scout",project:"DofuMax",kind:"scout",completion:{verb:"reported",date:"2026-09-09"}}
        ],
        counts:{active_children:0,decisions_open:0,holds:0,queued:2,landed:2,endpoints:1},omitted:[],
        parent_event:{raw:"working: delivery ready",note:"delivery ready"},contradiction:true},
       {id:"portfolio",current:{state:"unknown"},invalidity:{kind:"child_current_unavailable",ids:["alpha-unavailable"]},
        invalidities:[{kind:"child_current_unavailable",ids:["alpha-unavailable"],project:"AlphaMate"}],
        provenance:{selected:"structured-home",trust:"partial-structured"},
        freshness:{status:"fresh",observed_at:"2026-09-10T18:05:59Z",age_seconds:86},
        active_children:[{id:"alpha-secret",title:"Alpha secret",project:"AlphaMate",kind:"ship",state:"working",source:"run-step",doing:"private alpha work"}],
        decisions_open:[{id:"alpha-call",project:"AlphaMate",key:"alpha-call",summary:"Alpha secret decision",source:"status"}],
        holds:[],
        queued:[{id:"alpha-queue",title:"Alpha secret queue",project:"AlphaMate",repo:"AlphaMate"},{id:"beta-queue",title:"Beta queue",project:"BetaMate",repo:"BetaMate"},{id:"legacy",title:"Unidentified legacy row"}],
        landed:[{id:"alpha-landed",title:"Alpha secret landed",project:"AlphaMate"},{id:"beta-landed",title:"Beta landed",project:"BetaMate"}],
        counts:{active_children:1,decisions_open:1,holds:0,queued:3,landed:2,endpoints:1},omitted:[],contradiction:false}
     ]}}
  ' > "$1"
}

test_projection_resolution_and_authority() {
  local fixture runner arg_log out
  fixture="$TMP_ROOT/projection.json"
  arg_log="$TMP_ROOT/projection.args"
  write_projection_fixture "$fixture"
  runner=$(make_projection_runner projection "$fixture")

  out=$(ARG_LOG="$arg_log" SNAPSHOT_FIXTURE="$fixture" "$runner" --json alphaproject)
  printf '%s' "$out" | jq -e '
    .schema == "fm-project-status.v1"
      and .match == {status:"exact",project:"AlphaProject",candidates:[]}
      and .owner == {kind:"main",id:null}
      and .current.state == "working"
      and [.underway[].id] == ["alpha-active"]
      and [.captain_calls[].id] == ["alpha-call"]
      and [.queued[].id] == ["alpha-call","alpha-next"]
      and [.recently_landed[].id] == ["alpha-done"]
  ' >/dev/null || fail "exact local project projection was wrong: $out"
  [ "$(cat "$arg_log")" = "--json --read-only" ] \
    || fail "project status did not invoke the fleet snapshot read-only"

  out=$(ARG_LOG="$arg_log" SNAPSHOT_FIXTURE="$fixture" "$runner" --json BetaProject)
  printf '%s' "$out" | jq -e '
    .current == {state:"unknown",reason_code:"main_inventory_incomplete",reason_ids:["beta-orphan"]}
      and .underway == [] and ([.current.reason_ids[]] | index("alpha-active") | not)
  ' >/dev/null || fail "main inventory invalidity was not scoped to its project: $out"

  out=$(ARG_LOG="$arg_log" SNAPSHOT_FIXTURE="$fixture" "$runner" --json DofuMax)
  printf '%s' "$out" | jq -e '
    .match.status == "exact" and .owner == {kind:"secondmate",id:"dofumax"}
      and .current == {state:"unknown",reason_code:"child_current_unavailable",reason_ids:["dofumax-rpc-contract-v1"]}
      and .underway == [] and .captain_calls == []
      and [.queued[].id] == ["rpc-a","rpc-b"]
      and [.recently_landed[].id] == ["scout-new","scout-old"]
      and .counts == {underway:0,captain_calls:0,queued:2,landed:2}
      and .provenance.source == "fm-fleet-snapshot.v1/secondmate_current"
      and .provenance.trust == "partial-structured"
      and (.warnings | any(contains("historical parent evidence")))
  ' >/dev/null || fail "partial DofuMax projection did not preserve structured facts: $out"
  printf '%s' "$out" | jq -e '.current.state != "working"' >/dev/null \
    || fail "contradictory parent history replaced structured current state"

  out=$(ARG_LOG="$arg_log" SNAPSHOT_FIXTURE="$fixture" "$runner" --json BetaMate)
  printf '%s' "$out" | jq -e '
    .current.state == "no_active_work"
      and .underway == [] and .captain_calls == []
      and [.queued[].id] == ["beta-queue"]
      and [.recently_landed[].id] == ["beta-landed"]
      and .counts == {underway:0,captain_calls:0,queued:1,landed:1}
      and (.current.reason_ids | index("alpha-unavailable") | not)
      and (.omitted | any(.surface == "queued" and .reason == "project identity unavailable"))
      and ([.queued[].title,.recently_landed[].title] | all(contains("Alpha secret") | not))
  ' >/dev/null || fail "multi-project secondmate projection leaked or misattributed another project: $out"

  out=$(ARG_LOG="$arg_log" SNAPSHOT_FIXTURE="$fixture" "$runner" --json Shared)
  printf '%s' "$out" | jq -e '
    .match.status == "ambiguous" and .current.reason_code == "ambiguous_project_owner"
      and (.current.reason_ids | sort) == ["secondmate:mate-one","secondmate:mate-two"]
      and .underway == []
  ' >/dev/null || fail "ambiguous exact project ownership was not refused: $out"

  out=$(ARG_LOG="$arg_log" SNAPSHOT_FIXTURE="$fixture" "$runner" --json Collision)
  printf '%s' "$out" | jq -e '
    .match.status == "ambiguous" and .current.reason_code == "ambiguous_project_owner"
      and (.current.reason_ids | sort) == ["main:","secondmate:mate-one"]
  ' >/dev/null || fail "main and secondmate ownership collision was not refused: $out"

  out=$(ARG_LOG="$arg_log" SNAPSHOT_FIXTURE="$fixture" "$runner" --json Alpha)
  printf '%s' "$out" | jq -e '.match.status == "unknown" and .current.reason_code == "project_not_found"' >/dev/null \
    || fail "fuzzy project input unexpectedly matched: $out"
  out=$(ARG_LOG="$arg_log" SNAPSHOT_FIXTURE="$fixture" "$runner" --json Missing)
  printf '%s' "$out" | jq -e '.match.status == "unknown"' >/dev/null \
    || fail "unknown project result was not explicit: $out"
  pass "project status resolves exact local and secondmate owners without trusting parent history"
}

test_projection_source_failures_are_explicit() {
  local fixture runner arg_log out started elapsed mode reason
  fixture="$TMP_ROOT/failure-fixture.json"
  arg_log="$TMP_ROOT/failure.args"
  write_projection_fixture "$fixture"
  runner=$(make_projection_runner source-failures "$fixture")
  for mode in bad-schema oversized failure; do
    case "$mode" in
      bad-schema) reason=incompatible_source ;;
      oversized) reason=source_too_large ;;
      failure) reason=source_unreadable ;;
    esac
    out=$(ARG_LOG="$arg_log" SNAPSHOT_FIXTURE="$fixture" FAKE_SNAPSHOT_MODE="$mode" "$runner" --json AlphaProject)
    printf '%s' "$out" | jq -e --arg reason "$reason" '
      .schema == "fm-project-status.v1" and .match.status == "unavailable"
        and .current.state == "unavailable" and .current.reason_code == $reason
        and .underway == []
    ' >/dev/null || fail "$mode source failure was not explicit: $out"
  done
  started=$(date +%s)
  out=$(ARG_LOG="$arg_log" SNAPSHOT_FIXTURE="$fixture" FAKE_SNAPSHOT_MODE=timeout "$runner" --json AlphaProject)
  elapsed=$(( $(date +%s) - started ))
  printf '%s' "$out" | jq -e '.match.status == "unavailable" and .current.reason_code == "source_timeout"' >/dev/null \
    || fail "snapshot timeout was not explicit: $out"
  [ "$elapsed" -ge 7 ] && [ "$elapsed" -le 12 ] \
    || fail "snapshot timeout did not honor the eight-second bound: ${elapsed}s"
  pass "project status exposes bad schema, oversized output, process failure, and timeout"
}

test_projection_bounds_and_counts() {
  local fixture bounded runner arg_log out bytes
  fixture="$TMP_ROOT/bounds-source.json"
  bounded="$TMP_ROOT/bounds.json"
  arg_log="$TMP_ROOT/bounds.args"
  write_projection_fixture "$fixture"
  jq '
    .secondmate_current.records[0]
      |= (.active_children = [range(0;7) | {id:("active-" + tostring),project:"DofuMax",kind:"ship",state:"working",source:"run-step",doing:"bounded"}]
          | .decisions_open = [range(0;7) | {id:("call-" + tostring),project:"DofuMax",key:("call-" + tostring),verb:"needs-decision",summary:"choose",source:"status"}]
          | .queued = [range(0;7) | {id:("queue-" + tostring),title:"queued",project:"DofuMax",kind:"ship",repo:"DofuMax",unresolved_blocker_ids:[]}]
          | .landed = [range(0;5) | {id:("landed-" + tostring),title:"landed",project:"DofuMax",kind:"ship",completion:{verb:"done",date:"2026-09-10"}}]
          | .counts = {active_children:7,decisions_open:7,holds:0,queued:7,landed:5,endpoints:7}
          | .omitted = [range(0;12) | {surface:("source-" + tostring),count:1}])
  ' "$fixture" > "$bounded"
  runner=$(make_projection_runner bounds "$bounded")
  out=$(ARG_LOG="$arg_log" SNAPSHOT_FIXTURE="$bounded" "$runner" --json DofuMax)
  bytes=$(printf '%s' "$out" | LC_ALL=C wc -c | tr -d ' ')
  [ "$bytes" -le 65536 ] || fail "project status exceeded 64 KiB: $bytes"
  printf '%s' "$out" | jq -e '
    (.underway | length) == 5 and (.captain_calls | length) == 5
      and (.queued | length) == 5 and (.recently_landed | length) == 3
      and .counts == {underway:7,captain_calls:7,queued:7,landed:5}
      and ((.warnings | length) + (.omitted | length)) <= 10
      and (.omitted | any(.surface == "underway" and .count == 2))
  ' >/dev/null || fail "project status bounds or total counts were wrong: $out"
  pass "project status caps all collections, disclosures, and final JSON while preserving totals"
}

test_snapshot_read_only_uses_cache_without_writing() {
  local home cache remote_home cache_key cache_file fakebin before after out
  home="$TMP_ROOT/read-only-home"
  cache="$home/state/secondmate-summary-cache"
  remote_home=/srv/remote-firstmate
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$cache"
  chmod 700 "$cache"
  cat > "$home/data/secondmates.md" <<EOF
- remote - Remote scope (host: fake-host; root: /srv/code; home: $remote_home; scope: remote; projects: RemoteProject; added 2026-09-10)
EOF
  fm_write_meta "$home/state/remote.meta" \
    "kind=secondmate" "home=$remote_home" "projects=RemoteProject" \
    "remote_host=fake-host" "remote_root=/srv/code" "harness=codex" "mode=secondmate"
  cache_key=$(printf '%s\n%s\n%s\n' remote fake-host "$remote_home" | shasum -a 256 | awk '{print $1}')
  cache_file="$cache/$cache_key.json"
  jq -n --arg home "$remote_home" '
    {schema:"fm-secondmate-home-summary.v1",hold_classifier_schema:"fm-captain-hold-buckets.v1",
     generated:"2026-09-10T18:00:00Z",generated_epoch:1789063200,home:$home,valid:true,reason:null,
     invalidity:{kind:null,ids:[]},state:"no_active_work",active_children:[],decisions_open:[],holds:[],queued:[],landed:[],endpoints:[],
     counts:{active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0},omitted:[]}
  ' > "$cache_file"
  before=$(shasum -a 256 "$cache_file" | awk '{print $1}')
  fakebin="$TMP_ROOT/read-only-fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/fake-ssh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_SNAPSHOT_CACHE_DIR="$cache" FM_SNAPSHOT_NOW=2026-09-10T18:07:25Z \
    FM_SNAPSHOT_NOW_EPOCH=1789063645 "$SNAPSHOT" --json --read-only)
  after=$(shasum -a 256 "$cache_file" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "read-only snapshot rewrote an existing cache entry"
  printf '%s' "$out" | jq -e '
    .secondmate_current.records[] | select(.id == "remote")
    | .provenance.summary_source == "remote-ledger-cache"
      and .freshness.status == "cached"
      and .freshness.age_seconds == 445
  ' >/dev/null || fail "read-only snapshot did not consume the existing cache: $out"

  home="$TMP_ROOT/read-only-no-cache"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cat > "$home/data/secondmates.md" <<EOF
- remote - Remote scope (host: fake-host; root: /srv/code; home: $remote_home; scope: remote; projects: RemoteProject; added 2026-09-10)
EOF
  fm_write_meta "$home/state/remote.meta" \
    "kind=secondmate" "home=$remote_home" "projects=RemoteProject" \
    "remote_host=fake-host" "remote_root=/srv/code" "harness=codex" "mode=secondmate"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_SNAPSHOT_CACHE_DIR="$home/state/never-create" "$SNAPSHOT" --json --read-only >/dev/null \
    || fail "read-only snapshot failed without an existing cache"
  [ ! -e "$home/state/never-create" ] || fail "read-only snapshot created its cache directory"
  pass "snapshot read-only mode reads cache but never creates or refreshes it"
}

test_projection_resolution_and_authority
test_projection_source_failures_are_explicit
test_projection_bounds_and_counts
test_snapshot_read_only_uses_cache_without_writing

echo "All fm-project-status tests passed."
