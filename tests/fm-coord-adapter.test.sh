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
adapter "$tmp/offline" dispatch offline "$repo" "$tmp/offline.brief" branch/offline codex > "$tmp/offline.out" 2> "$tmp/offline.err" || fail 'offline dispatch must stay advisory'
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
  adapter "$tmp/$harness" dispatch "$harness" "$repo" "$tmp/$harness.brief" "branch/$harness" "$harness" > /dev/null 2> "$tmp/$harness.err" || fail "$harness dispatch must complete"
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
adapter "$tmp/missing-adapter" dispatch missing-adapter "$repo" "$tmp/missing-adapter.brief" branch/missing cursor > /dev/null 2> "$tmp/missing-adapter.err" || fail 'missing harness adapter remains advisory'
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
PATH="$tmp/sshbin:$PATH" adapter "$tmp/remote-home" dispatch remote-home "$repo" "$tmp/remote-home.brief" branch/remote codex > /dev/null 2> "$tmp/remote.err" || fail 'remote transport must dispatch'
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
PATH="$tmp/sshdown:$PATH" adapter "$tmp/remote-offline" dispatch remote-offline "$repo" "$tmp/remote-offline.brief" branch/offline-remote opencode > /dev/null 2> "$tmp/remote-offline.err" || fail 'offline remote dispatch remains advisory'
case "$(cat "$tmp/remote-offline.err")" in *'no claim granted'*) ;; *) fail 'offline SSH participant must warn no grant' ;; esac
PATH="$tmp/sshbin:$PATH" adapter "$tmp/remote-offline" replay > /dev/null 2> "$tmp/remote-replay.err" || fail 'offline remote replay must complete'
python3 - "$tmp/remote-offline/state/fm-coord-adapter.json" <<'PY' || fail 'remote replay must obtain central grant'
import json,sys
assert json.load(open(sys.argv[1]))['tasks']['remote-offline']['claim']['ok'] is True
PY
pass 'remote outage journals intent and replays after the authority returns'

make_home challenger
make_brief challenger base 99
adapter "$tmp/challenger" dispatch challenger "$repo" "$tmp/challenger.brief" branch/challenger claude > /dev/null 2> "$tmp/conflict.err" || fail 'conflict remains advisory'
case "$(cat "$tmp/conflict.err")" in *'held by offline'*) ;; *) fail 'conflict must name holder' ;; esac
pass 'pre-dispatch conflict names current holder'

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
fm_test_spawn_brief "$spawn_home" spawned
printf 'Coordination resources: [{"type":"file","name":"README.md"}]\n' >> "$spawn_home/data/spawned/brief.md"
printf '{"mode":"advisory","home_id":"spawn-home","repos":["owner/repo"],"db":"%s","project_repos":{"%s":"owner/repo"}}\n' "$db" "$spawn_repo" > "$spawn_home/config/coordination.json"
fakebin=$(fm_test_make_spawn_fakebin "$tmp/spawn-fake")
fm_test_run_spawn "$spawn_home" "$spawn_wt" "$fakebin" spawned "$spawn_repo" --mode direct-PR --yolo off --harness codex > "$tmp/spawn.out" || fail 'configured spawn must remain operational'
python3 - "$spawn_home/state/fm-coord-adapter.json" "$spawn_home/data/spawned/launch-brief.md" <<'PY' || fail 'spawn must submit intent and render worker checkpoints'
import json,sys
state=json.load(open(sys.argv[1]))
brief=open(sys.argv[2]).read()
assert state['tasks']['spawned']['claim']['ok'] is True
assert 'pre-push' in brief and 'pre-ci' in brief and 'heartbeat' in brief
PY
pass 'spawn submits declared resources and projects the same adapter into worker brief'
