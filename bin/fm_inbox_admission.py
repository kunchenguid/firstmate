"""Structured admission implementation for fm-inbox.sh (not a UI executable).

The shell owner serializes these operations with the admission lock, including
acknowledgement, and allocates publication cursors through its sequence owner.
"""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location('workforce', Path(__file__).with_name('fm-workforce.py'))
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)


def record(path):
    if path.is_symlink():
        w.fail('symlink record refused')
    headers, sep, body = path.read_text().partition('\n--\n')
    pairs = [line.split('=', 1) for line in headers.splitlines() if '=' in line]
    if not sep or len(dict(pairs)) != len(pairs):
        w.fail('malformed note record')
    return dict(pairs), body


def save(path, headers, body):
    fd, tmp = tempfile.mkstemp(prefix='.admission-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(''.join(k+'='+v+'\n' for k, v in headers.items())+'--\n'+body)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        parent = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def captured(home, note):
    w.ident(note, 'note_id')
    path = w.saved_note(home, note)
    headers, body = record(path)
    if headers.get('id') != note or not body.startswith(w.PREFIX):
        w.fail('not a captured Workforce note')
    request = json.loads(body[len(w.PREFIX):])
    w.validate(home, {}, request, current=False)
    rid = request['request_id']
    reservation = home/'state/inbox/.requests'/('workforce:'+rid)
    if headers.get('request_id') != 'workforce:'+rid or reservation.read_text().strip() != note:
        w.fail('captured request/note custody differs')
    if request['action'] != 'job-request':
        w.fail('admission requires job-request')
    return path, headers, body, request


def prepare(home, note, task, project, kind):
    w.ident(task, 'task_id')
    path, headers, body, request = captured(home, note)
    alias = request['scope']['project']
    if alias not in w.projects(home) or str((home/'projects'/alias).resolve()) != project:
        w.fail('origin project differs from registered spawn project')
    if kind not in {'ship', 'scout'} or request['payload']['kind'] != kind:
        w.fail('origin kind differs from spawn kind')
    if 'admission_prepared' in headers or 'admission' in headers:
        w.fail('origin already reserved; recover committed admission instead of spawning again')
    if (home/'state'/f'{task}.meta').exists():
        w.fail('existing task cannot acquire a fresh origin')
    inbox = home/'state/inbox'
    for other in list(inbox.glob('*.note')) + list((inbox/'handled').glob('*.note')):
        if other == path:
            continue
        other_headers, _ = record(other)
        if other_headers.get('admission_prepared'):
            reserved = json.loads(other_headers['admission_prepared'])
            if reserved.get('task_id') == task:
                w.fail('task already reserved by another note')
    for meta in (home/'state').glob('*.meta'):
        if meta.is_symlink():
            w.fail('ambiguous metadata custody')
        fields = w.meta_fields(home, meta.stem)
        if fields.get('admission_origin'):
            origin = json.loads(fields['admission_origin'])
            if origin.get('note_id') == note or origin.get('task_id') == task:
                w.fail('duplicate task origin')
    prepared = dict(request_id=request['request_id'], note_id=note, project=alias,
                    task_id=task, kind=kind, home=str(home))
    headers['admission_prepared'] = w.canonical(prepared)
    save(path, headers, body)
    return prepared


def origin(home, note, task, generation):
    _, headers, _, _ = captured(home, note)
    value = json.loads(headers['admission_prepared'])
    if value['task_id'] != task or value['home'] != str(home):
        w.fail('prepared task/home differs')
    w.ident(generation, 'admitted_generation')
    return dict(value, admitted_generation=generation)


def publish(home, task, cursor):
    if (home/'state'/f'{task}.meta').is_symlink():
        w.fail('symlink task custody refused')
    values = w.meta_fields(home, task)
    value = json.loads(values.get('admission_origin', '{}'))
    required = {'request_id', 'note_id', 'project', 'task_id', 'kind', 'home', 'admitted_generation'}
    if set(value) != required or value['home'] != str(home) or value['task_id'] != task:
        w.fail('committed task origin custody differs')
    w.ident(value['admitted_generation'], 'admitted_generation')
    stamp = values.get('admission_committed_at', '')
    import datetime
    datetime.datetime.strptime(stamp, '%Y-%m-%dT%H:%M:%SZ')
    if values.get('remote_host') or values.get('kind') != value['kind'] or value['kind'] not in {'ship', 'scout'}:
        w.fail('unsupported task admission kind/route')
    if values.get('endpoint_task_id') != task or not values.get('window') or not values.get('worktree'):
        w.fail('missing committed endpoint/worktree custody')
    if values.get('project') != str((home/'projects'/value['project']).resolve()):
        w.fail('committed project differs')
    if values.get('admission_committed_generation') != value['admitted_generation']:
        w.fail('committed admission generation differs')
    path, headers, body, request = captured(home, value['note_id'])
    prepared = {k: v for k, v in value.items() if k != 'admitted_generation'}
    if json.loads(headers.get('admission_prepared', '{}')) != prepared:
        w.fail('prepared origin differs')
    if request['request_id'] != value['request_id'] or request['scope']['project'] != value['project'] or request['payload']['kind'] != value['kind']:
        w.fail('captured request differs from committed origin')
    for meta in (home/'state').glob('*.meta'):
        if meta.stem == task:
            continue
        other = w.meta_fields(home, meta.stem).get('admission_origin')
        if other and json.loads(other).get('note_id') == value['note_id']:
            w.fail('duplicate committed origins')
    binding = {k: v for k, v in value.items() if k not in {'kind', 'home'}}
    binding.update(schema='fm-workforce-admission.v1', committed_at=stamp,
                   provenance=dict(owner='supervisor-intake', source='committed-task-and-inbox-record'))
    if 'admission' in headers:
        if json.loads(headers['admission']) != binding:
            w.fail('immutable admission conflict')
        return binding
    headers['admission'] = w.canonical(binding)
    headers['admission_cursor'] = '%012d' % int(cursor)
    save(path, headers, body)
    return binding


def main():
    home, _ = w.environment()
    # Only the canonical home is supported; shell caller verifies overrides too.
    command, *args = sys.argv[1:]
    if command == 'prepare':
        result = prepare(home, *args)
    elif command == 'origin':
        result = origin(home, *args)
    elif command == 'publish':
        result = publish(home, *args)
    else:
        w.fail('invalid inbox admission operation')
    w.emit(result)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        print('fm-inbox admission: '+str(error), file=sys.stderr)
        sys.exit(1)
