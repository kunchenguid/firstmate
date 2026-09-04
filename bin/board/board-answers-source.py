#!/usr/bin/env python3
"""Non-destructive, bounded answer-burst source; capture acknowledgement owns cursor.

Usage: board-answers-source.py [--config PATH]
Paths come from FM_HOME and board config; schema is owned by fm-board.py.
One atomic exporter publication gives one packet, up to 50 answers. A result
contains prefix hashes and byte offsets, plus the original JSONL records.
Cursor never advances here: a killed source can produce the same bytes again.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import time


def module():
    spec = importlib.util.spec_from_file_location('fm_board', Path(__file__).resolve().parents[1] / 'fm-board.py')
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config')
    args = p.parse_args()
    os.umask(0o077)
    m = module()
    b = m.Board(args.config)
    inbox = b.state / 'board-inbox'
    log = inbox / 'answers.jsonl'
    cursor = inbox / 'answers.cursor'
    while True:
        offset, prefix = 0, hashlib.sha256(b'').hexdigest()
        data = log.read_bytes() if log.exists() else b''
        if cursor.exists():
            saved = json.loads(cursor.read_text())
            if type(saved) is int:
                offset = saved
                if offset < 0 or offset > len(data):
                    raise m.Invalid('legacy cursor is outside the answer log')
                prefix = hashlib.sha256(data[:offset]).hexdigest()
            else:
                offset, prefix = saved['offset'], saved['prefix']
        if len(data) < offset or hashlib.sha256(data[:offset]).hexdigest() != prefix:
            raise m.Invalid('answer log continuity lost; preserve cursor and inspect')
        chunk = b''.join(data[offset:].splitlines(keepends=True)[:50])
        if chunk and chunk.endswith(b'\n'):
            records = [json.loads(line) for line in chunk.splitlines()]
            end = offset + len(chunk)
            print(json.dumps(dict(schema='board-answers.v1',config=str(b.config_path),source_id=b.source_id,
                start=offset,end=end,start_prefix=prefix,prefix=hashlib.sha256(data[:end]).hexdigest(),answers=records)),flush=True)
            return
        time.sleep(0.25)


if __name__ == '__main__':
    try:
        main()
    except (OSError,ValueError,KeyError) as e:
        print(json.dumps({'schema':'board-answers.error','error':str(e)}),flush=True)
        sys.exit(1)
