#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def git(project, *args):
    return subprocess.check_output(
        ['git', '-C', str(project), *args], stderr=subprocess.DEVNULL, text=True
    ).strip()


def canonical(path):
    path = Path(os.path.abspath(path))
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError(f'ambiguous symlink in native pool path: {part}')
        if part.exists() and not part.is_dir():
            raise ValueError(f'native pool path is not a directory: {part}')
    return path.resolve()


def select(project, exact=None):
    project = Path(git(project, 'rev-parse', '--show-toplevel'))
    common = Path(git(project, 'rev-parse', '--path-format=absolute', '--git-common-dir'))
    if common.name == '.git':
        project = common.parent
    project = project.resolve(strict=True)
    try:
        origin = git(project, 'remote', 'get-url', 'origin')
    except subprocess.CalledProcessError:
        origin = str(project)
    name = project.name + '-' + hashlib.sha256(origin.encode()).hexdigest()[:6]
    if exact:
        slot = canonical(exact)
        if not slot.is_dir() or not (slot / ".git").exists():
            raise ValueError(f"recorded native copy is unavailable: {slot}")
        pool = slot.parent.parent
        if pool.name != name or pool.parent.name != '.treehouse':
            raise ValueError(f'recorded slot has no proven native pool identity: {slot}')
        root = pool.parent.parent
    else:
        root = os.environ.get('TREEHOUSE_ROOT', '')
        if not root:
            repo_config = project / 'treehouse.toml'
            user_config = Path.home() / '.config/treehouse/config.toml'
            config = repo_config if repo_config.exists() else user_config
            if config.exists():
                import tomllib
                with config.open('rb') as stream:
                    root = tomllib.load(stream).get('root', '')
                if not isinstance(root, str):
                    raise ValueError(f'invalid root in {config}')
        if root:
            root = re.sub(r'\$(?:\{([^}]+)\}|([A-Za-z_][A-Za-z0-9_]*))',
                          lambda m: os.environ.get(m[1] or m[2], ''), root)
            root = Path(root)
            if not root.is_absolute():
                root = project / root
        else:
            root = Path.home()
        root = canonical(root)
        pool = canonical(root / '.treehouse' / name)
    if any(c in str(root) + str(pool) for c in '\r\n\t$'):
        raise ValueError('unsupported character in native pool identity')
    state = pool / 'treehouse-state.json'
    if state.exists() or state.is_symlink():
        if state.is_symlink() or not state.is_file() or state.stat().st_nlink != 1:
            raise ValueError(f'unsafe native pool state: {state}')
        with state.open() as stream:
            entries = json.load(stream)['worktrees']
        if entries is None:
            entries = []
        if not isinstance(entries, list):
            raise ValueError(f'invalid native pool state: {state}')
        seen = set()
        for entry in entries:
            path = canonical(entry['path'])
            if path.parent.parent != pool or path.parent.name != entry['name'] or str(path) != entry['path'] or str(path) in seen:
                raise ValueError(f'ambiguous native slot identity: {path}')
            seen.add(str(path))
        if exact and str(slot) not in seen:
            raise ValueError(f'recorded slot missing from native pool state: {slot}')
    elif exact or (pool.exists() and any(pool.iterdir())):
        raise ValueError(f'native pool state unavailable: {state}')
    return dict(root=str(root), pool=str(pool), project=str(project))


try:
    print(json.dumps(select(*sys.argv[1:])))
except (OSError, ValueError, KeyError, TypeError, ImportError, subprocess.CalledProcessError) as error:
    print(f'REFUSED: cannot prove native Treehouse pool identity: {error}', file=sys.stderr)
    sys.exit(1)
