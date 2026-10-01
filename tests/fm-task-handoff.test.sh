#!/usr/bin/env bash
# Behavioral coverage for the lease-safe cross-task handoff public interface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-handoff)
HANDOFF="$ROOT/bin/fm-task-handoff.sh"
LEASE="$ROOT/bin/fm-lease.sh"

make_fake_backend() {  # <case-dir>
  local dir=$1 fakebin="$1/fakebin" command
  mkdir -p "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  'status --json') echo '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}' ;;
  'pane read') printf '╭────╮\n│    │\n╰────╯\n' ;;
  'pane send-text') printf '%s\n' "$*" >> "${FM_TEST_SEND_LOG:-/dev/null}" ;;
  *) echo '{}' ;;
esac
SH
  chmod +x "$fakebin/herdr"
  for command in tmux zellij orca cmux; do
    printf '#!/bin/sh\nexit 97\n' > "$fakebin/$command"
    chmod +x "$fakebin/$command"
  done
  printf '%s\n' "$fakebin"
}

make_home() {  # <case-dir> <task>...
  local dir=$1 home="$1/home" task
  shift
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  for task in "$@"; do
    {
      printf 'window=fixture:w1:p-%s\n' "$task"
      printf 'endpoint_task_id=%s\n' "$task"
      printf 'harness=pi\n'
      printf 'kind=ship\n'
      printf 'backend=herdr\n'
      printf 'spawn_gen=test-%s\n' "$task"
    } > "$home/state/$task.meta"
  done
  printf '%s\n' "$home"
}

inbox_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

test_conflict_preserves_then_delivers_exactly_once() {
  local dir home fakebin id body out rc count record actual
  dir="$TMP_ROOT/conflict"
  fakebin=$(make_fake_backend "$dir")
  home=$(make_home "$dir" source target)
  id=legacy-full-missing-counts-backend
  body=$'Implement the authorized unknown-not-zero correction.\nKeep the accepted contract exact.\n'

  PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    "$LEASE" claim target --actor branch || fail "branch fixture lease failed"
  rc=0
  out=$(PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$HANDOFF" send source target --id "$id" "$body" 2>&1) || rc=$?
  [ "$rc" -eq 6 ] || fail "ownership-conflict handoff exited $rc, not 6: $out"
  assert_contains "$out" "not started" "ownership conflict did not deny a false start"
  assert_contains "$out" "leased to the branch supervision actor" "ownership conflict lost its concrete blocker"
  [ ! -d "$home/state/target.inbox" ] || {
    count=$(find "$home/state/target.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
    [ "$count" -eq 0 ] || fail "conflicting actor sent around the active owner"
  }
  out=$(FM_HOME="$home" "$HANDOFF" inspect "$id") || fail "durable refused handoff was not inspectable"
  assert_contains "$out" "state=retryable-refusal" "conflict did not persist a retryable refusal"
  assert_contains "$out" "target=target" "durable handoff lost its intended recipient"
  assert_contains "$out" "Implement the authorized unknown-not-zero correction." "durable handoff lost its body"

  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=branch \
    FM_TEST_SEND_LOG="$dir/send.log" "$LEASE" release target --actor branch \
    || fail "owner release failed"
  record=$(find "$home/state/target.inbox" -maxdepth 1 -name '*.msg' -print)
  [ -f "$record" ] || fail "ownership settlement did not deliver the handoff"
  actual=$(inbox_body "$record"; printf '\001')
  actual=${actual%?}
  [ "$actual" = "$body" ] || fail "delivered handoff body was not byte-exact"
  out=$(FM_HOME="$home" "$HANDOFF" inspect "$id") || fail "delivered handoff was not inspectable"
  assert_contains "$out" "state=delivered" "ownership settlement did not persist delivery"

  mkdir -p "$home/state/target.inbox/handled"
  mv "$record" "$home/state/target.inbox/handled/${record##*/}"

  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$HANDOFF" retry "$id" >/dev/null || fail "delivered handoff retry failed"
  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$HANDOFF" send source target --id "$id" "$body" >/dev/null || fail "original sender retry failed"
  count=$(find "$home/state/target.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "ownership settlement or duplicate retries delivered $count copies"
  pass "task-handoff: ownership conflict preserves the exact body and settlement delivers it once"
}

test_restart_sweep_recovers_pending_handoff() {
  local dir home fakebin id rc count
  dir="$TMP_ROOT/restart"
  fakebin=$(make_fake_backend "$dir")
  home=$(make_home "$dir" source target)
  id=restart-recovery
  PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    "$LEASE" claim target --actor branch || fail "restart fixture lease failed"
  rc=0
  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$HANDOFF" send source target --id "$id" "recover after branch replacement" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 6 ] || fail "restart fixture did not stop at the ownership conflict"

  rm "$home/state/.lease-target"
  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main \
    "$LEASE" sweep || fail "restart recovery sweep failed"
  count=$(find "$home/state/target.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "restart sweep did not recover exactly one handoff"
  assert_contains "$(FM_HOME="$home" "$HANDOFF" inspect "$id")" "state=delivered" \
    "restart recovery did not publish delivery"
  pass "task-handoff: restart recovery delivers without conversation memory after the lease is gone"
}

test_sweep_without_handoffs_is_a_noop() {
  local dir home
  dir="$TMP_ROOT/empty-sweep"
  home=$(make_home "$dir" target)
  FM_HOME="$home" "$LEASE" sweep || fail "empty handoff sweep failed"
  [ ! -e "$home/state/task-handoffs" ] \
    || fail "ordinary lease sweep materialized an empty handoff ledger"
  pass "task-handoff: a home without handoffs stays untouched by lease sweep"
}

test_local_runtime_backend_matrix_uses_one_durable_plane() {
  local dir home fakebin backend endpoint id record count rc out
  for backend in tmux herdr zellij orca cmux; do
    dir="$TMP_ROOT/backend-$backend"
    fakebin=$(make_fake_backend "$dir")
    home=$(make_home "$dir" source target)
    endpoint="test-$backend-endpoint"
    {
      printf 'endpoint_task_id=target\n'
      printf 'harness=pi\n'
      printf 'kind=ship\n'
      printf 'backend=%s\n' "$backend"
      if [ "$backend" = orca ]; then
        printf 'terminal=%s\n' "$endpoint"
      else
        printf 'window=%s\n' "$endpoint"
      fi
      printf 'spawn_gen=test-target\n'
    } > "$home/state/target.meta"
    id="backend-$backend"
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HANDOFF" send source target --id "$id" \
      "deliver independently of the $backend doorbell" 2>&1) || rc=$?
    if [ "$backend" != herdr ]; then
      [ "$rc" = 7 ] || fail "retired $backend handoff did not refuse: $out"
      out=$(FM_HOME="$home" "$HANDOFF" inspect "$id")
      assert_contains "$out" 'state=rejected' 'retired handoff rejection was not durable'
      assert_contains "$out" "deliver independently of the $backend doorbell" 'retired handoff lost body'
      [ ! -d "$home/state/target.inbox" ] || fail 'retired target received an instruction'
      continue
    fi
    [ "$rc" = 0 ] || fail "Herdr handoff failed: $out"
    record=$(find "$home/state/target.inbox" -maxdepth 1 -name '*.msg' -print)
    [ -f "$record" ] || fail "$backend delivery did not create an inbox record"
    assert_contains "$(inbox_body "$record")" "deliver independently of the $backend doorbell" \
      "$backend delivery changed the instruction"
    count=$(find "$home/state/target.inbox" -name '*.msg' | wc -l | tr -d ' ')
    [ "$count" -eq 1 ] || fail "$backend delivery created $count inbox records"
  done
  pass "task-handoff: Herdr delivers durably; retired backends reject without losing the requested body"
}

test_terminal_refusal_is_durable() {
  local dir home fakebin id out rc
  dir="$TMP_ROOT/rejected"
  fakebin=$(make_fake_backend "$dir")
  home=$(make_home "$dir" source)
  id=retired-target
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HANDOFF" send source retired --id "$id" \
    "do not lose this rejected instruction" 2>&1) || rc=$?
  [ "$rc" -eq 7 ] || fail "missing target exited $rc, not terminal refusal 7: $out"
  assert_contains "$out" "no safe live metadata record" "terminal refusal lost its concrete blocker"
  out=$(FM_HOME="$home" "$HANDOFF" inspect "$id") || fail "terminal refusal was not inspectable"
  assert_contains "$out" "state=rejected" "terminal refusal state was not durable"
  assert_contains "$out" "target=retired" "terminal refusal lost its intended recipient"
  assert_contains "$out" "do not lose this rejected instruction" "terminal refusal discarded the body"
  rc=0
  PATH="$fakebin:$PATH" FM_HOME="$home" "$HANDOFF" retry "$id" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 7 ] || fail "terminally refused handoff became retryable"
  pass "task-handoff: a terminal target refusal keeps the exact body and concrete blocker"
}

test_bound_terminal_source_is_permanently_rejected() {
  ROOT="$ROOT" CASE_DIR="$TMP_ROOT/terminal-source" FM_FIXTURE_BACKEND="$(make_fake_backend "$TMP_ROOT/terminal-source")" python3 - <<'PY'
import hashlib, json, os, pathlib, shutil, subprocess
root=pathlib.Path(os.environ['ROOT']);home=pathlib.Path(os.environ['CASE_DIR'])/'home'
for name in ('state','data'): (home/name).mkdir(parents=True)
(home/'state/.lock').write_text(str(os.getpid())+'\n')
bin=home/'bin';shutil.copytree(root/'bin',bin)
(bin/'fm-crew-state.sh').write_text('#!/bin/sh\nprintf "state: working · source: terminal-source-fixture\\n"\n')
(bin/'fm-crew-state.sh').chmod(0o755)
session=home/'main.jsonl';session.write_text('{"type":"session","id":"terminal-source"}\n')
env=dict(os.environ,FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),
         FM_LEASE_HOLDER_PID=str(os.getpid()),FM_BRANCH_GENERATION='1',FM_BRANCH_MAIN_SESSION_FILE=str(session),
         FM_BRANCH_TASK_SCOPE='["source","target"]',PATH=os.environ['FM_FIXTURE_BACKEND']+':'+os.environ['PATH'])
def run(owner,*args,actor='main',ok=True,bindings=None):
    e=dict(env,FM_SUPERVISION_ACTOR=actor)
    if bindings is not None:e['FM_BRANCH_TASK_BINDINGS']=json.dumps(bindings)
    p=subprocess.run([str(bin/owner),*args],env=e,text=True,capture_output=True,timeout=20)
    assert (p.returncode==0)==ok,(args,p.returncode,p.stdout,p.stderr)
    return p
def state(*args,**kwargs):
    p=run('fm-task-state.sh',*args,**kwargs)
    return json.loads(p.stdout) if p.returncode==0 and p.stdout.strip() else p
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
for task in ('source','target'):
    d=home/'data'/task;d.mkdir();(d/'brief.md').write_text('Continue the exact existing goal.\n')
    (home/'state'/f'{task}.meta').write_text(f'window=fixture:w1:p-{task}\nbackend=herdr\nharness=pi\nkind=ship\nexecutor=local-agent\nspawn_gen=g1\n')
    state('enroll',task)
source=state('lifecycle','source');target=state('lifecycle','target')
source['schema']='fm-task-lifecycle.v2';source['precheck']=None
source['delegation']=dict(revision=1,issuer='main',authority_ref='data/source/brief.md',authority_sha256=sha(home/'data/source/brief.md'),
    allowed=['inspect','precheck','steer-same-intent','observe-receipt','handoff'],
    edges=[dict(target='target',goal_revision=target['goal_revision'],execution_generation='g1',authority_ref='data/source/brief.md',authority_sha256=sha(home/'data/source/brief.md'),scope='Exact existing prerequisite')],
    expires_at='2099-01-01T00:00:00Z',revoked=False)
payload=home/'data/source/payload';payload.write_text('Deliver the exact existing prerequisite.')
source['next_action']=dict(id='source.g1.a1',kind='steer',phase='prepared',expected_execution_generation='g1',attempts=0,attempt_limit=1,
    recheck_at='2026-01-01T00:00:00Z',deadline='2099-01-01T00:00:00Z',payload_ref=str(payload),payload_sha256=sha(payload),receipt_ref=None)
source['next_action_seq']=2
proposal=home/'data/source/proposal.json';proposal.write_text(json.dumps(source));proposal.chmod(0o600)
source=state('reconcile','source','--expected-revision',str(source['revision']),'--record',str(proposal))
bindings={'source':dict(goal_revision=source['goal_revision'],brief_sha256=source['brief_sha256'],execution_generation='g1',delegation_revision=1),
          'target':dict(goal_revision=target['goal_revision'],brief_sha256=target['brief_sha256'],execution_generation='g1',delegation_revision=0)}
run('fm-wake-grant.sh','activate',str(os.getpid()),'1')
run('fm-lease.sh','claim','target','--actor','main')
p=run('fm-task-handoff.sh','send','source','target','--id','terminal-source-edge','--action-id','source.g1.a1','Deliver the exact existing prerequisite.',actor='branch',ok=False,bindings=bindings)
assert p.returncode==6,(p.returncode,p.stdout,p.stderr)
# Fixture-only owner disappearance avoids the release command's automatic retry;
# the next public retry must classify the now-terminal source before any effect.
(home/'state/.lease-target').unlink()
record=home/'state/task-handoffs/records/terminal-source-edge.msg'
assert record.exists() and not (home/'state/target.inbox').exists()
# MAIN accepts the source while the exact immutable handoff is still pending.
refusal=home/'data/source/handoff-refusal.md';refusal.write_text('The source goal reached final acceptance before handoff delivery.\n')
state('action','source','--action-id','source.g1.a1','--phase','refused','--receipt-ref',str(refusal))
source=state('lifecycle','source');source['disposition']='accepted';source['assessment']['outcome']='Accepted source result';source['assessment']['remaining_gap']=''
source['precheck']=None
proposal.write_text(json.dumps(source));proposal.chmod(0o600)
source=state('reconcile','source','--expected-revision',str(source['revision']),'--record',str(proposal))
bindings['source']['delegation_revision']=source['delegation']['revision']
p=run('fm-task-handoff.sh','retry','terminal-source-edge',actor='branch',ok=False,bindings=bindings)
assert p.returncode==7,(p.returncode,p.stdout,p.stderr)
assert 'exact bound source is terminal' in p.stderr
inspect=run('fm-task-handoff.sh','inspect','terminal-source-edge').stdout
assert 'state=rejected' in inspect and 'Deliver the exact existing prerequisite.' in inspect
assert not (home/'state/target.inbox').exists()
p=run('fm-task-handoff.sh','retry','terminal-source-edge',actor='branch',ok=False,bindings=bindings)
assert p.returncode==7 and 'terminally rejected' in p.stderr
print('ok - task-handoff: an exact pending handoff becomes a durable non-retryable refusal when its bound source is terminal')
PY
}


test_same_task_send_and_reminder_contract_stay_ordinary() {
  local dir home fakebin record handoff_record action
  dir="$TMP_ROOT/same-task"
  fakebin=$(make_fake_backend "$dir")
  home=$(make_home "$dir" same)
  PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ \
    "$LEASE" claim same --actor main || fail "same-task lease failed"
  touch "$home/state/.last-watcher-beat"
  PATH="$fakebin:$PATH" PI_CODING_AGENT=true FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SUPERVISION_ACTOR=main \
    FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" same "ordinary same-task steer" >/dev/null 2>&1 \
    || fail "ordinary same-task fm-send failed"
  record=$(find "$home/state/same.inbox" -maxdepth 1 -name '*.msg' -print)
  [ -f "$record" ] || fail "ordinary same-task steer did not create its inbox record"
  handoff_record=$(bash -c '. "$1"; fm_task_inbox_handoff_id "$2"' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$record" 2>/dev/null || true)
  [ -z "$handoff_record" ] || fail "ordinary same-task steer was rewritten as a cross-task handoff"
  touch -t 202001010000 "$record"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 bash -c '. "$1"; fm_task_inbox_due_action "$2" same' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state") || fail "reminder ladder check failed"
  case "$action" in "ring $record") ;; *) fail "ordinary unacknowledged reminder changed: $action" ;; esac
  pass "task-handoff: ordinary same-task steering and its unacknowledged reminder remain unchanged"
}

test_continuation_assessment_and_observed_executor() {
  ROOT="$ROOT" CASE_DIR="$TMP_ROOT/lifecycle" FM_FIXTURE_BACKEND="$(make_fake_backend "$TMP_ROOT/lifecycle")" python3 - <<'PY'
import copy, hashlib, json, os, pathlib, shutil, subprocess
root = pathlib.Path(os.environ['ROOT'])
home = pathlib.Path(os.environ['CASE_DIR'])
(home/'state').mkdir(parents=True)
(home/'data').mkdir()
(home/'state/.lock').write_text(str(os.getpid())+'\n')
# Only provider state is controlled; lifecycle, leases, handoff, inbox and
# acknowledgement use the candidate's public executables.
bin = home/'bin'
shutil.copytree(root/'bin', bin)
(bin/'fm-crew-state.sh').write_text('#!/bin/sh\nprintf "state: %s · source: controlled-provider\\n" "$(cat "$FM_HOME/state/provider-state")"\n')
(bin/'fm-crew-state.sh').chmod(0o755)
(home/'state/provider-state').write_text('working')
env = dict(os.environ, FM_HOME=str(home), FM_SUPERVISION_ACTOR='main', PI_CODING_AGENT='true')
def call(script, *args, ok=True):
    p = subprocess.run([str(bin/script), *args], env=env, text=True, capture_output=True)
    assert (p.returncode == 0) == ok, (args, p.returncode, p.stdout, p.stderr)
    return json.loads(p.stdout) if ok and p.stdout.strip().startswith(('{','[')) else p.stdout

def state(op, *args, **kw): return call('fm-task-state.sh', op, 'source', *args, **kw)
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def save(path, value):
    path.write_text(json.dumps(value)); path.chmod(0o600)
def reconcile(record, ok=True):
    path=home/'data/proposal.json'; save(path, record)
    return state('reconcile', '--expected-revision', str(record['revision']), '--record', str(path), ok=ok)
def receipt(phase):
    record=state('lifecycle')
    return state('action','--action-id',record['next_action']['id'],'--phase',phase,
                 '--receipt-ref','data/readback','--receipt-sha256',sha(home/'data/readback'))
for task in ('source','target'):
    (home/'data'/task).mkdir()
    (home/'data'/task/'brief.md').write_text('Apply prerequisite and verify the requested operation.\n')
    (home/'state'/f'{task}.meta').write_text(f'spawn_gen=g1\nkind=ship\nexecutor=local-agent\n')
(home/'data/readback').write_text('Observed provider readback, not semantic acceptance.\n')
# A presentation ack alone used to consume all debt. It now refuses until
# this exact task's goal is durably retained, then presentation stays consumed.
call('fm-branch-outcome.sh','append','--task','source','--verdict','captain','--summary','Prerequisite merged')
call('fm-branch-outcome.sh','mark-read','--through','1')
call('fm-branch-outcome.sh','mark-processed','--through','1',ok=False)
r=state('enroll')
call('fm-branch-outcome.sh','mark-processed','--through','1')
assert call('fm-branch-outcome.sh','unprocessed') == ''
assert state('observe')['state']=='pending'
assert state('enroll')['revision']==r['revision']
# False terminal, provider-success or report-only claims never remove a gap.
bad=copy.deepcopy(r);bad['disposition']='accepted';bad['assessment']['outcome']='PR green, provider done'
reconcile(bad,ok=False)
# An attempted effect has immutable identity/payload until evidenced readback.
a=dict(id='source.g1.a1',kind='steer',phase='prepared',expected_execution_generation='g1',attempts=0,attempt_limit=2,
       recheck_at='2026-01-01T00:00:00Z',deadline='2099-01-01T00:00:00Z',payload_ref='data/readback',payload_sha256=sha(home/'data/readback'),receipt_ref=None,
       continuation=dict(type='executor',task_id='target',execution_generation='g1',inbox_id='000001',sha256='a'*64))
r['next_action']=a;r['next_action_seq']=2;r=reconcile(r)
def execution_guard():
    return subprocess.run(['bash','-c','. "$1"; fm_task_lifecycle_execution_guard source',
                           '_',str(bin/'fm-task-lifecycle-lib.sh')], env=env, capture_output=True, text=True)
assert execution_guard().returncode == 0, 'prepared operation should remain executable'
state('action','--action-id',a['id'],'--phase','attempted')
assert execution_guard().returncode != 0, 'attempted effect must require readback before execution'
r=receipt('uncertain'); oldkey=state('observe')['key']
assert execution_guard().returncode != 0, 'uncertain effect must require readback before execution'
bad=copy.deepcopy(r);bad['next_action']=None;reconcile(bad,ok=False)
# Receipt has not arrived: a successful sender's claim cannot confirm execution.
state('action','--action-id',a['id'],'--phase','confirmed','--receipt-ref','data/readback','--receipt-sha256',sha(home/'data/readback'),ok=False)
# A refused uncertainty cannot silently be assigned a new id with the same body.
r=receipt('refused');bad=copy.deepcopy(r);bad['next_action']['id']='source.g1.a2';bad['next_action']['phase']='prepared';bad['next_action']['attempts']=0;bad['next_action_seq']=3;reconcile(bad,ok=False)
# A genuinely different authorized next action binds the exact handled message.
(home/'data/next').write_text('Different authorized operation after readback.\n')
queued=home/'state/target.inbox';(queued/'handled').mkdir(parents=True)
msg=queued/'000001.msg';msg.write_text('id=000001\n--\nApply exact prerequisite\n')
a.update(id='source.g1.a2',phase='prepared',attempts=0,payload_ref='data/next',payload_sha256=sha(home/'data/next'))
a['continuation']['sha256']=sha(msg)
r['next_action']=a;r['next_action_seq']=3;r=reconcile(r)
assert state('observe')['state']=='pending'
state('action','--action-id',a['id'],'--phase','attempted');receipt('uncertain')
missing=state('observe');msg.rename(queued/'handled/000001.msg')
observed=state('observe');assert observed['key']!=missing['key'] and 'observed' in observed['reason']
r=receipt('confirmed');assert state('observe')['state']=='running'
assert receipt('confirmed')['revision']==r['revision']
(home/'state/provider-state').write_text('done')
assert state('observe')['state']=='pending', 'provider done is not goal acceptance'
# Bind the real durable handoff owner, including its exact inbox wire format.
env['PATH']=os.environ['FM_FIXTURE_BACKEND']+os.pathsep+env['PATH']
with (home/'state/target.meta').open('a') as f: f.write('backend=herdr\nwindow=fixture:w1:p-target\nharness=pi\nendpoint_task_id=target\n')
call('fm-task-handoff.sh','send','source','target','--id','observed-handoff','Apply the next authorized operation exactly once.')
a=dict(a,id='source.g1.a3',phase='prepared',attempts=0,continuation=dict(type='executor',task_id='target',execution_generation='g1',handoff_id='observed-handoff'))
r['next_action']=a;r['next_action_seq']=4;r=reconcile(r)
assert state('observe')['state']=='pending'
messages=list(queued.glob('*.msg'));assert len(messages)==1
messages[0].rename(queued/'handled'/messages[0].name)
(home/'state/provider-state').write_text('working')
assert state('observe')['state']=='running'
state('action','--action-id',a['id'],'--phase','attempted');r=receipt('confirmed')
call('fm-task-handoff.sh','retry','observed-handoff')
assert len(list(queued.rglob('*.msg')))==2, 'replayed an already handled handoff'

# Real dependency evidence stays quiet; release changes only the observation,
# not the immutable action or any external effect.
(home/'data/dependency').write_text('permission pending')
a=dict(a,id='source.g1.a4',kind='wait',phase='prepared',attempts=0,
       continuation=dict(type='blocker',owner='permission-owner',dependency='approval for operation',release_ref='data/dependency',release_sha256=sha(home/'data/dependency'),recovery_trigger='evidence-change'))
r['next_action']=a;r['next_action_seq']=5;r=reconcile(r)
x=state('observe');assert x['state']=='blocked' and state('observe')['key']==x['key']
(home/'data/dependency').write_text('approval recorded for exact operation')
x=state('observe');assert x['state']=='pending' and state('observe')['key']==x['key']
# Explicit archive retains the outstanding action without authorizing it again.
(home/'data/stop').write_text('Explicitly stop this request; retain its local work.')
r['disposition']='archived';r['assessment']['authority_ref']='data/stop';r=reconcile(r)
assert state('observe')['state']=='archived'
assert r['next_action']['phase']=='prepared'
call('fm-control.sh','source','relaunch','--note','must not revive stopped work',ok=False)
call('fm-task-handoff.sh','send','source','target','--id','stopped-request','must not revive stopped work',ok=False)
assert len(list(queued.rglob('*.msg')))==2
bad=copy.deepcopy(r);bad['disposition']='open';reconcile(bad,ok=False)
# A later, separate goal cannot overwrite this goal's revision or stopped state.
call('fm-task-state.sh','enroll','target');assert state('observe')['state']=='archived'
# Newly spawned work can bind its launch brief, but a submitted-launch busy
# seed is not observed execution. Existing harness readers own that distinction.
t=call('fm-task-state.sh','lifecycle','target')
# Ordinary dispatch already binds this brief/generation, without a separate
# prepared action. Its published launch and actual activity are enough for
# observation, not for semantic acceptance or retry authorization.
with (home/'state/target.meta').open('a') as f: f.write('launch_state=confirmed\n')
assert call('fm-task-state.sh','observe','target')['state']=='pending'
(bin/'fm-crew-state.sh').write_text('#!/bin/sh\nprintf "state: working · doing: harness busy (pi-ext)\\n"\n')
before=(home/'data/target/lifecycle.json').read_bytes()
assert call('fm-task-state.sh','observe','target')['state']=='running', 'ordinary published launch lost its brief receipt'
assert (home/'data/target/lifecycle.json').read_bytes()==before, 'readback changed semantic authority'
m=home/'state/target.meta';original=m.read_text()
for phase in ('prepared','unconfirmed'):
    m.write_text(original.replace('launch_state=confirmed','launch_state='+phase))
    assert call('fm-task-state.sh','observe','target')['state']=='pending', 'uncertain launch became execution proof'
m.write_text(original)
(bin/'fm-crew-state.sh').write_text('#!/bin/sh\nprintf "state: working · doing: harness busy (fm-spawn)\\n"\n')
assert call('fm-task-state.sh','observe','target')['state']=='pending', 'synthetic busy seed became execution proof'
t['next_action_seq']=2
t['next_action']=dict(a,id='target.g1.a1',kind='spawn',phase='prepared',attempts=0,
    continuation=dict(type='executor',task_id='target',execution_generation='g1',brief_sha256=sha(home/'data/target/brief.md')))
save(home/'data/proposal.json',t)
call('fm-task-state.sh','reconcile','target','--expected-revision',str(t['revision']),'--record',str(home/'data/proposal.json'))
assert call('fm-task-state.sh','observe','target')['state']=='pending'
(bin/'fm-crew-state.sh').write_text('#!/bin/sh\nprintf "state: working · source: pane · doing: harness busy (pi-ext)\\n"\n')
assert call('fm-task-state.sh','observe','target')['state']=='running'
# Main can close only after resolving the action and binding actual acceptance.
call('fm-task-state.sh','action','target','--action-id','target.g1.a1','--phase','attempted')
call('fm-task-state.sh','action','target','--action-id','target.g1.a1','--phase','confirmed',
     '--receipt-ref','data/readback','--receipt-sha256',sha(home/'data/readback'))
(home/'data/acceptance').write_text('Requested operation and acceptance checks verified by main.')
t=call('fm-task-state.sh','lifecycle','target');t['disposition']='accepted'
t['assessment'].update(remaining_gap='',outcome='Requested operation verified',evidence=[dict(ref='data/acceptance',sha256=sha(home/'data/acceptance'))])
save(home/'data/proposal.json',t)
call('fm-task-state.sh','reconcile','target','--expected-revision',str(t['revision']),'--record',str(home/'data/proposal.json'))
assert call('fm-task-state.sh','observe','target')['state']=='accepted'

print('ok - lifecycle: acknowledgement retains debt, CAS rejects false closure/replay, actual receipt advances, dependency release and archive remain independent')
PY
}

test_delegated_lifecycle_effect_boundaries() {
  ROOT="$ROOT" CASE_DIR="$TMP_ROOT/delegated" FM_FIXTURE_BACKEND="$(make_fake_backend "$TMP_ROOT/delegated")" python3 - <<'PY'
import copy, hashlib, json, os, pathlib, shutil, subprocess
root=pathlib.Path(os.environ['ROOT']);home=pathlib.Path(os.environ['CASE_DIR'])
(home/'state').mkdir(parents=True);(home/'data').mkdir()
(home/'state/.lock').write_text(str(os.getpid())+'\n')
bin=home/'bin';shutil.copytree(root/'bin',bin)
(bin/'fm-crew-state.sh').write_text('#!/bin/sh\necho "state: working · source: controlled-provider"\n');(bin/'fm-crew-state.sh').chmod(0o755)
session=home/'main.jsonl';session.write_text('{"type":"session","id":"s"}\n')
env=dict(os.environ,FM_HOME=str(home),FM_SUPERVISION_ACTOR='main',PI_CODING_AGENT='true',FM_LEASE_HOLDER_PID=str(os.getpid()),FM_BRANCH_MAIN_SESSION_FILE=str(session),FM_BRANCH_GENERATION='1',FM_BRANCH_TASK_SCOPE='["source"]',PATH=os.environ['FM_FIXTURE_BACKEND']+':'+os.environ['PATH'])
def call(script,*args,ok=True,actor='main',extra=None):
    current=home/'data/source/lifecycle.json'
    bindings={}
    if current.exists():
        r=json.loads(current.read_text())
        if r.get('delegation'):bindings={'source':dict(goal_revision=r['goal_revision'],brief_sha256=r['brief_sha256'],execution_generation=r['execution_generation'],delegation_revision=r['delegation']['revision'])}
    p=subprocess.run([str(bin/script),*args],env=dict(env,FM_SUPERVISION_ACTOR=actor,FM_BRANCH_TASK_BINDINGS=json.dumps(bindings)) | (extra or {}),text=True,capture_output=True,timeout=20)
    assert (p.returncode==0)==ok,(script,args,p.returncode,p.stdout,p.stderr)
    return json.loads(p.stdout) if ok and p.stdout.strip().startswith(('{','[')) else p.stdout+p.stderr

def state(op,task='source',*args,**kw):return call('fm-task-state.sh',op,task,*args,**kw)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(name,value):
    p=home/'data'/name;p.write_text(json.dumps(value));p.chmod(0o600);return str(p)
def reconcile(r,ok=True):return state('reconcile',r['task_id'],'--expected-revision',str(r['revision']),'--record',save('proposal',r),ok=ok)
def patch(value,ok=True):
    r=state('lifecycle');return state('branch-patch','source','--expected-revision',str(r['revision']),'--record',save('patch',dict(delegation_revision=r['delegation']['revision'],**value)),actor='branch',ok=ok)
def new_action(r,body='Fill the existing acceptance evidence.'):
    payload=home/'data'/('payload'+str(r['next_action_seq']));payload.write_text(body)
    return dict(id=f"source.g{r['goal_revision']}.a{r['next_action_seq']}",kind='steer',phase='prepared',expected_execution_generation=r['execution_generation'],attempts=0,attempt_limit=1,recheck_at='2026-01-01T00:00:00Z',deadline='2099-01-01T00:00:00Z',payload_ref=str(payload),payload_sha256=sha(payload),receipt_ref=None)
for task in ('source','target','legacy'):
    d=home/'data'/task;d.mkdir();(d/'brief.md').write_text('Implement existing goal and supply exact verification evidence.\n')
    (home/'state'/f'{task}.meta').write_text(f'window=fixture:w1:p-{task}\nbackend=herdr\nharness=pi\nkind=ship\nexecutor=local-agent\nspawn_gen=g1\n')
    state('enroll',task)
call('fm-wake-grant.sh','activate',str(os.getpid()),'1')
r=state('lifecycle');r['schema']='fm-task-lifecycle.v2';r['precheck']=None
r['delegation']=dict(revision=1,issuer='main',authority_ref='data/source/brief.md',authority_sha256=sha(home/'data/source/brief.md'),allowed=['inspect','precheck','steer-same-intent','observe-receipt','handoff'],edges=[dict(target='target',goal_revision=1,execution_generation='g1',authority_ref='data/source/brief.md',authority_sha256=sha(home/'data/source/brief.md'),scope='Existing prerequisite evidence only')],expires_at='2099-01-01T00:00:00Z',revoked=False)
r=reconcile(r)
# Branch cannot mutate semantic truth or grant itself authority.
patch({'disposition':'accepted'},ok=False)
for owner,args in [('fm-control.sh',('source','relaunch')),('fm-teardown.sh',('source',)),('fm-task-retire.sh',('source',))]:
    call(owner,*args,actor='branch',ok=False)
assert (home/'state/source.meta').exists()
state('reconcile','source','--expected-revision',str(r['revision']),'--record',save('proposal',r),actor='branch',ok=False)
state('enroll','unknown',actor='branch',ok=False)
check=dict(delegation_revision=1,basis_key=state('observe')['basis_key'],conclusion='needs-evidence',checks=[dict(criterion='brief acceptance',result='missing',evidence=[])],summary='Existing evidence is missing')
r=patch({'precheck':check});revision=r['revision'];assert patch({'precheck':check})['revision']==revision
# Exact same-intent steer: denied body, intake barrier and stale generation have zero effects.
a=new_action(r);r=patch({'next_action':a})
call('fm-send.sh','source','--action-id',a['id'],'--expected-generation','g1','Different body',actor='branch',ok=False)
call('fm-send.sh','source','--action-id',a['id'],'--expected-generation','g1','Fill the existing acceptance evidence.',actor='branch',extra={'FM_BRANCH_TASK_BINDINGS':'{}'},ok=False)
call('fm-send.sh','source','--action-id',a['id'],'--expected-generation','g1','Fill the existing acceptance evidence.',actor='branch',extra={'FM_BRANCH_GENERATION':'old'},ok=False)
call('fm-send.sh','source','--action-id',a['id'],'--expected-generation','g1','Fill the existing acceptance evidence.',actor='branch',extra={'FM_BRANCH_TASK_SCOPE':'["other"]'},ok=False)
# Expiry is checked at the effect boundary, independently of model judgment.
expired=copy.deepcopy(r);expired['delegation']['expires_at']='2020-01-01T00:00:00Z';expired['delegation']['revision']+=1;expired['precheck']=None;reconcile(expired,ok=False)
revoked=copy.deepcopy(r);revoked['delegation']['revision']+=1;revoked['delegation']['revoked']=True;revoked['precheck']=None;r=reconcile(revoked)
expired=copy.deepcopy(r);expired['delegation']['expires_at']='2020-01-01T00:00:00Z';expired['delegation']['revision']+=1;expired['delegation']['revoked']=False;r=reconcile(expired)
call('fm-send.sh','source','--action-id',a['id'],'--expected-generation','g1','Fill the existing acceptance evidence.',actor='branch',ok=False)
revoked=copy.deepcopy(r);revoked['delegation']['revision']+=1;revoked['delegation']['revoked']=True;r=reconcile(revoked)
r['delegation']['expires_at']='2099-01-01T00:00:00Z';r['delegation']['revision']+=1;r['delegation']['revoked']=False;r=reconcile(r)

session.write_text('{"type":"session","id":"s"}\n'+json.dumps(dict(type='custom',id='i1',parentId=None,customType='fm-continuation-input',data=dict(id='new',text='Change scope',task='source',pending=True)))+'\n')
call('fm-send.sh','source','--action-id',a['id'],'--expected-generation','g1','Fill the existing acceptance evidence.',actor='branch',ok=False)
assert not (home/'state/source.inbox').exists()
with session.open('a') as f:f.write(json.dumps(dict(type='custom',id='i2',parentId='i1',customType='fm-continuation-input',data=dict(id='new',text='Change scope',task='source',pending=False)))+'\n')
# Ordinary chat and another task's pending intent cannot veto this task.
with session.open('a') as f:
    f.write(json.dumps(dict(type='custom',id='chat',parentId='i2',customType='fm-continuation-input',data=dict(id='chat',text='How does configuration work?')))+'\n')
    f.write(json.dumps(dict(type='custom',id='other-update',parentId='chat',customType='fm-continuation-input',data=dict(id='other',text='Change other task',task='other',pending=True)))+'\n')
# Inject a process boundary failure after the real enqueue, before receipt binding.
owner=bin/'fm-task-lifecycle.py';candidate=owner.read_text()
owner.write_text(candidate.replace("        elif args.operation == 'bind-inbox':", "        elif args.operation == 'bind-inbox':\n            raise Refusal('fixture crash after enqueue')"))
call('fm-send.sh','source','--action-id',a['id'],'--expected-generation','g1','Fill the existing acceptance evidence.',actor='branch',ok=False)
owner.write_text(candidate)
assert not state('lifecycle')['next_action'].get('continuation')
state('readback','source',actor='branch')
assert len(list((home/'state/source.inbox').glob('*.msg')))==1
r=state('lifecycle');assert r['next_action']['phase']=='attempted'
call('fm-send.sh','source','--action-id',a['id'],'--expected-generation','g1','Fill the existing acceptance evidence.',actor='branch',ok=False)
msg=next((home/'state/source.inbox').glob('*.msg'));handled=msg.parent/'handled'/msg.name
# Durable enqueue is not executor acknowledgement.
state('action','source','--action-id',a['id'],'--phase','confirmed','--receipt-ref',str(msg),'--receipt-sha256',sha(msg),actor='branch',ok=False)
msg.rename(handled)
state('action','source','--action-id',a['id'],'--phase','confirmed','--receipt-ref',str(handled),'--receipt-sha256',sha(handled),actor='branch')
# Exact provisional candidate remains open and its evidence cannot be silently replaced.
r=state('lifecycle');basis=state('observe')['basis_key'];evidence=dict(ref=str(handled),sha256=sha(handled))
check.update(delegation_revision=r['delegation']['revision'],basis_key=basis,conclusion='candidate',checks=[dict(criterion='brief acceptance',result='present',evidence=[evidence])],summary='Ready for MAIN semantic assessment')
r=patch({'precheck':check});assert r['disposition']=='open' and state('observe')['delegated']==False
actual=handled.read_bytes();handled.write_bytes(actual+b'changed')
bad=copy.deepcopy(r);bad['disposition']='accepted';bad['assessment']['remaining_gap']='';reconcile(bad,ok=False)
handled.write_bytes(actual)

bad=copy.deepcopy(r);bad['goal_revision']+=1;reconcile(bad,ok=False)
# Revoke preserves receipts/budgets and invalidates the old candidate.
r['delegation']['revision']+=1;r['delegation']['revoked']=True;r['precheck']=None;r=reconcile(r)
patch({'precheck':dict(check,delegation_revision=r['delegation']['revision']-1)},ok=False)
# Explicit renewal and target generation binding for cross-task handoff.
r['delegation']['revision']+=1;r['delegation']['revoked']=False;r=reconcile(r)
a=new_action(r,'Deliver authorized prerequisite evidence.');r=patch({'next_action':a})
call('fm-lease.sh','claim','target','--actor','main')
call('fm-task-handoff.sh','send','source','target','--id','dependency-one','--action-id',a['id'],'Deliver authorized prerequisite evidence.',actor='branch',ok=False)
assert not (home/'state/target.inbox').exists()
# A queued old branch instruction cannot bypass the input barrier when MAIN's
# lease release automatically retries its original durable handoff.
with session.open('a') as f:f.write(json.dumps(dict(type='custom',id='i3',parentId='other-update',customType='fm-continuation-input',data=dict(id='newer',text='Classify this new intent',task='source',pending=True)))+'\n')
call('fm-lease.sh','release','target','--actor','main')
assert not (home/'state/target.inbox').exists()
with session.open('a') as f:f.write(json.dumps(dict(type='custom',id='i4',parentId='i3',customType='fm-continuation-input',data=dict(id='newer',text='Classify this new intent',task='source',pending=False)))+'\n')
call('fm-task-handoff.sh','retry','dependency-one',actor='branch')
(home/'state/task-handoffs/status/dependency-one.state').unlink()
call('fm-task-handoff.sh','retry','dependency-one',actor='branch')
assert len(list((home/'state/target.inbox').glob('*.msg')))==1
assert state('lifecycle')['next_action']['continuation']['handoff_id']=='dependency-one'
# A newer execution cannot be reached by an old task-bound request.
(home/'state/target.meta').write_text((home/'state/target.meta').read_text().replace('spawn_gen=g1','spawn_gen=g2'))
call('fm-task-handoff.sh','send','source','target','--id','dependency-wrong-generation','--action-id',a['id'],'Deliver authorized prerequisite evidence.',actor='branch',ok=False)
assert len(list((home/'state/target.inbox').glob('*.msg')))==1
# v1 remains unenrolled in delegation and ordinary typed/inbox behavior stays independent.
assert state('lifecycle','legacy')['schema']=='fm-task-lifecycle.v1'
call('fm-send.sh','legacy','Ordinary v1 steer',actor='branch')
# Two opposite dependency edges use the actual public handoff owners concurrently.
# One uncertain effect fences its target until readback; neither retains locks
# while waiting for the other task, and both immutable bodies survive.
pair={}
for name,other in (('cycle-a','cycle-b'),('cycle-b','cycle-a')):
    d=home/'data'/name;d.mkdir();(d/'brief.md').write_text('Exchange the already authorized prerequisite evidence.')
    (home/'state'/f'{name}.meta').write_text(f'window=fixture:w1:p-{name}\nbackend=herdr\nharness=pi\nkind=ship\nexecutor=local-agent\nspawn_gen=g1\n')
    rr=state('enroll',name);rr['schema']='fm-task-lifecycle.v2';rr['precheck']=None
    rr['delegation']=dict(revision=1,issuer='main',authority_ref=f'data/{name}/brief.md',authority_sha256=sha(d/'brief.md'),allowed=['inspect','precheck','steer-same-intent','observe-receipt','handoff'],edges=[dict(target=other,goal_revision=1,execution_generation='g1',authority_ref=f'data/{name}/brief.md',authority_sha256=sha(d/'brief.md'),scope='Existing prerequisite exchange')],expires_at='2099-01-01T00:00:00Z',revoked=False)
    payload=d/'payload';payload.write_text('Exact existing evidence from '+name)
    rr['next_action']=dict(id=name+'.g1.a1',kind='steer',phase='prepared',expected_execution_generation='g1',attempts=0,attempt_limit=1,recheck_at='2026-01-01T00:00:00Z',deadline='2099-01-01T00:00:00Z',payload_ref=str(payload),payload_sha256=sha(payload),receipt_ref=None)
    rr['next_action_seq']=2;pair[name]=reconcile(rr)
bindings={name:dict(goal_revision=rr['goal_revision'],brief_sha256=rr['brief_sha256'],execution_generation='g1',delegation_revision=1) for name,rr in pair.items()}
cycle_env=dict(env,FM_SUPERVISION_ACTOR='branch',FM_BRANCH_TASK_SCOPE=json.dumps(list(pair)),FM_BRANCH_TASK_BINDINGS=json.dumps(bindings))
children=[]
for name,other in (('cycle-a','cycle-b'),('cycle-b','cycle-a')):
    children.append(subprocess.Popen([str(bin/'fm-task-handoff.sh'),'send',name,other,'--id',name+'-edge','--action-id',name+'.g1.a1','Exact existing evidence from '+name],env=cycle_env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE))
for child in children:
    stdout,stderr=child.communicate(timeout=20);assert child.returncode in (0,6),(stdout,stderr)
assert sum(c.returncode==0 for c in children)==1
for name in pair:assert (home/'state/task-handoffs/records'/f'{name}-edge.msg').exists()
first='cycle-a' if children[0].returncode==0 else 'cycle-b';other='cycle-b' if first=='cycle-a' else 'cycle-a'
msg=next((home/'state'/f'{other}.inbox').glob('*.msg'));handled=msg.parent/'handled'/msg.name;msg.rename(handled)
state('action',first,'--action-id',first+'.g1.a1','--phase','confirmed','--receipt-ref',str(handled),'--receipt-sha256',sha(handled))
call('fm-task-handoff.sh','retry',other+'-edge',actor='branch',extra={'FM_BRANCH_TASK_SCOPE':json.dumps(list(pair)),'FM_BRANCH_TASK_BINDINGS':json.dumps(bindings)})
for name in pair:call('fm-task-handoff.sh','retry',name+'-edge',actor='branch',extra={'FM_BRANCH_TASK_SCOPE':json.dumps(list(pair)),'FM_BRANCH_TASK_BINDINGS':json.dumps(bindings)})
assert sum(len(list((home/'state'/f'{name}.inbox').rglob('*.msg'))) for name in pair)==2
print('ok - delegated lifecycle: semantic ownership, CAS/no-op, intake/body fences, once-only effects, receipt/start, candidate/revoke, dependency identity and cyclic contention')
PY
}

test_routine_continuation_policy_and_exact_handled_receipt() {
  ROOT="$ROOT" CASE_DIR="$TMP_ROOT/routine-policy" FM_FIXTURE_BACKEND="$(make_fake_backend "$TMP_ROOT/routine-policy")" python3 - <<'PY'
import hashlib, json, os, pathlib, shutil, subprocess
root=pathlib.Path(os.environ['ROOT']);home=pathlib.Path(os.environ['CASE_DIR'])
for name in ('state','data','config'): (home/name).mkdir(parents=True)
(home/'state/.lock').write_text(str(os.getpid())+'\n')
bin=home/'bin';shutil.copytree(root/'bin',bin)
provider_state=home/'provider-state';provider_state.write_text('working')
(bin/'fm-crew-state.sh').write_text('#!/bin/sh\nprintf "state: %s · source: policy-fixture\\n" "$(cat "$FM_HOME/provider-state")"\n')
(bin/'fm-crew-state.sh').chmod(0o755)
session=home/'main.jsonl';session.write_text('{"type":"session","id":"policy"}\n')
env=dict(os.environ,FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),
         FM_CONFIG_OVERRIDE=str(home/'config'),FM_LEASE_HOLDER_PID=str(os.getpid()),FM_BRANCH_GENERATION='1',
         FM_BRANCH_MAIN_SESSION_FILE=str(session),FM_BRANCH_TASK_SCOPE='["routine"]',
         PATH=os.environ['FM_FIXTURE_BACKEND']+':'+os.environ['PATH'])
def call(*args,actor='main',ok=True,bindings=None):
    e=dict(env,FM_SUPERVISION_ACTOR=actor)
    if bindings is not None:e['FM_BRANCH_TASK_BINDINGS']=json.dumps(bindings)
    p=subprocess.run([str(bin/'fm-task-state.sh'),*args],env=e,text=True,capture_output=True,timeout=20)
    assert (p.returncode==0)==ok,(args,p.returncode,p.stdout,p.stderr)
    return json.loads(p.stdout) if ok and p.stdout.strip() else p.stdout+p.stderr
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def write_json(path,value):path.write_text(json.dumps(value));path.chmod(0o600);return str(path)
task='routine';directory=home/'data'/task;directory.mkdir();(directory/'brief.md').write_text('Continue the unchanged goal and retain verified evidence.\n')
(home/'state'/f'{task}.meta').write_text('window=fixture:w1:p-routine\nbackend=herdr\nharness=pi\nkind=ship\nexecutor=local-agent\nspawn_gen=g1\n')
call('enroll',task)
authority=home/'data/policy-authority.md';authority.write_text('Routine continuation ownership authorized for eligible current and future tasks.\n')
policy=dict(schema='fm-task-continuation-policy.v1',revision=0,issuer='main',enabled=True,
            authority_ref='data/policy-authority.md',authority_sha256=sha(authority),
            allowed=['inspect','precheck','steer-same-intent','observe-receipt'],expires_at='2099-01-01T00:00:00Z')
policy_file=home/'data/policy.json';write_json(policy_file,policy)
assert call('continuation-policy','--expected-revision','0','--record',str(policy_file))['revision']==1
r=call('refresh',task);r=call('lifecycle',task)
assert r['schema']=='fm-task-lifecycle.v2' and r['delegation']['policy_revision']==1
binding={task:dict(goal_revision=r['goal_revision'],brief_sha256=r['brief_sha256'],execution_generation=r['execution_generation'],delegation_revision=r['delegation']['revision'])}
subprocess.run([str(bin/'fm-wake-grant.sh'),'activate',str(os.getpid()),'1'],env=env,check=True,capture_output=True,text=True)
call('observe',task,actor='branch',bindings=binding)
assert call('inspect',task,actor='branch',bindings=binding)['execution_generation']=='g1'
assert call('refresh',task,actor='branch',bindings=binding)['execution_generation']=='g1'
call('continuation-policy','--expected-revision','1','--record',str(policy_file),actor='branch',ok=False)

body=b'Collect the already-authorized validation evidence.\n'
payload=directory/'payload';payload.write_bytes(body)
handled_dir=home/'state'/f'{task}.inbox/handled';handled_dir.mkdir(parents=True)
legacy_receipt=handled_dir/'001.msg';legacy_receipt.write_bytes(b'schema=fm-task-inbox.v1\nat=2026-10-01T00:00:00Z\n--\n'+body)
stale_receipt=handled_dir/'002.msg';stale_receipt.write_bytes(b'schema=fm-task-inbox.v1\nat=2026-10-01T00:00:00Z\nexecution_generation=g0\n--\n'+body)
receipt=handled_dir/'003.msg';receipt.write_bytes(b'schema=fm-task-inbox.v1\nat=2026-10-01T00:00:00Z\nexecution_generation=g1\n--\n'+body)
action=dict(id='routine.g1.a1',kind='steer',phase='prepared',expected_execution_generation='g1',attempts=0,attempt_limit=1,
            recheck_at='2026-01-01T00:00:00Z',deadline='2099-01-01T00:00:00Z',payload_ref=str(payload),payload_sha256=sha(payload),receipt_ref=None)
patch=dict(delegation_revision=r['delegation']['revision'],next_action=action)
patch_file=home/'data/patch.json';write_json(patch_file,patch)
r=call('branch-patch',task,'--expected-revision',str(r['revision']),'--record',str(patch_file),actor='branch',bindings=binding)
binding[task]['delegation_revision']=r['delegation']['revision']
call('observe-receipt',task,'--action-id',action['id'],'--receipt-ref',str(legacy_receipt),actor='branch',bindings=binding,ok=False)
call('observe-receipt',task,'--action-id',action['id'],'--receipt-ref',str(stale_receipt),actor='branch',bindings=binding,ok=False)
assert call('lifecycle',task)['next_action']['phase']=='prepared'
r=call('observe-receipt',task,'--action-id',action['id'],'--receipt-ref',str(receipt),actor='branch',bindings=binding)
assert r['next_action']['phase']=='confirmed' and r['next_action']['attempts']==0
assert r['next_action']['continuation']['inbox_id']=='003'

# Revocation fences the previously materialized grant immediately. Re-enable
# produces a new policy revision and a new exact task grant only after the
# earlier action is safely terminal.
disabled=dict(policy,revision=1,enabled=False);write_json(policy_file,disabled)
assert call('continuation-policy','--expected-revision','1','--record',str(policy_file))['revision']==2
assert call('observe',task,actor='branch',bindings=binding)['delegated'] is False
call('refresh',task,actor='branch',bindings=binding,ok=False)
enabled=dict(policy,revision=2,enabled=True);write_json(policy_file,enabled)
assert call('continuation-policy','--expected-revision','2','--record',str(policy_file))['revision']==3
r=call('refresh',task);r=call('lifecycle',task)
assert r['delegation']['policy_revision']==3 and r['delegation']['revision']==2
new_binding={task:dict(goal_revision=r['goal_revision'],brief_sha256=r['brief_sha256'],execution_generation=r['execution_generation'],delegation_revision=2)}
assert call('observe',task,actor='branch',bindings=binding)['delegated'] is False
assert call('observe',task,actor='branch',bindings=new_binding)['delegated'] is True

# A deliberately paused executor remains inspectable but cannot acquire a new
# same-intent effect through the standing policy.
provider_state.write_text('paused')
next_payload=directory/'payload-2';next_payload.write_text('Do not resume a deliberately paused executor.\n')
next_action=dict(action,id='routine.g1.a2',payload_ref=str(next_payload),payload_sha256=sha(next_payload))
write_json(patch_file,dict(delegation_revision=2,next_action=next_action))
call('branch-patch',task,'--expected-revision',str(r['revision']),'--record',str(patch_file),actor='branch',bindings=new_binding,ok=False)
assert call('lifecycle',task)['next_action']['id']=='routine.g1.a1'
print('ok - routine policy: automatic exact grants, branch-only bounded operations, revocation/renewal, handled receipt dedupe and paused-effect fencing')
PY
}

test_conflict_preserves_then_delivers_exactly_once
test_restart_sweep_recovers_pending_handoff
test_sweep_without_handoffs_is_a_noop
test_local_runtime_backend_matrix_uses_one_durable_plane
test_terminal_refusal_is_durable
test_bound_terminal_source_is_permanently_rejected
test_same_task_send_and_reminder_contract_stay_ordinary

test_continuation_assessment_and_observed_executor || fail "lifecycle behavior regression failed"
# shellcheck disable=SC2097,SC2098 # Export the existing root to the Python fixture.
ROOT="$ROOT" CASE_DIR="$TMP_ROOT/semantic" FM_FIXTURE_BACKEND="$(make_fake_backend "$TMP_ROOT/semantic")" \
  python3 "$ROOT/tests/lifecycle-semantic.py" || fail "semantic lifecycle regression failed"
test_delegated_lifecycle_effect_boundaries || fail "delegated lifecycle regression failed"
test_routine_continuation_policy_and_exact_handled_receipt || fail "routine continuation policy regression failed"
printf 'All task-handoff tests passed.\n'
