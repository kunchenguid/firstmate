"""Confined filesystem operations. All traversal uses anchored no-follow dir fds."""
import hashlib
import importlib.util
import json
import os
import stat
import sys
import uuid
from pathlib import Path
if __name__ == '__main__' and sys.platform == 'linux':
    import ctypes
    # A fixed helper never survives the worker that owns it.
    ctypes.CDLL(None).prctl(1, 9, 0, 0, 0)

LIMIT = 65536
PROTECTED = {'.git', '.omp', '.pi', '.claude', '.codex', '.env', '.ssh', '.aws', '.netrc', '.npmrc',
             'state', 'control', 'config', 'credentials', 'credentials.json', 'auth.db', 'auth.json'}
SOURCE = Path(__file__).resolve().parent


def protected(name):
    return name in PROTECTED or name.startswith('.env')


def digest(value):
    spec = importlib.util.spec_from_file_location('fm_confined_canonical', Path(__file__).with_name('controller.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return hashlib.sha256(module.canonical(value)).hexdigest()


def canonical_root(root):
    if not isinstance(root, str):
        raise ValueError('canonical_root_required')
    path = Path(root)
    if not path.is_absolute() or path.resolve() != path:
        raise ValueError('canonical_root_required')
    if path == SOURCE or path in SOURCE.parents or SOURCE in path.parents:
        raise ValueError('trusted_source_inside_worker_scope')
    return root


def parts(path):
    if not isinstance(path, str) or not path or os.path.isabs(path) or '\x00' in path:
        raise ValueError('relative_path_required')
    result = path.split('/')
    if any(p in ('', '.', '..') or protected(p) for p in result):
        raise ValueError('path_refused')
    return result


def parent(root, path):
    root = canonical_root(root)
    names = parts(path)
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for name in names[:-1]:
            nxt = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return fd, names[-1]
    except BaseException:
        os.close(fd)
        raise


def snapshot(fd):
    s = os.fstat(fd)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_size > LIMIT:
        raise ValueError('regular_single_link_bounded_file_required')
    data = os.read(fd, LIMIT + 1)
    return data, f'{s.st_dev}:{s.st_ino}:{s.st_size}:{s.st_mtime_ns}:' + hashlib.sha256(data).hexdigest()


def preview(root, args):
    fd, name = parent(root, args['path'])
    try:
        try:
            file_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        except FileNotFoundError:
            if args['operation'] != 'write':
                raise
            old, fingerprint = b'', 'missing'
        else:
            try:
                old, fingerprint = snapshot(file_fd)
            finally:
                os.close(file_fd)
        operation = args['operation']
        if operation == 'edit':
            before = args['oldText'].encode()
            if not before or old.count(before) != 1:
                raise ValueError('edit_requires_one_exact_match')
            new = old.replace(before, args['newText'].encode(), 1)
        elif operation == 'write':
            new = args['content'].encode()
        elif operation == 'read':
            new = old
        else:
            raise ValueError('unknown_operation')
        if len(new) > LIMIT:
            raise ValueError('content_too_large')
        return {'path': os.path.join(root, args['path']), 'fingerprint': fingerprint,
                'beforeSha256': hashlib.sha256(old).hexdigest(), 'afterSha256': hashlib.sha256(new).hexdigest(),
                'argsDigest': digest(args), 'bytes': len(new)}, new
    finally:
        os.close(fd)


def execute(root, args, expected=None, write_fn=None):
    evidence, data = preview(root, args)
    if args['operation'] == 'read':
        return data.decode('utf-8', 'replace')
    if evidence != expected:
        raise ValueError('approval_target_changed')
    fd, name = parent(root, args['path'])
    staged = '.fm-write-' + str(uuid.uuid4())
    try:
        file_fd = os.open(staged, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        try:
            offset = 0
            for _ in range(128):
                if offset == len(data):
                    break
                written = (write_fn or os.write)(file_fd, data[offset:])
                if type(written) is not int or not 0 < written <= len(data)-offset:
                    raise ValueError('staged_write_no_progress')
                offset += written
            if offset != len(data):
                raise ValueError('staged_write_limit')
            os.fsync(file_fd)
            os.lseek(file_fd, 0, os.SEEK_SET)
            if snapshot(file_fd)[0] != data:
                raise ValueError('staged_content_changed')
            if evidence['fingerprint'] == 'missing':
                os.link(staged, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
            else:
                target_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                try:
                    _, actual = snapshot(target_fd)
                    if actual != evidence['fingerprint']:
                        raise ValueError('approval_target_changed')
                    os.fchmod(file_fd, os.fstat(target_fd).st_mode & 0o777)
                finally:
                    os.close(target_fd)
                os.replace(staged, name, src_dir_fd=fd, dst_dir_fd=fd)
            os.fsync(fd)
        finally:
            os.close(file_fd)
    finally:
        try:
            os.unlink(staged, dir_fd=fd)
        except FileNotFoundError:
            pass
        os.close(fd)
    return 'mutation_applied'


def grep(root, path, text):
    root = canonical_root(root)
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if path != '.':
            for name in parts(path):
                nxt = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = nxt
        hits = []
        visited = 0
        def walk(directory, prefix):
            nonlocal visited
            for name in sorted(os.listdir(directory)):
                visited += 1
                if visited > 1000:
                    raise ValueError('grep_file_limit')
                if protected(name):
                    continue
                s = os.stat(name, dir_fd=directory, follow_symlinks=False)
                if stat.S_ISLNK(s.st_mode):
                    continue
                if stat.S_ISDIR(s.st_mode):
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                    try:
                        walk(child, prefix + name + '/')
                    finally:
                        os.close(child)
                elif stat.S_ISREG(s.st_mode) and s.st_nlink == 1 and s.st_size <= LIMIT:
                    child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
                    try:
                        raw, _ = snapshot(child)
                    finally:
                        os.close(child)
                    for number, line in enumerate(raw.decode('utf-8', 'replace').splitlines(), 1):
                        if text in line:
                            hits.append(f'{prefix}{name}:{number}:{line[:500]}')
                            if len(hits) >= 100:
                                return
                if len(hits) >= 100:
                    return
        walk(fd, '' if path == '.' else path + '/')
        return '\n'.join(hits)[:LIMIT]
    finally:
        os.close(fd)


if __name__ == '__main__':
    try:
        request = json.load(sys.stdin)
        root = request['root']
        canonical_root(root)
        mode, args = request['mode'], request['args']
        if mode == 'preview':
            result = preview(root, args)[0]
        elif args['operation'] == 'grep':
            result = grep(root, args['path'], args['text'])
        elif mode == 'execute':
            result = execute(root, args, request.get('expected'))
        else:
            raise ValueError('unknown_mode')
        print(json.dumps({'ok': True, 'result': result}))
    except Exception:
        print(json.dumps({'ok': False, 'error': 'filesystem_boundary_refused'}))
        sys.exit(1)
