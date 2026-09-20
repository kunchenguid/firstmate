#!/usr/bin/env python3
import fcntl
import json
import hashlib
import re
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def write(path, value):
    temporary = path.with_suffix(f'.tmp.{os.getpid()}')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def evaluate(root):
    cases = [json.loads(path.read_text()) for path in (root / 'cases').glob('*.json')]
    previous = json.loads((root / 'evaluation.json').read_text()) if (root / 'evaluation.json').exists() else {}
    outcomes = [set(case['comparison_label'].split(',')) for case in cases]
    labels = [label for outcome in outcomes for label in outcome]
    reasons = set(previous.get('stop_reasons', []))
    reasons.update(label for label in labels if label in {'incorrect', 'p2-exposure', 'launch-changed', 'roster-omission'})
    errors = sum(case['status'] == 'error' for case in cases)
    latencies = sorted(case['latency_ms'] for case in cases)
    p95 = latencies[math.ceil(len(latencies) * .95) - 1] if latencies else 0
    complete = len(cases) == 20 and not any(case['status'] == 'pending' for case in cases)
    reviewed = complete and all(
        len(outcome & {'correct', 'caught', 'missed', 'no-fit'}) == 1
        and not outcome & {'unlabeled', 'unknown'} for outcome in outcomes)
    if complete:
        if errors > 1:
            reasons.add('timeouts-or-invalid')
        if p95 >= 2000:
            reasons.add('latency-target')
        if labels.count('irrelevant') > 1:
            reasons.add('irrelevant-suggestions')
    if reviewed:
        if labels.count('caught') <= labels.count('missed'):
            reasons.add('coverage-not-better')
        if labels.count('caught') < 2 and labels.count('irrelevant') > 0:
            reasons.add('insufficient-useful-discoveries')
    result = {'status': 'stopped' if reasons else ('evaluated' if reviewed else ('review-required' if len(cases) >= 20 else 'collecting')),
              'cases': len(cases), 'stop_reasons': sorted(reasons), 'p95_ms': p95,
              'errors': errors, 'caught': labels.count('caught'), 'missed': labels.count('missed'),
              'irrelevant': labels.count('irrelevant')}
    write(root / 'evaluation.json', result)
    return result


def catalog(home, directories):
    approval = Path(home) / 'config' / 'jev-skill-public.json'
    if not approval.exists():
        print('[]')
        return
    approved = json.loads(approval.read_text())
    if not isinstance(approved, list) or not all(isinstance(value, str) for value in approved):
        raise ValueError('public approval must be a digest array')
    approved = set(approved)
    user_home = Path.home()
    roots = {str(user_home / item) for item in ('.agents/skills', '.claude/skills', '.grok/skills', '.pi/agent/skills')}
    roots.add(str(Path(os.environ.get('CODEX_HOME') or user_home / '.codex') / 'skills'))
    excluded = {'none', 'search_external', 'afk', 'quiet', 'ahoy', 'bearings', 'orchestrated-delivery',
                'harness-adapters', 'project-management', 'diagnostic-reasoning', 'ask-user-authority',
                'quota-array-dispatch'}
    prefixes = ('firstmate-', 'captain-', 'secondmate-', 'bootstrap-', 'stuck-', 'process-event-', 'fmx-')
    result = {}
    for directory in directories:
        if directory not in roots:
            continue
        for path in sorted(Path(directory).glob('*/SKILL.md')):
            skill = path.parent.name
            if skill in result or skill in excluded or skill.startswith(prefixes) or not re.fullmatch(r'[A-Za-z0-9._:-]+', skill):
                continue
            try:
                data = path.read_bytes()
            except OSError:
                continue
            if hashlib.sha256(data).hexdigest() not in approved:
                continue
            content = data.decode('utf-8')
            parts = re.split(r'^---\s*$', content, maxsplit=2, flags=re.MULTILINE)
            if len(parts) != 3 or parts[0].strip():
                continue
            front, body = parts[1:]
            if re.search(r'^\s+internal:\s*true\s*$', front, re.MULTILINE):
                continue
            match = re.search(r'^description:[ \t]*(.*(?:\n[ \t]+[^\n]+)*)', front, re.MULTILINE)
            if not match:
                continue
            description = match[1].strip()
            if description.startswith(('>-', '>', '|')):
                description = description.lstrip('>|-').strip()
            description = ' '.join(description.split())
            if re.search(r'\b(firstmate|supervisor|captain|secondmate|no-mistakes|treehouse|merge authority)\b', description, re.IGNORECASE):
                continue
            if description:
                result[skill] = {'id': skill, 'description': description, 'excerpt': body.replace('\n', ' ').replace('\r', ' ')[:700]}
    print(json.dumps(sorted(result.values(), key=lambda item: item['id'])))


def main():
    started = time.monotonic()
    home, launch, label, selector, *arguments = sys.argv[1:]
    if not launch:
        raise ValueError('originating launch ID is required')
    root = Path(home) / 'state' / 'jev-skill-shadow'
    (root / 'cases').mkdir(parents=True, exist_ok=True)
    path = root / 'cases' / f'{launch}.json'
    with (root / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if path.exists():
            record = json.loads(path.read_text())
            if label != 'unlabeled':
                if record['status'] == 'pending':
                    raise ValueError('cannot label an unfinished launch')
                record['comparison_label'] = label
                write(path, record)
            evaluate(root)
            print(json.dumps(record, indent=2))
            return
        if label != 'unlabeled':
            raise ValueError('comparison labels require an existing launch ID')
        checkpoint = evaluate(root)
        if checkpoint['status'] != 'collecting':
            print(json.dumps(checkpoint))
            return
        record = {'version': 2, 'experiment_id': launch, 'roster_hash': None, 'request_hash': None,
                  'resolved_model': None, 'status': 'pending', 'decisions': {},
                  'latency_ms': 0, 'token_totals': {'input_tokens': 0, 'output_tokens': 0},
                  'comparison_label': 'unlabeled', 'reason': 'reserved', 'shadow': True}
        write(path, record)
    environment = dict(os.environ, FM_JEV_SHADOW_CHILD='1')
    process = subprocess.Popen([selector, *arguments, '--launch-id', launch], env=environment,
                               stdout=subprocess.DEVNULL, start_new_session=True)
    timed_out = False
    try:
        process.wait(timeout=max(.001, 5.7 - (time.monotonic() - started)))
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    with (root / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = json.loads(path.read_text())
        if not timed_out and process.returncode == 0 and record['reason'] == 'reserved':
            path.unlink()
        else:
            if timed_out or record['status'] == 'pending' or process.returncode != 0:
                record.update(status='error', reason='timeout' if timed_out else 'selector_error')
            record['latency_ms'] = round((time.monotonic() - started) * 1000)
            write(path, record)
            print(json.dumps(record, indent=2))
        evaluate(root)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'catalog':
        catalog(sys.argv[2], sys.argv[3:])
    else:
        main()
