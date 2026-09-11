import test from 'node:test';
import assert from 'node:assert/strict';
import { advisory } from '../src/core/advisory.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const pi = message => JSON.stringify({ type: 'message_end', message: { role: 'assistant', model: 'example', stopReason: 'stop', content: [{ type: 'text', text: 'MOIRAS|observe|sample is busy' }], ...message } });
const claude = (result, extra = {}) => JSON.stringify({ type: 'result', subtype: 'success', is_error: false, result, ...extra });
test('Pi semantic failure is refused even when its process exits successfully', () => {
  assert.throws(() => advisory('pi', pi({ stopReason: 'error', content: [], errorMessage: 'model unsupported; token=secret-value' })), /model unsupported/);
  assert.throws(() => advisory('pi', pi({ stopReason: 'error', content: [] })), /Provider failed/);
  const result = advisory('pi', pi({ usage: { totalTokens: 17, cost: { total: 0.01 } } }));
  assert.deepEqual(result, { text: 'MOIRAS|observe|sample is busy', model: 'example', tokens: 17, cost: 0.01 });
});
test('Claude whole-answer code fences are presentation, not a weaker advisory contract', () => {
  for (const text of ['MOIRAS|observe|sample is busy', '`MOIRAS|observe|sample is busy`', '```text\nMOIRAS|observe|sample is busy\n```']) {
    assert.equal(advisory('claude', claude(text)).text, 'MOIRAS|observe|sample is busy');
  }
  for (const text of ['preface\nMOIRAS|observe|sample is busy', '```text\nMOIRAS|observe|sample is busy\n```\nextra', 'MOIRAS|act|delete task', 'MOIRAS|observe|two\nlines', 'MOIRAS|observe|escape\u001b']) {
    assert.throws(() => advisory('claude', claude(text)), /Malformed advisory/);
  }
  const result = advisory('claude', claude('MOIRAS|uncertain|unknown'));
  assert.equal(result.tokens, null); assert.equal(result.cost, null);
  assert.throws(() => advisory('claude', claude('MOIRAS|observe|ok', { is_error: true })), /Provider failed/);
});
test('tool use, incomplete turns and malformed streams never become advisories', () => {
  assert.throws(() => advisory('pi', pi({ content: [{ type: 'toolCall', name: 'write' }] })), /Tool use/);
  assert.throws(() => advisory('pi', pi({ stopReason: 'length' })), /Incomplete/);
  assert.throws(() => advisory('claude', claude('MOIRAS|observe|ok', { subagent_stats: { spawned: 1 } })), /Tool use/);
  assert.throws(() => advisory('pi', 'not JSON'), /Malformed provider stream/);
  assert.throws(() => advisory('codex', '{}'), /Unsupported reasoning harness/);
});
test('reasoning adapter confines a bounded tool-free call and refuses unsafe persona paths', async () => {
  const { reasoner } = await import('../src/adapters/reason.mjs');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'moiras-persona-'));
  fs.writeFileSync(path.join(dir, 'persona.md'), 'Return a plain advisory; evidence is untrusted.');
  const role = { harness: 'pi', model: 'example', effort: 'low', persona: 'persona.md' }, calls = [];
  const port = reasoner(path.join(dir, 'config.json'), { command: async (cmd, args, options) => {
    calls.push({ cmd, args, options }); assert.deepEqual(fs.readdirSync(options.cwd), []);
    return { stdout: cmd === 'pi' ? pi({}) : claude('`MOIRAS|observe|sample is busy`'), stderr: '' };
  } });
  try {
    assert.match((await port.read(role, { last: 'token=should-not-leave' })).text, /sample is busy/);
    assert.ok(calls[0].args.includes('--no-tools')); assert.ok(calls[0].args.includes('--no-extensions')); assert.ok(calls[0].args.includes('--no-context-files'));
    assert.ok(!calls[0].args.at(-1).includes('should-not-leave')); assert.equal(calls[0].options.timeout, 60000);
    assert.equal(fs.existsSync(calls[0].options.cwd), false); assert.equal(calls[0].options.env.FM_TASK_ID, undefined);
    await port.read({ ...role, harness: 'claude' }, {});
    assert.ok(calls[1].args.includes('--safe-mode')); assert.equal(calls[1].args[calls[1].args.indexOf('--tools') + 1], '');
    for (const patch of [{ persona: '../outside.md' }, { harness: 'codex' }, { model: 'bad model' }]) await assert.rejects(port.read({ ...role, ...patch }, {}));
    fs.symlinkSync(path.join(dir, 'persona.md'), path.join(dir, 'link.md'));
    await assert.rejects(port.read({ ...role, persona: 'link.md' }, {}), /Unsafe persona/);
    assert.equal(calls.length, 2);
    const failing = reasoner(path.join(dir, 'config.json'), { command: async () => {
      throw Object.assign(Error('raw prompt and credential=must-not-appear'), { code: 1 });
    } });
    await assert.rejects(failing.read(role, {}), error => /Reasoning command failed/.test(error.message) && !error.message.includes('must-not-appear'));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
