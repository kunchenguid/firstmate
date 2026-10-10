#!/usr/bin/env python3
"""Implementation of the wire contract owned by fm-dispatch-validation.sh --help."""

import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False).encode("utf-8")


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate result key")
        value[key] = item
    return value


def main():
    (validator, snapshot, home, state, data, config, task_id, kind, project,
     mode, base, effective) = sys.argv[1:]
    brief = Path(effective).read_bytes()
    request = dict(
        schema_version=1, home=home, state_dir=state, data_dir=data,
        config_dir=config, task_id=task_id, kind=kind, project=project,
        delivery_mode=mode or None, base_branch=base or None, relaunch=False,
        effective_brief_path=effective, brief_sha256=sha256(brief))
    request["request_sha256"] = sha256(encode(request))
    # A file for stdin avoids blocking on a validator that never reads its input.
    with tempfile.TemporaryFile() as stdin:
        stdin.write(encode(request) + b"\n")
        stdin.seek(0)
        child = subprocess.Popen([validator], stdin=stdin, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
        output = bytearray()
        sizes = {child.stdout: 0, child.stderr: 0}
        with selectors.DefaultSelector() as selector:
            for pipe in sizes:
                selector.register(pipe, selectors.EVENT_READ)
            while selector.get_map():
                for key, _ in selector.select():
                    chunk = os.read(key.fd, 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        continue
                    sizes[key.fileobj] += len(chunk)
                    if sizes[key.fileobj] > 65536:
                        # Stay under the outer watchdog so it reaps the whole
                        # group, including descendants holding output pipes.
                        print("error: dispatch validator output exceeds 65536 bytes", file=sys.stderr)
                        while True:
                            selector.select(timeout=5)
                    if key.fileobj is child.stderr:
                        sys.stderr.buffer.write(chunk)
                        sys.stderr.buffer.flush()
                    else:
                        output.extend(chunk)
        if child.wait() != 0:
            raise ValueError("validator exited nonzero")
    result = json.loads(output, object_pairs_hook=unique_object)
    if (not isinstance(result, dict) or
            set(result) != {"schema_version", "decision", "request_sha256"} or
            type(result["schema_version"]) is not int or result["schema_version"] != 1 or
            result["decision"] != "allow" or
            result["request_sha256"] != request["request_sha256"]):
        raise ValueError("expected schema-valid allow for this request digest")
    if Path(effective).read_bytes() != brief:
        raise ValueError("effective brief changed during validation")
    # Snapshot bytes held before validation, never re-read later mutable input.
    with open(snapshot, "wb") as accepted:
        accepted.write(brief)
    os.chmod(snapshot, 0o400)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"error: dispatch validation: {error}", file=sys.stderr)
        sys.exit(1)
