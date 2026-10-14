#!/usr/bin/env bash
# Token-free installed-Gemini guard for the Darwin shell-PTY mitigation.
# Runs the real spawn against isolated fake endpoints, then loads its generated
# launch environment with Gemini's actual PTY selector and executes six shell
# commands through the installed core service. No agent turn, auth, network,
# fleet endpoint, or operator settings are used. Bundle export drift fails with
# the installed version; refresh docs/verification/runtime-backends.md on upgrade.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate default-on FM_GEMINI_SHELL_LIVE gemini node lsof
if [ "$(uname -s)" != Darwin ]; then
  printf 'skip: live: Gemini shell-PTY mitigation applies only to Darwin\n'
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-gemini-shell-live)
GEMINI_BIN=$(command -v gemini)
home="$TMP_ROOT/home"
proj="$TMP_ROOT/project"
wt="$TMP_ROOT/worktree"
fakebin=$(make_spawn_fakebin "$TMP_ROOT/fake" gemini)
fm_test_spawn_home "$home" gemini
fm_git_worktree "$proj" "$wt" shell-live
fm_test_spawn_brief "$home" shell-live
out=$(FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch.sh" fm_test_run_spawn "$home" "$wt" "$fakebin" shell-live "$proj" --mode no-mistakes --yolo off)
expect_code 0 $? "Gemini fixture spawn failed: $out"
cat >"$TMP_ROOT/driver.mjs" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
import {SourceTextModule} from 'node:vm';
const timer = setTimeout(() => { console.error(`not ok - Gemini ${version}: installed shell guard timed out`); process.exit(1); }, 20000);
let version = 'unknown';
try {
  const entry = fs.realpathSync(process.argv[2]);
  const bundle = path.dirname(entry);
  version = JSON.parse(fs.readFileSync(path.join(bundle, '..', 'package.json'), 'utf8')).version;
  const required = ['ShellExecutionService', 'Config', 'getPty'];
  const pending = [entry];
  const visited = new Set();
  const candidates = [];
  while (pending.length) {
    const filename = fs.realpathSync(pending.pop());
    if (visited.has(filename)) continue;
    visited.add(filename);
    assert(path.dirname(filename) === bundle, `dependency escapes installed bundle: ${filename}`);
    const source = fs.readFileSync(filename, 'utf8');
    const imports = [...new SourceTextModule(source).dependencySpecifiers];
    const tokens = /\/\*[\s\S]*?\*\/|\/\/[^\n]*|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|`(?:\\[\s\S]|[^`\\])*`|\bimport\s*\(\s*['"](?<dynamic>[^'"]+)['"]\s*\)/g;
    for (const token of source.matchAll(tokens)) {
      if (token.groups.dynamic) imports.push(token.groups.dynamic);
    }
    for (const specifier of imports) {
      if (specifier.startsWith('.')) pending.push(path.resolve(path.dirname(filename), specifier));
    }
    const exports = [...source.matchAll(/^export\s*\{([^}]+)\}\s*;/gm)]
      .flatMap(([, names]) => names.split(',').map(name => name.trim().split(/\s+as\s+/).pop()));
    if (required.every(name => exports.includes(name))) candidates.push(filename);
  }
  assert(candidates.length, 'CLI dependency graph must resolve core exports');
  let core;
  for (const filename of candidates) {
    assert.notEqual(filename, entry, 'must not evaluate the CLI entry point');
    const module = await import(pathToFileURL(filename));
    for (const name of required) {
      assert.equal(typeof module[name], 'function', `installed core export ${name}`);
      if (core) assert.equal(module[name], core[name], `ambiguous CLI core export ${name}`);
    }
    core ??= module;
  }
  console.log(`ok - Gemini ${version}: CLI graph resolved core exports`);
  assert.equal(process.env.GEMINI_PTY_INFO, 'child_process', 'generated launch environment');
  assert.equal(await core.getPty(), null, 'real Gemini PTY selector must honor launch override');
  delete process.env.GEMINI_PTY_INFO;
  const control = await core.getPty();
  assert(control, 'control must find the installed native PTY backend');
  process.env.GEMINI_PTY_INFO = 'child_process';
  const selected = await core.getPty();
  // A user/workspace interactive-shell preference cannot override this selector.
  const config = new core.Config({sessionId: 'fm-shell-live', targetDir: process.argv[3], cwd: process.argv[3], interactive: true, ptyInfo: selected?.name, enableInteractiveShell: true});
  assert.equal(config.isInteractiveShellEnabled(), false);
  const count = () => {
    const result = spawnSync('lsof', ['-nP', '-a', '-p', String(process.pid), '/dev/ptmx'], {encoding: 'utf8'});
    assert([0, 1].includes(result.status), 'lsof failed');
    assert.equal(result.stderr.trim(), '', 'lsof diagnostic');
    return result.stdout.split('\n').filter(line => line.includes('/dev/ptmx')).length;
  };
  const before = count();
  for (let i = 0; i < 6; i++) {
    const handle = await core.ShellExecutionService.execute('printf fm-shell-ok', process.argv[3], () => {}, new AbortController().signal, true, {env: {PATH: process.env.PATH, HOME: process.env.HOME}, sanitizationConfig: {allowedEnvironmentVariables: [], blockedEnvironmentVariables: []}});
    const result = await handle.result;
    assert.equal(result.executionMethod, 'child_process');
    assert.equal(result.exitCode, 0);
    assert.equal(result.output, 'fm-shell-ok');
  }
  const after = count();
  assert.equal(after, before, 'completed commands must not retain PTY masters');
  console.log(`ok - Gemini ${version}: launch override wins; 6 child_process commands; ptmx ${before}->${after}`);
} catch (error) {
  console.error(`not ok - Gemini ${version}: ${error.stack}`);
  process.exitCode = 1;
} finally { clearTimeout(timer); }
JS
cat >"$fakebin/gemini" <<'SH'
#!/usr/bin/env bash
exec node --experimental-vm-modules --disable-warning=ExperimentalWarning "$FM_GEMINI_SHELL_DRIVER" "$FM_GEMINI_SHELL_BINARY" "$FM_GEMINI_SHELL_WORKTREE"
SH
chmod +x "$fakebin/gemini"
HOME="$home/user-home" GEMINI_CLI_HOME="$home/user-home" \
  FM_GEMINI_SHELL_DRIVER="$TMP_ROOT/driver.mjs" FM_GEMINI_SHELL_BINARY="$GEMINI_BIN" \
  FM_GEMINI_SHELL_WORKTREE="$wt" PATH="$fakebin:$PATH" bash "$TMP_ROOT/launch.sh"
expect_code 0 $? 'installed Gemini shell consumer verification failed'
