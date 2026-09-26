#!/usr/bin/env bash
# Test family: live-harness-optin
# Bounded prompt-submitting guard for actual skill discovery, loading and reference use.
# Usage: FM_PORTABLE_QUALITY_SKILLS_LIVE=1 bash tests/fm-portable-quality-skills-live-e2e.test.sh
# Optional argument: --verify-only rechecks existing receipts without model calls;
# --claude-only or --codex-only refreshes that installed runtime.
# Output: .no-mistakes/portable-skills/live/<runtime>-<skill>.log and command receipts.
# No runtime configuration is written; fixture links point at canonical skills.
set -eu
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"
fm_live_gate opt-in FM_PORTABLE_QUALITY_SKILLS_LIVE claude pi codex || exit 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$ROOT" "${1:-}" <<'PY'
import json
import os
import re
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
verify_only = sys.argv[2] == '--verify-only'
only_runtime = sys.argv[2][2:-5] if sys.argv[2] in ('--codex-only', '--claude-only') else None
out = root / '.no-mistakes/portable-skills/live'
out.mkdir(parents=True, exist_ok=True)
fixture = out / 'fixture'
(fixture / '.agents').mkdir(parents=True, exist_ok=True)
(fixture / '.claude').mkdir(exist_ok=True)
for alias, target in [(fixture / '.agents/skills', root / '.agents/skills'),
                      (fixture / '.claude/skills', Path('../.agents/skills'))]:
    if not alias.is_symlink():
        alias.symlink_to(target, target_is_directory=True)
scenarios = {
    'mobile-tablet-ui': ('device-checks.md', 'A fictional responsive web form fits a phone screenshot but its submit button is hidden when the software keyboard opens; tablet split-view and physical devices are unavailable. Produce a bounded adaptation/check plan and honest evidence limits; do not claim tests occurred.'),
    'ui-quality-evidence': ('matrix.md', 'A fictional implemented route has an authoritative template, loaded and empty states, light/dark and FR/EN requirements. Click tests pass but table density differs and hardware keyboard testing is unavailable. Produce selected evidence rows and limitations without inventing a design or approving delivery.'),
    'api-contract-evidence': ('paths.md', 'A fictional endpoint contract forbids role-denied and foreign-tenant writes, leaks no secret field, and uses an idempotency key for successful mutations. A refusal returns 403 but may enqueue a write. Produce allowed/refused/replay/partial-failure evidence rows checking status, payload and persisted effects; do not execute requests or choose authorization policy.')
}
versions = {}
if verify_only:
    versions = json.loads((out / 'versions.json').read_text())
else:
    for runtime in ('claude', 'pi', 'codex'):
        versions[runtime] = subprocess.check_output([runtime, '--version'], text=True).strip()
    (out / 'versions.json').write_text(json.dumps(versions, indent=2) + '\n')
env = dict(os.environ)
env.pop('CLAUDECODE', None)
env['PI_TELEMETRY'] = '0'
failed = False
for runtime in ((only_runtime,) if only_runtime else ('claude', 'pi', 'codex')):
    for name, (reference, scenario) in scenarios.items():
        instructions = ('You are a bounded read-only skill evaluation worker, not a Firstmate supervisor. Do not delegate or run fleet operations. '
                        f'Load the discovered {name} skill and read its linked references/{reference} file. '
                        'Use only skill/read tools or read-only file commands; do not edit, access network, or test an application. '
                        'State the loaded canonical skill path and reference path, then answer the scenario in at most 250 words. ' + scenario)
        if runtime == 'claude':
            command = ['claude', '-p', '--output-format', 'stream-json', '--verbose', '--no-session-persistence',
                       '--setting-sources', 'project', '--settings', '{"disableAllHooks":true}',
                       '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
                       '--tools', 'Read,Skill', '--allowedTools', 'Read,Skill', '--max-turns', '5',
                       '/' + name + ' ' + instructions]
        elif runtime == 'pi':
            command = ['pi', '-p', '--mode', 'json', '--no-session', '--no-extensions', '--no-context-files',
                       '--no-prompt-templates', '--no-themes', '--offline', '--approve', '--tools', 'read',
                       '/skill:' + name + ' ' + instructions]
        else:
            command = ['codex', 'exec', '--json', '--ephemeral', '--ignore-user-config', '--disable', 'hooks', '--enable', 'shell_tool', '--enable', 'unified_exec',
                       '--skip-git-repo-check', '-s', 'read-only', '-m', 'gpt-6-sol',
                       '-c', 'model_reasoning_effort="high"', '$' + name + ' ' + instructions]
        receipt = {'runtime': runtime, 'version': versions[runtime], 'cwd': str(fixture), 'argv': command}
        if runtime == 'codex' and not verify_only:
            discovery_command = ['codex', 'debug', 'prompt-input', '-c', 'features.hooks=false', '$' + name]
            discovery = subprocess.run(discovery_command, cwd=fixture, env=env, stdin=subprocess.DEVNULL,
                                       text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            (out / f'codex-{name}.discovery.json').write_text(discovery.stdout)
            receipt['discovery_argv'] = discovery_command
            receipt['discovery_exit_code'] = discovery.returncode
        if verify_only:
            receipt = json.loads((out / f'{runtime}-{name}.command.json').read_text())
            output = (out / f'{runtime}-{name}.log').read_text()
        else:
            try:
                result = subprocess.run(command, cwd=fixture, env=env, text=True,
                                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
                receipt['exit_code'] = result.returncode
                output = result.stdout
            except subprocess.TimeoutExpired as exc:
                receipt['exit_code'] = 'timeout'
                output = exc.stdout or b''
                if isinstance(output, bytes): output = output.decode('utf-8', 'replace')
            (out / f'{runtime}-{name}.log').write_text(output)
            (out / f'{runtime}-{name}.command.json').write_text(json.dumps(receipt, indent=2) + '\n')
        # Pair real read calls with successful results and resolve canonical paths.
        events = []
        for line in output.splitlines():
            try: events.append(json.loads(line))
            except json.JSONDecodeError: pass
        requests = {}
        successful = set()
        def canonical(path):
            candidate = Path(path)
            if not candidate.is_absolute(): candidate = fixture / candidate
            return str(candidate.resolve())
        for event in events:
            if runtime == 'claude':
                for block in event.get('message', {}).get('content', []):
                    if block.get('type') == 'tool_use' and block.get('name') == 'Read':
                        requests[block['id']] = canonical(block['input']['file_path'])
                    if block.get('type') == 'tool_result' and not block.get('is_error', False) and block.get('content'):
                        path = requests.get(block.get('tool_use_id'))
                        if path: successful.add(path)
            elif runtime == 'pi':
                if event.get('type') == 'tool_execution_start' and event.get('toolName') == 'read':
                    requests[event['toolCallId']] = canonical(event['args']['path'])
                if event.get('type') == 'tool_execution_end' and not event.get('isError', True) and event.get('result'):
                    path = requests.get(event.get('toolCallId'))
                    if path: successful.add(path)
            else:
                item = event.get('item', {})
                if item.get('type') == 'command_execution' and item.get('exit_code') == 0 and item.get('aggregated_output'):
                    import shlex
                    # Require exact path tokens in the completed read command.
                    words = shlex.split(item.get('command', ''))
                    nested = []
                    for word in words:
                        if 'SKILL.md' in word or reference in word:
                            nested.extend(shlex.split(word))
                    if not any(word in ('cat', 'sed', 'head') for word in words + nested):
                        continue
                    for word in words + nested:
                        if word.endswith('/SKILL.md') or word.endswith('/' + reference):
                            successful.add(canonical(word))
        base = root / '.agents/skills' / name
        loaded = str((base / 'SKILL.md').resolve()) in successful
        referenced = str((base / 'references' / reference).resolve()) in successful
        discovered = True
        if runtime == 'claude':
            discovered = any(name in event.get('skills', []) for event in events if event.get('subtype') == 'init')
            # Native slash expansion loads the entrypoint without a redundant Read event.
            native = receipt['argv'][-1].startswith('/' + name + ' ')
            completed = any(event.get('type') == 'result' and event.get('subtype') == 'success' and not event.get('is_error', True) for event in events)
            loaded = loaded or (discovered and native and completed)
        if runtime == 'pi':
            discovered = any('<skill name="' + name + '"' in content.get('text', '')
                             for event in events if event.get('type') == 'message_end'
                             for content in event.get('message', {}).get('content', []) if isinstance(content, dict))
        if runtime == 'codex':
            catalog = json.loads((out / f'codex-{name}.discovery.json').read_text())
            discovered = False
            for event in catalog:
                if event.get('role') != 'developer': continue
                for content in event.get('content', []):
                    text = content.get('text', '')
                    roots = dict(re.findall(r'- `(r[0-9]+)` = `([^`]+)`', text))
                    entry = re.search(r'- ' + re.escape(name) + r':[^\n]+\(file: ([^)]+)\)', text)
                    if entry:
                        location = entry.group(1)
                        alias, separator, suffix = location.partition('/')
                        path = str(Path(roots[alias]) / suffix) if alias in roots and separator else location
                        discovered = canonical(path) == str((base / 'SKILL.md').resolve())
        passed = receipt['exit_code'] == 0 and discovered and loaded and referenced
        print(f'{"PASS" if passed else "FAIL"} {runtime} {receipt["version"]} {name}: exit={receipt["exit_code"]}, discovered={discovered}, skill-loaded={loaded}, reference-read={referenced}', flush=True)
        if not passed: failed = True
if failed: sys.exit(1)
PY
