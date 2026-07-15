import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';

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

// Async spawn of a real, independent `mem` OS process. Used by the cross-process
// concurrency stress: this launches genuine separate processes contending for the
// registry lock, which an in-process Promise test cannot exercise.
export function spawnMemIn(dir, args, env = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [memBin, ...args], {
      cwd: memoryRoot,
      env: { ...process.env, MEM_REGISTRY_DIR: dir, MEM_LOCK_WAIT_MS: '30000', ...env }
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('exit', (code) => resolve({ code, stdout, stderr }));
  });
}

export function writeJsonl(file, rows) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, rows.map((row) => (typeof row === 'string' ? row : JSON.stringify(row))).join('\n') + '\n');
}
