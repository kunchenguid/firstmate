#!/usr/bin/env bash
# Public-interface tests for opt-in per-repository CI admission capacity.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(fm_test_tmproot fm-coord-ci-capacity)
db=$tmp/coord.sqlite3
coord() { "$ROOT/bin/fm-coord.sh" --db "$db" "$@"; }
coord init > /dev/null

# Four runners, 71 immutable heads: drive the coordinator through its command line.
python3 - "$ROOT/bin/fm-coord.sh" "$db" <<'PY' || fail 'four-runner capacity must admit 71 heads one at a time as slots complete'
import json, subprocess, sys
cmd, db = sys.argv[1], sys.argv[2]
def coord(op, payload, ok=True):
    run = subprocess.run([cmd, "--db", db, op, json.dumps(payload)], capture_output=True, text=True)
    assert (run.returncode == 0) == ok, (op, payload, run.stderr)
    return json.loads(run.stdout) if ok else run.stderr
def authorized():
    events = coord("outbox", {"limit": 1000})["events"]
    return [e["payload"]["batch_id"] for e in events if e["type"] == "ci-pulse-authorized"]
def heads(state):
    return [h["batch_id"] for h in coord("inspect", {})["ci_heads"] if h["state"] == state]
coord("enroll", {"request_id": "enroll-h", "home_id": "h", "repos": ["owner/repo", "owner/other"]})
gen = coord("session", {"request_id": "session-h", "home_id": "h"})["generation"]
live = {}
def intent(i, repo="owner/repo"):
    name = f"ci-{i}"
    coord("submit", {"request_id": f"submit-{name}", "intent_id": name, "home_id": "h", "generation": gen, "repo": repo, "base": "main", "base_oid": "0" * 40, "branch": f"branch/{name}", "task_id": name, "goal": "ci", "resources": [{"type": "file", "name": f"src/{name}.py"}]})
    grant = coord("claim", {"request_id": f"claim-{name}", "intent_id": name, "home_id": "h", "generation": gen, "version": 1})
    owner = {"home_id": "h", "generation": gen, "claim_id": grant["claim_id"], "fence": grant["fence"], "intent_id": name}
    head = f"{i:040x}"
    coord("publish-head", {**owner, "request_id": f"head-{name}", "head_oid": head, "expected_previous_oid": None})
    live[name] = (owner, head)
def pulse(name, batch, request_id):
    owner, head = live[name]
    return coord("pulse-batch", {**owner, "request_id": request_id, "head_oid": head, "batch_id": batch})
def complete(batch, conclusion, request_id, ok=True):
    owner, head = live[batch]
    return coord("ci-complete", {"request_id": request_id, "repo": "owner/repo", "base": "main", "head_oid": head, "conclusion": conclusion}, ok)

# Off by default: with no configured capacity every head is admitted at once.
for i in range(1, 6):
    intent(i, "owner/other")
    assert pulse(f"ci-{i}", f"ci-{i}", f"pulse-ci-{i}")["admitted"] is True
assert len(authorized()) == 5 and heads("active") == [] and heads("queued") == []

coord("ci-capacity-set", {"request_id": "capacity", "repo": "owner/repo", "base": "main", "capacity": 4})
for i in range(6, 77):
    intent(i)
replies = [pulse(f"ci-{i}", f"ci-{i}", f"pulse-ci-{i}") for i in range(6, 77)]
assert [r["admitted"] for r in replies] == [True] * 4 + [False] * 67
assert heads("active") == [f"ci-{i}" for i in range(6, 10)] and len(heads("queued")) == 67

# A lost reply replays its receipt; neither a replay nor a new request pulses a head twice.
assert pulse("ci-6", "ci-6", "pulse-ci-6") == replies[0]
assert pulse("ci-6", "ci-6", "pulse-ci-6-again") == {"ok": False, "reason": "batch-already-pulsed", "event_id": replies[0]["event_id"]}
assert pulse("ci-6", "ci-6-rerun", "pulse-ci-6-rerun")["reason"] == "head-already-admitted"
assert pulse("ci-10", "ci-10", "pulse-ci-10-poll")["admitted"] is False
assert len(authorized()) == 9

# Red-proof: a head whose run is red keeps its slot until the run reaches a terminal state.
owner, _ = live["ci-6"]
coord("release", {"request_id": "release-ci-6", **{k: owner[k] for k in ("home_id", "generation", "claim_id", "fence")}})
complete("ci-6", "red", "complete-ci-6-red", ok=False)
assert heads("active") == [f"ci-{i}" for i in range(6, 10)] and len(authorized()) == 9

# Terminal completion releases the slot and admits the next immutable head exactly once.
done = complete("ci-6", "failure", "complete-ci-6")
assert done["admitted"] == ["ci-10"], done
assert complete("ci-6", "failure", "complete-ci-6") == done
complete("ci-6", "failure", "complete-ci-6-again", ok=False)
assert pulse("ci-10", "ci-10", "pulse-ci-10-admitted")["admitted"] is True
assert pulse("ci-10", "ci-10", "pulse-ci-10-duplicate")["reason"] == "batch-already-pulsed"

order = ["ci-7", "ci-8", "ci-9", "ci-10"]
step = 0
while order:
    batch = order.pop(0)
    done = complete(batch, ("success", "failure", "cancelled")[step % 3], f"complete-{batch}")
    order.extend(done["admitted"])
    assert len(done["admitted"]) <= 1 and len(heads("active")) <= 4
    step += 1
granted = authorized()
assert len(granted) == 76 and len(set(granted)) == 76, len(granted)
assert granted[5:] == [f"ci-{i}" for i in range(6, 77)]
assert heads("active") == [] and heads("queued") == []
PY
pass 'four runners admit 71 immutable heads in order, each once, holding a red head until terminal completion'

# Adapter: an enforced worker whose batch is queued stops its CI request until the coordinator admits it.
repo=$tmp/repo
mkdir -p "$repo/src"
git -C "$repo" init -q -b main
git -C "$repo" remote add origin git@github.com:owner/gated.git
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m base
git -C "$repo" update-ref refs/remotes/origin/main HEAD
adapter() { FM_HOME=$1 python3 "$ROOT/bin/fm-coord-adapter.py" "${@:2}"; }
for name in x y; do
  mkdir -p "$tmp/$name/config"
  printf '{"mode":"shadow","home_id":"%s","repos":["owner/gated"],"enforce_repos":["owner/gated"],"db":"%s"}\n' "$name" "$db" > "$tmp/$name/config/coordination.json"
  printf 'Coordination resources: [{"type":"file","name":"src/%s.py"}]\n' "$name" > "$tmp/$name.brief"
  adapter "$tmp/$name" dispatch "$name" "$repo" "$repo" "$tmp/$name.brief" "branch/$name" codex > /dev/null || fail "$name dispatch must be admitted"
done
coord ci-capacity-set '{"request_id":"capacity-gated","repo":"owner/gated","base":"main","capacity":1}' > /dev/null
adapter "$tmp/x" pre-push x "$repo" > /dev/null || fail 'x must publish its head'
adapter "$tmp/x" pre-ci x batch-x "$repo" > /dev/null || fail 'the first head must take the free CI slot'
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m y
adapter "$tmp/y" pre-push y "$repo" > /dev/null || fail 'y must publish its head'
if adapter "$tmp/y" pre-ci y batch-y "$repo" > /dev/null 2> "$tmp/err"; then
  fail 'an enforced head queued behind a full CI capacity must not pulse'
fi
grep -q 'queued for CI capacity at position 1' "$tmp/err" || fail "a queued batch must say so: $(cat "$tmp/err")"
if adapter "$tmp/y" pre-ci y batch-y "$repo" > /dev/null 2> "$tmp/err"; then
  fail 'a queued batch must stay refused until a slot completes'
fi
head_x=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"]["x"]["published_head"])' "$tmp/x/state/fm-coord-adapter.json")
coord ci-complete "$(printf '{"request_id":"complete-x","repo":"owner/gated","base":"main","head_oid":"%s","conclusion":"failure"}' "$head_x")" > /dev/null
# The poll after admission lost its reply; replay then receives the authorization.
python3 - "$tmp/y/state/fm-coord-adapter.json" <<'PY'
import json,sys
path=sys.argv[1]
state=json.load(open(path))
task=state['tasks']['y']
live={'home_id':'y','generation':state['requests']['session']['reply']['generation'],'claim_id':task['claim']['claim_id'],'fence':task['claim']['fence']}
state['requests']['y:pulse:batch-y']={'op':'pulse-batch','payload':{**live,'intent_id':task['intent_id'],'head_oid':task['published_head'],'batch_id':'batch-y','request_id':'lost-poll'}}
task['pending_ci']='batch-y'
json.dump(state,open(path,'w'))
PY
adapter "$tmp/y" replay > /dev/null 2>&1 || fail 'replay must resend the lost CI poll'
adapter "$tmp/y" pre-ci y batch-y "$repo" > /dev/null 2> "$tmp/err" || fail "an admitted batch whose authorization reached replay must still authorize its pulse: $(cat "$tmp/err")"
if adapter "$tmp/y" pre-ci y batch-y "$repo" > /dev/null 2> "$tmp/err"; then
  fail 'an admitted batch must not pulse twice'
fi
python3 - "$(coord outbox '{"limit":1000}')" "$(adapter "$tmp/y" view)" <<'PY' || fail 'the queued batch must be authorized exactly once and clear its CI checkpoint'
import json,sys
events=[e['payload']['batch_id'] for e in json.loads(sys.argv[1])['events'] if e['type']=='ci-pulse-authorized' and e['payload']['repo']=='owner/gated']
assert events==['batch-x','batch-y'], events
assert not json.loads(sys.argv[2])['local_tasks']['y'].get('pending_ci')
PY
pass 'an enforced worker queued for CI capacity pulses once after the slot ahead completes'

# Recovery from an older backup must not admit and pulse again a head promoted after that backup.
python3 - "$ROOT/bin/fm-coord.sh" "$db" "$tmp/older.sqlite3" <<'PY' || fail 'fenced recovery must not re-admit a head promoted after the backup'
import json, sqlite3, subprocess, sys
cmd, db, older = sys.argv[1:4]
def coord(op, payload):
    run = subprocess.run([cmd, "--db", db, op, json.dumps(payload)], capture_output=True, text=True)
    assert run.returncode == 0, (op, run.stderr)
    return json.loads(run.stdout)
coord("enroll", {"request_id": "enroll-r", "home_id": "r", "repos": ["owner/rec"]})
gen = coord("session", {"request_id": "session-r", "home_id": "r"})["generation"]
coord("ci-capacity-set", {"request_id": "capacity-rec", "repo": "owner/rec", "base": "main", "capacity": 1})
for i in (1, 2):
    name = f"rec-{i}"
    coord("submit", {"request_id": f"submit-{name}", "intent_id": name, "home_id": "r", "generation": gen, "repo": "owner/rec", "base": "main", "base_oid": "0" * 40, "branch": f"branch/{name}", "task_id": name, "goal": "ci", "resources": [{"type": "file", "name": f"src/{name}.py"}]})
    grant = coord("claim", {"request_id": f"claim-{name}", "intent_id": name, "home_id": "r", "generation": gen, "version": 1})
    owner = {"home_id": "r", "generation": gen, "claim_id": grant["claim_id"], "fence": grant["fence"], "intent_id": name}
    coord("publish-head", {**owner, "request_id": f"head-{name}", "head_oid": f"e{i:039x}", "expected_previous_oid": None})
    coord("pulse-batch", {**owner, "request_id": f"pulse-{name}", "head_oid": f"e{i:039x}", "batch_id": name})
with sqlite3.connect(db) as source, sqlite3.connect(older) as target:
    source.backup(target)
assert coord("ci-complete", {"request_id": "complete-rec-1", "repo": "owner/rec", "base": "main", "head_oid": f"e{1:039x}", "conclusion": "success"})["admitted"] == ["rec-2"]
subprocess.run(["mv", older, db], check=True)
coord("recover", {"confirm": "FENCE_AND_REENROLL"})
assert [h["batch_id"] for h in coord("inspect", {})["ci_heads"] if h["repo"] == "owner/rec"] == ["rec-1"]
assert coord("ci-complete", {"request_id": "complete-rec-1-restored", "repo": "owner/rec", "base": "main", "head_oid": f"e{1:039x}", "conclusion": "success"})["admitted"] == []
events = coord("outbox", {"limit": 1000})["events"]
assert sum(e["type"] == "ci-pulse-authorized" and e["payload"]["batch_id"] == "rec-2" for e in events) == 0
PY
pass 'fenced recovery never re-admits a CI head promoted after the backup'
