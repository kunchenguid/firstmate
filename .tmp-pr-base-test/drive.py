import os
import pathlib
import shutil
import subprocess
import json
import time

root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/daddy/.no-mistakes-upstream-codex/evidence/01M6RXKB0R08340BE8CSAJ6QJ7')
lab = root / '.tmp-pr-base-test/manual-home'
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'HERDR_', 'TASKS_AXI_', 'GIT_')) or key in ('REX_SESSION', 'REX_BLOCK', 'GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN'):
        env.pop(key, None)
env.update(FM_HOME=str(lab), GH_CONFIG_DIR=str(lab / 'gh'), GH_TOKEN='synthetic-validation-token', GH_ENTERPRISE_TOKEN='synthetic-validation-token', GH_PROMPT_DISABLED='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', HTTPS_PROXY='http://127.0.0.1:1', HTTP_PROXY='http://127.0.0.1:1', ALL_PROXY='http://127.0.0.1:1', NO_PROXY='', no_proxy='')
records = []

def run(args, **kwargs):
    started = time.monotonic()
    result = subprocess.run(args, cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=25, **kwargs)
    records.append(dict(command=args, exit=result.returncode, elapsed_seconds=round(time.monotonic()-started, 3), output=result.stdout))
    return result

def require(value, message):
    if not value:
        raise AssertionError(message)

try:
    require(run(['bash', 'bin/fm-lab-home.sh', 'create', str(lab)]).returncode == 0, 'lab creation failed')
    (lab / 'gh').mkdir()
    (lab / 'tmp').mkdir()
    env['TMPDIR'] = str(lab / 'tmp')
    (lab / 'config/github-hosts').write_text('forge.invalid\n')
    project = lab / 'projects/synthetic'
    require(run(['git', 'init', '-q', '-b', 'main', str(project)]).returncode == 0, 'synthetic Git repository creation failed')
    require(run(['git', '-C', str(project), '-c', 'user.name=Validation', '-c', 'user.email=validation@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'synthetic local validation input']).returncode == 0, 'synthetic Git commit failed')
    run(['git', '-C', str(project), 'branch', 'release/integration'])
    for task, mode, extras in [('default-brief', 'no-mistakes', []), ('named-brief', 'direct-PR', ['--base-branch', 'release/integration']), ('local-brief', 'local-only', [])]:
        result = run(['bash', 'bin/fm-brief.sh', task, 'synthetic', '--mode', mode, '--project', str(project)] + extras)
        require(result.returncode == 0, f'{task} generation failed')
        generated = lab / 'data' / task / 'brief.md'
        shutil.copyfile(generated, evidence / f'{task}.md')
        text = generated.read_text()
        require(f'Delivery contract: mode={mode}' in text, 'generated delivery contract missing')
        if task == 'named-brief':
            require('release/integration' in text and '--base' in text, 'named integration destination absent in generated brief')
        if task == 'default-brief':
            require('expected_base' in text or 'live PR base' in text, 'default brief lacks destination proof requirement')
    url = 'https://forge.invalid/synthetic/repo/pull/1'
    header = f'kind=ship\nmode=direct-PR\nharness=codex\nworktree={project}\nproject={project}\nyolo=off\n'
    cases = dict(missing='', empty='expected_base=\n', duplicate='expected_base=main\nexpected_base=main\n', invalid='expected_base=../main\n', conflict='expected_base=main\nbase_branch=release/integration\n')
    for name, fields in cases.items():
        task = 'base-' + name
        meta = lab / 'state' / f'{task}.meta'
        meta.write_text(header + fields)
        before = meta.read_bytes()
        for script in ('fm-pr-check.sh', 'fm-pr-merge.sh'):
            result = run(['bash', 'bin/' + script, task, url])
            require(result.returncode != 0, f'{name} accepted by {script}')
            require('expected PR base is unavailable or inconsistent' in result.stdout, f'{name} refused by unrelated guard in {script}')
            require(meta.read_bytes() == before, 'refused request changed metadata')
            require(not (lab / 'state' / f'{task}.pr-poll').exists(), 'refused request armed merge poll')
    task = 'base-unreadable'
    meta = lab / 'state' / f'{task}.meta'
    meta.write_text(header + 'expected_base=release/integration\n')
    before = meta.read_bytes()
    result = run(['gh', 'pr', 'view', url, '--json', 'baseRefName', '-q', '.baseRefName'])
    require(result.returncode != 0 and '127.0.0.1:1' in result.stdout, 'real gh did not exercise unavailable connection')
    for script in ('fm-pr-check.sh', 'fm-pr-merge.sh'):
        result = run(['bash', 'bin/' + script, task, url])
        require(result.returncode != 0 and 'expected PR base release/integration, actual base unavailable' in result.stdout, f'unreadable proof not refused by {script}')
        require(meta.read_bytes() == before, 'unreadable proof changed destination state')
        require(not (lab / 'state' / f'{task}.pr-poll').exists(), 'unreadable proof armed merge poll')
    result = run(['bash', 'bin/fm-pr-poll.sh', '--validated', 'github', url, 'forge.invalid', 'synthetic/repo', '1', 'release/integration', str(meta)])
    require(result.returncode == 0 and result.stdout == '', 'unreadable poll claimed merge')
    # A registered check's documented standalone input protocol is persisted
    # synthetic state. Each invocation below is a new real product process.
    task = 'legacy-default'
    meta = lab / 'state' / f'{task}.meta'
    meta.write_text(header)
    check = lab / 'state' / f'{task}.check.sh'
    shutil.copyfile(root / 'bin/fm-pr-poll.sh', check)
    (lab / 'state' / f'{task}.pr-poll').write_text('github\n' + url + '\nforge.invalid\nsynthetic/repo\n1\n')
    for _ in range(2):
        result = run(['bash', str(check)])
        require(result.returncode == 0 and 'merge/readiness refused: expected PR base unavailable' in result.stdout and result.stdout.strip() != 'merged', 'legacy poll restart did not refuse missing pin')
    # Ship records cannot enter the state-only secondmate cleanup route.
    result = run(['bash', 'bin/fm-pr-poll.sh', '--retire-secondmate', 'github', url, 'forge.invalid', 'synthetic/repo', '1', str(meta)])
    require(result.returncode == 0 and result.stdout == '', 'ship gained secondmate cleanup result')
    records.append(dict(result='PASS', note='Real scaffold, registration, merge and standalone poll commands executed. Forge reads used real gh with synthetic credentials and an unreachable loopback proxy. No forge emulator or model process was started.'))
finally:
    (evidence / 'manual-cli.json').write_text(json.dumps(records, indent=2) + '\n')
    with (evidence / 'manual-cli.log').open('w') as log:
        for record in records:
            if 'command' in record:
                log.write('$ ' + ' '.join(record['command']) + '\n')
                log.write(record['output'])
                log.write(f"exit={record['exit']} elapsed_seconds={record['elapsed_seconds']}\n\n")
            else:
                log.write(json.dumps(record) + '\n')
