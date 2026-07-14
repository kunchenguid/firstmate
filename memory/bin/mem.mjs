#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const pkgPath = path.join(root, 'package.json');
const lockPath = path.join(root, 'package-lock.json');

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function parseMajor(version) {
  return Number(String(version).replace(/^v/, '').split('.')[0]);
}

function nodeCompatible() {
  const major = parseMajor(process.version);
  return major >= 20 && major < 23;
}

function dependencyStatus() {
  const pkg = readJson(pkgPath);
  const missing = [];
  for (const name of Object.keys(pkg.dependencies || {})) {
    const depPkg = path.join(root, 'node_modules', name, 'package.json');
    if (!fs.existsSync(depPkg)) missing.push(name);
  }
  return { pkg, missing };
}

function fallbackDoctor(json) {
  const required = { ok: false, missing: [], error: null };
  try {
    required.missing = dependencyStatus().missing;
    required.ok = required.missing.length === 0;
  } catch (error) {
    required.error = error.message;
  }
  const payload = {
    ok: nodeCompatible() && required.ok,
    cli: { available: true, path: fileURLToPath(import.meta.url) },
    canonicalCheckout: {
      path: process.env.FM_HOME || path.join(process.env.HOME || '', 'fleet', 'firstmate-runtime'),
      source: process.env.FM_HOME ? 'FM_HOME' : 'HOME'
    },
    node: { version: process.version, compatible: nodeCompatible(), required: '>=20.11.0 <23' },
    packageLock: { path: lockPath, present: fs.existsSync(lockPath) },
    requiredDependencies: required,
    pglite: { available: false, required: false, status: 'not installed for current milestone' },
    vectorExtension: { available: false, required: false, status: 'not installed for current milestone' },
    embeddingProvider: { configured: Boolean(process.env.MEM_EMBEDDING_KEY || process.env.OPENAI_API_KEY), required: false },
    registry: { path: process.env.MEM_REGISTRY_DIR || path.join(process.env.HOME || '', 'fleet', 'state', 'memory'), status: 'unknown' },
    activeIndex: { status: 'unknown' }
  };
  if (json) {
    console.log(JSON.stringify(payload, null, 2));
  } else {
    console.log(`Memory CLI: available (${payload.cli.path})`);
    console.log(`Canonical checkout: ${payload.canonicalCheckout.path}`);
    console.log(`Node: ${payload.node.version} (${payload.node.compatible ? 'compatible' : 'incompatible, fix: install Node >=20.11 <23'})`);
    console.log(`Package lock: ${payload.packageLock.present ? 'present' : `missing, fix: cd ${root} && npm install --package-lock-only`}`);
    console.log(required.ok ? 'Required dependencies: available' : `Required dependencies: missing ${required.missing.join(', ') || required.error}; fix: cd ${root} && npm ci`);
    console.log('PGlite: not installed for current milestone');
    console.log('Vector extension: not installed for current milestone');
    console.log(`Embedding provider: ${payload.embeddingProvider.configured ? 'configured' : 'not configured (optional)'}`);
  }
  process.exitCode = payload.ok ? 0 : 1;
}

const args = process.argv.slice(2);
const wantsDoctor = args[0] === 'doctor';
const wantsJson = args.includes('--json');

if (!nodeCompatible()) {
  const msg = `mem: Node ${process.version} is unsupported; fix: install Node >=20.11 <23 and rerun cd ${root} && npm ci`;
  if (wantsDoctor) fallbackDoctor(wantsJson);
  else {
    console.error(msg);
    process.exit(1);
  }
} else {
  const { missing } = dependencyStatus();
  if (missing.length > 0) {
    if (wantsDoctor) fallbackDoctor(wantsJson);
    else {
      console.error(`mem: required dependencies missing (${missing.join(', ')}); fix: cd ${root} && npm ci`);
      process.exit(1);
    }
  } else {
    const { main } = await import('../lib/cli.mjs');
    await main(args, { root });
  }
}
