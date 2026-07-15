import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { appendRegistryEvent } from '../lib/registry.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { satisfiesRange, versionMatches } from '../lib/doctor-core.mjs';
import { memoryRoot, runMemIn, tmpRegistry } from './helpers.mjs';

// Build a dependency-free package fixture by copying only the specific entries the
// CLI needs, NOT the whole package root. Copying explicit entries avoids Node's
// self-subdirectory refusal (ERR_FS_CP_EINVAL) entirely, so this is robust for any
// valid TMPDIR, including one located under the package tree (the A34 fragility).
function copyPackageWithoutDeps(prefix) {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  for (const entry of ['bin', 'lib', 'scripts', 'shims', 'package.json', 'package-lock.json']) {
    const src = path.join(memoryRoot, entry);
    if (fs.existsSync(src)) fs.cpSync(src, path.join(fixture, entry), { recursive: true });
  }
  return fixture;
}

// Compares KEY structure only (dropped/added fields), ignoring leaf value types
// so a null vs string reason at the same key is not a schema difference.
function keyShape(value) {
  if (Array.isArray(value)) return 'array';
  if (value && typeof value === 'object') {
    const out = {};
    for (const key of Object.keys(value).sort()) out[key] = keyShape(value[key]);
    return out;
  }
  return 0;
}

test('semver range honors the minor/patch floor, not just the major', () => {
  const range = '>=20.11.0 <23';
  assert.equal(satisfiesRange('v20.0.0', range), false, 'v20.0.0 must fail the >=20.11.0 floor');
  assert.equal(satisfiesRange('v20.10.9', range), false);
  assert.equal(satisfiesRange('v20.11.0', range), true);
  assert.equal(satisfiesRange('v22.22.1', range), true);
  assert.equal(satisfiesRange('v23.0.0', range), false);
  assert.equal(versionMatches('3.25.76', '3.25.76'), true);
  assert.equal(versionMatches('3.25.75', '3.25.76'), false);
});

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

test('doctor reports critical registry as non-green', () => {
  const dir = tmpRegistry();
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'memory-registry.jsonl'), '{bad');
  const json = runMemIn(dir, ['doctor', '--json']);
  assert.equal(json.status, 1);
  const parsed = JSON.parse(json.stdout);
  assert.equal(parsed.registry.status, 'critical');
  assert.equal(parsed.ok, false);
});

test('doctor fails closed when a healthy registry has a missing or stale active index', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, {
    event: 'proposed',
    memId: 'MEM-0001',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'doctor active index fixture' }
  });
  const paths = registryPaths(dir);
  fs.unlinkSync(paths.index);

  const missing = runMemIn(dir, ['doctor', '--json']);
  assert.equal(missing.status, 1);
  const missingParsed = JSON.parse(missing.stdout);
  assert.equal(missingParsed.registry.status, 'writable');
  assert.equal(missingParsed.activeIndex.status, 'missing');
  assert.equal(missingParsed.ok, false);

  await appendRegistryEvent(dir, {
    event: 'updated',
    memId: 'MEM-0001',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'doctor active index fixture updated' }
  });
  const staleIndex = JSON.parse(fs.readFileSync(paths.index, 'utf8'));
  staleIndex.registry.seq = 0;
  fs.writeFileSync(paths.index, `${JSON.stringify(staleIndex, null, 2)}\n`);

  const stale = runMemIn(dir, ['doctor', '--json']);
  assert.equal(stale.status, 1);
  const staleParsed = JSON.parse(stale.stdout);
  assert.equal(staleParsed.registry.status, 'writable');
  assert.equal(staleParsed.activeIndex.status, 'stale');
  assert.equal(staleParsed.ok, false);
});

test('doctor --json has ONE stable schema in healthy and missing-dependency modes', () => {
  const dir = tmpRegistry();
  const healthy = JSON.parse(runMemIn(dir, ['doctor', '--json']).stdout);

  const fixture = copyPackageWithoutDeps('mem-doctor-missing-deps-');
  const bin = path.join(fixture, 'bin', 'mem.mjs');
  const result = spawnSync(process.execPath, [bin, 'doctor', '--json'], {
    cwd: fixture,
    env: { ...process.env, MEM_REGISTRY_DIR: tmpRegistry() },
    encoding: 'utf8'
  });
  assert.equal(result.status, 1, result.stderr); // missing deps -> nonzero
  const fallback = JSON.parse(result.stdout);
  assert.equal(fallback.requiredDependencies.ok, false);
  assert.ok(fallback.requiredDependencies.missing.includes('zod'));
  // Same schema (recursive key shape), no dropped fields in fallback mode.
  assert.deepEqual(keyShape(fallback), keyShape(healthy));
  assert.equal(typeof fallback.registry.reason, 'string');
  assert.equal(typeof fallback.registry.status, 'string');
});

test('A34 missing node_modules fixture prints a diagnostic without a stack trace, under any TMPDIR', () => {
  const fixture = copyPackageWithoutDeps('mem-package-missing-deps-');
  const bin = path.join(fixture, 'bin', 'mem.mjs');
  const result = spawnSync(process.execPath, [bin, 'audit'], {
    cwd: fixture,
    // Deliberately point TMPDIR under the package tree to exercise the old self-copy fragility.
    env: { ...process.env, TMPDIR: path.join(fixture, '.inner-tmp'), MEM_REGISTRY_DIR: tmpRegistry() }
  });
  const result2 = spawnSync(process.execPath, [bin, 'audit'], { cwd: fixture, env: { ...process.env, MEM_REGISTRY_DIR: tmpRegistry() }, encoding: 'utf8' });
  assert.equal(result2.status, 1);
  assert.match(result2.stderr, /required dependencies missing/);
  assert.match(result2.stderr, /npm ci/);
  assert.doesNotMatch(result2.stderr, /Error: Cannot find module|\bat Module|node:internal/);
  assert.equal(result.status, 1);
});

test('shim resolves only MEM_CLI or the canonical HOME checkout, never FM_HOME or Fleet Bridge', () => {
  const shim = fs.readFileSync(path.join(memoryRoot, 'shims', 'mem'), 'utf8');
  assert.match(shim, /MEM_CLI/);
  assert.match(shim, /\$HOME\/fleet\/firstmate-runtime\/memory\/bin\/mem\.mjs/);
  // FM_HOME must not select the executable code path.
  assert.doesNotMatch(shim, /\$\{FM_HOME/);
  assert.doesNotMatch(shim, /\.fb-redesign|fleet-bridge|worktree|candidate/i);
});

test('a hostile FM_HOME does not redirect the shim code path', () => {
  const shimPath = path.join(memoryRoot, 'shims', 'mem');
  const result = spawnSync('bash', [shimPath, 'doctor'], {
    env: { ...process.env, FM_HOME: '/tmp/noncanonical-runtime', HOME: '/tmp/noncanonical-home-xyz' },
    encoding: 'utf8'
  });
  // With a fake HOME the canonical CLI is absent; the shim must report the CANONICAL
  // HOME path, proving FM_HOME did not redirect resolution.
  assert.match(result.stderr + result.stdout, /\/tmp\/noncanonical-home-xyz\/fleet\/firstmate-runtime\/memory\/bin\/mem\.mjs/);
  assert.doesNotMatch(result.stderr + result.stdout, /noncanonical-runtime/);
});

test('install-shim writes an executable pinned shim under HOME without invoking Fleet Bridge', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-home-'));
  const result = spawnSync(process.execPath, [path.join(memoryRoot, 'scripts', 'install-shim.mjs')], {
    cwd: memoryRoot,
    env: { ...process.env, HOME: home },
    encoding: 'utf8'
  });
  assert.equal(result.status, 0, result.stderr);
  const installedPath = path.join(home, '.local', 'bin', 'mem');
  const installed = fs.readFileSync(installedPath, 'utf8');
  assert.doesNotMatch(installed, /\.fb-redesign|fleet-bridge|worktree|candidate/i);
  assert.notEqual(fs.statSync(installedPath).mode & 0o111, 0, 'installed shim must be executable');
});

test('install-shim replaces a pre-existing symlink safely instead of following it', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-home-symlink-'));
  const binDir = path.join(home, '.local', 'bin');
  fs.mkdirSync(binDir, { recursive: true });
  const victim = path.join(home, 'victim.txt');
  fs.writeFileSync(victim, 'DO NOT OVERWRITE');
  fs.symlinkSync(victim, path.join(binDir, 'mem')); // hostile pre-existing symlink
  const result = spawnSync(process.execPath, [path.join(memoryRoot, 'scripts', 'install-shim.mjs')], {
    cwd: memoryRoot,
    env: { ...process.env, HOME: home },
    encoding: 'utf8'
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(victim, 'utf8'), 'DO NOT OVERWRITE', 'symlink target must not be followed/overwritten');
  assert.equal(fs.lstatSync(path.join(binDir, 'mem')).isSymbolicLink(), false, 'installed shim is a real file, not a symlink');
  assert.match(fs.readFileSync(path.join(binDir, 'mem'), 'utf8'), /pinned canonical mem shim/i);
});
