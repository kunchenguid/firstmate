#!/usr/bin/env python3
"""Owner asks: add ID QUESTION [URL] --owner-must CLASS --about WHAT --why NOW
--already DONE --option LABEL=OUTCOME (2-3) --recommend LABEL --reason WHY
--default LABEL. list/done ID maintain the ask list; post ID KEY CLOSE is the
hold bridge. Only authored owner asks can be posted; backlog prose is never used.
Install after merge: install HOME writes HOME/config/fm-captain-ask.sh as a shim.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def require(ok, message):
    if not ok:
        raise ValueError(message)


def validate(card):
    require(card['owner_must'] in ('login', '2fa', 'physical-grant', 'own-device-test', 'destructive-ok'),
            'only login, 2fa, physical-grant, own-device-test or destructive-ok needs the owner; other calls stay with the team')
    text = card['question']
    require(text.endswith('?') and text.count('?') == 1 and len(text.split()) <= 12,
            'write one question, 12 words or fewer')
    require(len(card['context']) == 3, 'give what it is, why now, and what is already done')
    require(len('\n'.join(card['context'])) <= 200, 'the three context lines must fit 200 characters together')
    options = card['options']
    require(2 <= len(options) <= 3, 'give two or three choices')
    labels, outcomes = zip(*options)
    require(all(re.fullmatch(r'[A-Za-z][A-Za-z0-9-]{0,39}', label) for label in labels), 'use short, single-word choice labels')
    require(len({s.casefold() for s in labels}) == len(labels), 'choice labels must differ')
    require(card['recommend'] in labels and card['default'] in labels, 'recommend and default must name a choice')
    prose = [text, *card['context'], card['reason'], *labels, *outcomes]
    internal = r'\[[^\]]+\]|\bMain\d+\b|(?:~?/|\b[\w.-]+/)[\w./-]+|\b[\w-]+\.(?:md|sh|json|tsx?|py|log)\b|\b(?:fm|task|ask)-[\w-]+|\b[a-z][a-z0-9]*(?:-[a-z0-9]+){2,}\b|\b(?:captain|Main|lead|secondmate|crewmate|backlog|lane|worker|CLI|reconcile|hold|held)\b'
    for value in prose:
        require(isinstance(value, str) and value.strip() and len(value) <= 200 and not re.search(r'[\r\n\t|]', value),
                'each text field must be one short line, at most 200 characters, without tabs or |')
        require(not re.search(internal, value, re.I) and not re.search(r'(?<!\w)' + re.escape(card['id']) + r'(?!\w)', value, re.I),
                'use plain words: remove tags, message/task ids, paths and team machinery')
    normalized = [re.sub(r'\W+', ' ', re.sub(r'^(?:your (?:yes|no) is recorded and |(?:yes|no)\W+)', '', s.casefold())).strip() for s in outcomes]
    require(len(set(normalized)) == len(normalized), 'each choice must have a distinct outcome')
    require(all(len(s) <= 120 for s in outcomes), 'choice outcomes must fit 120 characters')
    require(len(card['reason']) <= 160, 'recommendation reason must fit 160 characters')
    return card


def row_for(card, since, url):
    return [card['id'], since, card['question'], url, '|'.join(o[0] for o in card['options']),
            card['recommend'], ' '.join(card['context']), '|'.join(o[1] for o in card['options']),
            card['reason'], card['default']]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('add', 'done', 'list', 'post', 'install'))
    parser.add_argument('id', nargs='?')
    parser.add_argument('text', nargs='?', default='')
    parser.add_argument('url', nargs='?', default='')
    for flag in ('owner-must', 'about', 'why', 'already', 'recommend', 'reason', 'default'):
        parser.add_argument('--' + flag, default='')
    parser.add_argument('--option', action='append', default=[])
    args = parser.parse_args()
    if args.command == 'install':
        target = Path(args.id) / 'config/fm-captain-ask.sh'
        require(target.parent.is_dir(), 'the home must already have a config directory')
        import shlex
        target.write_text('#!/bin/sh\nexec python3 ' + shlex.quote(str(Path(__file__).resolve())) + ' "$@"\n')
        target.chmod(0o755)
        return
    require(bool(os.environ.get('FM_HOME')), 'set FM_HOME to the home that owns the ask')
    path = Path(os.environ['FM_HOME']) / 'data/captain-asks.tsv'
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(str(path) + '.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = [line.split('\t') for line in path.read_text().splitlines()] if path.exists() else []
        if args.command == 'list':
            print('\n'.join('\t'.join(row) for row in rows), end='\n' if rows else '')
            return
        require(bool(args.id) and re.fullmatch(r'[A-Za-z0-9._-]+', args.id), 'give a plain ask id')
        old = next((row for row in rows if row[0] == args.id), None)
        record = path.parent / 'captain-ask-cards' / (args.id + '.json')
        if args.command == 'post':
            require(old is not None and len(old) == 10 and record.is_file(), 'no authored owner ask; keep this call with the team or author the owner question first')
            card = validate(json.loads(record.read_text()))
            require(old == row_for(card, old[1], old[3]), 'authored ask differs from the list; author it again')
            require(card['id'] == args.id and args.url in ('done', 'release'), 'ask identity or close mode differs')
            command = ['sign-off-axi', 'raise', '--key', args.text, '--ask-ref', args.id,
                       '--title', card['question'], '--about', '\n'.join(card['context']), '--why', '\n'.join(card['context']),
                       '--close', args.url, '--recommend', card['recommend'].lower(),
                       '--recommend-reason', card['reason'], '--default', card['default'].lower()]
            for label, outcome in card['options']:
                command += ['--option', label.lower() + '=' + label, '--outcome', label.lower() + '=' + outcome]
            subprocess.run(command, check=True)
            return
        if args.command == 'add':
            require(all('=' in option for option in args.option), 'each option needs Label=outcome')
            card = validate(dict(id=args.id, owner_must=args.owner_must, question=args.text,
                                 context=[args.about, args.why, args.already], options=[o.split('=', 1) for o in args.option],
                                 recommend=args.recommend, reason=args.reason, default=args.default))
            require(not args.url or args.url.startswith(('https://', 'http://')), 'URL must be a web link, never a file path')
            require(not re.search(r'[\t\r\n]', args.url), 'URL must be one field')
            row = row_for(card, old[1] if old else str(int(time.time())), args.url)
            record.parent.mkdir(exist_ok=True)
            staged = record.with_suffix('.json.tmp')
            staged.write_text(json.dumps(card))
            staged.replace(record)
        else:
            require(old is not None, 'no open ask with that id')
        rows = [r for r in rows if r[0] != args.id] + ([row] if args.command == 'add' else [])
        temporary = path.with_suffix('.tsv.tmp')
        temporary.write_text(''.join('\t'.join(r) + '\n' for r in rows))
        temporary.replace(path)
        if args.command == 'done':
            record.unlink(missing_ok=True)


try:
    main()
except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
    sys.exit('owner ask refused: ' + str(error))
