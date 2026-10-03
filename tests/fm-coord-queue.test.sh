#!/usr/bin/env bash
# Public-interface tests for the advisory integration slot.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(fm_test_tmproot fm-coord-queue)
db=$tmp/coord.sqlite3
coord() { "$ROOT/bin/fm-coord.sh" --db "$db" "$@"; }
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
reject() {
  if coord "$1" "$2" > "$tmp/unexpected" 2> "$tmp/error"; then
    fail "$3"
  fi
}
base=0000000000000000000000000000000000000000
head_a=1111111111111111111111111111111111111111
head_b=2222222222222222222222222222222222222222
head_b2=5555555555555555555555555555555555555555
base_new=3333333333333333333333333333333333333333
merge_oid=4444444444444444444444444444444444444444

main_db=$db
db=$tmp/upgrade-v2.sqlite3
sqlite3 "$db" < "$ROOT/bin/fm-coord-migrations/001.sql"
sqlite3 "$db" < "$ROOT/bin/fm-coord-migrations/002.sql"
sqlite3 "$db" "INSERT INTO meta(key,value) VALUES('boot_id','synthetic-previous-boot'); PRAGMA user_version=2;"
upgraded=$(coord init)
[ "$(field "$upgraded" schema_version)" = 4 ] || fail 'existing v2 database must upgrade through numbered migrations'
db=$tmp/upgrade-v3.sqlite3
sqlite3 "$db" < "$ROOT/bin/fm-coord-migrations/001.sql"
sqlite3 "$db" < "$ROOT/bin/fm-coord-migrations/002.sql"
sqlite3 "$db" < "$ROOT/bin/fm-coord-migrations/003.sql"
sqlite3 "$db" "INSERT INTO meta(key,value) VALUES('boot_id','synthetic-previous-boot'); INSERT INTO participants(home_id,repos_json) VALUES('legacy','[\"owner/repo\"]'); PRAGMA user_version=3;"
upgraded=$(coord init)
[ "$(field "$upgraded" schema_version)" = 4 ] || fail 'existing v3 database must upgrade to host-aware schema'
coord enroll '{"request_id":"bind-legacy-host","home_id":"legacy","repos":["owner/repo"],"host_id":"legacy-test-host"}' > /dev/null
field "$(coord inspect '{}')" participants | python3 -c 'import ast,sys; assert any(p["home_id"]=="legacy" and p["host_id"]=="legacy-test-host" for p in ast.literal_eval(sys.stdin.read()))' || fail 'an existing participant must bind its host after v3 upgrade'
db=$main_db

authority_token=test-authority-credential-0123456789abcdef
FM_COORD_AUTHORITY_TOKEN="$authority_token" coord init > /dev/null
coord enroll '{"request_id":"enroll-a","home_id":"a","repos":["owner/repo"]}' > /dev/null
coord enroll '{"request_id":"enroll-b","home_id":"b","repos":["owner/repo"]}' > /dev/null
ga=$(field "$(coord session '{"request_id":"session-a","home_id":"a"}')" generation)
gb=$(field "$(coord session '{"request_id":"session-b","home_id":"b"}')" generation)
coord manifest-set '{"request_id":"manifest","repo":"owner/repo","base":"main","checks":["Lint","Tests"]}' > /dev/null

candidate() {
  id=$1; home=$2; generation=$3; head=$4
  coord submit "$(printf '{"request_id":"submit-%s","intent_id":"%s","home_id":"%s","generation":%s,"repo":"owner/repo","base":"main","base_oid":"%s","branch":"branch/%s","task_id":"%s","goal":"test","resources":[{"type":"file","name":"src/%s.py"}]}' "$id" "$id" "$home" "$generation" "$base" "$id" "$id" "$id")" > /dev/null
  grant=$(coord claim "$(printf '{"request_id":"claim-%s","intent_id":"%s","home_id":"%s","generation":%s,"version":1}' "$id" "$id" "$home" "$generation")")
  claim_id=$(field "$grant" claim_id)
  fence=$(field "$grant" fence)
  coord attach-pr "$(printf '{"request_id":"pr-%s","intent_id":"%s","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s,"pr_url":"https://github.com/owner/repo/pull/%s"}' "$id" "$id" "$home" "$generation" "$claim_id" "$fence" "$( [ "$id" = a ] && echo 1 || echo 2 )")" > /dev/null
  coord publish-head "$(printf '{"request_id":"head-%s","intent_id":"%s","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s","expected_previous_oid":null}' "$id" "$id" "$home" "$generation" "$claim_id" "$fence" "$head")" > /dev/null
  coord queue-ready "$(printf '{"request_id":"ready-%s","intent_id":"%s","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s","priority":%s}' "$id" "$id" "$home" "$generation" "$claim_id" "$fence" "$head" "${5:-0}")" > /dev/null
}
candidate a a "$ga" "$head_a"
claim_a=$claim_id fence_a=$fence
candidate b b "$gb" "$head_b"
claim_b=$claim_id fence_b=$fence

first=$(coord queue-next '{"request_id":"next-a","repo":"owner/repo","base":"main"}')
[ "$(field "$first" intent_id)" = a ] || fail 'first ready candidate should occupy the slot'
gen1=$(field "$first" generation)
reject queue-next '{"request_id":"next-b-early","repo":"owner/repo","base":"main"}' 'second candidate must not start final validation while slot is occupied'
pass 'one serial final integration slot for two candidates'

coord queue-synced "$(printf '{"request_id":"sync-a","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true}' "$ga" "$claim_a" "$fence_a" "$gen1" "$head_a" "$base")" > /dev/null
stale=$(coord queue-validated "$(printf '{"request_id":"validate-a-stale","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","validation_passed":true,"validation_id":"sim-a"}' "$ga" "$claim_a" "$fence_a" "$gen1" "$head_a" "$base_new")")
[ "$(field "$stale" state)" = sync-needed ] || fail 'base advancement must invalidate validation'
pass 'base advance during validation releases stale preparation'

second=$(coord queue-next '{"request_id":"next-b","repo":"owner/repo","base":"main"}')
[ "$(field "$second" intent_id)" = b ] || fail 'second candidate should get released slot'
gen2=$(field "$second" generation)
coord queue-synced "$(printf '{"request_id":"sync-b","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true}' "$gb" "$claim_b" "$fence_b" "$gen2" "$head_b" "$base_new")" > /dev/null
coord publish-head "$(printf '{"request_id":"head-b-2","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s","expected_previous_oid":"%s"}' "$gb" "$claim_b" "$fence_b" "$head_b2" "$head_b")" > /dev/null
changed=$(coord queue-validated "$(printf '{"request_id":"validate-b-changed","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","validation_passed":true,"validation_id":"sim-b"}' "$gb" "$claim_b" "$fence_b" "$gen2" "$head_b2" "$base_new")")
[ "$(field "$changed" state)" = sync-needed ] || fail 'new published head must invalidate old preparation'
pass 'head change after check requires new preparation'

coord queue-ready "$(printf '{"request_id":"ready-a-again","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s"}' "$ga" "$claim_a" "$fence_a" "$head_a")" > /dev/null
third=$(coord queue-next '{"request_id":"next-a-again","repo":"owner/repo","base":"main"}')
gen3=$(field "$third" generation)
coord queue-synced "$(printf '{"request_id":"sync-a-again","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true}' "$ga" "$claim_a" "$fence_a" "$gen3" "$head_a" "$base_new")" > /dev/null
coord queue-validated "$(printf '{"request_id":"validate-a-again","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","validation_passed":true,"validation_id":"sim-a-2"}' "$ga" "$claim_a" "$fence_a" "$gen3" "$head_a" "$base_new")" > /dev/null
reject queue-checks "$(printf '{"request_id":"checks-missing","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","protection_available":false,"checks":[]}' "$ga" "$claim_a" "$fence_a" "$gen3" "$head_a" "$base_new")" 'empty check rollup must not pass unavailable protection'
reject queue-checks "$(printf '{"request_id":"checks-extra-missing","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","protection_available":true,"forge_required_checks":["Policy"],"checks":[{"name":"Lint","head_oid":"%s","conclusion":"success"},{"name":"Tests","head_oid":"%s","conclusion":"success"}]}' "$ga" "$claim_a" "$fence_a" "$gen3" "$head_a" "$base_new" "$head_a" "$head_a")" 'forge-required check outside manifest must also be present'
coord queue-checks "$(printf '{"request_id":"checks-green","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","protection_available":false,"checks":[{"name":"Lint","head_oid":"%s","conclusion":"success"},{"name":"Tests","head_oid":"%s","conclusion":"success"}]}' "$ga" "$claim_a" "$fence_a" "$gen3" "$head_a" "$base_new" "$head_a" "$head_a")" > /dev/null
reject queue-attempt "$(printf '{"request_id":"attempt-held","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true,"captain_hold_released":false,"away_merge_allowed":true,"merge_authorized":true,"wrapper_pid":'"$$"'}' "$ga" "$claim_a" "$fence_a" "$gen3" "$head_a" "$base_new")" 'captain hold must refuse attempt'
reject queue-attempt "$(printf '{"request_id":"attempt-away","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true,"captain_hold_released":true,"away_merge_allowed":false,"merge_authorized":true,"wrapper_pid":'"$$"'}' "$ga" "$claim_a" "$fence_a" "$gen3" "$head_a" "$base_new")" 'away restriction must refuse attempt'
pass 'repo manifest fails closed and holds refuse a merge decision'

attempt=$(coord queue-attempt "$(printf '{"request_id":"attempt-a","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true,"captain_hold_released":true,"away_merge_allowed":true,"merge_authorized":true,"wrapper_pid":'"$$"'}' "$ga" "$claim_a" "$fence_a" "$gen3" "$head_a" "$base_new")")
attempt_id=$(field "$attempt" attempt_event_id)
unknown=$(coord queue-result "$(printf '{"request_id":"result-forged-refusal","intent_id":"a","generation":%s,"outcome":"refused","wrapper_refused":true,"pr_merged":false,"observed_base_oid":"%s"}' "$gen3" "$base_new")")
[ "$(field "$unknown" state)" = outcome-unknown ] || fail 'caller-supplied refusal and base OID must not settle a merge attempt'
reject queue-next '{"request_id":"next-while-unknown","repo":"owner/repo","base":"main"}' 'unknown outcome must occupy slot'
pass 'caller-supplied refusal evidence leaves the slot outcome-unknown'
mkdir "$tmp/bin"
cat > "$tmp/bin/gh-axi" <<'EOF'
#!/usr/bin/env bash
[ "${FM_TEST_FAIL:-0}" = 1 ] && exit 1
case "$3" in
  */pulls/*)
    if [ -n "${FM_TEST_KILL:-}" ]; then
      kill "$FM_TEST_KILL"
      while kill -0 "$FM_TEST_KILL" 2> /dev/null; do sleep 0.05; done
    fi
    state=${FM_TEST_STATE:-closed} merged=$FM_TEST_MERGED
    if [ -n "${FM_TEST_FLIP:-}" ]; then
      [ -e "$FM_TEST_FLIP" ] && state=closed merged=true
      : > "$FM_TEST_FLIP"
    fi
    printf 'api_response:\n  body: "https://github.com/owner/repo/pull/%s|%s|%s|%s|main|%s"\n  truncated: false\n' "${3##*/}" "$state" "$merged" "$FM_TEST_HEAD" "$FM_TEST_MERGE_OID" ;;
  graphql) printf 'api_response:\n  body: %s\n  truncated: false\n' "${FM_TEST_PENDING:-false|none}" ;;
  */git/ref/heads/main) printf 'api_response:\n  body: %s\n  truncated: false\n' "$FM_TEST_BASE_OID" ;;
  */compare/"$FM_TEST_BASE_OID...$FM_TEST_HEAD") printf 'api_response:\n  body: %s\n  truncated: false\n' "$FM_TEST_COMPARE" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh-axi"
reconcile_payload=$(printf '{"request_id":"reconcile-landed","intent_id":"a","generation":%s,"pr_url":"https://github.com/owner/repo/pull/1","base":"main","head_oid":"%s"}' "$gen3" "$head_a")
if PATH="$tmp/bin:$PATH" FM_TEST_MERGED=false FM_TEST_HEAD="$head_a" FM_TEST_MERGE_OID="$merge_oid" FM_TEST_BASE_OID="$merge_oid" FM_TEST_COMPARE=identical coord queue-reconcile "$(printf '{"request_id":"reconcile-on-base","intent_id":"a","generation":%s,"pr_url":"https://github.com/owner/repo/pull/1","base":"main","head_oid":"%s"}' "$gen3" "$head_a")" > "$tmp/unexpected" 2> "$tmp/error"; then
  fail 'an unmerged PR whose head is already on base must not release unknown slot'
fi
reject queue-reconcile "$(printf '{"request_id":"reconcile-injected","intent_id":"a","generation":%s,"pr_url":"https://github.com/owner/repo/pull/1","base":"main","_forge_outcome":"refused"}' "$gen3")" 'caller must not inject a forge observation'
landed=$(PATH="$tmp/bin:$PATH" FM_TEST_MERGED=true FM_TEST_HEAD="$head_a" FM_TEST_MERGE_OID="$merge_oid" FM_TEST_BASE_OID="$merge_oid" coord queue-reconcile "$reconcile_payload")
[ "$(field "$landed" state)" = merged ] || fail 'live read should confirm actual landing'
[ "$(field "$landed" attempt_event_id)" = "$attempt_id" ] || fail 'landing must bind original attempt event'
[ "$(PATH="$tmp/bin:$PATH" FM_TEST_FAIL=1 coord queue-reconcile "$reconcile_payload")" = "$landed" ] || fail 'lost reconciliation reply must replay without a new forge read'
if PATH="$tmp/bin:$PATH" FM_TEST_MERGED=true FM_TEST_HEAD="$head_a" FM_TEST_MERGE_OID="$merge_oid" FM_TEST_BASE_OID="$merge_oid" coord queue-reconcile "$(printf '{"request_id":"reconcile-again","intent_id":"a","generation":%s,"pr_url":"https://github.com/owner/repo/pull/1","base":"main"}' "$gen3")" > "$tmp/unexpected" 2> "$tmp/error"; then
  fail 'a second terminal outcome must be refused'
fi
pass 'timeout and restart reconciliation preserve one terminal outcome'

head_b3=6666666666666666666666666666666666666666
coord queue-ready "$(printf '{"request_id":"ready-b-after-merge","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s"}' "$gb" "$claim_b" "$fence_b" "$head_b2")" > /dev/null
after_merge=$(coord queue-next '{"request_id":"next-b-after-merge","repo":"owner/repo","base":"main"}')
gen4=$(field "$after_merge" generation)
coord queue-synced "$(printf '{"request_id":"sync-b-again","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true}' "$gb" "$claim_b" "$fence_b" "$gen4" "$head_b2" "$merge_oid")" > /dev/null
coord queue-validated "$(printf '{"request_id":"validate-b-again","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","validation_passed":true,"validation_id":"sim-b-2"}' "$gb" "$claim_b" "$fence_b" "$gen4" "$head_b2" "$merge_oid")" > /dev/null
coord queue-checks "$(printf '{"request_id":"checks-b-green","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","protection_available":false,"checks":[{"name":"Lint","head_oid":"%s","conclusion":"success"},{"name":"Tests","head_oid":"%s","conclusion":"success"}]}' "$gb" "$claim_b" "$fence_b" "$gen4" "$head_b2" "$merge_oid" "$head_b2" "$head_b2")" > /dev/null
coord publish-head "$(printf '{"request_id":"head-b-3","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s","expected_previous_oid":"%s"}' "$gb" "$claim_b" "$fence_b" "$head_b3" "$head_b2")" > /dev/null
after_check_change=$(coord queue-attempt "$(printf '{"request_id":"attempt-b-stale","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true,"captain_hold_released":true,"away_merge_allowed":true,"merge_authorized":true,"wrapper_pid":'"$$"'}' "$gb" "$claim_b" "$fence_b" "$gen4" "$head_b3" "$merge_oid")")
[ "$(field "$after_check_change" state)" = sync-needed ] || fail 'a head change after green checks must refuse the attempt'
pass 'head change after remote green invalidates check evidence'

coord submit "$(printf '{"request_id":"submit-c","intent_id":"c","home_id":"a","generation":%s,"repo":"owner/repo","base":"main","base_oid":"%s","branch":"branch/c","task_id":"c","goal":"test","resources":[{"type":"file","name":"src/c.py"}]}' "$ga" "$base")" > /dev/null
coord submit "$(printf '{"request_id":"submit-d","intent_id":"d","home_id":"b","generation":%s,"repo":"owner/repo","base":"main","base_oid":"%s","branch":"branch/d","task_id":"d","goal":"test","resources":[{"type":"file","name":"src/d.py"}],"predecessors":["c"]}' "$gb" "$base")" > /dev/null
reject predecessors-set "$(printf '{"request_id":"cycle","intent_id":"c","home_id":"a","generation":%s,"predecessors":["d"]}' "$ga")" 'dependency cycle must be refused'
pass 'dependency cycle is refused'
for id in c d; do
  if [ "$id" = c ]; then home=a; generation=$ga; head=$head_a; number=3; priority=0; else home=b; generation=$gb; head=$head_b; number=4; priority=9; fi
  grant=$(coord claim "$(printf '{"request_id":"claim-%s","intent_id":"%s","home_id":"%s","generation":%s,"version":1}' "$id" "$id" "$home" "$generation")")
  claim_id=$(field "$grant" claim_id)
  fence=$(field "$grant" fence)
  coord attach-pr "$(printf '{"request_id":"pr-%s","intent_id":"%s","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s,"pr_url":"https://github.com/owner/repo/pull/%s"}' "$id" "$id" "$home" "$generation" "$claim_id" "$fence" "$number")" > /dev/null
  coord publish-head "$(printf '{"request_id":"head-%s","intent_id":"%s","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s","expected_previous_oid":null}' "$id" "$id" "$home" "$generation" "$claim_id" "$fence" "$head")" > /dev/null
  coord queue-ready "$(printf '{"request_id":"ready-%s","intent_id":"%s","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s","priority":%s}' "$id" "$id" "$home" "$generation" "$claim_id" "$fence" "$head" "$priority")" > /dev/null
done
dependency_pick=$(coord queue-next '{"request_id":"next-dependency","repo":"owner/repo","base":"main"}')
[ "$(field "$dependency_pick" intent_id)" = c ] || fail 'high-priority dependent must wait for predecessor landing'
pass 'dependent candidate cannot leapfrog its predecessor'

db=$tmp/aging.sqlite3
coord init > /dev/null
coord enroll '{"request_id":"enroll-a","home_id":"a","repos":["owner/repo"]}' > /dev/null
coord enroll '{"request_id":"enroll-b","home_id":"b","repos":["owner/repo"]}' > /dev/null
ga=$(field "$(coord session '{"request_id":"session-a","home_id":"a"}')" generation)
gb=$(field "$(coord session '{"request_id":"session-b","home_id":"b"}')" generation)
candidate low a "$ga" "$head_a" 0
sleep 2.2
candidate high b "$gb" "$head_b" 1
aged=$(FM_COORD_AGING_SECONDS=1 coord queue-next '{"request_id":"next-aged","repo":"owner/repo","base":"main"}')
[ "$(field "$aged" intent_id)" = low ] || fail 'aged lower-priority ready work must outrank fresh high-priority work'
pass 'ready-time aging prevents routine starvation'
coord queue-abort "$(printf '{"request_id":"abort-low","intent_id":"low","slot_generation":%s,"reason":"validation failed","repair_needed":true}' "$(field "$aged" generation)")" > /dev/null
after_failure=$(coord queue-next '{"request_id":"next-after-failure","repo":"owner/repo","base":"main"}')
[ "$(field "$after_failure" intent_id)" = high ] || fail 'failed preparation must yield to independent ready work'
pass 'one failing candidate yields its slot'

db=$tmp/unlanded.sqlite3
FM_COORD_AUTHORITY_TOKEN="$authority_token" coord init > /dev/null
coord enroll '{"request_id":"enroll-a","home_id":"a","repos":["owner/repo"]}' > /dev/null
coord enroll '{"request_id":"enroll-b","home_id":"b","repos":["owner/repo"]}' > /dev/null
ga=$(field "$(coord session '{"request_id":"session-a","home_id":"a"}')" generation)
gb=$(field "$(coord session '{"request_id":"session-b","home_id":"b"}')" generation)
coord manifest-set '{"request_id":"manifest","repo":"owner/repo","base":"main","checks":["Lint"]}' > /dev/null
candidate a a "$ga" "$head_a"
claim_a=$claim_id fence_a=$fence
candidate b b "$gb" "$head_b"
claim_b=$claim_id fence_b=$fence
for bad in https://github.com/owner/repo/pull/1/files https://gitlab.com/owner/repo/pull/1 http://github.com/owner/repo/pull/1 https://github.com/owner/repo/pull/0 https://github.com/owner/other/pull/1; do
  reject attach-pr "$(printf '{"request_id":"pr-bad","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"pr_url":"%s"}' "$ga" "$claim_a" "$fence_a" "$bad")" "attach-pr must refuse unevaluable PR URL $bad"
done
pass 'attach-pr accepts only an exact GitHub PR URL for the intent repository'

attempt() {
  id=$1; home=$2; generation=$3; claim=$4; fence=$5; head=$6
  pick=$(coord queue-next "$(printf '{"request_id":"next-%s-%s","repo":"owner/repo","base":"main"}' "$id" "$7")")
  [ "$(field "$pick" intent_id)" = "$id" ] || fail "$id should occupy the slot"
  slot=$(field "$pick" generation)
  common=$(printf '"intent_id":"%s","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s"' "$id" "$home" "$generation" "$claim" "$fence" "$slot" "$head" "$base")
  coord queue-synced "{\"request_id\":\"sync-$id-$7\",$common,\"head_contains_base\":true}" > /dev/null
  coord queue-validated "{\"request_id\":\"validate-$id-$7\",$common,\"validation_passed\":true,\"validation_id\":\"v-$id-$7\"}" > /dev/null
  coord queue-checks "{\"request_id\":\"checks-$id-$7\",$common,\"protection_available\":false,\"checks\":[{\"name\":\"Lint\",\"head_oid\":\"$head\",\"conclusion\":\"success\"}]}" > /dev/null
  coord queue-attempt "{\"request_id\":\"attempt-$id-$7\",$common,\"head_contains_base\":true,\"captain_hold_released\":true,\"away_merge_allowed\":true,\"merge_authorized\":true,\"wrapper_pid\":${8:-$$}}" > /dev/null
}
attempt_unknown() {
  attempt "$@"
  coord queue-result "$(printf '{"request_id":"unknown-%s-%s","intent_id":"%s","generation":%s,"outcome":"unknown"}' "$id" "$7" "$id" "$slot")" > /dev/null
}

still_unknown() {
  case "$(field "$(coord inspect '{}')" slots)" in *"'state': 'outcome-unknown'"*) ;; *) fail "$1" ;; esac
}
not_landed() {
  PATH="$tmp/bin:$PATH" FM_TEST_STATE=open FM_TEST_MERGED=false FM_TEST_HEAD="$head_a" FM_TEST_MERGE_OID=null FM_TEST_BASE_OID="$base" FM_TEST_COMPARE=ahead coord queue-reconcile "$(printf '{"request_id":"%s","intent_id":"a","generation":%s,"pr_url":"https://github.com/owner/repo/pull/1","base":"main","head_oid":"%s"}' "$1" "$slot" "$head_a")"
}
(sleep 600 & echo $! > "$tmp/wrapper-a"; wait) &
while [ ! -s "$tmp/wrapper-a" ]; do sleep 0.05; done
wrapper=$(cat "$tmp/wrapper-a")
attempt_unknown a a "$ga" "$claim_a" "$fence_a" "$head_a" 1 "$wrapper"
for pending in 'true|none' 'false|armed'; do
  if FM_TEST_PENDING="$pending" FM_COORD_QUIET_SECONDS=0 not_landed "reconcile-pending-${pending%%|*}${pending##*|}" > "$tmp/unexpected" 2> "$tmp/error"; then
    fail "pending merge ($pending) must not release the unknown slot"
  fi
  still_unknown "pending merge ($pending) must keep the slot outcome-unknown"
done
pass 'merge queue or armed auto-merge keeps the slot outcome-unknown'
if FM_COORD_QUIET_SECONDS=0 not_landed reconcile-live-wrapper > "$tmp/unexpected" 2> "$tmp/error"; then
  fail 'a live merge wrapper must not release the unknown slot'
fi
still_unknown 'a live merge wrapper must keep the slot outcome-unknown'
pass 'live merge wrapper keeps the slot outcome-unknown'
if FM_TEST_KILL="$wrapper" FM_COORD_QUIET_SECONDS=0 not_landed reconcile-wrapper-exits-mid-read > "$tmp/unexpected" 2> "$tmp/error"; then
  fail 'a wrapper alive when the forge reads start must not release the unknown slot'
fi
still_unknown 'a wrapper alive when the forge reads start must keep the slot outcome-unknown'
pass 'wrapper exiting during the forge reads keeps the slot outcome-unknown'
if not_landed reconcile-too-soon > "$tmp/unexpected" 2> "$tmp/error"; then
  fail 'the default quiet period must not release a fresh attempt'
fi
still_unknown 'the quiet period must keep the slot outcome-unknown'
if FM_TEST_FLIP="$tmp/flip" FM_COORD_QUIET_SECONDS=0 not_landed reconcile-flipped > "$tmp/unexpected" 2> "$tmp/error"; then
  fail 'a PR that merges during reconciliation must not be recorded as not merged'
fi
still_unknown 'a PR that merges during reconciliation must keep the slot outcome-unknown'
pass 'PR merging during reconciliation keeps the slot outcome-unknown'
unlanded=$(FM_COORD_QUIET_SECONDS=0 not_landed reconcile-timeout)
[ "$(field "$unlanded" state)" = refused ] || fail 'open unmerged PR off base must record a not-merged outcome'
pass 'exited wrapper after the quiet period releases a not-landed slot with one terminal outcome'

pick=$(coord queue-next '{"request_id":"next-b-identity","repo":"owner/repo","base":"main"}')
slot=$(field "$pick" generation)
common=$(printf '"intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s"' "$gb" "$claim_b" "$fence_b" "$slot" "$head_b" "$base")
coord queue-synced "{\"request_id\":\"sync-b-identity\",$common,\"head_contains_base\":true}" > /dev/null
coord queue-validated "{\"request_id\":\"validate-b-identity\",$common,\"validation_passed\":true,\"validation_id\":\"v-b-identity\"}" > /dev/null
coord queue-checks "{\"request_id\":\"checks-b-identity\",$common,\"protection_available\":false,\"checks\":[{\"name\":\"Lint\",\"head_oid\":\"$head_b\",\"conclusion\":\"success\"}]}" > /dev/null
gates='"head_contains_base":true,"captain_hold_released":true,"away_merge_allowed":true,"merge_authorized":true'
reject queue-attempt "{\"request_id\":\"attempt-b-no-identity\",$common,$gates}" 'an attempt without wrapper identity must be refused'
sleep 0 &
gone=$!
wait "$gone"
reject queue-attempt "{\"request_id\":\"attempt-b-dead-wrapper\",$common,$gates,\"wrapper_pid\":$gone}" 'an attempt whose wrapper start time cannot be proven must be refused'
coord queue-abort "$(printf '{"request_id":"abort-b-identity","intent_id":"b","slot_generation":%s,"reason":"identity test"}' "$slot")" > /dev/null
pass 'queue-attempt refuses missing or unverifiable wrapper identity'

coord queue-ready "$(printf '{"request_id":"ready-b-live","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s"}' "$gb" "$claim_b" "$fence_b" "$head_b")" > /dev/null
sleep 600 &
live_wrapper=$!
attempt_unknown b b "$gb" "$claim_b" "$fence_b" "$head_b" 1 "$live_wrapper"
if PATH="$tmp/bin:$PATH" FM_COORD_QUIET_SECONDS=0 FM_TEST_MERGED=false FM_TEST_HEAD="$head_b" FM_TEST_MERGE_OID=null FM_TEST_BASE_OID="$base" FM_TEST_COMPARE=diverged coord queue-reconcile "$(printf '{"request_id":"reconcile-live-b","intent_id":"b","generation":%s,"pr_url":"https://github.com/owner/repo/pull/2","base":"main","head_oid":"%s"}' "$slot" "$head_b")" > "$tmp/unexpected" 2> "$tmp/error"; then
  fail 'a stuck live wrapper must never auto-release as not merged'
fi
still_unknown 'a stuck live wrapper must keep the slot outcome-unknown'
FM_COORD_AUTHORITY_TOKEN="$authority_token" reject queue-operator-abort "$(printf '{"request_id":"operator-abort-participant","intent_id":"b","home_id":"b","generation":%s,"operator":"captain","reason":"wrapper lost"}' "$slot")" 'a participant must not impersonate the authority even with its local token'
FM_COORD_AUTHORITY_TOKEN="$authority_token" reject queue-operator-abort "$(printf '{"request_id":"operator-abort-forged-name","intent_id":"b","generation":%s,"operator":"captain","reason":"wrapper lost"}' "$slot")" 'operator identity must not come from caller text'
abort_payload=$(printf '{"request_id":"operator-abort-b","intent_id":"b","generation":%s,"reason":"wrapper lost"}' "$slot")
reject queue-operator-abort "$abort_payload" 'operator abort must require the enrolled authority credential'
aborted=$(FM_COORD_AUTHORITY_TOKEN="$authority_token" coord queue-operator-abort "$abort_payload")
[ "$(field "$aborted" state)" = repair-needed ] || fail 'operator abort must release the slot to repair-needed'
reject queue-operator-abort "$abort_payload" 'an unauthenticated replay must not return the authority receipt'
operator_identity=$(python3 -c 'import os,pwd; uid=os.geteuid(); print(f"@authority:{pwd.getpwuid(uid).pw_name}:{uid}")')
field "$(coord outbox '{"limit":1000}')" events | python3 -c 'import ast,sys; assert any(e["type"]=="slot-operator-aborted" and e["payload"]["operator"]==sys.argv[1] and e["payload"]["reason"]=="wrapper lost" for e in ast.literal_eval(sys.stdin.read()))' "$operator_identity" || fail 'operator abort must record its authenticated local account and reason'
kill "$live_wrapper"
wait "$live_wrapper" 2> /dev/null || true
pass 'a stuck wrapper never auto-releases; only the enrolled authority can abort'

coord queue-ready "$(printf '{"request_id":"ready-b-retry","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s"}' "$gb" "$claim_b" "$fence_b" "$head_b")" > /dev/null
sleep 600 &
wrapper=$!
attempt_unknown b b "$gb" "$claim_b" "$fence_b" "$head_b" 2 "$wrapper"
kill "$wrapper"
wait "$wrapper" 2> /dev/null || true
coord queue-ready "$(printf '{"request_id":"ready-a-2","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s"}' "$ga" "$claim_a" "$fence_a" "$head_a")" > /dev/null
refusal_payload=$(printf '{"request_id":"reconcile-lost-refusal","intent_id":"b","home_id":"b","generation":%s,"pr_url":"https://github.com/owner/repo/pull/2","base":"main","head_oid":"%s"}' "$slot" "$head_b")
lost=$(PATH="$tmp/bin:$PATH" FM_COORD_QUIET_SECONDS=0 FM_TEST_MERGED=false FM_TEST_HEAD="$head_b" FM_TEST_MERGE_OID=null FM_TEST_BASE_OID="$base" FM_TEST_COMPARE=diverged coord queue-reconcile "$refusal_payload")
[ "$(field "$lost" state)" = refused ] || fail 'closed unmerged PR off base must record a not-merged outcome'
[ "$(PATH="$tmp/bin:$PATH" FM_TEST_FAIL=1 coord queue-reconcile "$refusal_payload")" = "$lost" ] || fail 'reconciliation replay with home_id must return the stored receipt without a forge read'
pass 'lost refusal reply releases the slot and replays its receipt'

coord queue-ready "$(printf '{"request_id":"ready-b-2","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s"}' "$gb" "$claim_b" "$fence_b" "$head_b")" > /dev/null
epoch_b() { field "$(coord inspect '{}')" queue | python3 -c 'import ast,sys; print([q for q in ast.literal_eval(sys.stdin.read()) if q["intent_id"]=="b"][0]["ready_epoch"])'; }
before=$(epoch_b)
attempt a a "$ga" "$claim_a" "$fence_a" "$head_a" 2
direct=$(PATH="$tmp/bin:$PATH" FM_TEST_MERGED=true FM_TEST_HEAD="$head_a" FM_TEST_MERGE_OID="$merge_oid" FM_TEST_BASE_OID="$merge_oid" coord queue-reconcile "$(printf '{"request_id":"reconcile-a-merged","intent_id":"a","generation":%s,"pr_url":"https://github.com/owner/repo/pull/1","base":"main"}' "$slot")")
[ "$(field "$direct" state)" = merged ] || fail 'a forge-proven landing must settle directly from attempting'
[ "$(epoch_b)" = "$before" ] || fail 'a merge must not reset waiting ready items'
next_b=$(coord queue-next '{"request_id":"next-b-after-merge","repo":"owner/repo","base":"main"}')
[ "$(field "$next_b" intent_id)" = b ] || fail 'waiting ready item must keep its queue position after a merge'
pass 'forge-proven landing settles from attempting and keeps waiting ready items and their age'

python3 -c 'import sqlite3,sys; db=sqlite3.connect(sys.argv[1]); db.execute("UPDATE intents SET pr_url=? WHERE intent_id=?", ("https://github.com/owner/repo/pull/2/files","b")); db.commit()' "$db"
coord queue-abort "$(printf '{"request_id":"abort-b","intent_id":"b","slot_generation":%s,"reason":"legacy url"}' "$(field "$next_b" generation)")" > /dev/null
reject queue-ready "$(printf '{"request_id":"ready-b-legacy","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s"}' "$gb" "$claim_b" "$fence_b" "$head_b")" 'queue-ready must refuse a stored PR URL that reconciliation cannot evaluate'
pass 'queue-ready refuses an unevaluable PR URL'

queue_state() { coord inspect '{}' | python3 -c 'import json,sys; print(next(q["state"] for q in json.load(sys.stdin)["queue"] if q["intent_id"]==sys.argv[1]))' "$1"; }
slot_count() { coord inspect '{}' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["slots"]))'; }
db=$tmp/untokened.sqlite3
coord init > /dev/null
coord enroll '{"request_id":"enroll-untokened","home_id":"a","repos":["owner/repo"]}' > /dev/null
ga=$(field "$(coord session '{"request_id":"session-untokened","home_id":"a"}')" generation)
coord manifest-set '{"request_id":"manifest-untokened","repo":"owner/repo","base":"main","checks":["Lint"]}' > /dev/null
candidate a a "$ga" "$head_a"
sleep 600 &
wrapper=$!
attempt a a "$ga" "$claim_id" "$fence" "$head_a" untokened "$wrapper"
kill "$wrapper"
wait "$wrapper" 2> /dev/null || true
refused=$(coord queue-result "$(printf '{"request_id":"refused-untokened","intent_id":"a","generation":%s,"outcome":"refused"}' "$slot")")
[ "$(field "$refused" state)" = outcome-unknown ] || fail 'a wrapper refusal must leave the slot outcome-unknown'
reject queue-operator-abort "$(printf '{"request_id":"abort-untokened","intent_id":"a","generation":%s,"reason":"no token"}' "$slot")" 'operator abort must stay disabled without an enrolled token'
released=$(FM_COORD_QUIET_SECONDS=0 not_landed reconcile-untokened)
[ "$(field "$released" state)" = refused ] || fail 'an exited wrapper refusal must release the slot without an authority token'
[ "$(slot_count)" = 0 ] || fail 'a reconciled refusal must free the integration slot'
pass 'refusal on a database without a token reconciles to a released slot'

enrolled_events() { coord outbox '{"limit":1000}' | python3 -c 'import json,sys; print(sum(e["type"]=="authority-enrolled" for e in json.load(sys.stdin)["events"]))'; }
[ "$(enrolled_events)" = 0 ] || fail 'init without a token must not record an enrollment'
FM_COORD_AUTHORITY_TOKEN="$authority_token" coord init > /dev/null
[ "$(enrolled_events)" = 1 ] || fail 'first token on an initialized v3 database must enroll with one event'
FM_COORD_AUTHORITY_TOKEN="$authority_token" coord init > /dev/null
[ "$(enrolled_events)" = 1 ] || fail 'repeating enrollment with the same token must be idempotent'
FM_COORD_AUTHORITY_TOKEN=other-authority-credential-0123456789abcdef reject init '{}' 'init must never replace an enrolled token'
FM_COORD_AUTHORITY_TOKEN=other-authority-credential-0123456789abcdef reject queue-operator-abort '{"request_id":"abort-wrong-token","intent_id":"a","generation":1,"reason":"x"}' 'a refused replacement token must not authorize operator abort'
pass 'init enrolls an authority token once on an existing v3 database'

db=$tmp/revocation.sqlite3
coord init > /dev/null
coord enroll '{"request_id":"enroll-recovery","home_id":"a","repos":["owner/repo"]}' > /dev/null
ga=$(field "$(coord session '{"request_id":"session-recovery-1","home_id":"a"}')" generation)
reclaim() {
  id=$1; generation=$2; head=$3
  grant=$(coord claim "$(printf '{"request_id":"reclaim-%s-%s","intent_id":"%s","home_id":"a","generation":%s,"version":1}' "$id" "$generation" "$id" "$generation")")
  claim_id=$(field "$grant" claim_id)
  fence=$(field "$grant" fence)
  coord queue-ready "$(printf '{"request_id":"requeue-%s-%s","intent_id":"%s","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"head_oid":"%s"}' "$id" "$generation" "$id" "$generation" "$claim_id" "$fence" "$head")" > /dev/null
}

candidate released a "$ga" "$head_a"
released_claim=$claim_id released_fence=$fence
picked=$(coord queue-next '{"request_id":"next-released","repo":"owner/repo","base":"main"}')
coord release "$(printf '{"request_id":"release-queued","home_id":"a","generation":%s,"claim_id":"%s","fence":%s}' "$ga" "$released_claim" "$released_fence")" > /dev/null
[ "$(slot_count)" = 0 ] || fail 'release must free an unattempted integration slot'
[ "$(queue_state released)" = repair-needed ] || fail 'released queue item must be re-admittable'
coord outbox '{"limit":1000}' | python3 -c 'import json,sys; assert any(e["type"]=="slot-claim-revoked" and e["payload"]["intent_id"]=="released" for e in json.load(sys.stdin)["events"])' || fail 'pre-attempt slot release needs a durable event'
ga=$(field "$(coord session '{"request_id":"session-recovery-2","home_id":"a"}')" generation)
reclaim released "$ga" "$head_a"
picked=$(coord queue-next '{"request_id":"next-reclaimed","repo":"owner/repo","base":"main"}')
[ "$(field "$picked" intent_id)" = released ] || fail 'same intent must re-enter after a new generation claims it'
coord queue-abort "$(printf '{"request_id":"abort-reclaimed","intent_id":"released","slot_generation":%s,"reason":"test complete"}' "$(field "$picked" generation)")" > /dev/null
pass 'release frees the slot and a new session can re-admit the same intent'

candidate expired a "$ga" "$head_b"
coord renew "$(printf '{"request_id":"shorten-queued","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"ttl_seconds":1}' "$ga" "$claim_id" "$fence")" > /dev/null
sleep 1.2
[ "$(queue_state expired)" = repair-needed ] || fail 'expiry must remove ready work from the queue'
ga=$(field "$(coord session '{"request_id":"session-recovery-3","home_id":"a"}')" generation)
reclaim expired "$ga" "$head_b"
[ "$(queue_state expired)" = ready ] || fail 'expired item must re-enter ready under the new generation'
pass 'expiry removes stale ready work and supports re-admission'

picked=$(coord queue-next '{"request_id":"next-expired","repo":"owner/repo","base":"main"}')
coord queue-synced "$(printf '{"request_id":"sync-expired","intent_id":"expired","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true}' "$ga" "$claim_id" "$fence" "$(field "$picked" generation)" "$head_b" "$base")" > /dev/null
ga=$(field "$(coord session '{"request_id":"session-recovery-4","home_id":"a"}')" generation)
[ "$(slot_count)" = 0 ] || fail 'session revocation must free a validating slot before a forge attempt'
[ "$(queue_state expired)" = repair-needed ] || fail 'revoked validation must be re-admittable'
reclaim expired "$ga" "$head_b"
[ "$(queue_state expired)" = ready ] || fail 'revoked item must re-enter ready under the new generation'
pass 'session revocation frees the validating slot and supports re-admission'

coord manifest-set '{"request_id":"manifest-recovery","repo":"owner/repo","base":"main","checks":["Lint"]}' > /dev/null
attempt_unknown expired a "$ga" "$claim_id" "$fence" "$head_b" 3
coord release "$(printf '{"request_id":"release-unsettled","home_id":"a","generation":%s,"claim_id":"%s","fence":%s}' "$ga" "$claim_id" "$fence")" > /dev/null
[ "$(slot_count)" = 1 ] || fail 'claim release must not free an unknown forge outcome'
[ "$(queue_state expired)" = outcome-unknown ] || fail 'unknown outcome must survive claim revocation'
ga=$(field "$(coord session '{"request_id":"session-recovery-5","home_id":"a"}')" generation)
reject claim "$(printf '{"request_id":"reclaim-unsettled","intent_id":"expired","home_id":"a","generation":%s,"version":1}' "$ga")" 'unsettled intent must not be reclaimed'
pass 'claim revocation cannot release or re-admit an unsettled merge attempt'

db=$tmp/reboot.sqlite3
coord init > /dev/null
coord enroll '{"request_id":"enroll-reboot","home_id":"a","repos":["owner/repo"]}' > /dev/null
ga=$(field "$(coord session '{"request_id":"session-reboot-1","home_id":"a"}')" generation)
candidate reboot a "$ga" "$head_a"
picked=$(coord queue-next '{"request_id":"next-reboot","repo":"owner/repo","base":"main"}')
[ "$(field "$picked" intent_id)" = reboot ] || fail 'reboot candidate must hold the pre-attempt slot'
python3 - "$db" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE meta SET value='synthetic-previous-boot' WHERE key='boot_id'")
PY
[ "$(slot_count)" = 0 ] || fail 'coordinator reboot must free a pre-attempt slot after claim revocation'
[ "$(queue_state reboot)" = repair-needed ] || fail 'reboot-revoked work must be re-admittable'
coord outbox '{"limit":1000}' | python3 -c 'import json,sys; assert any(e["type"]=="slot-claim-revoked" and e["payload"]["intent_id"]=="reboot" and e["payload"]["reason"]=="coordinator reboot" for e in json.load(sys.stdin)["events"])' || fail 'reboot slot release needs a durable event'
ga=$(field "$(coord session '{"request_id":"session-reboot-2","home_id":"a"}')" generation)
reclaim reboot "$ga" "$head_a"
picked=$(coord queue-next '{"request_id":"next-reboot-reclaimed","repo":"owner/repo","base":"main"}')
[ "$(field "$picked" intent_id)" = reboot ] || fail 'reboot-revoked intent must re-enter under the new session generation'
pass 'coordinator reboot releases pre-attempt slot and permits fenced re-admission'

db=$tmp/upgrade-v2.sqlite3
coord enroll '{"request_id":"enroll-upgrade","home_id":"a","repos":["owner/repo"]}' > /dev/null
ga=$(field "$(coord session '{"request_id":"session-upgrade","home_id":"a"}')" generation)
coord manifest-set '{"request_id":"manifest-upgrade","repo":"owner/repo","base":"main","checks":["Lint"]}' > /dev/null
candidate upgraded a "$ga" "$head_a"
attempt upgraded a "$ga" "$claim_id" "$fence" "$head_a" 1
[ "$(queue_state upgraded)" = attempting ] || fail 'upgraded v2 database must support queue-attempt columns'
pass 'legacy v2 database upgrades and can record a merge attempt'

db=$tmp/upgrade-v2-with-columns.sqlite3
sqlite3 "$db" < "$ROOT/bin/fm-coord-migrations/001.sql"
sqlite3 "$db" < "$ROOT/bin/fm-coord-migrations/002.sql"
sqlite3 "$db" "ALTER TABLE queue_items ADD COLUMN attempt_epoch INTEGER; ALTER TABLE queue_items ADD COLUMN wrapper_pid INTEGER; ALTER TABLE queue_items ADD COLUMN wrapper_start TEXT; ALTER TABLE queue_items ADD COLUMN wrapper_boot TEXT; INSERT INTO meta(key,value) VALUES('boot_id','synthetic-previous-boot'); PRAGMA user_version=2;"
upgraded=$(coord init)
[ "$(field "$upgraded" schema_version)" = 4 ] || fail 'previously patched v2 database must upgrade without duplicate-column failure'
pass 'already patched v2 database upgrades without replaying its columns'

db=$tmp/remote-wrapper.sqlite3
coord init > /dev/null
coord enroll '{"request_id":"enroll-remote","home_id":"remote","repos":["owner/repo"],"host_id":"remote-test-host"}' > /dev/null
coord enroll '{"request_id":"enroll-other","home_id":"other","repos":["owner/repo"],"host_id":"other-test-host"}' > /dev/null
remote_generation=$(field "$(coord session '{"request_id":"session-remote","home_id":"remote"}')" generation)
other_generation=$(field "$(coord session '{"request_id":"session-other","home_id":"other"}')" generation)
coord manifest-set '{"request_id":"manifest-remote","repo":"owner/repo","base":"main","checks":["Lint"]}' > /dev/null
candidate a remote "$remote_generation" "$head_a"
remote_claim=$claim_id remote_fence=$fence
picked=$(coord queue-next '{"request_id":"next-remote","repo":"owner/repo","base":"main"}')
slot=$(field "$picked" generation)
remote_common=$(printf '"intent_id":"a","home_id":"remote","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s"' "$remote_generation" "$remote_claim" "$remote_fence" "$slot" "$head_a" "$base")
coord queue-synced "{\"request_id\":\"sync-remote\",$remote_common,\"head_contains_base\":true}" > /dev/null
coord queue-validated "{\"request_id\":\"validate-remote\",$remote_common,\"validation_passed\":true,\"validation_id\":\"v-remote\"}" > /dev/null
coord queue-checks "{\"request_id\":\"checks-remote\",$remote_common,\"protection_available\":false,\"checks\":[{\"name\":\"Lint\",\"head_oid\":\"$head_a\",\"conclusion\":\"success\"}]}" > /dev/null
remote_pid=2147483000
remote_start=remote-start-1
remote_attempt=$(coord queue-attempt "{\"request_id\":\"attempt-remote\",$remote_common,\"head_contains_base\":true,\"captain_hold_released\":true,\"away_merge_allowed\":true,\"merge_authorized\":true,\"wrapper_pid\":$remote_pid,\"wrapper_start\":\"$remote_start\"}")
remote_attempt_id=$(field "$remote_attempt" attempt_event_id)
[ "$(field "$remote_attempt" state)" = attempting ] || fail 'remote wrapper PID must not be checked on the coordinator host'
coord queue-result "$(printf '{"request_id":"remote-refused","intent_id":"a","generation":%s,"outcome":"refused"}' "$slot")" > /dev/null
if FM_COORD_QUIET_SECONDS=0 not_landed remote-unattested > "$tmp/unexpected" 2> "$tmp/error"; then
  fail 'a remote wrapper without attested exit must keep the slot outcome-unknown'
fi
still_unknown 'missing remote exit attestation must retain the slot'
reject queue-wrapper-exited "$(printf '{"request_id":"exit-other","intent_id":"a","home_id":"other","generation":%s,"slot_generation":%s,"attempt_event_id":"%s","wrapper_host_id":"remote-test-host","wrapper_pid":%s,"wrapper_start":"%s"}' "$other_generation" "$slot" "$remote_attempt_id" "$remote_pid" "$remote_start")" 'another participant must not attest a remote wrapper exit'
reject queue-wrapper-exited "$(printf '{"request_id":"exit-wrong-start","intent_id":"a","home_id":"remote","generation":%s,"slot_generation":%s,"attempt_event_id":"%s","wrapper_host_id":"remote-test-host","wrapper_pid":%s,"wrapper_start":"wrong-start"}' "$remote_generation" "$slot" "$remote_attempt_id" "$remote_pid")" 'remote exit attestation must match the exact wrapper start time'
remote_exit_payload=$(printf '{"request_id":"exit-remote","intent_id":"a","home_id":"remote","generation":%s,"slot_generation":%s,"attempt_event_id":"%s","wrapper_host_id":"remote-test-host","wrapper_pid":%s,"wrapper_start":"%s"}' "$remote_generation" "$slot" "$remote_attempt_id" "$remote_pid" "$remote_start")
remote_exit=$(coord queue-wrapper-exited "$remote_exit_payload")
[ "$(field "$remote_exit" state)" = outcome-unknown ] || fail 'attested exit must retain the slot until forge non-landing proof'
coord session '{"request_id":"session-remote-new","home_id":"remote"}' > /dev/null
reject queue-wrapper-exited "$remote_exit_payload" 'a stale participant session must not replay an authenticated exit receipt'
if not_landed remote-before-quiet > "$tmp/unexpected" 2> "$tmp/error"; then
  fail 'remote exit attestation must still observe the quiet period'
fi
released=$(FM_COORD_QUIET_SECONDS=0 not_landed remote-after-exit)
[ "$(field "$released" state)" = refused ] || fail 'attested remote exit plus quiet period and forge non-landing must release the slot'
[ "$(slot_count)" = 0 ] || fail 'reconciled remote refusal must free the integration slot'
pass 'remote wrapper exit attestation and forge proof release an unknown slot'
