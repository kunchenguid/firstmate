#!/usr/bin/env bash
# Portable behavior tests for the opt-in Codex Herdr session selector.
# The fake app-server uses TOML parsing and native-shaped metadata; the separate
# live guard verifies the installed Codex parser rather than trusting this fake.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-herdr-hooks)
export FM_HOOK_TEST_ROOT="$ROOT" FM_HOOK_TEST_TMP="$TMP_ROOT"
test_python=
for candidate in python3 python3.14 python3.13 python3.12 python3.11; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
    test_python=$candidate
    break
  fi
done
[ -n "$test_python" ] || { echo 'skip: Python 3.11+ with tomllib is needed for the fake Codex parser'; exit 0; }
"$test_python" - <<'PY'
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import unittest

ROOT = Path(os.environ['FM_HOOK_TEST_ROOT'])
TMP = Path(os.environ['FM_HOOK_TEST_TMP'])
HELPER = ROOT / 'bin/fm-codex-herdr-hooks.sh'

FAKE = r'''#!/usr/bin/env python3
import json,os,subprocess,sys,tomllib
from pathlib import Path
home=Path(os.environ['CODEX_HOME'])
args=sys.argv[1:]
case=os.environ.get('HOOK_CASE','')
if args[-2:]==['features','list']:
 print('hooks stable '+('false' if case=='feature-off' else 'true'));sys.exit()
if args==['--version']:
 print('codex-cli '+('0.165.0' if case=='version' else '0.164.0'));sys.exit()
state={}
notify=None
for i,a in enumerate(args[:-1]):
 if a=='-c':
  parsed=tomllib.loads(args[i+1])
  state.update(parsed.get('hooks',{}).get('state',{}))
  notify=parsed.get('notify',notify)
key=str(home/'hooks.json')+':session_start:3:0'
hooks=[dict(key=key,eventName='sessionStart',handlerType='command',command='bash '+shlex_quote(str(home/'herdr-agent-state.sh'))+' session',
 async_=False,matcher=None,timeoutSec=10,sourcePath=str(home/'hooks.json'),source='user',pluginId=None,displayOrder=0,
 enabled=True,isManaged=False,currentHash='sha256:official',trustStatus='trusted')]
hooks[0]['async']=hooks[0].pop('async_')
for i,source in enumerate(['user','project','plugin']):
 hooks.append(dict(hooks[0],key=f'/tmp/a.b.{i}/hooks.json:stop:0:0',eventName='stop',command='unrelated-hook',source=source,displayOrder=i+1))
if case=='untrusted':hooks[0]['trustStatus']='untrusted'
if case=='modified':hooks[0]['trustStatus']='modified'
if case=='managed':hooks[-1]['isManaged']=True
if case=='unknown':hooks[-1]['source']='unknown'
if case=='duplicate':hooks.append(dict(hooks[-1]))
if case=='missing':hooks=hooks[1:]
if case=='builtin':hooks[-1]['source']='plugin'
for h in hooks:
 if state and case!='ignore-state':h['enabled']=state.get(h['key'],{}).get('enabled',h['enabled'])
if state and case=='builtin':hooks[-1]['enabled']=True
if state and case=='changed':hooks[-1]['currentHash']='sha256:new'
if state and case=='new-key':hooks.append(dict(hooks[-1],key='new-hook'))
if 'app-server' not in args:
 Path(os.environ['HOOK_EXEC_LOG']).write_text(json.dumps(dict(argv=args,thread=os.environ.get('CODEX_THREAD_ID'),state=state)))
 if notify:subprocess.run(notify+[json.dumps({'thread-id':'exact-native-thread'})],check=True)
 sys.exit()
for line in sys.stdin:
 request=json.loads(line);method=request['method']
 with (home/'requests.jsonl').open('a') as log:log.write(json.dumps(request)+'\n')
 if method=='initialize':result={'codexHome':str(home)}
 elif method=='configRequirements/read':result={'requirements':({'hooks':{}} if case=='policy' else {'featureRequirements':{'hooks':False}} if case=='feature-policy' else None)}
 elif method=='hooks/list':
  result={'data':[{'cwd':request['params']['cwds'][0],'hooks':hooks,'warnings':['ambiguous source'] if case=='warning' else [],'errors':[{'message':'bad','path':'p'}] if case=='errors' else []}]}
 else:sys.exit(99)
 print(json.dumps({'id':request['id'],'result':result}),flush=True)
'''
# Use the same shell quoting shape as Herdr's installed command.
FAKE = FAKE.replace('home=Path', 'from shlex import quote as shlex_quote\nhome=Path', 1)

class SelectorTests(unittest.TestCase):
    def setUp(self):
        self.path = TMP / self._testMethodName
        self.path.mkdir()
        self.home = self.path / 'codex home.with.dots'
        self.home.mkdir()
        self.bin = self.path / 'bin'
        self.bin.mkdir()
        codex = self.bin / 'codex'
        codex.write_text(FAKE.replace("#!/usr/bin/env python3", "#!" + sys.executable, 1))
        codex.chmod(0o755)
        self.script = self.home / 'herdr-agent-state.sh'
        self.script.write_text('# installed by herdr\n# HERDR_INTEGRATION_ID=codex\n# HERDR_INTEGRATION_VERSION=10\n')
        self.config = self.path / 'operator-review.json'
        self.log = self.path / 'launch.json'
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'], CODEX_HOME=str(self.home),
                        HERDR_ENV='1',HERDR_PANE_ID='only-this-pane',HERDR_SOCKET_PATH='/tmp/lab-only.sock',
                        CODEX_THREAD_ID='inherited-parent',HOOK_EXEC_LOG=str(self.log))
        candidate = self.call('review',str(self.path))
        self.assertEqual(candidate.returncode,0,candidate.stderr)
        self.config.write_text(candidate.stdout)
        self.before = self.config.read_bytes()

    def call(self,*args,case=''):
        return subprocess.run(['bash',str(HELPER),*args],env=dict(self.env,HOOK_CASE=case),cwd=self.path,text=True,capture_output=True)

    def check(self,case=''):
        return self.call('check',str(self.config),str(self.path),case=case)

    def test_exclusive_native_keys_and_no_writes(self):
        result=self.check()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('3 unrelated hooks disabled',result.stdout)
        self.assertEqual(self.config.read_bytes(),self.before)
        requests=[json.loads(l) for l in (self.home/'requests.jsonl').read_text().splitlines()]
        self.assertTrue(requests)
        self.assertEqual(set(r['method'] for r in requests),{'initialize','hooks/list','configRequirements/read'})
        self.assertFalse(self.log.exists())

    def test_exec_preserves_notify_and_clears_parent_identity(self):
        marker=self.path/'turn end.marker'
        notify='notify='+json.dumps(['bash','-c','touch '+shlex.quote(str(marker))])
        result=self.call('exec',str(self.config),'--','-m','example','-c','model_reasoning_effort="xhigh"',
                         '--approve-for-me','-c',notify,'FIRSTMATE_OP: launch-brief')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(marker.is_file())
        launched=json.loads(self.log.read_text())
        self.assertIsNone(launched['thread'])
        self.assertIn('--no-daemon',launched['argv'])
        self.assertNotIn('--disable',launched['argv'])
        self.assertNotIn('--dangerously-bypass-hook-trust',launched['argv'])
        self.assertEqual(sum(v['enabled'] for v in launched['state'].values()),1)
        self.assertTrue(launched['state'][str(self.home/'hooks.json')+':session_start:3:0']['enabled'])
        self.assertTrue(all(set(v)=={'enabled'} for v in launched['state'].values()))

    def test_fail_closed_discovery_and_policy(self):
        for case in ['version','untrusted','modified','managed','policy','feature-policy','feature-off','unknown','duplicate','missing','warning','errors',
                     'ignore-state','changed','new-key','builtin']:
            with self.subTest(case=case):
                result=self.check(case)
                self.assertNotEqual(result.returncode,0,result.stdout)
                self.assertIn('refused:',result.stderr)
                self.assertFalse(self.log.exists())

    def test_review_staleness_and_shape(self):
        self.script.write_text(self.script.read_text()+'# updated\n')
        self.assertNotEqual(self.check().returncode,0)
        self.config.write_text('{}')
        self.assertNotEqual(self.check().returncode,0)
        self.config.write_text('broken json')
        self.assertNotEqual(self.check().returncode,0)

    def test_exec_refuses_missing_routing_and_extra_selectors(self):
        for selector in ['--dangerously-bypass-hook-trust','--config=hooks.state={}','-p','--cd','-cfeatures.hooks=false']:
            with self.subTest(selector=selector):
                result=self.call('exec',str(self.config),'--',selector,'prompt')
                self.assertNotEqual(result.returncode,0)
                self.assertFalse(self.log.exists())
        result=self.call('exec',str(self.config),'--','-c','notify=[]\n[features]\nhooks=false','prompt')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.log.exists())
        result=self.call('exec',str(self.config),'--','prompt')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.log.exists())
        self.env.pop('HERDR_PANE_ID')
        result=self.call('exec',str(self.config),'--','prompt')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.log.exists())

unittest.main(argv=['fm-codex-herdr-hooks'],verbosity=2)
PY
