#!/usr/bin/env python3
"""Append redacted captain messages from Claude JSONL transcripts."""
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from collections import Counter

MAX_TEXT = 4000
WRAPPERS = {
    'main_dialog_mirror': re.compile(r'(?i)main dialog mirror'),
    'compaction_summary': re.compile(r'(?i)summarized conversation'),
    'artifact_content': re.compile(r'(?i)<artifact-content(?:-[a-z0-9_-]+)?\s*/?>|artifact-content wrapper'),
    'supervision_wake': re.compile(r'(?i)firstmate supervision wake'),
    'operational_inbox': re.compile(r'(?i)firstmate operational inbox message'),
    'instruction_waiting': re.compile(r'(?i)firstmate instruction waiting'),
    'stop_hook_wake': re.compile(r'(?im)^\s*stop[- ]hook(?: wake)?'),
    'watcher_wake': re.compile(r'(?im)^\s*watcher[- ]wake|^\s*watcher wake'),
}
BLOCKS = re.compile(r'(?is)<(system-reminder|firstmate-instruction|firstmate-operational-input|pasted_content|cross-session-message|task-notification)>.*?</\1>')
XML_STYLE_TAG = re.compile(r'<((?:task|system|command)-[A-Za-z0-9_-]+|local-command(?:-[A-Za-z0-9_-]+)?|bash-[A-Za-z0-9_-]+|user-prompt(?:-[A-Za-z0-9_-]+)?)\b[^>]*>', re.I)
INJECTED_LINE = re.compile(r'(?i)(?:^|\s)(?:system:|hook:|notification:|firstmate instruction waiting|firstmate operational input)\b')


def redact(text):
    patterns = [
        r'(?i)\b(?:pin|passcode|password|passwd|token|api[_ -]?key|secret|key|credential|code|pairing code|sign[- ]?in code|verification code)\b\s*[:=]\s*\S+',
        r'(?i)\b(?:pin|passcode|password|passwd|token|api[_ -]?key|secret|key|credential|code|pairing code|sign[- ]?in code|verification code)\b\s+is\s+\S+',
        r'(?i)\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|Bearer\s+\S+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|[A-Fa-f0-9]{32,}|[A-Za-z0-9+/]{40,}={0,2})',
        r'(?i)\b\d{4,8}\b',
    ]
    for pattern in patterns:
        text = re.sub(pattern, '[redacted]', text)
    return text


def extract_text(content):
    if isinstance(content, str):
        return content, False
    if isinstance(content, list):
        has_tools = any(isinstance(item, dict) and item.get('type') == 'tool_result' for item in content)
        return '\n'.join(str(item.get('text', '')) for item in content if isinstance(item, dict) and item.get('type') == 'text'), has_tools
    return '', False


def clean(text):
    hits = [name for name, pattern in WRAPPERS.items() if pattern.search(text)]
    if hits:
        positions = [WRAPPERS[name].search(text).start() for name in hits]
        text = text[:min(positions)]
    block_hits = Counter()
    def remove_block(match):
        block_hits[f'injected_{match.group(1).lower()}'] += 1
        return ''
    text = BLOCKS.sub(remove_block, text)
    xml_hits = Counter()
    while match := XML_STYLE_TAG.search(text):
        tag = match.group(1)
        self_closing = match.group(0).rstrip().endswith('/>')
        close = re.search(r'</' + re.escape(tag) + r'\s*>', text[match.end():], re.I) if not self_closing else None
        end = match.end() if self_closing else match.end() + close.end() if close else len(text)
        xml_hits[f'xml_{tag.lower()}'] += 1
        text = text[:match.start()] + ' ' + text[end:]
    line_count = 0
    line_drops = Counter()
    kept = []
    for line in text.splitlines():
        match = INJECTED_LINE.search(line)
        if match:
            line_count += 1
            line = line[:match.start()].strip()
        line = line.strip()
        if not line:
            continue
        if line.lower().startswith(('reminder', '<system-reminder', '<firstmate')):
            line_drops['injected_line_wrapper'] += 1
            continue
        if line.startswith('/'):
            line_drops['slash_command'] += 1
            continue
        kept.append(line)
    return ' '.join(kept), hits, block_hits, xml_hits, line_count, line_drops


def main():
    home = Path(os.environ.get('FM_HOME', str(Path.home() / 'firstmate'))).resolve()
    transcript_default = Path.home() / '.claude/projects/-home-umer-firstmate'
    transcripts = Path(os.environ.get('CHAT_TSV_TRANSCRIPTS', str(transcript_default)))
    dest, sidecar = home / 'data/chat.tsv', home / 'data/chat.tsv.seen'
    if len(sys.argv) not in (1, 3):
        raise SystemExit('usage: chat-tsv.py [YYYY-MM-DD YYYY-MM-DD]')
    start = dt.date.fromisoformat(sys.argv[1]) if len(sys.argv) == 3 else None
    end = dt.date.fromisoformat(sys.argv[2]) if len(sys.argv) == 3 else None
    if not transcripts.is_dir():
        raise SystemExit(f'transcripts directory missing: {transcripts}')
    if subprocess.run(['git', '-C', str(home), 'check-ignore', '-q', str(dest)], check=False).returncode:
        raise SystemExit(f'refusing: {dest} is not gitignored')
    data = dest.parent
    data.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(data, 0o700)
    seen = set(sidecar.read_text().splitlines()) if sidecar.exists() else set()
    drops, rows, ids = Counter(), [], []
    for file in sorted(transcripts.glob('*.jsonl')):
        for raw in file.read_text(errors='replace').splitlines():
            try:
                rec = json.loads(raw)
            except ValueError:
                drops['malformed_json'] += 1
                continue
            if rec.get('type') != 'user':
                drops['not_user'] += 1
                continue
            if rec.get('isMeta'):
                drops['metadata'] += 1
                continue
            if rec.get('isSidechain'):
                drops['sidechain'] += 1
                continue
            msg = rec.get('message', {})
            if not isinstance(msg, dict) or msg.get('role') != 'user':
                drops['not_user_message'] += 1
                continue
            uid = msg.get('id') or rec.get('uuid')
            if not uid:
                drops['missing_uuid'] += 1
                continue
            if uid in seen:
                drops['already_written'] += 1
                continue
            try:
                stamp = dt.datetime.fromisoformat(rec['timestamp'].replace('Z', '+00:00')).astimezone(dt.timezone.utc)
            except (ValueError, TypeError, KeyError, AttributeError):
                drops['bad_timestamp'] += 1
                continue
            if start and not start <= stamp.date() <= end:
                drops['outside_date_range'] += 1
                continue
            content, has_tools = extract_text(msg.get('content'))
            if has_tools:
                drops['tool_content'] += 1
            body, hits, block_hits, xml_hits, line_count, line_drops = clean(content)
            for hit in hits:
                drops[hit] += 1
            drops.update(block_hits)
            drops.update(xml_hits)
            drops.update(line_drops)
            if line_count:
                drops['injected_line'] += line_count
            if not body:
                drops['injected_only' if hits or block_hits or xml_hits or line_drops or line_count else 'empty_content'] += 1
                continue
            if not any(char.isalnum() for char in body):
                drops['punctuation_only'] += 1
                continue
            if re.match(r'(?i)^(system|hook|notification|firstmate instruction waiting|firstmate operational input|local-command|/\w+)', body):
                drops['command_or_injected_envelope'] += 1
                continue
            cwd = rec.get('cwd', '')
            work = Path(cwd).name if cwd and Path(cwd).name not in ('firstmate', '') else 'main'
            text = redact(body).replace('\t', ' ').replace('\n', ' ')
            if len(text) > MAX_TEXT:
                text = text[:MAX_TEXT - len('[truncated]')] + '[truncated]'
                drops['truncated'] += 1
            rows.append((stamp.isoformat().replace('+00:00', 'Z'), work, text))
            ids.append(uid)
            seen.add(uid)
    with dest.open('a', encoding='utf-8') as out:
        for row in rows:
            out.write('\t'.join(row) + '\n')
    os.chmod(dest, 0o600)
    with sidecar.open('a', encoding='utf-8') as out:
        for uid in ids:
            out.write(uid + '\n')
    os.chmod(sidecar, 0o600)
    summary = ', '.join(f'{key}={value}' for key, value in sorted(drops.items())) or 'none'
    print(f'appended={len(rows)} drops={summary}', file=sys.stderr)


if __name__ == '__main__':
    main()
