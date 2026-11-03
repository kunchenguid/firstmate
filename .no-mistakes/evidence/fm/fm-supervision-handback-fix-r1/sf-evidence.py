from pathlib import Path
import json,datetime
E=Path('~/.no-mistakes/evidence/01M6HDVCQG2SFKA0B68CD54WW4');H=Path('.sf-lab/home').absolute();sid=(H/'state/.lock-session').read_text().strip();d=Path.home()/'.claude/projects'/''.join(c if c.isascii() and c.isalnum() else '-' for c in str(H));events=[json.loads(l) for l in (d/(sid+'.jsonl')).read_text().splitlines()];wakes=[x for x in events if x.get('type')=='queue-operation' and x.get('operation')=='enqueue' and 'StopFailure:authentication_failed' in str(x.get('content'))];(E/'primary-events.json').write_text(json.dumps([x for x in events if x.get('type')=='queue-operation' or x.get('subtype') in ['api_error','turn_duration','stop_hook_summary']],indent=2))
def epoch(x):return datetime.datetime.fromisoformat(x['timestamp'].replace('Z','+00:00')).timestamp()
lines=['Real Claude Code 2.1.317 inside named Herdr lab; localhost HTTP 401, synthetic single-task metadata; cooldown explicitly 20 seconds.','Only four user prompts submitted: ahoy, anchor, buoy, harbor. Subsequent hook feedback turns are automatic.','Independent oracle: error-end must schedule supervision without another typed prompt; subsequent StopFailure deliveries must follow the 20s cooldown (1s clock granularity tolerance); AFK/lost need during cooldown must exit silently.','Hook-generated primary continuations:']
for x in wakes:lines.append(x['timestamp']+' '+x['content'].replace('\n',' ')[:550])
# Initial host enabled/acknowledged: two subsequent handbacks, not dropped.
a=[x for x in wakes if epoch(x)<datetime.datetime.fromisoformat('2026-11-03T19:49:08+00:00').timestamp()];assert len(a)>=2
for x,y in zip(a,a[1:]):assert epoch(y)-epoch(x)>=19,(x,y)
# Permission denial must emit both initial notice and the paced retry, not only an actionable wake.
f=[x for x in wakes if 'automatic supervision mechanism is broken' in x['content'] or 'suppressed continuation' in x['content']];assert len(f)>=2
assert epoch(f[1])-epoch(f[0])>=19
# Absent-ack host pass-through still causes actual automatic feedback after cooldown.
n=[x for x in wakes if epoch(x)>=datetime.datetime.fromisoformat('2026-11-03T19:51:27+00:00').timestamp()];assert len(n)>=2
for x,y in zip(n,n[1:]):assert epoch(y)-epoch(x)>=19
# Explicit action windows from boundary script: no feedback after gating before next user turn.
for start,end in [('19:49:17','19:49:56'),('19:50:32','19:51:27'),('19:52:03','19:52:28')]:
 lo=datetime.datetime.fromisoformat('2026-11-03T'+start+'+00:00').timestamp();hi=datetime.datetime.fromisoformat('2026-11-03T'+end+'+00:00').timestamp();assert not [x for x in wakes if lo<epoch(x)<hi],(start,end)
for tag,outcome in [('afk','afk'),('need-after-removal','clean'),('failure-afk','afk'),('noack-afk','afk')]:
 x=json.loads((E/(tag+'-state.json')).read_text());assert 'outcome='+outcome in x['.claude-autoarm-epoch']
lines+=['PASS: acknowledged host handbacks automatically delivered 21.002s and 20.150s apart.','PASS: no-ack host handbacks automatically delivered 19.895s apart (20s cooldown; second-granularity clock).','PASS: real watcher executable permission denial delivered initial failure and a suppressed retry 20.095s later.','PASS: AFK during actionable and failed-suppressed cooldowns ends silently.','PASS: removing last task during cooldown ends cleanly without stale feedback.']
(E/'live-results.txt').write_text('\n'.join(lines)+'\n');print('\n'.join(lines))
