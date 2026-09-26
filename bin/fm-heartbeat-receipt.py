#!/usr/bin/env python3
"""Validate the three duty readbacks of fm-stow-run.sh's heartbeat receipt.

This is a validator, not an executor or a new state owner. Semantic judgment
and guarded effect owners remain responsible for the evidence's meaning.
"""
import hashlib
import json
from pathlib import Path
import sys

def require(ok, reason):
    if not ok:
        raise ValueError(reason)


try:
    home = Path(sys.argv[1]).resolve(strict=True)
    receipt = json.loads(Path(sys.argv[2]).read_text())
    duties = receipt['heartbeat']
    require(isinstance(duties, dict) and set(duties) == {'archival', 'continuation', 'knowledge'}, 'missing duty')
    for name, duty in duties.items():
        require(duty['status'] in ('complete', 'unchanged'), name + ' unfinished')
        path = home / duty['evidence_ref']
        require(not path.is_symlink() and path.is_file(), 'unsafe evidence')
        resolved = path.resolve(strict=True)
        require(resolved.is_relative_to(home / 'data') or resolved.is_relative_to(home / 'state'), 'evidence outside home')
        require(path.stat().st_size <= 262144, 'oversized evidence')
        require(hashlib.sha256(path.read_bytes()).hexdigest() == duty['sha256'], 'changed evidence')
except (AssertionError, KeyError, ValueError, OSError, IndexError, TypeError) as error:
    print('heartbeat receipt refused: ' + str(error), file=sys.stderr)
    sys.exit(1)
