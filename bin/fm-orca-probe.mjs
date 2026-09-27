#!/usr/bin/env node
// Read-only Orca recovery evidence. Usage: fm-orca-probe.mjs <orca-cli> <handle>
// Prints missing, unreadable, ambiguous, unverified, or process<TAB><foreground process>.
// The shell adapter owns harness-name classification. No connected shell is
// declared dead: Orca's legacy child-process boolean cannot prove that absence.
//
// `unverified` is the reading Orca gave before it had a classifier, and it is
// reserved for an install where this probe cannot run at all: no bundled
// client, a runtime below the recovery floor, or a non-local Orca. A probe
// that ran and failed, or whose reads contradicted each other, is `unreadable`.
// Neither reading proves anything, so every recovery proof still refuses.
//
// terminal.show is presentation, not process authority. Pair an exact handle's
// incarnation with terminal.list(requireFreshPtyLiveness) on its execution host.
// Even a cached operator_close needs terminal.wait's nonnegative exit code;
// synthetic disconnects carry -1. Re-read identity after the host observation.
// Never recover a stale handle by listing and picking another one.
//
// Orca 1.4.212's CLI omits inspectProcess and requireFreshPtyLiveness. Use the
// installed CLI's bundled RuntimeClient, with local routing explicitly pinned,
// rather than reading its socket/token ourselves. No npm package is installed.
// A missing client or changed response fails closed. See the active evidence
// in docs/verification/runtime-backends.md before updating this dependency.
import { realpathSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { createRequire } from 'node:module';

const [cli, handle] = process.argv.slice(2);
const require = createRequire(import.meta.url);
const nonempty = value => typeof value === 'string' && value.length > 0 && !/[\r\n\t]/.test(value);
const unverified = reason => Object.assign(Error(reason), { unverified: true });
let runtimeId;
try {
  if (!cli || !nonempty(handle)) throw Error('probe arguments');
  if (process.env.ORCA_ENVIRONMENT || process.env.ORCA_PAIRING_CODE || process.env.ORCA_REMOTE_PAIRING) throw unverified('local Orca required');
  const clientPath = resolve(dirname(realpathSync(cli)), '../app.asar.unpacked/out/cli/runtime/client.js');
  let RuntimeClient;
  try {
    ({ RuntimeClient } = require(clientPath));
  } catch {
    throw unverified('bundled client unavailable');
  }
  if (typeof RuntimeClient !== 'function') throw unverified('bundled client unavailable');
  const client = new RuntimeClient(undefined, 8000, null, null);
  const call = async (method, params) => {
    const reply = await client.call(method, params);
    if (reply.ok !== true || !nonempty(reply._meta?.runtimeId)) throw Error('unbound reply');
    runtimeId ??= reply._meta.runtimeId;
    if (reply._meta.runtimeId !== runtimeId) throw Error('runtime changed');
    return reply.result;
  };
  const status = await call('status.get', {});
  const version = /^(\d+)\.(\d+)\.(\d+)$/.exec(status.appVersion ?? '');
  if (status.graphStatus !== 'ready' || !version) throw Error('runtime not ready');
  if (Number(version[1]) < 1 || (Number(version[1]) === 1 &&
      (Number(version[2]) < 4 || (Number(version[2]) === 4 && Number(version[3]) < 212)))) throw unverified('Orca version below the recovery floor');
  const read = async () => {
    const terminal = (await call('terminal.show', { terminal: handle })).terminal;
    if (terminal?.handle !== handle || terminal.executionHostId !== 'local' ||
        !nonempty(terminal.ptyId) || !nonempty(terminal.incarnationId) ||
        !nonempty(terminal.worktreeId) || !nonempty(terminal.worktreePath) ||
        typeof terminal.connected !== 'boolean' || typeof terminal.writable !== 'boolean') throw Error('unbound terminal');
    return terminal;
  };
  const before = await read();
  const inventory = await call('terminal.list', {
    worktree: `id:${before.worktreeId}`, limit: 1000,
    requireFreshPtyLiveness: true, includeVisualLayouts: false,
  });
  if (!Array.isArray(inventory.terminals) || inventory.truncated !== false ||
      !Array.isArray(inventory.hostScope?.hostIds) ||
      !inventory.hostScope.hostIds.includes('local')) throw Error('host inventory unavailable');
  const matches = inventory.terminals.filter(row => row.ptyId === before.ptyId || row.handle === handle);
  let verdict = 'ambiguous';
  if (matches.length === 1 && before.connected && before.writable) {
    const row = matches[0];
    if (row.handle !== handle || row.ptyId !== before.ptyId || row.incarnationId !== before.incarnationId ||
        row.worktreeId !== before.worktreeId || row.executionHostId !== 'local' || !row.connected || !row.writable) throw Error('inventory identity changed');
    const evidence = (await call('terminal.inspectProcess', {
      terminal: handle, expectedIncarnationId: before.incarnationId, scanChildProcesses: true,
    })).process;
    // Positive foreground attribution can prove an agent exists; neither a
    // shell name nor hasChildProcesses=false licenses a replacement.
    if (nonempty(evidence?.foregroundProcess)) verdict = `process\t${evidence.foregroundProcess}`;
  } else if (matches.length === 0 && !before.connected && !before.writable) {
    const wait = (await call('terminal.wait', { terminal: handle, for: 'exit', timeoutMs: 1 })).wait;
    if (wait?.handle === handle && wait.condition === 'exit' && wait.satisfied === true &&
        wait.status === 'exited' && Number.isInteger(wait.exitCode) && wait.exitCode >= 0 &&
        ['operator_close', 'exited', 'signaled'].includes(wait.exitCause?.kind) &&
        wait.exitCause.kind === before.exitCause?.kind) verdict = 'missing';
  }
  const after = await read();
  for (const key of ['ptyId', 'incarnationId', 'worktreeId', 'worktreePath', 'connected', 'writable']) {
    if (after[key] !== before[key]) throw Error('terminal changed during observation');
  }
  if (after.exitCause?.kind !== before.exitCause?.kind) throw Error('exit changed');
  console.log(verdict);
} catch (err) {
  console.log(err?.unverified === true ? 'unverified' : 'unreadable');
}
