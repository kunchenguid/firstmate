#!/usr/bin/env python3
"""Task-local lifecycle record mechanics, called under the existing meta lock.

Not a worker, queue or semantic acceptance engine.
Public entry: fm-task-state.sh lifecycle|enroll|reconcile|action|observe|coordinate TASK.
coordinate --expected-revision N --record private.json records a native
fm-periodic-stow readback receipt and admits at most two model requests per
observation fingerprint, with 30/60-second backoff. Its independent coordination
field is scheduling evidence only, never executor receipt, blocker or acceptance.
The record binds session_file, entry_id, byte offset/length and sha256 to the
actual fm-continuation-receipt custom entry. It retains every fingerprint budget
across reload/compaction and refuses overflow rather than resetting it.
Each budget may retain a reserved admission id while the native safety owner
defers notification. Later readback of custom_message.details.admissions in
the actual session branch acknowledges delivery and anchors the backoff to
that message's timestamp. A deferred reservation consumes no extra attempt.
After both requests are delivered without progress, coordinate requires a
native main-session escalation, then paced recovery while still unresolved.
Recovery attempts are counted separately in the same budget, with persistent
60-second exponential backoff capped at 15 minutes, never resetting attempts.
Delivery is not execution or progress. Recovery reports coordination failure; it neither holds
the task for a fabricated dependency nor claims executor receipt or acceptance.
Main owns semantic assessment; explicitly delegated v2 branch patches can change
only precheck and bounded next_action. Existing lease/meta locks own CAS.
An open goal without a verified continuation remains due after presentation ack.
Optional next_action.continuation has exactly one of these observation contracts:
  executor: {type, task_id, execution_generation, handoff_id} OR
            {type, task_id, execution_generation, inbox_id, sha256} OR
            {type, task_id, execution_generation, brief_sha256}.
    A spawn brief needs observed pi-ext/Codex/TraeX transcript activity, never
    the synthetic fm-spawn busy seed, process presence, or a status report.
    A matching handled inbox message plus current working executor proves receipt;
    delivery alone is pending. This reader never sends, retries or relaunches.
  blocker: {type, owner, dependency, release_ref, release_sha256, recovery_trigger}.
    recovery_trigger is evidence-change; an unchanged bound dependency stays quiet
    until deadline, then becomes due once. Changed evidence requests judgment,
    never grants effect/merge/permission authority.
Unknown, stale, missing or uncertain effects are due for readback, never replay.
An action receipt is not goal acceptance. Acceptance is main's evidence-backed
assessment with an empty remaining_gap. Archived goals never request execution.
No cleanup, remote-followup, historical enrollment, or provider success acceptance. A supervisor supplies the
assessment; we check revision, scope, evidence and transition invariants.
Store: data/<task>/lifecycle.json (0600, single-link, bounded, atomic replace).
Absent => legacy; invalid/changed brief/execution generation => unknown.
Semantic disposition is independent of provider/process state and cleanup.
Usage via fm-task-state.sh:
  lifecycle ID
  branch-patch ID --expected-revision N --record private.json
  readback ID
v2 is an explicit reconcile upgrade preserving v1 fields and coordination.
MAIN issues delegation {revision,issuer:"main",authority_ref,authority_sha256,
allowed,edges,expires_at,revoked}; each change advances its revision once and
clears precheck. Revoke before changing goal/brief/execution. No downgrade.
Allowed actions: inspect, precheck, steer-same-intent, observe-receipt, handoff.
Each edge binds target, goal_revision, execution_generation, authority_ref/hash
and scope (maximum 16). Parent lifecycle binds the source identity.
Branch patch accepts only delegation_revision, precheck and next_action.
Precheck {delegation_revision,basis_key,conclusion,checks,summary} records only
needs-evidence/candidate/conflict/blocked; checks (maximum 64) each have criterion,
result (present/missing/conflict/not-applicable), evidence [{ref,sha256}].
Present/not-applicable need evidence; candidate cannot contain missing/conflict.
Use observe.basis_key, not the routing key; repeat identical patches are no-ops.
Only MAIN reconcile may accept, against the exact current candidate/evidence.
Branch generation is the existing wake owner, not a new task scheduler.
Effect-time readback of original MAIN input receipts (bounded at 16 MiB) fails
closed on unknown data or unclassified input. No store mirrors that authority.
Actual send/handoff owners use private effect/bind-inbox/handoff-effect calls
inside lease/meta critical sections; callers must not pre-mark attempted.
readback can recover the stable action inbox receipt without re-enqueueing it.
The first version delegates no interrupt/exit/relaunch. Escalate exact recovery
requests to MAIN through the existing control owner and its transaction receipt.
  reconcile ID --expected-revision N --record private.json
  action ID --action-id ID --phase attempted|uncertain|confirmed|refused
            [--receipt-ref data/... --receipt-sha256 HASH]
Enrollment is main-owned and holds the existing lease and metadata lock.
One outstanding action, monotonic ids; a retry never rewrites its payload.
Attempted/uncertain actions cannot be replaced or reset by reconciliation.
No operation executes a payload, launches a worker or contacts a provider.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import subprocess
import time

SCHEMA = 'fm-task-lifecycle.v1'
DELEGATED_SCHEMA = 'fm-task-lifecycle.v2'
PERMISSIONS = {'inspect', 'precheck', 'steer-same-intent', 'observe-receipt', 'handoff'}
MAX_BYTES = 262144
MAX_INT = 9007199254740991
KINDS = {'steer', 'relaunch', 'spawn', 'readback', 'wait', 'decision'}
PHASES = {'prepared', 'attempted', 'confirmed', 'refused', 'uncertain'}


class Refusal(Exception):
    pass


def require(ok, reason):
    if not ok:
        raise Refusal(reason)


def atom(value):
    return isinstance(value, str) and bool(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,159}', value))


def integer(value, minimum=0):
    return type(value) is int and minimum <= value <= MAX_INT


def text(value, maximum=8192, empty=False):
    return isinstance(value, str) and (empty or bool(value)) and len(value) <= maximum and '\0' not in value


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def regular(path, private=False):
    st = path.lstat()
    require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1, 'unsafe file: ' + str(path))
    require(st.st_uid == os.getuid() and st.st_size <= MAX_BYTES, 'unsafe owner or size: ' + str(path))
    if private:
        require(stat.S_IMODE(st.st_mode) in (0o600, 0o400), 'private file mode required: ' + str(path))
    return path.read_bytes()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON key: ' + key)
        result[key] = value
    return result


def load(path):
    return json.loads(regular(path, True), object_pairs_hook=unique_object)


def stamp(value):
    require(isinstance(value, str) and re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', value), 'invalid UTC timestamp')
    return datetime.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


class Task:
    def __init__(self, task):
        require(atom(task), 'invalid task id')
        self.id = task
        require(bool(os.environ.get('FM_HOME')), 'FM_HOME must be explicit')
        self.home = Path(os.environ['FM_HOME']).resolve(strict=True)
        self.data = Path(os.environ.get('FM_DATA_OVERRIDE', self.home / 'data')).resolve(strict=True)
        self.state = Path(os.environ.get('FM_STATE_OVERRIDE', self.home / 'state')).resolve(strict=True)
        self.directory = self.data / task
        require(self.directory.is_dir() and not self.directory.is_symlink(), 'missing or unsafe task data directory')
        self.path = self.directory / 'lifecycle.json'

    def generation(self):
        meta = self.state / (self.id + '.meta')
        if not meta.exists() and not meta.is_symlink():
            return None
        fields = {}
        for line in regular(meta).decode().splitlines():
            key, sep, value = line.partition('=')
            if sep and key in ('spawn_gen', 'executor', 'provider', 'remote_state'):
                require(key not in fields, 'duplicate execution identity')
                fields[key] = value
        if fields.get('executor') in ('remote-agent', 'cloud-worker'):
            if fields.get('provider') == 'aime':
                state = load(self.state / 'cloud-tasks' / self.id / 'state.json')
                generation = state.get('execution_generation')
                require(state.get('task_id') == self.id and atom(generation), 'legacy AIME execution identity needs explicit reconciliation')
                return generation
            require(fields.get('provider') == 'ida', 'provider has no lifecycle execution-generation binding; continuation unsupported')
            remote = self.state / 'remote-tasks' / self.id / 'state.json'
            state = load(remote)
            generation = state.get('generation', 1)
            require(integer(generation, 1), 'invalid remote generation')
            return 'remote-' + str(generation)
        generation = fields.get('spawn_gen')
        require(atom(generation), 'missing execution generation')
        return generation

    def reference(self, ref, sha=None):
        require(text(ref, 4096), 'missing evidence reference')
        path = Path(ref)
        if not path.is_absolute():
            path = self.home / path
        require(not path.is_symlink(), 'symlink evidence')
        resolved = path.resolve(strict=True)
        require(resolved.is_relative_to(self.data) or resolved.is_relative_to(self.state), 'evidence outside this home data/state')
        raw = regular(path)
        if sha is not None:
            require(sha == digest(raw), 'evidence digest changed: ' + ref)
        return raw

    def authority_identity(self, ref):
        raw = self.reference(ref)
        path = Path(ref)
        if not path.is_absolute():
            path = self.home / path
        return str(path.resolve(strict=True)), digest(raw)

    def validate(self, record, current=True):
        require(isinstance(record, dict), 'record must be an object')
        require(record.get('schema') in (SCHEMA, DELEGATED_SCHEMA) and record.get('task_id') == self.id, 'record identity/schema mismatch')
        require(integer(record.get('revision'), 1) and integer(record.get('goal_revision'), 1), 'invalid revision')
        require(record.get('disposition') in ('open', 'accepted', 'archived'), 'invalid disposition')
        require(atom(record.get('execution_generation')), 'missing bound execution generation')
        require(integer(record.get('next_action_seq'), 1), 'invalid action sequence')
        for key in ('decision_ref', 'cleanup_ref'):
            require(record.get(key) is None or text(record[key], 4096), 'invalid ' + key)
        assessment = record.get('assessment')
        require(isinstance(assessment, dict), 'missing assessment')
        require(text(assessment.get('outcome')) and text(assessment.get('remaining_gap'), empty=True), 'missing outcome/gap')
        stamp(assessment.get('assessed_at'))
        require(text(assessment.get('authority_ref'), 4096), 'missing authority')
        evidence = assessment.get('evidence')
        require(isinstance(evidence, list) and 1 <= len(evidence) <= 64, 'missing or excessive evidence')
        for item in evidence:
            require(isinstance(item, dict) and text(item.get('ref'), 4096), 'invalid evidence')
            require(bool(re.fullmatch('[a-f0-9]{64}', str(item.get('sha256')))), 'invalid evidence digest')
        if record['disposition'] == 'accepted':
            require(not assessment['remaining_gap'], 'accepted task still has a gap')
        coordination = record.get('coordination')
        if coordination is not None:
            require(isinstance(coordination, dict) and isinstance(coordination.get('budgets'), dict), 'invalid readback coordination')
            require(len(coordination['budgets']) <= 256, 'excessive readback history')
            for key, budget in coordination['budgets'].items():
                require(bool(re.fullmatch('[a-f0-9]{64}', key)) and isinstance(budget, dict), 'invalid readback fingerprint')
                require(integer(budget.get('attempts')) and budget['attempts'] <= 2 and integer(budget.get('not_before_ms')), 'invalid readback pacing')
                require(budget.get('reserved') is None or atom(budget['reserved']), 'invalid reserved admission')
                require(budget.get('escalated_at_ms') is None or integer(budget['escalated_at_ms']), 'invalid escalation receipt')
                require(integer(budget.get('recovery_attempts', 0)) and integer(budget.get('recovery_not_before_ms', 0)), 'invalid recovery pacing')
                require(budget.get('recovery_reserved') is None or atom(budget['recovery_reserved']), 'invalid recovery reservation')
            require(isinstance(coordination.get('receipt'), dict) and isinstance(coordination.get('receiver'), dict), 'missing native readback receipt')
        self.validate_delegation(record)
        action = record.get('next_action')
        if action is not None:
            require(isinstance(action, dict) and atom(action.get('id')), 'invalid action identity')
            require(action.get('kind') in KINDS and action.get('phase') in PHASES, 'invalid action kind/phase')
            require(action.get('expected_execution_generation') == record['execution_generation'] or
                    (action['phase'] in ('attempted', 'uncertain', 'confirmed') and action.get('result_execution_generation') == record['execution_generation']),
                    'action generation mismatch')
            require(integer(action.get('attempts')) and integer(action.get('attempt_limit'), 1) and action['attempt_limit'] <= 2 and action['attempts'] <= action['attempt_limit'], 'invalid retry budget')
            require(stamp(action.get('recheck_at')) <= stamp(action.get('deadline')), 'invalid action deadline')
            require(text(action.get('payload_ref'), 4096) and bool(re.fullmatch('[a-f0-9]{64}', str(action.get('payload_sha256')))), 'invalid action payload')
            require(action.get('receipt_ref') is None or text(action['receipt_ref'], 4096), 'invalid receipt')
            continuation = action.get('continuation')
            if continuation is not None:
                require(isinstance(continuation, dict), 'invalid continuation')
                if continuation.get('type') == 'executor':
                    require(atom(continuation.get('task_id')) and atom(continuation.get('execution_generation')), 'missing executor identity')
                    identities = [key for key in ('handoff_id', 'inbox_id', 'brief_sha256') if key in continuation]
                    require(len(identities) == 1, 'one exact executor receipt identity required')
                    if identities[0] == 'handoff_id':
                        require(atom(continuation['handoff_id']), 'invalid handoff identity')
                    elif identities[0] == 'inbox_id':
                        require(bool(re.fullmatch(r'[0-9]+', str(continuation['inbox_id']))) and
                                bool(re.fullmatch(r'[a-f0-9]{64}', str(continuation.get('sha256', '')))), 'invalid inbox binding')
                    else:
                        require(action['kind'] == 'spawn' and bool(re.fullmatch(r'[a-f0-9]{64}', str(continuation['brief_sha256']))), 'invalid spawn brief binding')
                elif continuation.get('type') == 'blocker':
                    require(action['kind'] in ('wait', 'decision'), 'blocker requires wait/decision action')
                    require(text(continuation.get('owner')) and text(continuation.get('dependency')), 'blocker needs owner and dependency')
                    require(continuation.get('recovery_trigger') == 'evidence-change', 'unsupported recovery trigger')
                    require(text(continuation.get('release_ref')) and bool(re.fullmatch(r'[a-f0-9]{64}', str(continuation.get('release_sha256', '')))), 'blocker needs observable release condition')
                else:
                    raise Refusal('unsupported continuation type')
        if action and record['disposition'] != 'open':
            require(action['phase'] in ('confirmed', 'refused'), 'unreconciled action prevents terminal acceptance')
        if current:
            require(record.get('brief_sha256') == digest(regular(self.directory / 'brief.md')), 'brief changed; explicit reconciliation required')
            generation = self.generation()
            require(generation is None or generation == record['execution_generation'], 'stale execution generation')
        return record

    def validate_delegation(self, record):
        grant, precheck = record.get('delegation'), record.get('precheck')
        if record['schema'] == SCHEMA:
            require(grant is None and precheck is None, 'delegation requires explicit v2 upgrade')
            return
        if grant is not None:
            require(isinstance(grant, dict) and set(grant) == {
                'revision', 'issuer', 'authority_ref', 'authority_sha256', 'allowed',
                'edges', 'expires_at', 'revoked'}, 'invalid delegation fields')
            require(integer(grant['revision'], 1) and grant['issuer'] == 'main' and type(grant['revoked']) is bool, 'invalid delegation issuer/revision')
            require(text(grant['authority_ref'], 4096) and re.fullmatch('[a-f0-9]{64}', str(grant['authority_sha256'])), 'invalid delegation authority')
            allowed = grant['allowed']
            require(isinstance(allowed, list) and all(isinstance(x, str) and x in PERMISSIONS for x in allowed) and len(set(allowed)) == len(allowed), 'invalid delegation permissions')
            stamp(grant['expires_at'])
            require(isinstance(grant['edges'], list) and len(grant['edges']) <= 16, 'invalid dependency edges')
            for edge in grant['edges']:
                require(isinstance(edge, dict) and set(edge) == {'target', 'goal_revision', 'execution_generation', 'authority_ref', 'authority_sha256', 'scope'}, 'invalid dependency edge')
                require(atom(edge['target']) and edge['target'] != self.id and integer(edge['goal_revision'], 1) and atom(edge['execution_generation']), 'invalid dependency identity')
                require(text(edge['scope']) and text(edge['authority_ref'], 4096) and re.fullmatch('[a-f0-9]{64}', str(edge['authority_sha256'])), 'invalid dependency authority')
        if precheck is not None:
            require(isinstance(precheck, dict) and set(precheck) == {'delegation_revision', 'basis_key', 'conclusion', 'checks', 'summary'}, 'invalid precheck fields')
            require(grant and precheck['delegation_revision'] == grant['revision'], 'stale precheck delegation')
            require(re.fullmatch('[a-f0-9]{64}', str(precheck['basis_key'])) and text(precheck['summary']), 'invalid precheck basis')
            require(precheck['conclusion'] in ('needs-evidence', 'candidate', 'conflict', 'blocked'), 'invalid provisional conclusion')
            require(isinstance(precheck['checks'], list) and 1 <= len(precheck['checks']) <= 64, 'invalid precheck checks')
            for check in precheck['checks']:
                require(isinstance(check, dict) and set(check) == {'criterion', 'result', 'evidence'}, 'invalid criterion fields')
                require(text(check['criterion']) and check['result'] in ('present', 'missing', 'conflict', 'not-applicable'), 'invalid criterion')
                require(isinstance(check['evidence'], list) and len(check['evidence']) <= 64, 'invalid criterion evidence')
                if check['result'] in ('present', 'not-applicable'):
                    require(check['evidence'], 'present/not-applicable requires bound evidence')
                for item in check['evidence']:
                    require(isinstance(item, dict) and set(item) == {'ref', 'sha256'} and text(item['ref'], 4096) and re.fullmatch('[a-f0-9]{64}', str(item['sha256'])), 'invalid precheck evidence')
            if precheck['conclusion'] == 'candidate':
                require(all(c['result'] in ('present', 'not-applicable') for c in precheck['checks']), 'candidate still has missing/conflicting evidence')

    def delegated(self, record, permission, revision=None, effect=False):
        grant = record.get('delegation')
        require(record['schema'] == DELEGATED_SCHEMA and record['disposition'] == 'open' and grant, 'task is not delegated')
        require(self.generation() == record['execution_generation'], 'delegated task has no current exact executor identity')
        require(not grant['revoked'] and stamp(grant['expires_at']) > stamp(now()), 'delegation revoked or expired')
        require(revision is None or revision == grant['revision'], 'delegation revision conflict')
        require(permission in grant['allowed'], 'action outside delegation')
        self.reference(grant['authority_ref'], grant['authority_sha256'])
        if os.environ.get('FM_SUPERVISION_ACTOR', 'main') == 'branch':
            pid = os.environ.get('FM_LEASE_HOLDER_PID', '')
            require(pid.isdigit() and int(pid) > 1 and regular(self.state / '.lock').decode().strip() == pid, 'branch no longer owns the home generation')
            os.kill(int(pid), 0)
            scope = json.loads(os.environ.get('FM_BRANCH_TASK_SCOPE', '[]'))
            require(isinstance(scope, list) and (self.id in scope or scope == ['*']), 'task outside the current branch offer')
            binding = json.loads(os.environ.get('FM_BRANCH_TASK_BINDINGS', '{}')).get(self.id)
            require(binding == {'goal_revision': record['goal_revision'], 'brief_sha256': record['brief_sha256'],
                                'execution_generation': record['execution_generation'], 'delegation_revision': grant['revision']},
                    'task intent/delegation changed since branch admission')
        if effect and os.environ.get('FM_SUPERVISION_ACTOR', 'main') == 'branch':
            require(os.environ.get('FM_BRANCH_INPUT_BARRIER') != '1', 'unclassified user input prevents new effects')
            self.input_barrier(os.environ.get('FM_BRANCH_MAIN_SESSION_FILE', ''))
        return grant

    def input_barrier(self, session_file):
        # Read original input receipts again at effect time. An environment
        # snapshot alone misses input arriving during a long bash command.
        path = Path(session_file)
        require(path.is_absolute(), 'branch effects require the original MAIN input receipt session')
        st = path.lstat()
        require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and st.st_uid == os.getuid() and st.st_size <= 16777216, 'MAIN input receipt session is unsafe or exceeds bounded readback')
        entries = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        by_id = {e['id']: e for e in entries if 'id' in e}
        chain, seen = [], set()
        entry = entries[-1] if entries else {}
        while entry.get('id') and entry.get('id') not in seen:
            seen.add(entry['id']); chain.append(entry)
            entry = by_id.get(entry.get('parentId'), {})
        inputs = {}
        for entry in reversed(chain):
            if entry.get('type') == 'custom' and entry.get('customType') == 'fm-continuation-input':
                value = entry.get('data', {})
                inputs[value['id']] = value
        require(not any(not v.get('task') and not v.get('answer') for v in inputs.values()), 'unclassified original input receipt prevents new effects')

    def branch_patch(self, args):
        record = self.read()
        require(record and args.expected_revision == record['revision'], 'revision conflict')
        patch = load(Path(args.record))
        require(isinstance(patch, dict) and set(patch) <= {'delegation_revision', 'precheck', 'next_action'} and 'delegation_revision' in patch, 'branch patch cannot change semantic ownership')
        self.delegated(record, 'precheck', patch['delegation_revision'])
        original = json.dumps(record, sort_keys=True)
        if 'precheck' in patch:
            check = patch['precheck']
            require(check and check.get('basis_key') == self.observe()['basis_key'], 'precheck observation changed')
            require(check.get('delegation_revision') == patch['delegation_revision'], 'precheck delegation changed')
            for criterion in check.get('checks', []):
                for evidence in criterion.get('evidence', []):
                    self.reference(evidence['ref'], evidence['sha256'])
            record['precheck'] = check
        if 'next_action' in patch:
            action = patch['next_action']
            old = record.get('next_action')
            require(not old or old['phase'] in ('confirmed', 'refused'), 'outstanding action requires readback')
            require(action and action['kind'] in ('steer', 'wait', 'readback', 'decision'), 'branch cannot launch or change execution')
            self.delegated(record, 'steer-same-intent' if action['kind'] == 'steer' else 'observe-receipt', patch['delegation_revision'], effect=action['kind'] == 'steer')
            require(action['id'] == f'{self.id}.g{record["goal_revision"]}.a{record["next_action_seq"]}' and action['phase'] == 'prepared' and action['attempts'] == 0, 'new action must be monotonic and prepared')
            require(not old or old['phase'] != 'refused' or (old['kind'], old['payload_sha256']) != (action['kind'], action['payload_sha256']), 'refused effect budget cannot reset')
            self.reference(action['payload_ref'], action['payload_sha256'])
            continuation = action.get('continuation', {})
            if continuation.get('type') == 'blocker':
                self.reference(continuation['release_ref'], continuation['release_sha256'])
            if action['kind'] == 'steer':
                require(not action.get('continuation'), 'steer receipt belongs to the actual delivery owner')
            record['next_action'] = action
            record['next_action_seq'] += 1
            record['precheck'] = None
        if json.dumps(record, sort_keys=True) != original:
            record['revision'] += 1
            self.write(record)
        return record

    def handoff_binding(self, args):
        record = self.read()
        if not record or record['schema'] != DELEGATED_SCHEMA:
            require(not args.action_id, 'bound handoff requires v2 source')
            return None
        grant = self.delegated(record, 'handoff', effect=True)
        target = Task(args.target).read()
        require(target and target['disposition'] == 'open', 'dependency target is not an enrolled open task')
        edge = next((e for e in grant['edges'] if e['target'] == args.target and e['goal_revision'] == target['goal_revision'] and e['execution_generation'] == target['execution_generation']), None)
        require(edge, 'dependency edge is not authorized for this target generation')
        self.reference(edge['authority_ref'], edge['authority_sha256'])
        action = record.get('next_action')
        require(action and action['id'] == args.action_id and action['kind'] == 'steer' and action['phase'] == 'prepared', 'handoff requires exact prepared action')
        keys = ('task_id', 'goal_revision', 'brief_sha256', 'execution_generation')
        return {'source': {k: record[k] for k in keys}, 'target': {k: target[k] for k in keys},
                'delegation_revision': grant['revision'], 'action_id': action['id'], 'payload_sha256': action['payload_sha256'],
                'input_session': os.environ.get('FM_BRANCH_MAIN_SESSION_FILE') if os.environ.get('FM_SUPERVISION_ACTOR') == 'branch' else None}

    def handoff_effect(self, args):
        raw = regular(Path(args.record))
        header, sep, body = raw.partition(b'--\n')
        fields = dict(line.decode().split('=', 1) for line in header.splitlines() if b'=' in line)
        binding = json.loads(fields.get('lifecycle', 'null'))
        require(binding and fields.get('from') == self.id and fields.get('target') == args.target, 'missing exact handoff binding')
        record = self.read()
        target = Task(args.target).read()
        for name, actual in (('source', record), ('target', target)):
            require(actual and actual['disposition'] == 'open' and all(actual.get(k) == v for k, v in binding[name].items()), 'handoff task identity changed')
        self.delegated(record, 'handoff', binding['delegation_revision'], effect=True)
        if binding.get('input_session'):
            self.input_barrier(binding['input_session'])
        require(digest(body) == binding['payload_sha256'], 'handoff body changed')
        action = record.get('next_action')
        require(action and action['id'] == binding['action_id'] and action['payload_sha256'] == binding['payload_sha256'], 'handoff action changed')
        # Preserve exact executor identity before the irreversible inbox enqueue.
        # After a crash observe can discover its receipt without a second send.
        continuation = {'type': 'executor', 'task_id': args.target, 'execution_generation': target['execution_generation'], 'handoff_id': fields['id']}
        if action['phase'] in ('attempted', 'uncertain', 'confirmed') and action.get('continuation') == continuation:
            matches = []
            inbox = self.state / (args.target + '.inbox')
            for folder in (inbox, inbox / 'handled'):
                for path in folder.glob('*.msg'):
                    message = regular(path)
                    headers, separator, received_body = message.partition(b'--\n')
                    if ('handoff=' + fields['id']).encode() in headers.splitlines():
                        require(separator and received_body == body, 'handoff receipt body collision')
                        matches.append(str(path))
            require(len(matches) == 1, 'effect receipt absent or conflicting; readback required, no replay')
            return {'readback': matches[0]}
        require(action['phase'] == 'prepared', 'handoff effect may have happened; readback required')
        require(action['attempts'] < action['attempt_limit'] and stamp(action['deadline']) >= stamp(now()), 'handoff budget expired')
        action['continuation'] = continuation
        action['phase'] = 'attempted'
        action['attempts'] += 1
        record['revision'] += 1
        self.write(record)
        return record

    def readback(self, args):
        record = self.read()
        require(record, 'no lifecycle to read back')
        self.delegated(record, 'observe-receipt')
        action = record.get('next_action')
        require(action and action['phase'] in ('attempted', 'uncertain'), 'no uncertain action to read back')
        if not action.get('continuation') and action['kind'] == 'steer':
            inbox = self.state / (self.id + '.inbox')
            matches = []
            for directory in (inbox, inbox / 'handled'):
                for path in directory.glob('*.msg'):
                    header = regular(path).partition(b'--\n')[0]
                    if ('handoff=action.' + action['id']).encode() in header.splitlines():
                        matches.append(path)
            require(len(matches) == 1, 'effect receipt absent or conflicting; no replay authorized')
            args.action_id, args.receipt_ref = action['id'], str(matches[0])
            return self.bind_inbox(args)
        return self.observe()

    def bind_inbox(self, args):
        record = self.read()
        action = record and record.get('next_action')
        require(action and action['id'] == args.action_id and action['phase'] in ('attempted', 'uncertain'), 'inbox action binding mismatch')
        raw = self.reference(args.receipt_ref)
        header, sep, body = raw.partition(b'--\n')
        require(sep and digest(body) == action['payload_sha256'] and ('handoff=action.' + action['id']).encode() in header.splitlines(), 'not the exact action inbox receipt')
        path = Path(args.receipt_ref)
        require(path.parent in (self.state / (self.id + '.inbox'), self.state / (self.id + '.inbox') / 'handled') and re.fullmatch(r'[0-9]+\.msg', path.name), 'inbox belongs to another task')
        action['continuation'] = {'type': 'executor', 'task_id': self.id, 'execution_generation': record['execution_generation'], 'inbox_id': path.stem, 'sha256': digest(raw)}
        action['receipt_ref'] = args.receipt_ref
        action['receipt_sha256'] = digest(raw)
        record['revision'] += 1
        self.write(record)
        return record

    def effect(self, args):
        """Called only inside the actual inbox owner's lease/meta critical section.

        attempted is persisted before enqueue. A repeated call is readback only;
        even a crash before enqueue never licenses an automatic resend.
        """
        record = self.read()
        require(record and record['disposition'] == 'open', 'effect requires an open goal')
        action = record.get('next_action')
        require(action and action['id'] == args.action_id and action['kind'] == 'steer', 'effect action identity mismatch')
        require(action['phase'] == 'prepared', 'effect may have happened; readback required')
        require(action['payload_sha256'] == args.payload_sha256, 'effect body differs from prepared action')
        self.reference(action['payload_ref'], action['payload_sha256'])
        if os.environ.get('FM_SUPERVISION_ACTOR', 'main') == 'branch':
            self.delegated(record, 'steer-same-intent', effect=True)
        args.phase = 'attempted'
        return self.action(args)

    def read(self, current=True):
        if not self.path.exists() and not self.path.is_symlink():
            return None
        return self.validate(load(self.path), current)

    def write(self, record):
        record['assessment']['evidence_key'] = digest(json.dumps([
            record['goal_revision'], record['execution_generation'], record['disposition'],
            record['assessment']['evidence'], record['assessment']['remaining_gap'],
            record.get('next_action'), record.get('decision_ref'), record.get('cleanup_ref'),
        ], sort_keys=True).encode())
        self.validate(record)
        if self.path.exists() or self.path.is_symlink():
            regular(self.path, True)
        raw = (json.dumps(record, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()
        require(len(raw) <= MAX_BYTES, 'record too large')
        fd, temporary = tempfile.mkstemp(prefix='.lifecycle.', dir=self.directory)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            directory_fd = os.open(self.directory, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def coordinate(self, args):
        """Record actual native readback receipt, not execution or acceptance.

        The Pi clock receives/starts the readback and appends a session entry.
        Validate that exact persisted entry under the existing task CAS. The
        separate budget survives session/runtime changes and never edits action.
        """
        record = self.read()
        require(record is not None and args.expected_revision == record['revision'], 'revision conflict')
        proof = load(Path(args.record))
        require(isinstance(proof, dict), 'missing coordinator session proof')
        path = Path(proof.get('session_file', ''))
        require(path.is_absolute(), 'absolute session file required')
        st = path.lstat()
        require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and st.st_uid == os.getuid(), 'unsafe session file')
        offset, size = proof.get('offset'), proof.get('length')
        require(integer(offset) and integer(size, 1) and size <= 32768 and offset + size <= st.st_size, 'invalid session receipt range')
        with path.open('rb') as stream:
            header = json.loads(stream.readline(32768))
            stream.seek(offset)
            raw = stream.read(size)
        require(digest(raw) == proof.get('sha256'), 'session receipt changed')
        entry = json.loads(raw, object_pairs_hook=unique_object)
        require(entry.get('type') == 'custom' and entry.get('customType') == 'fm-continuation-receipt' and entry.get('id') == proof.get('entry_id'), 'not a native continuation receipt')
        receipt = entry.get('data', {})
        require(receipt.get('owner') == 'fm-periodic-stow' and atom(receipt.get('generation')), 'invalid readback owner')
        require(header.get('type') == 'session' and header.get('id') == receipt.get('session_id'), 'session identity changed')
        pid = receipt.get('pid')
        require(integer(pid, 2) and regular(self.state / '.lock').decode().strip() == str(pid), 'readback no longer owns the home lock')
        os.kill(pid, 0)
        parent = os.getpid()
        for _ in range(32):
            if parent == pid:
                break
            result = subprocess.run(['ps', '-o', 'ppid=', '-p', str(parent)], capture_output=True, text=True, check=False)
            require(result.returncode == 0 and result.stdout.strip().isdigit(), 'cannot verify readback process')
            parent = int(result.stdout.strip())
            require(parent > 1, 'readback caller is outside owning Pi process')
        require(parent == pid, 'readback process ancestry exceeded')
        current_ms = int(time.time() * 1000)
        started, recheck = receipt.get('started_at_ms'), receipt.get('recheck_at_ms')
        require(integer(started) and integer(recheck) and started <= current_ms + 1000 and started <= recheck and current_ms <= recheck, 'expired readback receipt')
        observation = self.observe()
        require(any(item == {'task_id': self.id, 'key': observation['key'], 'revision': record['revision']}
                    for item in receipt.get('observations', [])), 'receipt does not bind current readback')
        require(observation['state'] not in ('accepted', 'archived', 'running', 'blocked'), 'readback already has an ordinary continuation')
        coordination = record.get('coordination', {'budgets': {}})
        budgets = coordination['budgets']
        key = observation['key']
        require(key in budgets or len(budgets) < 256, 'readback fingerprint history is full; explicit reconciliation required')
        budget = budgets.setdefault(key, {'attempts': 0, 'not_before_ms': 0})
        delivered = receipt.get('delivered_admissions', {}).get(budget.get('reserved'))
        if delivered is not None:
            require(integer(delivered) and delivered <= current_ms, 'invalid admission delivery readback')
            budget.pop('reserved')
            budget['not_before_ms'] = max(budget['not_before_ms'], delivered + 30000 * 2 ** (budget['attempts'] - 1))
        if not budget.get('reserved') and budget['attempts'] < 2 and current_ms >= budget['not_before_ms']:
            budget['attempts'] += 1
            budget['not_before_ms'] = current_ms + 30000 * 2 ** (budget['attempts'] - 1)
            budget['reserved'] = 'n.' + key + '.' + str(budget['attempts'])
        admitted = bool(budget.get('reserved'))
        # A delivered escalation cannot discharge an unfinished obligation.
        # The existing heartbeat clock executes recovery; settle only retains
        # its reservation. Ordinary admissions and effect budgets stay intact.
        escalation = None
        recovery = None
        if budget['attempts'] == 2 and not admitted:
            escalation_id = 'e.' + key
            escalated = receipt.get('delivered_admissions', {}).get(escalation_id)
            if escalated is not None:
                require(integer(escalated) and escalated <= current_ms, 'invalid escalation delivery readback')
                budget['escalated_at_ms'] = escalated
            if budget.get('escalated_at_ms') is None:
                escalation = escalation_id
            else:
                budget.setdefault('recovery_attempts', 0)
                budget.setdefault('recovery_not_before_ms', budget['escalated_at_ms'] + 60000)
                recovered = receipt.get('delivered_admissions', {}).get(budget.get('recovery_reserved'))
                if recovered is not None:
                    require(integer(recovered) and recovered <= current_ms, 'invalid recovery delivery readback')
                    budget.pop('recovery_reserved')
                    delay = min(900000, 60000 * 2 ** min(budget['recovery_attempts'], 4))
                    budget['recovery_not_before_ms'] = max(budget['recovery_not_before_ms'], recovered + delay)
                if not budget.get('recovery_reserved') and current_ms >= budget['recovery_not_before_ms']:
                    require(budget['recovery_attempts'] < MAX_INT, 'recovery counter exhausted')
                    budget['recovery_attempts'] += 1
                    budget['recovery_reserved'] = 'r.' + key + '.' + str(budget['recovery_attempts'])
                recovery = budget.get('recovery_reserved')
        record['coordination'] = {'budgets': budgets, 'observation_key': key,
                                  'receipt': proof, 'receiver': receipt}
        record['revision'] += 1
        self.write(record)
        return {'observation': observation, 'coordination': record['coordination'], 'admitted': admitted,
                'admission': budget.get('reserved'),
                'escalation': escalation,
                'recovery': recovery,
                'revision': record['revision']}

    def reconcile(self, args):
        prior = self.read(current=False)
        require(args.expected_revision == (prior['revision'] if prior else 0), 'revision conflict')
        candidate = load(Path(args.record))
        candidate['revision'] = args.expected_revision + 1
        if prior and 'coordination' in prior:
            require(candidate.get('coordination', prior['coordination']) == prior['coordination'], 'coordination belongs to the native readback owner')
            candidate['coordination'] = prior['coordination']
        else:
            require('coordination' not in candidate, 'coordination requires an actual native readback receipt')
        self.validate(candidate)
        grant = candidate.get('delegation')
        if grant:
            self.reference(grant['authority_ref'], grant['authority_sha256'])
            for edge in grant['edges']:
                self.reference(edge['authority_ref'], edge['authority_sha256'])
        if prior:
            old_grant = prior.get('delegation')
            if old_grant and not old_grant['revoked']:
                require(all(candidate.get(k) == prior.get(k) for k in ('goal_revision', 'brief_sha256', 'execution_generation')), 'revoke delegation before changing intent')
            if grant != old_grant:
                require(grant and grant['revision'] == (old_grant['revision'] + 1 if old_grant else 1), 'delegation revision must advance once')
                require(candidate.get('precheck') is None, 'new delegation invalidates precheck')
            if prior['schema'] == DELEGATED_SCHEMA:
                require(candidate['schema'] == DELEGATED_SCHEMA, 'v2 receipts cannot be downgraded')
            if candidate['disposition'] == 'accepted' and candidate.get('precheck'):
                require(candidate['precheck'] == prior.get('precheck'), 'accept only the exact loaded candidate')
                require(candidate['precheck']['basis_key'] == self.observe()['basis_key'], 'candidate observation is stale')
                for check in candidate['precheck']['checks']:
                    for item in check['evidence']:
                        self.reference(item['ref'], item['sha256'])
        candidate_authority = self.authority_identity(candidate['assessment']['authority_ref'])
        for item in candidate['assessment']['evidence']:
            self.reference(item['ref'], item['sha256'])
        action = candidate.get('next_action')
        if action:
            self.reference(action['payload_ref'], action['payload_sha256'])
            continuation = action.get('continuation', {})
            if continuation.get('type') == 'blocker' and (not prior or action != prior.get('next_action')):
                self.reference(continuation['release_ref'], continuation['release_sha256'])
        if candidate['disposition'] != 'open' and action and (not prior or action != prior.get('next_action')):
            require(action['kind'] in ('decision', 'readback', 'wait'), 'terminal task cannot prepare execution')
        if prior:
            require(candidate['goal_revision'] in (prior['goal_revision'], prior['goal_revision'] + 1), 'goal revision must advance once')
            if candidate['execution_generation'] != prior['execution_generation']:
                require(candidate['disposition'] == 'open' and ((prior['execution_generation'] == 'unassigned-g1' and not prior.get('next_action')) or
                        (candidate['goal_revision'] == prior['goal_revision'] + 1 and candidate['assessment']['authority_ref'] != prior['assessment']['authority_ref'])),
                        'replacement execution requires a newly authorized open goal; reconcile the replacement explicitly')
            if prior['disposition'] != 'open' and candidate['disposition'] == 'open':
                require(candidate['goal_revision'] == prior['goal_revision'] + 1 and candidate['assessment']['authority_ref'] != prior['assessment']['authority_ref'], 'reopen requires a new goal and explicit authority')
            if prior['disposition'] != 'archived' and candidate['disposition'] == 'archived':
                require(candidate_authority != self.authority_identity(prior['assessment']['authority_ref']), 'archive requires explicit stop authority')
            old_action = prior.get('next_action')
            if old_action and old_action['phase'] not in ('confirmed', 'refused'):
                require(action == old_action, 'outstanding action must be confirmed/refused before replacement')
            if action and (not old_action or old_action['id'] != action['id']):
                require(action['id'] == f'{self.id}.g{candidate["goal_revision"]}.a{prior["next_action_seq"]}' and action['phase'] == 'prepared' and action['attempts'] == 0, 'new action identity/phase must be monotonic')
                require(candidate['next_action_seq'] == prior['next_action_seq'] + 1, 'action sequence mismatch')
                if old_action and old_action['phase'] == 'refused' and candidate['goal_revision'] == prior['goal_revision']:
                    require((action['kind'], action['payload_sha256']) != (old_action['kind'], old_action['payload_sha256']),
                            'same refused effect cannot reset its budget under a new id; choose a materially different authorized step')
            else:
                if action and old_action:
                    require(action == old_action, 'action id collision; use a new action identity')
                require(candidate['next_action_seq'] == prior['next_action_seq'], 'unexpected action sequence change')
        elif action:
            require(action['phase'] == 'prepared' and action['attempts'] == 0 and action['id'] == f'{self.id}.g1.a1' and candidate['next_action_seq'] == 2, 'invalid initial action')
        # write() derives the evidence binding, including durable action state.
        if prior:
            compare = dict(candidate, revision=prior['revision'])
            compare['assessment'] = dict(compare['assessment'], assessed_at=prior['assessment']['assessed_at'])
            if compare == prior:
                return prior
        self.write(candidate)
        return candidate

    def action(self, args):
        record = self.read()
        require(record is not None, 'no goal assessment')
        if os.environ.get('FM_SUPERVISION_ACTOR', 'main') == 'branch':
            self.delegated(record, 'observe-receipt')
            require(args.operation == 'effect' or args.phase == 'confirmed', 'branch phase requires owner evidence')
        action = record.get('next_action')
        require(action and action['id'] == args.action_id, 'action identity conflict')
        if action['phase'] == args.phase:
            return record
        transitions = {'prepared': {'attempted', 'refused'}, 'attempted': {'confirmed', 'uncertain', 'refused'}, 'uncertain': {'confirmed', 'refused'}}
        require(args.phase in transitions.get(action['phase'], set()), 'invalid action phase transition')
        if args.phase == 'attempted':
            require(record['disposition'] == 'open' or action['kind'] in ('decision', 'readback', 'wait'), 'terminal task cannot execute')
            require(action['attempts'] < action['attempt_limit'] and stamp(action['deadline']) >= stamp(now()), 'action budget expired')
            action['attempts'] += 1
        else:
            require(args.receipt_ref and args.receipt_sha256, 'phase change requires a bound owner receipt')
            self.reference(args.receipt_ref, args.receipt_sha256)
            action['receipt_ref'] = args.receipt_ref
            action['receipt_sha256'] = args.receipt_sha256
        if os.environ.get('FM_SUPERVISION_ACTOR', 'main') == 'branch' and args.phase == 'confirmed':
            require(action.get('continuation', {}).get('type') == 'executor', 'branch confirmation requires actual executor receipt')
        if args.phase == 'confirmed' and action.get('continuation', {}).get('type') == 'executor':
            require(self.observe_executor(action['continuation'])[0] == 'running', 'executor has not acknowledged its exact instruction')
        action['phase'] = args.phase
        record['revision'] += 1
        self.write(record)
        return record

    def observe_executor(self, continuation):
        target = continuation['task_id']
        fields = {}
        for line in regular(self.state / (target + '.meta')).decode().splitlines():
            key, sep, value = line.partition('=')
            if sep:
                require(key not in fields, 'duplicate executor metadata')
                fields[key] = value
        require(fields.get('spawn_gen') == continuation['execution_generation'], 'executor generation changed')
        require(fields.get('executor', 'local-agent') == 'local-agent' and fields.get('kind') != 'secondmate', 'executor receipt requires an ordinary local task')
        directory = self.state / (target + '.inbox')
        require(not directory.is_symlink(), 'unsafe inbox')
        handled = directory / 'handled'
        require(not handled.is_symlink(), 'unsafe handled inbox')
        handoff = continuation.get('handoff_id')
        if continuation.get('brief_sha256'):
            self.reference(str(self.data / target / 'brief.md'), continuation['brief_sha256'])
        elif handoff:
            record = self.state / 'task-handoffs' / 'records' / (handoff + '.msg')
            raw = self.reference(str(record)).decode()
            header, body = raw.split('\n--\n', 1)
            values = dict(line.split('=', 1) for line in header.splitlines() if '=' in line)
            require(values.get('from') == self.id and values.get('target') == target, 'handoff task identity mismatch')
            # Inbox owner already deduplicates queued and handled records by this id.
            matches = []
            for folder in (directory, handled):
                if not folder.exists():
                    continue
                for path in folder.glob('*.msg'):
                    raw_message = self.reference(str(path)).decode()
                    headers, message_body = raw_message.split('\n--\n', 1)
                    if ('handoff=' + handoff) in headers.splitlines():
                        require(message_body == body, 'handoff body collision')
                        matches.append(path)
            require(len(matches) <= 1, 'duplicate handoff receipts')
            if not matches or matches[0].parent != handled:
                return 'pending', 'handoff queued or lease-refused; retry only the existing handoff id'
            receipt = matches[0]
        else:
            receipt = handled / (continuation['inbox_id'] + '.msg')
            if not receipt.exists():
                return 'pending', 'executor has not handled the exact inbox message'
            self.reference(str(receipt), continuation['sha256'])
        # Current state is still owned by the provider-aware public reader.
        result = subprocess.run([str(Path(__file__).with_name('fm-task-state.sh')), target],
                                text=True, capture_output=True, timeout=3, check=False)
        require(result.returncode == 0, 'executor state read failed')
        match = re.search(r'(?:^|\n)state: ([a-z-]+)', result.stdout)
        require(match is not None, 'executor state unreadable')
        if match[1] != 'working':
            return 'pending', 'executor receipt exists but current state is ' + match[1]
        if continuation.get('brief_sha256'):
            if not re.search(r'harness busy \((?:pi-ext|codex-transcript|traex-transcript)\)', result.stdout):
                return 'pending', 'spawn brief is assigned but actual harness start is not observed'
            return 'running', 'bound spawn brief and actual harness activity observed'
        return 'running', 'exact handled inbox receipt and current working executor'

    def observe(self):
        record = self.read()
        if record is None:
            return {'task_id': self.id, 'state': 'unknown', 'reason': 'not enrolled', 'key': 'absent'}
        disposition = record['disposition']
        state, reason = disposition, 'semantic disposition recorded by main'
        action = record.get('next_action')
        observation = ''
        if disposition == 'open':
            state, reason = 'pending', 'no verified continuation; compare remaining acceptance with the brief'
            if action:
                continuation = action.get('continuation', {})
                if action['phase'] in ('attempted', 'uncertain'):
                    reason = 'effect may have happened; read back before any retry'
                    if continuation.get('type') == 'executor':
                        observed, detail = self.observe_executor(continuation)
                        observation = observed + ': ' + detail
                        if observed == 'running':
                            reason = 'executor receipt/start observed; confirm the existing action without replay'
                elif action['phase'] == 'refused':
                    reason = 'action refused; choose a different authorized diagnostic or evidenced blocker'
                elif continuation.get('type') == 'blocker':
                    raw = self.reference(continuation['release_ref'])
                    observation = digest(raw)
                    if observation == continuation['release_sha256'] and stamp(now()) < stamp(action['deadline']):
                        state, reason = 'blocked', continuation['owner'] + ': ' + continuation['dependency']
                    else:
                        reason = 'dependency evidence changed or blocker deadline expired; re-evaluate exact next action'
                elif continuation.get('type') == 'executor':
                    state, reason = self.observe_executor(continuation)
                    if state == 'running' and stamp(now()) >= stamp(action['deadline']):
                        state, reason = 'pending', 'execution observation deadline reached; read back without replay'
        # Stable over re-reads and superficial no-change reassessments. Never a retry key for effects.
        key = digest(json.dumps([self.id, record['goal_revision'], record['execution_generation'],
                                 state, reason, observation, record['assessment']['remaining_gap'],
                                 action], sort_keys=True).encode())
        basis_key = key
        precheck = record.get('precheck')
        candidate = bool(precheck and precheck['basis_key'] == basis_key and precheck['conclusion'] in ('candidate', 'conflict', 'blocked'))
        if candidate and disposition == 'open':
            state, reason = 'pending', 'preliminary ' + precheck['conclusion'] + ': ' + precheck['summary']
            key = digest(json.dumps([basis_key, precheck], sort_keys=True).encode())
        delegated = False
        try:
            self.delegated(record, 'inspect')
            delegated = not candidate
        except Refusal:
            pass
        return {'task_id': self.id, 'state': state, 'reason': reason, 'key': key, 'basis_key': basis_key,
                'delegated': delegated, 'revision': record['revision']}


    def init(self):
        prior = self.read()
        if prior:
            return prior
        brief = self.directory / 'brief.md'
        sha = digest(regular(brief))
        generation = self.generation()
        generation = generation or 'unassigned-g1'
        ref = str(brief)
        result = {
            'schema': SCHEMA, 'task_id': self.id, 'revision': 1,
            'goal_revision': 1, 'brief_sha256': sha,
            'execution_generation': generation, 'disposition': 'open',
            'decision_ref': None, 'cleanup_ref': None,
            'assessment': {'evidence_key': sha, 'outcome': 'Execution published; acceptance has not been assessed.',
                           'remaining_gap': 'Reconcile the requested outcome against the durable brief.',
                           'evidence': [{'ref': ref, 'sha256': sha}],
                           'authority_ref': ref, 'assessed_at': now()},
            'next_action': None, 'next_action_seq': 1,
        }
        self.write(result)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('read', 'init', 'reconcile', 'action', 'observe', 'coordinate', 'branch-patch', 'effect', 'bind-inbox', 'handoff-binding', 'handoff-effect', 'readback'))
    parser.add_argument('task')
    parser.add_argument('--expected-revision', type=int)
    parser.add_argument('--record')
    parser.add_argument('--action-id')
    parser.add_argument('--target')
    parser.add_argument('--payload-sha256')
    parser.add_argument('--phase', choices=tuple(PHASES))
    parser.add_argument('--receipt-ref')
    parser.add_argument('--receipt-sha256')
    args = parser.parse_args()
    try:
        task = Task(args.task)
        if args.operation == 'init':
            result = task.init()
        elif args.operation == 'reconcile':
            require(integer(args.expected_revision) and args.record, 'reconcile needs revision and record')
            result = task.reconcile(args)
        elif args.operation == 'coordinate':
            require(integer(args.expected_revision) and args.record, 'coordinate needs revision and receipt record')
            result = task.coordinate(args)
        elif args.operation == 'branch-patch':
            result = task.branch_patch(args)
        elif args.operation == 'readback':
            result = task.readback(args)
        elif args.operation == 'handoff-binding':
            result = task.handoff_binding(args)
        elif args.operation == 'handoff-effect':
            result = task.handoff_effect(args)
        elif args.operation == 'bind-inbox':
            result = task.bind_inbox(args)
        elif args.operation == 'effect':
            result = task.effect(args)
        elif args.operation == 'action':
            result = task.action(args)
        elif args.operation == 'observe':
            result = task.observe()
        else:
            result = task.read()
        print(json.dumps(result, ensure_ascii=False))
    except (Refusal, OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired) as error:
        print('REFUSED: lifecycle: ' + str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
