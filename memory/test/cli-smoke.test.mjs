import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { registryPaths } from '../lib/paths.mjs';
import { runMemIn, tmpRegistry } from './helpers.mjs';

test('CLI fixture smoke exercises PR-1 verbs on an isolated registry with valid transitions only', () => {
  const dir = tmpRegistry();
  let result = runMemIn(dir, ['propose', '--summary', 'Isolated smoke memory', '--body', 'Created only in a disposable registry.', '--keyword', 'smoke', '--project', '*', '--kind', 'dispatch', '--risk-class', 'critical', '--json']);
  assert.equal(result.status, 0, result.stderr);
  const memId = JSON.parse(result.stdout).memId;
  // High-impact (dispatch/critical) memory needs captain authority to activate.
  result = runMemIn(dir, ['activate', memId, '--actor-kind', 'captain', '--actor', 'captain', '--evidence', 'test:cli-smoke', '--method', 'test', '--json']);
  assert.equal(result.status, 0, result.stderr);
  result = runMemIn(dir, ['show', memId, '--chain', '--json']);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).record.status, 'active');

  result = runMemIn(dir, ['snapshot', '--json']);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(fs.existsSync(JSON.parse(result.stdout).file));
  result = runMemIn(dir, ['audit', '--json']);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).activeIndex.status, 'current');

  // Valid supersession: propose + activate a successor, then supersede the original.
  const second = runMemIn(dir, ['propose', '--summary', 'Replacement smoke memory', '--json']);
  const successor = JSON.parse(second.stdout).memId;
  result = runMemIn(dir, ['activate', successor, '--actor-kind', 'captain', '--actor', 'captain', '--evidence', 'test:cli-smoke', '--method', 'test', '--json']);
  assert.equal(result.status, 0, result.stderr);
  result = runMemIn(dir, ['supersede', memId, '--successor', successor, '--reason', 'fixture supersession', '--json']);
  assert.equal(result.status, 0, result.stderr);

  const chain = JSON.parse(runMemIn(dir, ['show', memId, '--json']).stdout).record;
  assert.equal(chain.status, 'superseded');
  assert.equal(chain.supersededBy, successor);
  assert.ok(fs.readFileSync(registryPaths(dir).registry, 'utf8').includes('Replacement smoke memory'));
});

test('summary-only CLI update preserves omitted fields', () => {
  const dir = tmpRegistry();
  const memId = JSON.parse(runMemIn(dir, ['propose', '--summary', 'orig', '--body', 'keep me', '--scope', 'project', '--project', 'firstmate', '--kind', 'dispatch', '--keyword', 'k1', '--confidence', 'observed', '--risk-class', 'critical', '--json']).stdout).memId;
  const update = runMemIn(dir, ['update', memId, '--summary', 'changed', '--json']);
  assert.equal(update.status, 0, update.stderr);
  const record = JSON.parse(runMemIn(dir, ['show', memId, '--json']).stdout).record;
  assert.equal(record.summary, 'changed');
  assert.equal(record.body, 'keep me');
  assert.equal(record.scope, 'project');
  assert.deepEqual(record.projects, ['firstmate']);
  assert.deepEqual(record.keywords, ['k1']);
  assert.equal(record.confidence, 'observed');
  assert.equal(record.riskClass, 'critical');
});

test('canonical non-mutating fixture creates an empty index without production records', () => {
  const dir = tmpRegistry();
  const project = runMemIn(dir, ['project', '--json']);
  assert.equal(project.status, 0, project.stderr);
  const audit = runMemIn(dir, ['audit', '--json']);
  assert.equal(audit.status, 0, audit.stderr);
  const parsed = JSON.parse(audit.stdout);
  assert.equal(parsed.records.total, 0);
  assert.equal(parsed.records.active, 0);
  assert.equal(parsed.activeIndex.status, 'current');
  assert.equal(fs.existsSync(registryPaths(dir).registry), false);
});
