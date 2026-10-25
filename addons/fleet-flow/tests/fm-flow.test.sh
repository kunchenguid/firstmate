#!/usr/bin/env bash
# Integration: query the real flow CLI over isolated durable fleet records.
# Run it with FM_BIN pointing at a Firstmate checkout's bin/: the reader sources
# its helper libraries from there and the second block drives the fork's
# model/skill statistics and outcome-recording readers, which did not move.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ -n "${FM_BIN:-}" ] && [ -f "$FM_BIN/fm-classify-lib.sh" ] || {
  echo "fm-flow test: set FM_BIN to a Firstmate checkout's bin/ (helper libraries live there)" >&2
  exit 2
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/xdg" "$TMP/tmp"
HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" TMPDIR="$TMP/tmp" python3 - "$ROOT/bin/fm-flow.sh" "$TMP" <<'PY'
import hashlib, json, os, shlex, shutil, socket, subprocess, sys, threading
from pathlib import Path
script, tmp = sys.argv[1], Path(sys.argv[2])
main, child = tmp / 'main', tmp / 'child'
for h in (main, child):
    (h / 'state').mkdir(parents=True)
    (h / 'data').mkdir()
    (h / 'data/backlog.md').write_text('## Queued\n')
(main / 'data/secondmates.md').write_text(f'- child - Worker (home: {child}; scope: app; projects: app)\n')
(child / 'data/secondmates.md').write_text(f'- main - Parent (home: {main}; scope: fleet; projects: app)\n')
# Exact rejected-key return from writeboost.status; key and timestamp remain unknown.
(main / 'state/child.status').write_text('done [key=ov-rn-setup-polish corr=03b23bf8e7b2c26c]: PR 26 merged and verified - guarded merge read back state=MERGED at the exact checked head 2c7f3076 with all checks green; task cleaned up; per your words, production-phone replacement and live ChatGPT remain separately unapproved\n')
(main / 'data/backlog.md').write_text('## Queued\n- [ ] next - Next blocked-by: prior\n'
    '- [ ] held - Held (hold: fm-hold-v1:V2FpdCBmb3IgWW91)\n'
    '- [ ] ready - Ready blocked-by: finished\n## In flight\n- [ ] prior - Prerequisite\n'
    '## Done\n- [x] finished - Completed\n')
(child / 'state/live.meta').write_text('kind=ship\nspawn_gen=s99.1.2\n')
(child / 'state/live.status').write_text('working [at=10]: building\n'
    'needs-decision [at=20] [key=captain-hold-a]: choose scope\n'
    'blocked [at=25] [key=external]: external credential\n'
    'done [at=30]: implemented\nresolved [at=40] [key=external]: credential ready\n'
    'working [at=50]: resumed\nworking [at=60]: still working\n')
(child / 'state/unknown.meta').write_text('kind=scout\n')
(child / 'state/unknown.status').write_text('blocked: missing timestamp\n')
ledger = [dict(v=1, task='closed', ts=t, event='task.' + event) for t, event in
          [(10, 'dispatched'), (20, 'status'), (35, 'pr_ready'), (70, 'merged'), (80, 'cleaned_up')]]
ledger[1].update(state='working', text='building')
(child / 'state/fleet-ledger.jsonl').write_text('\n'.join(map(json.dumps, ledger + [ledger[3]])) + '\n{bad}\n')
def files():
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for h in (main, child) for p in h.rglob('*') if p.is_file()}
def run():
    return subprocess.check_output(['bash', script, '--json', '--now', '100'],
                                   env=dict((k, v) for k, v in dict(os.environ, FM_HOME=str(main), FM_DATA_OVERRIDE='').items()
                                            if k != 'TASKS_AXI_BACKEND'))
before = files()
a = run()
assert a == run() and files() == before, 'deterministic and read-only'
x = json.loads(a)
assert x['homes'] == ['child', 'main'], 'registry cycle deduplicated'
live = next(l for l in x['lanes'] if l['task'] == 'live')
assert live['seconds_in_stage'] == 50 and len(live['open_waits']) == 1
assert live['open_waits'][0]['seconds'] == 80, 'done/working do not close keyed wait'
assert live['times']['dispatched'] is None, 'spawn incarnation is not pickup'
assert live['state_seconds'] == {'working': 20, 'needs-decision': 5, 'blocked': 5, 'done': 10, 'resolved': 10}, 'stage time from recorded status intervals'
closed = x['executed_24h'][0]
assert len(x['executed_24h']) == 1 and closed['durations']['time_to_merge'] == 60
assert closed['durations']['merge_to_cleanup'] == 10
assert closed['state_seconds'] == {'working': 50}, 'the trailing stage runs to the merge'
assert 'pr_opened' not in closed['times'] and 'checks_green' not in closed['times']
assert x['time_to_merge']['median_seconds'] == x['time_to_merge']['p85_seconds'] == 60
assert {q['task']: q['why'] for q in x['queue']} == {'next': 'dependency: prior', 'held': 'hold: Wait for You',
    'ready': 'unknown: dispatch admission not recorded'}
assert next(b for b in x['bottlenecks'] if b['cause'] == 'unknown')['unknown_items'] == 1
assert any(n.get('line') == 7 for n in x['limitations']), 'malformed durable record disclosed'
assert sum(d['known'] + d['unknown'] for d in x['trend_7d']) == len(x['executed_7d'])
grand = tmp / 'grand'
(grand / 'state').mkdir(parents=True)
(grand / 'data').mkdir()
(grand / 'data/backlog.md').write_text('## Queued\n')
(grand / 'data/secondmates.md').write_text(f'- main - Parent (home: {main}; scope: fleet; projects: app)\n')
with open(child / 'data/secondmates.md', 'a') as f:
    f.write(f'- grand - Worker (home: {grand}; scope: app; projects: app)\n')
(child / 'state/grand.status').write_text('done [at=70] [key=merged-gtask]: merged\n')
with open(child / 'state/fleet-ledger.jsonl', 'a') as f:
    f.write(json.dumps(dict(v=1, task='reused', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='reused', ts=70, event='task.merged')) + '\n')
    f.write(json.dumps(dict(v=1, task='reused', ts=90, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='nullstage', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='nullstage', ts=20, event='task.status', state=None, key='k', text='t')) + '\n')
    f.write(json.dumps(dict(v=1, task='restale', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='restale', ts=20, event='task.status', state='blocked', key='k', text='stale')) + '\n')
    f.write(json.dumps(dict(v=1, task='restale', ts=90, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='nullwait', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='nullwait', ts=20, event='task.status', state='blocked', key='k', text=None)) + '\n')
    f.write(json.dumps(dict(v=1, task='relive', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='relive', ts=90, event='task.dispatched')) + '\n')
(child / 'state/relive.meta').write_text('kind=ship\n')
(child / 'state/relive.status').write_text('working [at=20]: building\nblocked [at=25] [key=stale-key]: waiting\n')
y = json.loads(run())
assert y['homes'] == ['child', 'grand', 'main'], 'nested home discovered'
bytask = {(l['home'], l['task']): l for l in y['lanes']}
assert bytask[('grand', 'gtask')]['times']['merged'] == 70, 'nested return-channel merge found'
assert bytask[('grand', 'gtask')]['durations']['time_to_merge'] is None, 'no guessed pickup'
assert 'gtask' in {l['task'] for l in y['executed_24h']}
assert bytask[('child', 'reused')]['times']['merged'] is None, 'reused id keeps no merge'
assert 'reused' not in {l['task'] for l in y['executed_24h']}
assert bytask[('child', 'nullstage')]['stage'] == 'unknown', 'null ledger state stays unknown'
restale = bytask[('child', 'restale')]
assert restale['stage'] == 'unknown' and restale['open_waits'] == [], 'reuse drops pre-dispatch status'
assert restale['seconds_in_stage'] is None and restale['times']['working'] is None
assert restale['reason'] == 'unknown: no status reason'
assert 'restale' not in {l['task'] for l in y['executed_24h']}
assert bytask[('child', 'nullwait')]['open_waits'][0]['reason'] == '', 'null wait text coerced'
relive = bytask[('child', 'relive')]
assert relive['open'] and relive['timestamp_basis'] == 'emitted'
assert relive['stage'] == 'unknown' and relive['open_waits'] == [], 'live reuse drops pre-dispatch status'
assert relive['seconds_in_stage'] is None and relive['times']['working'] is None
assert relive['reason'] == 'unknown: no status reason'
(main / 'config').mkdir()
(main / 'config/fm-flow-check.sh').write_text("clock = 30 if L['verb'] == 'needs-decision' else 50\n")
(main / 'config/lane-caps').write_text('main 0\n')
(main / 'data/captain-shared.md').write_text('# Captain notes\n- project-x: soft pause pending budget review\n')
(child / 'data/backlog.md').write_text('## In flight\n- [ ] hold-lane - Captain held task (hold: wait for captain) (hold-kind: captain)\n')
(child / 'state/hold-lane.meta').write_text('kind=ship\nproject=project-y\n')
(child / 'state/hold-lane.status').write_text('working [at=10]: started\n')
(child / 'state/project-paused.meta').write_text('kind=ship\nproject=project-x\n')
(child / 'state/project-paused.status').write_text('paused [at=10]: soft pause\n')
for task, reason in [('memory', 'fm-mem-gate: waiting (free 1 GB)'), ('credential', 'waiting for login'),
                     ('ci', 'waiting for CI queue'), ('merge', 'waiting for merge'),
                     ('mention', 'memory gate code fixed; waiting for new instructions')]:
    (child / 'state' / (task + '.meta')).write_text('kind=ship\n')
    (child / 'state' / (task + '.status')).write_text(f'blocked [at=10] [key=wait]: {reason}\n')
(child / 'state/mixed.meta').write_text('kind=ship\n')
(child / 'state/mixed.status').write_text('blocked [at=10] [key=a]: fm-mem-gate: waiting (free 1 GB)\n'
    'blocked [at=30] [key=a2]: fm-mem-gate: waiting (free 1 GB)\n'
    'blocked [key=a0]: fm-mem-gate: waiting (free 1 GB)\n'
    'needs-decision [at=20] [key=b]: waiting for merge\n')
(child / 'state/partknown.meta').write_text('kind=ship\n')
(child / 'state/partknown.status').write_text('blocked [at=10] [key=a]: fm-mem-gate: waiting (free 1 GB)\n'
    'blocked [key=b]: fm-mem-gate: waiting (free 1 GB)\n')
(child / 'state/smallmerge.meta').write_text('kind=ship\n')
(child / 'state/smallmerge.status').write_text('blocked [at=90] [key=wait]: waiting for merge\n')
z = json.loads(run())
new = {l['task']: l for l in z['lanes'] if l['open']}
assert new['hold-lane']['kind'] == 'ship' and new['hold-lane']['hold_kind'] == 'captain', new['hold-lane']
assert new['hold-lane']['open_waits'][-1]['cause'] == 'captain'
assert new['hold-lane']['open_waits'][-1]['reason'] == 'wait for captain'
assert new['project-paused']['project'] == 'project-x'
assert new['project-paused']['parked_reason'] == 'project-x: soft pause pending budget review'
for task, expected in [('memory', 'memory_gate'), ('credential', 'credential_external'),
                       ('ci', 'ci_queue'), ('merge', 'review_merge'), ('mention', 'unknown')]:
    assert new[task]['open_waits'][0]['cause'] == expected
    assert new[task]['stage_clock']['seconds'] == 50 and new[task]['stage_clock']['overdue'] is True
    assert new[task]['ci'] is None, 'no reported CI is not a zero or green'
mem_bucket = next(b for b in z['bottlenecks'] if b['cause'] == 'memory_gate')
merge_bucket = next(b for b in z['bottlenecks'] if b['cause'] == 'review_merge')
mem_item = next(i for i in mem_bucket['items'] if i['task'] == 'mixed')
merge_item = next(i for i in merge_bucket['items'] if i['task'] == 'mixed')
assert mem_item['seconds'] is None, 'unstamped same-cause wait keeps full total unknown'
assert mem_item['known_seconds'] == 90 and len(mem_item['waits']) == 3, 'within-cause maximum, not sum'
assert mem_item['unknown_waits'] == 1
assert merge_item['seconds'] == 80 and merge_item['known_seconds'] == 80
assert mem_bucket['known_lower_bound_lane_hours'] == (90 + 90 + 90) / 3600
assert mem_bucket['unknown_items'] == 2 and mem_bucket['unknown_waits'] == 2
part = next(i for i in mem_bucket['items'] if i['task'] == 'partknown')
assert part['seconds'] is None and part['known_seconds'] == 90 and part['unknown_waits'] == 1
assert [b['cause'] for b in z['bottlenecks']].index('memory_gate') < [b['cause'] for b in z['bottlenecks']].index('review_merge'), 'known lower bound ranks first'
assert mem_item['overlap'] is True and merge_item['overlap'] is True
assert mem_bucket['additive'] is False and merge_bucket['additive'] is False
assert next(i for i in mem_bucket['items'] if i['task'] == 'memory')['overlap'] is False
assert 'mixed' not in {i['task'] for i in next(b for b in z['bottlenecks'] if b['cause'] == 'unknown')['items']}
assert {q['task']: q['why'] for q in z['queue']}['ready'] == 'lane cap: 0 recorded active lanes, cap 0'
assert new['unknown']['stage_clock']['overdue'] is None, 'unstamped stage never guessed overdue'
scenarios = {
    'keyclose': [('blocked', 10, 'a', 'waiting for login'),
                 ('resolved', 20, None, '[key=a] login restored')],
    'noteopens': [('blocked', 10, None, '[key=a] waiting for login'),
                  ('blocked', 20, None, '[key=b] waiting for merge'),
                  ('captain-held', 30, 'a', 'held')],
    'reopened': [('blocked', 10, 'a', 'waiting for login'),
                 ('blocked', 20, None, '[key=a] waiting for merge'),
                 ('blocked', 30, 'b', 'waiting for merge')],
    'precedence': [('blocked', 10, 'a', '[key=b] waiting for login'),
                   ('resolved', 20, 'b', 'answered')],
    'pause': [('paused', 10, None, 'waiting for memory gate')],
    'repause': [('paused', 10, None, 'waiting for login'),
                ('paused', 20, None, 'waiting for memory gate')],
    'resumed': [('paused', 10, None, 'waiting for memory gate'),
                ('working', 20, None, 'building')],
    'decisionpause': [('blocked', 10, 'a', 'waiting for merge'),
                      ('paused', 20, None, 'waiting for memory gate')],
    'unknownpause': [('paused', None, None, 'waiting for memory gate')],
}
for representation in ('emitted', 'captured'):
    for task, entries in scenarios.items():
        task = representation + '-' + task
        (child / 'state' / (task + '.meta')).write_text('kind=ship\n')
        if representation == 'emitted':
            lines = [state + (f' [at={ts}]' if ts is not None else '') +
                     (f' [key={key}]' if key else '') + ': ' + text + '\n'
                     for state, ts, key, text in entries]
            (child / 'state' / (task + '.status')).write_text(''.join(lines))
        else:
            if any(ts is None for _, ts, _, _ in entries):
                continue
            with open(child / 'state/fleet-ledger.jsonl', 'a') as f:
                for state, ts, key, text in entries:
                    stored_key = key or (text.split(']', 1)[0][5:] if text.startswith('[key=') else None)
                    f.write(json.dumps(dict(v=1, task=task, ts=ts, event='task.status',
                                           state=state, key=stored_key, text=text)) + '\n')
result = json.loads(run())
rows = {l['task']: l for l in result['lanes']}
for representation in ('emitted', 'captured'):
    def lane(task):
        return rows[representation + '-' + task]
    assert lane('keyclose')['open_waits'] == [], 'note-head resolution closes the stated key'
    waits = lane('noteopens')['open_waits']
    assert [(w['key'], w['reason'], w['cause'], w['seconds']) for w in waits] == [
        ('b', 'waiting for merge', 'review_merge', 80)], 'distinct note-head keys and normalized reasons'
    waits = lane('reopened')['open_waits']
    assert [(w['key'], w['cause'], w['seconds']) for w in waits] == [
        ('a', 'review_merge', 80), ('b', 'review_merge', 70)], 'latest opener replaces cause and age'
    bucket = next(b for b in result['bottlenecks'] if b['cause'] == 'review_merge')
    item = next(i for i in bucket['items'] if i['task'] == representation + '-reopened')
    assert item['seconds'] == item['known_seconds'] == 80, 'distinct same-cause keys retain maximum'
    waits = lane('precedence')['open_waits']
    assert len(waits) == 1 and waits[0]['key'] == 'a' and waits[0]['reason'] == '[key=b] waiting for login'
    for task, seconds in [('pause', 90), ('repause', 80)]:
        waits = lane(task)['open_waits']
        assert len(waits) == 1 and waits[0]['key'] is None
        assert waits[0]['cause'] == 'memory_gate' and waits[0]['seconds'] == seconds
        bucket = next(b for b in result['bottlenecks'] if b['cause'] == 'memory_gate')
        item = next(i for i in bucket['items'] if i['task'] == representation + '-' + task)
        assert item['seconds'] == seconds and item['unknown_waits'] == 0
    assert lane('resumed')['open_waits'] == [], 'working ends the current declared pause'
    waits = lane('decisionpause')['open_waits']
    assert [(w['key'], w['cause'], w['seconds']) for w in waits] == [
        ('a', 'review_merge', 90), (None, 'memory_gate', 80)], 'pause does not overwrite keyed decision'
wait = rows['emitted-unknownpause']['open_waits'][0]
assert wait['seconds'] is None and wait['since'] is None, 'unstamped pause stays unknown'
(main / 'data/done-archive.md').write_text('## Done\n- [x] archived - Completed prerequisite\n')
with open(main / 'data/backlog.md', 'a') as f:
    f.write('## Queued\n- [ ] archive-ready - Archived prerequisite blocked-by: archived\n'
            '- [ ] multiple - Multiple dependencies blocked-by: archived blocked-by: prior\n')
with open(main / 'data/secondmates.md', 'a') as f:
    f.write(f'- macbook - Remote (host: macbook; root: /remote/repo; home: {grand}; scope: app; projects: app)\n')
before = files()
coverage = json.loads(run())
assert files() == before, 'authoritative backlog reads never mutate homes or archive'
assert coverage['homes'] == ['child', 'grand', 'macbook', 'main'], 'remote registration remains visible'
assert not any(l['home'] == 'macbook' for l in coverage['lanes']), 'remote path is never collected locally'
assert not any(q['home'] == 'macbook' for q in coverage['queue'])
remote = next(n for n in coverage['limitations'] if n['source'] == 'macbook')
assert remote['host'] == 'macbook' and remote['home'] == str(grand)
assert 'unknown' in remote['reason'] and 'remote' in remote['reason']
reasons = {q['task']: q['why'] for q in coverage['queue'] if q['home'] == 'main'}
assert reasons['archive-ready'] == 'lane cap: 0 recorded active lanes, cap 0'
assert reasons['multiple'] == 'dependency: prior', 'completed edges excluded, unresolved edge retained'
assert reasons['held'] == 'hold: Wait for You', 'consumer decodes hold reasons'
(grand / 'data/backlog.md').unlink()
before = files()
missing = json.loads(run())
assert files() == before and not (grand / 'data/backlog.md').exists(), 'missing backlog read does not create a file'
assert any(n['source'] == 'grand/backlog' and n['reason'].startswith('unknown:')
           for n in missing['limitations']), 'missing backlog is unknown, not a known empty queue'
(child / '.tasks.toml').write_text('backend = "beads"\n[beads]\npath = ".beads"\n'
                                   'bin = "./unavailable-bd"\nprefix = "flow"\n')
(child / 'data/backlog.md').write_text('## Queued\n- [ ] stale-markdown - Must not be consumed\n')
before = files()
unavailable = json.loads(run())
assert files() == before, 'unavailable alternate backend never migrates or changes its home'
assert not any(q['home'] == 'child' for q in unavailable['queue']), 'no stale markdown fallback after migration'
assert any(n['source'] == 'child/backlog' and n['reason'].startswith('unknown:')
           for n in unavailable['limitations']), 'unavailable alternate backend disclosed'
(main / 'config/fm-flow-check.sh').write_text('unrecognized clock policy\n')
assert next(l for l in json.loads(run())['lanes'] if l['task'] == 'memory')['stage_clock']['seconds'] is None
(main / 'config/fm-mem-gate.sh').write_text('min=${FM_MEM_MIN_GB:-12}\n'
    '[ "$psi" -lt 40 ] && [ "$running" -lt "${FM_EMU_MAX:-3}" ] && [ "$builds" -lt "${FM_GRADLE_MAX:-2}" ]\n'
    'echo "${FM_MEM_JOB_GB:-10}G"\n')
clean_env = dict(os.environ, FM_HOME=str(main))
for key in ('FM_MAC_HOST', 'XDG_DATA_HOME', 'FM_MEM_MIN_GB', 'FM_EMU_MAX', 'FM_GRADLE_MAX', 'FM_MEM_JOB_GB'):
    clean_env.pop(key, None)
before = files()
c = json.loads(subprocess.check_output(['bash', script, '--json', '--capacity'], env=clean_env))['capacity']
assert files() == before, 'native read-only census never writes the isolated home'
assert c['limits']['FM_EMU_MAX'] == 3 and c['limits']['FM_GRADLE_MAX'] == 2
assert c['gate_source'] == str(main / 'config/fm-mem-gate.sh')
# Installed gate (host-memory/install.sh): config/fm-mem-gate.sh is a shim, so the policy is read from the copy.
installed = tmp / 'home/.local/share/fm-host-memory/fm-mem-gate.sh'
installed.parent.mkdir(parents=True)
installed.write_text('min=${FM_MEM_MIN_GB:-12}\n[ "$psi" -lt 40 ] && [ "$running" -lt "${FM_EMU_MAX:-2}" ]\n'
    '[ "$builds" -lt "${FM_GRADLE_MAX:-1}" ] && echo "${FM_MEM_JOB_GB:-10}G"\n')
shim = (main / 'config/fm-mem-gate.sh').read_text()
(main / 'config/fm-mem-gate.sh').write_text('#!/usr/bin/env bash\nexec "${XDG_DATA_HOME:-$HOME/.local/share}/fm-host-memory/fm-mem-gate.sh" "$@"\n')
s = json.loads(subprocess.check_output(['bash', script, '--json', '--capacity'], env=clean_env))['capacity']
assert s['gate_source'] == str(installed), s['gate_source']
assert s['limits'] == dict(c['limits'], FM_EMU_MAX=2, FM_GRADLE_MAX=1), s['limits']
installed.unlink(); (main / 'config/fm-mem-gate.sh').write_text(shim)
assert c['mac']['reachable'] is None and c['mac']['available_bytes'] is None and c['mac']['simulators'] is None
if Path('/proc/meminfo').exists():
    assert c['memory_bytes']['MemTotal'] > 0 and 0 <= c['memory_bytes']['MemAvailable'] <= c['memory_bytes']['MemTotal']
for kind, limit in [('emulator', 3), ('gradle_gate_match', 2)]:
    if c['gate_counts'][kind] is not None:
        assert c['gate_counts'][kind] == sum(j['kind'] == kind for j in c['jobs'])
        assert c['slots_under_caps'][kind] == max(limit - c['gate_counts'][kind], 0)
assert all(j['rss_bytes'] is None or j['rss_bytes'] % 1024 == 0 for j in c['jobs'])
if c['tmp']['top_folders_complete'] is False:
    assert all(f['bytes'] is None and f['known_bytes'] >= 0 for f in c['tmp']['top_folders'])
# Real SSH stalls on a task-owned loopback banner exchange. A private port route
# extends SSH's own timeout so the flow CLI's six-second outer bound must win.
ssh = shutil.which('ssh')
assert ssh, 'native SSH client required for timeout integration'
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    listener.settimeout(30)
    banner = []
    def stalled_banner():
        with listener.accept()[0] as connection:
            connection.settimeout(30)
            while data := connection.recv(4096):
                banner.append(data)
    thread = threading.Thread(target=stalled_banner, daemon=True)
    thread.start()
    route = tmp / 'ssh-route'
    route.mkdir()
    config = route / 'config'
    config.write_text('Host *\n    UpdateHostKeys yes\n')
    effective = route / 'effective-options'
    native = shlex.quote(ssh) + ' -F ' + shlex.quote(str(config)) + \
        f' -p {listener.getsockname()[1]} -o ConnectTimeout=30'
    control = dict(line.split(None, 1) for line in subprocess.check_output(
        [ssh, '-G', '-F', str(config), 'nobody@127.0.0.1'], text=True).splitlines())
    assert control['updatehostkeys'] == 'true', 'private configuration enables host-key updates'
    wrapper = route / 'ssh'
    wrapper.write_text('#!/bin/sh\n' + native + ' -G "$@" > ' + shlex.quote(str(effective)) +
        ' || exit $?\nexec ' + native + ' "$@"\n')
    wrapper.chmod(0o700)
    before = files()
    stalled = json.loads(subprocess.check_output(['bash', script, '--json', '--capacity'],
        env=dict(clean_env, FM_MAC_HOST='nobody@127.0.0.1', PATH=str(route) + os.pathsep + os.environ['PATH']),
        timeout=45))
    thread.join(2)
    options = dict(line.split(None, 1) for line in effective.read_text().splitlines())
    assert options['updatehostkeys'] == 'false', 'flow CLI disables host-key updates in native SSH'
    assert banner and banner[0].startswith(b'SSH-'), 'actual SSH client reached private native transport'
    assert not thread.is_alive(), 'timed-out SSH connection closed'
    assert files() == before, 'timeout path also leaves fleet records untouched'
    assert any(n['source'] == 'Mac SSH probe' and 'timed out after 6 seconds' in n['reason']
               for n in stalled['limitations']), 'outer Mac deadline enforced with native SSH'
    mac = stalled['capacity']['mac']
    assert mac['reachable'] is None and mac['available_bytes'] is None and mac['simulators'] is None
bad = subprocess.run(['bash', script, '--json', '--now', 'bad'], capture_output=True)
assert bad.returncode == 2
print('PASS: real flow CLI, two homes, queue, keyed waits, retained lifecycle, unknowns, read-only determinism')
PY

# The per-model and per-skill readers and the outcome recorder: run the real CLIs
# over isolated durable records and read the JSON the dashboard's Models and Skills views consume.
mkdir -p "$TMP/stats"
HOME="$TMP/stats/home" XDG_CONFIG_HOME="$TMP/xdg" TMPDIR="$TMP/tmp" python3 - \
  "$FM_BIN/fm-model-stats.sh" "$FM_BIN/fm-skill-stats.sh" "$FM_BIN/fm-task-outcome.sh" "$TMP/stats" <<'PY'
import json, os, subprocess, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

model, skill, writer, tmp = sys.argv[1], sys.argv[2], sys.argv[3], Path(sys.argv[4])
now, day = 1700000000, 86400

def run(script, home):
    return subprocess.check_output(['bash', script, '--json', '--now', str(now)],
        env=dict(os.environ, FM_HOME=str(home), FM_DATA_OVERRIDE=''))
def iso(e):
    return datetime.fromtimestamp(e, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
def onday(off):
    return (datetime.fromtimestamp(now, timezone.utc) - timedelta(days=off)).strftime('%Y-%m-%d')
def stamps(home):
    return {str(p): p.stat().st_mtime_ns for p in home.rglob('*') if p.is_file()}

# Models: per-model rates, windows, per-home split, sampled fallback.
m, mb = tmp / 'main', tmp / 'byokit'
for h in (m, mb):
    (h / 'data/metrics').mkdir(parents=True, exist_ok=True)
    (h / 'state').mkdir(parents=True, exist_ok=True)
(m / 'data/secondmates.md').write_text(f'- byokit - BYOKit (home: {mb}; scope: toolkit; projects: byokit)\n')
oh = 'home\ttask\tkind\tproject\tmodels\tstarted\tended\toutcome\tpr\n'
(m / 'data/metrics/task-outcomes.tsv').write_text(oh +
    'main\tt1\tship\tacme\tclaude:claude-opus-5-5:medium\t%d\t%d\tmerged\thttps://github.com/acme/app/pull/1\n' % (now - 2*day, now - day) +
    'main\tt2\tship\tacme\tclaude:claude-opus-5-5:medium;pi:opencode-go/muse-spark-1.3-contributor:high\t%d\t%d\tmerged\thttps://github.com/acme/app/pull/2\n' % (now - 3*day, now - 2*day) +
    'main\tt3\tship\tacme\tpi:opencode-go/muse-spark-1.3-contributor:medium\t%d\t%d\tcancelled\t\n' % (now - 5*day, now - 4*day) +
    'main\tt4\tscout\tacme\tpi:opencode-go/muse-spark-1.3-contributor:medium\t%d\t%d\tscout\t\n' % (now - day, now - day) +
    'main\tt5\tship\tacme\tpi:opencode-go/muse-spark-1.3-contributor:medium\t%d\t%d\tmerged\thttps://github.com/acme/app/pull/5\n' % (now - 20*day, now - 19*day))
(mb / 'data/metrics/task-outcomes.tsv').write_text(oh +
    'byokit\tb1\tship\tbyokit\tpi:opencode-go/deepseek-v4.1-flash:medium\t%d\t%d\tmerged\thttps://github.com/acme/tool/pull/11\n' % (now - 2*day, now - day))
ph = ('home\trepo\tpr\tcreated\tmerged\thours_to_merge\tbuild_hours\tcommits\tcommits_after_open\t'
      'rework_ci\trework_pipeline\trework_other\treverted\tescaped\tfirst_pass\tbot\ttitle\n')
def prow(home, repo, pr, merged, fp, cao=0, rci=0, rp=0, ro=0):
    return '%s\t%s\t%s\t%s\t%s\t0\t0\t1\t%d\t%d\t%d\t%d\t0\t0\t%d\t0\tt\n' % (
        home, repo, pr, iso(merged - 3600), iso(merged), cao, rci, rp, ro, fp)
(m / 'data/metrics/prs.tsv').write_text(ph +
    prow('main', 'acme/app', 1, now - day, 1) + prow('main', 'acme/app', 2, now - 2*day, 0, cao=2, rci=1, rp=1) +
    prow('main', 'acme/app', 5, now - 19*day, 1) + prow('main', 'acme/app', 3, now - 2*day, 1) + prow('byokit', 'acme/tool', 11, now - day, 1))
lh = 'first_seen\thome\ttask\tkind\tproject\tharness\tmodel\teffort\tmode\tpr\n'
(m / 'data/metrics/lanes.tsv').write_text(lh +
    '%s\tmain\toldkind\tship\tacme\tpi\topencode-go/muse-spark-1.3-contributor\tmedium\tno-mistakes\thttps://github.com/acme/app/pull/3\n' % iso(now - 3*day) +
    '%s\tmain\tt1\tship\tacme\tclaude\tclaude-opus-5-5\tmedium\tno-mistakes\thttps://github.com/acme/app/pull/1\n' % iso(now - 2*day))
before = stamps(m)
x = json.loads(run(model, m))
assert run(model, m) == run(model, m) and stamps(m) == before, 'model reader deterministic and read-only'
assert x['schema'] == 'fm-model-stats.v1' and x['windows'] == [7, 30] and x['coverage']['outcome_rows'] == 6 and x['coverage']['sampled_tasks'] == 1, 'model schema, windows and coverage'
def by(rows, name):
    return next(r for r in rows if r['model'] == name)
opus = by(x['models'], 'claude-opus-5-5')['w7']
assert (opus['n_finished'], opus['merged'], opus['ended_ship'], opus['merge_rate']) == (1, 1, 1, 1.0), 'opus recorded cohort and rate'
assert (opus['p50_hours'], opus['p75_hours'], opus['timed_merges'], opus['first_pass_n'], opus['first_pass_rate'], opus['switches']) == (24.0, 24.0, 1, 1, 1.0, 0), 'opus time, first pass, switches'
muse = by(x['models'], 'opencode-go/muse-spark-1.3-contributor')['w7']
assert (muse['n_finished'], muse['merged'], muse['ended_ship'], muse['merge_rate']) == (4, 2, 2, 0.5), 'muse cohort and recorded-only rate'
assert muse['sampled'] is True and muse['unknown_outcome'] == 0 and muse['cancelled_failed'] == 1, 'sampled disclosed and cancelled counted'
assert (muse['switches'], muse['first_pass_n'], muse['first_pass_sample'], muse['first_pass_rate']) == (1, 0, 1, 0.0), 'switch and first-pass sample'
assert (muse['rework'], muse['rework_ci'], muse['rework_pipeline']) == (1, 1, 1), 'rework join'
deep = by(x['models'], 'opencode-go/deepseek-v4.1-flash')
assert deep['provider'] == 'OpenCode Go' and deep['name'] == 'DeepSeek' and deep['w7']['merge_rate'] == 1.0, 'model naming'
assert by(x['models'], 'opencode-go/muse-spark-1.3-contributor')['w30']['merged'] >= 3 and by(x['models'], 'claude-opus-5-5')['w30']['n_finished'] == 1, '30-day window'
empty = tmp / 'empty'
empty.mkdir()
y = json.loads(run(model, empty))
assert y['models'] == [] and y['coverage']['outcome_rows'] == 0 and y['limitations'], 'empty model home is not an error'
open_lane = tmp / 'open-lane'
(open_lane / 'data/metrics').mkdir(parents=True)
(open_lane / 'state').mkdir()
(open_lane / 'data/metrics/task-outcomes.tsv').write_text(oh)
(open_lane / 'data/metrics/lanes.tsv').write_text(lh + '%s\tmain\tstuck\tship\tacme\tpi\topencode-go/deepseek-v4.1-flash\tmedium\tno-mistakes\t\n' % iso(now - day))
ow = json.loads(run(model, open_lane))
st = by(ow['models'], 'opencode-go/deepseek-v4.1-flash')['w7']
assert (st['n_started'], st['n_finished'], st['unknown_outcome']) == (1, 0, 1), 'a sampled lane with no merged PR is unknown, not finished'
reuse_home = tmp / 'reuse'
(reuse_home / 'data/metrics').mkdir(parents=True)
(reuse_home / 'state').mkdir()
(reuse_home / 'data/metrics/task-outcomes.tsv').write_text(oh +
    'main\trl\tship\tacme\tpi:opencode-go/muse-spark-1.3-contributor:medium\t%d\t%d\tcancelled\t\n' % (now - 2*day, now - 2*day + 3600) +
    'main\trl\tship\tacme\tclaude:claude-opus-5-5:medium\t%d\t%d\tmerged\thttps://github.com/acme/app/pull/12\n' % (now - day, now - day + 3600))
(reuse_home / 'data/metrics/lanes.tsv').write_text(lh + '%s\tmain\trl\tship\tacme\tpi\topencode-go/deepseek-v4.1-flash\tmedium\tno-mistakes\t\n' % iso(now - 3*day))
rr = json.loads(run(model, reuse_home))
assert not any(r['model'] == 'opencode-go/deepseek-v4.1-flash' for r in rr['models']), 'a sampled lane for a task id the outcome file covers is skipped'
rm = by(rr['models'], 'opencode-go/muse-spark-1.3-contributor')['w7']
ro = by(rr['models'], 'claude-opus-5-5')['w7']
assert (rm['n_finished'], rm['cancelled_failed']) == (1, 1) and (ro['n_finished'], ro['merged'], ro['merge_rate']) == (1, 1, 1.0), 'a reused task id keeps every launch outcome'

# Skills: reads, windows, ranking, zero-read discovery, remote disclosure.
s, sb = tmp / 's', tmp / 'sb'
for h in (s, sb):
    (h / 'data/metrics').mkdir(parents=True, exist_ok=True)
    (h / 'state').mkdir(parents=True, exist_ok=True)
(s / 'data/secondmates.md').write_text(f'- byokit - BYOKit (home: {sb}; scope: toolkit; projects: byokit)\n'
    '- distant - Remote (host: box; root: /srv; home: /srv/home; scope: x; projects: y)\n')
for rel in ('skills', '.agents/skills'):
    for name in ('widget', 'gadget'):
        p = s / rel / name
        p.mkdir(parents=True, exist_ok=True)
        (p / 'SKILL.md').write_text('x')
(sp := sb / '.agents/skills/spanner').mkdir(parents=True)
(sp / 'SKILL.md').write_text('x')
(s / 'data/metrics/skills.tsv').write_text('day\thome\tskill\treads\n' + ''.join(
    f'{onday(0)}\tmain\tused-heavy\t5\n{onday(1)}\tmain\tused-heavy\t3\n{onday(0)}\tmain\tshared\t2\n{onday(0)}\tbyokit\tshared\t4\n'
    f'{onday(20)}\tmain\told\t10\n{onday(10)}\tmain\tgadget\t100\n{onday(7)}\tmain\twidget\t9\n'))
before = stamps(s)
z = json.loads(run(skill, s))
assert run(skill, s) == run(skill, s) and stamps(s) == before, 'skill reader deterministic and read-only'
assert z['schema'] == 'fm-skill-stats.v1' and z['windows'] == [7, 30] and (z['coverage']['rows'], z['coverage']['skills'], z['coverage']['homes']) == (7, 5, 2), 'skill schema, windows, coverage'
def sk(name):
    return next(r for r in z['skills'] if r['skill'] == name)
assert [r['skill'] for r in z['skills']][:2] == ['used-heavy', 'shared'] and [r['skill'] for r in z['skills']][2:] == ['gadget', 'old', 'widget'], 'skill ranking by reads'
assert sk('used-heavy')['w7'] == {'reads': 8, 'homes': 1} and sk('shared')['w7'] == {'reads': 6, 'homes': 2}, 'window sums and cross-home reads'
assert sk('gadget')['w7']['reads'] == 0 and sk('gadget')['w30']['reads'] == 100 and sk('widget')['w30']['reads'] == 9, 'a skill read only outside 7 days'
assert z['zero_read_w7'] == [] and z['zero_read_w30'] == [], 'a registered remote home suppresses zero-read claims'
assert [r['skill'] for r in z['by_home']['main']][:3] == ['used-heavy', 'shared', 'gadget'] and [r['skill'] for r in z['by_home']['byokit']] == ['shared'], 'per-home skill breakdown'
assert any('distant' in n for n in z['limitations']), 'a remote home is disclosed as unreadable'
def mk_skill_home(name, skills=(), tsv=None):
    h = tmp / name
    (h / 'data/metrics').mkdir(parents=True)
    for s in skills:
        (h / 'skills' / s).mkdir(parents=True)
        (h / 'skills' / s / 'SKILL.md').write_text('x')
    if tsv is not None:
        (h / 'data/metrics/skills.tsv').write_text('day\thome\tskill\treads\n' + tsv)
    return h
zempty = json.loads(run(skill, mk_skill_home('empty-skill')))
assert zempty['skills'] == [] and zempty['by_home'] == {} and zempty['limitations'], 'absent skill record is empty, not fatal'
znr = json.loads(run(skill, mk_skill_home('no-reads', ['widget'])))
assert znr['zero_read_w7'] == [] and znr['zero_read_w30'] == [], 'known skills are not zero-read without any read records'
zs = json.loads(run(skill, mk_skill_home('stale-skill', ['widget'], f'{onday(40)}\tmain\twidget\t1\n')))
assert zs['zero_read_w7'] == [] and zs['zero_read_w30'] == [], 'a collector whose coverage ends before the window claims no zero reads'
zz = json.loads(run(skill, mk_skill_home('zero-count', ['beta'],
    f'{onday(6)}\tmain\talpha\t1\n{onday(0)}\tmain\talpha\t3\n{onday(0)}\tmain\tbeta\t0\n')))
assert zz['zero_read_w7'] == ['beta'] and zz['zero_read_w30'] == [], 'a covered window lists known skills with no reads; a window the coverage does not span lists none'
assert next(r for r in zz['skills'] if r['skill'] == 'beta')['w7'] == {'reads': 0, 'homes': 0}, 'a zero-count row does not count as reading a home'

# Outcome recorder: one durable row per finished task, best effort.
o = tmp / 'o'
(o / 'state').mkdir(parents=True)
(o / 'data').mkdir()
outcomes = o / 'data/metrics/task-outcomes.tsv'
def rec(*args):
    subprocess.run(['bash', writer, *args], env=dict(os.environ, FM_HOME=str(o), FM_DATA_OVERRIDE=''), check=True)
def met(tid, *lines):
    (o / f'state/{tid}.meta').write_text(''.join(l + '\n' for l in lines))
def hist(tid, *rows):
    (o / f'state/{tid}.models').write_text(''.join(r + '\n' for r in rows))
def row(tid):
    return [l for l in outcomes.read_text().splitlines() if l.split('\t')[1:2] == [tid]]
def nrows():
    return len(outcomes.read_text().splitlines())
met('rl-ship', 'kind=ship', 'project=/home/fixture/users/user-020/projects/acme', 'harness=claude', 'model=claude-opus-5-5', 'effort=medium', 'spawn_gen=s1700000200.9.abc', 'pr=https://github.com/acme/app/pull/7')
hist('rl-ship', '1700000000\tclaude\tclaude-opus-5-5\tmedium', '1700000500\tpi\topencode-go/muse-spark-1.3-contributor\thigh')
rec('rl-ship')
f = row('rl-ship')
assert len(f) == 1 and f[0].split('\t')[:6] == ['main', 'rl-ship', 'ship', 'acme', 'claude:claude-opus-5-5:medium;pi:opencode-go/muse-spark-1.3-contributor:high', '1700000000'] and f[0].split('\t')[7] == 'merged' and f[0].endswith('/pull/7'), 'a landed ship records its full history in order'
met('rl-failed', 'kind=ship', 'harness=pi', 'model=opencode-go/deepseek-v4.1-flash', 'effort=medium', 'pr=https://github.com/acme/app/pull/8')
(o / 'state/rl-failed.status').write_text('failed [at=1700000100]: checks broke\n')
rec('rl-failed', '--force')
assert row('rl-failed')[0].split('\t')[7] == 'failed', 'a failed last status is recorded as failed'
met('rl-closed', 'kind=ship', 'harness=pi', 'model=muse', 'effort=medium', 'pr=https://github.com/acme/app/pull/9')
(o / 'state/rl-closed.status').write_text('working [at=1700000100]: building\n')
rec('rl-closed', '--force')
assert row('rl-closed')[0].split('\t')[7] == 'closed', 'a discarded task with a PR is closed'
met('rl-cancel', 'kind=ship', 'harness=pi', 'model=muse', 'effort=medium')
rec('rl-cancel', '--force')
assert row('rl-cancel')[0].split('\t')[7] == 'cancelled', 'a discarded task with no PR is cancelled'
met('rl-scout', 'kind=scout', 'harness=claude', 'model=claude-opus-5-5', 'effort=high')
rec('rl-scout')
assert row('rl-scout')[0].split('\t')[7] == 'scout', 'a scout records its report outcome'
met('rl-legacy', 'kind=ship', 'harness=claude', 'model=claude-opus-5-5', 'effort=xhigh', 'spawn_gen=s1700000300.7.def', 'pr=https://github.com/acme/app/pull/10')
rec('rl-legacy')
leg = row('rl-legacy')[0].split('\t')
assert 'claude:claude-opus-5-5:xhigh' in leg[4] and leg[5] == '1700000300', 'fallback uses the record model and spawn_gen epoch'
met('rl-secondmate', 'kind=secondmate', 'harness=pi', 'model=muse', 'effort=medium')
n0 = nrows()
rec('rl-secondmate')
assert nrows() == n0, 'a secondmate retirement appends nothing'
rec('rl-absent')
assert nrows() == n0, 'a missing record appends nothing'
head = outcomes.read_text().splitlines()
assert head[0] == 'home\ttask\tkind\tproject\tmodels\tstarted\tended\toutcome\tpr' and {len(l.split('\t')) for l in head[1:]} == {9}, 'one header and every row has nine columns'
met('rl-retry', 'kind=ship', 'harness=claude', 'model=claude-opus-5-5', 'effort=medium', 'pr=https://github.com/acme/app/pull/11')
rec('rl-retry'); rec('rl-retry')
assert len(row('rl-retry')) == 1, 'a retried teardown keeps one outcome row per task'
met('rl-reuse', 'kind=ship', 'harness=pi', 'model=muse', 'effort=medium')
hist('rl-reuse', '1700000400\tpi\tmuse\tmedium')
rec('rl-reuse', '--force')
met('rl-reuse', 'kind=ship', 'harness=claude', 'model=claude-opus-5-5', 'effort=medium', 'pr=https://github.com/acme/app/pull/12')
hist('rl-reuse', '1700000900\tclaude\tclaude-opus-5-5\tmedium')
rec('rl-reuse')
reuse = row('rl-reuse')
assert len(reuse) == 2 and reuse[1].split('\t')[7] == 'merged', 'a reused task id records each launch'
print('PASS: model and skill readers and the outcome recorder over isolated durable records')
PY
