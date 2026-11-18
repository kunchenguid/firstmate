"""Prepared owner control producer; never callable as a worker tool.

Usage (authorized owner console only):
  sudo /usr/bin/python3 -I record_signer.py capsule <task> <reviewed-payload.json>
  sudo /usr/bin/python3 -I record_signer.py mutation <task> <nonce> approve|deny
  sudo /usr/bin/python3 -I record_signer.py credit <task> <verified-credit.json>
No operation installs keys, logs in, queries a provider, or runs an SDK session.
The enrolled owner key is fixed at /etc/firstmate/omp-kepler/owner.key, root-only.
Root access alone does not establish captain identity: deployment must bind this
console/key to the authenticated owner-controlled FM channel before use.
Envelope serialization matches controller.canonical; content stays in files.
"""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


controller = load('controller')
boundary = load('fs_boundary')
KEY = Path('/etc/firstmate/omp-kepler/owner.key')


def sign_record(payload, key):
    with tempfile.TemporaryDirectory(prefix='fm-owner-signature-') as directory:
        message = Path(directory) / 'payload'
        message.write_bytes(controller.canonical(payload))
        result = subprocess.run(['/usr/bin/openssl', 'pkeyutl', '-sign', '-rawin', '-inkey', str(key), '-in', str(message)],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=True)
    return {'payload': payload, 'signature': base64.b64encode(result.stdout).decode()}


def bind_mutation(request, capsule, capsule_hash, now):
    if request.get('version') != 1 or request.get('task') != capsule['task'] or request.get('capsuleHash') != capsule_hash:
        raise ValueError('mutation_task_binding_changed')
    if capsule['role'] != 'crew' or request.get('operation') not in ('write', 'edit') or not now < request.get('expiresAt', 0) <= min(capsule['deadline'], now + 60):
        raise ValueError('mutation_authority_expired')
    args = request['arguments']
    if args.get('operation') != request['operation'] or boundary.preview(capsule['worktree'], args)[0] != request.get('preview'):
        raise ValueError('mutation_preview_changed')


def bind_credit(record, capsule, capsule_hash, now):
    expected = {'version', 'kind', 'task', 'capsuleHash', 'provider', 'modelId', 'accountEvidenceRef', 'usageEvidenceRef',
                'included', 'overage', 'observedAt', 'validUntil'}
    if set(record) != expected or record.get('kind') != 'verified-provider-credit' or record.get('version') != 1:
        raise ValueError('verified_credit_schema_required')
    if record['task'] != capsule['task'] or record['capsuleHash'] != capsule_hash or record['provider'] != capsule['model']['provider'] or record['modelId'] != capsule['model']['id']:
        raise ValueError('credit_binding_changed')
    if record['included'] is not True or record['overage'] != 0 or not record['accountEvidenceRef'] or not record['usageEvidenceRef']:
        raise ValueError('external_verified_credit_evidence_required')
    if not now - 60 <= record['observedAt'] <= now < record['validUntil'] <= capsule['deadline']:
        raise ValueError('credit_evidence_expired')


def publish(path, envelope, mode):
    path = Path(path)
    if not path.is_absolute() or path.parent.resolve() != path.parent or path.name in ('', '.', '..'):
        raise ValueError('canonical_publish_path_required')
    parent_fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    temporary = f'.owner-{uuid.uuid4()}.next'
    try:
        for component in path.parent.parts[1:]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
            os.close(parent_fd)
            parent_fd = next_fd
        fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600, dir_fd=parent_fd)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(controller.canonical(envelope))
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
        os.replace(temporary, path.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
    finally:
        try:
            os.unlink(temporary, dir_fd=parent_fd)
        except FileNotFoundError:
            pass
        os.close(parent_fd)


def main():
    if os.geteuid() != 0:
        raise ValueError('authenticated_owner_console_required')
    if len(sys.argv) < 4 or sys.argv[1] not in ('capsule', 'mutation', 'credit') or not controller.TASK_RE.fullmatch(sys.argv[2]):
        raise ValueError('usage: record_signer.py capsule|mutation|credit <task> <record-or-nonce> [approve|deny]')
    action, task = sys.argv[1:3]
    host = controller.load_host()
    controller.owned_host(KEY)
    if KEY.stat().st_mode & 0o077:
        raise ValueError('private_owner_key_custody_required')
    paths = controller.host_paths(host)
    target = paths['capsuleRoot'] / f'{task}.json'
    if action == 'capsule':
        if len(sys.argv) != 4:
            raise ValueError('invalid_capsule_arguments')
        capsule = json.loads(Path(sys.argv[3]).read_text())
        controller.validate(capsule, host, task)
        if target.exists():
            raise ValueError('existing_capsule_requires_new_owner_task_decision')
        publish(target, sign_record(capsule, KEY), 0o444)
    else:
        capsule = controller.verify_envelope(json.loads(target.read_text()), host['ownerPublicKey'])
        controller.validate(capsule, host, task)
        capsule_hash = hashlib.sha256(controller.canonical(capsule)).hexdigest()
        state = paths['stateRoot'] / task
        if action == 'mutation':
            if len(sys.argv) != 5 or not re.fullmatch(r'[0-9a-f-]{36}', sys.argv[3]) or sys.argv[4] not in ('approve', 'deny'):
                raise ValueError('exact_mutation_nonce_and_decision_required')
            request = json.loads((state / 'approvals' / f'{sys.argv[3]}.request.json').read_text())
            if request.get('nonce') != sys.argv[3]:
                raise ValueError('nonce_changed')
            bind_mutation(request, capsule, capsule_hash, time.time())
            receipt = {**request, 'decision': sys.argv[4]}
            publish(state / 'approvals' / f'{sys.argv[3]}.receipt.json', sign_record(receipt, KEY), 0o644)
        else:
            if len(sys.argv) != 4:
                raise ValueError('invalid_credit_arguments')
            record = json.loads(Path(sys.argv[3]).read_text())
            bind_credit(record, capsule, capsule_hash, time.time())
            publish(state / 'credit.json', sign_record(record, KEY), 0o644)
    print(json.dumps({'published': action, 'task': task}))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('{"error":"owner_record_producer_refused"}', file=sys.stderr)
        sys.exit(1)
