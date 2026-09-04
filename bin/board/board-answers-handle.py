#!/usr/bin/env python3
"""Apply captured answer packets, leaving uncertain effects for firstmate.

This helper never evaluates answer text. All argv are passed literally.
A pre-route claim prevents automatic retries after an uncertain external effect.
Successful answers use fm-board.sh answered; failed/unkeyed packets remain in
procevent-inbox and a bounded exception packet is also printed to stdout.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys

spec = importlib.util.spec_from_file_location('fm_board', Path(__file__).resolve().parents[1] / 'fm-board.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def handle(source, sequence, result):
    os.umask(0o077)
    home = Path(os.environ['FM_HOME']).resolve()
    m.slug(source, 'source'); m.slug(sequence, 'sequence')
    expected = home / 'state/procevent-inbox' / f'{source}.{sequence}.result'
    if Path(result).resolve() != expected or expected.is_symlink() or not expected.is_file():
        raise m.Invalid('handler requires the exact durable captured result')
    packet = json.loads(expected.read_text())
    if packet.get('schema') != 'board-answers.v1':
        raise m.Invalid('invalid captured answer packet')
    b = m.Board(packet['config'])
    if source != b.source_id or packet['source_id'] != source:
        raise m.Invalid('source identity mismatch')
    exceptions = []
    with m.file_lock(b.state / 'board-inbox/handle.lock'):
        log = b.state / 'board-inbox/answers.jsonl'
        data = log.read_bytes()
        start, end = packet['start'], packet['end']
        if type(start) is not int or type(end) is not int or not 0 <= start < end <= len(data):
            raise m.Invalid('invalid captured offsets')
        if hashlib.sha256(data[:start]).hexdigest() != packet['start_prefix'] or hashlib.sha256(data[:end]).hexdigest() != packet['prefix']:
            raise m.Invalid('captured answer continuity mismatch')
        records = [json.loads(line) for line in data[start:end].splitlines()]
        if records != packet['answers'] or len(records) > 50:
            raise m.Invalid('captured records mismatch')
        cursor = b.state / 'board-inbox/answers.cursor'
        old = json.loads(cursor.read_text()) if cursor.exists() else {'offset':0}
        if type(old) is int:
            old = {'offset':old}
        if old['offset'] < start:
            raise m.Invalid('earlier answer burst must be captured first')
        # Capture is durable even when a route needs firstmate. Advance once so
        # a failed record does not starve every subsequent answer burst.
        if old['offset'] < end:
            m.atomic(cursor,json.dumps({'offset':end,'prefix':packet['prefix']}).encode())
        for record in records:
            with b.connect() as c:
                a = c.execute('SELECT * FROM answers WHERE answer_id=?', (record.get('answer_id'),)).fetchone()
                if not a or not a['consumed_at']:
                    exceptions.append(dict(record,error=a['error'] if a else 'unknown answer'))
        if exceptions:
            report = {'schema':'board-answers.exceptions.v1','source':source,'sequence':sequence,
                      'result':str(expected),'answers':exceptions}
            m.atomic(expected.with_suffix('.exceptions.json'),json.dumps(report).encode())
            print(json.dumps(report))
            return 1
        m.run([m.ROOT/'bin/fm-procevent.sh','handled',source,sequence],b.home)
        print(json.dumps({'schema':'board-answers.handled.v1','source':source,'sequence':sequence,'count':len(records)}))
        return 0


def route(config):
    b = m.Board(config)
    exceptions = []
    with m.file_lock(b.state / 'board-inbox/route.lock'):
        with b.connect() as c:
            rows = c.execute("SELECT * FROM answers WHERE consumed_at IS NULL AND error IS NULL AND cancelled_at IS NULL AND ready_at<=? ORDER BY received_at LIMIT 50", (m.time.time(),)).fetchall()
        for a in rows:
            aid = a['answer_id']
            try:
                with b.connect() as c:
                    d = b.latest(c,a['home_id'],a['task_id'],a['decision_key'])
                    if not d or d['revision'] != a['revision']:
                        raise m.Invalid('decision changed before routing')
                    if a['action'] == 'correction':
                        raise m.Invalid('correction requested; firstmate must review')
                    if a['routing_at']:
                        raise m.Invalid('previous route outcome uncertain; inspect before retry')
                    if a['decision_key'] == 'default':
                        raise m.Invalid('unkeyed decision; firstmate must review')
                    target_home = b.homes[a['home_id']]
                    options = json.loads(d['options'])
                    wording = ' '.join(next((o['label'] for o in options if o['value'] == a['choice']),a['choice']).split())
                    note = ' '.join(a['note'].split())
                    answer_text = f'{wording} (note: {note})' if note else wording
                    if a['choice'] == 'request-options':
                        answer_text = (f'Captain requested structured options for decision {a["decision_key"]}: '
                            f'register 2-4 distinct alternatives with `bin/fm-board.sh decision {a["home_id"]} '
                            f'{a["task_id"]} {a["decision_key"]} --option \'...\'` and stop.')
                if d['source'] == 'hold' and a['choice'] != 'request-options':
                    argv = [m.ROOT/'bin/fm-decision-hold.sh','answers',d['origin_id'],'--source',f'board:{aid}']
                    stdin = f'{a["decision_key"]}\t{answer_text}\tCaptain dashboard\n'
                else:
                    state = m.run([m.ROOT/'bin/fm-crew-state.sh',a['task_id']],target_home)
                    if not re.match(r'state: (working|parked|blocked|paused)\b',state):
                        raise m.Invalid('no confirmed live worker for this answer')
                    argv = [m.ROOT/'bin/fm-send.sh',a['task_id']]
                    if a['choice'] != 'request-options':
                        argv += ['--resolve-key',a['decision_key']]
                    argv += [answer_text]
                    stdin = None
                with b.write() as (c, changed):
                    c.execute('UPDATE answers SET routing_at=? WHERE answer_id=?', (m.stamp(),aid))
                    c.execute("UPDATE decisions SET state='sent' WHERE home_id=? AND task_id=? AND decision_key=? AND revision=?", (a['home_id'],a['task_id'],a['decision_key'],a['revision']))
                    changed[0] = True
                m.run(argv,target_home,10,stdin)
                m.run([m.ROOT/'bin/fm-board.sh','answered',aid,'--config',b.config_path],b.home)
            except (OSError,ValueError,KeyError) as e:
                b.failed(aid,str(e)[:500])
                exceptions.append({'answer_id':aid,'error':str(e)[:500]})
        b.export()
    print(json.dumps({'routed':len(rows)-len(exceptions),'exceptions':exceptions}))
    return 0


if __name__ == '__main__':
    try:
        os.umask(0o077)
        if len(sys.argv) >= 2 and sys.argv[1] == 'route':
            p = m.Parser(description='Route ready SQLite answers, without an LLM.')
            p.add_argument('--config')
            args = p.parse_args(sys.argv[2:])
            sys.exit(route(args.config))
        if len(sys.argv) != 5 or sys.argv[1] != 'capture':
            raise m.Invalid('expected route [--config PATH] or capture <source> <seq> <result>')
        sys.exit(handle(*sys.argv[2:]))
    except (OSError,ValueError,KeyError) as e:
        print(json.dumps({'schema':'board-answers.exceptions.v1','error':str(e)}))
        sys.exit(1)
