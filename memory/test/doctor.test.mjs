import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { checkDoctor } from '../lib/doctor.mjs';
import { memoryRoot, memBin, runMemIn, tmpRegistry } from './helpers.mjs';

test('mem doctor and --json report required PR-1 probes', () => {
  const dir = tmpRegistry();
  const human = runMemIn(dir, ['doctor']);
  assert.equal(human.status, 0, human.stderr);
  assert.match(human.stdout, /Memory CLI: available/);
  assert.match(human.stdout, /PGlite: not installed for current milestone/);
  assert.match(human.stdout, /Embedding provider: not configured/);
  const json = runMemIn(dir, ['doctor', '--json']);
  assert.equal(json.status, 0, json.stderr);
  const parsed = JSON.parse(json.stdout);
  assert.equal(parsed.cli.available, true);
  assert.equal(parsed.node.compatible, true);
  assert.equal(parsed.requiredDependencies.ok, true);
  assert.equal(parsed.pglite.required, false);
  assert.equal(parsed.vectorExtension.required, false);
  assert.equal(parsed.registry.status, 'missing');
});

test('doctor reports critical registry as non-green', async () => {
  const dir = tmpRegistry();
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'memory-registry.jsonl'), '{bad');
  const json = runMemIn(dir, ['doctor', '--json']);
  assert.equal(json.status, 1);
  const parsed = JSON.parse(json.stdout);
  assert.equal(parsed.registry.status, 'critical');
  assert.equal(parsed.ok, false);
});

test('A34 missing node_modules fixture prints diagnostic without stack trace', () => {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-package-missing-deps-'));
  fs.cpSync(memoryRoot, fixture, { recursive: true, filter: (src) => !src.includes(`${path.sep}node_modules`) });
  const bin = path.join(fixture, 'bin', 'mem.mjs');
  const result = spawnSync(process.execPath, [bin, 'audit'], {
    cwd: fixture,
    env: { ...process.env, MEM_REGISTRY_DIR: tmpRegistry() },
    encoding: 'utf8'
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /required dependencies missing/);
  assert.match(result.stderr, /npm ci/);
  assert.doesNotMatch(result.stderr, /Error: Cannot find module|stack|at Module/);
});

test('shim resolves only MEM_CLI or canonical FM_HOME/HOME path', () => {
  const shim = fs.readFileSync(path.join(memoryRoot, 'shims', 'mem'), 'utf8');
  assert.match(shim, /MEM_CLI/);
  assert.match(shim, /FM_HOME:-\$HOME\/fleet\/firstmate-runtime/);
  assert.doesNotMatch(shim, /\.fb-redesign|fleet-bridge|worktree|candidate/i);
});

test('install-shim writes pinned shim under HOME without invoking Fleet Bridge', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-home-'));
  const result = spawnSync(process.execPath, [path.join(memoryRoot, 'scripts', 'install-shim.mjs')], {
    cwd: memoryRoot,
    env: { ...process.env, HOME: home },
    encoding: 'utf8'
  });
  assert.equal(result.status, 0, result.stderr);
  const installed = fs.readFileSync(path.join(home, '.local', 'bin', 'mem'), 'utf8');
  assert.doesNotMatch(installed, /\.fb-redesign|fleet-bridge|worktree|candidate/i);
});
