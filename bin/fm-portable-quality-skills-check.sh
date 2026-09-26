#!/usr/bin/env bash
# Validate the portable quality lot's format, local references and canonical discovery.
# Usage: bin/fm-portable-quality-skills-check.sh [--root <repository>]
# Uses Python's standard library; never invokes a model or installs a dependency.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 - "$ROOT" "$@" <<'PY'
import argparse
import re
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description='Validate portable quality skill packaging')
parser.add_argument('--root', type=Path, default=Path(sys.argv[1]))
args = parser.parse_args(sys.argv[2:])
root = args.root.resolve()
names = ('mobile-tablet-ui', 'ui-quality-evidence', 'api-contract-evidence')
try:
    for name in names:
        folder = root / '.agents/skills' / name
        skill = folder / 'SKILL.md'
        text = skill.read_text(encoding='utf-8')
        if not text.startswith('---\n') or '\n---\n' not in text[4:]:
            raise ValueError(f'{name}: missing frontmatter')
        header, body = text[4:].split('\n---\n', 1)
        # The lot intentionally uses a portable YAML subset, not a general parser.
        if not re.fullmatch(r'name: ([a-z0-9]+(?:-[a-z0-9]+)*)\ndescription: ([^\n]+)\nmetadata:\n  internal: true', header):
            raise ValueError(f'{name}: invalid portable frontmatter subset')
        fields = header.splitlines()
        if fields[0] != f'name: {name}' or len(name) > 64:
            raise ValueError(f'{name}: name/directory mismatch')
        description = fields[1][len('description: '):]
        if (not 1 <= len(description) <= 1024 or any(c in description for c in '<>')
                or description[0] in '#&*!|>\"\'{}[],%@`'
                or ': ' in description or ' #' in description):
            raise ValueError(f'{name}: invalid description')
        if not body.strip():
            raise ValueError(f'{name}: empty procedure')
        for document in folder.rglob('*.md'):
            for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', document.read_text(encoding='utf-8')):
                if '://' in target or target.startswith('#'):
                    continue
                destination = (document.parent / target.split('#', 1)[0]).resolve()
                if root not in destination.parents or not destination.exists():
                    raise ValueError(f'{document.relative_to(root)}: invalid reference {target}')
        alias = root / '.claude/skills' / name / 'SKILL.md'
        if not alias.exists() or alias.resolve() != skill.resolve():
            raise ValueError(f'{name}: Claude discovery diverges from canonical path')
        print(f'PASS {name}: portable format, local references, canonical .agents and .claude discovery')
    if not (root / '.claude/skills').is_symlink():
        raise ValueError('Claude compatibility path must remain a symlink')
except (OSError, ValueError) as exc:
    print(f'FAIL {exc}', file=sys.stderr)
    sys.exit(1)
PY
