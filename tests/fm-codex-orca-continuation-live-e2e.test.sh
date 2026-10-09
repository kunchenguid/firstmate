#!/usr/bin/env bash
# Opt-in, read-only live receipt/turn-event guard for an attended Orca Codex
# primary. Root supplies native turn events from two actual final-to-wake
# cycles and invokes this from the lock-owning primary. This does not launch,
# send, ACK, close or adopt any endpoint. It is not a substitute for the
# independently attended observer and bounded recovery required by the test.
# Usage: FM_CODEX_ORCA_CONTINUATION_LIVE=1 FM_HOME=<home>
#        FM_ORCA_CONTINUATION_EVENTS=<native-event-array.json> <this-script>
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_ORCA_CONTINUATION_LIVE codex python3
: "${FM_HOME:?explicit FM_HOME required}"
: "${ORCA_TERMINAL_HANDLE:?run from the actual Orca primary}"
: "${FM_ORCA_CONTINUATION_EVENTS:?root native final/complete/start events required}"
context=$(python3 "$ROOT/bin/fm-codex-orca-continuation.py" context --home "$FM_HOME" --code-root "$ROOT")
status=$(python3 "$ROOT/bin/fm-codex-orca-continuation.py" status --home "$FM_HOME" --code-root "$ROOT")
FM_ORCA_GUARD_CONTEXT="$context" FM_ORCA_GUARD_STATUS="$status" python3 - <<'PY'
import datetime,json,os,pathlib
binding=json.loads(os.environ['FM_ORCA_GUARD_CONTEXT'])
current=json.loads(os.environ['FM_ORCA_GUARD_STATUS'])
assert current['ready'] is True and current['binding']==binding, 'actual bound owner is not ready'
events=json.loads(pathlib.Path(os.environ['FM_ORCA_CONTINUATION_EVENTS']).read_text())
assert isinstance(events,list), 'native events must be an array'
def epoch(event):
 return datetime.datetime.fromisoformat(event['timestamp'].replace('Z','+00:00')).timestamp()
pairs=[]
final=complete=None
for event in sorted(events,key=epoch):
 if event['type']=='assistant_final': final=epoch(event)
 elif event['type']=='task_complete':
  assert final is not None and final<=epoch(event), 'completion lacks an actual final'
  complete=epoch(event)
 elif event['type']=='task_started' and complete is not None:
  pairs.append((complete,epoch(event)));final=complete=None
assert len(pairs)>=2, 'two native final/complete/new-start cycles required'
matched=[]
for p in (pathlib.Path(os.environ['FM_HOME'])/'state/.codex-orca-continuation').glob('*.json'):
 episode=json.loads(p.read_text())
 if episode.get('phase')!='turn-started': continue
 if (episode.get('owner_generation')!=current['generation'] or episode.get('owner_pid')!=current['owner_pid']
     or episode.get('owner_identity')!=current['owner_identity'] or episode.get('binding')!=binding): continue
 for row in episode['attempts']:
  if row['exit']!=0: continue
  receipt=json.loads(row['stdout']);send=receipt['result']['send'];prompt=send['prompt']
  if (receipt.get('ok') is not True or send.get('accepted') is not True
      or send['handle']!=binding['target']['handle'] or receipt['_meta']['runtimeId']!=binding['target']['runtimeId']
      or prompt['processIncarnation']!=binding['target']['incarnationId'] or prompt['provider']!='codex'
      or not prompt['requestId'] or not {'input_accepted','turn_started'}<=set(prompt['stages'])): continue
  for index,(end,start) in enumerate(pairs):
   if end<row['submitted_at']<=start<=row['at']+2:
    matched.append((index,episode['generation'],prompt['requestId'],row['successor'][0]))
valid=False
for a in matched:
 for b in matched:
  if a[0]<b[0] and a[1]!=b[1] and a[2]!=b[2] and a[3]!=b[3]: valid=True
assert valid, 'two distinct post-completion receipts and verified successors were not correlated'
print('ok - actual bound Orca/Codex owner has two distinct native final-to-turn-start receipt correlations')
print('evidence: '+json.dumps(matched))
PY
printf 'ok - %s live receipt guard; observer samples, ACK and cleanup remain separately required\n' "$(codex --version)"
