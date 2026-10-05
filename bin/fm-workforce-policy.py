#!/usr/bin/env python3
"""Supervisor policy owner: preflight NOTE TASK HARNESS BACKEND ROUTE MODE YOLO MODEL EFFORT,
launch TASK -- codex ARGS, observe TASK. Requires explicit canonical FM_HOME.
No dispatch, merge, lifecycle, grants or arbitrary executable operation.
Wire and supported limits are owned by fm_workforce_policy.py.
"""
import os
import json
from pathlib import Path
import sys
import subprocess
import fm_workforce_policy as p
from fm_inbox_admission import captured

try:
    raw = os.environ.get('FM_HOME', '')
    if not raw or not Path(raw).is_absolute():
        raise ValueError('explicit absolute FM_HOME required')
    home = Path(raw).resolve(strict=True)
    verb, *args = sys.argv[1:]
    if verb == 'probe' and not args:
        policy = p.validate(json.load(sys.stdin))
        result = p.probe_codex(policy)
    elif verb == 'capabilities' and not args:
        result = p.capabilities()
    elif verb == 'preflight' and len(args) == 9:
        result = p.preflight(home, *args, captured)
    elif verb == 'allocation' and len(args) == 1:
        _, headers, _, _ = captured(home, args[0])
        result = json.loads(headers.get('workforce_allocation', 'null'))
    elif verb == 'origin-note' and len(args) == 1:
        print(json.loads(p.read_meta(home, args[0])['admission_origin'])['note_id'])
        sys.exit(0)
    elif verb == 'launch' and len(args) >= 3 and args[1] == '--':
        result = p.launch(home, args[0], args[2:])
    elif verb == 'observe' and len(args) == 1:
        result = p.observe(home, args[0])
    else:
        raise ValueError(__doc__)
    print(p.canonical(result))
except (ValueError, OSError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
    print('Workforce policy refused: '+str(error), file=sys.stderr)
    sys.exit(1)
