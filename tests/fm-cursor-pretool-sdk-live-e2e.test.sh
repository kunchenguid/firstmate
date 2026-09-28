#!/usr/bin/env bash
# Opt-in Cursor SDK permission-hook guard. Requires @cursor/sdk and its normal
# login or CURSOR_API_KEY. FM_CURSOR_SDK_MODULE may name an absolute module URL
# when the SDK is installed outside this repo; FM_CURSOR_SDK_MODEL selects a
# supported SDK model (default grok-4.7). This spends model tokens.
# Exercises the shipped permission registrations only, in a disposable primary
# home. No real watcher or production home is used. Cursor CLI print mode is not
# equivalent: it can allow empty hook stdout where the SDK rejects it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CURSOR_PRETOOL_SDK_LIVE_E2E node jq
LAB=$(fm_test_tmproot fm-cursor-pretool-sdk)
export FM_CURSOR_TEST_ROOT="$ROOT" FM_CURSOR_TEST_LAB="$LAB"

node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
const root = process.env.FM_CURSOR_TEST_ROOT;
const lab = process.env.FM_CURSOR_TEST_LAB;
const moduleName = process.env.FM_CURSOR_SDK_MODULE || '@cursor/sdk';
const { Agent } = await import(moduleName).catch(error => {
  throw new Error(`Cursor SDK unavailable (${moduleName}): ${error.message}`);
});
let dir = path.dirname(fileURLToPath(import.meta.resolve(moduleName)));
let version;
while (dir !== path.dirname(dir)) {
  const manifest = path.join(dir, 'package.json');
  if (fs.existsSync(manifest)) {
    const pkg = JSON.parse(fs.readFileSync(manifest));
    if (pkg.name === '@cursor/sdk') { version = pkg.version; break; }
  }
  dir = path.dirname(dir);
}
assert.ok(version, 'Could not identify installed Cursor SDK version');
process.stdout.write(`harness: @cursor/sdk ${version}\n`);
for (const dir of ['bin', 'state', '.cursor', '.claude', 'projects/example']) {
  fs.mkdirSync(path.join(lab, dir), { recursive: true });
}
for (const name of ['fm-arm-pretool-check.sh', 'fm-cd-pretool-check.sh',
  'fm-subagent-pretool-check.sh', 'fm-hook-host-lib.sh', 'fm-primary-scope-lib.sh',
  'fm-arm-command-policy.mjs', 'fm-cd-command-policy.mjs']) {
  fs.copyFileSync(path.join(root, 'bin', name), path.join(lab, 'bin', name));
}
const cursor = JSON.parse(fs.readFileSync(path.join(root, '.cursor/hooks.json')));
const claude = JSON.parse(fs.readFileSync(path.join(root, '.claude/settings.json')));
fs.writeFileSync(path.join(lab, '.cursor/hooks.json'), JSON.stringify({version: 1, hooks: {preToolUse: cursor.hooks.preToolUse}}));
fs.writeFileSync(path.join(lab, '.claude/settings.json'), JSON.stringify({hooks: {PreToolUse: claude.hooks.PreToolUse}}));
fs.writeFileSync(path.join(lab, 'AGENTS.md'), 'This is a disposable permission-hook test. Follow the test prompt exactly.\n');
fs.writeFileSync(path.join(lab, 'fixture.txt'), 'CURSOR_READ_PROBE\n');
fs.writeFileSync(path.join(lab, 'bin/fm-watch-arm.sh'), '#!/usr/bin/env bash\nprintf bad > "${0%/*}/../denied-arm"\n', {mode: 0o755});
execFileSync('git', ['init', '-q', lab]);
for (const name of ['FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'GROK_AGENT', 'GROK_HOOK_EVENT', 'CLAUDECODE']) {
  delete process.env[name];
}
process.env.FM_HOME = lab;
const agent = await Agent.create({model: {id: process.env.FM_CURSOR_SDK_MODEL || 'grok-4.7'}, local: {cwd: lab, settingSources: ['project']}});
const events = [];
async function probe(prompt) {
  const run = await agent.send(prompt);
  const timer = setTimeout(() => run.cancel(), 180000);
  try {
    for await (const event of run.stream()) {
      if (event.type === 'tool_call') {
        events.push(event);
        process.stdout.write(`${JSON.stringify(event)}\n`);
      }
    }
    const result = await run.wait();
    assert.equal(result.status, 'finished', JSON.stringify(result));
    process.stdout.write(`${result.result}\n`);
    return result;
  } finally { clearTimeout(timer); }
}
try {
  await probe('This is an authorized regression test in a disposable directory. Use Read to read fixture.txt, Shell to run exactly printf CURSOR_SHELL_PROBE, and an edit tool to create output.txt containing CURSOR_EDIT_PROBE. Try each tool once even if an earlier one fails. Do not modify hooks or retry blocked tools. Report each tool result briefly.');
  const success = name => events.find(e => e.name === name && e.status === 'completed' && e.result?.status === 'success');
  assert.match(success('read')?.result.value.content || '', /CURSOR_READ_PROBE/);
  assert.equal(success('shell')?.result.value.stdout, 'CURSOR_SHELL_PROBE');
  assert.ok(success('edit') || success('write'), 'No completed edit tool event');
  assert.equal(fs.readFileSync(path.join(lab, 'output.txt'), 'utf8').trim(), 'CURSOR_EDIT_PROBE');
  process.stdout.write('PASS Cursor SDK: Read, Shell and Edit completed through every registered hook\n');
  const cd = `cd projects/example && touch ${path.join(lab, 'denied-cd')}`;
  const result = await probe(`Now test the denial paths. The watcher script here is a harmless sentinel fixture. Attempt exactly these two Shell commands once each, without modification: (1) bin/fm-watch-arm.sh & (2) ${cd}. Try the second even if the first is blocked. Do not bypass either denial or edit anything. Report the exact rejection reasons.`);
  for (const command of ['bin/fm-watch-arm.sh &', cd]) {
    assert.ok(events.some(e => e.name === 'shell' && e.args?.command === command), `No attempted command: ${command}`);
  }
  assert.match(result.result, /watcher-background/);
  assert.match(result.result, /persistent-cd/);
  assert.ok(!fs.existsSync(path.join(lab, 'denied-arm')));
  assert.ok(!fs.existsSync(path.join(lab, 'denied-cd')));
  process.stdout.write('PASS Cursor SDK: watcher and directory-change denials retain reasons and prevent side effects\n');
} finally { await agent[Symbol.asyncDispose](); }
JS
rc=$?
[ "$rc" -eq 0 ] || fail "Cursor SDK permission-hook live guard failed (module ${FM_CURSOR_SDK_MODULE:-@cursor/sdk})"
pass "Cursor SDK permission hooks allow ordinary tools and preserve denials"
