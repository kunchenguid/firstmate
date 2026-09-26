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
  ROOT="$ROOT" CASE_DIR="$TMP_ROOT/lifecycle" python3 - <<'PY'
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
state('action','--action-id',a['id'],'--phase','attempted')
r=receipt('uncertain'); oldkey=state('observe')['key']
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
fake=home/'fakebin';fake.mkdir()
(fake/'tmux').write_text('#!/bin/sh\ncase "$1" in capture-pane) printf "╭────╮\\n│    │\\n╰────╯\\n" ;; display-message) printf "1\\n" ;; esac\nexit 0\n')
(fake/'tmux').chmod(0o755);env['PATH']=str(fake)+os.pathsep+env['PATH']
with (home/'state/target.meta').open('a') as f: f.write('backend=tmux\nwindow=fm-target\nharness=pi\nendpoint_task_id=target\n')
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
# Explicit archive refuses until the outstanding action has owner readback.
bad=copy.deepcopy(r);bad['disposition']='archived';reconcile(bad,ok=False)
r=receipt('refused')
(home/'data/stop').write_text('Explicitly stop this request; retain its local work.')
r['disposition']='archived';r['assessment']['authority_ref']='data/stop';r=reconcile(r)
assert state('observe')['state']=='archived'
call('fm-control.sh','source','relaunch','--note','must not revive stopped work',ok=False)
call('fm-task-handoff.sh','send','source','target','--id','stopped-request','must not revive stopped work',ok=False)
assert len(list(queued.rglob('*.msg')))==2
bad=copy.deepcopy(r);bad['disposition']='open';reconcile(bad,ok=False)
# A later, separate goal cannot overwrite this goal's revision or stopped state.
call('fm-task-state.sh','enroll','target');assert state('observe')['state']=='archived'
# Newly spawned work can bind its launch brief, but a submitted-launch busy
# seed is not observed execution. Existing harness readers own that distinction.
t=call('fm-task-state.sh','lifecycle','target')
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

test_conflict_preserves_then_delivers_exactly_once
test_restart_sweep_recovers_pending_handoff
test_sweep_without_handoffs_is_a_noop
test_local_runtime_backend_matrix_uses_one_durable_plane
test_terminal_refusal_is_durable
test_same_task_send_and_reminder_contract_stay_ordinary

test_continuation_assessment_and_observed_executor
printf 'All task-handoff tests passed.\n'
