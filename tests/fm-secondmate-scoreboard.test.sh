#!/usr/bin/env bash
# Exercise aggregate metrics, hourly cache, privacy, read-only sources, rendering,
# partial coverage and forbidden output placement through the public CLI.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(fm_test_tmproot secondmate-scoreboard)
export SCORE_TEST_ROOT="$T" SCORE_TEST_SCRIPT="$ROOT/bin/fm-secondmate-scoreboard.py"
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(os.environ['SCORE_TEST_ROOT'])
src = root/'source'
for directory in ('inbox/handled', 'pending', 'board', 'transcripts', 'goals'):
    (src/directory).mkdir(parents=True)
(root/'fakebin').mkdir()
now = 1800000000
corr = '0123456789abcdef'
rows = [
    {'uuid': 'one', 'timestamp': now-200, 'type': 'assistant', 'message': {'content': [
        {'type': 'tool_use', 'name': 'Bash', 'input': {'command': 'read '+str(src/'inbox/1.msg')}}]}},
    {'uuid': 'drain', 'timestamp': now-190, 'type': 'assistant', 'message': {'content': [
        {'type': 'tool_use', 'id': 'drain-call', 'name': 'Bash', 'input': {'command': 'fm-wake-drain.sh'}}]}},
    {'uuid': 'drained', 'timestamp': now-180, 'type': 'user', 'message': {'content': [
        {'type': 'tool_result', 'tool_use_id': 'drain-call', 'content': 'inbox: 2.msg'}]}},
    {'uuid': 'two', 'timestamp': now-100, 'type': 'system', 'subtype': 'turn_duration', 'durationMs': 200000},
    {'uuid': 'three', 'timestamp': now-90, 'type': 'assistant', 'message': {'content': [
        {'type': 'tool_use', 'name': 'Bash', 'input': {'command': 'fm-send.sh demo'}}]}},
    {'uuid': 'four', 'timestamp': now-10, 'type': 'system', 'subtype': 'turn_duration', 'durationMs': 90000},
    {'uuid': 'five', 'timestamp': now-50, 'type': 'system', 'subtype': 'compact_boundary'},
]
transcript = src/'transcripts/a.jsonl'
transcript.write_text(''.join(json.dumps(r)+'\n' for r in rows))
# A resumed transcript repeats ancestors; it must not double-count them.
resumed = src/'transcripts/b.jsonl'
resumed.write_text(transcript.read_text())
(src/'inbox/1.msg').write_text(f'schema=fm-task-inbox.v1\nat={now-250}\n--\ncorr={corr} board round 1 (session demo, owning task task)')
(src/'inbox/handled/2.msg').write_text(f'at={now-240}\n--\nAutomatic reminder: no reply yet')
(src/'pending'/corr).write_text(f'task_id=task\ncorr_id={corr}\ndelivered_epoch={now-250}\nresolved_epoch={now-40}\nresolved_via=status\nescalated_epoch={now-100}\nrequest_summary=DO_NOT_PUBLISH\n')
(src/'pending/expired').write_text(f'task_id=task\ndelivered_epoch={now-200}\nresolved_epoch={now-20}\nresolved_via=expired-unanswered\n')
(src/'pending/unrelated').write_text(f'task_id=other\ndelivered_epoch={now-250}\n')
board = src/'board/demo.1.result'
board.write_text('private fixture board body')
os.utime(board, (now-300, now-300))
goals = src/'goals/task.status'
goals.write_text(f'goal [goal=g] [item=i] [state=done] [at={now-20}]: https://github.com/demo/repo/pull/1\n')
cli = root/'fakebin/gh-axi'
cli.write_text('#!/usr/bin/env bash\nprintf "count\\t1\\n1\\t'+str(now-1000)+'\\t'+str(now-500)+'\\n"\n')
cli.chmod(0o755)
config = root/'config.json'
cfg = {'read_only_home': str(src), 'transcripts': [str(transcript), str(resumed)], 'inbox': str(src/'inbox'),
       'pending_replies': str(src/'pending'), 'task_id': 'task', 'repo': 'demo/repo',
       'goal_status': [str(goals)], 'board_results': str(src/'board')}
config.write_text(json.dumps(cfg))
page = root/'cockpit.html'
page.write_text('<html><body><h1>Cockpit</h1></body></html>')
output = root/'scoreboard.json'
env = dict(os.environ, PATH=str(root/'fakebin')+os.pathsep+os.environ['PATH'])
command = [sys.executable, '-I', os.environ['SCORE_TEST_SCRIPT'], '--config', str(config),
           '--output', str(output), '--page', str(page)]
def run(at, success=True, args=None):
    p = subprocess.run((args or command)+['--now', str(at)], env=env, capture_output=True, text=True)
    assert (p.returncode == 0) == success, p.stderr
    return p

def source_snapshot():
    return {str(p): (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns)
            for p in src.rglob('*') if p.is_file()}
before = source_snapshot()
run(now)
data = json.loads(output.read_text())
m = data['metrics']
assert data['coverage']['completed_turns'] == 2
assert m['busy_percent'] == round(290/864, 2)
assert m['no_action_percent'] == 50
assert m['compactions'] == 1
assert m['turns_per_hour'] == round(2/24, 3)
assert m['inbox_pickup_seconds'] == {'n': 2, 'median': 55, 'p90': 60}
assert m['reply_seconds'] == {'n': 1, 'median': 210, 'p90': 210}
assert m['board_reply_seconds']['median'] == 260
assert m['reminders'] == 1
assert m['false_missed'] == {'answered_within_900s': 1, 'alarms': 1}
assert m['merge_goal_seconds']['median'] == 480
assert m['pr_merge_seconds']['median'] == 500
assert 'DO_NOT_PUBLISH' not in output.read_text()+page.read_text()
assert corr not in output.read_text()+page.read_text()
assert page.read_text().count('id="secondmate-scoreboard"') == 1
assert before == source_snapshot(), 'source writes'
snapshot = output.read_bytes()
run(now+3599)
assert snapshot == output.read_bytes(), 'hourly cache miss'
assert page.read_text().count('id="secondmate-scoreboard"') == 1
run(now+3600)
assert json.loads(output.read_text())['generated_epoch'] == now+3600
# A missing/unsupported history is unknown rather than fabricated zero busy.
cfg['transcripts'] = [str(src/'transcripts/missing.jsonl')]
config.write_text(json.dumps(cfg))
cli.write_text('#!/usr/bin/env bash\nexit 1\n')
run(now+7200)
partial = json.loads(output.read_text())
assert partial['metrics']['busy_percent'] is None
assert partial['metrics']['pr_merge_seconds'] is None
assert 'github-unavailable' in partial['warnings']
assert 'source-unavailable' in partial['warnings']
assert 'unknown' in page.read_text()
# Never write into the source namespace, even when output does not yet exist.
unsafe = command.copy()
unsafe[unsafe.index('--output')+1] = str(src/'inbox/forbidden.json')
run(now, False, unsafe)
assert not (src/'inbox/forbidden.json').exists()
print('PASS: scoreboard metrics, hourly cache, read-only privacy, rendering and missing-source coverage')
PY
pass "secondmate scoreboard public CLI"
