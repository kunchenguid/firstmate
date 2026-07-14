import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

export const memoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const memBin = path.join(memoryRoot, 'bin', 'mem.mjs');

export function tmpRegistry() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'mem-registry-'));
}

export function runMem(args, env = {}) {
  return spawnSync(process.execPath, [memBin, ...args], {
    cwd: memoryRoot,
    env: { ...process.env, MEM_REGISTRY_DIR: tmpRegistry(), ...env },
    encoding: 'utf8'
  });
}

export function runMemIn(dir, args, env = {}) {
  return spawnSync(process.execPath, [memBin, ...args], {
    cwd: memoryRoot,
    env: { ...process.env, MEM_REGISTRY_DIR: dir, ...env },
    encoding: 'utf8'
  });
}

export function writeJsonl(file, rows) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, rows.map((row) => typeof row === 'string' ? row : JSON.stringify(row)).join('\n') + '\n');
}
