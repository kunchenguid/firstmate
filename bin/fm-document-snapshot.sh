#!/usr/bin/env bash
# Capture or receive a reviewed, non-secret document for a routed request.
# Usage:
#   FM_HOME=<source-home> fm-document-snapshot.sh capture <document-path>
#   FM_HOME=<receiving-home> fm-document-snapshot.sh receive <sha256> <bytes> < document
# Both print data/report-snapshots/<sha256>.md only after verified publication.
# capture accepts an absolute or home-relative .md/.txt file under data/.
# Hidden/credential paths, symlinks, hardlinks, non-UTF-8 text, control bytes,
# and recognizable credential content are refused. These checks are not proof
# that arbitrary prose is non-secret: callers must review the document first.
# The snapshot is at most 1 MiB, the existing remote-file transport safety bound.
# A larger input must be reduced to the relevant non-secret document, never
# silently truncated. The source document is never modified.
# receive is the narrow artifact-copy endpoint for fm-on.sh --stdin; its hash
# and byte count commit to the exact reviewed bytes, including final newlines.
# Source-home and source-document provenance travel with the referring message.
set -eu
case "${1:-}" in
  --help|-h) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
# Descriptor-relative IO keeps components confined across directory replacement.
python3 - "$@" 3<&0 <<'PY'
import hashlib
import os
import re
import stat
import sys
import uuid

MAX_BYTES = 1048576
DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW


def refuse(message):
    raise ValueError(message)


def directory(parent, name, create=False):
    if create:
        try:
            os.mkdir(name, 0o700, dir_fd=parent)
        except FileExistsError:
            pass
    return os.open(name, DIRECTORY, dir_fd=parent)


def read_file(parent, name):
    with os.fdopen(os.open(name, FILE, dir_fd=parent), 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            refuse('document must be an ordinary, non-hardlinked file')
        if info.st_size > MAX_BYTES:
            refuse('document exceeds the 1048576-byte safety bound')
        return source.read(MAX_BYTES + 1)


def check_content(content):
    if len(content) > MAX_BYTES:
        refuse('document exceeds the 1048576-byte safety bound')
    text = content.decode('utf-8')
    if re.search(r'[\x00-\x08\x0b-\x1f\x7f]', text):
        refuse('document contains control bytes')
    patterns = (
        r'-----BEGIN [A-Z ]*PRIVATE KEY-----',
        r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
        r'\b(?:gh[pousr]_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]+',
        r'\b(?:sk_live_|sk-proj-)[A-Za-z0-9_-]+',
        r'\b(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|'
        r'client[_-]?secret|authorization)[\w-]*[\s\"\x27]*[:=]\s*\S+',
        r'\bBearer\s+[A-Za-z0-9._~-]+',
        r'://[^\s/:]+:[^\s/@]+@',
    )
    if any(re.search(pattern, text, re.IGNORECASE) for pattern in patterns):
        refuse('document contains possible credentials; provide a reviewed non-secret extract')


def publish(home, content, digest):
    data = directory(home, 'data', create=True)
    try:
        snapshots = directory(data, 'report-snapshots', create=True)
    finally:
        os.close(data)
    name = digest + '.md'
    temporary = '.' + uuid.uuid4().hex
    try:
        try:
            info = os.stat(name, dir_fd=snapshots, follow_symlinks=False)
        except FileNotFoundError:
            info = None
        if info is not None and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1):
            refuse('snapshot destination is unsafe')
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=snapshots)
        with os.fdopen(fd, 'wb') as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, name, src_dir_fd=snapshots, dst_dir_fd=snapshots)
        if read_file(snapshots, name) != content:
            refuse('snapshot read-back differs from the reviewed bytes')
        # A successful write through an old directory descriptor is not proof
        # the receiving home can still reach that directory by its named path.
        current_data = directory(home, 'data')
        try:
            current = directory(current_data, 'report-snapshots')
        finally:
            os.close(current_data)
        try:
            current_info, stored_info = os.fstat(current), os.fstat(snapshots)
            if (current_info.st_dev, current_info.st_ino) != (stored_info.st_dev, stored_info.st_ino):
                refuse('snapshot directory changed during publication')
        finally:
            os.close(current)
    finally:
        try:
            os.unlink(temporary, dir_fd=snapshots)
        except FileNotFoundError:
            pass
        os.close(snapshots)
    print('data/report-snapshots/' + name)


def main():
    home_path = os.path.realpath(os.environ['FM_HOME'])
    home = os.open(home_path, DIRECTORY)
    try:
        args = sys.argv[1:]
        if len(args) == 2 and args[0] == 'capture':
            path = args[1]
            if re.search(r'[\x00-\x1f\x7f]', path):
                refuse('document path contains control bytes')
            if os.path.isabs(path):
                path = os.path.relpath(path, home_path)
            parts = path.split('/')
            if parts[0] != 'data' or any(not part or part.startswith('.') for part in parts):
                refuse("document must be a non-hidden path under this home's data directory")
            if not path.endswith(('.md', '.txt')):
                refuse('document must be Markdown or plain text')
            if re.search(r'(?:credential|secret|password|token|id_rsa|id_ed25519|\.pem|\.key)', path, re.I):
                refuse('credential paths cannot be snapshotted')
            parent = os.dup(home)
            try:
                for part in parts[:-1]:
                    child = directory(parent, part)
                    os.close(parent)
                    parent = child
                content = read_file(parent, parts[-1])
            finally:
                os.close(parent)
            digest = hashlib.sha256(content).hexdigest()
        elif len(args) == 3 and args[0] == 'receive':
            digest, size = args[1:]
            if not re.fullmatch(r'[a-f0-9]{64}', digest) or not re.fullmatch(r'\d{1,7}', size):
                refuse('invalid snapshot digest or byte count')
            if int(size) > MAX_BYTES:
                refuse('document exceeds the 1048576-byte safety bound')
            with os.fdopen(3, 'rb') as source:
                content = source.read(MAX_BYTES + 1)
            if len(content) != int(size) or hashlib.sha256(content).hexdigest() != digest:
                refuse('snapshot bytes do not match their commitment')
        else:
            refuse('usage: fm-document-snapshot.sh capture <path> | receive <sha256> <bytes>')
        check_content(content)
        publish(home, content, digest)
    finally:
        os.close(home)


try:
    main()
except (OSError, ValueError, KeyError) as error:
    sys.exit('error: cannot deliver document snapshot: ' + str(error))
PY
