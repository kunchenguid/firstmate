import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
// The caller owns the immutable event and any deduplication policy.
export async function publishEvent({ home, root, module, id }) {
  if (!/^[a-z][a-z0-9-]{0,63}$/.test(module) || !/^[a-f0-9]{24}$/.test(id)) throw Error('Invalid module or event id');
  home = fs.realpathSync(home);
  const file = path.join(home, 'state', module, 'events', `${id}.json`);
  if (fs.realpathSync(file) !== file || !fs.lstatSync(file).isFile() || fs.statSync(file).size > 65536) throw Error('Unsafe event file');
  if (JSON.parse(fs.readFileSync(file, 'utf8')).id !== id) throw Error('Event id mismatch');
  const source = `${module}-${id}`;
  const run = args => new Promise((resolve, reject) => {
    const child = execFile(path.join(root, 'bin/fm-procevent.sh'), args, { timeout: 30000, maxBuffer: 65536,
      env: { ...process.env, FM_HOME: home, FM_ROOT_OVERRIDE: root, FM_STATE_OVERRIDE: path.join(home, 'state') } }, error => error ? reject(Error(`Process-event ${args[0]} failed: ${error.killed ? 'timeout' : error.code ?? error.signal ?? 'unknown'}`)) : resolve());
    child.stdin?.end();
  });
  await run(['register', 'fm-state-reader', source, '--', '/bin/cat', file]);
  await run(['start', source]);
  return { source };
}
