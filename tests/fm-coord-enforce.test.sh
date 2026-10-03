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
git -C "$repo" update-ref refs/remotes/origin/main HEAD
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
if adapter "$tmp/a" dispatch a "$repo" "$repo" "$tmp/a.brief" branch/a codex > "$tmp/out" 2> "$tmp/err"; then
  fail 'enforced dispatch must pause while the coordinator is offline'
fi
case "$(cat "$tmp/err")" in *'enforcement paused'*) ;; *) fail 'outage refusal must be visible' ;; esac
coord init > /dev/null
adapter "$tmp/a" readmit a "$repo" > /dev/null 2> "$tmp/err" || fail 'explicit re-admission must recover a pending dispatch'
adapter "$tmp/b" dispatch b "$repo" "$repo" "$tmp/b.brief" branch/b codex > /dev/null || fail 'independent scope must be admitted'
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

if adapter "$tmp/a" pre-merge undispatched https://github.com/owner/repo/pull/1 "$(git -C "$repo" rev-parse HEAD)" > "$tmp/out" 2> "$tmp/err"; then
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
coord outbox '{"limit":1000}' > "$tmp/newer-outbox.json"
lost_seq=$(python3 -c 'import json,sys; print(max(e["seq"] for e in json.load(open(sys.argv[1]))["events"]))' "$tmp/newer-outbox.json")
mv "$tmp/older.sqlite3" "$db"
if coord session '{"request_id":"stale-session","home_id":"a"}' > "$tmp/out" 2> "$tmp/err"; then
  fail 'restored older database must not re-grant an old generation'
fi
case "$(cat "$tmp/err")" in *'older than authority marker'*) ;; *) fail 'restored DB refusal must name authority marker' ;; esac
pass 'restored older database cannot re-grant superseded generations'
coord recover '{"confirm":"FENCE_AND_REENROLL"}' > /dev/null || fail 'manual recovery must fence prior generations'
python3 - "$tmp/newer-outbox.json" "$(coord outbox '{"limit":1000}')" "$lost_seq" <<'PY' || fail 'fenced recovery must not reissue an event sequence issued before the restore'
import json,sys
newer={e["event_id"] for e in json.load(open(sys.argv[1]))["events"]}
events=json.loads(sys.argv[2])["events"]
lost=int(sys.argv[3])
assert all(e["event_id"] in newer for e in events if e["seq"]<=lost)
recovered=[e for e in events if e["type"] in {"authority-manually-recovered","lease-revoked"} and e["event_id"] not in newer]
assert recovered and all(e["seq"]>lost for e in recovered)
PY
pass 'fenced recovery advances event sequences past the recorded high-water mark'
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
python3 - "$tmp/a/state/fm-coord-adapter.json" "$(adapter "$tmp/a" view)" <<'PY' || fail 'readmit must drop unanswered requests that carry the revoked claim'
import json,sys
state=json.load(open(sys.argv[1]))
assert 'a:renew:lost' not in state['requests'] and state['requests']['a:pulse:batch-two']['payload']['request_id']!='lost-pulse'
assert not json.loads(sys.argv[2])['local_pending']
PY
pass 'readmit opens a new session and intent after recovery revokes the claim and drops stale renew and pulse requests'

coord manifest-set '{"request_id":"manifest-land","repo":"owner/repo","base":"main","checks":["ci"]}' > /dev/null
head_a=$(git -C "$repo" rev-parse HEAD)
pr=https://github.com/owner/repo/pull/7
# The forge base has advanced past anything the task worktree has fetched.
git clone -q "$repo" "$tmp/forge"
git -C "$tmp/forge" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m advanced
forge_base=$(git -C "$tmp/forge" rev-parse HEAD)
merge_oid=$(printf 'd%.0s' $(seq 40))
landed_base=$(printf 'c%.0s' $(seq 40))
mkdir -p "$tmp/fakebin"
cat > "$tmp/fakebin/gh" <<SH
#!/usr/bin/env bash
[ "\$*" = "api repos/owner/repo/compare/$forge_base...$head_a --jq .status" ] || exit 1
case \$(cat "$tmp/compare-status") in
  HTTP*) cat "$tmp/compare-status" >&2; exit 1 ;;
esac
cat "$tmp/compare-status"
SH
cat > "$tmp/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
case "\$3" in
  repos/owner/repo/pulls/7) body=\$(cat "$tmp/pr-state") ;;
  repos/owner/repo/git/ref/heads/main) body=$landed_base ;;
  graphql) body='false|none' ;;
  repos/owner/repo/compare/*) body=ahead ;;
  *) exit 1 ;;
esac
printf 'api_response:\n  body: "%s"\n  truncated: false\n' "\$body"
SH
chmod +x "$tmp/fakebin/gh" "$tmp/fakebin/gh-axi"
printf '%s|open|false|%s|main|\n' "$pr" "$head_a" > "$tmp/pr-state"
view_a=$(printf '{"baseRefOid":"%s","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}' "$forge_base")
# Each land runs under its own short-lived wrapper shell, as fm-pr-merge.sh is the adapter's parent in production.
land() { PATH="$tmp/fakebin:$PATH" FM_PR_GITHUB_VIEW=$view_a FM_PR_GITHUB_REQUIRED='[{"context":"ci","app_id":null}]' FM_HOME="$tmp/a" bash -c 'python3 "$0" pre-merge a "$1" "$2"; exit $?' "$ROOT/bin/fm-coord-adapter.py" "$pr" "$head_a"; }
result() { PATH="$tmp/fakebin:$PATH" FM_PR_GITHUB_VIEW=$view_a adapter "$tmp/a" merge-result a "$pr" "$1"; }
slot_state() { python3 -c 'import json,sys; c=json.loads(sys.argv[1]); i=json.load(open(sys.argv[2]))["tasks"]["a"]["intent_id"]; print(" ".join([q["state"] for q in c["queue"] if q["intent_id"]==i]+["slot:"+s["state"] for s in c["slots"]]))' "$(coord inspect)" "$tmp/a/state/fm-coord-adapter.json"; }
for forge_error in 'HTTP 403: API rate limit exceeded' 'HTTP 502: Bad Gateway'; do
  printf '%s\n' "$forge_error" > "$tmp/compare-status"
  if land > /dev/null 2> "$tmp/err"; then
    fail "an unavailable forge comparison ($forge_error) must not let the merge through"
  fi
  grep -q 'queue synchronization paused: forge comparison .* unavailable' "$tmp/err" || fail "an unavailable forge comparison must pause with a visible reason: $(cat "$tmp/err")"
  if grep -q 'must contain current base' "$tmp/err"; then
    fail 'an unavailable forge comparison must not be reported as a head lacking the base'
  fi
  [ "$(slot_state)" = 'syncing slot:syncing' ] || fail "an unavailable forge comparison must keep the slot syncing for retry: $(slot_state)"
done
pass 'an unavailable forge comparison pauses queue synchronization instead of proving the head lacks the base'
printf 'diverged\n' > "$tmp/compare-status"
if land > /dev/null 2> "$tmp/err"; then
  fail 'a head the forge reports as not containing the current base must refuse the merge'
fi
printf 'ahead\n' > "$tmp/compare-status"
land > /dev/null 2> "$tmp/err" || fail "ordinary dispatched task must reach an attempting integration slot at merge: $(cat "$tmp/err")"
land > /dev/null 2> "$tmp/err" || fail "a retried merge must reuse the attempting slot: $(cat "$tmp/err")"
python3 - "$(coord inspect)" "$tmp/a/state/fm-coord-adapter.json" <<'PY' || fail 'pre-merge must attach the PR and hold the attempting slot for the task intent'
import json,sys
central=json.loads(sys.argv[1])
intent=json.load(open(sys.argv[2]))['tasks']['a']['intent_id']
assert [i['pr_url'] for i in central['intents'] if i['intent_id']==intent]==['https://github.com/owner/repo/pull/7']
assert [(s['intent_id'],s['state']) for s in central['slots']]==[(intent,'attempting')]
PY
pass 'pre-merge attaches the PR and advances an ordinary dispatched task to the attempting integration slot'
pass 'the forge, not a stale task worktree, decides whether the merge head contains the current base'

result refused > /dev/null 2> "$tmp/err" || fail "a refused merge must report its outcome: $(cat "$tmp/err")"
[ "$(slot_state)" = 'outcome-unknown slot:outcome-unknown' ] || fail "a wrapper-reported refusal must stay outcome-unknown while the wrapper may still act: $(slot_state)"
FM_COORD_QUIET_SECONDS=0 land > /dev/null 2> "$tmp/err" || fail "the next merge run must settle the exited attempt from the forge and re-queue: $(cat "$tmp/err")"
python3 - "$(coord outbox '{"limit":1000}')" <<'PY' || fail 'the prior attempt must settle refused before the new attempt'
import json,sys
assert [e['type'] for e in json.loads(sys.argv[1])['events'] if e['type'] in {'merge-refused','merge-attempted'}][-2:]==['merge-refused','merge-attempted']
PY
[ "$(slot_state)" = 'attempting slot:attempting' ] || fail "re-queued task must hold the attempting slot again: $(slot_state)"
pass 'a refused merge settles from the forge once its wrapper exits and releases the slot for the next attempt'

result unknown > /dev/null 2> "$tmp/err" || fail "a timed-out merge must report its outcome: $(cat "$tmp/err")"
[ "$(slot_state)" = 'outcome-unknown slot:outcome-unknown' ] || fail "an unproven merge must stay outcome-unknown: $(slot_state)"
pass 'a timed-out merge the forge cannot prove landed stays outcome-unknown'

printf '%s|closed|true|%s|main|%s\n' "$pr" "$head_a" "$merge_oid" > "$tmp/pr-state"
result merged > /dev/null 2> "$tmp/err" || fail "a merged outcome must report: $(cat "$tmp/err")"
[ "$(slot_state)" = merged ] || fail "a merge the forge proves landed must settle merged and release the slot: $(slot_state)"
pass 'a merge the forge proves landed settles merged and releases the integration slot'

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
adapter "$tmp/shadow" dispatch shadow "$repo" "$repo" "$tmp/empty.brief" branch/shadow codex > /dev/null 2> "$tmp/err" || fail 'shadow dispatch with the scaffolded empty declaration must only warn'
case "$(cat "$tmp/err")" in *'no coordination resources'*) ;; *) fail 'shadow declaration problem must stay visible' ;; esac
adapter "$tmp/shadow" pre-push shadow "$repo" > /dev/null 2> "$tmp/err" || fail 'shadow push without a local intent must only warn'
printf '{"mode":"shadow","home_id":"shadow","repos":["other/repo"],"db":"%s"}\n' "$db" > "$tmp/shadow/config/coordination.json"
adapter "$tmp/shadow" dispatch shadow "$repo" "$repo" "$tmp/b.brief" branch/shadow codex > /dev/null 2> "$tmp/err" || fail 'dispatch outside coordination enrollment must only warn'
if adapter "$tmp/b" dispatch b2 "$repo" "$repo" "$tmp/empty.brief" branch/b2 codex > /dev/null 2> "$tmp/err"; then
  fail 'enforced dispatch must refuse an empty declaration'
fi
mkdir -p "$tmp/mixed/config" "$tmp/mixed/state" "$tmp/shadowrepo" "$tmp/gitlabrepo"
for other in shadowrepo gitlabrepo; do
  git -C "$tmp/$other" init -q -b main
  git -C "$tmp/$other" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m base
done
git -C "$tmp/gitlabrepo" remote add origin git@gitlab.com:owner/elsewhere.git
printf '{"mode":"shadow","home_id":"mixed","repos":["owner/repo","other/shadow"],"enforce_repos":["owner/repo"],"db":"%s","project_repos":{"%s":"other/shadow"}}\n' "$db" "$(cd "$tmp/shadowrepo" && pwd -P)" > "$tmp/mixed/config/coordination.json"
adapter "$tmp/mixed" dispatch mixed "$tmp/shadowrepo" "$tmp/shadowrepo" "$tmp/empty.brief" branch/mixed codex > /dev/null 2> "$tmp/err" || fail 'shadow repository dispatch in an enforcing home must only warn'
adapter "$tmp/mixed" pre-ci mixed batch-mixed "$tmp/shadowrepo" > /dev/null 2> "$tmp/err" || fail "shadow repository CI pulse without a full intent must only warn in an enforcing home: $(cat "$tmp/err")"
adapter "$tmp/mixed" pre-push mixed "$tmp/shadowrepo" > /dev/null 2> "$tmp/err" || fail 'shadow repository push without a full intent must only warn in an enforcing home'
adapter "$tmp/mixed" pre-push elsewhere "$tmp/gitlabrepo" > /dev/null 2> "$tmp/err" || fail 'push from a non-GitHub repository outside enforcement must only warn'
if adapter "$tmp/mixed" pre-ci never-dispatched > /dev/null 2> "$tmp/err"; then
  fail 'CI pulse for a task this enforcing home never dispatched must refuse'
fi
pass 'shadow repositories warn and continue; enforced repositories refuse'
