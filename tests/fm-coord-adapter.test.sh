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
printf '%s\n' "$1" >> "${SSH_LOG:-/dev/null}"
exec /bin/bash -c "$1"
SH
chmod +x "$tmp/sshbin/ssh"
SSH_LOG="$tmp/remote-ssh.log" PATH="$tmp/sshbin:$PATH" adapter "$tmp/remote-home" dispatch remote-home "$repo" "$repo" "$tmp/remote-home.brief" branch/remote codex > /dev/null 2> "$tmp/remote.err" || fail 'remote transport must dispatch'
python3 - "$tmp/remote-home/state/fm-coord-adapter.json" <<'PY' || fail 'remote transport must return central claim'
import json,sys
assert json.load(open(sys.argv[1]))['tasks']['remote-home']['claim']['ok'] is True
PY
python3 - "$tmp/remote-ssh.log" "$(coord inspect '{}')" <<'PY' || fail 'remote enrollment must bind the home machine identity it sent'
import json,shlex,sys
enroll = [json.loads(shlex.split(line)[-1]) for line in open(sys.argv[1]) if shlex.split(line)[-2] == 'enroll']
assert len(enroll) == 1 and enroll[0]['host_id'].startswith('machine:'), enroll
assert {p['home_id']: p['host_id'] for p in json.loads(sys.argv[2])['participants']}['remote-home'] == enroll[0]['host_id']
PY
make_home switch
make_brief switch switch 103
adapter "$tmp/switch" dispatch switch "$repo" "$repo" "$tmp/switch.brief" branch/switch claude > /dev/null 2>&1 || fail 'direct transport must dispatch'
printf '{"mode":"shadow","home_id":"switch","repos":["owner/repo"],"remote":{"host":"coord.example","command":"%s/bin/fm-coord.sh","db":"%s"}}\n' "$ROOT" "$db" > "$tmp/switch/config/coordination.json"
PATH="$tmp/sshbin:$PATH" adapter "$tmp/switch" heartbeat switch > /dev/null 2> "$tmp/switch.err" || fail "transport switch must reuse the journaled enrollment: $(cat "$tmp/switch.err")"
pass 'fixed-argument SSH transport enrolls a remote home against one authority'

make_home no-intent
for checkpoint in "heartbeat ghost" "pre-ci ghost batch-127 $repo" "pre-ci ghost" "pre-push ghost $repo"; do
  # shellcheck disable=SC2086
  adapter "$tmp/no-intent" $checkpoint > /dev/null 2> "$tmp/no-intent.err" || fail "$checkpoint without a local intent must stay advisory: $(cat "$tmp/no-intent.err")"
  case "$checkpoint:$(cat "$tmp/no-intent.err")" in *"no local intent record"*) ;; *) fail "$checkpoint without a local intent must say so" ;; esac
done
pass 'checkpoints for a task without a local intent warn instead of failing'

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
adapter "$tmp/challenger" pre-ci challenger batch-155 "$repo" > /dev/null 2>&1 || fail 'refused task CI checkpoint must stay advisory'

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
adapter "$tmp/challenger" pre-ci challenger batch-168 "$repo" > /dev/null 2> "$tmp/retry.err" || fail 'refused claim retry must complete'
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
adapter "$tmp/codex" pre-ci codex batch-185 "$repo" > /dev/null 2> "$tmp/ci.err" || fail 'current writer CI check must complete'
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
adapter "$tmp/codex" pre-ci codex batch-offline "$repo" > /dev/null 2> "$tmp/offline-ci.err" || fail 'offline CI checkpoint remains advisory'
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

printf 'h4\n' > "$repo/src/codex.py"
git -C "$repo" commit -qam h4
adapter "$tmp/codex" pre-ci codex batch-265 "$repo" > /dev/null 2> "$tmp/unpublished-ci.err" || fail 'unpublished head CI checkpoint stays advisory'
case "$(cat "$tmp/unpublished-ci.err")" in *'is not the published head'*) ;; *) fail 'CI checkpoint must refuse an unpublished head' ;; esac
adapter "$tmp/codex" replay > /dev/null 2>&1 || fail 'replay with unpublished head must complete'
python3 - "$(adapter "$tmp/codex" view)" <<'PY' || fail 'CI checkpoint for an unpublished head must stay pending'
import json,sys
assert 'pre-ci' in {p['operation'] for p in json.loads(sys.argv[1])['local_pending']}
PY
adapter "$tmp/codex" pre-push codex "$repo" > /dev/null 2>&1 || fail 'h4 push checkpoint must complete'
adapter "$tmp/codex" pre-ci codex batch-273 "$repo" > /dev/null 2> "$tmp/published-ci.err" || fail 'published head CI checkpoint must complete'
[ ! -s "$tmp/published-ci.err" ] || fail "published head CI check must not warn: $(cat "$tmp/published-ci.err")"
python3 - "$(adapter "$tmp/codex" view)" <<'PY' || fail 'published head clears the CI checkpoint'
import json,sys
assert not json.loads(sys.argv[1])['local_pending']
PY
pass 'CI checkpoint refuses a worktree HEAD that differs from the published head'

adapter "$tmp/codex" pre-ci codex > /dev/null 2> "$tmp/no-wt-ci.err" || fail "pre-ci without a worktree must use the recorded worktree: $(cat "$tmp/no-wt-ci.err")"
[ ! -s "$tmp/no-wt-ci.err" ] || fail "pre-ci with a recorded worktree must not warn: $(cat "$tmp/no-wt-ci.err")"
if adapter "$tmp/offline" pre-ci offline > /dev/null 2> "$tmp/no-wt-refuse.err"; then fail 'pre-ci without any worktree must refuse'; fi
case "$(cat "$tmp/no-wt-refuse.err")" in *'no recorded worktree'*) ;; *) fail "pre-ci refusal must name the missing worktree: $(cat "$tmp/no-wt-refuse.err")" ;; esac
pass 'pre-ci TASK falls back to the recorded worktree and refuses when none is recorded'

python3 - "$tmp/codex/state/fm-coord-adapter.json" <<'PY'
import json,sys
path=sys.argv[1]
state=json.load(open(path))
state['tasks']['codex'].pop('worktree')
state['tasks']['codex']['pending_ci']=True
json.dump(state,open(path,'w'))
PY
adapter "$tmp/codex" replay > /dev/null 2> "$tmp/legacy-ci.err" || fail "replay of a pending pre-ci without a worktree must complete: $(cat "$tmp/legacy-ci.err")"
case "$(cat "$tmp/legacy-ci.err")" in *'no recorded worktree'*) ;; *) fail 'replay must warn about a pending pre-ci without a worktree' ;; esac
adapter "$tmp/codex" pre-ci codex batch-297 "$repo" > /dev/null 2>&1 || fail 'pre-ci with a worktree must clear the legacy checkpoint'
pass 'replay skips a legacy pending pre-ci that has no worktree'

h4=$(git -C "$repo" rev-parse HEAD)
printf 'h5\n' > "$repo/src/codex.py"
git -C "$repo" commit -qam h5
h5=$(git -C "$repo" rev-parse HEAD)
adapter "$tmp/codex" pre-push codex "$repo" > /dev/null 2>&1 || fail 'h5 push checkpoint must complete'
python3 - "$tmp/codex/state/fm-coord-adapter.json" "$h4" "$h5" <<'PY'
import json,sys
path,h4,h5=sys.argv[1:]
state=json.load(open(path))
state['requests']['codex:head:'+h4+':'+h5].pop('reply')
state['tasks']['codex']['published_head']=h4
json.dump(state,open(path,'w'))
PY
git -C "$repo" reset -q --hard "$h4"
adapter "$tmp/codex" pre-ci codex batch-314 "$repo" > /dev/null 2> "$tmp/lost-head-ci.err" || fail 'stale-cache CI checkpoint stays advisory'
case "$(cat "$tmp/lost-head-ci.err")" in *'is not the published head'*) ;; *) fail 'CI checkpoint must compare against the central published head, not a stale local cache' ;; esac
git -C "$repo" reset -q --hard "$h5"
adapter "$tmp/codex" pre-push codex "$repo" > /dev/null 2>&1 || fail 'h5 republish checkpoint must complete'
adapter "$tmp/codex" pre-ci codex batch-318 "$repo" > /dev/null 2> "$tmp/h5-ci.err" || fail 'central head CI checkpoint must complete'
python3 - "$(adapter "$tmp/codex" view)" "$h5" <<'PY' || fail "central head refresh must clear CI and the lost publish request: $(cat "$tmp/h5-ci.err")"
import json,sys
view=json.loads(sys.argv[1])
assert not view['local_pending'], view['local_pending']
assert view['local_tasks']['codex']['published_head']==sys.argv[2]
PY
pass 'CI checkpoint compares HEAD with the central published head after a lost publish reply'

python3 - "$tmp/codex/state/fm-coord-adapter.json" <<'PY'
import json,sys
path=sys.argv[1]
state=json.load(open(path))
state['tasks']['codex']['claim']['fence']+=1
json.dump(state,open(path,'w'))
PY
adapter "$tmp/codex" pre-ci codex batch-stale "$repo" > /dev/null 2> "$tmp/stale.err" || fail 'stale writer stays advisory'
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
adapter "$tmp/claude" heartbeat claude > /dev/null 2>&1 || fail 'post-reboot checkpoint must complete'
adapter "$tmp/claude" heartbeat claude > /dev/null 2> "$tmp/reboot-ci.err" || fail 'recovered checkpoint must complete'
[ ! -s "$tmp/reboot-ci.err" ] || fail "recovered writer must check cleanly: $(cat "$tmp/reboot-ci.err")"
python3 - "$tmp/claude/state/fm-coord-adapter.json" <<'PY' || fail 'coordinator reboot must recover through a fresh session'
import json,sys
tasks=json.load(open(sys.argv[1]))['tasks']
assert tasks['claude-b']['claim']['ok'] is True
assert tasks['claude']['claim']['ok'] is True
PY
pass 'coordinator reboot starts a fresh session and resubmits local intents'

db=$tmp/central/attempt.sqlite3
coord init > /dev/null
coord manifest-set '{"request_id":"manifest-attempt","repo":"owner/repo","base":"main","checks":["Lint"]}' > /dev/null
head=$(git -C "$repo" rev-parse HEAD)
# Prepare TASK in HOME up to awaiting-checks with the adapter's own claim, PR number $3; prints the slot generation.
prepare_slot() {
  local state claim generation base_oid common slot
  state=$tmp/$1/state/fm-coord-adapter.json
  claim=$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); t=s["tasks"][sys.argv[2]]; print("\"intent_id\":\"%s\",\"home_id\":\"%s\",\"generation\":%s,\"claim_id\":\"%s\",\"fence\":%s" % (t["intent_id"], sys.argv[2], s["requests"]["session"]["reply"]["generation"], t["claim"]["claim_id"], t["claim"]["fence"]))' "$state" "$1")
  base_oid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][sys.argv[2]]["base_oid"])' "$state" "$1")
  coord attach-pr "{\"request_id\":\"pr-$1\",$claim,\"pr_url\":\"https://github.com/owner/repo/pull/$2\"}" > /dev/null
  coord publish-head "{\"request_id\":\"head-$1\",$claim,\"head_oid\":\"$head\",\"expected_previous_oid\":null}" > /dev/null
  coord queue-ready "{\"request_id\":\"ready-$1\",$claim,\"head_oid\":\"$head\",\"priority\":0}" > /dev/null
  slot=$(field "$(coord queue-next "{\"request_id\":\"next-$1\",\"repo\":\"owner/repo\",\"base\":\"main\"}")" generation)
  common="$claim,\"slot_generation\":$slot,\"current_head_oid\":\"$head\",\"current_base_oid\":\"$base_oid\""
  coord queue-synced "{\"request_id\":\"sync-$1\",$common,\"head_contains_base\":true}" > /dev/null
  coord queue-validated "{\"request_id\":\"validate-$1\",$common,\"validation_passed\":true,\"validation_id\":\"v-$1\"}" > /dev/null
  coord queue-checks "{\"request_id\":\"checks-$1\",$common,\"protection_available\":false,\"checks\":[{\"name\":\"Lint\",\"head_oid\":\"$head\",\"conclusion\":\"success\"}]}" > /dev/null
  printf '{"slot_generation":%s,"current_head_oid":"%s","current_base_oid":"%s","head_contains_base":true,"captain_hold_released":true,"away_merge_allowed":true,"merge_authorized":true' "$slot" "$head" "$base_oid"
}
host_of() { coord inspect '{}' | python3 -c 'import json,sys; print({p["home_id"]: p["host_id"] for p in json.load(sys.stdin)["participants"]}[sys.argv[1]])' "$1"; }

make_home upgraded
make_brief upgraded upgraded 201
adapter "$tmp/upgraded" dispatch upgraded "$repo" "$repo" "$tmp/upgraded.brief" branch/upgraded claude > /dev/null 2>&1 || fail 'pre-migration dispatch must complete'
gates=$(prepare_slot upgraded 201)
# Simulate a v4 database whose binding is not the coordinator hostname, then upgrade it: migration 005 clears that host ID.
sqlite3 "$db" "UPDATE participants SET host_id='pre-migration-hostname' WHERE home_id='upgraded'; DROP TABLE ci_heads; DROP TABLE ci_capacity; DROP TABLE fenced_ci_batches; DROP TABLE ci_batches; PRAGMA user_version=4;"
coord init > /dev/null
[ "$(host_of upgraded)" = None ] || fail 'migration must keep treating a non-hostname v4 binding as untrusted'
sleep 600 &
wrapper=$!
attempted=$(adapter "$tmp/upgraded" attempt upgraded "$gates,\"wrapper_pid\":$wrapper}" 2> "$tmp/upgraded-attempt.err") || fail "upgraded attempt must complete: $(cat "$tmp/upgraded-attempt.err")"
kill "$wrapper"
wait "$wrapper" 2> /dev/null || true
[ "$(field "$attempted" state)" = attempting ] || fail "a home with cached enrollment must re-enroll once and record its attempt after migration: $(cat "$tmp/upgraded-attempt.err")"
case "$(host_of upgraded)" in machine:*) ;; *) fail 'the retried enrollment must bind the home machine identity' ;; esac
pass 'a cached enrollment cleared by migration re-enrolls once and retries the merge attempt'

db=$tmp/central/far.sqlite3
coord init > /dev/null
coord manifest-set '{"request_id":"manifest-far","repo":"owner/repo","base":"main","checks":["Lint"]}' > /dev/null
make_home far
make_brief far far 202
# The journaled enrollment stands in for a home on another machine.
printf '{"requests":{"enroll":{"op":"enroll","payload":{"home_id":"far","repos":["owner/repo"],"host_id":"far-test-host","request_id":"enroll-far"}}},"tasks":{}}\n' > "$tmp/far/state/fm-coord-adapter.json"
adapter "$tmp/far" dispatch far "$repo" "$repo" "$tmp/far.brief" branch/far codex > /dev/null 2>&1 || fail 'remote-host dispatch must complete'
gates=$(prepare_slot far 202)
sleep 600 &
wrapper=$!
attempted=$(adapter "$tmp/far" attempt far "$gates,\"wrapper_pid\":$wrapper}") || fail 'remote-host attempt must complete'
attempt_id=$(field "$attempted" attempt_event_id)
start=$(coord inspect '{}' | python3 -c 'import json,sys; print([q for q in json.load(sys.stdin)["queue"] if q["intent_id"]=="far:owner/repo:far"][0]["wrapper_start"])')
slot=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["slot_generation"])' "$gates}")
coord queue-result "{\"request_id\":\"result-far\",\"intent_id\":\"far:owner/repo:far\",\"generation\":$slot,\"outcome\":\"unknown\"}" > /dev/null
exit_fields="{\"slot_generation\":$slot,\"attempt_event_id\":\"$attempt_id\",\"wrapper_host_id\":\"far-test-host\",\"wrapper_pid\":$wrapper,\"wrapper_start\":\"$start\"}"
if adapter "$tmp/far" wrapper-exited far "$exit_fields" > /dev/null 2> "$tmp/far-exit.err"; then fail 'the adapter must refuse to attest while its wrapper process runs'; fi
case "$(cat "$tmp/far-exit.err")" in *'still running'*) ;; *) fail 'a running wrapper refusal must say so' ;; esac
kill "$wrapper"
wait "$wrapper" 2> /dev/null || true
exited=$(adapter "$tmp/far" wrapper-exited far "$exit_fields" 2> "$tmp/far-exit.err") || fail "the adapter must attest an exited wrapper: $(cat "$tmp/far-exit.err")"
[ "$(field "$exited" state)" = outcome-unknown ] || fail 'an attested exit must still wait for forge non-landing proof'
coord outbox '{"limit":1000}' | python3 -c 'import json,sys; assert any(e["type"]=="wrapper-exit-attested" and e["payload"]["host_id"]=="far-test-host" for e in json.load(sys.stdin)["events"])' || fail 'the exit attestation must be recorded for the remote host'
pass 'remote wrapper exit is attested by the participant adapter after its own host check'

db=$tmp/central/restarted.sqlite3
coord init > /dev/null
coord manifest-set '{"request_id":"manifest-restarted","repo":"owner/repo","base":"main","checks":["Lint"]}' > /dev/null
make_home restarted
make_brief restarted restarted 203
printf '{"requests":{"enroll":{"op":"enroll","payload":{"home_id":"restarted","repos":["owner/repo"],"host_id":"restarted-test-host","request_id":"enroll-restarted"}}},"tasks":{}}\n' > "$tmp/restarted/state/fm-coord-adapter.json"
adapter "$tmp/restarted" dispatch restarted "$repo" "$repo" "$tmp/restarted.brief" branch/restarted codex > /dev/null 2>&1 || fail 'restart-case dispatch must complete'
gates=$(prepare_slot restarted 203)
sleep 600 &
wrapper=$!
attempted=$(adapter "$tmp/restarted" attempt restarted "$gates,\"wrapper_pid\":$wrapper}") || fail 'restart-case attempt must complete'
attempt_id=$(field "$attempted" attempt_event_id)
start=$(coord inspect '{}' | python3 -c 'import json,sys; print([q for q in json.load(sys.stdin)["queue"] if q["intent_id"]=="restarted:owner/repo:restarted"][0]["wrapper_start"])')
slot=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["slot_generation"])' "$gates}")
coord queue-result "{\"request_id\":\"result-restarted\",\"intent_id\":\"restarted:owner/repo:restarted\",\"generation\":$slot,\"outcome\":\"unknown\"}" > /dev/null
sqlite3 "$db" "UPDATE meta SET value='previous-boot' WHERE key='boot_id'"
# Every checkpoint after the restart must start fresh session requests instead of reusing the attempt's old submit.
for checkpoint in "heartbeat restarted" "pre-push restarted $repo" "pre-ci restarted batch-616 $repo"; do
  # shellcheck disable=SC2086
  adapter "$tmp/restarted" $checkpoint > /dev/null 2> "$tmp/restarted-checkpoint.err" || fail "$checkpoint after the restart must complete: $(cat "$tmp/restarted-checkpoint.err")"
  case "$(cat "$tmp/restarted-checkpoint.err")" in *'changed payload'*) fail "$checkpoint must not reuse a request from the old session" ;; esac
done
python3 - "$tmp/restarted/state/fm-coord-adapter.json" <<'PY' || fail 'the restarted task must hold a fresh claim while its attempt identity is kept'
import json,sys
task=json.load(open(sys.argv[1]))['tasks']['restarted']
assert task['claim']['ok'] is True and task['intent_id'] != 'restarted:owner/repo:restarted'
assert task['attempt']['intent_id'] == 'restarted:owner/repo:restarted'
assert 'pending_ci' not in task and 'pending_head' not in task
PY
# A fresh dispatch from a new start commit submits a fresh intent while the attempt is still unreported.
git -C "$repo" worktree add -q --detach "$tmp/restarted-wt"
git -C "$tmp/restarted-wt" commit -q --allow-empty -m restarted-start
adapter "$tmp/restarted" dispatch restarted "$repo" "$tmp/restarted-wt" "$tmp/restarted.brief" branch/restarted codex > /dev/null 2> "$tmp/restarted-dispatch.err" || fail "a changed start commit must dispatch: $(cat "$tmp/restarted-dispatch.err")"
python3 - "$tmp/restarted/state/fm-coord-adapter.json" "$(git -C "$tmp/restarted-wt" rev-parse HEAD)" <<'PY' || fail 'a changed start commit must get a fresh submit request'
import json,sys
state=json.load(open(sys.argv[1]))
task=state['tasks']['restarted']
assert task['claim']['ok'] is True and task['base_oid'] == sys.argv[2]
assert state['requests']['restarted:submit']['payload']['base_oid'] == sys.argv[2]
assert task['attempt']['intent_id'] == 'restarted:owner/repo:restarted'
PY
kill "$wrapper"
wait "$wrapper" 2> /dev/null || true
exit_fields="{\"slot_generation\":$slot,\"attempt_event_id\":\"$attempt_id\",\"wrapper_host_id\":\"restarted-test-host\",\"wrapper_pid\":$wrapper,\"wrapper_start\":\"$start\"}"
exited=$(adapter "$tmp/restarted" wrapper-exited restarted "$exit_fields" 2> "$tmp/restarted-exit.err") || fail "a restarted coordinator must accept the exit of the unsettled attempt: $(cat "$tmp/restarted-exit.err")"
[ "$(field "$exited" state)" = outcome-unknown ] || fail "the exit must be reported against the recorded attempt: $(cat "$tmp/restarted-exit.err")"
# Lose that reply across another restart: the retry reuses the attempt-keyed request ID from a new session.
python3 - "$tmp/restarted/state/fm-coord-adapter.json" "$attempt_id" <<'PY'
import json,sys
path=sys.argv[1]
state=json.load(open(path))
state['requests']['restarted:exit:'+sys.argv[2]].pop('reply')
state['tasks']['restarted']['attempt']={'attempt_event_id':sys.argv[2],'intent_id':'restarted:owner/repo:restarted'}
json.dump(state,open(path,'w'))
PY
sqlite3 "$db" "UPDATE meta SET value='previous-boot' WHERE key='boot_id'"
again=$(adapter "$tmp/restarted" wrapper-exited restarted "$exit_fields" 2> "$tmp/restarted-exit.err") || fail "a lost exit reply must be recovered after a restart: $(cat "$tmp/restarted-exit.err")"
[ "$(field "$again" event_id)" = "$(field "$exited" event_id)" ] || fail 'the retried exit must return the original receipt'
mkdir -p "$tmp/forge"
cat > "$tmp/forge/gh-axi" <<'GH'
#!/usr/bin/env bash
case "$3" in
  */pulls/*) printf 'api_response:\n  body: "https://github.com/owner/repo/pull/%s|open|false|%s|main|null"\n  truncated: false\n' "${3##*/}" "$FM_TEST_HEAD" ;;
  graphql) printf 'api_response:\n  body: false|none\n  truncated: false\n' ;;
  */git/ref/heads/main) printf 'api_response:\n  body: %s\n  truncated: false\n' "$FM_TEST_BASE_OID" ;;
  */compare/*) printf 'api_response:\n  body: ahead\n  truncated: false\n' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$tmp/forge/gh-axi"
settled=$(PATH="$tmp/forge:$PATH" FM_COORD_QUIET_SECONDS=0 FM_TEST_HEAD="$head" FM_TEST_BASE_OID="$(printf 'b%.0s' $(seq 40))" coord queue-reconcile "{\"request_id\":\"reconcile-restarted\",\"intent_id\":\"restarted:owner/repo:restarted\",\"generation\":$slot,\"pr_url\":\"https://github.com/owner/repo/pull/203\",\"base\":\"main\",\"head_oid\":\"$head\"}") || fail 'the attested exit must let reconciliation settle the slot'
[ "$(field "$settled" state)" = refused ] || fail 'a not-landed attempt must settle without an operator step'
coord inspect '{}' | python3 -c 'import json,sys; assert not json.load(sys.stdin)["slots"]' || fail 'the settled attempt must release the integration slot'
pass 'a coordinator restart during a remote attempt keeps its identity so the exit settles the slot'

db=$tmp/central/widened.sqlite3
coord init > /dev/null
make_home widened
make_brief widened widened 301
git -C "$repo" worktree add -q --detach "$tmp/widened-wt" origin/main
adapter "$tmp/widened" dispatch widened "$repo" "$tmp/widened-wt" "$tmp/widened.brief" branch/widened codex > /dev/null 2>&1 || fail 'widened dispatch must complete'
printf 'amended\n' > "$tmp/widened-wt/src/amended.py"
git -C "$tmp/widened-wt" add src/amended.py
git -C "$tmp/widened-wt" commit -qm amended
adapter "$tmp/widened" pre-push widened "$tmp/widened-wt" > /dev/null 2>&1 || fail 'widened amendment push must complete'
sqlite3 "$db" "UPDATE meta SET value='previous-boot' WHERE key='boot_id'"
# Work committed after the restart but before the next checkpoint is in flight too.
printf 'late\n' > "$tmp/widened-wt/src/late.py"
git -C "$tmp/widened-wt" add src/late.py
git -C "$tmp/widened-wt" commit -qm late
adapter "$tmp/widened" heartbeat widened > /dev/null 2> "$tmp/widened-hb.err" || fail "post-restart heartbeat must recover: $(cat "$tmp/widened-hb.err")"
python3 - "$tmp/widened/state/fm-coord-adapter.json" <<'PY' || fail 'the restarted task must hold a replacement claim'
import json,sys
assert json.load(open(sys.argv[1]))['tasks']['widened']['claim']['ok'] is True
PY
for path in amended late; do
  make_home "intruder-$path"
  make_brief "intruder-$path" "$path" "302-$path"
  adapter "$tmp/intruder-$path" dispatch "intruder-$path" "$repo" "$repo" "$tmp/intruder-$path.brief" "branch/intruder-$path" claude > /dev/null 2> "$tmp/intruder.err" || fail 'intruder dispatch stays advisory'
  case "$(cat "$tmp/intruder.err")" in *'held by widened'*) ;; *) fail "the replacement claim must still cover src/$path.py: $(cat "$tmp/intruder.err")" ;; esac
done
pass 'a replacement claim after a restart keeps amended scope and in-flight worktree paths'
