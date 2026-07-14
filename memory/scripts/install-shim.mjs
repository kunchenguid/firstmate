#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const src = path.join(root, 'shims', 'mem');
const home = process.env.HOME || os.homedir();
const destDir = path.join(home, '.local', 'bin');
const dest = path.join(destDir, 'mem');

fs.mkdirSync(destDir, { recursive: true, mode: 0o755 });
fs.copyFileSync(src, dest);
fs.chmodSync(dest, 0o755);
console.log(`installed pinned mem shim: ${dest}`);
