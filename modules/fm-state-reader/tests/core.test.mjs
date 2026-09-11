import test from 'node:test';
import assert from 'node:assert/strict';
import { task, pool, ledger, safe } from '../src/index.mjs';
const record = text => ({ text, at: 1000, truncated: false });
test('plain domain records preserve spaces and refuse invented idle evidence', () => {
  const args = ['task', record('harness=pi\nmodel=example\neffort=low\nworktree=/tmp/space here'), record('working: tests'), record('state=idle gen=old ts=950')];
  assert.equal(task(...args, record('new'), 1200).busy, 'unknown');
  const t = task(...args, record('old'), 1200); assert.equal(t.busy, 'idle'); assert.equal(t.age, 200); assert.equal(t.worktree, '/tmp/space here');
  assert.equal(task('missing', null, null, null, null, 1200).busy, 'unknown');
  const partial = task('partial', { ...record('harness=pi'), truncated: true }, { ...record('fragment\nworking: last'), truncated: true }, args[3], record('old'), 1200);
  assert.equal(partial.busy, 'unknown'); assert.equal(partial.truncated, true); assert.deepEqual(partial.lines, ['working: last']);
  assert.equal(safe('token=hidden \x1b'), '[redacted] ?');
});
test('pool and ledger corruption remain unknown or explicitly incomplete', () => {
  assert.deepEqual(pool(record('{"worktrees":[{"leased":true},{"leased":false}]}')), { used: 1, capacity: 2 });
  assert.equal(pool(record('{"worktrees":[{}]}')), null); assert.equal(pool(null), null);
  assert.deepEqual(ledger({ ...record('fragment\n{"ok":true}\ninvalid\n'), truncated: true }), { rows: [{ ok: true }], malformed: 1, truncated: true });
});
