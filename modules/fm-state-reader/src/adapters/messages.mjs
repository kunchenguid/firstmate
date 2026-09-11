import fs from 'node:fs';
import path from 'node:path';
import { execFile, execFileSync } from 'node:child_process';

function messageRunner({ home, root, service }) {
  home = fs.realpathSync(home);
  root = fs.realpathSync(root);
  const cwd = process.cwd();
  const env = { ...process.env, FM_HOME: home, FM_ROOT_OVERRIDE: root, FM_STATE_OVERRIDE: path.join(home, 'state') };
  if (service !== undefined) {
    if (typeof service !== 'string' || !/^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$/.test(service) || service === 'supervisor') throw Error('Invalid service name');
    env.FM_SERVICE_ID = service;
    delete env.FM_TASK_ID;
  }
  const run = args => new Promise((resolve, reject) => {
    const child = execFile(path.join(root, 'bin/fm-message.sh'), args, { cwd, env, timeout: 30000, maxBuffer: 1048576 }, (error, stdout) => {
      // Exit 3 is a retained partial fan-out, not permission to mint a new id.
      if (error && (args[0] !== 'send' || error.code !== 3)) {
        reject(Error(`Message ${args[0]} failed: ${error.killed ? 'timeout' : error.code ?? error.signal ?? 'unknown'}`));
      } else resolve({ stdout, partial: error?.code === 3 });
    });
    child.stdin?.end();
  });
  return { run, sync: args => execFileSync(path.join(root, 'bin/fm-message.sh'), args, { cwd, env, timeout: 30000, maxBuffer: 1048576, stdio: 'pipe' }) };
}

/** @returns {import('../ports/messages.d.ts').MessagePort} */
export function messages(options) { return messagePort(messageRunner(options).run); }

/** @returns {Promise<import('../ports/messages.d.ts').ServiceMessagePort>} */
export async function serviceMessages({ home, root, name }) {
  if (name === undefined) throw Error('Service name required');
  const { run, sync } = messageRunner({ home, root, service: name });
  const closeArgs = ['service', 'deregister', name, String(process.pid)];
  const cleanup = () => {
    try { sync(closeArgs); } catch { process.stderr.write('warning: service deregistration failed; registration retained for inspection\n'); }
  };
  process.once('exit', cleanup);
  try { await run(['service', 'register', name, String(process.pid)]); }
  catch (error) { cleanup(); process.off('exit', cleanup); throw error; }
  return {
    ...messagePort(run),
    async close() { await run(closeArgs); process.off('exit', cleanup); },
  };
}

function messagePort(run) {
  const send = async args => {
    const { stdout, partial } = await run(['send', ...args]);
    const receipt = /^message=(msg-[a-f0-9]{32}) thread=([A-Za-z0-9._-]+) delivered=([A-Za-z0-9._ -]*)\n$/.exec(stdout);
    if (!receipt) throw Error('Message sender returned no valid delivery receipt');
    return { id: receipt[1], thread: receipt[2], delivered: receipt[3].split(' ').filter(Boolean), partial };
  };
  return {
    async send(to, text, options = {}) {
      if (!Array.isArray(to) || !to.length || to.some(id => typeof id !== 'string' || !/^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$/.test(id)) || new Set(to).size !== to.length) throw Error('Invalid message recipients');
      if (typeof text !== 'string' || Object.keys(options).some(key => !['thread', 'kind', 'ref'].includes(key))) throw Error('Invalid message arguments');
      const args = [to.join(',')];
      for (const key of ['thread', 'kind', 'ref']) {
        if (options[key] !== undefined) {
          if (typeof options[key] !== 'string' || !options[key]) throw Error('Invalid message option');
          args.push(`--${key}`, options[key]);
        }
      }
      // Explicit kind selects the shared structured route even for a supervisor.
      if (!options.kind) args.push('--kind', 'note');
      return send([...args, '--', text]);
    },
    async reply(ref, text) {
      if (typeof ref !== 'string' || typeof text !== 'string') throw Error('Invalid reply arguments');
      return send(['--reply', ref, '--', text]);
    },
    async retry(id, thread) {
      if (typeof id !== 'string' || typeof thread !== 'string') throw Error('Invalid retry arguments');
      return send(['--retry', id, '--thread', thread]);
    },
    async receive() {
      const { stdout } = await run(['receive']);
      return stdout.split('\n').filter(Boolean).map(line => JSON.parse(line));
    },
    async acknowledge(name) {
      if (typeof name !== 'string' || !/^[0-9]+\.msg$/.test(name)) throw Error('Invalid message record name');
      await run(['ack', name]);
    },
  };
}
