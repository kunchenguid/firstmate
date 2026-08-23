#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [stateFile, requestedPath, holder] = process.argv.slice(2);
const requested = fs.realpathSync(requestedPath);
const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
if (!Array.isArray(state.worktrees)) throw new Error('treehouse state has no worktrees array');
const matches = state.worktrees.filter((entry) => {
  if (!entry || typeof entry.path !== 'string') return false;
  try { return fs.realpathSync(entry.path) === requested; } catch { return false; }
});
if (matches.length !== 1) throw new Error(`treehouse state has ${matches.length} entries for ${requested}`);
const entry = matches[0];
// Promotion supersedes both process ownership and an interrupted destruction
// reservation. Keeping `destroying` after removing its owner would prevent
// Treehouse's healing transition from making the guarded slot usable again.
entry.leased = true;
entry.lease_id ||= crypto.randomBytes(16).toString('hex');
entry.lease_holder ||= holder;
entry.leased_at ||= new Date().toISOString();
delete entry.destroying;
delete entry.owner_pid;
delete entry.owner_started_at;
const mode = fs.statSync(stateFile).mode;
const temp = `${stateFile}.fm-guard-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
let fd;
try {
  fd = fs.openSync(temp, 'wx', mode);
  fs.writeFileSync(fd, `${JSON.stringify(state, null, 2)}\n`);
  fs.fsyncSync(fd);
  fs.closeSync(fd);
  fd = undefined;
  fs.renameSync(temp, stateFile);
  const dirfd = fs.openSync(path.dirname(stateFile), 'r');
  try { fs.fsyncSync(dirfd); } finally { fs.closeSync(dirfd); }
} finally {
  if (fd !== undefined) fs.closeSync(fd);
  try { fs.unlinkSync(temp); } catch (error) { if (error.code !== 'ENOENT') throw error; }
}
