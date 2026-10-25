#!/usr/bin/env python3
"""Record one task's ticket truth on the fleet board now, from a lifecycle step.

Usage: ticket.py <task> [--stage WORD] [--state WORD] [--pr URL] [--release TEXT]

FM_HOME names the home whose config/fleet-board owns this task, and the task is
its backlog item id, published as the ticket for main/<task> (the sync's own
home name, bin/fm-watch.sh's check environment included).

Nothing is written when this home has no fleet board, when the board file is
missing, or when the sync has not published that ticket yet: the poll owns
creating tickets along with their title, parent and ask, and this writer only
corrects a ticket that already exists, so a merge or a cleanup never invents a
half ticket. Only fields that differ from the board's are written, so a repeated
lifecycle step appends nothing; state done also sets progress 100, because the
sync's own completion rule does.

last-event-at is not written here: lane.py derives it from the lane's own status
stamps and the next poll owns it, so a writer-supplied time would only make the
poll rewrite the row once.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess as sp
import sys
import os

STAGES = ('queued', 'building', 'review', 'merging', 'done')
STATES = ('queued', 'in progress', 'on hold', 'done')


def die(message):
    print('ticket: ' + message, file=sys.stderr)
    return 1


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('task')
    parser.add_argument('--stage', choices=STAGES)
    parser.add_argument('--state', choices=STATES)
    parser.add_argument('--pr', default=None, help='the delivered PR URL, or "" to clear it')
    parser.add_argument('--release', default=None, help='the target release, up to 40 characters')
    options = parser.parse_args(argv)
    if not options.task or '/' in options.task:
        return die('task must be one backlog item id')
    if (options.stage, options.state, options.pr, options.release) == (None, None, None, None):
        return die('nothing to record: pass --stage, --state, --pr or --release')
    home = Path(os.environ.get('FM_HOME') or '.').resolve()
    pointer = home / 'config/fleet-board'
    if not pointer.exists():
        return 0
    board = Path(pointer.read_text().strip() or '.')
    if not board.is_absolute():
        board = home / board
    if not board.is_file():
        return 0
    ticket_id = 'fm-' + hashlib.sha256(f'main/{options.task}'.encode()).hexdigest()[:32]
    try:
        read = sp.run(['sign-off-axi', 'ticket', str(board), '--id', ticket_id, '--json'],
                      text=True, capture_output=True, timeout=60)
    except (OSError, sp.TimeoutExpired) as error:
        return die(f'{error}')
    if read.returncode:
        answer = read.stderr + read.stdout
        if 'code: NOT_FOUND' in answer:
            return 0  # the poll has not published this task yet; it owns creating the ticket
        return die(answer.strip() or 'sign-off-axi could not read the board')
    try:
        ticket = (json.loads(read.stdout or '{}') or {}).get('ticket')
    except ValueError:
        return die('unreadable board answer for ' + ticket_id)
    if not ticket:
        return 0
    wanted = {'stage': options.stage, 'state': options.state,
              'pr': options.pr, 'release': options.release}
    write = {}
    for key, value in wanted.items():
        if value is None:
            continue
        stored = ticket.get('prs' if key == 'pr' else key)
        if key == 'pr':
            if list(stored or []) != ([value] if value else []):
                write[key] = value
        elif (stored or '') != value:
            write[key] = value
    if options.state == 'done' and ticket.get('progress') != 100:
        write['progress'] = '100'
    if not write:
        return 0
    command = ['sign-off-axi', 'ticket', str(board), '--id', ticket_id]
    for key, value in write.items():
        command += ['--' + key, value]
    try:
        wrote = sp.run(command, text=True, capture_output=True, timeout=60)
    except (OSError, sp.TimeoutExpired) as error:
        return die(f'{error}')
    if wrote.returncode:
        return die((wrote.stderr or wrote.stdout).strip() or 'sign-off-axi could not write the ticket')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
