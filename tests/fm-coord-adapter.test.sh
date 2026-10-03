#!/usr/bin/env bash
# Public adapter behavior: enrollment, replay, scope expansion, and fencing.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

tmp=$(fm_test_tmproot fm-coord-adapter)
repo=$tmp/repo
db=$tmp/central/coord.sqlite3
mkdir -p "$repo/src" "$tmp/central"
git -C "$repo" init -q -b main
git -C "$repo" config user.name 'Fixture'
git -C "$repo" config user.email 'fixture@example.invalid'
git -C "$repo" remote add origin git@github.com:owner/repo.git
printf 'base\n' > "$repo/src/base.py"
git -C "$repo" add src/base.py
git -C "$repo" commit -qm base
git -C "$repo" update-ref refs/remotes/origin/main HEAD

coord() { "$ROOT/bin/fm-coord.sh" --db "$db" "$@"; }
adapter() { FM_HOME=$1 python3 "$ROOT/bin/fm-coord-adapter.py" "${@:2}"; }
make_home() {
  local name=$1
  mkdir -p "$tmp/$name/config" "$tmp/$name/state"
  printf '{"mode":"shadow","home_id":"%s","repos":["owner/repo"],"db":"%s"}\n' "$name" "$db" > "$tmp/$name/config/coordination.json"
}
make_brief() {
  printf '## Firstmate spec\nCoordination resources: [{"type":"file","name":"src/%s.py"}]\nCoordination issue: owner/repo#%s\n' "$2" "$3" > "$tmp/$1.brief"
}
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }

make_home offline
make_brief offline base 1
adapter "$tmp/offline" dispatch offline "$repo" "$repo" "$tmp/offline.brief" branch/offline codex > "$tmp/offline.out" 2> "$tmp/offline.err" || fail 'offline dispatch must stay advisory'
case "$(cat "$tmp/offline.err")" in *'no claim granted'*) ;; *) fail 'offline dispatch must warn no grant' ;; esac
python3 - "$tmp/offline/state/fm-coord-adapter.json" <<'PY' || fail 'offline request must be persisted'
import json,sys
state=json.load(open(sys.argv[1]))
assert 'enroll' in state['requests'] and 'reply' not in state['requests']['enroll']
assert 'offline' in state['tasks'] and 'claim' not in state['tasks']['offline']
PY
coord init > /dev/null
coord area-set '{"request_id":"area-omp","repo":"owner/repo","name":"omp-api","paths":["src/omp-area"],"aliases":["api-alias"]}' > /dev/null
adapter "$tmp/offline" replay > "$tmp/replay.out" 2> "$tmp/replay.err" || fail 'offline replay must complete'
python3 - "$tmp/offline/state/fm-coord-adapter.json" <<'PY' || fail 'replay must obtain a real claim'
import json,sys
state=json.load(open(sys.argv[1]))
assert state['tasks']['offline']['claim']['ok'] is True
PY
pass 'offline participant journals requests and later replays without a silent grant'

python3 - "$tmp/offline/state/fm-coord-adapter.json" <<'PY'
import json,sys
path=sys.argv[1]
state=json.load(open(path))
state['requests']['offline:claim'].pop('reply')
state['tasks']['offline'].pop('claim')
json.dump(state,open(path,'w'))
PY
before=$(field "$(coord view)" claims)
adapter "$tmp/offline" replay > /dev/null 2> "$tmp/lost.err" || fail 'lost reply replay must complete'
after=$(field "$(coord view)" claims)
[ "$before" = "$after" ] || fail 'lost reply must not make a second claim'
pass 'lost grant reply reuses its request ID and returns the original fence'

for harness in claude codex omp opencode; do
  make_home "$harness"
  make_brief "$harness" "$harness" "$((10 + ${#harness}))"
  if [ "$harness" = omp ]; then
    printf 'Coordination resources: [{"type":"area","name":"api-alias"}]\nCoordination issue: owner/repo#13\n' > "$tmp/omp.brief"
  fi
  adapter "$tmp/$harness" dispatch "$harness" "$repo" "$repo" "$tmp/$harness.brief" "branch/$harness" "$harness" > /dev/null 2> "$tmp/$harness.err" || fail "$harness dispatch must complete"
  python3 - "$tmp/$harness/state/fm-coord-adapter.json" "$harness" <<'PY' || fail "$harness must use the shared intent and event protocol"
import json,sys
state=json.load(open(sys.argv[1]))
task=state['tasks'][sys.argv[2]]
assert task['claim']['ok'] is True
assert task['harness']==sys.argv[2]
assert state['requests'][sys.argv[2]+':submit']['reply']['ok'] is True
assert any(resource[0]=='issue' for resource in task['resources'])
if sys.argv[2]=='omp':
    assert ['area','omp-api'] in task['resources']
    assert ['directory','src/omp-area'] in task['resources']
PY
done
pass 'Claude Code, Codex, omp, and OpenCode enroll with the same protocol'

make_home missing-adapter
make_brief missing-adapter missing 100
adapter "$tmp/missing-adapter" dispatch missing-adapter "$repo" "$repo" "$tmp/missing-adapter.brief" branch/missing cursor > /dev/null 2> "$tmp/missing-adapter.err" || fail 'missing harness adapter remains advisory'
case "$(cat "$tmp/missing-adapter.err")" in *'cursor has no coordination adapter'*) ;; *) fail 'missing harness adapter must be visible' ;; esac
pass 'missing harness adapter fails visibly without claiming authority'

make_home remote-home
make_brief remote-home remote 101
printf '{"mode":"shadow","home_id":"remote-home","repos":["owner/repo"],"remote":{"host":"coord.example","command":"%s/bin/fm-coord.sh","db":"%s"}}\n' "$ROOT" "$db" > "$tmp/remote-home/config/coordination.json"
mkdir -p "$tmp/sshbin"
cat > "$tmp/sshbin/ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 1 ]; do shift; done
exec /bin/bash -c "$1"
SH
chmod +x "$tmp/sshbin/ssh"
PATH="$tmp/sshbin:$PATH" adapter "$tmp/remote-home" dispatch remote-home "$repo" "$repo" "$tmp/remote-home.brief" branch/remote codex > /dev/null 2> "$tmp/remote.err" || fail 'remote transport must dispatch'
python3 - "$tmp/remote-home/state/fm-coord-adapter.json" <<'PY' || fail 'remote transport must return central claim'
import json,sys
assert json.load(open(sys.argv[1]))['tasks']['remote-home']['claim']['ok'] is True
PY
pass 'fixed-argument SSH transport enrolls a remote home against one authority'

make_home remote-offline
make_brief remote-offline offline-remote 102
printf '{"mode":"advisory","home_id":"remote-offline","repos":["owner/repo"],"remote":{"host":"coord.example","command":"%s/bin/fm-coord.sh","db":"%s"}}\n' "$ROOT" "$db" > "$tmp/remote-offline/config/coordination.json"
mkdir -p "$tmp/sshdown"
printf '#!/usr/bin/env bash\nexit 255\n' > "$tmp/sshdown/ssh"
chmod +x "$tmp/sshdown/ssh"
PATH="$tmp/sshdown:$PATH" adapter "$tmp/remote-offline" dispatch remote-offline "$repo" "$repo" "$tmp/remote-offline.brief" branch/offline-remote opencode > /dev/null 2> "$tmp/remote-offline.err" || fail 'offline remote dispatch remains advisory'
case "$(cat "$tmp/remote-offline.err")" in *'no claim granted'*) ;; *) fail 'offline SSH participant must warn no grant' ;; esac
PATH="$tmp/sshbin:$PATH" adapter "$tmp/remote-offline" replay > /dev/null 2> "$tmp/remote-replay.err" || fail 'offline remote replay must complete'
python3 - "$tmp/remote-offline/state/fm-coord-adapter.json" <<'PY' || fail 'remote replay must obtain central grant'
import json,sys
assert json.load(open(sys.argv[1]))['tasks']['remote-offline']['claim']['ok'] is True
PY
pass 'remote outage journals intent and replays after the authority returns'

make_home challenger
make_brief challenger base 99
adapter "$tmp/challenger" dispatch challenger "$repo" "$repo" "$tmp/challenger.brief" branch/challenger claude > /dev/null 2> "$tmp/conflict.err" || fail 'conflict remains advisory'
case "$(cat "$tmp/conflict.err")" in *'held by offline'*) ;; *) fail 'conflict must name holder' ;; esac
pass 'pre-dispatch conflict names current holder'
adapter "$tmp/challenger" pre-push challenger "$repo" > /dev/null 2>&1 || fail 'refused task push checkpoint must stay advisory'
adapter "$tmp/challenger" pre-ci challenger > /dev/null 2>&1 || fail 'refused task CI checkpoint must stay advisory'

python3 - "$db" <<'PY'
import sqlite3,sys
db=sqlite3.connect(sys.argv[1])
db.execute("UPDATE claims SET expires_mono_ns=0 WHERE intent_id LIKE 'offline:%'")
db.commit()
PY
adapter "$tmp/challenger" replay > /dev/null 2> "$tmp/retry.err" || fail 'replay after refusal must complete'
python3 - "$tmp/challenger/state/fm-coord-adapter.json" <<'PY' || fail 'replay must not reclaim resources for a task without a pending dispatch or checkpoint'
import json,sys
assert 'claim' not in json.load(open(sys.argv[1]))['tasks']['challenger']
PY
adapter "$tmp/challenger" pre-ci challenger > /dev/null 2> "$tmp/retry.err" || fail 'refused claim retry must complete'
python3 - "$tmp/challenger/state/fm-coord-adapter.json" <<'PY' || fail 'refused claim must be retried after the holder lease expires'
import json,sys
assert json.load(open(sys.argv[1]))['tasks']['challenger']['claim']['ok'] is True
PY
pass 'refused claim is retried by the next live checkpoint, never by replay alone'

printf 'extra\n' > "$repo/src/extra.py"
git -C "$repo" add src/extra.py
git -C "$repo" commit -qm extra
adapter "$tmp/codex" pre-push codex "$repo" > /dev/null 2> "$tmp/scope.err" || fail 'scope expansion must stay advisory'
case "$(cat "$tmp/scope.err")" in *'undeclared changed paths: src/extra.py'*) ;; *) fail 'undeclared path must warn' ;; esac
python3 - "$(coord view)" <<'PY' || fail 'amendment must reach central state'
import json,sys
view=json.loads(sys.argv[1])
assert any(i['intent_id']=='codex:owner/repo:codex' and i['version']==2 for i in view['intents'])
PY
adapter "$tmp/codex" pre-ci codex > /dev/null 2> "$tmp/ci.err" || fail 'current writer CI check must complete'
[ ! -s "$tmp/ci.err" ] || fail 'current writer CI check must not warn'
adapter "$tmp/codex" heartbeat codex > /dev/null 2> "$tmp/heartbeat.err" || fail 'active worker heartbeat must complete'
python3 - "$(coord outbox '{"limit":1000}')" <<'PY' || fail 'heartbeat must renew the claim centrally'
import json,sys
events=json.loads(sys.argv[1])['events']
assert any(event['type']=='lease-renewed' for event in events)
PY
pass 'undeclared write requests amendment before push; current writer checks before CI'

python3 - "$tmp/codex/config/coordination.json" "$tmp/unreachable.sqlite3" <<'PY'
import json,sys
path=sys.argv[1]
config=json.load(open(path))
config['db']=sys.argv[2]
json.dump(config,open(path,'w'))
PY
adapter "$tmp/codex" pre-ci codex > /dev/null 2> "$tmp/offline-ci.err" || fail 'offline CI checkpoint remains advisory'
adapter "$tmp/codex" pre-push codex "$repo" > /dev/null 2> "$tmp/offline-push.err" || fail 'offline push checkpoint remains advisory'
python3 - "$(adapter "$tmp/codex" view)" <<'PY' || fail 'offline checkpoints must be journaled locally'
import json,sys
pending=json.loads(sys.argv[1])['local_pending']
assert {p['operation'] for p in pending} >= {'pre-ci','pre-push'}
PY
python3 - "$tmp/codex/config/coordination.json" "$db" <<'PY'
import json,sys
path=sys.argv[1]
config=json.load(open(path))
config['db']=sys.argv[2]
json.dump(config,open(path,'w'))
PY
adapter "$tmp/codex" replay > /dev/null 2> "$tmp/checkpoint-replay.err" || fail 'checkpoint replay must complete'
python3 - "$(adapter "$tmp/codex" view)" <<'PY' || fail 'replay must clear recovered checkpoints'
import json,sys
assert not json.loads(sys.argv[1])['local_pending']
PY
pass 'offline push and CI checkpoints remain visible until replay'

printf 'h1\n' > "$repo/src/codex.py"
git -C "$repo" add src/codex.py
git -C "$repo" commit -qm h1
adapter "$tmp/codex" pre-push codex "$repo" > /dev/null 2>&1 || fail 'h1 push checkpoint must complete'
python3 - "$tmp/codex/state/fm-coord-adapter.json" "$(git -C "$repo" rev-parse HEAD~1)" "$(git -C "$repo" rev-parse HEAD)" <<'PY'
import json,sys
path,previous,h1=sys.argv[1:]
state=json.load(open(path))
state['requests']['codex:head:'+previous+':'+h1].pop('reply')
state['tasks']['codex']['published_head']=previous
state['tasks']['codex']['pending_head']=h1
json.dump(state,open(path,'w'))
PY
printf 'h2\n' > "$repo/src/codex.py"
git -C "$repo" commit -qam h2
adapter "$tmp/codex" pre-push codex "$repo" > /dev/null 2> "$tmp/head-chain.err" || fail 'h2 push checkpoint must complete'
python3 - "$(adapter "$tmp/codex" view)" "$(git -C "$repo" rev-parse HEAD)" <<'PY' || fail 'lost head reply must not wedge the next head publication'
import json,sys
view=json.loads(sys.argv[1])
assert not view['local_pending'], view['local_pending']
assert view['local_tasks']['codex']['published_head']==sys.argv[2]
PY
pass 'lost publish-head reply is replayed before the next head is published'

h2=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" commit -q --amend -m h2-rebased
adapter "$tmp/codex" pre-push codex "$repo" > /dev/null 2>&1 || fail 'rebased push checkpoint must complete'
git -C "$repo" reset -q --hard "$h2"
adapter "$tmp/codex" pre-push codex "$repo" > /dev/null 2>&1 || fail 'reset push checkpoint must complete'
printf 'h3\n' > "$repo/src/codex.py"
git -C "$repo" commit -qam h3
adapter "$tmp/codex" pre-push codex "$repo" > /dev/null 2>&1 || fail 'h3 push checkpoint must complete'
python3 - "$(adapter "$tmp/codex" view)" "$(git -C "$repo" rev-parse HEAD)" <<'PY' || fail 'returning to an earlier head must not wedge later head publication'
import json,sys
view=json.loads(sys.argv[1])
assert not view['local_pending'], view['local_pending']
assert view['local_tasks']['codex']['published_head']==sys.argv[2]
PY
pass 'a head republished after a rebase keeps the central head chain'

python3 - "$tmp/codex/state/fm-coord-adapter.json" <<'PY'
import json,sys
path=sys.argv[1]
state=json.load(open(path))
state['tasks']['codex']['claim']['fence']+=1
json.dump(state,open(path,'w'))
PY
adapter "$tmp/codex" pre-ci codex > /dev/null 2> "$tmp/stale.err" || fail 'stale writer stays advisory'
case "$(cat "$tmp/stale.err")" in *'cannot be checked'*) ;; *) fail 'stale writer must warn' ;; esac
pass 'stale branch writer generation warns before CI request'

view=$(adapter "$tmp/codex" view)
python3 - "$view" <<'PY' || fail 'view must project central intents, claims, conflicts, queue, and local pending'
import json,sys
view=json.loads(sys.argv[1])
assert all(k in view['central'] for k in ('intents','claims','conflicts','queue','outbox'))
assert 'local_pending' in view
assert any(c['type']=='claim-denied' for c in view['central']['conflicts'])
PY
pass 'coordinator view projects claims, conflicts, queue, and local outbox'

spawn_home=$tmp/spawn-home
spawn_repo=$tmp/spawn-repo
spawn_wt=$tmp/spawn-wt
fm_test_spawn_home "$spawn_home" codex
fm_git_worktree "$spawn_repo" "$spawn_wt" fixture-slot
git -C "$spawn_repo" fetch -q origin
git clone -q "$spawn_repo.origin.git" "$tmp/spawn-upstream"
printf 'upstream\n' > "$tmp/spawn-upstream/upstream.txt"
git -C "$tmp/spawn-upstream" add upstream.txt
git -C "$tmp/spawn-upstream" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm upstream
git -C "$tmp/spawn-upstream" push -q origin HEAD:main
fm_test_spawn_brief "$spawn_home" spawned
printf 'Coordination resources: [{"type":"file","name":"README.md"}]\n' >> "$spawn_home/data/spawned/brief.md"
printf '{"mode":"advisory","home_id":"spawn-home","repos":["owner/repo"],"db":"%s","project_repos":{"%s":"owner/repo"}}\n' "$db" "$spawn_repo" > "$spawn_home/config/coordination.json"
fakebin=$(fm_test_make_spawn_fakebin "$tmp/spawn-fake")
fm_test_run_spawn "$spawn_home" "$spawn_wt" "$fakebin" spawned "$spawn_repo" --mode direct-PR --yolo off --harness codex > "$tmp/spawn.out" || fail 'configured spawn must remain operational'
python3 - "$spawn_home/state/fm-coord-adapter.json" "$spawn_home/data/spawned/launch-brief.md" "$(git -C "$spawn_wt" rev-parse HEAD)" "$(git -C "$tmp/spawn-upstream" rev-parse HEAD)" <<'PY' || fail 'spawn must submit intent and render worker checkpoints'
import json,sys
state=json.load(open(sys.argv[1]))
brief=open(sys.argv[2]).read()
assert state['tasks']['spawned']['claim']['ok'] is True
assert state['tasks']['spawned']['base_oid']==sys.argv[3]==sys.argv[4], (state['tasks']['spawned']['base_oid'], sys.argv[3], sys.argv[4])
assert 'pre-push' in brief and 'pre-ci' in brief and 'heartbeat' in brief
PY
pass 'spawn records the refreshed worker start commit as the intent base and projects the adapter into the worker brief'

abort_wt=$tmp/spawn-abort-wt
git -C "$spawn_repo" worktree add --quiet -b abort-slot "$abort_wt"
fm_test_spawn_brief "$spawn_home" aborted
printf 'Coordination resources: [{"type":"file","name":"src/aborted.py"}]\n' >> "$spawn_home/data/aborted/brief.md"
mkdir -p "$spawn_home/user-home/.claude.json"
if fm_test_run_spawn "$spawn_home" "$abort_wt" "$fakebin" aborted "$spawn_repo" --mode direct-PR --yolo off --harness claude > "$tmp/spawn-abort.out"; then
  fail 'spawn with unwritable Claude trust must abort'
fi
rmdir "$spawn_home/user-home/.claude.json"
python3 - "$spawn_home/state/fm-coord-adapter.json" "$(coord view)" <<'PY' || fail "aborted spawn must release the claim its dispatch acquired: $(cat "$tmp/spawn-abort.out")"
import json,sys
task=json.load(open(sys.argv[1]))['tasks']['aborted']
view=json.loads(sys.argv[2])
assert 'claim' not in task and not task.get('pending_dispatch'), task
assert not any(c['intent_id'].startswith('spawn-home:owner/repo:aborted') for c in view['claims']), view['claims']
PY
pass 'a spawn that aborts before launch releases the claim its dispatch acquired'

git -C "$repo" worktree add -q --detach "$tmp/lag-wt" main
printf 'upstream\n' > "$tmp/lag-wt/src/upstream.py"
git -C "$tmp/lag-wt" add src/upstream.py
git -C "$tmp/lag-wt" commit -qm upstream
git -C "$repo" update-ref refs/remotes/origin/main "$(git -C "$tmp/lag-wt" rev-parse HEAD)"
make_home lag
make_brief lag lag 103
adapter "$tmp/lag" dispatch lag "$repo" "$tmp/lag-wt" "$tmp/lag.brief" branch/lag codex > /dev/null 2>&1 || fail 'lagging-main dispatch must complete'
printf 'lag\n' > "$tmp/lag-wt/src/lag.py"
git -C "$tmp/lag-wt" add src/lag.py
git -C "$tmp/lag-wt" commit -qm lag
adapter "$tmp/lag" pre-push lag "$tmp/lag-wt" > /dev/null 2> "$tmp/lag.err" || fail 'lagging-main push checkpoint must complete'
case "$(cat "$tmp/lag.err")" in *upstream.py*) fail 'upstream commits must not count as undeclared task paths' ;; esac
pass 'scope diff starts at the origin base, not a lagging local main'

make_home blocked
make_brief blocked blocked 104
git -C "$repo" worktree add -q --detach "$tmp/blocked-wt" origin/main
adapter "$tmp/blocked" dispatch blocked "$repo" "$tmp/blocked-wt" "$tmp/blocked.brief" branch/blocked codex > /dev/null 2>&1 || fail 'blocked-scope dispatch must complete'
printf 'taken\n' > "$tmp/blocked-wt/src/opencode.py"
git -C "$tmp/blocked-wt" add src/opencode.py
git -C "$tmp/blocked-wt" commit -qm taken
adapter "$tmp/blocked" pre-push blocked "$tmp/blocked-wt" > /dev/null 2> "$tmp/blocked.err" || fail 'refused amendment push checkpoint must stay advisory'
case "$(cat "$tmp/blocked.err")" in *'head not published'*) ;; *) fail "refused amendment must warn that the head is unpublished: $(cat "$tmp/blocked.err")" ;; esac
python3 - "$db" "$(adapter "$tmp/blocked" view)" <<'PY' || fail 'a head with unclaimed changed paths must not be published centrally'
import json,sqlite3,sys
assert sqlite3.connect(sys.argv[1]).execute("SELECT count(*) FROM heads WHERE intent_id LIKE 'blocked:%'").fetchone()[0]==0
pending={p['operation'] for p in json.loads(sys.argv[2])['local_pending'] if p['key']=='blocked'}
assert pending>={'pre-push','scope-amend'}, pending
PY
pass 'a refused scope amendment keeps the head unpublished and the unclaimed scope pending'

git init -q "$tmp/nobase"
git -C "$tmp/nobase" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m nobase
make_home nobase
printf '{"mode":"shadow","home_id":"nobase","repos":["owner/repo"],"db":"%s","project_repos":{"%s":"owner/repo"}}\n' "$db" "$(cd "$tmp/nobase" && pwd -P)" > "$tmp/nobase/config/coordination.json"
make_brief nobase nobase 105
adapter "$tmp/nobase" dispatch nobase "$tmp/nobase" "$tmp/nobase" "$tmp/nobase.brief" branch/nobase codex > /dev/null 2> "$tmp/nobase.err" || fail "missing origin base must stay advisory: $(cat "$tmp/nobase.err")"
case "$(cat "$tmp/nobase.err")" in *'origin/main is missing'*) ;; *) fail 'missing origin base must warn' ;; esac
python3 - "$tmp/nobase/state/fm-coord-adapter.json" <<'PY' || fail 'missing origin base must record an explicit no-base intent'
import json,sys
task=json.load(open(sys.argv[1]))['tasks']['nobase']
assert task['base_oid'] is None and 'claim' not in task and not task['pending_dispatch']
PY
pass 'a missing origin base records an explicit unsubmitted no-base intent'
git -C "$tmp/nobase" update-ref refs/remotes/origin/main HEAD
adapter "$tmp/nobase" dispatch nobase "$tmp/nobase" "$tmp/nobase" "$tmp/nobase.brief" branch/nobase codex > /dev/null 2> "$tmp/nobase-retry.err" || fail "no-base retry must dispatch: $(cat "$tmp/nobase-retry.err")"
git -C "$tmp/nobase" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m advanced
git -C "$tmp/nobase" update-ref refs/remotes/origin/main HEAD
python3 - "$tmp/nobase/state/fm-coord-adapter.json" "$(git -C "$tmp/nobase" rev-parse HEAD~1)" <<'PY' || fail 'a retry after a no-base attempt must submit and claim at the retried worktree HEAD'
import json,sys
task=json.load(open(sys.argv[1]))['tasks']['nobase']
assert task['base_oid']==sys.argv[2] and task['claim']['ok'] is True, task
PY
adapter "$tmp/nobase" dispatch nobase "$tmp/nobase" "$tmp/nobase" "$tmp/nobase.brief" branch/nobase codex > /dev/null 2> "$tmp/nobase-advance.err" || fail "advanced-base retry must dispatch: $(cat "$tmp/nobase-advance.err")"
python3 - "$tmp/nobase/state/fm-coord-adapter.json" "$(git -C "$tmp/nobase" rev-parse HEAD)" "$(coord view)" <<'PY' || fail "a retry after the base advanced must record and claim the retried worktree HEAD: $(cat "$tmp/nobase-advance.err")"
import json,sys
task=json.load(open(sys.argv[1]))['tasks']['nobase']
assert task['base_oid']==sys.argv[2] and task['claim']['ok'] is True, task
live=[i for i in json.loads(sys.argv[3])['intents'] if i['task_id']=='nobase' and i['state']=='claimed']
assert [i['intent_id'] for i in live]==[task['intent_id']], live
PY
pass 'a fresh retry refreshes the intent base to the retried worktree HEAD'
old_claim=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"]["nobase"]["claim"]["claim_id"])' "$tmp/nobase/state/fm-coord-adapter.json")
printf '{"mode":"shadow","home_id":"nobase","repos":["owner/repo"],"remote":{"host":"coord.example","command":"%s/bin/fm-coord.sh","db":"%s"},"project_repos":{"%s":"owner/repo"}}\n' "$ROOT" "$db" "$(cd "$tmp/nobase" && pwd -P)" > "$tmp/nobase/config/coordination.json"
git -C "$tmp/nobase" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m offline-retry
git -C "$tmp/nobase" update-ref refs/remotes/origin/main HEAD
PATH="$tmp/sshdown:$PATH" adapter "$tmp/nobase" dispatch nobase "$tmp/nobase" "$tmp/nobase" "$tmp/nobase.brief" branch/nobase codex > /dev/null 2> "$tmp/nobase-offline.err" || fail "offline retry must stay advisory: $(cat "$tmp/nobase-offline.err")"
python3 - "$tmp/nobase/state/fm-coord-adapter.json" "$old_claim" <<'PY' || fail 'an offline retry must journal the prior claim release and hold the new attempt until it replays'
import json,sys
state=json.load(open(sys.argv[1]))
task=state['tasks']['nobase']
release=state['requests'][task['releasing']]
assert release['op']=='release' and release['payload']['claim_id']==sys.argv[2] and 'reply' not in release, release
assert not any(k.startswith('nobase:') for k in state['requests']), state['requests']
PY
PATH="$tmp/sshbin:$PATH" adapter "$tmp/nobase" replay > /dev/null 2> "$tmp/nobase-replay.err" || fail "replay after offline retry must complete: $(cat "$tmp/nobase-replay.err")"
python3 - "$tmp/nobase/state/fm-coord-adapter.json" "$(git -C "$tmp/nobase" rev-parse HEAD)" "$(coord view)" "$db" "$old_claim" <<'PY' || fail "replay must release the prior attempt and claim the offline retry: $(cat "$tmp/nobase-replay.err")"
import json,sqlite3,sys
state=json.load(open(sys.argv[1]))
task=state['tasks']['nobase']
assert task['base_oid']==sys.argv[2] and task['claim']['ok'] is True and 'releasing' not in task, task
live=[i for i in json.loads(sys.argv[3])['intents'] if i['task_id']=='nobase' and i['state']=='claimed']
assert [i['intent_id'] for i in live]==[task['intent_id']], live
assert sqlite3.connect(sys.argv[4]).execute("SELECT state FROM claims WHERE claim_id=?", (sys.argv[5],)).fetchone()[0]!='active'
PY
pass 'an offline retry queues the prior claim release and claims the retry once it replays'

make_home scaffold
mkdir -p "$tmp/scaffold/data"
FM_HOME="$tmp/scaffold" "$ROOT/bin/fm-brief.sh" scaffold some-proj --mode local-only > /dev/null 2>&1 || fail 'coordinated brief must scaffold'
adapter "$tmp/scaffold" dispatch scaffold "$repo" "$repo" "$tmp/scaffold/data/scaffold/brief.md" branch/scaffold codex > /dev/null 2> "$tmp/scaffold.err" || fail 'empty declaration dispatch must stay advisory'
case "$(cat "$tmp/scaffold.err")" in *'no coordination resources'*unclaimed*) ;; *) fail 'empty declaration must warn it is unclaimed' ;; esac
python3 - "$tmp/scaffold/state/fm-coord-adapter.json" <<'PY' || fail 'empty declaration must be recorded as an unclaimed local intent'
import json,sys
task=json.load(open(sys.argv[1]))['tasks']['scaffold']
assert task['declared']==[] and 'claim' not in task
PY
sed -i.bak 's#^Coordination resources: \[\]$#Coordination resources: [{"type":"file","name":"src/scaffold.py"}]#' "$tmp/scaffold/data/scaffold/brief.md"
adapter "$tmp/scaffold" dispatch scaffold "$repo" "$repo" "$tmp/scaffold/data/scaffold/brief.md" branch/scaffold codex > /dev/null 2> "$tmp/scaffold-filled.err" || fail "filled declaration must replace the unsubmitted one: $(cat "$tmp/scaffold-filled.err")"
python3 - "$tmp/scaffold/state/fm-coord-adapter.json" <<'PY' || fail 'filled declaration must be submitted and claimed'
import json,sys
assert json.load(open(sys.argv[1]))['tasks']['scaffold']['claim']['ok'] is True
PY
mkdir -p "$tmp/plain/data"
FM_HOME="$tmp/plain" "$ROOT/bin/fm-brief.sh" plain some-proj --mode local-only > /dev/null 2>&1 || fail 'uncoordinated brief must scaffold'
if grep -q 'Coordination resources' "$tmp/plain/data/plain/brief.md"; then fail 'uncoordinated brief must not scaffold a coordination declaration'; fi
adapter "$tmp/plain" dispatch plain "$repo" "$repo" "$tmp/plain/data/plain/brief.md" branch/plain codex > /dev/null 2> "$tmp/plain.err" || fail 'uncoordinated dispatch must be a no-op'
[ ! -s "$tmp/plain.err" ] && [ ! -e "$tmp/plain/state/fm-coord-adapter.json" ] || fail 'uncoordinated dispatch must record nothing'
pass 'coordination scaffold follows home enrollment; an empty declaration is a visible unclaimed intent'

python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"a+"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(15)' "$tmp/claude/state/fm-coord-adapter.lock" "$tmp/lock.ready" &
holder=$!
while [ ! -e "$tmp/lock.ready" ]; do sleep 0.1; done
start=$(date +%s)
if adapter "$tmp/claude" heartbeat claude > /dev/null 2> "$tmp/lock.err"; then fail 'busy journal checkpoint must fail visibly'; fi
elapsed=$(($(date +%s) - start))
kill "$holder"
wait "$holder" 2> /dev/null || true
case "$(cat "$tmp/lock.err")" in *busy*) ;; *) fail 'busy journal must warn' ;; esac
[ "$elapsed" -lt 12 ] || fail 'busy journal wait must be bounded'
pass 'a held adapter journal lock bounds the checkpoint wait'

python3 - "$db" <<'PY'
import sqlite3,sys
db=sqlite3.connect(sys.argv[1])
db.execute("UPDATE meta SET value='previous-boot' WHERE key='boot_id'")
db.commit()
PY
printf '## Firstmate spec\nCoordination resources: [{"type":"file","name":"src/claude-b.py"}]\n' > "$tmp/claude-b.brief"
adapter "$tmp/claude" dispatch claude-b "$repo" "$repo" "$tmp/claude-b.brief" branch/claude-b claude > /dev/null 2> "$tmp/reboot.err" || fail 'post-reboot dispatch must complete'
adapter "$tmp/claude" pre-ci claude > /dev/null 2>&1 || fail 'post-reboot checkpoint must complete'
adapter "$tmp/claude" pre-ci claude > /dev/null 2> "$tmp/reboot-ci.err" || fail 'recovered checkpoint must complete'
[ ! -s "$tmp/reboot-ci.err" ] || fail "recovered writer must check cleanly: $(cat "$tmp/reboot-ci.err")"
python3 - "$tmp/claude/state/fm-coord-adapter.json" <<'PY' || fail 'coordinator reboot must recover through a fresh session'
import json,sys
tasks=json.load(open(sys.argv[1]))['tasks']
assert tasks['claude-b']['claim']['ok'] is True
assert tasks['claude']['claim']['ok'] is True
PY
pass 'coordinator reboot starts a fresh session and resubmits local intents'
