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
import contextlib
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

PROTOCOL_LIMIT = 1024 * 1024
ANTIGRAVITY_PRINT_TIMEOUT = '24h'
ANTIGRAVITY_TRUNCATION_NOTE = '(response may be truncated)'


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
    brief = subprocess.run([str(root / 'fm-operational-input.sh'), 'encode', 'launch-brief'],
        input=Path(args.brief).read_text(), text=True,
        stdout=subprocess.PIPE, check=True).stdout
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
    if herdr_pane and not herdr_session:
        raise RuntimeError('Herdr bridge requires explicit HERDR_SESSION')
    herdr_source = 'firstmate:bridge:' + args.gen
    native_agent = 'agy' if args.harness == 'antigravity' else 'hermes'
    herdr_registered = False

    def herdr_report(value=None):
        nonlocal herdr_registered
        if not herdr_pane:
            return
        command = ['herdr', 'pane',
                   'report-agent' if value is not None else 'release-agent',
                   herdr_pane, '--source', herdr_source, '--agent', native_agent,
                   '--seq', str(time.time_ns()), '--session', herdr_session]
        if value is not None:
            command += ['--state', 'working' if value == 'busy' else value]
        try:
            result = subprocess.run(command, stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE, text=True, timeout=3)
        except (OSError, subprocess.SubprocessError) as error:
            failure = str(error)
        else:
            failure = (result.stderr.strip() or 'herdr exited %d' % result.returncode
                       ) if result.returncode else ''
        if value is None:
            return
        if not failure:
            herdr_registered = True
            return
        # An unregistered pane reads as a dead agent, so only publications made
        # after a successful registration may be treated as best-effort.
        if not herdr_registered:
            raise RuntimeError('Herdr agent registration failed: ' + failure)
        print('Herdr lifecycle publication failed: ' + failure, flush=True)

    atexit.register(herdr_report)

    def event(value, reason):
        # The record writer holds an mkdir lock; a signal that killed it would
        # strand that lock and refuse every later publication.
        with deferred():
            result = subprocess.run([str(root / 'fm-busy-event.sh'), 'apply',
                str(state), args.id, value, '--gen', args.gen,
                '--source', 'worker-bridge', '--event', reason], check=False)
            if result.returncode:
                raise RuntimeError('busy generation retired or state publication failed')
            herdr_report(value)

    def terminate(process):
        if process is None or getattr(process, "_fm_drained", False):
            return
        # The session leader may already have exited while a tool descendant
        # still owns the group. Never use leader.poll() as group-liveness proof.
        deadline = time.monotonic() + 5
        try:
            os.killpg(process.pid, signal.SIGTERM)
            while time.monotonic() < deadline:
                process.poll()
                os.killpg(process.pid, 0)
                time.sleep(.05)
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        process._fm_drained = True

    deferring = False
    pending_signal = None

    def terminated(signum, frame):
        nonlocal pending_signal
        if deferring:
            pending_signal = signum
            return
        if signum == signal.SIGINT:
            raise KeyboardInterrupt
        raise SystemExit(128 + signum)

    @contextlib.contextmanager
    def deferred():
        nonlocal deferring, pending_signal
        deferring = True
        try:
            yield
        finally:
            deferring = False
        if pending_signal is not None:
            signum = pending_signal
            pending_signal = None
            terminated(signum, None)

    @contextlib.contextmanager
    def uninterrupted():
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            yield
        finally:
            signal.signal(signal.SIGINT, terminated)

    def antigravity_result(output):
        nonlocal conversation
        try:
            result = json.loads(output)
        except ValueError as error:
            return False, 'Antigravity returned no readable JSON result: ' + str(error)
        if not isinstance(result, dict):
            return False, 'Antigravity JSON result must be an object'
        response = result.get('response', output)
        next_conversation = result.get('conversation_id')
        if result.get('status') != 'SUCCESS' or not isinstance(next_conversation, str) or not next_conversation:
            return False, response
        conversation = next_conversation
        return True, response

    signal.signal(signal.SIGINT, terminated)
    signal.signal(signal.SIGTERM, terminated)
    signal.signal(signal.SIGHUP, terminated)

    def run(prompt):
        nonlocal conversation
        if args.harness == 'hermes':
            command = ['hermes', 'chat', '--cli', '--oneshot', '-Q', '--yolo',
                       '--continue', session, '--create-if-missing',
                       '--no-restore-cwd', '--query-file', '-']
            if args.effort:
                command += ['--reasoning', args.effort]
            payload = prompt
        else:
            text = prompt if conversation or prompt == brief else brief.rstrip() + '\n\n' + prompt
            command = ['agy', '--print', text, '--output-format', 'json',
                       '--print-timeout', ANTIGRAVITY_PRINT_TIMEOUT,
                       '--dangerously-skip-permissions']
            if conversation:
                command += ['--conversation', conversation]
            if args.effort:
                command += ['--effort', args.effort]
            payload = ''
        if args.model:
            command += ['--model', args.model]
        process = None
        output_file = tempfile.TemporaryFile()
        error_file = tempfile.TemporaryFile()
        try:
            event('busy', 'turn-start')
            print('Firstmate worker running', flush=True)
            with deferred():
                process = subprocess.Popen(command, stdin=subprocess.PIPE,
                    stdout=output_file, stderr=error_file, text=True,
                    env=env, start_new_session=True)
            process.communicate(payload)
            with uninterrupted():
                terminate(process)
                output_file.seek(0)
                raw_output = output_file.read(PROTOCOL_LIMIT + 1)
                output_overflow = len(raw_output) > PROTOCOL_LIMIT
                output = raw_output[:PROTOCOL_LIMIT].decode(errors='replace')
                # Both CLIs write their turn markers last, so keep the tail.
                error_size = error_file.seek(0, os.SEEK_END)
                error_overflow = error_size > PROTOCOL_LIMIT
                error_file.seek(max(error_size - PROTOCOL_LIMIT, 0))
                errors = error_file.read().decode(errors='replace')
                if errors:
                    print(errors, flush=True)
                if error_overflow:
                    print('CLI diagnostics exceeded the 1 MiB protocol limit; showing the last 1 MiB', flush=True)
                if output_overflow:
                    print('CLI output exceeded the 1 MiB protocol limit', flush=True)
                success = process.returncode == 0 and not output_overflow
                if args.harness == 'hermes':
                    success = success and bool(re.search(r'^session_id: \S+$', errors, re.M)) and bool(output.strip())
                if args.harness == 'antigravity' and success:
                    success, response = antigravity_result(output)
                    print(response, flush=True)
                    success = success and ANTIGRAVITY_TRUNCATION_NOTE not in errors
                else:
                    print(output, flush=True)
                if not success:
                    with (state / (args.id + '.status')).open('a') as status:
                        status.write('blocked: ' + args.harness + ' worker turn failed; inspect endpoint output\n')
                    print('Firstmate worker turn failed', flush=True)
                event('idle', 'turn-end' if success else 'turn-failed')
                # Apply rejects stale generations before we emit the completion wake.
                (state / (args.id + '.turn-ended')).touch()
        except KeyboardInterrupt:
            with uninterrupted():
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
                (state / (args.id + '.turn-ended')).touch()
                print('\nFirstmate worker cancelled', flush=True)
        except (OSError, ValueError) as error:
            print('Firstmate worker error: ' + str(error), flush=True)
            event('unknown', 'turn-error')
            raise
        finally:
            terminate(process)
            output_file.close()
            error_file.close()

    run(brief)
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
        if prompt == '/exit':
            break
        if prompt.strip():
            run(prompt)


if __name__ == '__main__':
    main()
