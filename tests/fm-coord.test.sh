#!/usr/bin/env bash
# Public-interface behavior for the advisory coordination SQLite store.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(fm_test_tmproot fm-coord)
db=$tmp/coord.sqlite3
coord() { "$ROOT/bin/fm-coord.sh" --db "$db" "$@"; }
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
assert_error() {
  if coord "$1" "$2" > "$tmp/unexpected.out" 2> "$tmp/error"; then
    fail "$3"
  fi
}
submit() {
  coord submit "$(printf '{"request_id":"submit-%s","intent_id":"%s","home_id":"%s","generation":%s,"repo":"owner/repo","base":"main","base_oid":"0000000000000000000000000000000000000000","branch":"branch/%s","task_id":"%s","goal":"test","resources":%s}' "$1" "$1" "$2" "$3" "$1" "$1" "$4")"
}
claim() {
  coord claim "$(printf '{"request_id":"claim-%s","intent_id":"%s","home_id":"%s","generation":%s,"version":1}' "$1" "$1" "$2" "$3")"
}
release() {
  coord release "$(printf '{"request_id":"release-%s","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s}' "$1" "$2" "$3" "$4" "$5")"
}

mkdir "$tmp/no-sqlite"
if PATH="$tmp/no-sqlite" /bin/bash "$ROOT/bin/fm-coord.sh" --db "$db" init > "$tmp/no-sqlite.out" 2> "$tmp/no-sqlite.err"; then
  fail 'missing sqlite3 must fail'
fi
case "$(cat "$tmp/no-sqlite.err")" in *'sqlite3 command is required'*) ;; *) fail 'missing sqlite3 error must be clear' ;; esac
pass 'missing sqlite3 dependency is explicit'

coord init > /dev/null
coord enroll '{"request_id":"enroll-a","home_id":"a","repos":["owner/repo"]}' > /dev/null
coord enroll '{"request_id":"enroll-b","home_id":"b","repos":["owner/repo"]}' > /dev/null
ga=$(field "$(coord session '{"request_id":"session-a","home_id":"a"}')" generation)
gb=$(field "$(coord session '{"request_id":"session-b","home_id":"b"}')" generation)
coord area-set '{"request_id":"area-api","repo":"owner/repo","name":"api","paths":["src/api"],"aliases":["server-api","service-api"]}' > /dev/null
coord migration-seed '{"request_id":"seed-migrations","repo":"owner/repo","namespace":"db","next_number":227}' > /dev/null

submit a1 a "$ga" '[{"type":"file","name":"src/shared.py"},{"type":"issue","name":"owner/repo#1"}]' > /dev/null
submit b1 b "$gb" '[{"type":"file","name":"src/shared.py"},{"type":"issue","name":"owner/repo#1"}]' > /dev/null
claim a1 a "$ga" > "$tmp/a-claim" &
pa=$!
claim b1 b "$gb" > "$tmp/b-claim" &
pb=$!
wait "$pa"
wait "$pb"
grants=$(python3 -c 'import json,sys; print(sum(json.load(open(p))["ok"] for p in sys.argv[1:]))' "$tmp/a-claim" "$tmp/b-claim")
[ "$grants" -eq 1 ] || fail 'concurrent same-resource claims must yield exactly one grant'
if [ "$(field "$(cat "$tmp/a-claim")" ok)" = True ]; then
  winner=a; loser=b; gw=$ga; winner_result=$(cat "$tmp/a-claim"); loser_result=$(cat "$tmp/b-claim")
else
  winner=b; loser=a; gw=$gb; winner_result=$(cat "$tmp/b-claim"); loser_result=$(cat "$tmp/a-claim")
fi
python3 - "$loser_result" "$winner" <<'PY' || fail 'denial must name durable owner'
import json, sys
result = json.loads(sys.argv[1])
assert result['reason'] == 'scope-conflict'
assert any(c['home_id'] == sys.argv[2] for c in result['conflicts'])
PY
[ "$(claim "${winner}1" "$winner" "$gw")" = "$winner_result" ] || fail 'lost grant reply must replay identical receipt'
winner_claim=$(field "$winner_result" claim_id)
winner_fence=$(field "$winner_result" fence)
pass 'atomic same-resource admission and idempotent grant replay'

pr_attached=$(coord attach-pr "$(printf '{"request_id":"attach-pr","intent_id":"%s1","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s,"pr_url":"https://github.com/owner/repo/pull/123"}' "$winner" "$winner" "$gw" "$winner_claim" "$winner_fence")")
[ "$(field "$pr_attached" pr_url)" = 'https://github.com/owner/repo/pull/123' ] || fail 'PR URL must be retained on the intent'
assert_error attach-pr "$(printf '{"request_id":"attach-other-pr","intent_id":"%s1","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s,"pr_url":"https://github.com/owner/repo/pull/124"}' "$winner" "$winner" "$gw" "$winner_claim" "$winner_fence")" 'PR URL replacement must fail'
pass 'guarded immutable PR identity'

loser_generation=$( [ "$loser" = a ] && printf '%s' "$ga" || printf '%s' "$gb" )
coord submit "$(printf '{"request_id":"submit-second-writer","intent_id":"second-writer","home_id":"%s","generation":%s,"repo":"owner/repo","base":"main","base_oid":"0000000000000000000000000000000000000000","branch":"branch/%s1","task_id":"second-writer","goal":"test","resources":[{"type":"file","name":"src/other-writer.py"}]}' "$loser" "$loser_generation" "$winner")" > /dev/null
writer_denial=$(claim second-writer "$loser" "$loser_generation")
[ "$(field "$writer_denial" ok)" = False ] || fail 'one branch must have one writer even with independent files'
pass 'single branch writer ownership'

submit partial-denial "$loser" "$loser_generation" '[{"type":"file","name":"src/shared.py"},{"type":"file","name":"src/free.py"}]' > /dev/null
partial_result=$(claim partial-denial "$loser" "$loser_generation")
[ "$(field "$partial_result" ok)" = False ] || fail 'one conflicting resource must deny the whole scope'
submit free-only "$loser" "$loser_generation" '[{"type":"file","name":"src/free.py"}]' > /dev/null
free_result=$(claim free-only "$loser" "$loser_generation")
[ "$(field "$free_result" ok)" = True ] || fail 'denied scope must not retain a partial claim'
pass 'all-or-none scope admission'

submit independent "$loser" "$( [ "$loser" = a ] && printf '%s' "$ga" || printf '%s' "$gb" )" '[{"type":"file","name":"src/unrelated.py"}]' > /dev/null
independent_result=$(claim independent "$loser" "$( [ "$loser" = a ] && printf '%s' "$ga" || printf '%s' "$gb" )")
[ "$(field "$independent_result" ok)" = True ] || fail 'independent files should both admit'
pass 'independent file admission'

for scenario in directory rename area; do
  case "$scenario" in
    directory) resource='[{"type":"directory","name":"src"}]' ;;
    rename) resource='[{"type":"rename","from":"src/shared.py","to":"dst/shared.py"}]' ;;
    area) resource='[{"type":"area","name":"server-api"}]' ;;
  esac
  submit "$scenario" "$loser" "$( [ "$loser" = a ] && printf '%s' "$ga" || printf '%s' "$gb" )" "$resource" > /dev/null
done
directory_result=$(claim directory "$loser" "$( [ "$loser" = a ] && printf '%s' "$ga" || printf '%s' "$gb" )")
[ "$(field "$directory_result" ok)" = False ] || fail 'parent directory must overlap child file'
rename_result=$(claim rename "$loser" "$( [ "$loser" = a ] && printf '%s' "$ga" || printf '%s' "$gb" )")
[ "$(field "$rename_result" ok)" = False ] || fail 'rename old path must overlap file'

submit area-other "$winner" "$gw" '[{"type":"area","name":"service-api"}]' > /dev/null
area_grant=$(claim area-other "$winner" "$gw")
[ "$(field "$area_grant" ok)" = True ] || fail 'first area alias should grant'
area_denial=$(claim area "$loser" "$( [ "$loser" = a ] && printf '%s' "$ga" || printf '%s' "$gb" )")
[ "$(field "$area_denial" ok)" = False ] || fail 'second alias of one area must conflict'
pass 'directory, rename, and area alias overlap'

outbox_before=$(coord outbox '{"limit":1000}')
event_id=$(field "$winner_result" event_id)
coord ack "$(printf '{"request_id":"ack-grant","event_id":"%s"}' "$event_id")" > /dev/null
coord ack "$(printf '{"request_id":"ack-grant","event_id":"%s"}' "$event_id")" > /dev/null
outbox_after=$(coord outbox '{"limit":1000}')
python3 - "$outbox_before" "$outbox_after" "$event_id" <<'PY' || fail 'outbox acknowledgment must preserve event identity and suppress delivered event'
import json, sys
before, after, event = json.loads(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3]
assert any(x['event_id'] == event for x in before['events'])
assert not any(x['event_id'] == event for x in after['events'])
PY
pass 'transactional outbox acknowledgment'

release winner "$winner" "$gw" "$winner_claim" "$winner_fence" > /dev/null
assert_error check "$(printf '{"home_id":"%s","generation":%s,"claim_id":"%s","fence":%s}' "$winner" "$gw" "$winner_claim" "$winner_fence")" 'released grant must fail live check'

submit migration "$winner" "$gw" '[{"type":"migration-sequence","name":"db"}]' > /dev/null
migration_grant=$(claim migration "$winner" "$gw")
migration_claim=$(field "$migration_grant" claim_id)
migration_fence=$(field "$migration_grant" fence)
reservation=$(coord reserve "$(printf '{"request_id":"reserve-1","intent_id":"migration","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s,"namespace":"db"}' "$winner" "$gw" "$migration_claim" "$migration_fence")")
[ "$(field "$reservation" number)" -eq 227 ] || fail 'seeded migration number must be reserved'
[ "$(coord reserve "$(printf '{"request_id":"reserve-1","intent_id":"migration","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s,"namespace":"db"}' "$winner" "$gw" "$migration_claim" "$migration_fence")")" = "$reservation" ] || fail 'reservation replay must retain allocation ID'
pass 'persistent migration allocation identity and replay'

new_generation=$(field "$(coord session "$(printf '{"request_id":"session-new","home_id":"%s"}' "$winner")")" generation)
assert_error renew "$(printf '{"request_id":"old-renew","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s}' "$winner" "$gw" "$migration_claim" "$migration_fence")" 'old generation must not renew after session replacement'
assert_error check "$(printf '{"home_id":"%s","generation":%s,"claim_id":"%s","fence":%s}' "$winner" "$gw" "$migration_claim" "$migration_fence")" 'old generation must fail live check'
submit migration-next "$winner" "$new_generation" '[{"type":"migration-sequence","name":"db"}]' > /dev/null
next_grant=$(claim migration-next "$winner" "$new_generation")
next_claim=$(field "$next_grant" claim_id)
next_fence=$(field "$next_grant" fence)
next_reservation=$(coord reserve "$(printf '{"request_id":"reserve-2","intent_id":"migration-next","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s,"namespace":"db"}' "$winner" "$new_generation" "$next_claim" "$next_fence")")
[ "$(field "$next_reservation" number)" -eq 228 ] || fail 'migration number must not recycle after old lease revocation'
pass 'expired generation fencing and nonrecycled reservations'

submit short-lease "$winner" "$new_generation" '[{"type":"file","name":"src/expiring.py"}]' > /dev/null
short_result=$(coord claim "$(printf '{"request_id":"claim-short-lease","intent_id":"short-lease","home_id":"%s","generation":%s,"version":1,"ttl_seconds":1}' "$winner" "$new_generation")")
short_claim=$(field "$short_result" claim_id)
short_fence=$(field "$short_result" fence)
sleep 1.2
assert_error check "$(printf '{"home_id":"%s","generation":%s,"claim_id":"%s","fence":%s}' "$winner" "$new_generation" "$short_claim" "$short_fence")" 'expired lease must reject the old worker'
submit fresh-lease "$loser" "$( [ "$loser" = a ] && printf '%s' "$ga" || printf '%s' "$gb" )" '[{"type":"file","name":"src/expiring.py"}]' > /dev/null
fresh_result=$(claim fresh-lease "$loser" "$( [ "$loser" = a ] && printf '%s' "$ga" || printf '%s' "$gb" )")
[ "$(field "$fresh_result" ok)" = True ] || fail 'expired resource should admit a fresh claimant'
assert_error release "$(printf '{"request_id":"stale-release","home_id":"%s","generation":%s,"claim_id":"%s","fence":%s}' "$winner" "$new_generation" "$short_claim" "$short_fence")" 'old claim cannot release the successor'
pass 'lease expiry and successor fencing'
