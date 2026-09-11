import test from 'node:test';
import assert from 'node:assert/strict';
import { snapshot, readLedger } from '../src/index.mjs';
import { fakeFiles } from './fake-files.mjs';
test('snapshot orchestration uses fake I/O and reports absent evidence as unknown', () => {
  const source = fakeFiles({ 'state/a.meta': 'harness=pi\nmodel=small', 'state/a.status': 'working: red\nworking: green', 'state/.last-watcher-beat': '', 'state/.wake-queue': 'one\ntwo\n', 'pool:0': '{"worktrees":[{"leased":true}]}' });
  const s = snapshot(source, 1100);
  assert.equal(s.workers[0].harness, 'pi'); assert.equal(s.workers[0].busy, 'unknown'); assert.equal(s.beaconAge, 100); assert.equal(s.wake.count, 2);
  assert.deepEqual(s.pools, [{ key: 'pool:0', used: 1, capacity: 1 }]);
  const absent = snapshot(fakeFiles(), 1100); assert.equal(absent.beaconAt, null); assert.equal(absent.wake, null);
  assert.deepEqual(readLedger(source, 'data/routing-outcomes.jsonl').rows, []);
  let changes = 0; const close = source.watch(() => changes++); source.set('state/a.status', 'done: check'); close(); source.set('state/a.status', 'paused: wait'); assert.equal(changes, 1);
});
