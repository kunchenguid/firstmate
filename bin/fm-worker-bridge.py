#!/usr/bin/env python3
"""Persistent Firstmate crew/scout endpoint for Hermes and Antigravity CLI.

Usage: fm-worker-bridge.py --harness hermes|antigravity --state DIR --id ID
       --gen GENERATION --brief FILE [--model MODEL] [--effort LEVEL]

Each submitted line runs the actual CLI in headless mode, bound to this
incarnation's private conversation. Ctrl+C cancels its process group; /exit
closes only this endpoint. Busy records are generation-bound. No primary or
secondmate supervision is provided. Python 3 standard library only.
"""
import argparse
import atexit
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import uuid
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--harness', choices=('hermes', 'antigravity'), required=True)
    for name in ('state', 'id', 'gen', 'brief'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--backend', default='tmux')
    parser.add_argument('--model')
    parser.add_argument('--effort')
    args = parser.parse_args()
    if args.harness == 'antigravity' and args.effort not in (None, 'low', 'medium', 'high'):
        parser.error('Antigravity supports only low, medium, and high effort')
    root = Path(__file__).resolve().parent
    state = Path(args.state)
    session = 'firstmate-' + uuid.uuid4().hex
    conversation = None
    env = os.environ.copy()
    for key in ('CLAUDECODE', 'PI_CODING_AGENT', 'GROK_AGENT', 'FM_PI_HARNESS',
                'CURSOR_AGENT', 'CURSOR_INVOKED_AS', 'GEMINI_CLI'):
        env.pop(key, None)
    env['FM_WORKER_BRIDGE_HARNESS'] = args.harness

    herdr_pane = env.get('HERDR_PANE_ID') if args.backend == 'herdr' else None
    if args.backend == 'herdr' and not herdr_pane:
        raise RuntimeError('Herdr bridge has no inherited pane identity')
    herdr_session = env.get('HERDR_SESSION')
    herdr_source = 'firstmate:bridge:' + args.gen
    native_agent = 'agy' if args.harness == 'antigravity' else 'hermes'

    def herdr_report(value=None):
        if not herdr_pane:
            return
        if not herdr_session:
            raise RuntimeError('Herdr bridge requires explicit HERDR_SESSION')
        command = [env.get('HERDR_BIN_PATH') or 'herdr', 'pane',
                   'report-agent' if value is not None else 'release-agent',
                   herdr_pane, '--source', herdr_source, '--agent', native_agent,
                   '--seq', str(time.time_ns()), '--session', herdr_session]
        if value is not None:
            command += ['--state', 'working' if value == 'busy' else value]
        result = subprocess.run(command, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, text=True, timeout=3)
        if result.returncode and value is not None:
            raise RuntimeError('Herdr lifecycle publication failed: ' + result.stderr)

    atexit.register(herdr_report)

    def event(value, reason):
        result = subprocess.run([str(root / 'fm-busy-event.sh'), 'apply',
            str(state), args.id, value, '--gen', args.gen,
            '--source', 'worker-bridge', '--event', reason], check=False)
        if result.returncode:
            raise RuntimeError('busy generation retired or state publication failed')
        herdr_report(value)

    def terminate(process):
        if process is None or getattr(process, "_fm_drained", False):
            return
        process._fm_drained = True
        # The session leader may already have exited while a tool descendant
        # still owns the group. Never use leader.poll() as group-liveness proof.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            process.wait()
            return
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            process.poll()
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                process.wait()
                return
            time.sleep(.05)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()

    spawning = False
    pending_signal = None

    def terminated(signum, frame):
        nonlocal pending_signal
        if spawning:
            pending_signal = signum
            return
        if signum == signal.SIGINT:
            raise KeyboardInterrupt
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGINT, terminated)
    signal.signal(signal.SIGTERM, terminated)
    signal.signal(signal.SIGHUP, terminated)

    def run(prompt):
        nonlocal conversation, spawning, pending_signal
        if args.harness == 'hermes':
            command = ['hermes', 'chat', '--cli', '--oneshot', '-Q', '--yolo',
                       '--continue', session, '--create-if-missing',
                       '--no-restore-cwd', '--query-file', '-']
            if args.effort:
                command += ['--reasoning', args.effort]
            payload = prompt
        else:
            command = ['agy', '--print', prompt, '--output-format', 'json',
                       '--dangerously-skip-permissions']
            if conversation:
                command += ['--conversation', conversation]
            if args.effort in ('low', 'medium', 'high'):
                command += ['--effort', args.effort]
            payload = ''
        if args.model:
            command += ['--model', args.model]
        event('busy', 'turn-start')
        print('Firstmate worker running', flush=True)
        process = None
        output_file = tempfile.TemporaryFile()
        error_file = tempfile.TemporaryFile()
        try:
            spawning = True
            process = subprocess.Popen(command, stdin=subprocess.PIPE,
                stdout=output_file, stderr=error_file, text=True,
                env=env, start_new_session=True)
            spawning = False
            if pending_signal is not None:
                interrupted = pending_signal
                pending_signal = None
                terminated(interrupted, None)
            process.communicate(payload)
            terminate(process)
            output_file.seek(0)
            error_file.seek(0)
            output = output_file.read(1024 * 1024 + 1).decode(errors='replace')
            errors = error_file.read(1024 * 1024 + 1).decode(errors='replace')
            if len(output) > 1024 * 1024 or len(errors) > 1024 * 1024:
                raise ValueError('CLI output exceeded the 1 MiB protocol limit')
            if errors:
                print(errors, flush=True)
            success = process.returncode == 0
            if args.harness == 'hermes':
                success = success and bool(re.search(r'^session_id: \S+$', errors, re.M)) and bool(output.strip())
            if args.harness == 'antigravity' and success:
                result = json.loads(output)
                if not isinstance(result, dict):
                    raise ValueError('Antigravity JSON result must be an object')
                next_conversation = result.get('conversation_id')
                success = result.get('status') == 'SUCCESS' and isinstance(next_conversation, str) and bool(next_conversation)
                if success:
                    conversation = next_conversation
                print(result.get('response', output), flush=True)
            else:
                print(output, flush=True)
            if not success:
                with (state / (args.id + '.status')).open('a') as status:
                    status.write('blocked: ' + args.harness + ' worker turn failed; inspect endpoint output\n')
                print('Firstmate worker turn failed', flush=True)
            event('idle', 'turn-end' if success else 'turn-failed')
        except KeyboardInterrupt:
            if process is not None and process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGINT)
                except ProcessLookupError:
                    pass
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate()
            terminate(process)
            event('idle', 'turn-cancelled')
            print('\nFirstmate worker cancelled', flush=True)
        except (OSError, ValueError) as error:
            print('Firstmate worker error: ' + str(error), flush=True)
            event('unknown', 'turn-error')
            raise
        finally:
            spawning = False
            terminate(process)
            output_file.close()
            error_file.close()
        # Apply rejects stale generations before we emit the completion wake.
        (state / (args.id + '.turn-ended')).touch()

    run(Path(args.brief).read_text())
    # readline supplies a real single-line composer and Ctrl+U editing.
    import readline  # noqa: F401
    while True:
        try:
            prompt = input('❯ ')
        except EOFError:
            break
        except KeyboardInterrupt:
            print()
            continue
        if prompt in ('/exit', '/quit'):
            break
        if prompt.strip():
            run(prompt)


if __name__ == '__main__':
    main()
