#!/usr/bin/env python3
"""Publish private Markdown evidence and an offline Connections graph as one generation.

Configuration/ownership: docs/configuration.md, Project brains.
No extraction, model, network, global graph, timer or project-file writes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
from datetime import datetime, timezone


class Invalid(ValueError):
    pass


def require(test, message):
    if not test:
        raise Invalid(message)


def slug(value):
    require(isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,99}', value), 'invalid project/source/unit id')
    return value


def safe(path):
    path = Path(os.path.abspath(path))
    require(not any(p.is_symlink() for p in [path, *path.parents]), f'symlink path refused: {path}')
    return path


def read(path, limit=2_000_000):
    path = safe(path)
    require(path.is_file() and path.stat().st_size <= limit, f'missing, oversized or non-file input: {path}')
    with path.open(encoding='utf-8', newline='') as handle:
        return handle.read()


def pairs(entries):
    result = {}
    for key, value in entries:
        require(key not in result, f'duplicate JSON key: {key}')
        result[key] = value
    return result


def decode(text):
    return json.loads(text, object_pairs_hook=pairs)


def encoded(data):
    return json.dumps(data, ensure_ascii=False, sort_keys=True, indent=2) + '\n'


def digest(data):
    return hashlib.sha256(data.encode()).hexdigest()


def atomic(path, text):
    safe(path.parent).mkdir(parents=True, exist_ok=True)
    safe(path)
    fd, name = tempfile.mkstemp(prefix='.publish-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def config_root(home):
    return safe(os.environ.get('FM_CONFIG_OVERRIDE', home / 'config'))


def data_root(home):
    return safe(os.environ.get('FM_DATA_OVERRIDE', home / 'data'))


def state_root(home):
    return safe(os.environ.get('FM_STATE_OVERRIDE', home / 'state'))


def configured(home, project):
    path = safe(config_root(home) / 'project-brains' / f'{project}.json')
    if not path.exists():
        return None
    cfg = decode(read(path, 65536))
    require(isinstance(cfg, dict), 'configuration must be an object')
    require(set(cfg) == {'schema_version', 'sources'} and type(cfg['schema_version']) is int and cfg['schema_version'] == 1, 'invalid brain configuration')
    require(isinstance(cfg['sources'], list) and 0 < len(cfg['sources']) <= 64, 'require 1..64 explicit sources')
    names = set()
    for item in cfg['sources']:
        require(isinstance(item, dict) and set(item) == {'id', 'path'}, 'invalid source record')
        name = slug(item['id'])
        require(name not in names, 'duplicate source id')
        names.add(name)
        require(isinstance(item['path'], str) and Path(item['path']).is_absolute(), 'source path must be absolute')
        src = safe(item['path'])
        require(src.suffix.lower() == '.md', 'source must be an explicit Markdown file')
        require(not src.is_relative_to(data_root(home) / 'brains'), 'brain output cannot ingest itself')
    registry = read(data_root(home) / 'projects.md', 1_000_000)
    matches = [s for s in registry.splitlines() if s.startswith(f'- {project} - ') or s.startswith(f'- {project} [')]
    require(len(matches) == 1, 'brain requires one registered project')
    return cfg


def snapshot(cfg):
    result = {}
    for src in cfg['sources']:
        path = safe(src['path'])
        if path.exists():
            text = read(path)
            result[src['id']] = dict(path=str(path), sha256=digest(text), text=text, lines=len(text.splitlines()), status='current')
        else:
            result[src['id']] = dict(path=str(path), sha256=None, status='missing')
    return result


def load_current(brain):
    pointer = safe(brain / 'CURRENT')
    if not pointer.exists():
        return None, {}, {}
    name = read(pointer, 100).strip()
    require(re.fullmatch('[a-f0-9]{64}', name), 'invalid CURRENT generation')
    generation = safe(brain / 'generations' / name)
    return generation, decode(read(generation / 'manifest.json', 20_000_000)), decode(read(generation / 'units.json'))


def usable(current, manifest):
    if current is None:
        return False
    try:
        require(decode(read(current / 'manifest.json', 20_000_000)) == manifest, 'serialized manifest mismatch')
        decode(read(current / 'units.json'))
        read(current / 'log.md')
        return (digest(read(current / 'graphify-out/graph.json', 20_000_000)) == manifest.get('graph_sha256')
                and all(digest(read(current / 'pages' / f'{pid}.md', 8_000_000)) == sha for pid, sha in manifest['pages'].items()))
    except (ValueError, OSError, KeyError):
        return False


def fingerprints(sources):
    return {k: {a: v[a] for a in ['path', 'sha256', 'status']} for k, v in sources.items()}


def summary_file(path):
    data = decode(read(path, 65536))
    require(isinstance(data, dict) and set(data) == {'title', 'body', 'sources', 'connections'}, 'invalid completion summary')
    require(isinstance(data['title'], str) and 0 < len(data['title']) <= 200 and '\n' not in data['title'], 'invalid summary title')
    require(isinstance(data['body'], str) and 0 < len(data['body']) <= 32000, 'invalid summary body')
    require(isinstance(data['sources'], list) and data['sources'] and all(isinstance(x, str) for x in data['sources']), 'summary requires source ids')
    for source in data['sources']:
        slug(source)
    require(isinstance(data['connections'], list) and all(isinstance(x, str) and re.fullmatch(r'units/[A-Za-z0-9][A-Za-z0-9._-]{0,99}', x) for x in data['connections']), 'connections must name units/<id>')
    # Body is untrusted evidence prose, never another structural Connections section.
    require(not re.search(r'^##\s+Connections\s*$', data['body'], re.M), 'summary body cannot supply a Connections section')
    return data


def connections(text):
    """Exact path links from the owned section only, excluding fenced examples."""
    active = False
    fence = None
    targets = {}
    for lineno, line in enumerate(text.splitlines(), 1):
        match = re.match(r'^\s*(`{3,}|~{3,})', line)
        if match:
            marker = match[1][0]
            if fence is None:
                fence = (marker, len(match[1]))
            elif fence[0] == marker and len(match[1]) >= fence[1] and not line[match.end():].strip():
                fence = None
            continue
        if fence:
            continue
        if line.startswith('## '):
            active = line.strip() == '## Connections'
            continue
        if active:
            for target in re.findall(r'\[\[([A-Za-z0-9][A-Za-z0-9._/-]*)\]\]', line):
                targets.setdefault(target, lineno)
    require(fence is None, 'unclosed Markdown fence; close summary fences and retry')
    return sorted(targets.items())


def build(home, project, cfg, unit=None, summary=None, task=False):
    brain = safe(data_root(home) / 'brains' / project)
    brain.mkdir(parents=True, exist_ok=True)
    lock = brain / '.write-lock'
    try:
        lock.mkdir()
    except FileExistsError as exc:
        raise Invalid(f'brain update already owned; retry after current writer finishes: {lock}') from exc
    state = state_root(home) / 'project-brains' / f'{project}.json'
    stage = None
    try:
        (lock / 'owner.json').write_text(encoded({'pid': os.getpid(), 'project': project, 'acquired_at': datetime.now(timezone.utc).isoformat()}), encoding='utf-8')
        previous, prior_manifest, units = load_current(brain)
        sources = snapshot(cfg)
        if unit:
            existing_unit = task and unit in units
            if existing_unit:
                summary = units[unit]  # Preserve the contributor's richer completion record.
            elif task:
                summary = {'title': f'Completed work: {unit}', 'body': f'The existing delivery owner completed work unit {unit}. Consult its authoritative task record for delivery and decisions.', 'sources': list(sources), 'connections': []}
            if not existing_unit:
                require(all(s in sources for s in summary['sources']), 'summary references an unconfigured source; fix summary and retry')
                require(all(sources[s]['status'] == 'current' for s in summary['sources']), 'completion evidence is missing; restore input and retry')
            units[unit] = summary
        # Stable identity excludes observation time: unchanged content is a no-op.
        identity = dict(renderer_version=2, project=project, sources=fingerprints(sources), units=units)
        require(len(encoded(units).encode()) <= 2_000_000, 'unit synthesis exceeds 2 MB; curate before adding more')
        input_sha = digest(encoded(identity))
        generation_id = input_sha
        destination = brain / 'generations' / generation_id
        if previous and prior_manifest.get('input_sha256') == input_sha and usable(previous, prior_manifest):
            destination = previous
            atomic(state, encoded({'status': 'ok', 'generation': str(destination), 'changed': False}))
            return {'status': 'current', 'generation': str(destination), 'changed': False}
        while destination.exists():
            try:
                manifest = decode(read(destination / 'manifest.json', 20_000_000))
                valid = manifest.get('input_sha256') == input_sha and usable(destination, manifest)
            except (Invalid, OSError, ValueError):
                valid = False
            if valid:
                break
            generation_id = digest(input_sha + ':repair:' + generation_id)
            destination = brain / 'generations' / generation_id
        stage = Path(tempfile.mkdtemp(prefix='.generation-', dir=brain))
        pages = {}
        for sid, source in sources.items():
            if source['status'] != 'current':
                continue
            raw = brain / 'raw' / f'{source["sha256"]}.md'
            if raw.exists():
                require(digest(read(raw)) == source['sha256'], 'immutable raw snapshot hash mismatch')
            else:
                atomic(raw, source['text'])
            # A source page is an evidence view, not fabricated semantic synthesis.
            # Fence raw content so source examples never create graph edges.
            fence = '`' * max(3, max([len(m[0]) + 1 for m in re.finditer(r'`+', source['text'])] or [3]))
            pages[f'sources/{sid}'] = f'# Evidence: {sid}\n\nStatus: current source snapshot, not independently verified claims.\nSource: {source["path"]}:1\nSource lines: 1-{source["lines"]}\nSHA-256: {source["sha256"]}\nImmutable input: ../../../../raw/{source["sha256"]}.md\n\n## Content\n\n{fence}markdown\n{source["text"]}\n{fence}\n\n## Connections\n'
        unit_states = {}
        for uid, value in sorted(units.items()):
            refs = [f'sources/{s}' for s in value['sources']]
            stale = any(ref not in pages for ref in refs)
            unit_states[uid] = {'status': 'stale' if stale else 'current', 'sources': value['sources']}
            refs += value['connections']
            pages[f'units/{uid}'] = f'# {value["title"]}\n\nStatus: {unit_states[uid]["status"]}\nWork unit: {uid}\n\n{value["body"]}\n\n## Sources\n' + ''.join(f'- {s}\n' for s in value['sources']) + '\n## Connections\n' + ''.join(f'- [[{ref}]]\n' for ref in refs)
        nodes = []
        links = []
        unresolved = []
        page_hashes = {}
        for pid, text in sorted(pages.items()):
            path = stage / 'pages' / f'{pid}.md'
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(text.encode('utf-8'))
            page_hashes[pid] = digest(text)
            node_id = f'{project}/{pid}'
            nodes.append(dict(status=unit_states.get(pid.removeprefix('units/'), {}).get('status', 'current') if pid.startswith('units/') else 'current', id=node_id, label=text.splitlines()[0][2:], source_file=f'pages/{pid}.md', source_location=f'pages/{pid}.md:1', type='wiki-page', confidence='EXTRACTED'))
            for target, lineno in connections(text):
                if target not in pages:
                    # Source deletion is expected drift; unknown unit links are author errors.
                    require(target.startswith('sources/'), f'unresolved unit connection: {target}; fix summary and retry')
                    unresolved.append(dict(source=pid, target=target))
                    continue
                links.append(dict(source=node_id, target=f'{project}/{target}', relation='connects_to', confidence='EXTRACTED', weight=1, source_location=f'pages/{pid}.md:{lineno}'))
        manifest = dict(schema_version=1, project=project, generation=generation_id, input_sha256=input_sha, sources=fingerprints(sources), pages=page_hashes, units=unit_states)
        graph = dict(directed=True, multigraph=False, graph=dict(project=project, mode='connections-wikilinks', generation=generation_id, source_snapshot_sha256=input_sha), nodes=nodes, links=links)
        (stage / 'graphify-out').mkdir()
        (stage / 'graphify-out/graph.json').write_text(encoded(graph), encoding='utf-8')
        (stage / 'graphify-out/GRAPH_REPORT.md').write_text(f'# Structural Connections graph\n\n{len(nodes)} pages, {len(links)} extracted wikilink edges.\nNo semantic inference or model calls.\n\n## Unresolved links\n' + ''.join(f'- {x["source"]} -> {x["target"]}\n' for x in unresolved), encoding='utf-8')
        manifest['graph_sha256'] = digest(encoded(graph))
        (stage / 'manifest.json').write_text(encoded(manifest), encoding='utf-8')
        (stage / 'units.json').write_text(encoded(units), encoding='utf-8')
        (stage / 'index.md').write_text(f'# {project} private project brain\n\nEvidence and work synthesis; task, preference and decision owners remain authoritative.\n\n' + ''.join(f'- [{pid}](pages/{pid}.md)\n' for pid in sorted(pages)), encoding='utf-8')
        old_log = read(previous / 'log.md') if previous else '# Wiki update log\n'
        now = datetime.now(timezone.utc).isoformat()
        (stage / 'log.md').write_text(old_log + f'\n- {now}: generation {generation_id}; unit {unit or "source-refresh"}; previous {prior_manifest.get("generation", "none")}.\n', encoding='utf-8')
        (stage / 'SCHEMA.md').write_text('# Private wiki schema v1\n\nSources are exact content-addressed immutable Markdown snapshots.\nEvidence pages cite original paths, line ranges and hashes.\nUnit pages retain contributor synthesis and explicit source ids; missing/removed sources mark units stale.\nOnly exact path-scoped links in the generated Connections section become EXTRACTED edges.\nThe graph and index are derived; they never close tasks or change decisions/preferences.\n', encoding='utf-8')
        require(usable(stage, manifest), 'staged generation failed validation; previous generation retained')
        # Recheck approved inputs before switching the sole visible pointer.
        require(configured(home, project) == cfg, 'approved corpus changed during build; retry')
        require(fingerprints(snapshot(cfg)) == fingerprints(sources), 'sources changed during build; retry')
        (brain / 'generations').mkdir(exist_ok=True)
        if destination.exists():
            shutil.rmtree(stage)
        else:
            os.replace(stage, destination)
        stage = None
        atomic(brain / 'CURRENT', generation_id + '\n')
        atomic(state, encoded({'status': 'ok', 'generation': str(destination), 'changed': True}))
        return dict(status='current', generation=str(destination), changed=True, stale_units=[u for u, v in unit_states.items() if v['status'] == 'stale'])
    except Exception as exc:
        atomic(state, encoded({'status': 'failed', 'error': str(exc), 'retry': f'fm-brain.sh build {project} (or retry the same complete command)', 'previous_generation_retained': True}))
        raise
    finally:
        if stage and stage.exists():
            shutil.rmtree(stage)
        (lock / 'owner.json').unlink(missing_ok=True)
        lock.rmdir()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['status', 'check', 'build', 'complete', 'complete-task', 'query'])
    parser.add_argument('project')
    parser.add_argument('term', nargs='?')
    parser.add_argument('--unit')
    parser.add_argument('--summary')
    args = parser.parse_args()
    project = slug(args.project)
    require(os.environ.get('FM_HOME'), 'set FM_HOME to the knowledge-owning home')
    home = safe(os.environ['FM_HOME'])
    require(home.is_dir(), 'FM_HOME is missing')
    try:
        cfg = configured(home, project)
    except (Invalid, OSError, ValueError) as exc:
        if args.command == 'status':
            print(encoded(dict(status='stale', error=str(exc))))
            return 0
        raise
    if cfg is None:
        require(args.command in ['status', 'complete-task'], 'project brain is not configured')
        print(encoded(dict(status='unconfigured', project=project)))
        return 0
    if args.command in ['build', 'complete', 'complete-task']:
        unit = slug(args.unit) if args.unit else None
        if args.command != 'build':
            require(unit, 'completion requires --unit')
        summary = summary_file(args.summary) if args.command == 'complete' and args.summary else None
        require(args.command != 'complete' or summary is not None, 'complete requires --summary')
        print(encoded(build(home, project, cfg, unit, summary, args.command == 'complete-task')))
        return 0
    brain = safe(data_root(home) / 'brains' / project)
    current, manifest, _ = load_current(brain)
    try:
        fresh = usable(current, manifest) and manifest.get('sources') == fingerprints(snapshot(cfg))
    except (Invalid, OSError):
        fresh = False
    if args.command == 'query':
        require(current is not None and fresh, 'graph is stale or absent; rebuild before querying current relationships')
        require(args.term, 'query requires a literal label term')
        graph = decode(read(current / 'graphify-out/graph.json', 20_000_000))
        hits = {n['id'] for n in graph['nodes'] if args.term.casefold() in n['label'].casefold()}
        print(encoded(dict(generation=str(current), nodes=[n for n in graph['nodes'] if n['id'] in hits], links=[e for e in graph['links'] if e['source'] in hits or e['target'] in hits])))
        return 0
    state = state_root(home) / 'project-brains' / f'{project}.json'
    stale_units = [u for u, value in manifest.get('units', {}).items() if value['status'] == 'stale']
    missing_sources = [s for s, value in manifest.get('sources', {}).items() if value['status'] == 'missing']
    result = dict(project=project, knowledge_status='stale' if stale_units or missing_sources or not fresh else 'current', stale_units=stale_units, missing_sources=missing_sources, status='current' if fresh else 'stale', generation=str(current) if current else None, last_attempt=decode(read(state)) if state.exists() else None)
    print(encoded(result))
    return 0 if args.command == 'status' or fresh else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Invalid, OSError, ValueError, TypeError, KeyError) as error:
        print(f'BRAIN_INVALID: {error}', file=sys.stderr)
        sys.exit(1)
