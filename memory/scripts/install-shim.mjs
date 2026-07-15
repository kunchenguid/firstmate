#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Hardened pinned-shim install: lstat the destination (never follow a
// pre-existing symlink), write to a temp file with the correct executable mode,
// fsync it, atomically rename over the destination, then validate the installed
// mode. Atomic rename replaces an existing file or symlink in place, so a
// hostile symlink at the destination is overwritten rather than followed.

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const src = path.join(root, 'shims', 'mem');
const home = process.env.HOME || os.homedir();
const destDir = path.join(home, '.local', 'bin');
const dest = path.join(destDir, 'mem');

fs.mkdirSync(destDir, { recursive: true, mode: 0o755 });

try {
  const info = fs.lstatSync(dest);
  if (info.isDirectory()) {
    console.error(`install-shim: refusing to overwrite directory at ${dest}`);
    process.exit(1);
  }
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}

const data = fs.readFileSync(src);
const tmp = path.join(destDir, `.mem.install-${process.pid}`);
const fd = fs.openSync(tmp, 'w', 0o755);
try {
  fs.writeFileSync(fd, data);
  fs.fsyncSync(fd);
} finally {
  fs.closeSync(fd);
}
fs.chmodSync(tmp, 0o755);
fs.renameSync(tmp, dest);

const finalMode = fs.statSync(dest).mode & 0o777;
if ((finalMode & 0o111) === 0) {
  console.error(`install-shim: installed shim is not executable (mode ${finalMode.toString(8)})`);
  process.exit(1);
}
console.log(`installed pinned mem shim: ${dest} (mode ${finalMode.toString(8)})`);
