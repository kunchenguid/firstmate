#!/usr/bin/env bash
# Public acceptance path for opt-in enforcement and coordinator recovery fencing.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(fm_test_tmproot fm-coord-enforce)
repo=$tmp/repo
db=$tmp/central/coord.sqlite3
mkdir -p "$repo/src" "$tmp/central"
git -C "$repo" init -q -b main
git -C "$repo" config user.name Fixture
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" remote add origin git@github.com:owner/repo.git
printf 'base\n' > "$repo/src/base.py"
git -C "$repo" add .
git -C "$repo" commit -qm base
coord() { "$ROOT/bin/fm-coord.sh" --db "$db" "$@"; }
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
outbox_ids() { coord outbox '{"limit":1000}' | python3 -c 'import json,sys; print(" ".join(e["event_id"] for e in json.load(sys.stdin)["events"]))'; }
adapter() { FM_HOME=$1 python3 "$ROOT/bin/fm-coord-adapter.py" "${@:2}"; }
home() {
  mkdir -p "$tmp/$1/config" "$tmp/$1/state"
  printf '{"mode":"shadow","home_id":"%s","repos":["owner/repo"],"enforce_repos":["owner/repo"],"db":"%s"}\n' "$1" "$db" > "$tmp/$1/config/coordination.json"
  printf 'Coordination resources: [{"type":"file","name":"src/%s.py"}]\n' "$2" > "$tmp/$1.brief"
}
home a a
home b b
if adapter "$tmp/a" dispatch a "$repo" "$tmp/a.brief" branch/a codex > "$tmp/out" 2> "$tmp/err"; then
  fail 'enforced dispatch must pause while the coordinator is offline'
fi
case "$(cat "$tmp/err")" in *'enforcement paused'*) ;; *) fail 'outage refusal must be visible' ;; esac
coord init > /dev/null
adapter "$tmp/a" readmit a "$repo" > /dev/null 2> "$tmp/err" || fail 'explicit re-admission must recover a pending dispatch'
adapter "$tmp/b" dispatch b "$repo" "$tmp/b.brief" branch/b codex > /dev/null || fail 'independent scope must be admitted'
printf 'change\n' > "$repo/src/b.py"
git -C "$repo" add .
git -C "$repo" commit -qm change
if adapter "$tmp/a" pre-push a "$repo" > "$tmp/out" 2> "$tmp/err"; then
  fail 'enforced push must refuse undeclared conflicting scope'
fi
case "$(cat "$tmp/err")" in *'enforcement paused'*) ;; *) fail 'scope refusal must be visible' ;; esac
python3 - "$tmp/b/state/fm-coord-adapter.json" "$db" "$ROOT/bin/fm-coord.sh" <<'PY' || fail 'holder release must succeed'
import json,subprocess,sys,uuid
state=json.load(open(sys.argv[1]))
task=state['tasks']['b']
p={'request_id':str(uuid.uuid4()),'home_id':'b','generation':state['requests']['session']['reply']['generation'],'claim_id':task['claim']['claim_id'],'fence':task['claim']['fence']}
subprocess.run([sys.argv[3],'--db',sys.argv[2],'release',json.dumps(p)],check=True,capture_output=True)
PY
adapter "$tmp/a" readmit a "$repo" > /dev/null 2> "$tmp/err" || fail "explicit amendment re-admission must pass after conflict clears: $(cat "$tmp/err")"
adapter "$tmp/a" pre-push a "$repo" > /dev/null || fail 'admitted current writer must publish exact head'
python3 - "$tmp/a/config/coordination.json" "$tmp/unreachable.sqlite3" <<'PY'
import json,sys
path=sys.argv[1]
config=json.load(open(path))
config['db']=sys.argv[2]
json.dump(config,open(path,'w'))
PY
if adapter "$tmp/a" pre-ci a batch-one > "$tmp/out" 2> "$tmp/err"; then
  fail 'enforced CI pulse must pause during a store outage'
fi
case "$(cat "$tmp/err")" in *'enforcement paused'*) ;; *) fail 'CI outage must be visible' ;; esac
python3 - "$tmp/a/config/coordination.json" "$db" <<'PY'
import json,sys
path=sys.argv[1]
config=json.load(open(path))
config['db']=sys.argv[2]
json.dump(config,open(path,'w'))
PY
adapter "$tmp/a" pre-ci a batch-one > /dev/null || fail 'one batch pulse must be authorized'
python3 - "$tmp/a/state/fm-coord-adapter.json" <<'PY'
import json,sys
path=sys.argv[1]
state=json.load(open(path))
state['requests']['a:pulse:batch-one'].pop('reply')
state['tasks']['a']['pending_ci']=True
json.dump(state,open(path,'w'))
PY
adapter "$tmp/a" pre-ci a batch-one > /dev/null 2> "$tmp/err" || fail "lost pulse reply must replay its stored central receipt: $(cat "$tmp/err")"
python3 - "$(adapter "$tmp/a" view)" "$(coord outbox '{"limit":1000}')" <<'PY' || fail 'lost pulse reply replay must clear the CI checkpoint without a second pulse'
import json,sys
assert not json.loads(sys.argv[1])['local_tasks']['a'].get('pending_ci')
assert sum(e['type']=='ci-pulse-authorized' for e in json.loads(sys.argv[2])['events'])==1
PY
if adapter "$tmp/a" pre-ci a batch-one > "$tmp/out" 2> "$tmp/err"; then
  fail 'second pulse for the same batch must be refused'
fi
case "$(cat "$tmp/err")" in *'already requested'*) ;; *) fail 'duplicate pulse must name batch' ;; esac
pass 'enforcement pauses offline dispatch and undeclared push until re-admission; one CI pulse per batch survives a lost reply'

if adapter "$tmp/a" pre-merge https://github.com/owner/repo/pull/1 "$(git -C "$repo" rev-parse HEAD)" > "$tmp/out" 2> "$tmp/err"; then
  fail 'merge without a live integration slot must be refused'
fi
pass 'final merge requires a current integration slot'

python3 - "$db.authority.lock" "$tmp/locked" <<'PY' &
import fcntl,sys,time
with open(sys.argv[1],'a+') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX)
    open(sys.argv[2],'w').close()
    time.sleep(2)
PY
holder=$!
i=0
while [ ! -f "$tmp/locked" ] && [ "$i" -lt 10 ]; do sleep .1; i=$((i+1)); done
if FM_COORD_LOCK_WAIT_SECONDS=0 coord view > "$tmp/out" 2> "$tmp/err"; then
  fail 'second coordinator process must be excluded by the host lock'
fi
wait "$holder"
case "$(cat "$tmp/err")" in *'host lock is held'*) ;; *) fail 'host lock refusal must be explicit' ;; esac
pass 'host lock excludes a second coordinator copy'

base_r=$(git -C "$repo" rev-parse HEAD)
coord enroll '{"request_id":"enroll-r","home_id":"r","repos":["owner/repo"]}' > /dev/null
coord migration-seed '{"request_id":"seed-r","repo":"owner/repo","namespace":"db","next_number":7}' > /dev/null
admit_r() {
  gen_r=$(field "$(coord session "{\"request_id\":\"session-r$1\",\"home_id\":\"r\"}")" generation)
  coord submit "$(printf '{"request_id":"submit-r%s","intent_id":"r%s","home_id":"r","generation":%s,"repo":"owner/repo","base":"main","base_oid":"%s","branch":"branch/r","task_id":"r","goal":"recovery","resources":[{"type":"file","name":"src/r.py"},{"type":"migration-sequence","name":"db"}]}' "$1" "$1" "$gen_r" "$base_r")" > /dev/null
  grant=$(coord claim "$(printf '{"request_id":"claim-r%s","intent_id":"r%s","home_id":"r","generation":%s,"version":1}' "$1" "$1" "$gen_r")")
  live_r=$(printf '"intent_id":"r%s","home_id":"r","generation":%s,"claim_id":"%s","fence":%s' "$1" "$gen_r" "$(field "$grant" claim_id)" "$(field "$grant" fence)")
  coord attach-pr "{\"request_id\":\"pr-r$1\",$live_r,\"pr_url\":\"https://github.com/owner/repo/pull/9\"}" > /dev/null
  coord publish-head "{\"request_id\":\"head-r$1\",$live_r,\"head_oid\":\"$base_r\",\"expected_previous_oid\":null}" > /dev/null
}
issue_r() {
  number_r=$(field "$(coord reserve "{\"request_id\":\"reserve-r$1\",$live_r,\"namespace\":\"db\"}")" number)
  coord queue-ready "{\"request_id\":\"ready-r$1\",$live_r,\"head_oid\":\"$base_r\"}" > /dev/null
  slot_r=$(field "$(coord queue-next "{\"request_id\":\"next-r$1\",\"repo\":\"owner/repo\",\"base\":\"main\"}")" generation)
  pulse_r=$(field "$(coord pulse-batch "{\"request_id\":\"pulse-r$1\",$live_r,\"head_oid\":\"$base_r\",\"batch_id\":\"batch-r\"}")" ok)
}
admit_r 1
python3 - "$db" "$tmp/older.sqlite3" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as source, sqlite3.connect(sys.argv[2]) as target:
    source.backup(target)
PY
coord enroll '{"request_id":"later-enrollment","home_id":"later","repos":["owner/repo"]}' > /dev/null
coord session '{"request_id":"later-session","home_id":"later"}' > /dev/null
issue_r 1
lost_number=$number_r
lost_slot=$slot_r
[ "$pulse_r" = True ] || fail 'batch-r must be authorized once before the restore'
mv "$tmp/older.sqlite3" "$db"
if coord session '{"request_id":"stale-session","home_id":"a"}' > "$tmp/out" 2> "$tmp/err"; then
  fail 'restored older database must not re-grant an old generation'
fi
case "$(cat "$tmp/err")" in *'older than authority marker'*) ;; *) fail 'restored DB refusal must name authority marker' ;; esac
pass 'restored older database cannot re-grant superseded generations'
coord recover '{"confirm":"FENCE_AND_REENROLL"}' > /dev/null || fail 'manual recovery must fence prior generations'
coord enroll '{"request_id":"later-reenrollment","home_id":"later","repos":["owner/repo"]}' > /dev/null
later_generation=$(coord session '{"request_id":"later-new-session","home_id":"later"}')
python3 - "$later_generation" <<'PY' || fail 'lost participant must not reuse a pre-restore generation'
import json,sys
assert json.loads(sys.argv[1])['generation'] > 1
PY
old_generation=$(python3 - "$tmp/a/state/fm-coord-adapter.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['requests']['session']['reply']['generation'])
PY
)
if coord submit "$(printf '{"request_id":"old-writer","intent_id":"old-writer","home_id":"a","generation":%s,"repo":"owner/repo","base":"main","base_oid":"0000000000000000000000000000000000000000","branch":"old","task_id":"old","goal":"stale","resources":[{"type":"file","name":"src/old.py"}]}' "$old_generation")" > "$tmp/out" 2> "$tmp/err"; then
  fail 'manual recovery must not accept an old participant generation'
fi
pass 'manual fenced recovery retains old-generation refusal'

admit_r 2
issue_r 2
[ "$number_r" -gt "$lost_number" ] || fail "restore after reserving migration $lost_number must never hand it out again"
[ "$pulse_r" = False ] || fail 'pre-restore batch must not authorize a second pulse'
[ "$slot_r" != "$lost_slot" ] || fail 'recovery must not reissue a pre-restore slot generation'
if coord queue-abort "{\"request_id\":\"abort-stale-slot\",\"intent_id\":\"r2\",\"slot_generation\":$lost_slot,\"reason\":\"stale\"}" > "$tmp/out" 2> "$tmp/err"; then
  fail 'pre-restore slot generation must be rejected'
fi
case "$(cat "$tmp/err")" in *'integration generation mismatch'*) ;; *) fail 'stale slot refusal must name the generation' ;; esac
pass 'manual recovery fences migration numbers, slot generations, and CI batches issued after the backup'

acked=$(coord outbox '{"limit":1}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["events"][0]["event_id"])')
coord ack "{\"request_id\":\"ack-before-crash\",\"event_id\":\"$acked\"}" > /dev/null
before=$(outbox_ids)
python3 - "$db.authority.json" <<'PY'
import json,sys
path=sys.argv[1]
marker=json.load(open(path))
marker['pending']=True
with open(path,'w') as out:
    json.dump(marker,out)
PY
if coord view > "$tmp/out" 2> "$tmp/err"; then
  fail 'interrupted authority transaction must not silently resume'
fi
case "$(cat "$tmp/err")" in *'interrupted transaction'*) ;; *) fail 'interrupted transaction refusal must be explicit' ;; esac
coord recover '{"confirm":"FENCE_AND_REENROLL"}' > /dev/null || fail 'manual recovery must clear an interrupted transaction marker'
pass 'interrupted transaction requires manual fenced recovery'
after=$(outbox_ids)
case "$after" in "$before "*) ;; *) fail 'unacknowledged events must keep their IDs and order across interrupted-transaction recovery' ;; esac
case " $after " in *" $acked "*) fail 'acknowledged event must not reappear after recovery' ;; esac
pass 'outbox replay after interrupted-transaction recovery keeps unacknowledged event IDs and order'

python3 - "$tmp/a/state/fm-coord-adapter.json" <<'PY'
import json,sys
path=sys.argv[1]
state=json.load(open(path))
task=state['tasks']['a']
live={'home_id':'a','generation':state['requests']['session']['reply']['generation'],'claim_id':task['claim']['claim_id'],'fence':task['claim']['fence']}
task['renew_key']='a:renew:lost'
state['requests']['a:renew:lost']={'op':'renew','payload':{**live,'request_id':'lost-renew'}}
state['requests']['a:pulse:batch-two']={'op':'pulse-batch','payload':{**live,'intent_id':task['intent_id'],'head_oid':task['published_head'],'batch_id':'batch-two','request_id':'lost-pulse'}}
json.dump(state,open(path,'w'))
PY
adapter "$tmp/a" readmit a "$repo" > /dev/null 2> "$tmp/err" || fail "readmit must recover a task fenced by manual recovery: $(cat "$tmp/err")"
adapter "$tmp/a" pre-push a "$repo" > /dev/null 2> "$tmp/err" || fail "readmitted writer must publish under its new generation: $(cat "$tmp/err")"
adapter "$tmp/a" heartbeat a > /dev/null 2> "$tmp/err" || fail "readmitted writer must renew despite a lost pre-readmit renew: $(cat "$tmp/err")"
adapter "$tmp/a" pre-ci a batch-two > /dev/null 2> "$tmp/err" || fail "readmitted writer must pulse a batch whose pre-readmit request was lost: $(cat "$tmp/err")"
pass 'readmit opens a new session and intent after recovery revokes the claim and drops stale renew and pulse requests'

if adapter "$tmp/b" pre-push missing "$repo" > /dev/null 2> "$tmp/err"; then
  fail 'enforced push without a local intent must refuse'
fi
if adapter "$tmp/b" pre-ci missing > /dev/null 2> "$tmp/err"; then
  fail 'CI pulse without a local intent must refuse in a home with enforcement'
fi
pass 'missing local intent cannot bypass enforcement'

mkdir -p "$tmp/shadow/config" "$tmp/shadow/state"
printf '{"mode":"shadow","home_id":"shadow","repos":["owner/repo"],"db":"%s"}\n' "$db" > "$tmp/shadow/config/coordination.json"
printf 'Coordination resources: []\n' > "$tmp/empty.brief"
adapter "$tmp/shadow" dispatch shadow "$repo" "$tmp/empty.brief" branch/shadow codex > /dev/null 2> "$tmp/err" || fail 'shadow dispatch with the scaffolded empty declaration must only warn'
case "$(cat "$tmp/err")" in *'nonempty JSON array'*) ;; *) fail 'shadow declaration problem must stay visible' ;; esac
adapter "$tmp/shadow" pre-push shadow "$repo" > /dev/null 2> "$tmp/err" || fail 'shadow push without a local intent must only warn'
printf '{"mode":"shadow","home_id":"shadow","repos":["other/repo"],"db":"%s"}\n' "$db" > "$tmp/shadow/config/coordination.json"
adapter "$tmp/shadow" dispatch shadow "$repo" "$tmp/b.brief" branch/shadow codex > /dev/null 2> "$tmp/err" || fail 'dispatch outside coordination enrollment must only warn'
if adapter "$tmp/b" dispatch b2 "$repo" "$tmp/empty.brief" branch/b2 codex > /dev/null 2> "$tmp/err"; then
  fail 'enforced dispatch must refuse an empty declaration'
fi
pass 'shadow repositories warn and continue; enforced repositories refuse'
