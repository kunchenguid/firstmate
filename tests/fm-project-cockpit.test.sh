#!/usr/bin/env bash
# Behavior tests for the deterministic Project Cockpit projection and builder.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECTOR="$ROOT/bin/fm-project-cockpit-snapshot.sh"
BOARD="$ROOT/bin/fm-project-cockpit-board.sh"
TEMPLATE="$ROOT/assets/project-cockpit-template.html"
FIXTURES="$ROOT/tests/fixtures/project-cockpit"
TMP_ROOT=$(fm_test_tmproot fm-project-cockpit)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

project() {  # <fixture> <output> [extra args...]
  local fixture=$1 output=$2
  shift 2
  "$PROJECTOR" --from-snapshot "$FIXTURES/$fixture" --observed-at 2026-09-15T12:01:00Z "$@" > "$output"
}

files_digest() {  # <home>
  local home=$1
  find "$home/data" "$home/state" "$home/projects" -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum
}

test_projection_is_deterministic_and_allowlisted() {
  local one=$TMP_ROOT/model-one.json two=$TMP_ROOT/model-two.json
  project states.json "$one"
  project states.json "$two"
  cmp -s "$one" "$two" || fail "fixed snapshot and observation time did not produce byte-stable output"
  jq -e '
    .schema == "fm-project-cockpit.v1"
    and .freshness == "fresh"
    and .counts == {running:2,waiting:2,blocked:1,attention:2}
    and [.projects[].id] == ["alpha","beta","delta","gamma"]
    and ([.projects[].tasks[] | select(.id == "healthy-work")][0]
      | .state == "working" and .crew.summary == "1 LIVE" and .elapsed_seconds == 5460)
    and ([.projects[].tasks[] | select(.id == "captain-call")][0]
      | .hold.classification == "live" and .hold.actionable == true
        and .hold.question == "Keep legacy readers or require version 2?"
        and .elapsed_seconds == null)
    and ([.projects[].tasks[] | select(.id == "blocked-work")][0]
      | .state == "blocked" and .blockers == ["upstream-api"] and .artifacts.pr_url == null)
    and ([.projects[].tasks[] | select(.id == "unknown-work")][0]
      | .state == "unknown" and .crew.summary == "UNKNOWN" and .state != "stopped")
    and ([.projects[].tasks[] | select(.id == "done-work")][0]
      | .lane == "recently_completed" and .artifacts.pr_url == "https://github.com/example/gamma/pull/7")
  ' "$one" >/dev/null || fail "projected state semantics, stable ordering, elapsed time, or safe links are wrong"
  for unsafe in PRIVATE-INBOX-TEXT-MUST-NOT-LEAK SECRET-STATUS-DETAIL SECRET-RAW-LINE PRIVATE-EVENT-TEXT PRIVATE-DECISION-TEXT FORBIDDEN-CONTROL-TEXT; do
    ! grep -Fq "$unsafe" "$one" || fail "unsafe source text leaked through the allowlist: $unsafe"
  done
  pass "projection is deterministic, stably ordered, semantically faithful, and allowlisted"
}

test_stale_partial_invalid_empty_and_replacement_states() {
  local stale=$TMP_ROOT/stale.json partial=$TMP_ROOT/partial.json invalid=$TMP_ROOT/invalid.json
  local empty=$TMP_ROOT/empty.json replacement=$TMP_ROOT/replacement.json truncated=$TMP_ROOT/truncated.json
  FM_COCKPIT_STALE_AFTER=999999 "$PROJECTOR" --from-snapshot "$FIXTURES/states.json" --observed-at 2026-09-15T12:10:01Z > "$stale"
  jq -e '.freshness == "stale" and .age_seconds == 601 and .stale_after_seconds == 300' "$stale" >/dev/null \
    || fail "stale age classification is wrong"
  jq '.secondmate_current.truncated=true | .secondmate_landed.partial=["mate"]' "$FIXTURES/states.json" \
    | "$PROJECTOR" --from-snapshot - --observed-at 2026-09-15T12:01:00Z > "$partial"
  jq -e '.inventory.status == "partial" and .inventory.partial_reasons == ["secondmate inventory partial","secondmate inventory truncated"]' "$partial" >/dev/null \
    || fail "partial inventory disclosure is wrong"
  jq '.main_inventory.valid=false | .main_inventory.reason="in-flight backlog item has no child metadata"' "$FIXTURES/empty.json" \
    | "$PROJECTOR" --from-snapshot - --observed-at 2026-09-15T12:01:00Z > "$invalid"
  jq -e '.inventory.status == "invalid" and .projects == [] and .inventory.reason != null' "$invalid" >/dev/null \
    || fail "invalid inventory was not distinguished from empty"
  project empty.json "$empty"
  jq -e '.inventory.status == "empty" and .projects == [] and .freshness == "fresh"' "$empty" >/dev/null \
    || fail "valid empty fleet was not explicit"
  project replacement.json "$replacement"
  jq -e '[.projects[].tasks[]][0] | .spawn_gen == "gen-healthy-2" and .state == "unknown" and .crew.summary == "UNKNOWN"' "$replacement" >/dev/null \
    || fail "replacement generation did not discard the old observation"
  jq '.backlog.records=[] | .tasks=[range(0;501) as $i | (.tasks[0] | .id=("task-"+($i|tostring)) | .spawn_gen=("gen-"+($i|tostring)) | .project="/work/crowded" | .backlog=null)]' "$FIXTURES/states.json" \
    | "$PROJECTOR" --from-snapshot - --observed-at 2026-09-15T12:01:00Z > "$truncated"
  jq -e '.inventory.truncated == true and ([.projects[].tasks[]] | length) == 160 and .projects[0].total_task_count == 500' "$truncated" >/dev/null \
    || fail "oversized inventory did not disclose and enforce task bounds"
  jq '.backlog.records=[(.backlog.records[] | select(.id == "queued-work") | .id="overflow-queued")]
      | .tasks=[range(0;500) as $i | (.tasks[0] | .id=("task-"+($i|tostring)) | .spawn_gen=("gen-"+($i|tostring)) | .project=("/work/project-"+((($i % 5)+1)|tostring)) | .backlog=null)]' "$FIXTURES/states.json" \
    | "$PROJECTOR" --from-snapshot - --observed-at 2026-09-15T12:01:00Z > "$truncated"
  jq -e '.inventory.truncated == true and ([.projects[].tasks[]] | length) == 500' "$truncated" >/dev/null \
    || fail "pre-cap combined population did not disclose its omitted item"
  pass "projection distinguishes stale, partial, invalid, empty, and replacement-generation states"
}

test_secondmate_structured_surfaces_are_projected_once() {
  local model=$TMP_ROOT/secondmate.json
  jq '.secondmate_current = {
        records:[{
          id:"mate-one",home:"/fleet/mates/one",spawn_gen:"mate-gen",provenance:{selected:"structured-home"},
          freshness:{observed_at:"2026-09-15T11:59:30Z"},
          active_children:[
            {id:"child-live",kind:"ship",state:"working",repo:"omega",name:"Remote implementation",source:"structured-home",doing:"PRIVATE-REMOTE-DETAIL"},
            {id:"release-call",kind:"ship",state:"working",repo:"omega",name:"Release preparation",source:"structured-home",doing:"PRIVATE-REMOTE-DECISION"}
          ],
          decisions_open:[{id:"release-call",verb:"captain-hold",summary:"Choose release route",reason:"Pick blue or green",hold_bucket:"live",source:"backlog"}],
          queued:[
            {id:"release-call",title:"Release preparation",repo:"omega",kind:"captain",captain_actionable:true,hold_bucket:"live",hold_reason:"Pick blue or green",unresolved_blocker_ids:[]},
            {id:"queued-child",title:"Remote follow-up",repo:"omega",kind:"ship",captain_actionable:false,hold_bucket:null,unresolved_blocker_ids:[]}
          ],
          landed:[{id:"landed-child",title:"Remote delivery",kind:"ship",completion:{verb:"merged",date:"2026-09-14"},pr_url:"https://github.com/example/omega/pull/9",report_path:null}],
          omitted:[]
        }],total:1,shown:1,truncated:0
      }' "$FIXTURES/states.json" \
    | "$PROJECTOR" --from-snapshot - --observed-at 2026-09-15T12:01:00Z > "$model"
  jq -e '
    ([.projects[].tasks[] | select(.id | startswith("mate-one:"))] | length) == 4
    and ([.projects[].tasks[] | select(.id == "mate-one:child-live")][0]
      | .lane == "running" and .project_id == "omega" and .crew.kind == "ship")
    and ([.projects[].tasks[] | select(.id == "mate-one:release-call")][0]
      | .lane == "waiting" and .attention == true and .hold.actionable == true
        and .hold.question == "Pick blue or green")
    and ([.projects[].tasks[] | select(.id == "mate-one:queued-child")][0].lane == "queued")
    and ([.projects[].tasks[] | select(.id == "mate-one:landed-child")][0]
      | .lane == "recently_completed" and .artifacts.pr_url == "https://github.com/example/omega/pull/9")
  ' "$model" >/dev/null || fail "bounded secondmate surfaces were not projected with stable identity and deduplication"
  ! grep -Fq 'PRIVATE-REMOTE-' "$model" || fail "secondmate prose outside the allowlist leaked into the cockpit"
  pass "secondmate structured surfaces project once through the cockpit allowlist"
}

test_builder_is_fail_closed_and_atomic() {
  local home=$TMP_ROOT/builder-home model=$TMP_ROOT/builder.json prior altered out rc before after
  project states.json "$model"
  out=$(FM_HOME="$home" "$BOARD" build "$model") || fail "valid cockpit build failed: $out"
  assert_contains "$out" "board: $home/.lavish/project-cockpit.html" "builder did not report the stable path"
  prior=$home/.lavish/project-cockpit.html
  [ "$(stat -c '%a' "$prior")" = 600 ] || fail "cockpit artifact permissions are not private"
  grep -Fq '"schema":"fm-project-cockpit.v1"' "$prior" || fail "built artifact lacks embedded cockpit data"
  altered=$TMP_ROOT/injection.json
  jq '(.projects[0].tasks[0].name)="</script><script>globalThis.injected=true</script>"' "$model" > "$altered"
  FM_HOME="$home" "$BOARD" build "$altered" >/dev/null || fail "safe script-boundary text was refused"
  ! grep -Fq '</script><script>globalThis.injected=true' "$prior" || fail "script-closing text survived unescaped"
  grep -Fq '\u003c/script>' "$prior" || fail "script-closing text was not safely JSON escaped"
  before=$(sha256sum "$prior" | awk '{print $1}')
  jq '.projects[0].tasks[0].artifacts.pr_url="http://unsafe.example/pull/1"' "$model" > "$altered"
  set +e
  out=$(FM_HOME="$home" "$BOARD" build "$altered" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "builder accepted an unsafe artifact URL"
  assert_contains "$out" "does not satisfy fm-project-cockpit.v1" "unsafe URL refusal did not name the schema"
  after=$(sha256sum "$prior" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "failed validation replaced the previous artifact"
  set +e
  out=$(FM_HOME="$home" "$BOARD" path 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "removed path command remained publicly callable"
  pass "builder escapes script boundaries and leaves the prior artifact untouched on validation failure"
}

test_build_path_does_not_mutate_fleet_or_invoke_authority() {
  local runtime=$TMP_ROOT/runtime home=$TMP_ROOT/no-mutation-home model=$TMP_ROOT/no-mutation.json
  local fakebin=$TMP_ROOT/serve-bin before=$TMP_ROOT/before.digest after=$TMP_ROOT/after.digest poison=$TMP_ROOT/poison.log name out
  mkdir -p "$runtime/bin" "$runtime/assets" "$fakebin" "$home/data/task" "$home/state" "$home/projects/project"
  cp "$BOARD" "$PROJECTOR" "$runtime/bin/"
  cp "$TEMPLATE" "$runtime/assets/"
  for name in fm-captain-hold.sh fm-procevent-lavish.sh fm-send.sh fm-control.sh; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexit 97\n' "$name" "$poison" > "$runtime/bin/$name"
    chmod +x "$runtime/bin/$name"
  done
  printf 'backlog sentinel\n' > "$home/data/backlog.md"
  printf 'report sentinel\n' > "$home/data/task/report.md"
  printf 'meta sentinel\n' > "$home/state/task.meta"
  printf 'status sentinel\n' > "$home/state/task.status"
  printf 'project sentinel\n' > "$home/projects/project/file"
  files_digest "$home" > "$before"
  project states.json "$model"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$runtime" "$runtime/bin/fm-project-cockpit-board.sh" build "$model" >/dev/null \
    || fail "isolated no-mutation build failed"
  # shellcheck disable=SC2016 # The generated stub expands these variables when it runs.
  printf '#!/usr/bin/env bash\nif [ "$#" -eq 0 ]; then printf "%%s,open,\\\"http://127.0.0.1/\\\",0\\n" "${FAKE_COCKPIT_BOARD:?}"; else printf "status: open\\n"; fi\n' > "$fakebin/lavish-axi"
  chmod +x "$fakebin/lavish-axi"
  out=$(PATH="$fakebin:$PATH" FAKE_COCKPIT_BOARD="$home/.lavish/project-cockpit.html" FM_HOME="$home" FM_ROOT_OVERRIDE="$runtime" \
    "$runtime/bin/fm-project-cockpit-board.sh" serve "$model") || fail "serve-only Lavish path failed: $out"
  assert_contains "$out" "served: $home/.lavish/project-cockpit.html" "serve-only path did not verify its presentation session"
  files_digest "$home" > "$after"
  cmp -s "$before" "$after" || fail "projection or build changed authoritative fleet/project records"
  [ ! -e "$poison" ] || fail "observational build invoked an authority-bearing command: $(<"$poison")"
  [ -f "$home/.lavish/project-cockpit.html" ] || fail "the allowed presentation artifact was not written"
  pass "projection, build, and serve-only Lavish are observational outside the private presentation artifact"
}

test_live_collection_failure_is_explicitly_unavailable() {
  local runtime=$TMP_ROOT/unavailable-runtime out=$TMP_ROOT/unavailable.json
  mkdir -p "$runtime/bin"
  cp "$PROJECTOR" "$runtime/bin/"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$runtime/bin/fm-fleet-snapshot.sh"
  chmod +x "$runtime/bin/fm-fleet-snapshot.sh"
  FM_COCKPIT_NOW=2026-09-15T12:01:00Z "$runtime/bin/fm-project-cockpit-snapshot.sh" > "$out" \
    || fail "a failed live snapshot did not produce the bounded unavailable model"
  jq -e '.inventory.status == "unavailable" and .freshness == "unavailable" and .projects == []' "$out" >/dev/null \
    || fail "snapshot failure was confused with an empty inventory"
  pass "live collection failure renders unavailable without retaining task identity"
}

test_refresh_uses_canonical_snapshot_without_fleet_mutation() {
  local home=$TMP_ROOT/refresh-home before=$TMP_ROOT/refresh-before.digest after=$TMP_ROOT/refresh-after.digest out
  mkdir -p "$home/data" "$home/state" "$home/projects/project"
  printf '## In flight\n\n## Queued\n- [ ] queued-refresh - Queued refresh (repo: refresh) (kind: ship)\n\n## Done\n' > "$home/data/backlog.md"
  printf 'project sentinel\n' > "$home/projects/project/file"
  files_digest "$home" > "$before"
  out=$(FM_HOME="$home" "$BOARD" refresh) || fail "canonical refresh failed: $out"
  files_digest "$home" > "$after"
  cmp -s "$before" "$after" || fail "canonical refresh changed backlog, task, or project state"
  assert_contains "$out" "board: $home/.lavish/project-cockpit.html" "refresh did not publish the stable artifact"
  sed -n '/<script id="cockpit-data" type="application\/json">/,/<\/script>/p' "$home/.lavish/project-cockpit.html" \
    | sed '1d;$d' \
    | jq -e '.schema == "fm-project-cockpit.v1" and ([.projects[].tasks[] | select(.id == "queued-refresh")] | length) == 1' >/dev/null \
    || fail "refresh artifact did not render the canonical fleet snapshot"
  pass "refresh consumes the canonical snapshot and mutates only its private artifact"
}

test_projection_does_not_call_network_tools() {
  local runtime=$TMP_ROOT/network-runtime fakebin=$TMP_ROOT/network-bin out=$TMP_ROOT/network.json poison=$TMP_ROOT/network.log name
  mkdir -p "$runtime/bin" "$fakebin"
  cp "$PROJECTOR" "$runtime/bin/"
  printf '#!/usr/bin/env bash\n[ "$1" = --json-read-only ] || exit 95\nexec jq . "%s"\n' "$FIXTURES/states.json" > "$runtime/bin/fm-fleet-snapshot.sh"
  chmod +x "$runtime/bin/fm-fleet-snapshot.sh"
  for name in curl wget gh gh-axi ssh; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexit 96\n' "$name" "$poison" > "$fakebin/$name"
    chmod +x "$fakebin/$name"
  done
  PATH="$fakebin:$PATH" FM_COCKPIT_NOW=2026-09-15T12:01:00Z "$runtime/bin/fm-project-cockpit-snapshot.sh" > "$out" \
    || fail "default projection with a canonical snapshot stub failed"
  [ ! -e "$poison" ] || fail "projection invoked a network tool: $(<"$poison")"
  jq -e '.schema == "fm-project-cockpit.v1"' "$out" >/dev/null || fail "network-isolated projection output is invalid"
  pass "default projection makes no independent external network call"
}

test_read_only_fleet_collection_uses_but_never_updates_cache() {
  local home=$TMP_ROOT/read-only-fleet remote=$TMP_ROOT/remote-summary-home fakebin=$TMP_ROOT/remote-summary-bin
  local cache=$home/state/summary-cache before after output=$TMP_ROOT/read-only-fleet.json
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$remote/state" "$fakebin"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf -- '- mate-remote - fixture (host: remote-host; root: /remote/root; home: /remote/home; scope: fixture; projects: omega; added 2026-09-15)\n' > "$home/data/secondmates.md"
  fm_write_meta "$home/state/mate-remote.meta" \
    'kind=secondmate' 'mode=secondmate' 'harness=pi' 'remote_host=remote-host' \
    'remote_root=/remote/root' 'home=/remote/home'
  jq -n '{
    schema:"fm-secondmate-home-summary.v1",hold_classifier_schema:"fm-captain-hold-buckets.v1",
    generated:"2026-09-15T12:00:00Z",generated_epoch:1789473600,home:"/remote/home",
    valid:true,reason:null,invalidity:{kind:null,ids:[]},state:"no_active_work",
    active_children:[],decisions_open:[],holds:[],queued:[],landed:[],endpoints:[],
    counts:{active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0},omitted:[]
  }' > "$remote/state/home-summary.json"
  cat > "$fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
if [ -f "$FM_TEST_REMOTE_SUMMARY" ]; then
  cat "$FM_TEST_REMOTE_SUMMARY"
else
  exit 1
fi
SH
  chmod +x "$fakebin/fake-ssh"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_TEST_REMOTE_SUMMARY="$remote/state/home-summary.json" FM_SNAPSHOT_CACHE_DIR="$cache" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json-read-only > "$output" \
    || fail "read-only fleet collection failed with a healthy remote ledger"
  [ ! -e "$cache" ] || fail "read-only fleet collection created the remote-summary cache"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_TEST_REMOTE_SUMMARY="$remote/state/home-summary.json" FM_SNAPSHOT_CACHE_DIR="$cache" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$output" \
    || fail "default fleet collection did not seed its remote-summary cache"
  before=$(find "$cache" -type f -exec sha256sum {} + | sort)
  jq '.generated="2026-09-15T12:02:00Z" | .generated_epoch=1789473720' "$remote/state/home-summary.json" > "$remote/state/new-summary.json"
  mv "$remote/state/new-summary.json" "$remote/state/home-summary.json"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_TEST_REMOTE_SUMMARY="$remote/state/home-summary.json" FM_SNAPSHOT_CACHE_DIR="$cache" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json-read-only > "$output" \
    || fail "read-only fleet collection failed while cache data existed"
  after=$(find "$cache" -type f -exec sha256sum {} + | sort)
  [ "$before" = "$after" ] || fail "read-only fleet collection refreshed the remote-summary cache"
  rm -f "$remote/state/home-summary.json"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_TEST_REMOTE_SUMMARY="$remote/state/home-summary.json" FM_SNAPSHOT_CACHE_DIR="$cache" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json-read-only > "$output" \
    || fail "read-only fleet collection failed to consume its existing cache"
  jq -e '.secondmate_current.records[0].provenance.summary_source == "remote-ledger-cache"' "$output" >/dev/null \
    || fail "read-only fleet collection did not consume the existing cache"
  pass "read-only fleet collection consumes cache without creating or refreshing it"
}

test_projection_is_deterministic_and_allowlisted
test_stale_partial_invalid_empty_and_replacement_states
test_secondmate_structured_surfaces_are_projected_once
test_builder_is_fail_closed_and_atomic
test_build_path_does_not_mutate_fleet_or_invoke_authority
test_live_collection_failure_is_explicitly_unavailable
test_refresh_uses_canonical_snapshot_without_fleet_mutation
test_projection_does_not_call_network_tools
test_read_only_fleet_collection_uses_but_never_updates_cache
