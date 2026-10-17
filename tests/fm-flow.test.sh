#!/usr/bin/env bash
# Integration: the task outcome recorder, over isolated durable records; the
# rows the per-model and per-skill readers consume. The readers themselves moved
# to firstmate-addons (fleet-stats): their behaviour is tested in that repo, and
# tests/fm-stats-shim.test.sh covers the fork shims that exec them.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stats"
HOME="$TMP/stats/home" XDG_CONFIG_HOME="$TMP/xdg" TMPDIR="$TMP/tmp" python3 - \
  "$ROOT/bin/fm-task-outcome.sh" "$TMP/stats" <<'PY'
import os, subprocess, sys
from pathlib import Path

writer, tmp = sys.argv[1], Path(sys.argv[2])

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
met('rl-ship', 'kind=ship', 'project=/home/x/projects/acme', 'harness=claude', 'model=claude-opus-5-5', 'effort=medium', 'spawn_gen=s1700000200.9.abc', 'pr=https://github.com/acme/app/pull/7')
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
print('PASS: the outcome recorder over isolated durable records')
PY
