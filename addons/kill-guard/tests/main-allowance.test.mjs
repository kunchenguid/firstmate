// Executable public guard journey with synthetic /proc trees; never signals a fixture PID.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
import { execFileSync, spawn } from 'node:child_process';
import { tmpdir, userInfo } from 'node:os';
import { join } from 'node:path';
const original = Object.fromEntries(['readFileSync', 'realpathSync', 'readdirSync', 'lstatSync', 'appendFileSync', 'mkdirSync', 'existsSync'].map(k => [k, fs[k]]));
const temp = fs.mkdtempSync(join(tmpdir(), 'kill-main-'));
const account = userInfo().homedir, home = `${account}/firstmate`, audit = join(temp, 'audit.jsonl');
Object.assign(process.env, { HOME: join(temp, 'home'), XDG_CONFIG_HOME: join(temp, 'config'), TMPDIR: temp });
fs.mkdirSync(process.env.HOME);
let lock = '4001', fake = true, reused = false, logFailure = false, symlinkLock = false;
const project = join(temp, 'project'); fs.mkdirSync(project); execFileSync('git', ['init', '-q', project]);
const procs = new Map();
const put = (pid, comm, cwd = home, ppid = 1, argv = [comm]) => procs.set(pid, { pid, comm, cwd, ppid, argv, start: '12345', tty: '0' });
put(1, 'init'); put(4001, 'codex'); put(process.pid, 'node', home, 4001);
put(5001, 'sleep', `${home}/projects/demo`);
const procPath = p => String(p).match(/^\/proc\/(\d+)\/(stat|comm|cmdline|cwd)$/);
fs.readFileSync = (p, ...args) => {
  if (fake && String(p) === `${home}/state/.lock`) { if (lock === null) throw Error('missing lock'); return lock + '\n'; }
  const m = fake && procPath(p);
  if (!m) return original.readFileSync(p, ...args);
  const v = procs.get(+m[1]); if (!v) throw Error('missing process');
  if (m[2] === 'comm') return v.comm + '\n';
  if (m[2] === 'cmdline') return v.argv.join('\0') + '\0';
  const fields = ['S', v.ppid, '0', '0', v.tty, ...Array(14).fill('0'), reused && +m[1] === 5001 ? String(+v.start + 1) : v.start];
  return `${v.pid} (${v.comm}) ${fields.join(' ')}`;
};
fs.realpathSync = (p, ...args) => {
  const m = fake && procPath(p);
  if (m) { const v = procs.get(+m[1]); if (!v?.cwd) throw Error('unreadable cwd'); return v.cwd; }
  if (fake && p === `${project}/.git`) return `${home}/projects/demo/.git`;
  if (fake && (String(p).startsWith(`${account}/`) || String(p).startsWith('/outside'))) return String(p).replace(`${home}/link-away`, '/outside');
  return original.realpathSync(p, ...args);
};
fs.readdirSync = (p, ...args) => fake && p === '/proc' ? [...procs.keys()].map(String) : original.readdirSync(p, ...args);
fs.lstatSync = (p, ...args) => fake && p === `${home}/state/.lock` ? { isFile: () => true, isSymbolicLink: () => symlinkLock } : original.lstatSync(p, ...args);
fs.existsSync = p => fake && procPath(p) ? procs.has(+procPath(p)[1]) : original.existsSync(p);
fs.mkdirSync = (p, ...args) => String(p).endsWith('/kill-guard/state') ? undefined : original.mkdirSync(p, ...args);
fs.appendFileSync = (p, ...args) => { if (logFailure) throw Error('audit unavailable'); return original.appendFileSync(String(p).endsWith('/main-kills.jsonl') ? audit : p, ...args); };
syncBuiltinESMExports();
const { guard } = await import('../guard.mjs');
const allow = (text, options) => assert.equal(guard(text, options), null, text);
const deny = (text, options) => assert.match(guard(text, options) ?? '', /BLOCKED/, text);
try {
  allow('kill 5001', { reason: 'kill stuck --token=private' });
  let rows = fs.readFileSync(audit, 'utf8').trim().split('\n').map(JSON.parse);
  assert.deepEqual([rows[0].pid, rows[0].starttime, rows[0].caller], [5001, '12345', process.pid]);
  assert(!JSON.stringify(rows).includes('private')); assert.equal(rows[0].cwd, `${home}/projects/demo`);
  for (const cwd of [`${account}/.treehouse/firstmate-abc/4/firstmate`, `${account}/.treehouse/addons-abc/3/firstmate-addons`, `${account}/.local/share/fm-preview`]) {
    put(5001, 'sleep', cwd); allow('kill 5001');
  }
  put(5001, 'node', '/outside', 1, ['node', `${home}/bin/watch.mjs`, '--token=private']); allow('kill 5001');
  put(5001, 'sleep', project); allow('kill 5001');
  put(5001, 'sleep', '/outside'); deny('kill 5001');
  put(5001, 'sleep', `${home}-other`); deny('kill 5001');
  put(5001, 'sleep', `${home}/link-away`); deny('kill 5001');
  put(5001, 'sleep');
  for (const [comm, argv] of [['systemd', ['systemd', '--user']], ['herdr', ['herdr', 'server']], ['node', ['node', '/tools/herdr/cli.mjs', 'server']], ['node', ['node', '/tools/no-mistakes/dist/no-mistakes.js', 'daemon']], ['sshd', ['sshd']], ['tailscaled', ['tailscaled']], ['bash', ['-bash']], ['zsh', ['zsh', '-i']]]) {
    put(5001, comm, home, process.pid, argv); deny('kill 5001'); lock = null; deny('kill 5001'); lock = '4001';
  }
  put(5001, 'bash'); procs.get(5001).tty = '123'; deny('kill 5001');
  deny('kill 1'); deny('pkill -f sleep'); deny('pkill sleep'); deny('killall sleep');
  put(5001, 'sleep', null); deny('kill 5001');
  put(5001, 'sleep');
  const count = fs.readFileSync(audit, 'utf8').trim().split('\n').length; allow('kill 5001; kill 5001');
  assert.equal(fs.readFileSync(audit, 'utf8').trim().split('\n').length, count + 2);
  assert(!fs.readFileSync(audit, 'utf8').includes('private'));
  const before = fs.readFileSync(audit, 'utf8'); deny('kill 5001; kill 1'); assert.equal(fs.readFileSync(audit, 'utf8'), before);
  put(4002, 'codex', '/outside'); put(process.pid, 'node', '/outside', 4002);
  process.env.FM_HOME = home; process.env.FM_ROLE = 'main'; process.env.FM_MAIN_PID = '4001';
  deny('kill 5001'); deny('kill 5001', { caller: 4001 });
  // Even a worker launched below Main must not inherit its fleet allowance.
  procs.get(4002).ppid = 4001; deny('kill 5001'); deny('kill 5001', { caller: 4001 });
  put(5002, 'sleep', '/outside', 4002); allow('kill 5002', { caller: 4002 });
  put(4002, 'claude', `${account}/.treehouse/firstmate-abc/4/firstmate`, 4001); deny('kill 5001');
  put(process.pid, 'node', home, 4001); lock = '999999'; deny('kill 5001');
  lock = null; deny('kill 5001'); lock = '4001';
  symlinkLock = true; deny('kill 5001'); symlinkLock = false;
  lock = '4001oops'; deny('kill 5001'); lock = '4001';
  procs.get(4001).cwd = '/outside'; deny('kill 5001'); procs.get(4001).cwd = home;
  logFailure = true; deny('kill 5001'); logFailure = false;
  reused = true; // identity initially consistent but changes before final approval
  const append = fs.readFileSync;
  let reads = 0;
  fs.readFileSync = (p, ...args) => { if (String(p) === '/proc/5001/stat') reused = ++reads > 2; return append(p, ...args); };
  syncBuiltinESMExports(); deny('kill 5001');
  Object.assign(fs, original); syncBuiltinESMExports(); fake = false;
  const sleep = spawn('sleep', ['60']);
  try { allow(`kill ${sleep.pid}`); sleep.kill(); await new Promise(resolve => sleep.once('exit', resolve)); }
  finally { if (sleep.exitCode === null && sleep.signalCode === null) sleep.kill(); }
  console.log('Main allowance journey: PASS (fixture denials, audited approvals, real task-owned sleep)');
} finally {
  Object.assign(fs, original); syncBuiltinESMExports(); fs.rmSync(temp, { recursive: true, force: true });
}
