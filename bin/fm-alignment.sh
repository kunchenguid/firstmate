#!/usr/bin/env bash
# Manage private alignment records. Requires python3; uses fm-tasks-axi for links.
# Usage: fm-alignment.sh create <YYYY-MM-DD-slug> <ask-file>
#        fm-alignment.sh link <key> <task-id> <no-mistakes|direct-PR|local-only|scout>
#        fm-alignment.sh delivered <key> <task-id> <evidence>
#        fm-alignment.sh archive <key>
#        fm-alignment.sh validate [--task <task-id> | --intake <task-id> | --ready <key>]
# FM_HOME (else code root), FM_DATA_OVERRIDE and FM_STATE_OVERRIDE select the home.
# create generates spec.md, plan.md and index.md; keys are unique across archives.
# link preserves the work-item body and adds alignment: <key>, plus reciprocal
# item: <id> | <mode> | open | - lines in BOTH spec and plan. Repeating is safe.
# delivered changes those lines to complete with mode-appropriate evidence:
# PR modes: landed https URL; scout: retained path relative to data/;
# local-only: local:<full 40- or 64-hex landing commit>. Record evidence only after
# the existing landing/report guards prove delivery; this is not merge authority
# or a substitute for those guards. It retains a pointer receipt in the spec so
# completed tasks survive backlog pruning. Evidence cannot contain | or newline.
# archive refuses unless every linked item has delivery evidence; moves to
# archive/<today>-<key>/ and refreshes the index. Never archives early.
# validate is read-only (including startup); absent area passes. --ready requires
# aligned spec, approved plan, and at least one linked item. --task checks the
# brief and work-item pointer, its receipt, and archival when all items complete;
# unlinked tasks pass unchanged. Backend read failures are not missing pointers.
# Spec required headings are defined by spec-template.md; plan by plan-template.md.
# decision: Dn references in plans must resolve to unique '- Dn:' spec entries.
# index.md contains '- <key>: <relative directory>/spec.md' for every record.
# One mkdir lock serializes mutations, and atomic replacements publish files.
# Interrupted writes are detected by validation; no automatic repair or approval.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ALIGNMENT_CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export FM_ALIGNMENT_CODE_ROOT
# Preserve legacy completion even on hosts without the optional record tooling.
# Missing records with a surviving pointer must still enter the validator.
if [ "${1:-}" = validate ] && [ "${2:-}" = --task ] && [ $# -eq 3 ]; then
  case "$3" in ''|*[!a-zA-Z0-9_-]*) echo 'ALIGNMENT: invalid task id' >&2; exit 1 ;; esac
  DATA="${FM_DATA_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ALIGNMENT_CODE_ROOT}}/data}"
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
  FM_ALIGNMENT_TASK_BACKEND=$(fm_tasks_axi_backend_resolve "$(dirname "$DATA")") || exit 1
  export FM_ALIGNMENT_TASK_BACKEND
  if [ "$FM_ALIGNMENT_TASK_BACKEND" = markdown ] && [ ! -e "$DATA/alignments" ] && [ ! -L "$DATA/alignments" ]; then
    linked=0
    for record in "$DATA/$3/brief.md" "$DATA/backlog.md"; do
      if [ -e "$record" ] || [ -L "$record" ]; then
        [ -r "$record" ] || { echo "ALIGNMENT: unreadable $record" >&2; exit 1; }
        if grep -q 'alignment:' "$record"; then linked=1; fi
      fi
    done
    [ "$linked" = 1 ] || exit 0
  fi
fi
exec python3 - "$@" <<'PY'
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(os.environ['FM_ALIGNMENT_CODE_ROOT'])
home = Path(os.environ.get('FM_HOME', os.environ.get('FM_ROOT_OVERRIDE', str(root))))
data = Path(os.environ.get('FM_DATA_OVERRIDE', str(home / 'data')))
area = data / 'alignments'
key_re = r'\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*'
id_re = r'[a-zA-Z0-9][a-zA-Z0-9_-]*'
modes = {'no-mistakes', 'direct-PR', 'local-only', 'scout'}

def require(ok, message):
    if not ok:
        raise ValueError(message)

def safe(path):
    require(not path.is_symlink(), f'symlink refused: {path}')
    for parent in path.parents:
        require(not parent.is_symlink(), f'symlink ancestor refused: {parent}')
    return path

def text(path):
    return safe(path).read_text()

def put(path, body):
    safe(path)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.alignment-')
    try:
        with os.fdopen(fd, 'w') as out:
            out.write(body)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)

def valid_key(key):
    require(re.fullmatch(key_re, key), f'malformed key: {key}')
    datetime.date.fromisoformat(key[:10])

def scalar(body, field):
    values = re.findall(r'^' + re.escape(field) + r': (.*)$', body, re.M)
    require(len(values) == 1, f'exactly one {field}: line required')
    return values[0]

def pointer(body):
    values = re.findall(r'^alignment:[ \t]*(.*)$', body, re.M)
    require(len(values) <= 1, 'duplicate alignment pointer')
    if values:
        valid_key(values[0])
        return values[0]
    return None

def records():
    if not area.exists():
        return {}
    safe(area)
    found = {}
    directories = [p for p in area.iterdir() if p.name not in ('archive', 'index.md', '.lock')]
    archive = area / 'archive'
    if archive.exists():
        safe(archive)
        directories += list(archive.iterdir())
    for path in directories:
        require(path.is_dir(), f'unexpected alignment artifact: {path}')
        body = text(path / 'spec.md')
        key = scalar(body, 'key')
        valid_key(key)
        expected = path.name if path.parent == area else path.name[11:]
        require(expected == key, f'folder/key mismatch: {path}')
        if path.parent != area:
            datetime.date.fromisoformat(path.name[:10])
            require(path.name[10:11] == '-', f'malformed archive folder: {path}')
        require(key not in found, f'duplicate key: {key}')
        found[key] = path
    return found

def locate(key):
    valid_key(key)
    found = records()
    require(key in found, f'missing alignment: {key}')
    return found[key]

def index_body():
    return '# Alignment index\n\n' + ''.join(
        f'- {key}: {path.relative_to(area)}/spec.md\n' for key, path in sorted(records().items()))

def refresh():
    put(area / 'index.md', index_body())

def task_body(task):
    require(re.fullmatch(id_re, task), 'invalid task id')
    result = subprocess.run([str(root / 'bin/fm-tasks-axi.sh'), 'show', task, '--full'],
                            capture_output=True, text=True, timeout=30)
    require(result.returncode == 0, f'cannot read work item {task}: {result.stderr.strip()}')
    values = re.findall(r'^  body: (.*)$', result.stdout, re.M)
    require(len(values) == 1, f'cannot decode work item {task}')
    return json.loads(values[0]) if values[0].startswith('"') else values[0]

def items(body):
    result = {}
    for line in body.splitlines():
        if not line.startswith('item:'):
            continue
        parts = line[5:].strip().split(' | ')
        require(len(parts) == 4, f'malformed item: {line}')
        task, mode, status, evidence = parts
        require(re.fullmatch(id_re, task) and task not in result, f'invalid/duplicate item: {task}')
        require(mode in modes and status in ('open', 'complete'), f'invalid item: {line}')
        require(status != 'open' or evidence == '-', f'open item has evidence: {task}')
        if status == 'complete':
            evidence_valid(mode, evidence)
        result[task] = (mode, status, evidence)
    return result

def evidence_valid(mode, evidence):
    require('\n' not in evidence and '|' not in evidence, 'malformed evidence')
    if mode in ('no-mistakes', 'direct-PR'):
        require(re.fullmatch(r'https://[^\s/]+/[^\s]+', evidence), 'landed PR URL required')
    elif mode == 'local-only':
        require(re.fullmatch(r'local:(?:[0-9a-f]{40}|[0-9a-f]{64})', evidence), 'full local landing commit required')
    else:
        path = Path(evidence)
        require(not path.is_absolute() and '..' not in path.parts, 'report must be relative to data/')
        require(safe(data / path).is_file(), f'missing retained report: {evidence}')

def validate_record(key, path, ready=False):
    spec, plan = text(path / 'spec.md'), text(path / 'plan.md')
    require(scalar(spec, 'key') == key and scalar(plan, 'key') == key, 'key mismatch')
    require(scalar(spec, 'plan') == 'plan.md' and scalar(plan, 'spec') == 'spec.md', 'broken spec/plan link')
    for body, template in ((spec, root / '.agents/skills/align-intake/spec-template.md'),
                           (plan, root / '.agents/skills/plan-breakdown/plan-template.md')):
        for heading in re.findall(r'^## .+$', text(template), re.M):
            require(heading in body.splitlines(), f'missing section {heading} in {path}')
    decisions = re.findall(r'^- (D[1-9][0-9]*):', spec, re.M)
    require(len(decisions) == len(set(decisions)), 'duplicate decision id')
    for decision in re.findall(r'^decision: (.*)$', plan, re.M):
        require(decision in decisions, f'unresolved decision: {decision}')
    linked = items(spec)
    require(linked == items(plan), 'spec/plan work-item links disagree')
    for task, (_, status, _) in linked.items():
        if status == 'open':
            require(pointer(task_body(task)) == key, f'missing work-item pointer: {task}')
        else:
            require(f'receipt: {task} alignment: {key}' in spec.splitlines(), f'missing pointer receipt: {task}')
    if path.parent != area:
        require(linked and all(row[1] == 'complete' for row in linked.values()), 'archive contains unfinished items')
    if ready:
        require(scalar(spec, 'status') == 'aligned', 'spec is not aligned')
        require(scalar(plan, 'status') == 'approved', 'plan is not approved')
        require(linked, 'no linked work items')
    return linked

def task_pointer(task):
    require(re.fullmatch(id_re, task), 'invalid task id')
    brief = data / task / 'brief.md'
    from_brief = pointer(text(brief)) if brief.exists() else None
    # Backlog-less historical homes remain unchanged; an existing backlog must
    # be readable, not mistaken for an absent pointer on tool/backend failure.
    backlog = data / 'backlog.md'
    may_have_pointer = ((backlog.exists() and 'alignment:' in text(backlog)) or area.exists()
                        or os.environ.get('FM_ALIGNMENT_TASK_BACKEND', 'markdown') != 'markdown')
    from_item = pointer(task_body(task)) if may_have_pointer or from_brief else None
    require(not from_brief or from_brief == from_item, 'brief/work-item pointer mismatch')
    return from_item or from_brief

def validate(args):
    require(not args or (len(args) == 2 and args[0] in ('--task', '--intake', '--ready')), 'invalid validate arguments')
    if args and args[0] in ('--task', '--intake'):
        task = args[1]
        key = task_pointer(task)
        if key is None:
            return
        path = locate(key)
        linked = validate_record(key, path, ready=True)
        require(text(area / 'index.md') == index_body(), 'broken alignment index')
        require(task in linked, f'task is not linked from alignment: {task}')
        state = Path(os.environ.get('FM_STATE_OVERRIDE', str(home / 'state')))
        meta = state / f'{task}.meta'
        if meta.exists():
            fields = dict(line.split('=', 1) for line in text(meta).splitlines() if '=' in line)
            mode = 'scout' if fields.get('kind') == 'scout' else fields.get('mode')
            require(mode == linked[task][0], 'delivery mode differs from task record')
        if args[0] == '--intake':
            require(linked[task][1] == 'open' and path.parent == area, 'task already delivered or archived')
            return
        require(linked[task][1] == 'complete', f'missing delivery evidence: {task}')
        if all(row[1] == 'complete' for row in linked.values()):
            require(path.parent != area, f'archive completed alignment before completion: {key}')
    elif args:
        validate_record(args[1], locate(args[1]), ready=True)
    else:
        for key, path in records().items():
            validate_record(key, path)
        if area.exists():
            require(text(area / 'index.md') == index_body(), 'missing, stale, or broken alignment index')
        # Detect misplaced alignment specs without classifying ordinary reports.
        if data.exists():
            for name in ('spec.md', 'plan.md'):
                for path in data.rglob(name):
                    if area not in path.parents and re.search(r'^key: ' + key_re + '$', text(path), re.M):
                        raise ValueError(f'alignment record outside dedicated area: {path}')

def main(args):
    require(args, 'command required; see --help')
    command, *args = args
    if command in ('--help', '-h'):
        for line in (root / 'bin/fm-alignment.sh').read_text().splitlines()[1:]:
            if not line.startswith('#'):
                break
            print(line[2:])
        return
    if command == 'validate':
        validate(args)
        return
    require(command in ('create', 'link', 'delivered', 'archive'), 'unknown command')
    require(len(args) == {'create': 2, 'link': 3, 'delivered': 3, 'archive': 1}[command], 'wrong argument count')
    key = args[0]
    valid_key(key)
    safe(area).mkdir(parents=True, exist_ok=True)
    lock = safe(area / '.lock')
    lock.mkdir()  # refusal, not stale-lock guessing
    try:
        if command == 'create':
            require(key not in records(), f'duplicate alignment: {key}')
            ask = '\n'.join('> ' + line for line in text(Path(args[1])).rstrip().splitlines())
            path = area / key
            path.mkdir()
            for name, skill in (('spec', 'align-intake'), ('plan', 'plan-breakdown')):
                template = text(root / f'.agents/skills/{skill}/{name}-template.md')
                put(path / f'{name}.md', template.replace('{key}', key).replace('{ask}', ask.rstrip()))
            refresh()
        else:
            path = locate(key)
            require(path.parent == area, 'archived record is immutable')
            spec, plan = text(path / 'spec.md'), text(path / 'plan.md')
            linked = items(spec)
            require(linked == items(plan), 'spec/plan links disagree')
            if command == 'link':
                task, mode = args[1:]
                require(mode in modes, 'invalid delivery mode')
                body = task_body(task)
                require(pointer(body) in (None, key), 'task already linked elsewhere')
                require(task not in linked or linked[task] == (mode, 'open', '-'), 'item already delivered or mode differs')
                if pointer(body) is None:
                    result = subprocess.run([str(root / 'bin/fm-tasks-axi.sh'), 'update', task,
                                             '--body', body.rstrip() + '\n\nalignment: ' + key, '--archive-body'],
                                            capture_output=True, text=True, timeout=30)
                    require(result.returncode == 0, f'work-item update failed: {result.stderr}')
                if task not in linked:
                    line = f'\nitem: {task} | {mode} | open | -\n'
                    put(path / 'spec.md', spec + line)
                    put(path / 'plan.md', plan + line)
            elif command == 'delivered':
                task, evidence = args[1:]
                require(task in linked, 'task not linked')
                mode, status, old_evidence = linked[task]
                require(pointer(task_body(task)) == key, 'missing task pointer')
                evidence_valid(mode, evidence)
                require(status == 'open' or old_evidence == evidence, 'conflicting delivery evidence')
                old = f'item: {task} | {mode} | {status} | {old_evidence}'
                new = f'item: {task} | {mode} | complete | {evidence}'
                receipt = f'receipt: {task} alignment: {key}'
                spec = spec.replace(old, new)
                if receipt not in spec.splitlines():
                    spec += '\n' + receipt + '\n'
                put(path / 'spec.md', spec)
                put(path / 'plan.md', plan.replace(old, new))
            else:
                linked = validate_record(key, path, ready=True)
                require(linked and all(row[1] == 'complete' for row in linked.values()), 'cannot archive unfinished alignment')
                archive = safe(area / 'archive')
                archive.mkdir(exist_ok=True)
                destination = archive / f'{datetime.date.today().isoformat()}-{key}'
                require(not destination.exists(), 'archive destination exists')
                path.rename(destination)
                refresh()
    finally:
        lock.rmdir()

try:
    main(sys.argv[1:])
except (ValueError, OSError, subprocess.SubprocessError) as error:
    print(f'ALIGNMENT: {error}', file=sys.stderr)
    sys.exit(1)
PY
