#!/usr/bin/env bash
# Token-free native Hermes profile-safety probe. Opt in with
# FM_HERMES_PROFILE_SAFETY_LIVE=1 and FM_HERMES_PYTHON=<Hermes environment's
# Python interpreter>. Holds the native gateway runtime lock without starting
# or messaging a gateway; opens an uncredentialed TUI and exercises two native
# session/memory writers in the same disposable profile. This does not verify
# a real mid-turn gateway, external memory providers, or same-session writes.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_HERMES_PROFILE_SAFETY_LIVE hermes tmux python3
: "${FM_HERMES_PYTHON:?provide the installed Hermes Python environment}"
HERMES_BIN=$(command -v hermes)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/hm-safety.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$LAB/profiles/worker" "$LAB/work"
printf '%s\n' '{"model":{"default":"gpt-6-astra","provider":"openai-codex"},"telemetry":{"shared_metrics":{"enabled":false,"send":false,"offer_version":2}}}' > "$LAB/profiles/worker/config.yaml"
VERSION=$(HERMES_HOME="$LAB" "$HERMES_BIN" --version 2>/dev/null | head -1)
VERSION=${VERSION:-Hermes version unknown}
HERMES_HOME="$LAB/profiles/worker" "$FM_HERMES_PYTHON" - "$LAB" "$HERMES_BIN" "$ROOT" <<'PY'
import os, shlex, shutil, subprocess, sys, time
from pathlib import Path
from gateway.status import acquire_gateway_runtime_lock, release_gateway_runtime_lock
from hermes_state import SessionDB
root, binary = Path(sys.argv[1]), sys.argv[2]
home = root / 'profiles/worker'
assert Path(os.environ['HERMES_HOME']) == home
assert acquire_gateway_runtime_lock()
print('native gateway runtime lock: held', flush=True)
socket = str(root / 'native-safety.sock')
command = ('env HERMES_HOME=' + shlex.quote(str(root)) + ' ' + shlex.quote(binary)
           + ' -p worker --tui --yolo --in ' + shlex.quote(str(root / 'work')))
try:
    subprocess.run(['tmux', '-S', socket, 'new-session', '-d', '-s', 'native-safety', '-n', 'tui',
                    '-x', '140', '-y', '44', '-c', str(root / 'work'), command], check=True)
    for _ in range(240):
        screen = subprocess.check_output(['tmux', '-S', socket, 'capture-pane', '-p', '-t', 'native-safety'], text=True)
        if '─ ready' in screen and 'worker ❯' in screen:
            print('native TUI beside held gateway runtime lock: ready', flush=True)
            break
        time.sleep(.5)
    else:
        raise RuntimeError('native Hermes TUI did not reach ready beside its gateway lock')
    probe = '''probe_tmux=$2; probe_socket=$3
tmux() { "$probe_tmux" -S "$probe_socket" "$@"; }
. "$1/bin/fm-backend.sh"
fm_backend_source tmux || exit 1
fm_backend_agent_state tmux native-safety:tui
'''
    verdict = subprocess.check_output(['bash', '-c', probe, '_', sys.argv[3],
                                       shutil.which('tmux'), socket],
                                      text=True).strip()
    assert verdict == 'alive', 'native Hermes foreground liveness: ' + verdict
    print('native TUI foreground liveness: alive', flush=True)
    code = """from hermes_state import SessionDB
from tools.memory_tool_store import MemoryStore
import sys
sid=sys.argv[1]
db=SessionDB(); db.create_session(sid, source='gateway' if sid.endswith('gateway') else 'tui'); db.close()
result=MemoryStore().add('memory', sid)
assert not result.get('error'), result
"""
    jobs = [subprocess.Popen([sys.executable, '-c', code, 'fm-probe-' + name],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            for name in ('gateway', 'tui')]
    for job in jobs:
        out, err = job.communicate(timeout=20)
        if job.returncode:
            raise RuntimeError(err)
    db = SessionDB(read_only=True)
    assert all(db.get_session('fm-probe-' + name) for name in ('gateway', 'tui'))
    db.close()
    memory = (home / 'memories/MEMORY.md').read_text()
    assert all('fm-probe-' + name in memory for name in ('gateway', 'tui'))
    print('two native session-store writers: distinct sessions retained', flush=True)
    print('two native memory add writers: both entries retained', flush=True)
finally:
    subprocess.run(['tmux', '-S', socket, 'kill-server'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    release_gateway_runtime_lock()
    print('native gateway runtime lock: released', flush=True)
PY
result=$?
[ "$result" = 0 ] || fail "$VERSION: native Hermes profile-safety probe failed"
pass "$VERSION: native lock/TUI coexistence and distinct session/memory writers"
