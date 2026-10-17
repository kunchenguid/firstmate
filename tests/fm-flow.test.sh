#!/usr/bin/env bash
# Integration: per-model and per-skill fleet statistics and the task outcome
# recorder, over isolated durable records; the JSON the dashboard's Models and
# Skills views consume. The flow reader itself moved to firstmate-addons
# (fleet-flow): its CLI journey runs from the add-on with FM_BIN naming this
# checkout's bin/ (fleet-flow/tests/fm-flow.test.sh there), and the
# bin/fm-flow.sh shim is covered by tests/fm-flow-shim.test.sh.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The per-model and per-skill readers and the outcome recorder: run the real CLIs
# over isolated durable records and read the JSON the dashboard's Models and Skills views consume.
mkdir -p "$TMP/stats"
HOME="$TMP/stats/home" XDG_CONFIG_HOME="$TMP/xdg" TMPDIR="$TMP/tmp" python3 - \
  "$ROOT/bin/fm-model-stats.sh" "$ROOT/bin/fm-skill-stats.sh" "$ROOT/bin/fm-task-outcome.sh" "$TMP/stats" <<'PY'
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
print('PASS: model and skill readers and the outcome recorder over isolated durable records')
PY
