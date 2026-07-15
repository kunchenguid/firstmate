#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { assembleDoctor, packageLockStatus, satisfiesRange, versionMatches } from '../lib/doctor-core.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const pkgPath = path.join(root, 'package.json');
const lockPath = path.join(root, 'package-lock.json');

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

const pkg = readJson(pkgPath);
const engines = pkg.engines?.node || '>=20.11.0 <23';

function nodeCompatible() {
  return satisfiesRange(process.version, engines);
}

function dependencyStatus() {
  const missing = [];
  const mismatched = [];
  for (const [name, want] of Object.entries(pkg.dependencies || {})) {
    const depPkg = path.join(root, 'node_modules', name, 'package.json');
    if (!fs.existsSync(depPkg)) {
      missing.push(name);
      continue;
    }
    try {
      const installed = readJson(depPkg).version;
      if (!versionMatches(installed, want)) mismatched.push(`${name}@${installed} != ${want}`);
    } catch {
      missing.push(name);
    }
  }
  return { ok: missing.length === 0 && mismatched.length === 0, missing, mismatched };
}

// Fallback doctor emits the SAME stable schema as lib/doctor.mjs. Probes that
// cannot run without dependencies (the registry fold needs zod) report an explicit
// status + reason rather than dropping fields.
function fallbackDoctor(json) {
  const lock = fs.existsSync(lockPath) ? readJson(lockPath) : null;
  const reason = 'required dependencies missing; run npm ci in the memory package';
  const payload = assembleDoctor({
    nodeVersion: process.version,
    engines,
    cli: { available: true, path: fileURLToPath(import.meta.url) },
    canonicalCheckout: { path: path.join(process.env.HOME || '', 'fleet', 'firstmate-runtime'), source: 'HOME' },
    packageLock: packageLockStatus(lock, pkg, lockPath),
    requiredDependencies: dependencyStatus(),
    pglite: { available: false, required: false, status: 'not installed for current milestone' },
    vectorExtension: { available: false, required: false, status: 'not installed for current milestone' },
    embeddingProvider: { configured: Boolean(process.env.MEM_EMBEDDING_KEY || process.env.OPENAI_API_KEY), required: false, status: 'optional' },
    registry: { path: process.env.MEM_REGISTRY_DIR || path.join(process.env.HOME || '', 'fleet', 'state', 'memory'), status: 'unknown', health: null, reason },
    snapshots: { health: null, outstanding: [], issues: [], path: null, reason },
    activeIndex: { status: 'unknown', watermark: null, reason }
  });
  if (json) {
    console.log(JSON.stringify(payload, null, 2));
  } else {
    console.log(`Memory CLI: available (${payload.cli.path})`);
    console.log(`Canonical checkout: ${payload.canonicalCheckout.path}`);
    console.log(`Node: ${payload.node.version} (${payload.node.compatible ? 'compatible' : 'incompatible, fix: install Node >=20.11 <23'})`);
    console.log(`Package lock: ${payload.packageLock.present ? (payload.packageLock.current ? 'current' : 'not current') : `missing, fix: cd ${root} && npm install --package-lock-only`}`);
    const dep = payload.requiredDependencies;
    console.log(dep.ok ? 'Required dependencies: available' : `Required dependencies: missing ${[...dep.missing, ...dep.mismatched].join(', ')}; fix: cd ${root} && npm ci`);
    console.log('PGlite: not installed for current milestone');
    console.log('Vector extension: not installed for current milestone');
    console.log(`Embedding provider: ${payload.embeddingProvider.configured ? 'configured' : 'not configured (optional)'}`);
    console.log(`Registry: ${payload.registry.status} (${payload.registry.reason})`);
    console.log(`Active-memory index: ${payload.activeIndex.status}`);
  }
  process.exitCode = payload.ok ? 0 : 1;
}

const args = process.argv.slice(2);
const wantsDoctor = args[0] === 'doctor';
const wantsJson = args.includes('--json');

if (!nodeCompatible()) {
  if (wantsDoctor) {
    fallbackDoctor(wantsJson);
  } else {
    console.error(`mem: Node ${process.version} is unsupported (requires ${engines}); fix: install a supported Node and rerun cd ${root} && npm ci`);
    process.exit(1);
  }
} else {
  const { ok, missing, mismatched } = dependencyStatus();
  if (!ok) {
    if (wantsDoctor) {
      fallbackDoctor(wantsJson);
    } else {
      console.error(`mem: required dependencies missing (${[...missing, ...mismatched].join(', ')}); fix: cd ${root} && npm ci`);
      process.exit(1);
    }
  } else {
    const { main } = await import('../lib/cli.mjs');
    await main(args, { root });
  }
}
