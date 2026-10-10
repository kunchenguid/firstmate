#!/usr/bin/env python3
"""Typed local Workforce intake over the existing Firstmate inbox.

Usage (FM_HOME must be explicit):
  fm-workforce.py submit                 JSON request on stdin
  fm-workforce.py receipts [inbox receipt flags]
  fm-workforce.py status
  fm-workforce.py answer <note-id>       JSON answer on stdin; supervisor only

FM_HOME must name an existing absolute operational home. The bridge clears other
FM_* and TASKS_AXI_FILE/BACKEND overrides for delegated owners and uses this
script's code root; it does not support alternate project/state/config roots.

This is a trusted local CLI, not an authenticated network service. Only submit,
receipts and status are UI surfaces. answer is the supervisor's reply publisher,
not execution or approval authority. The inbox owns all durable records/wakes.
Requests never execute lifecycle, change policy, spawn, merge or validate.
No payload can select a home, executable, arguments, endpoint or worktree.
See --help for the request schema; this header owns the integration wire contract.
"""
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import hashlib
import shutil
import subprocess
import sys

BIN = Path(__file__).resolve().parent
SCHEMA = 'fm-workforce-request.v1'
PREFIX = 'Workforce request v1\n'
MODES = {'local-only', 'direct-PR', 'no-mistakes'}
VERBS = {'focus', 'open', 'send-instruction', 'interrupt', 'exit', 'relaunch'}
HELP = '''Request object (unknown keys refused):
 {schema: "fm-workforce-request.v1", request_id: stable-safe-id,
  action: validation-request|job-request|policy-request|window-request|defaults-request,
  scope: {project: registered-alias, job?: exact-task-id, batch?: revision-id,
          branch?: git-branch, head?: full-object-id, generation?: spawn_gen, level?: defaults-level}, payload: {...}}
Validation scope requires project, job, batch, branch, head and generation;
batch is the full Git commit ID of the completed revision and must equal head.
Payload is
 {posture: "assistant", delivery_mode: "no-mistakes"}.
Job payload optionally adds preferences (same fixed defaults fields) and
preference_revision (64 lowercase hex digits from the observed status snapshot).
This immutable requested snapshot is not a dispatch selection or effective grant.
Job payload: {kind: ship|scout, text: instructions, posture: autonomy|assistant,
 delivery_mode: local-only|direct-PR|no-mistakes, merge_autonomy: boolean}.
Job scope is only project. Policy scope is project or project/job/generation.
Policy payload: {posture, delivery_mode, merge_autonomy}.
Window payload: {verb: focus|open|send-instruction|interrupt|exit|relaunch,
 text?: instructions-or-relaunch-checkpoint}; scope requires project, job and generation (recorded spawn_gen).
Defaults request scope: {level: global} or {level: project, project: alias}
or {level: job, project: alias, job: id, generation: spawn_gen}; payload is a nonempty subset of
posture, delivery_mode, merge_autonomy, harness, model, effort, backend.
Model requests require explicit harness and an authoritative supported catalog.
Defaults remain requests; status projects existing global/project/job records,
inherited sources and an observation revision, never mutates running rows.
Answers: {decision: approved|declined|refused, reason: text, scope: exact scope}.
Replies bind schema fm-workforce-answer.v1, request_id, scope, provenance and
observed_at. Acknowledgement is not approval. Approval is not execution or yolo.
Validation approval rechecks batch/HEAD, clean branch and worker generation; row approvals recheck generation.
Execution must revalidate scope through ordinary supervisor intake and its existing guarded owners.
Request IDs are at most 118 characters; replay requires identical canonical content, including scope/revision.
Capture exits 3 if saved but not announced: retry identical request to repair.
Contract revision 1.4 is additive; request wire v1 remains unchanged.
Receipts optionally attach fm-workforce-admission.v1: request_id, note_id,
project, task_id, admitted_generation, committed_at and provenance
{owner: supervisor-intake, source: committed-task-and-inbox-record}.
Only fm-spawn.sh --origin-note and inbox publication produce this relation.
Prepared/answered notes remain unadmitted. admission_cursor and admissions
are separate from reply_cursor; admissions are a full historical attachment
inventory, so reconnect reloads them even when replies are cursor-filtered.
Each note execution projects pending, admitted, generation-changed, retired,
or unknown from the exact bound fleet row. Original admission generation never
changes on relaunch; current generation must be refreshed for scoped controls.
Missing/omitted/incompatible fleet inventory means unknown, never completion.
Retired means historical admission with no current row, not successful outcome.
Receipts retain fm-inbox-receipts.v1 cursor, omission and reply semantics.
Status embeds fm-fleet-snapshot.v1 and fm-inbox readiness with owner provenance.
Window request_supported verifies registered project/job/generation scope and
the guarded owner's capability, not endpoint liveness or permission to execute.
Unaddressable rows, including secondmate-home rows, expose no supported verbs.
Preference status reports explicit global harness settings; absent/default
harness inheritance is unresolved, not inferred from the client process.
Dispatch defaults are projected only after the dispatch owner's config validation;
invalid config exposes configuration_valid=false, a null value and a reason.
Model catalogs are read only from the Codex cache or installed OpenCode listing;
other harnesses expose unavailable selection rather than inferred identities.
Unsupported focus/open, remote/experimental lifecycle, arbitrary commands,
teardown, merges, check waivers, provisioning and credentials are refused.
'''


def fail(message):
    raise ValueError(message)


def emit(value):
    print(json.dumps(value, separators=(',', ':'), sort_keys=True))


def canonical(value):
    return json.dumps(value, separators=(',', ':'), sort_keys=True, ensure_ascii=True)


def keys(value, allowed, required=None):
    if not isinstance(value, dict) or set(value) - set(allowed):
        fail('unknown fields or non-object')
    if not set(required if required is not None else allowed) <= set(value):
        fail('missing required fields')


def text(value, name, maximum=16000):
    if not isinstance(value, str) or not value.strip() or len(value) > maximum or '\x00' in value:
        fail('invalid ' + name)
    return value


def ident(value, name):
    text(value, name, 128)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:-]*', value) or '..' in value:
        fail('invalid ' + name)
    return value


def read_json():
    raw = sys.stdin.buffer.read(32769)
    if len(raw) > 32768:
        fail('input exceeds 32768 bytes')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                fail('duplicate JSON field: ' + key)
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique)


def environment():
    explicit = os.environ.get('FM_HOME', '')
    if not explicit or not Path(explicit).is_absolute():
        fail('FM_HOME must be an explicit absolute operational home')
    home = Path(explicit).resolve(strict=True)
    env = os.environ.copy()
    for key in list(env):
        if key.startswith('FM_'):
            del env[key]
    env.pop('TASKS_AXI_FILE', None)
    env.pop('TASKS_AXI_BACKEND', None)
    env.update(FM_HOME=str(home), FM_ROOT_OVERRIDE=str(BIN.parent))
    return home, env


def run(env, script, *args, body=None):
    return subprocess.run(['bash', str(BIN / script), *args], input=body,
                          text=True, capture_output=True, env=env, check=False)


def output(env, script, *args):
    result = run(env, script, *args)
    if result.returncode:
        fail(result.stderr.strip() or script + ' refused')
    return result.stdout.strip()


def projects(home):
    path = home / 'data/projects.md'
    if not path.exists():
        return []
    return [m.group(1) for line in path.read_text().splitlines()
            if (m := re.match(r'^- (.*?) (?:\[.*?\] )?- ', line))]


def meta_fields(home, job):
    ident(job, 'job')
    path = home / 'state' / (job + '.meta')
    if not path.is_file():
        fail('job is not recorded in this home')
    pairs = [line.split('=', 1) for line in path.read_text().splitlines() if '=' in line]
    if len({key for key, _ in pairs}) != len(pairs):
        fail('duplicate job metadata fields')
    return dict(pairs)


def meta(home, scope):
    values = meta_fields(home, scope['job'])
    if values.get('project') != str((home / 'projects' / scope['project']).resolve()):
        fail('job/project scope mismatch')
    if values.get('remote_host'):
        fail('remote job is not a supported local action')
    if 'generation' in scope and values.get('spawn_gen') != scope['generation']:
        fail('stale job generation')
    return values


def exact_head(home, scope):
    values = meta(home, scope)
    worktree = values.get('worktree', '')
    if not worktree or not Path(worktree).is_dir():
        fail('recorded job worktree unavailable')
    def git(*args):
        result = subprocess.run(['git', '-C', worktree, *args], capture_output=True, text=True)
        if result.returncode:
            fail('recorded worktree revision unavailable')
        return result.stdout.strip()
    if values.get('branch') != scope['branch'] or git('branch', '--show-current') != scope['branch']:
        fail('stale branch scope')
    if git('rev-parse', 'HEAD') != scope['head']:
        fail('stale head scope')
    if scope['batch'] != scope['head'] or git('rev-parse', scope['batch'] + '^{commit}') != scope['head']:
        fail('batch does not identify the requested revision')
    if git('status', '--porcelain'):
        fail('completed batch has uncommitted changes')


def window_capability(env, values, verb):
    if verb in {'focus', 'open'}:
        return False, 'no portable guarded focus/open owner'
    if values.get('remote_host'):
        return False, 'remote endpoint is supervisor-owned'
    backend = values.get('backend', 'tmux')
    if verb == 'send-instruction':
        # Conservatively expose only production backends; send owns delivery refusal.
        return backend in {'tmux', 'herdr'}, 'fm-send.sh retains delivery checks'
    result = subprocess.run(['bash', '-c',
        '. "$1"; fm_control_harness_supports_kind "$3" "$4" && '
        'fm_control_backend_state_verified "$2" && '
        'key=$(fm_control_interrupt_key "$3") && '
        'fm_control_backend_supports_key "$2" "$key"',
        'fm-workforce-capability', str(BIN / 'fm-control-lib.sh'), backend,
        values.get('harness', ''), values.get('kind', '')],
        env=env, capture_output=True, text=True)
    return result.returncode == 0, 'fm-control-lib.sh capability; fm-control.sh retains postcondition checks'


def validate_preferences(env, payload, current):
    keys(payload, {'posture', 'delivery_mode', 'merge_autonomy', 'harness', 'model', 'effort', 'backend'}, set())
    if not payload:
        fail('empty defaults request')
    if 'posture' in payload and payload['posture'] not in {'assistant', 'autonomy'}:
        fail('unsupported posture')
    if 'delivery_mode' in payload and payload['delivery_mode'] not in MODES:
        fail('unsupported delivery mode')
    if 'merge_autonomy' in payload and type(payload['merge_autonomy']) is not bool:
        fail('merge_autonomy must be boolean')
    if 'backend' in payload:
        text(payload['backend'], 'backend', 32)
        if current and subprocess.run(['bash', '-c', '. "$1"; fm_backend_is_known "$2"',
                'workforce', str(BIN / 'fm-backend.sh'), payload['backend']], env=env).returncode != 0:
            fail('unsupported backend')
    if 'effort' in payload and payload['effort'] not in {'low', 'medium', 'high', 'xhigh', 'max', 'ultra'}:
        fail('unsupported effort')
    if 'model' in payload and 'harness' not in payload:
        fail('model requires an explicit harness')
    if 'harness' in payload:
        ident(payload['harness'], 'harness')
        if current:
            supported = subprocess.run(['bash', '-c', '. "$1"; fm_control_harness_supported "$2"',
                'workforce', str(BIN / 'fm-control-lib.sh'), payload['harness']], env=env).returncode == 0
            if not supported:
                fail('unsupported harness')
    if 'model' in payload:
        text(payload['model'], 'model', 256)
    if current and 'effort' in payload:
        result = run(env, 'fm-harness.sh', 'validate-native-effort',
                     payload.get('harness', ''), payload.get('model', ''), payload['effort'])
        if result.returncode:
            fail(result.stderr.strip() or 'unsupported harness/model/effort combination')
    if current and 'model' in payload:
        catalog = model_catalog(payload['harness'])
        if payload['model'] not in catalog['models']:
            fail('model not established by authoritative catalog: ' + catalog['reason'])


def validate(home, env, request, current=True):
    keys(request, {'schema', 'request_id', 'action', 'scope', 'payload'})
    if request['schema'] != SCHEMA:
        fail('unsupported request schema')
    ident(request['request_id'], 'request_id')
    if len(request['request_id']) > 118:
        fail('request_id exceeds 118 characters including inbox namespace budget')
    scope, payload, action = request['scope'], request['payload'], request['action']
    keys(scope, {'project', 'job', 'batch', 'branch', 'head', 'level', 'generation'},
         {'level'} if action == 'defaults-request' else {'project'})
    if action == 'defaults-request':
        if scope['level'] not in {'global', 'project', 'job'}:
            fail('unsupported defaults scope')
        required = {'global': {'level'}, 'project': {'level', 'project'},
                    'job': {'level', 'project', 'job', 'generation'}}[scope['level']]
        keys(scope, required)
    elif 'level' in scope:
        fail('level is only accepted for defaults-request')
    if 'project' in scope:
        text(scope['project'], 'project', 128)
        if scope['project'] in {'.', '..'} or '/' in scope['project'] or '\n' in scope['project']:
            fail('project must be a registered alias, not a path')
    if current and 'project' in scope and scope['project'] not in projects(home):
        fail('project is not registered in this home')
    for field in ('job', 'batch', 'generation'):
        if field in scope:
            ident(scope[field], field)
    if 'branch' in scope:
        text(scope['branch'], 'branch', 256)
        if scope['branch'].startswith('-') or '\n' in scope['branch']:
            fail('invalid branch')
    if 'head' in scope and not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', scope['head']):
        fail('head must be a full Git object ID')
    if action == 'defaults-request':
        validate_preferences(env, payload, current)
        if current and scope['level'] == 'job':
            meta(home, scope)
    elif action == 'validation-request':
        keys(scope, {'project', 'job', 'batch', 'branch', 'head', 'generation'})
        keys(payload, {'posture', 'delivery_mode'})
        if payload != {'posture': 'assistant', 'delivery_mode': 'no-mistakes'}:
            fail('validation is an Assistant no-mistakes request')
        if current:
            exact_head(home, scope)
            values = meta(home, scope)
            if values.get('mode') == 'local-only':
                fail('local-only job cannot request a publishing pipeline')
    elif action in {'job-request', 'policy-request'}:
        keys(scope, {'project'} if action == 'job-request' or 'job' not in scope else {'project', 'job', 'generation'},
             {'project', 'job', 'generation'} if 'job' in scope else {'project'})
        allowed = {'posture', 'delivery_mode', 'merge_autonomy'}
        if action == 'job-request':
            allowed |= {'kind', 'text'}
        keys(payload, allowed | ({'preferences', 'preference_revision'} if action == 'job-request' else set()), allowed)
        if action == 'job-request' and ('preferences' in payload or 'preference_revision' in payload):
            if not {'preferences', 'preference_revision'} <= set(payload):
                fail('new-worker preference snapshot requires preferences and preference_revision')
            if not isinstance(payload['preference_revision'], str) or not re.fullmatch(r'[0-9a-f]{64}', payload['preference_revision']):
                fail('invalid preference snapshot revision')
            validate_preferences(env, payload['preferences'], current)
            if current and payload['preference_revision'] != status_snapshot(home, env)['preferences']['revision']:
                fail('stale preference snapshot revision')
        if payload['posture'] not in {'assistant', 'autonomy'} or payload['delivery_mode'] not in MODES:
            fail('unsupported posture or delivery mode')
        if type(payload['merge_autonomy']) is not bool:
            fail('merge_autonomy must be boolean; it is only a request')
        if action == 'job-request':
            if payload['kind'] not in {'ship', 'scout'}:
                fail('unsupported task kind')
            text(payload['text'], 'text')
        if 'job' in scope and current:
            meta(home, scope)
    elif action == 'window-request':
        keys(scope, {'project', 'job', 'generation'})
        keys(payload, {'verb', 'text'}, {'verb'})
        if payload['verb'] not in VERBS:
            fail('unsupported window verb')
        if payload['verb'] in {'send-instruction', 'relaunch'}:
            text(payload.get('text'), 'text')
        elif 'text' in payload:
            fail('text is not accepted for this window verb')
        if current:
            supported, reason = window_capability(env, meta(home, scope), payload['verb'])
            if not supported:
                fail('unsupported window request: ' + reason)
    else:
        fail('unsupported action')


def note_body(path):
    raw = path.read_text()
    if '\n--\n' not in raw:
        fail('invalid inbox note')
    return raw.split('\n--\n', 1)[1].rstrip('\n')


def saved_note(home, note_id):
    ident(note_id, 'note_id')
    for base in (home / 'state/inbox', home / 'state/inbox/handled'):
        path = base / (note_id + '.note')
        if path.is_file():
            return path
    fail('unknown inbox note')


@contextlib.contextmanager
def capture_lock(home):
    inbox = home / 'state/inbox'
    inbox.mkdir(parents=True, exist_ok=True)
    with (inbox / '.workforce.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def submit(home, env):
    request = read_json()
    validate(home, env, request, current=False)
    body = PREFIX + canonical(request)
    rid = 'workforce:' + request['request_id']
    with capture_lock(home):
        reservation = home / 'state/inbox/.requests' / rid
        replay = False
        recovered_staging = None
        if reservation.exists():
            note_id = reservation.read_text().strip()
            try:
                path = saved_note(home, note_id)
            except ValueError:
                ident(note_id, 'note_id')
                suffix = note_id.partition('-')[2]
                path = home / 'state/inbox' / ('.staging-' + suffix)
                if not suffix or not path.is_file():
                    fail('incomplete inbox reservation; original staged content unavailable')
                header = path.read_text().split('\n--\n', 1)[0].splitlines()
                if 'id=' + note_id not in header or 'request_id=' + rid not in header:
                    fail('incomplete inbox reservation; staged identity differs')
                recovered_staging = path
            if note_body(path) != body:
                fail('request identity reused with different content')
            replay = True
        # Identical retries remain readable after HEAD or policy changes.
        if not replay:
            validate(home, env, request)
        result = run(env, 'fm-inbox.sh', 'note', '--request-id', rid, '--json', '-', body=body)
        if recovered_staging is not None and result.returncode in {0, 3}:
            if note_body(saved_note(home, note_id)) == body:
                recovered_staging.unlink()
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        return result.returncode


def answer(home, env, note_id):
    body = note_body(saved_note(home, note_id))
    if not body.startswith(PREFIX):
        fail('not a Workforce request')
    request = json.loads(body[len(PREFIX):])
    validate(home, env, request, current=False)
    response = read_json()
    keys(response, {'decision', 'reason', 'scope'})
    if response['decision'] not in {'approved', 'declined', 'refused'}:
        fail('unsupported decision')
    text(response['reason'], 'reason')
    if response['scope'] != request['scope']:
        fail('answer scope differs from request')
    if response['decision'] == 'approved':
        validate(home, env, request)
    response.update(schema='fm-workforce-answer.v1', request_id=request['request_id'],
                    action=request['action'], provenance='firstmate:fm-inbox.sh reply',
                    observed_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    effect='answer-only; normal supervisor intake owns execution and authority')
    result = run(env, 'fm-inbox.sh', 'reply', '--json', note_id, '-', body=canonical(response))
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    return result.returncode


def model_catalog(harness):
    result = {'harness': harness, 'models': [], 'provenance': None,
              'reason': 'no supported authoritative catalog reader; model selection unavailable'}
    if harness == 'codex':
        path = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'models_cache.json'
        result['provenance'] = 'codex models_cache.json'
        if path.is_file():
            try:
                data = json.loads(path.read_text())
            except (ValueError, OSError):
                result['reason'] = 'authoritative Codex cache unreadable; no inferred model support'
                return result
            if not isinstance(data, dict) or not isinstance(data.get('models'), list):
                result['reason'] = 'unsupported Codex cache shape; no inferred model support'
                return result
            result['models'] = sorted({row['slug'] for row in data.get('models', [])
                                       if isinstance(row, dict) and isinstance(row.get('slug'), str)})
            result['reason'] = 'cached installed Codex catalog; runtime remains authoritative'
            result['observed_at'] = datetime.datetime.fromtimestamp(path.stat().st_mtime, datetime.timezone.utc).isoformat()
    elif harness == 'opencode' and shutil.which('opencode'):
        result['provenance'] = 'opencode models'
        try:
            catalog = subprocess.run(['opencode', 'models'], text=True, capture_output=True, timeout=15)
            if catalog.returncode == 0:
                result['models'] = sorted({line for line in catalog.stdout.splitlines()
                                           if re.fullmatch(r'[A-Za-z0-9._:-]+/[A-Za-z0-9._:/-]+', line)})
                result['reason'] = 'installed OpenCode authoritative model listing'
        except subprocess.TimeoutExpired:
            result['reason'] = 'authoritative catalog query timed out; no inferred model support'
    return result


def backend_projection(home, env):
    supported = subprocess.check_output(['bash', '-c',
        '. "$1"; printf "%s\n" "$FM_BACKEND_KNOWN"', 'workforce',
        str(BIN / 'fm-backend.sh')], env=env, text=True).split()
    path = home / 'config/backend'
    configured = None
    if path.is_file():
        lines = [line.split('#', 1)[0].strip() for line in path.read_text().splitlines()]
        configured = next((line for line in lines if line), None)
    return {'configured': configured if configured in supported else None,
            'configuration_valid': configured is None or configured in supported,
            'known': supported, 'provenance': 'fm-backend.sh + config/backend',
            'effective': 'recorded per job; new-spawn detection remains supervisor-owned',
            'experimental_lifecycle': 'unavailable through this bridge'}


def profile_projection(profile):
    if isinstance(profile, list):
        return [profile_projection(row) for row in profile]
    return {key: value for key, value in profile.items()
            if key in {'harness', 'model', 'effort', 'provider'}}


def preference_snapshot(home, env, policies, fleet):
    # Only project-mode and existing dispatch owners establish effective values.
    configured = home / 'config/crew-dispatch.json'
    dispatch_value = None
    dispatch_valid = True
    dispatch_reason = None
    if configured.is_file():
        raw = configured.read_text()
        result = run(env, 'fm-dispatch-resolve.sh', '--validate-config', body=raw)
        dispatch_valid = result.returncode == 0
        if dispatch_valid:
            dispatch = json.loads(raw)
            if 'default' in dispatch:
                dispatch_value = profile_projection(dispatch['default'])
        else:
            dispatch_reason = result.stderr.strip() or 'dispatch configuration validation unavailable'
    harness_path = home / 'config/crew-harness'
    configured_harness = ''.join(harness_path.read_text().split()) if harness_path.is_file() else ''
    explicit_harness = configured_harness not in {'', 'default'}
    global_values = {'harness': {'value': configured_harness if explicit_harness else None,
                                 'source': 'config/crew-harness' if explicit_harness else 'inherited primary harness unresolved'},
                     'dispatch_default': {'value': dispatch_value,
                                          'configuration_valid': dispatch_valid,
                                          'reason': dispatch_reason,
                                          'source': 'config/crew-dispatch.json' if configured.is_file() else 'absent'},
                     'posture': {'value': None, 'source': 'not registered by Firstmate'}}
    project_values = [{'project': row['project'], 'delivery': row['effective'],
                       'branch_prefix': row['branch_prefix'], 'forge': row['forge'],
                       'source': 'fm-project-mode.sh',
                       'worker_preferences': 'inherit global; task-specific supervisor dispatch rules may override'}
                      for row in policies]
    rows = []
    for row in fleet['tasks']:
        try:
            observed = meta_fields(home, row['id'])
        except (ValueError, OSError):
            observed = {}
        unchanged = observed.get('spawn_gen') == row.get('spawn_gen')
        rows.append({'job': row['id'], 'project': Path(row['project']).name,
                     'harness': row['harness'], 'backend': row['backend'],
                     'delivery_mode': row['mode'], 'merge_autonomy': row['yolo'],
                     'generation': row.get('spawn_gen'),
                     'model': observed.get('model') if unchanged else None,
                     'effort': observed.get('effort') if unchanged else None,
                     'source': 'recorded task metadata; unaffected by prospective defaults',
                     'profile_observation': 'same-generation' if unchanged else 'unknown-generation-changed'})
    snapshot = {'global': global_values, 'projects': project_values, 'jobs': rows,
                'precedence': ['global', 'project', 'explicit-job'],
                'application': 'requested defaults are not effective until supervisor-owned intake applies them',
                'new_worker': 'snapshot is an observation, not a dispatch grant; supervisor resolves rules at intake'}
    snapshot['revision'] = hashlib.sha256(canonical(snapshot).encode()).hexdigest()
    return snapshot


def admission_projection(home, env, receipts, fleet=None):
    if fleet is None:
        try:
            fleet = json.loads(output(env, 'fm-fleet-snapshot.sh', '--json'))
        except (ValueError, OSError):
            fleet = None
    known = (isinstance(fleet, dict) and fleet.get('schema') == 'fm-fleet-snapshot.v1'
             and fleet.get('fm_home') == str(home) and isinstance(fleet.get('tasks'), list)
             and fleet.get('task_inventory_complete') is True and not fleet.get('omitted'))
    for note in receipts.get('pending', []) + receipts.get('handled', []):
        binding = note.get('admission')
        projection = dict(state='pending', provenance='fm-inbox.sh receipts', current=None)
        if binding:
            projection.update(state='unknown', provenance='fm-fleet-snapshot.sh',
                              admitted_generation=binding['admitted_generation'])
            if known:
                matches = [r for r in fleet['tasks'] if r.get('id') == binding['task_id']]
                if not matches:
                    projection['state'] = 'retired'
                elif len(matches) == 1:
                    row = matches[0]
                    origin = row.get('admission_origin') or {}
                    fields = ('request_id', 'note_id', 'project', 'task_id', 'admitted_generation')
                    exact = (all(origin.get(k) == binding[k] for k in fields)
                             and origin.get('home') == str(home)
                             and row.get('project') == str((home/'projects'/binding['project']).resolve())
                             and row.get('admission_committed_at') == binding['committed_at']
                             and row.get('admission_committed_generation') == binding['admitted_generation']
                             and row.get('spawn_gen') and not row.get('remote')
                             and row.get('generation_current') is True)
                    if exact:
                        generation = row['spawn_gen']
                        projection['state'] = ('admitted' if generation == binding['admitted_generation']
                                               else 'generation-changed')
                        projection['current'] = dict(task_id=row['id'], project=binding['project'],
                            generation=generation, backend=row.get('backend'),
                            endpoint=row.get('endpoint'), worktree=row.get('paths', {}).get('worktree'),
                            state=row.get('current_state'), observed_at=fleet.get('generated'))
        note['execution'] = projection
    return receipts


def status_snapshot(home, env):
    fleet = json.loads(output(env, 'fm-fleet-snapshot.sh', '--json'))
    policies = []
    for project in projects(home):
        policies.append({'project': project,
                         'registered': output(env, 'fm-project-mode.sh', '--raw', project),
                         'effective': output(env, 'fm-project-mode.sh', project),
                         'branch_prefix': output(env, 'fm-project-mode.sh', '--branch-prefix', project),
                         'forge': output(env, 'fm-project-mode.sh', '--forge', project),
                         'provenance': 'fm-project-mode.sh'})
    windows = []
    for task in fleet['tasks']:
        scope = {'job': task['id'], 'project': Path(task['project']).name,
                 'generation': task.get('spawn_gen')}
        verbs = {}
        for verb in sorted(VERBS):
            payload = {'verb': verb}
            if verb in {'send-instruction', 'relaunch'}:
                payload['text'] = 'Workforce capability observation'
            try:
                validate(home, env, {'schema': SCHEMA, 'request_id': 'status-capability',
                                    'action': 'window-request', 'scope': scope, 'payload': payload})
                supported, reason = True, 'request scope and window capability verified; guarded owner retains execution checks'
            except ValueError as error:
                supported, reason = False, str(error)
            verbs[verb] = {'request_supported': supported, 'direct_execution': False, 'reason': reason}
        windows.append(dict(scope, backend=task['backend'], verbs=verbs))
    return {'schema': 'fm-workforce-status.v1', 'fleet': fleet,
          'admissions': admission_projection(home, env, json.loads(output(env, 'fm-inbox.sh', 'receipts', '--all-pending', '--all-handled')), fleet),
          'readiness': json.loads(output(env, 'fm-inbox.sh', 'ready')),
          'projects': policies, 'windows': windows,
          'backends': backend_projection(home, env),
          'preferences': preference_snapshot(home, env, policies, fleet),
          'model_catalogs': [model_catalog(h) for h in subprocess.check_output(['bash', '-c', '. "$1"; fm_control_harnesses',
              'workforce', str(BIN / 'fm-control-lib.sh')], text=True, env=env).splitlines()],
          'provenance': ['fm-fleet-snapshot.sh', 'fm-inbox.sh ready', 'fm-control-lib.sh', 'fm-backend.sh'],
          'unsupported': ['direct-execution', 'teardown', 'merge', 'check-waiver',
                          'credentials', 'remote-provisioning', 'public-relay-enable']}


def main():
    if len(sys.argv) < 2 or sys.argv[1] in {'--help', '-h'}:
        print(__doc__ + '\n' + HELP)
        return 0
    home, env = environment()
    command = sys.argv[1]
    if command == 'submit' and len(sys.argv) == 2:
        return submit(home, env)
    if command == 'answer' and len(sys.argv) == 3:
        return answer(home, env, sys.argv[2])
    if command == 'status' and len(sys.argv) == 2:
        emit(status_snapshot(home, env))
        return 0
    if command == 'receipts':
        result = run(env, 'fm-inbox.sh', 'receipts', *sys.argv[2:])
        if result.returncode == 0:
            emit(admission_projection(home, env, json.loads(result.stdout)))
        else:
            sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        return result.returncode
    fail('invalid command; use --help')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError) as error:
        emit({'schema': 'fm-workforce-error.v1', 'error': str(error)})
        sys.exit(1)
