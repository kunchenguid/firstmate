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
def complete(name, conclusion, request_id, ok=True, batch=None):
    owner, head = live[name]
    return coord("ci-complete", {"request_id": request_id, "repo": "owner/repo", "base": "main", "head_oid": head, "batch_id": batch or name, "conclusion": conclusion}, ok)

# Off by default: with no configured capacity every head is admitted at once.
for i in range(1, 6):
    intent(i, "owner/other")
    assert pulse(f"ci-{i}", f"ci-{i}", f"pulse-ci-{i}")["admitted"] is True
assert len(authorized()) == 5 and heads("active") == [] and heads("queued") == []

coord("ci-capacity-set", {"request_id": "capacity", "repo": "owner/repo", "capacity": 4})
for i in range(6, 77):
    intent(i)
replies = [pulse(f"ci-{i}", f"ci-{i}", f"pulse-ci-{i}") for i in range(6, 77)]
assert [r["admitted"] for r in replies] == [True] * 4 + [False] * 67
assert heads("active") == [f"ci-{i}" for i in range(6, 10)] and len(heads("queued")) == 67

# A lost reply replays its receipt; neither a replay nor a new request pulses a head twice.
assert pulse("ci-6", "ci-6", "pulse-ci-6") == replies[0]
assert pulse("ci-6", "ci-6", "pulse-ci-6-again") == {"ok": False, "reason": "batch-already-pulsed", "event_id": replies[0]["event_id"]}
assert pulse("ci-6", "ci-6-rerun", "pulse-ci-6-rerun")["reason"] == "head-batch-in-flight"
assert pulse("ci-10", "ci-10", "pulse-ci-10-poll")["admitted"] is False
assert pulse("ci-10", "ci-10-rerun", "pulse-ci-10-rerun")["reason"] == "head-batch-in-flight"
complete("ci-10", "failure", "complete-ci-10-queued", ok=False)
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

# ci-8 failed and completed: a new batch ID for that immutable head is its next attempt, one batch at a time.
retry = pulse("ci-8", "ci-8-retry", "pulse-ci-8-retry")
assert retry["admitted"] is True, retry
assert pulse("ci-8", "ci-8-concurrent", "pulse-ci-8-concurrent")["reason"] == "head-batch-in-flight"
# A late completion for the earlier attempt never frees the retry's slot.
complete("ci-8", "failure", "complete-ci-8-stale", ok=False)
assert heads("active") == ["ci-8-retry"]
assert complete("ci-8", "success", "complete-ci-8-retry", batch="ci-8-retry")["released"] == "ci-8-retry"
assert heads("active") == [] and authorized()[-1] == "ci-8-retry"
PY
pass 'four runners admit 71 immutable heads in order, each once, holding a red head until terminal completion, then admit a retry attempt'

# Adapter: an enforced worker whose batch is queued stops its CI request until the coordinator admits it.
repo=$tmp/repo
mkdir -p "$repo/src"
git -C "$repo" init -q -b main
git -C "$repo" remote add origin git@github.com:owner/gated.git
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m base
git -C "$repo" update-ref refs/remotes/origin/main HEAD
adapter() { FM_HOME=$1 python3 "$ROOT/bin/fm-coord-adapter.py" "${@:2}"; }
for name in x y z; do
  mkdir -p "$tmp/$name/config"
  printf '{"mode":"shadow","home_id":"%s","repos":["owner/gated"],"enforce_repos":["owner/gated"],"db":"%s"}\n' "$name" "$db" > "$tmp/$name/config/coordination.json"
  printf 'Coordination resources: [{"type":"file","name":"src/%s.py"}]\n' "$name" > "$tmp/$name.brief"
  adapter "$tmp/$name" dispatch "$name" "$repo" "$repo" "$tmp/$name.brief" "branch/$name" codex > /dev/null || fail "$name dispatch must be admitted"
done
coord ci-capacity-set '{"request_id":"capacity-gated","repo":"owner/gated","capacity":1}' > /dev/null
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
# The worker reports its batch's terminal run through the adapter, which frees the slot without an operator.
adapter "$tmp/x" ci-complete x batch-x failure > /dev/null || fail 'the worker must complete its own batch through the adapter'
# The poll after admission lost its reply; replay then receives the authorization.
lose_poll() {
  python3 - "$tmp/$1/state/fm-coord-adapter.json" "$1" <<'PY'
import json,sys
path,name=sys.argv[1:3]
state=json.load(open(path))
task=state['tasks'][name]
live={'home_id':name,'generation':state['requests']['session']['reply']['generation'],'claim_id':task['claim']['claim_id'],'fence':task['claim']['fence']}
state['requests'][f'{name}:pulse:batch-{name}']={'op':'pulse-batch','payload':{**live,'intent_id':task['intent_id'],'head_oid':task['published_head'],'batch_id':f'batch-{name}','request_id':f'lost-poll-{name}'}}
task['pending_ci']=f'batch-{name}'
json.dump(state,open(path,'w'))
PY
  adapter "$tmp/$1" replay > /dev/null 2>&1 || fail 'replay must resend the lost CI poll'
}
lose_poll y
# A replayed authorization is never enough alone: a worktree HEAD moved off the admitted head refuses.
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m moved
if adapter "$tmp/y" pre-ci y batch-y "$repo" > /dev/null 2> "$tmp/err"; then
  fail 'a replayed CI authorization must refuse a worktree HEAD moved off the admitted head'
fi
git -C "$repo" reset -q --hard HEAD~1
adapter "$tmp/y" pre-ci y batch-y "$repo" > /dev/null 2> "$tmp/err" || fail "an admitted batch whose authorization reached replay must still authorize its pulse: $(cat "$tmp/err")"
if adapter "$tmp/y" pre-ci y batch-y "$repo" > /dev/null 2> "$tmp/err"; then
  fail 'an admitted batch must not pulse twice'
fi
coord outbox '{"limit":1000}' > "$tmp/outbox.json"
adapter "$tmp/y" view > "$tmp/view.json"
python3 - "$tmp/outbox.json" "$tmp/view.json" <<'PY' || fail 'the queued batch must be authorized exactly once and clear its CI checkpoint'
import json,sys
events=[e['payload']['batch_id'] for e in json.load(open(sys.argv[1]))['events'] if e['type']=='ci-pulse-authorized' and e['payload']['repo']=='owner/gated']
assert events==['batch-x','batch-y'], events
assert not json.load(open(sys.argv[2]))['local_tasks']['y'].get('pending_ci')
PY
pass 'an enforced worker queued for CI capacity pulses once after the slot ahead completes'

# A replayed authorization whose writer lease expired refuses until the writer is readmitted.
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m z
adapter "$tmp/z" pre-push z "$repo" > /dev/null || fail 'z must publish its head'
adapter "$tmp/z" pre-ci z batch-z "$repo" > /dev/null 2>&1 && fail 'z must queue behind the active head'
adapter "$tmp/y" ci-complete y batch-y success > /dev/null || fail 'a green batch must free its slot through the adapter'
adapter "$tmp/y" ci-complete y batch-y success > /dev/null || fail 'a repeated completion of a released batch must not fail'
adapter "$tmp/y" view > "$tmp/view.json"
python3 - "$tmp/view.json" <<'PY' || fail 'a completed batch must leave no pending local completion'
import json,sys
assert not [p for p in json.load(open(sys.argv[1]))['local_pending'] if p['operation']=='ci-complete']
PY
lose_poll z
sqlite3 "$db" "UPDATE claims SET expires_mono_ns=0 WHERE intent_id LIKE 'z:%' AND state='active'"
if adapter "$tmp/z" pre-ci z batch-z "$repo" > /dev/null 2> "$tmp/err"; then
  fail 'a replayed CI authorization must refuse once the writer lease has expired'
fi
coord outbox '{"limit":1000}' > "$tmp/outbox.json"
python3 - "$tmp/outbox.json" <<'PY' || fail 'the expired writer lease must be revoked centrally'
import json,sys
assert any(e['type']=='lease-expired' for e in json.load(open(sys.argv[1]))['events'])
PY
pass 'every pre-ci reverifies the live lease and exact admitted HEAD, including a replayed authorization'

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
coord("ci-capacity-set", {"request_id": "capacity-rec", "repo": "owner/rec", "capacity": 1})
for i in (1, 2):
    name = f"rec-{i}"
    coord("submit", {"request_id": f"submit-{name}", "intent_id": name, "home_id": "r", "generation": gen, "repo": "owner/rec", "base": "main", "base_oid": "0" * 40, "branch": f"branch/{name}", "task_id": name, "goal": "ci", "resources": [{"type": "file", "name": f"src/{name}.py"}]})
    grant = coord("claim", {"request_id": f"claim-{name}", "intent_id": name, "home_id": "r", "generation": gen, "version": 1})
    owner = {"home_id": "r", "generation": gen, "claim_id": grant["claim_id"], "fence": grant["fence"], "intent_id": name}
    coord("publish-head", {**owner, "request_id": f"head-{name}", "head_oid": f"e{i:039x}", "expected_previous_oid": None})
    coord("pulse-batch", {**owner, "request_id": f"pulse-{name}", "head_oid": f"e{i:039x}", "batch_id": name})
with sqlite3.connect(db) as source, sqlite3.connect(older) as target:
    source.backup(target)
assert coord("ci-complete", {"request_id": "complete-rec-1", "repo": "owner/rec", "base": "main", "head_oid": f"e{1:039x}", "batch_id": "rec-1", "conclusion": "success"})["admitted"] == ["rec-2"]
subprocess.run(["mv", older, db], check=True)
coord("recover", {"confirm": "FENCE_AND_REENROLL"})
assert [h["batch_id"] for h in coord("inspect", {})["ci_heads"] if h["repo"] == "owner/rec"] == ["rec-1"]
assert coord("ci-complete", {"request_id": "complete-rec-1-restored", "repo": "owner/rec", "base": "main", "head_oid": f"e{1:039x}", "batch_id": "rec-1", "conclusion": "success"})["admitted"] == []
events = coord("outbox", {"limit": 1000})["events"]
assert sum(e["type"] == "ci-pulse-authorized" and e["payload"]["batch_id"] == "rec-2" for e in events) == 0
PY
pass 'fenced recovery never re-admits a CI head promoted after the backup'

# Capacity is per repository across base refs; queued promotion rechecks the writer; green forge checks leave
# the batch's slot held, and only that batch's completion or its expired slot lease admits the next head.
python3 - "$ROOT/bin/fm-coord.sh" "$db" <<'PY' || fail 'CI slots must be shared across bases, recheck queued writers, stay held on green checks, and free on batch completion or lease expiry'
import json, subprocess, sys, time
cmd, db = sys.argv[1], sys.argv[2]
def coord(op, payload):
    run = subprocess.run([cmd, "--db", db, op, json.dumps(payload)], capture_output=True, text=True)
    assert run.returncode == 0, (op, payload, run.stderr)
    return json.loads(run.stdout)
def heads(state):
    return [h["batch_id"] for h in coord("inspect", {})["ci_heads"] if h["repo"] == "owner/heal" and h["state"] == state]
coord("enroll", {"request_id": "enroll-heal", "home_id": "heal", "repos": ["owner/heal"]})
gen = coord("session", {"request_id": "session-heal", "home_id": "heal"})["generation"]
coord("manifest-set", {"request_id": "manifest-heal", "repo": "owner/heal", "base": "main", "checks": ["Lint"]})
coord("ci-capacity-set", {"request_id": "capacity-heal", "repo": "owner/heal", "capacity": 1})
live = {}
def intent(name, base="main"):
    coord("submit", {"request_id": f"submit-{name}", "intent_id": name, "home_id": "heal", "generation": gen, "repo": "owner/heal", "base": base, "base_oid": "0" * 40, "branch": f"branch/{name}", "task_id": name, "goal": "ci", "resources": [{"type": "file", "name": f"src/{name}.py"}]})
    grant = coord("claim", {"request_id": f"claim-{name}", "intent_id": name, "home_id": "heal", "generation": gen, "version": 1})
    owner = {"home_id": "heal", "generation": gen, "claim_id": grant["claim_id"], "fence": grant["fence"], "intent_id": name}
    head = name.encode().hex().ljust(40, "0")
    coord("publish-head", {**owner, "request_id": f"head-{name}", "head_oid": head, "expected_previous_oid": None})
    live[name] = (owner, head)
def pulse(name, request_id=None):
    owner, head = live[name]
    return coord("pulse-batch", {**owner, "request_id": request_id or f"pulse-{name}-{time.monotonic_ns()}", "head_oid": head, "batch_id": name})
for name, base in (("main-a", "main"), ("release-b", "release"), ("gone-c", "main"), ("main-d", "main")):
    intent(name, base)
assert pulse("main-a")["admitted"] is True
assert pulse("release-b")["admitted"] is False, "a second base must share the repository's one CI slot"
assert pulse("gone-c")["admitted"] is False and pulse("main-d")["admitted"] is False
owner, _ = live["gone-c"]
coord("release", {"request_id": "release-gone-c", **{k: owner[k] for k in ("home_id", "generation", "claim_id", "fence")}})

# The merge path observes main-a's required checks green; its separately authorized batch may still be running.
owner, head = live["main-a"]
coord("attach-pr", {**owner, "request_id": "pr-main-a", "pr_url": "https://github.com/owner/heal/pull/1"})
coord("queue-ready", {**owner, "request_id": "ready-main-a", "head_oid": head, "priority": 0})
slot = coord("queue-next", {"request_id": "next-main-a", "repo": "owner/heal", "base": "main"})["generation"]
common = {**owner, "slot_generation": slot, "current_head_oid": head, "current_base_oid": "0" * 40}
coord("queue-synced", {**common, "request_id": "sync-main-a", "head_contains_base": True})
coord("queue-validated", {**common, "request_id": "validate-main-a", "validation_passed": True, "validation_id": "v-main-a"})
coord("queue-checks", {**common, "request_id": "checks-main-a", "protection_available": False, "checks": [{"name": "Lint", "head_oid": head, "conclusion": "success"}]})
assert heads("active") == ["main-a"] and heads("queued") == ["release-b", "gone-c", "main-d"], (heads("active"), heads("queued"))
assert coord("ci-complete", {"request_id": "complete-main-a", "repo": "owner/heal", "base": "main", "head_oid": head, "batch_id": "main-a", "conclusion": "success"})["admitted"] == ["release-b"]
assert heads("active") == ["release-b"] and heads("queued") == ["gone-c", "main-d"], (heads("active"), heads("queued"))
assert pulse("release-b")["admitted"] is True

# release-b's run never reports; under a shorter configured lease its slot lapses, the released gone-c is dropped, and main-d is admitted.
time.sleep(2)
assert coord("ci-capacity-set", {"request_id": "ttl-heal", "repo": "owner/heal", "capacity": 1, "ttl_seconds": 1})["admitted"] == ["main-d"]
# Restore a long lease at once so main-d's own fresh slot cannot lapse before its poll.
coord("ci-capacity-set", {"request_id": "ttl-restore", "repo": "owner/heal", "capacity": 1, "ttl_seconds": 3600})
assert pulse("main-d")["admitted"] is True
events = coord("outbox", {"limit": 1000})["events"]
assert any(e["type"] == "ci-completed" and e["payload"]["batch_id"] == "release-b" and e["payload"]["conclusion"] == "lease-expired" for e in events)
assert any(e["type"] == "ci-pulse-dropped" and e["payload"]["batch_id"] == "gone-c" for e in events)
assert not any(e["type"] == "ci-pulse-authorized" and e["payload"]["batch_id"] == "gone-c" for e in events)
assert heads("active") == ["main-d"] and heads("queued") == []
PY
pass 'CI capacity is shared across bases, skips stale queued writers, holds slots through green checks, and frees them on batch completion or lease expiry'
