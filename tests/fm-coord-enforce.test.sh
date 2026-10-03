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
if adapter "$tmp/a" pre-ci a batch-one > "$tmp/out" 2> "$tmp/err"; then
  fail 'second pulse for the same batch must be refused'
fi
case "$(cat "$tmp/err")" in *'already requested'*) ;; *) fail 'duplicate pulse must name batch' ;; esac
pass 'enforcement pauses offline dispatch and undeclared push until re-admission; one CI pulse per batch'

before=$(coord outbox '{"limit":1000}')
after=$(coord outbox '{"limit":1000}')
[ "$before" = "$after" ] || fail 'unacknowledged outbox replay must keep event IDs and order'
pass 'outbox replay preserves event IDs across coordinator invocations'

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

python3 - "$db" "$tmp/older.sqlite3" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as source, sqlite3.connect(sys.argv[2]) as target:
    source.backup(target)
PY
coord enroll '{"request_id":"later-enrollment","home_id":"later","repos":["owner/repo"]}' > /dev/null
coord session '{"request_id":"later-session","home_id":"later"}' > /dev/null
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
