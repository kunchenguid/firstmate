#!/usr/bin/env python3
"""Task-local lifecycle record mechanics, called under the existing meta lock.

Not a worker, queue or semantic acceptance engine.
Public entry: fm-task-state.sh lifecycle|enroll|reconcile|action|observe|coordinate TASK.
MAIN normally uses inspect/assess, not a reconstructed lifecycle document:
  inspect ID --evidence data/checks --evidence data/authority
  assess ID --basis TOKEN --judgment '{"disposition":"open","outcome":"...",
    "remaining_gap":"...","authority_ref":"data/authority","evidence":["data/checks"]}'
inspect returns an opaque basis binding the record, current brief, execution and
every specified file. Include authority, action payload and blocker release paths
in that inspection. assess takes semantic fields only; stale bytes or revisions
refuse. next_action optionally supplies kind, payload_ref, recheck_at, deadline,
attempt_limit (default 1), and blocker {owner,dependency,release_ref}; null clears
only a resolved action. supersede_prepared explicitly clears/replaces an
unattempted wait/readback/decision with new authority and exact old-payload
evidence; attempted/uncertain effects still require readback.
The owner derives identity, hashes, timestamps and counters.
intent_changed is explicit MAIN reconciliation for unexplained brief/execution
changes with new authority; revoke_delegation revokes a v2 grant separately first.
The native fm_task_continuation route action with update_brief:true appends exact
authenticated input words to the intent subsection and synchronizes this record.
Its internal update-brief takes --session-file, --entry-id and --input, verifying
the original current-branch user message (or verified Feishu delivery) and explicit
task route under the native home owner and task lock. Historical task-assigned
capture proofs remain recoverable; chat is not an independently supervised goal.
The bounded intent_updates field retains before/after hashes and a prepared
transaction until atomic brief replacement and record commit converge. Retry
the same route after interruption; a different unexplained byte sequence refuses.
refresh records a verified executor receipt/start without semantic acceptance.
Merge and cleanup owners alone call owner-receipt inside their guarded effects;
owner_receipts holds exact generation-bound observed facts, never permissions.
completion-read validates retained-resource business closure: terminal judgment,
assessed report and captain-call inventory for scouts, guarded merge facts for
accepted ships. Explicit archive is stop authority, never invented delivery.
cleanup-copy-inspect reads the current metadata directory/Git identity without
writing; current MAIN judgments bind that snapshot. cleanup-copy-bind captures the original metadata's canonical copy/project
paths, directory and Git owner identities in the existing cleanup receipt before
metadata removal. cleanup-copy-read verifies this immutable home/task/generation
binding for the teardown owner's copy-only path; it never recreates metadata.
Missing historical identity and attempted disposal require exact readback.
cleanup-preserve is private teardown-owner bookkeeping after the exact MAIN
ShortTask recovery in fm-short-agent.mjs. It binds a distinct preservation proof
to the immutable failed attempt and surviving copy, never disposal success.
cleanup_complete recognizes that proof only with completed cleanup-owner facts.
link-cleanup owns cleanup_observation_key in this same record: phase state/reason
and identity bindings, excluding presentation clocks and additive diagnostics.
The due reader also recognizes assessed historical ShortTask results through
their same-home request, nonce, exact cleanup step, execution binding and complete
operation receipt. Missing/conflicting evidence remains due; readback never replays.
inspect/assess/update-brief/refresh return the current judgment/action and receipt
summary; lifecycle retains the complete coordination and recovery history.
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
    Ordinary actionless dispatch can use its confirmed launch publication with
    the lifecycle-bound brief and execution generation for the same observation.
    A spawn brief needs observed pi-ext/Codex/TraeX transcript activity, never
    the synthetic fm-spawn busy seed, process presence, or a status report.
    A matching handled inbox message plus current working executor proves receipt;
    delivery alone is pending. This reader never sends, retries or relaunches.
  blocker: {type, owner, dependency, release_ref, release_sha256, recovery_trigger,
            optional release_projection: delivery-v1, release_task_kind: ship|scout}.
    recovery_trigger is evidence-change; an unchanged bound dependency stays quiet
    until deadline, then becomes due once. Changed evidence requests judgment,
    never grants effect/merge/permission authority.
    New terminal lifecycle-file blockers use delivery-v1: task/goal/execution/brief,
    disposition, assessed final scout report, or current-generation guarded ship
    merge facts. Open goals, other files and historical bindings stay byte-bound.
    This never loosens inspect or effect-payload byte checks.
Unknown, stale, missing or uncertain effects are due for readback, never replay.
An action receipt is not goal acceptance. Acceptance is main's evidence-backed
assessment with an empty remaining_gap. Archived goals never request execution.
Cleanup receipts and remote-followup effects use this same record; they never
authorize historical enrollment or provider success acceptance. A supervisor supplies the
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
import copy
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time
import subprocess

SCHEMA = 'fm-task-lifecycle.v1'
DELEGATED_SCHEMA = 'fm-task-lifecycle.v2'
PERMISSIONS = {'inspect', 'precheck', 'steer-same-intent', 'observe-receipt', 'handoff'}
MAX_BYTES = 262144
MAX_INT = 9007199254740991
KINDS = {'steer', 'relaunch', 'spawn', 'readback', 'wait', 'decision', 'cleanup', 'remote-followup'}
PHASES = {'prepared', 'attempted', 'confirmed', 'refused', 'uncertain'}
SESSION_INDEX_SCHEMA = 'fm-task-session-index.v1'
SESSION_SCAN_BYTES = 33554432
SESSION_RECORD_BYTES = 16777216
SESSION_INDEX_BYTES = 16777216
SESSION_INDEX_ENTRIES = 50000


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


def native_session(path, index_directory, selected_entry=None, input_id=None):
    """Incrementally index bounded session deltas and read current-branch records."""
    require(path.is_absolute(), 'native session path must be absolute')
    started = time.monotonic()
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(fd, 'rb') as stream:
        st = os.fstat(stream.fileno())
        require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and st.st_uid == os.getuid(), 'unsafe native input session file identity')
        probe = os.environ.get('FM_TASK_SESSION_READ_PROBE')
        def emit_probe(session_bytes, records, status):
            if probe:
                with open(probe, 'a', encoding='utf-8') as output:
                    output.write(json.dumps({'bytes': session_bytes, 'records': records, 'status': status}) + '\n')
        emit_probe(0, 0, 'start')
        index_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        index_st = index_directory.lstat()
        require(stat.S_ISDIR(index_st.st_mode) and index_st.st_uid == os.getuid() and not index_directory.is_symlink(),
                'unsafe native session index directory')
        index_path = index_directory / (digest(str(path).encode()) + '.json')
        cached = None
        if index_path.exists() or index_path.is_symlink():
            index_file_st = index_path.lstat()
            require(stat.S_ISREG(index_file_st.st_mode) and index_file_st.st_nlink == 1 and
                    index_file_st.st_uid == os.getuid() and index_file_st.st_size <= SESSION_INDEX_BYTES,
                    'unsafe native session index')
            try:
                candidate = json.loads(index_path.read_bytes(), object_pairs_hook=unique_object)
                candidate_entries = candidate.get('entries')
                require(candidate.get('schema') == SESSION_INDEX_SCHEMA and candidate.get('path') == str(path) and
                        candidate.get('device') == st.st_dev and candidate.get('inode') == st.st_ino and
                        integer(candidate.get('indexed_size')) and candidate['indexed_size'] <= st.st_size and
                        isinstance(candidate_entries, list) and len(candidate_entries) <= SESSION_INDEX_ENTRIES,
                        'stale native session index')
                offsets = {}
                for item in candidate_entries:
                    require(isinstance(item, dict) and text(item.get('id'), 512) and
                            (item.get('parentId') is None or text(item.get('parentId'), 512)) and
                            integer(item.get('offset')) and integer(item.get('length'), 1) and
                            bool(re.fullmatch(r'[a-f0-9]{64}', str(item.get('sha256', '')))),
                            'invalid native session index entry')
                    require(item['id'] not in offsets, 'duplicate native session index identity')
                    offsets[item['id']] = item
                boundary_length = min(4096, candidate['indexed_size'])
                boundary = os.pread(stream.fileno(), boundary_length, candidate['indexed_size'] - boundary_length)
                require(digest(boundary) == candidate.get('boundary_sha256'), 'native session index boundary changed')
                if candidate['indexed_size'] == st.st_size:
                    require(candidate.get('mtime_ns') == st.st_mtime_ns, 'native session changed without append')
                cached = candidate
            except (Refusal, ValueError, TypeError, KeyError, AttributeError):
                cached = None
        index = cached or {'schema': SESSION_INDEX_SCHEMA, 'path': str(path), 'device': st.st_dev,
                           'inode': st.st_ino, 'indexed_size': 0, 'header': None, 'entries': [], 'leaf_id': None}
        offsets = {item['id']: item for item in index['entries']}
        starting_offset = index['indexed_size']
        checkpoint = starting_offset
        stream.seek(starting_offset)
        scanned_bytes = 0
        scanned_records = 0
        while stream.tell() < st.st_size and time.monotonic() - started < 10:
            offset = stream.tell()
            remaining = min(SESSION_SCAN_BYTES - scanned_bytes, st.st_size - offset)
            if remaining <= 0:
                break
            raw = stream.readline(min(SESSION_RECORD_BYTES + 1, remaining))
            if not raw:
                break
            scanned_bytes += len(raw)
            require(len(raw) <= SESSION_RECORD_BYTES, 'native session record exceeds bounded readback')
            if not raw.endswith(b'\n') and stream.tell() < st.st_size:
                stream.seek(offset)
                break
            checkpoint = stream.tell()
            if not raw.strip():
                continue
            entry = json.loads(raw, object_pairs_hook=unique_object)
            scanned_records += 1
            if index['header'] is None:
                require(entry.get('type') == 'session', 'missing session identity')
                index['header'] = {'offset': offset, 'length': len(raw), 'sha256': digest(raw)}
                continue
            require(len(index['entries']) < SESSION_INDEX_ENTRIES, 'native session index exceeds entry bound')
            entry_id = entry.get('id')
            parent_id = entry.get('parentId')
            require(text(entry_id, 512) and (parent_id is None or text(parent_id, 512)), 'invalid native session ancestry')
            require(entry_id not in offsets, 'duplicate session entry identity')
            receipt = entry.get('type') == 'custom' and entry.get('customType') == 'fm-continuation-input'
            item = {'id': entry_id, 'parentId': parent_id, 'type': entry.get('type'), 'offset': offset,
                    'length': len(raw), 'sha256': digest(raw)}
            if receipt:
                item.update({'customType': 'fm-continuation-input', 'input_id': entry.get('data', {}).get('id'),
                             'task': entry.get('data', {}).get('task'), 'pending': entry.get('data', {}).get('pending')})
            index['entries'].append(item)
            offsets[entry_id] = item
            index['leaf_id'] = entry_id
        require(index['header'] is not None, 'missing session identity')
        index['indexed_size'] = checkpoint
        index['mtime_ns'] = st.st_mtime_ns
        boundary_length = min(4096, checkpoint)
        index['boundary_sha256'] = digest(os.pread(stream.fileno(), boundary_length, checkpoint - boundary_length))
        changed_index = bool(scanned_bytes or cached is None)
        def persist_index():
            raw_index = (json.dumps(index, ensure_ascii=False, separators=(',', ':')) + '\n').encode()
            require(len(raw_index) <= SESSION_INDEX_BYTES, 'native session index exceeds byte bound')
            temporary_fd, temporary = tempfile.mkstemp(prefix='.session-index.', dir=index_directory)
            try:
                with os.fdopen(temporary_fd, 'wb') as output:
                    output.write(raw_index); output.flush(); os.fsync(output.fileno())
                os.replace(temporary, index_path)
            finally:
                if os.path.exists(temporary): os.unlink(temporary)
        after_scan = os.fstat(stream.fileno())
        if (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns) != \
                (after_scan.st_dev, after_scan.st_ino, after_scan.st_size, after_scan.st_mtime_ns):
            emit_probe(scanned_bytes, scanned_records, 'changed')
            raise Refusal('native session changed during readback')
        if checkpoint < st.st_size:
            require(checkpoint > starting_offset, 'native session bounded readback made no complete-record progress')
            if changed_index:
                persist_index()
            emit_probe(scanned_bytes, scanned_records, 'checkpoint')
            raise Refusal('native session index catch-up incomplete; retry the same operation')

        chain, seen = [], set()
        entry_id = index['leaf_id']
        while entry_id is not None:
            require(entry_id not in seen, 'invalid session ancestry')
            seen.add(entry_id)
            item = offsets.get(entry_id)
            require(item is not None, 'incomplete session ancestry')
            chain.append(item)
            entry_id = item['parentId']
        chain.reverse()
        require(selected_entry is None or selected_entry in seen, 'route receipt is outside the current session branch')

        session_bytes = scanned_bytes
        def read_indexed(item):
            nonlocal session_bytes
            raw = os.pread(stream.fileno(), item['length'], item['offset'])
            session_bytes += len(raw)
            require(len(raw) == item['length'] and digest(raw) == item['sha256'], 'native session indexed entry changed')
            return json.loads(raw, object_pairs_hook=unique_object)

        header = read_indexed(index['header'])
        full = set()
        if selected_entry is not None:
            full.add(selected_entry)
            route = read_indexed(offsets[selected_entry])
            source_id = route.get('data', {}).get('source_entry_id')
            if source_id is not None:
                require(source_id in seen, 'original message is outside the current session branch')
                full.add(source_id)
        entries = [header]
        retained_bytes = 0
        for item in chain:
            receipt = item.get('customType') == 'fm-continuation-input'
            keep = item['id'] in full or receipt and (input_id is None or item.get('input_id') == input_id)
            if keep:
                entry = route if selected_entry == item['id'] else read_indexed(item)
                retained_bytes += item['length']
                require(retained_bytes <= SESSION_RECORD_BYTES, 'native task receipts exceed bounded readback')
                if input_id is None and receipt:
                    entry['data'] = {key: entry.get('data', {})[key] for key in ('id', 'task', 'pending') if key in entry.get('data', {})}
                entries.append(entry)
            else:
                entries.append({key: item[key] for key in ('id', 'parentId', 'type') if key in item})
        final = os.fstat(stream.fileno())
        require((st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns) ==
                (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns), 'native session changed during readback')
        if changed_index:
            persist_index()
        emit_probe(session_bytes, scanned_records, 'success')
        return entries


def load(path):
    return json.loads(regular(path, True), object_pairs_hook=unique_object)


def complete_cleanup_facts(facts):
    """Known postconditions, not incidental extra diagnostic fields, prove completion."""
    return (isinstance(facts, dict) and facts.get('taskRecordRemoved') is True and
            facts.get('endpointConfirmedGone') is True and facts.get('bookkeepingComplete') is True and
            facts.get('copyDisposition') in ('returned-or-already-absent', 'retained-shared', 'retained-primary', 'retained-dirty', 'retained-unlanded', 'retained-unverified'))


def cleanup_observation(receipt):
    """Retained resource facts, excluding business close and presentation data."""
    result = {key: receipt.get(key) for key in
              ('task_id', 'spawn_gen', 'goal_revision', 'journal_sha256', 'launch_binding', 'copy_binding', 'preservation_ref', 'preservation_sha256')}
    phases = receipt.get('phases', {})
    require(isinstance(phases, dict), 'invalid cleanup phases')
    require(all(isinstance(phase, dict) for phase in phases.values()), 'invalid cleanup phase')
    result['phases'] = {name: {key: phase.get(key) for key in ('state', 'reason_code')}
                        for name, phase in phases.items() if name != 'record_close'}
    return result


def cleanup_observation_matches(receipt, key):
    """Absent preservation fields add no fact to a pre-preservation digest."""
    observation = cleanup_observation(receipt)
    if key == digest(json.dumps(observation, sort_keys=True).encode()):
        return True
    if 'preservation_ref' in receipt or 'preservation_sha256' in receipt:
        return False
    for field in ('preservation_ref', 'preservation_sha256'):
        observation.pop(field)
    return key == digest(json.dumps(observation, sort_keys=True).encode())


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

    def task_kind(self):
        meta = self.state / (self.id + '.meta')
        values = []
        for line in regular(meta).decode().splitlines():
            key, sep, value = line.partition('=')
            if sep and key == 'kind':
                values.append(value)
        require(len(values) == 1 and values[0] in ('ship', 'scout'), 'completion needs a known task kind')
        return values[0]

    def captain_call_completion(self, record=None):
        meta = self.state / (self.id + '.meta')
        if not meta.exists() and not meta.is_symlink():
            return (record or self.read(current=False) or {}).get('captain_call_completion')
        reviewed = None
        keys = None
        for line in regular(meta).decode().splitlines():
            key, sep, value = line.partition('=')
            if sep and key == 'decisions_reviewed':
                reviewed = value
            elif sep and key == 'decision_keys':
                keys = value
        if reviewed != '1' or keys is None:
            return None
        inventory = [] if not keys else keys.split(',')
        if not all(atom(key) for key in inventory) or inventory != sorted(set(inventory)):
            return None
        try:
            gate = subprocess.run([str(Path(__file__).with_name('fm-captain-hold.sh')), 'verify', self.id],
                env=dict(os.environ, FM_HOME=str(self.home), FM_DATA_OVERRIDE=str(self.data),
                         FM_STATE_OVERRIDE=str(self.state)), capture_output=True, text=True, timeout=10, check=False)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if gate.returncode != 0:
            return None
        return {'decisions_reviewed': True, 'decision_keys': inventory, 'verified': True}

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

    def release_digest(self, ref, task_kind=None):
        """A lifecycle dependency releases on goal/delivery, not readback bookkeeping.

        Other evidence remains byte-bound. This projection is observation only;
        inspect/assessment evidence and effect payloads still bind exact bytes.
        """
        raw = self.reference(ref)
        path = Path(ref)
        if not path.is_absolute():
            path = self.home / path
        if path.name != 'lifecycle.json':
            return digest(raw)
        dependency = Task(path.parent.name)
        require(path.resolve() == dependency.path.resolve(), 'noncanonical lifecycle dependency')
        record = dependency.read()
        require(record is not None, 'missing lifecycle dependency')
        task_kind = task_kind or dependency.task_kind()
        require(task_kind in ('ship', 'scout'), 'delivery projection needs a known task kind')
        delivery = None
        if record['disposition'] == 'accepted' and task_kind == 'scout':
            report = dependency.directory / 'report.md'
            identity = str(report.resolve(strict=True))
            reports = []
            for item in record['assessment']['evidence']:
                evidence = Path(item['ref'])
                if not evidence.is_absolute():
                    evidence = dependency.home / evidence
                if not evidence.is_symlink() and str(evidence.resolve(strict=True)) == identity:
                    reports.append(item['sha256'])
            require(len(set(reports)) == 1, 'accepted scout needs its assessed final report')
            delivery = {'report_ref': identity, 'report_sha256': reports[0],
                        'captain_calls': dependency.captain_call_completion(record)}
        elif record['disposition'] == 'accepted' and task_kind == 'ship':
            delivery = {'merge': [proof for proof in record.get('owner_receipts', {}).get('merge', [])
                if proof['execution_generation'] == record['execution_generation'] and
                text(proof['facts'].get('head')) and text(proof['facts'].get('url'))]}
        return digest(json.dumps([record['task_id'], record['goal_revision'],
            record['execution_generation'], record['brief_sha256'], record['disposition'],
            task_kind, delivery], sort_keys=True).encode())

    def check_release(self, continuation):
        require(self.release_observation(continuation) == continuation['release_sha256'],
                'dependency release evidence changed')

    def release_observation(self, continuation):
        if continuation.get('release_projection') == 'delivery-v1':
            return self.release_digest(continuation['release_ref'], continuation.get('release_task_kind'))
        return digest(self.reference(continuation['release_ref']))

    def validate(self, record, current=True):
        require(isinstance(record, dict), 'record must be an object')
        require(record.get('schema') in (SCHEMA, DELEGATED_SCHEMA) and record.get('task_id') == self.id, 'record identity/schema mismatch')
        require(integer(record.get('revision'), 1) and integer(record.get('goal_revision'), 1), 'invalid revision')
        require(record.get('disposition') in ('open', 'accepted', 'archived'), 'invalid disposition')
        require(atom(record.get('execution_generation')), 'missing bound execution generation')
        require(integer(record.get('next_action_seq'), 1), 'invalid action sequence')
        for key in ('decision_ref', 'cleanup_ref'):
            require(record.get(key) is None or text(record[key], 4096), 'invalid ' + key)
        require(record.get('cleanup_observation_key') is None or
                bool(re.fullmatch('[a-f0-9]{64}', str(record['cleanup_observation_key']))),
                'invalid cleanup observation binding')
        completion = record.get('captain_call_completion')
        require(completion is None or isinstance(completion, dict) and
                set(completion) == {'decisions_reviewed', 'decision_keys', 'verified'} and
                completion['decisions_reviewed'] is True and completion['verified'] is True and
                isinstance(completion['decision_keys'], list) and
                all(atom(key) for key in completion['decision_keys']) and
                completion['decision_keys'] == sorted(set(completion['decision_keys'])),
                'invalid retained captain-call completion')
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
        updates = record.get('intent_updates', {})
        require(isinstance(updates, dict) and len(updates) <= 128, 'invalid intent receipt history')
        for key, update in updates.items():
            require(re.fullmatch('[a-f0-9]{64}', key) and isinstance(update, dict) and
                    update.get('phase') in ('prepared', 'confirmed') and isinstance(update.get('proof'), dict), 'invalid intent transaction')
            require(all(re.fullmatch('[a-f0-9]{64}', str(update.get(k))) for k in ('before', 'after')), 'invalid intent byte binding')
            if update['phase'] == 'prepared':
                require(text(update.get('content'), MAX_BYTES) and digest(update['content'].encode()) == update['after'], 'invalid prepared intent bytes')
        receipts = record.get('owner_receipts', {})
        require(isinstance(receipts, dict) and set(receipts) <= {'merge', 'cleanup'}, 'invalid owner receipts')
        for history in receipts.values():
            require(isinstance(history, list) and 1 <= len(history) <= 128, 'invalid effect receipt history')
            for proof in history:
                require(isinstance(proof, dict) and atom(proof.get('execution_generation')) and
                        isinstance(proof.get('facts'), dict) and proof.get('sha256') == digest(json.dumps(proof['facts'], sort_keys=True).encode()),
                        'invalid effect fact binding')
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
                    require(continuation.get('release_projection') in (None, 'delivery-v1'), 'unsupported release projection')
                    require(continuation.get('release_task_kind') is None or
                            continuation.get('release_projection') == 'delivery-v1' and
                            continuation['release_task_kind'] in ('ship', 'scout'), 'invalid release task kind')
                else:
                    raise Refusal('unsupported continuation type')
        if action and record['disposition'] == 'accepted':
            require(action['phase'] in ('confirmed', 'refused') or
                    (action['kind'] == 'wait' and action['phase'] == 'prepared' and action['attempts'] == 0 and
                     action.get('continuation', {}).get('type') == 'blocker'),
                    'unreconciled action prevents terminal acceptance')
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
            self.input_barrier(os.environ.get('FM_BRANCH_MAIN_SESSION_FILE', ''))
        return grant

    def input_barrier(self, session_file):
        # Read original input receipts again at effect time. An environment
        # snapshot alone misses input arriving during a long bash command.
        path = Path(session_file)
        require(path.is_absolute(), 'branch effects require the original MAIN input receipt session')
        entries = native_session(path, self.state / 'task-session-index')
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
        require(not any(v.get('task') == self.id and v.get('pending') for v in inputs.values()), 'pending task intent update prevents new effects')

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
                self.check_release(continuation)
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
        if os.environ.get('FM_SUPERVISION_ACTOR', 'main') == 'branch':
            self.delegated(record, 'observe-receipt')
        action = record.get('next_action')
        require(action and action['phase'] in ('attempted', 'uncertain'), 'no uncertain action to read back')
        if action['kind'] == 'steer':
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
        require(action['payload_sha256'] == args.payload_sha256, 'effect body differs from prepared action')
        self.reference(action['payload_ref'], action['payload_sha256'])
        if action['phase'] == 'confirmed':
            return record
        if action['phase'] in ('attempted', 'uncertain'):
            record = self.readback(args)
            action = record['next_action']
            args.phase = 'confirmed'
            args.receipt_ref = action.get('receipt_ref')
            return self.action(args)
        require(action['phase'] == 'prepared', 'effect cannot execute')
        if os.environ.get('FM_SUPERVISION_ACTOR', 'main') == 'branch':
            self.delegated(record, 'steer-same-intent', effect=True)
        args.phase = 'attempted'
        return self.action(args)

    def read(self, current=True):
        if not self.path.exists() and not self.path.is_symlink():
            return None
        record = self.validate(load(self.path), current)
        if current:
            require(not any(u['phase'] == 'prepared' for u in record.get('intent_updates', {}).values()),
                    'intent update pending; retry the same authenticated route before further effects')
        return record

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

    def inspect(self, refs=()):
        """Opaque compare-and-swap basis includes bytes, not just a revision.

        Callers inspect the evidence they will judge, then return this token.
        Reading does not enroll, fix stale identity, or consume any receipt.
        """
        record = self.read(current=False)
        evidence = [{'ref': ref, 'sha256': digest(self.reference(ref))} for ref in sorted(set(refs))]
        brief_sha, generation = digest(regular(self.directory / 'brief.md')), self.generation()
        snapshot = [record, brief_sha, generation, evidence]
        return {**self.summary(record), 'basis': digest(json.dumps(snapshot, sort_keys=True).encode()),
                'evidence': evidence, 'brief_changed': bool(record and record['brief_sha256'] != brief_sha),
                'current_execution_generation': generation,
                'pending_intent_updates': [u['proof'].get('input') for u in (record or {}).get('intent_updates', {}).values()
                                           if u['phase'] == 'prepared']}

    def summary(self, record):
        if record is None:
            return {'task_id': self.id, 'enrolled': False}
        result = {key: record.get(key) for key in ('schema', 'task_id', 'revision', 'goal_revision', 'execution_generation',
                'disposition', 'assessment', 'next_action', 'decision_ref', 'cleanup_ref', 'delegation', 'precheck')}
        result['intent_updates'] = {key: {'phase': update['phase'], 'proof': update['proof']}
            for key, update in record.get('intent_updates', {}).items()}
        result['owner_receipts'] = {kind: history[-1] for kind, history in record.get('owner_receipts', {}).items()}
        return result

    def assess(self, args):
        require(os.environ.get('FM_SUPERVISION_ACTOR', 'main') == 'main', 'assessment belongs to MAIN')
        judgment = json.loads(args.judgment, object_pairs_hook=unique_object)
        require(isinstance(judgment, dict) and set(judgment) <= {
            'disposition', 'outcome', 'remaining_gap', 'authority_ref', 'evidence', 'next_action',
            'intent_changed', 'revoke_delegation', 'supersede_prepared'}, 'unsupported semantic input')
        require(all(type(judgment[key]) is bool for key in ('intent_changed', 'revoke_delegation', 'supersede_prepared') if key in judgment),
                'semantic intent/delegation choices must be booleans')
        refs = judgment.get('evidence')
        require(isinstance(refs, list) and refs and all(text(ref, 4096) for ref in refs), 'evidence references required')
        authority = judgment.get('authority_ref')
        require(text(authority, 4096), 'explicit judgment authority required')
        bound = list(refs) + [authority]
        action = judgment.get('next_action')
        if action:
            require(isinstance(action, dict) and set(action) <= {
                'kind', 'payload_ref', 'recheck_at', 'deadline', 'attempt_limit', 'blocker'}, 'unsupported next action input')
            bound.append(action['payload_ref'])
            if action.get('blocker'):
                bound.append(action['blocker']['release_ref'])
        require(args.basis == self.inspect(bound)['basis'], 'assessment basis changed; inspect current judgment/evidence again')
        prior = self.read(current=False)
        require(prior is not None, 'enroll the task before assessment')
        candidate = copy.deepcopy(prior)
        changed = prior['brief_sha256'] != digest(regular(self.directory / 'brief.md'))
        generation = self.generation() or prior['execution_generation']
        identity_changed = generation != prior['execution_generation']
        require(not changed and not identity_changed or judgment.get('intent_changed') is True,
                'changed brief/execution requires explicit intent_changed judgment')
        require(not judgment.get('intent_changed') or changed or identity_changed or prior['disposition'] != 'open',
                'unchanged intent cannot reset goal or effect budgets')
        if judgment.get('intent_changed'):
            require(authority != prior['assessment']['authority_ref'], 'changed intent requires new explicit authority')
            candidate['goal_revision'] += 1
            candidate['brief_sha256'] = digest(regular(self.directory / 'brief.md'))
            candidate['execution_generation'] = generation
        if judgment.get('revoke_delegation'):
            grant = candidate.get('delegation')
            require(grant is not None, 'no delegation to revoke')
            if not grant['revoked']:
                grant['revoked'] = True
                grant['revision'] += 1
                candidate['precheck'] = None
        candidate['disposition'] = judgment['disposition']
        candidate['assessment'] = {'outcome': judgment['outcome'], 'remaining_gap': judgment['remaining_gap'],
            'authority_ref': authority, 'assessed_at': now(),
            'evidence_key': prior['assessment'].get('evidence_key'),
            'evidence': [{'ref': ref, 'sha256': digest(self.reference(ref))} for ref in refs]}
        if 'next_action' in judgment:
            if action is None:
                candidate['next_action'] = None
            else:
                candidate['next_action'] = {
                    'id': f'{self.id}.g{candidate["goal_revision"]}.a{prior["next_action_seq"]}',
                    'kind': action['kind'], 'phase': 'prepared', 'attempts': 0,
                    'attempt_limit': action.get('attempt_limit', 1),
                    'expected_execution_generation': generation,
                    'payload_ref': action['payload_ref'], 'payload_sha256': digest(self.reference(action['payload_ref'])),
                    'recheck_at': action['recheck_at'], 'deadline': action['deadline'], 'receipt_ref': None}
                if action.get('blocker'):
                    blocker = action['blocker']
                    require(set(blocker) == {'owner', 'dependency', 'release_ref'}, 'unsupported blocker input')
                    release_kind = None
                    if (candidate['disposition'] in ('accepted', 'archived') and
                            Path(blocker['release_ref']).name == 'lifecycle.json'):
                        dependency = Task(Path(blocker['release_ref']).parent.name)
                        dependency_record = dependency.read()
                        if dependency_record and dependency_record['disposition'] in ('accepted', 'archived'):
                            release_kind = dependency.task_kind()
                    projected = release_kind is not None
                    candidate['next_action']['continuation'] = dict(blocker, type='blocker',
                        release_sha256=(self.release_digest(blocker['release_ref'], release_kind) if projected else
                                        digest(self.reference(blocker['release_ref']))), recovery_trigger='evidence-change')
                    if projected:
                        candidate['next_action']['continuation']['release_projection'] = 'delivery-v1'
                        candidate['next_action']['continuation']['release_task_kind'] = release_kind
                candidate['next_action_seq'] += 1
        args.supersede_prepared = judgment.get('supersede_prepared', False)
        if args.supersede_prepared:
            old = prior.get('next_action')
            require(old and old['phase'] == 'prepared' and old['attempts'] == 0 and
                    old['kind'] in ('wait', 'readback', 'decision'), 'only an unattempted observation can be superseded')
            require('next_action' in judgment and authority != prior['assessment']['authority_ref'] and
                    old['payload_ref'] in refs, 'superseding needs new authority and the exact old payload in readback')
        # Recheck immediately before the existing invariant/CAS owner commits.
        require(args.basis == self.inspect(bound)['basis'], 'assessment evidence changed during readback')
        args.expected_revision = prior['revision']
        return self.summary(self.reconcile(args, candidate))

    def native_input(self, args):
        """Only an original, explicitly routed native input can append intent.

        The session is the authority store. The lifecycle retains a transaction
        receipt, never a second copy of the conversation or an authority grant.
        """
        require(os.environ.get('FM_SUPERVISION_ACTOR', 'main') == 'main', 'intent updates belong to MAIN')
        pid = regular(self.state / '.lock').decode().strip()
        require(pid.isdigit() and int(pid) > 1, 'missing native owner')
        parent = os.getpid()
        for _ in range(32):
            if str(parent) == pid:
                break
            result = subprocess.run(['ps', '-o', 'ppid=', '-p', str(parent)], capture_output=True, text=True, check=False)
            require(result.returncode == 0 and result.stdout.strip().isdigit(), 'cannot verify native input owner')
            parent = int(result.stdout.strip())
            require(parent > 1, 'input caller is outside owning session')
        require(str(parent) == pid, 'input owner ancestry exceeded')
        path = Path(args.session_file)
        entries = native_session(path, self.state / 'task-session-index', args.entry_id, args.input)
        by_id = {e['id']: e for e in entries[1:] if 'id' in e}
        chain, seen = [], set()
        route = by_id.get(args.entry_id)
        require(route is not None, 'unread native route receipt')
        entry = entries[-1] if len(entries) > 1 else None
        while entry is not None:
            require(entry['id'] not in seen, 'invalid session ancestry')
            seen.add(entry['id']); chain.append(entry)
            if entry.get('parentId') is None:
                break
            entry = by_id.get(entry['parentId'])
            require(entry is not None, 'incomplete session ancestry')
        require(args.entry_id in seen, 'route receipt is outside the current session branch')
        require(route.get('customType') == 'fm-continuation-input' and route.get('data', {}).get('task') == self.id and
                route.get('data', {}).get('update_brief') is True and route.get('data', {}).get('id') == args.input,
                'not an explicit intent route receipt')
        value = route['data']
        proof = {'session_file': str(path), 'entry_id': args.entry_id, 'input': args.input,
                 'sha256': digest(json.dumps(route, sort_keys=True).encode())}
        source_id = value.get('source_entry_id')
        if source_id:
            require(source_id in seen, 'original message is outside the current session branch')
            source = by_id[source_id]
            require(source_id == args.input, 'original message identity changed')
            content = source.get('message', {}).get('content') if source.get('type') == 'message' else source.get('content')
            original = content if isinstance(content, str) else ''.join(p.get('text', '') for p in content
                if isinstance(p, dict) and p.get('type') == 'text') if isinstance(content, list) else ''
            require(text(original) and value.get('text') == original, 'intent words differ from original message')
            proof['source_sha256'] = digest(json.dumps(source, sort_keys=True).encode())
            retained = self.read(current=False)
            prior = (retained or {}).get('intent_updates', {}).get(digest((str(path) + '\0' + args.input).encode()))
            # A prepared transaction has already authenticated these exact bytes.
            # Rechecking a consumed delivery would strand a safe interrupted append.
            authenticated = prior and prior.get('proof') == proof
            if not authenticated:
                if source.get('type') == 'message':
                    require(source.get('message', {}).get('role') == 'user', 'source is not an original user message')
                else:
                    script = Path(__file__).resolve().with_name('fm-feishu-state.mjs').as_uri()
                    check = subprocess.run(['node', '--input-type=module', '-e',
                        'import {verifyFeishuSessionMessage as verify} from ' + json.dumps(script) +
                        '; let raw=""; for await (const part of process.stdin) raw+=part; ' +
                        'process.stdout.write(verify(process.argv[1],JSON.parse(raw))?"verified":"refused");', str(self.home)],
                        input=json.dumps(source), capture_output=True, text=True, check=False, timeout=10)
                    require(check.returncode == 0 and check.stdout == 'verified', 'missing immutable Feishu delivery proof')
                operational = subprocess.run([str(Path(__file__).resolve().with_name('fm-operational-input.sh')), 'classify'],
                    input=original, capture_output=True, text=True, check=False, timeout=10)
                require(operational.returncode == 1 and not operational.stdout.strip(), 'operational input is not task intent')
        else:
            # Older task-assigned transactions retain their original capture and
            # route proofs. Unassigned historical chat is never newly supervised.
            values = [e.get('data', {}) for e in reversed(chain) if e.get('type') == 'custom' and
                      e.get('customType') == 'fm-continuation-input' and e.get('data', {}).get('id') == args.input]
            require(len(values) >= 2 and text(values[0].get('text')) and not values[0].get('task') and
                    not values[0].get('answer'), 'missing original authenticated input')
            require(all(v.get('text') == value['text'] and v.get('task', self.id) == self.id and not v.get('answer') for v in values),
                    'input authority was rerouted or answered')
        return value, proof

    def update_brief(self, args):
        value, proof = self.native_input(args)
        record = self.read(current=False)
        require(record is not None and record['disposition'] == 'open', 'intent update requires an enrolled open goal')
        require((self.generation() or 'unassigned-g1') == record['execution_generation'], 'stale execution generation')
        updates = record.get('intent_updates', {})
        key = digest((proof['session_file'] + '\0' + args.input).encode())
        prior = updates.get(key)
        brief = self.directory / 'brief.md'
        raw = regular(brief)
        if prior and prior.get('phase') == 'confirmed':
            require(prior['proof'] == proof, 'input receipt identity changed')
            self.validate(record)
            return self.summary(record)
        if prior:
            require(prior['proof'] == proof and prior['phase'] == 'prepared', 'intent transaction collision')
            require(digest(raw) in (prior['before'], prior['after']), 'uncertain brief update; exact readback required')
        else:
            self.validate(record)
            grant = record.get('delegation')
            require(not grant or grant['revoked'], 'revoke delegation before changing intent')
            action = record.get('next_action')
            require(not action or action['phase'] in ('confirmed', 'refused'), 'outstanding action requires readback before intent update')
            require(len(updates) < 128, 'intent receipt history full; explicit reconciliation required')
            # The scope is exact append-only user words in the owned subsection.
            body = raw.decode()
            heading = "## Captain's intent\n"
            require(body.count(heading) == 1, 'brief needs one canonical Captain intent subsection')
            start = body.index(heading) + len(heading)
            end = re.search(r'^#{1,2} ', body[start:], flags=re.M)
            position = start + end.start() if end else len(body)
            body = body[:position].rstrip('\n') + '\n\n' + value['text'] + '\n\n' + body[position:]
            # Newer briefs carry an additional pipeline-only intent subsection.
            pipeline = '## Captain intent authorized for --intent\n'
            if pipeline in body:
                require(body.count(pipeline) == 1, 'ambiguous pipeline intent subsection')
                body = body.rstrip('\n') + '\n\n' + value['text'] + '\n'
            after = body.encode()
            require(len(after) <= MAX_BYTES, 'updated brief too large')
            prior = {'phase': 'prepared', 'proof': proof, 'before': digest(raw), 'after': digest(after),
                     'content': body}
            updates[key] = prior
            record['intent_updates'] = updates
            record['revision'] += 1
            self.write(record)
        if digest(raw) == prior['before']:
            # Recheck before replacement. Cooperating writers share the meta lock.
            require(digest(regular(brief)) == prior['before'], 'brief changed during intent append')
            fd, name = tempfile.mkstemp(prefix='.brief.', dir=self.directory)
            try:
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(prior['content'].encode()); stream.flush(); os.fsync(stream.fileno())
                os.replace(name, brief)
            finally:
                if os.path.exists(name):
                    os.unlink(name)
        require(digest(regular(brief)) == prior['after'], 'brief replacement uncertain; retry the same input receipt')
        record['brief_sha256'] = prior['after']
        record['goal_revision'] += 1
        record['revision'] += 1
        record['precheck'] = None
        # Retain the previous gap AND this obligation until MAIN assesses it.
        record['assessment']['remaining_gap'] += '\nUnassessed routed input: ' + args.input
        record['assessment']['evidence'].append({'ref': str(brief), 'sha256': prior['after']})
        record['assessment']['evidence'] = [e for e in record['assessment']['evidence']
            if e['ref'] != str(brief) or e['sha256'] == prior['after']]
        prior['phase'] = 'confirmed'
        del prior['content']
        self.write(record)
        return self.summary(record)

    def refresh(self, args):
        record = self.read()
        if record is None:
            return self.summary(record)
        action = record.get('next_action')
        if action and action['phase'] in ('attempted', 'uncertain'):
            if not action.get('continuation') and action['kind'] == 'steer':
                self.readback(args)
                record = self.read()
                action = record['next_action']
            continuation = action.get('continuation', {})
            if continuation.get('type') == 'executor' and self.observe_executor(continuation)[0] == 'running':
                # This observed effect confirms execution receipt, never the goal.
                target = continuation['task_id']
                if 'inbox_id' in continuation:
                    receipt = self.state / (target + '.inbox') / 'handled' / (continuation['inbox_id'] + '.msg')
                    raw = self.reference(str(receipt), continuation['sha256'])
                elif 'handoff_id' in continuation:
                    receipt = self.state / 'task-handoffs' / 'records' / (continuation['handoff_id'] + '.msg')
                    raw = self.reference(str(receipt))
                    require(digest(raw.partition(b'--\n')[2]) == action['payload_sha256'], 'handoff receipt payload changed')
                else:
                    receipt = self.data / target / 'brief.md'
                    raw = self.reference(str(receipt), continuation['brief_sha256'])
                action['receipt_ref'], action['receipt_sha256'] = str(receipt), digest(raw)
                action['phase'] = 'confirmed'
                record['revision'] += 1
                self.write(record)
        return self.summary(record)

    def owner_receipt(self, args):
        require(args.kind in ('merge', 'cleanup'), 'unknown effect receipt owner')
        record = self.read()
        if record is None:
            return {'task_id': self.id, 'enrolled': False}
        require(args.execution_generation == record['execution_generation'], 'stale owner receipt execution')
        facts = json.loads(args.facts, object_pairs_hook=unique_object)
        require(isinstance(facts, dict), 'invalid owner facts')
        if args.kind == 'merge':
            require(set(facts) == {'url', 'head'} and text(facts['url']) and isinstance(facts['head'], str), 'invalid merge receipt')
        else:
            require(complete_cleanup_facts(facts), 'incomplete cleanup receipt')
            require(not (self.state / (self.id + '.meta')).exists(), 'cleanup task record still exists')
        proof = {'execution_generation': args.execution_generation, 'facts': facts,
                 'sha256': digest(json.dumps(facts, sort_keys=True).encode())}
        receipts = record.setdefault('owner_receipts', {})
        history = receipts.setdefault(args.kind, [])
        same = [p for p in history if p['execution_generation'] == args.execution_generation and
                p['facts'].get('url') == facts.get('url')]
        require(not same or same == [proof], 'owner receipt collision; reconcile exact effect')
        if not same:
            require(len(history) < 128, 'owner receipt history full; retain effect for explicit readback')
            history.append(proof)
            record['revision'] += 1
            self.write(record)
        return self.summary(record)

    def reconcile(self, args, candidate=None):
        prior = self.read(current=False)
        require(args.expected_revision == (prior['revision'] if prior else 0), 'revision conflict')
        require(not any(u['phase'] == 'prepared' for u in (prior or {}).get('intent_updates', {}).values()),
                'intent update pending; retry the same authenticated route')
        candidate = load(Path(args.record)) if candidate is None else candidate
        candidate['revision'] = args.expected_revision + 1
        if prior and 'coordination' in prior:
            require(candidate.get('coordination', prior['coordination']) == prior['coordination'], 'coordination belongs to the native readback owner')
            candidate['coordination'] = prior['coordination']
        else:
            require('coordination' not in candidate, 'coordination requires an actual native readback receipt')
        require(candidate.get('owner_receipts') == (prior or {}).get('owner_receipts'), 'effect facts belong to their receipt owners')
        require(candidate.get('cleanup_observation_key') == (prior or {}).get('cleanup_observation_key'),
                'cleanup observation belongs to its receipt owner')
        require(candidate.get('intent_updates') == (prior or {}).get('intent_updates'), 'intent receipts belong to the brief update owner')
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
                    require(grant and grant['revoked'] and all(
                        grant.get(k) == old_grant.get(k) for k in old_grant if k not in ('revision', 'revoked')),
                        'revoke the existing delegation before issuing a replacement')
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
                self.check_release(continuation)
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
                require(action == old_action or getattr(args, 'supersede_prepared', False) and
                        old_action['phase'] == 'prepared' and old_action['attempts'] == 0 and
                        old_action['kind'] in ('wait', 'readback', 'decision'),
                        'outstanding action must be confirmed/refused before replacement')
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
            require(args.receipt_ref, 'phase change requires a bound owner receipt')
            args.receipt_sha256 = args.receipt_sha256 or digest(self.reference(args.receipt_ref))
            self.reference(args.receipt_ref, args.receipt_sha256)
            action['receipt_ref'] = args.receipt_ref
            action['receipt_sha256'] = args.receipt_sha256
        if os.environ.get('FM_SUPERVISION_ACTOR', 'main') == 'branch' and args.phase == 'confirmed':
            require(action.get('continuation', {}).get('type') == 'executor', 'branch confirmation requires actual executor receipt')
        if args.phase == 'confirmed' and action.get('continuation', {}).get('type') == 'executor':
            continuation = action['continuation']
            if continuation.get('inbox_id'):
                receipt = Path(action['receipt_ref'])
                if receipt.parent == self.state / (self.id + '.inbox') / 'handled':
                    self.reference(str(receipt), action['receipt_sha256'])
                else:
                    require(self.observe_executor(continuation)[0] == 'running', 'executor has not acknowledged its exact instruction')
            else:
                require(self.observe_executor(continuation)[0] == 'running', 'executor has not acknowledged its exact instruction')
        action['phase'] = args.phase
        record['revision'] += 1
        self.write(record)
        return record

    def observe_executor(self, continuation, published_launch=False):
        target = continuation['task_id']
        fields = {}
        meta = self.state / (target + '.meta')
        if published_launch and not meta.exists() and not meta.is_symlink():
            return 'pending', 'ordinary launch has no publication receipt'
        for line in regular(meta).decode().splitlines():
            key, sep, value = line.partition('=')
            if sep:
                require(key not in fields, 'duplicate executor metadata')
                fields[key] = value
        if published_launch and (fields.get('executor', 'local-agent') != 'local-agent' or
                                 fields.get('kind') == 'secondmate' or fields.get('launch_state') != 'confirmed'):
            return 'pending', 'ordinary local launch has no confirmed publication receipt'
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
            if not action and record['execution_generation'] != 'unassigned-g1':
                # Ordinary dispatch binds the exact brief and generation without
                # preparing a lifecycle action. Read the same structural start
                # proof as an explicit spawn, without inventing an effect/action.
                state, reason = self.observe_executor(dict(type='executor', task_id=self.id,
                    execution_generation=record['execution_generation'], brief_sha256=record['brief_sha256']),
                    published_launch=True)
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
                    observation = self.release_observation(continuation)
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


    def authorize(self, args):
        record = self.read()
        require(record and record['disposition'] == 'open', 'execution requires an open goal')
        action = record.get('next_action')
        require(action and action['id'] == args.action_id and action['kind'] == args.kind,
                'action identity/kind conflict')
        require(action['expected_execution_generation'] == args.expected_generation,
                'execution generation conflict')
        require(action['phase'] in ('prepared', 'attempted', 'confirmed'), 'action cannot execute')
        require(action['phase'] == 'confirmed' or stamp(action['deadline']) >= stamp(now()), 'action deadline expired; read back existing effects without executing')
        payload = self.reference(action['payload_ref'], action['payload_sha256'])
        require(sys.stdin.buffer.read(MAX_BYTES + 1) == payload, 'action payload collision')
        if action['phase'] == 'prepared':
            args.phase = 'attempted'
            return self.action(args)
        return record

    def completion_read(self):
        """Business completion proof for retained-resource backlog closure only."""
        record = self.read()
        require(record and record['disposition'] in ('accepted', 'archived'), 'goal is not terminal')
        if record['disposition'] == 'archived':
            return record
        self.reference(record['assessment']['authority_ref'])
        for item in record['assessment']['evidence']:
            if record.get('cleanup_ref') == item['ref'] and record.get('cleanup_observation_key'):
                require(cleanup_observation_matches(self.cleanup_read(), record['cleanup_observation_key']),
                        'cleanup facts changed')
                continue
            self.reference(item['ref'], item['sha256'])
        meta = dict(line.split('=', 1) for line in
                    regular(self.state / (self.id + '.meta')).decode().splitlines() if '=' in line)
        kind = self.task_kind()
        report = self.directory / 'report.md'
        if kind == 'scout':
            sha = digest(regular(report))
            require(any(self.authority_identity(item['ref']) == (str(report.resolve()), sha)
                        and item['sha256'] == sha for item in record['assessment']['evidence']),
                    'accepted scout needs its assessed final report')
            completion = self.captain_call_completion(record)
            require(completion is not None, 'scout captain-call completion gate is not verified')
            if record.get('captain_call_completion') != completion:
                record['captain_call_completion'] = completion
                record['revision'] += 1
                self.write(record)
        else:
            proofs = [p for p in record.get('owner_receipts', {}).get('merge', [])
                      if p['execution_generation'] == record['execution_generation']]
            require(len(proofs) == 1 and text(proofs[0]['facts'].get('head')) and
                    text(proofs[0]['facts'].get('url')), 'required delivery has no confirmed merge receipt')
            require(not meta.get('pr') or meta['pr'] == proofs[0]['facts']['url'], 'delivery URL conflicts with merge receipt')
        return record

    def due(self, record):
        action = record.get('next_action') if record else None
        terminal = bool(record and record['disposition'] in ('accepted', 'archived'))
        complete = bool(terminal and self.cleanup_complete(record))
        cleanup = bool(terminal and not complete and
                       ((self.state / (self.id + '.meta')).exists() or record.get('cleanup_ref') or
                        (self.state / (self.id + '.cleanup.json')).exists()))
        release = None
        if cleanup and action and action['kind'] == 'wait' and action['phase'] == 'prepared':
            continuation = action.get('continuation', {})
            if continuation.get('type') == 'blocker':
                try:
                    release = self.release_observation(continuation)
                    if stamp(now()) < min(stamp(action['recheck_at']), stamp(action['deadline'])):
                        cleanup = release != continuation['release_sha256']
                except (Refusal, OSError, ValueError):
                    release = 'unreadable'
        open_goal = bool(record and record['disposition'] == 'open')
        due = bool((open_goal and (not action or stamp(action['recheck_at']) <= stamp(now()))) or cleanup)
        expired = bool((open_goal or cleanup) and action and stamp(action['deadline']) <= stamp(now()))
        observations = []
        for path in (self.directory / 'report.md', self.state / (self.id + '.cleanup.json')):
            if path.exists() or path.is_symlink():
                try:
                    observed = digest(regular(path))
                    # Receipt presentation/formatting is not a new resource fact.
                    if terminal and (not complete or record.get('cleanup_observation_key')) and path.name.endswith('.cleanup.json'):
                        try:
                            receipt = self.cleanup_read()
                        except Refusal:
                            # Historical minimal receipts may lack resource
                            # identity; an independent complete owner proof
                            # retains their previous byte-bound readback.
                            if not complete:
                                raise
                            receipt = None
                        if receipt is not None:
                            observation = cleanup_observation(receipt)
                            observations.append(observation)
                            if cleanup_observation_matches(receipt, record.get('cleanup_observation_key')):
                                continue
                        else:
                            observations.append(observed)
                    else:
                        observations.append(observed)
                    if record and not any(item['sha256'] == observed and
                            (self.home / item['ref']).resolve() == path.resolve()
                            for item in record['assessment']['evidence']):
                        due = True
                except (Refusal, OSError, ValueError):
                    observations.append('unreadable')
                    due = True
            elif record and any((self.home / item['ref']).resolve() == path.resolve()
                                for item in record['assessment']['evidence']):
                observations.append('missing:' + path.name)
                due = True
        key = digest(json.dumps(observations, sort_keys=True).encode())
        result = {'due': due, 'expired': expired, 'observed_evidence_key': key, 'record': record}
        if terminal:
            # No revision, assessment prose, coordination, or presentation clock.
            # The first reached bound remains the same observation after restart.
            wait = None
            if action and action['kind'] == 'wait':
                bound = min(action['recheck_at'], action['deadline'])
                wait = [bound, stamp(now()) >= stamp(bound), release]
            effect = action if action and action['kind'] == 'cleanup' else None
            result['reconciliation_key'] = digest(json.dumps([record['goal_revision'],
                record['execution_generation'], record['disposition'], key, wait, effect], sort_keys=True).encode())
        return result

    def link_cleanup(self):
        record = self.read()
        require(record and record['disposition'] in ('accepted', 'archived'), 'cleanup needs terminal disposition')
        receipt = self.state / (self.id + '.cleanup.json')
        regular(receipt, True)
        evidence = {'ref': str(receipt), 'sha256': digest(regular(receipt, True))}
        observation_key = digest(json.dumps(cleanup_observation(load(receipt)), sort_keys=True).encode())
        if record.get('cleanup_ref') == str(receipt) and record.get('cleanup_observation_key') == observation_key:
            return record
        record['cleanup_ref'] = str(receipt)
        record['cleanup_observation_key'] = observation_key
        record['assessment']['evidence'] = [item for item in record['assessment']['evidence'] if item['ref'] != str(receipt)] + [evidence]
        record['revision'] += 1
        self.write(record)
        return record

    def cleanup_complete(self, record):
        """Read current owner facts or the historical ShortTask effect chain.

        This projects existing evidence only. It never imports receipts, changes
        disposition, calls a tool, or authorizes repeating a cleanup effect.
        """
        meta = self.state / (self.id + '.meta')
        if meta.exists() or meta.is_symlink():
            return False
        receipt_path = self.state / (self.id + '.cleanup.json')
        if receipt_path.exists() or receipt_path.is_symlink():
            try:
                receipt = load(receipt_path)
                if receipt.get('copy_binding'):
                    receipt = self.cleanup_read()
                    if receipt['phases'].get('directory_return', {}).get('state') != 'confirmed':
                        if receipt['phases'].get('directory_return') not in (dict(state='retained', reason_code='copy-preserved-after-uncertain-return'),
                                dict(state='retained', reason_code='copy-preserved-current-recovery')):
                            return False
                        proof = self.cleanup_preservation_read(receipt)
                        if proof.get('schema') == 'fm-cleanup-current-retention.v1' and (
                                receipt['phases'].get('pane_close', {}).get('state') != 'confirmed' or
                                receipt['phases'].get('record_close', {}).get('state') != 'confirmed'):
                            return False
            except (Refusal, OSError, ValueError, TypeError, KeyError, AttributeError):
                return False
        if any(proof['execution_generation'] == record['execution_generation'] and
               complete_cleanup_facts(proof['facts'])
               for proof in record.get('owner_receipts', {}).get('cleanup', [])):
            return True
        ref = record.get('cleanup_ref')
        if not ref:
            return False
        refs = [ref] + [item.get('ref') for item in record['assessment']['evidence']]
        completed = set()
        for ref in refs:
            try:
                path = Path(ref)
                if not path.is_absolute():
                    path = self.home / path
                root = self.state / 'short-agents'
                require(path.name == 'result.json' and path.parent.parent == root and
                        re.fullmatch(r'short-[a-f0-9]{64}', path.parent.name), 'not a ShortTask result')
                require(path.resolve(strict=True) == path, 'unsafe ShortTask result path')
                evidence = [item for item in record['assessment']['evidence']
                            if (self.home / item['ref']).resolve() == path]
                require(len(evidence) == 1, 'unbound historical cleanup result')
                self.reference(str(path), evidence[0]['sha256'])
                result = load(path)
                request = load(path.parent / 'request.json')
                require(result.get('id') == request.get('id') == path.parent.name and
                        result.get('state') == 'completed' and result.get('evidence') == str(path.parent),
                        'historical cleanup result identity conflict')
                require(atom(request.get('nonce')), 'missing ShortTask nonce')
                require(text(request['input'].get('key')) and
                        request['id'] == 'short-' + digest(request['input']['key'].encode()), 'ShortTask key conflict')
                steps = request['input']['operations']['steps']
                bindings = request['operationBindings']
                require(isinstance(steps, list) and isinstance(bindings, list) and
                        len(steps) == len(bindings), 'invalid historical operation chain')
                indices = [i for i, step in enumerate(steps) if isinstance(step, dict) and
                           step.get('action') == 'cleanup' and step.get('task') == self.id]
                require(len(indices) == 1, 'ambiguous cleanup step')
                index = indices[0]
                binding = bindings[index]
                require(binding.get('spawn_gen') == record['execution_generation'] and
                        binding.get('endpoint_task_id', self.id) == self.id, 'cleanup generation conflict')
                receipt = load(path.parent / f'operation-{index}.receipt.json')
                require(receipt.get('id') == request['id'] and receipt.get('nonce') == request['nonce'] and
                        type(receipt.get('index')) is int and receipt['index'] == index and
                        receipt.get('action') == 'cleanup' and receipt.get('state') == 'completed',
                        'historical cleanup effect identity conflict')
                if complete_cleanup_facts(receipt.get('evidence')):
                    completed.add(path)
            except (Refusal, OSError, ValueError, TypeError, KeyError, AttributeError):
                # Missing/conflicting evidence retains the existing readback duty;
                # no shape mismatch is permission to replay an uncertain operation.
                continue
        return len(completed) == 1

    def cleanup_read(self):
        record = self.read()
        require(record and record['disposition'] in ('accepted', 'archived'), 'cleanup needs terminal disposition')
        result = load(self.state / (self.id + '.cleanup.json'))
        require(result.get('schema') == 'fm-task-cleanup.v1' and result.get('task_id') == self.id and
                result.get('spawn_gen') == record['execution_generation'] and
                result.get('goal_revision') == record['goal_revision'], 'cleanup receipt identity conflict')
        require(isinstance(result.get('phases'), dict), 'invalid cleanup phases')
        return result

    def cleanup_copy_inspect(self):
        """Read current metadata directory/Git identity without publishing a receipt."""
        record = self.read()
        require(record and record['disposition'] in ('accepted', 'archived'), 'copy binding needs terminal task')
        fields = unique_object([line.split('=', 1) for line in regular(self.state / (self.id + '.meta')).decode().splitlines() if '=' in line])
        require(fields.get('spawn_gen') == record['execution_generation'], 'copy execution generation conflict')
        def identity(raw):
            path = Path(raw)
            require(path.is_absolute() and path.is_dir(), 'copy/project needs an existing absolute directory')
            canonical = path.resolve(strict=True)
            st = canonical.stat()
            result = {'path': str(canonical), 'device': st.st_dev, 'inode': st.st_ino}
            git = subprocess.run(['git', '-C', str(canonical), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                capture_output=True, text=True, check=False, timeout=10)
            if git.returncode == 0:
                common = Path(git.stdout.strip()).resolve(strict=True)
                common_stat = common.stat()
                result['git'] = dict(path=str(common), device=common_stat.st_dev, inode=common_stat.st_ino)
            return result
        binding = {'home': str(self.home.resolve()), 'task': self.id, 'spawn_gen': record['execution_generation'],
                   'copy': identity(fields.get('worktree', '')), 'project': identity(fields.get('project', ''))}
        return binding

    def cleanup_copy_bind(self):
        """Capture exact copy identity in the existing cleanup receipt before retirement."""
        record = self.read()
        binding = self.cleanup_copy_inspect()
        receipt_path = self.state / (self.id + '.cleanup.json')
        if receipt_path.exists() or receipt_path.is_symlink():
            receipt = self.cleanup_read()
        else:
            receipt = dict(schema='fm-task-cleanup.v1', task_id=self.id, spawn_gen=record['execution_generation'],
                           goal_revision=record['goal_revision'], phases={})
        require(not receipt.get('copy_binding') or receipt['copy_binding'] == binding, 'copy binding changed')
        if receipt.get('copy_binding') != binding:
            receipt['copy_binding'] = binding
            self.write_cleanup_receipt(receipt_path, receipt)
        return binding

    def write_cleanup_receipt(self, path, receipt):
        raw = (json.dumps(receipt, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()
        require(len(raw) <= MAX_BYTES, 'cleanup receipt too large')
        fd, temporary = tempfile.mkstemp(prefix='.cleanup.', dir=self.state)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(raw); stream.flush(); os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)

    def cleanup_copy_read(self):
        receipt = self.cleanup_read()
        binding = receipt.get('copy_binding')
        require(isinstance(binding, dict) and binding.get('home') == str(self.home.resolve()) and
                binding.get('task') == self.id and binding.get('spawn_gen') == receipt['spawn_gen'],
                'missing exact retained copy binding; recover original owner evidence, never recreate metadata')
        phase = receipt['phases'].get('directory_return', {})
        require(isinstance(phase, dict), 'invalid retained copy phase')
        if phase.get('state') == 'confirmed':
            return dict(binding=binding, phase=phase, absent=False)
        for kind in ('project', 'copy'):
            identity = binding.get(kind, {})
            path = Path(identity.get('path', ''))
            require(path.is_absolute(), 'invalid copy binding path')
            if kind == 'copy' and not path.exists() and not path.is_symlink():
                return dict(binding=binding, phase=phase, absent=True)
            require(path.is_dir() and not path.is_symlink() and str(path.resolve()) == identity['path'], 'copy/project path changed')
            st = path.stat()
            require(st.st_dev == identity.get('device') and st.st_ino == identity.get('inode'), 'copy/project identity changed')
            git_identity = identity.get('git')
            if git_identity:
                git = subprocess.run(['git', '-C', str(path), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                    capture_output=True, text=True, check=False, timeout=10)
                require(git.returncode == 0, 'copy Git owner unreadable')
                common = Path(git.stdout.strip()).resolve(strict=True)
                common_stat = common.stat()
                require(str(common) == git_identity['path'] and common_stat.st_dev == git_identity['device'] and
                        common_stat.st_ino == git_identity['inode'], 'copy Git owner changed')
        return dict(binding=binding, phase=phase, absent=False)

    def cleanup_current_retention_read(self, receipt, proof, ref):
        """A current MAIN judgment preserves historical uncertainty, never no-effect."""
        require(proof.get('schema') == 'fm-cleanup-current-retention.v1' and
                proof.get('home') == str(self.home.resolve()) and proof.get('task') == self.id and
                proof.get('spawn_gen') == receipt['spawn_gen'] and proof.get('goal_revision') == receipt['goal_revision'] and
                proof.get('id') == ref.parent.name and proof.get('originalAttempt') == 'uncertain',
                'current cleanup retention identity conflict')
        index = proof.get('index')
        require(type(index) is int and index >= 0 and ref.name == f'operation-{index}.preservation.json',
                'current cleanup retention index conflict')
        names = {'request.json', 'result.json', f'operation-{index}.intent.json',
                 f'operation-{index}.effect.json', f'operation-{index}.output.json'}
        require(set(proof.get('hashes', {})) == names, 'incomplete current cleanup evidence')
        for name in names:
            require(digest(regular(ref.parent / name, True)) == proof['hashes'][name], 'cleanup original failure evidence changed')
        judgment_ref = Path(proof.get('judgment_ref', ''))
        require(judgment_ref.is_absolute() and judgment_ref.is_relative_to(self.home / 'data') and
                judgment_ref.resolve(strict=True) == judgment_ref and
                digest(regular(judgment_ref, True)) == proof.get('judgment_sha256'), 'current cleanup judgment changed')
        q = load(judgment_ref)
        request = load(ref.parent / 'request.json')
        require(q.get('home') == proof['home'] and q.get('id') == request.get('id') == proof['id'] and
                q.get('index') == index and q.get('nonce') == request.get('nonce') == proof.get('nonce') and
                q.get('task') == self.id and q.get('spawn_gen') == receipt['spawn_gen'] and
                q.get('goal_revision') == receipt['goal_revision'] and q.get('hashes') == proof['hashes'] and
                request['input']['operations']['steps'][index] == dict(action='cleanup', task=self.id) and
                request['operationBindings'][index].get('spawn_gen') == receipt['spawn_gen'], 'current cleanup grant conflict')
        record = self.read()
        require(q.get('brief_sha256') == record['brief_sha256'] == digest(regular(self.directory / 'brief.md')),
                'current cleanup intent changed')
        merges = [p['facts'] for p in record.get('owner_receipts', {}).get('merge', [])
                  if p['execution_generation'] == receipt['spawn_gen']]
        require(merges == [q.get('candidate')], 'current cleanup candidate changed')
        judgment = q['judgment']
        require(record['disposition'] == judgment['disposition'] == 'accepted' and
                record['assessment']['outcome'] == judgment['outcome'] and record['assessment']['remaining_gap'] == '' and
                record['assessment']['authority_ref'] == judgment['authority_ref'], 'current cleanup assessment changed')
        for item in q['evidence']:
            if (self.home / item['ref']).resolve() == self.state / (self.id + '.meta'):
                require(digest(proof['metadata'].encode()) == item['sha256'], 'current cleanup saved metadata changed')
                if (self.state / (self.id + '.meta')).exists():
                    self.reference(item['ref'], item['sha256'])
            else:
                self.reference(item['ref'], item['sha256'])
            require(item in record['assessment']['evidence'], 'current cleanup assessment evidence changed')
        require(proof.get('copy_binding') == receipt.get('copy_binding'), 'current cleanup copy binding changed')
        require(not self.cleanup_copy_read()['absent'], 'current cleanup surviving copy is missing')
        return proof

    def cleanup_preservation_read(self, receipt):
        """Bind acknowledgement of an uncertain return to its unchanged failure."""
        ref = Path(receipt.get('preservation_ref', ''))
        require(ref.is_absolute() and ref.parent.parent == self.state / 'short-agents' and
                re.fullmatch(r'short-[a-f0-9]{64}', ref.parent.name) and
                re.fullmatch(r'operation-\d+\.preservation\.json', ref.name), 'invalid cleanup preservation reference')
        require(ref.resolve(strict=True) == ref, 'unsafe cleanup preservation path')
        proof = load(ref)
        require(digest(regular(ref, True)) == receipt.get('preservation_sha256'), 'cleanup preservation evidence changed')
        if proof.get('schema') == 'fm-cleanup-current-retention.v1':
            return self.cleanup_current_retention_read(receipt, proof, ref)
        index = proof.get('index')
        require(proof.get('schema') == 'fm-cleanup-preservation.v1' and proof.get('home') == str(self.home.resolve()) and
                proof.get('task') == self.id and proof.get('spawn_gen') == receipt['spawn_gen'] and
                proof.get('id') == ref.parent.name and type(index) is int and index >= 0 and
                ref.name == f'operation-{index}.preservation.json', 'cleanup preservation identity conflict')
        original = proof.get('original_cleanup', {})
        require(original.get('task_id') == self.id and original.get('spawn_gen') == receipt['spawn_gen'] and
                original.get('goal_revision') == receipt['goal_revision'] and
                original.get('copy_binding') == receipt.get('copy_binding') and
                original.get('phases', {}).get('pane_close', {}).get('state') == 'confirmed' and
                original.get('phases', {}).get('directory_return') == dict(state='pending', reason_code='copy-disposal-attempt'),
                'cleanup preservation original attempt conflict')
        names = {'request.json', 'result.json', f'operation-{index}.intent.json',
                 f'operation-{index}.effect.json', f'operation-{index}.output.json'}
        require(set(proof.get('hashes', {})) == names, 'incomplete cleanup preservation evidence')
        for name in names:
            require(digest(regular(ref.parent / name, True)) == proof['hashes'][name], 'cleanup original failure evidence changed')
        request = load(ref.parent / 'request.json')
        require(request.get('id') == proof['id'] and request.get('nonce') == proof.get('nonce') and
                request['input']['operations']['steps'][index] == dict(action='cleanup', task=self.id) and
                request['operationBindings'][index].get('spawn_gen') == receipt['spawn_gen'], 'cleanup preservation grant conflict')
        return proof

    def cleanup_preserve(self, args):
        """Private teardown owner writes preservation, never successful disposal."""
        receipt = self.cleanup_read()
        ref = Path(args.record)
        candidate = dict(receipt, preservation_ref=str(ref), preservation_sha256=digest(regular(ref, True)))
        proof = self.cleanup_preservation_read(candidate)
        if receipt.get('preservation_ref'):
            require(receipt.get('preservation_ref') == str(ref) and
                    receipt.get('preservation_sha256') == candidate['preservation_sha256'], 'cleanup preservation binding changed')
        readback = self.cleanup_copy_read()
        require(not readback['absent'], 'cleanup preservation requires the surviving bound copy')
        if proof.get('schema') == 'fm-cleanup-current-retention.v1':
            reason = 'copy-preserved-current-recovery'
        else:
            require(readback['phase'] in (dict(state='pending', reason_code='copy-disposal-attempt'),
                    dict(state='retained', reason_code='copy-preserved-after-uncertain-return')), 'cleanup preservation phase conflict')
            reason = 'copy-preserved-after-uncertain-return'
        candidate['phases'] = dict(candidate['phases'], directory_return=dict(state='retained', reason_code=reason))
        if candidate != receipt:
            self.write_cleanup_receipt(self.state / (self.id + '.cleanup.json'), candidate)
        return self.link_cleanup()

    def cleanup_binding(self, args):
        """Validate or persist an immutable binding before endpoint effects.

        Teardown owns the receipt; these are its common bounded/private-file
        mechanics, used instead of a second file-safety implementation.
        """
        result = self.cleanup_read()
        journal = self.state / (self.id + '.herdr-presentation')
        binding = digest(regular(journal))
        prior = result.get('journal_sha256')
        require(prior is None or prior == binding, 'cleanup launch binding changed')
        print(binding)
        return None

    def bind_execution(self, args):
        record = self.read(current=False)
        if record is None:
            return self.init()
        generation = self.generation()
        require(generation is not None, 'execution must publish metadata first')
        action = record.get('next_action')
        if generation == record['execution_generation']:
            if action and action['id'] == args.action_id and action['phase'] == 'uncertain' and args.phase != 'uncertain':
                require(action['kind'] == 'remote-followup', 'uncertain local execution requires its control owner')
                args.phase = 'confirmed'
                args.receipt_ref = str(self.state / 'remote-tasks' / self.id / 'state.json')
                args.receipt_sha256 = digest(regular(Path(args.receipt_ref), True))
                return self.action(args)
            return record
        require(record['disposition'] == 'open', 'cannot bind new execution to a terminal goal')
        require(record['execution_generation'] == args.expected_generation, 'old execution generation conflict')
        if action and action['phase'] not in ('confirmed', 'refused'):
            require(action['id'] == args.action_id and action['kind'] in ('spawn', 'relaunch', 'remote-followup'), 'unconfirmed action prevents replacing execution')
            require(args.phase != 'uncertain' or action['kind'] == 'remote-followup', 'only remote submission has a prepared new generation')
            action['phase'] = ('uncertain' if args.phase == 'uncertain' else
                               'attempted' if action.get('continuation', {}).get('type') == 'executor' else 'confirmed')
            receipt = (self.state / 'remote-tasks' / self.id / 'state.json'
                       if action['kind'] == 'remote-followup' else self.state / (self.id + '.meta'))
            action['receipt_ref'] = str(receipt)
            action['receipt_sha256'] = digest(regular(receipt))
        if action:
            action['result_execution_generation'] = generation
        record['execution_generation'] = generation
        record['brief_sha256'] = digest(regular(self.directory / 'brief.md'))
        record['revision'] += 1
        self.write(record)
        return record

    def refresh_brief(self, args):
        record = self.read(current=False)
        if record is None:
            return None
        require(record['disposition'] == 'open' and record['execution_generation'] == args.expected_generation == self.generation(), 'brief refresh generation/disposition conflict')
        sha = digest(regular(self.directory / 'brief.md'))
        if sha != record['brief_sha256']:
            record['brief_sha256'] = sha
            record['revision'] += 1
            self.write(record)
        return record

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
    parser.add_argument('operation', choices=('read', 'inspect', 'assess', 'update-brief', 'refresh', 'owner-receipt', 'init', 'reconcile', 'action', 'observe', 'coordinate', 'branch-patch', 'effect', 'bind-inbox', 'handoff-binding', 'handoff-effect', 'readback', 'mode', 'modes', 'due', 'authorize', 'link-cleanup', 'cleanup-read', 'completion-read', 'cleanup-copy-inspect', 'cleanup-copy-bind', 'cleanup-copy-read', 'cleanup-preserve', 'cleanup-binding', 'bind-execution', 'refresh-brief'))
    parser.add_argument('task')
    parser.add_argument('--expected-revision', type=int)
    parser.add_argument('--record')
    parser.add_argument('--action-id')
    parser.add_argument('--target')
    parser.add_argument('--payload-sha256')
    parser.add_argument('--phase', choices=tuple(PHASES))
    parser.add_argument('--receipt-ref')
    parser.add_argument('--receipt-sha256')
    parser.add_argument('--basis')
    parser.add_argument('--evidence', action='append', default=[])
    parser.add_argument('--judgment')
    parser.add_argument('--session-file')
    parser.add_argument('--entry-id')
    parser.add_argument('--input')
    parser.add_argument('--kind', choices=tuple(KINDS | {'merge'}))
    parser.add_argument('--execution-generation')
    parser.add_argument('--facts')
    parser.add_argument('--expected-generation')
    args = parser.parse_args()
    try:
        if args.operation == 'modes':
            require(args.task is not None and len(args.task.encode()) <= MAX_BYTES, 'invalid task batch size')
            tasks = json.loads(args.task)
            require(isinstance(tasks, list) and len(tasks) <= 1000 and all(atom(t) for t in tasks), 'invalid task batch')
            modes = {}
            for task_id in tasks:
                try:
                    record = Task(task_id).read()
                    modes[task_id] = record['disposition'] if record else 'legacy'
                except (Refusal, OSError, ValueError, TypeError, KeyError):
                    modes[task_id] = 'unknown'
            print(json.dumps(modes))
            return
        task = Task(args.task)
        if args.operation == 'inspect':
            result = task.inspect(args.evidence)
        elif args.operation == 'assess':
            result = task.assess(args)
        elif args.operation == 'update-brief':
            result = task.update_brief(args)
        elif args.operation == 'refresh':
            result = task.refresh(args)
        elif args.operation == 'owner-receipt':
            result = task.owner_receipt(args)
        elif args.operation == 'init':
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
        elif args.operation == 'authorize':
            result = task.authorize(args)
        elif args.operation == 'link-cleanup':
            result = task.link_cleanup()
        elif args.operation == 'cleanup-copy-inspect':
            result = task.cleanup_copy_inspect()
        elif args.operation == 'cleanup-copy-bind':
            result = task.cleanup_copy_bind()
        elif args.operation == 'cleanup-copy-read':
            result = task.cleanup_copy_read()
        elif args.operation == 'cleanup-preserve':
            require(args.record, 'cleanup preservation needs owner evidence')
            result = task.cleanup_preserve(args)
        elif args.operation == 'cleanup-binding':
            task.cleanup_binding(args)
            return
        elif args.operation == 'cleanup-read':
            result = task.cleanup_read()
        elif args.operation == 'completion-read':
            result = task.completion_read()
        elif args.operation == 'bind-execution':
            result = task.bind_execution(args)
        elif args.operation == 'refresh-brief':
            result = task.refresh_brief(args)
        else:
            result = task.read()
            if args.operation == 'mode':
                print(result['disposition'] if result else 'legacy')
                return
            if args.operation == 'due':
                print(json.dumps(task.due(result)))
                return
        print(json.dumps(result, ensure_ascii=False))
    except (Refusal, OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired) as error:
        if args.operation == 'mode':
            # Homes without this task data predate the optional lifecycle record.
            home = Path(os.environ.get('FM_DATA_OVERRIDE', str(Path(os.environ.get('FM_HOME', '.')) / 'data')))
            if atom(args.task) and not (home / args.task).exists():
                print('legacy')
                return
            print('unknown')
        print('REFUSED: lifecycle: ' + str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
