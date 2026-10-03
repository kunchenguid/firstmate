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

coord init > /dev/null
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
  eval "claim_$id=\$claim_id fence_$id=\$fence"
}
candidate a a "$ga" "$head_a"
candidate b b "$gb" "$head_b"

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
reject queue-attempt "$(printf '{"request_id":"attempt-held","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true,"captain_hold_released":false,"away_merge_allowed":true,"merge_authorized":true}' "$ga" "$claim_a" "$fence_a" "$gen3" "$head_a" "$base_new")" 'captain hold must refuse attempt'
reject queue-attempt "$(printf '{"request_id":"attempt-away","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true,"captain_hold_released":true,"away_merge_allowed":false,"merge_authorized":true}' "$ga" "$claim_a" "$fence_a" "$gen3" "$head_a" "$base_new")" 'away restriction must refuse attempt'
pass 'repo manifest fails closed and holds refuse a merge decision'

attempt=$(coord queue-attempt "$(printf '{"request_id":"attempt-a","intent_id":"a","home_id":"a","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true,"captain_hold_released":true,"away_merge_allowed":true,"merge_authorized":true}' "$ga" "$claim_a" "$fence_a" "$gen3" "$head_a" "$base_new")")
attempt_id=$(field "$attempt" attempt_event_id)
unknown=$(coord queue-result "$(printf '{"request_id":"result-unknown","intent_id":"a","generation":%s,"outcome":"unknown"}' "$gen3")")
[ "$(field "$unknown" state)" = outcome-unknown ] || fail 'timeout must retain unknown outcome'
reject queue-next '{"request_id":"next-while-unknown","repo":"owner/repo","base":"main"}' 'unknown outcome must occupy slot'
mkdir "$tmp/bin"
cat > "$tmp/bin/gh-axi" <<'EOF'
#!/usr/bin/env bash
[ "${FM_TEST_FAIL:-0}" = 1 ] && exit 1
case "$3" in
  */pulls/1) printf 'api_response:\n  body: "https://github.com/owner/repo/pull/1|closed|%s|%s|main|%s"\n  truncated: false\n' "$FM_TEST_MERGED" "$FM_TEST_HEAD" "$FM_TEST_MERGE_OID" ;;
  */git/ref/heads/main) printf 'api_response:\n  body: %s\n  truncated: false\n' "$FM_TEST_BASE_OID" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh-axi"
reconcile_payload=$(printf '{"request_id":"reconcile-landed","intent_id":"a","generation":%s,"outcome":"merged","pr_url":"https://github.com/owner/repo/pull/1","base":"main"}' "$gen3")
if PATH="$tmp/bin:$PATH" FM_TEST_MERGED=false FM_TEST_HEAD="$head_a" FM_TEST_MERGE_OID="$merge_oid" FM_TEST_BASE_OID="$merge_oid" coord queue-reconcile "$reconcile_payload" > "$tmp/unexpected" 2> "$tmp/error"; then
  fail 'unproved landing must not release unknown slot'
fi
landed=$(PATH="$tmp/bin:$PATH" FM_TEST_MERGED=true FM_TEST_HEAD="$head_a" FM_TEST_MERGE_OID="$merge_oid" FM_TEST_BASE_OID="$merge_oid" coord queue-reconcile "$reconcile_payload")
[ "$(field "$landed" state)" = merged ] || fail 'live read should confirm actual landing'
[ "$(field "$landed" attempt_event_id)" = "$attempt_id" ] || fail 'landing must bind original attempt event'
[ "$(PATH="$tmp/bin:$PATH" FM_TEST_FAIL=1 coord queue-reconcile "$reconcile_payload")" = "$landed" ] || fail 'lost reconciliation reply must replay without a new forge read'
if PATH="$tmp/bin:$PATH" FM_TEST_MERGED=true FM_TEST_HEAD="$head_a" FM_TEST_MERGE_OID="$merge_oid" FM_TEST_BASE_OID="$merge_oid" coord queue-reconcile "$(printf '{"request_id":"reconcile-again","intent_id":"a","generation":%s,"outcome":"merged","pr_url":"https://github.com/owner/repo/pull/1","base":"main"}' "$gen3")" > "$tmp/unexpected" 2> "$tmp/error"; then
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
after_check_change=$(coord queue-attempt "$(printf '{"request_id":"attempt-b-stale","intent_id":"b","home_id":"b","generation":%s,"claim_id":"%s","fence":%s,"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true,"captain_hold_released":true,"away_merge_allowed":true,"merge_authorized":true}' "$gb" "$claim_b" "$fence_b" "$gen4" "$head_b3" "$merge_oid")")
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
