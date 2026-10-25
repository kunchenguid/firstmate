// Drive a disposable guard CLI with live sibling processes and an isolated OS-account fixture.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fork, spawn, spawnSync, execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const ev = process.env.DONE_DONE_EVIDENCE_ROOT; assert(ev, 'DONE_DONE_EVIDENCE_ROOT required');
const temp = fs.mkdtempSync(join(tmpdir(), 'kill-live-')), home = join(temp, 'account'), main = join(home, 'firstmate'), copy = join(temp, 'kill-guard');
const dirs = [main, join(home, 'worker'), join(home, 'lead')], agents = [], children = [], log = text => fs.appendFileSync(join(ev, 'journey.txt'), text + '\n');
for (const dir of [...dirs, copy, join(main, 'state'), join(main, 'data'), join(main, 'bin'), join(main, 'projects/demo'), join(temp, 'no-mistakes')]) fs.mkdirSync(dir, { recursive: true });
for (const dir of dirs) execFileSync('git', ['init', '-q', dir], { env: { ...process.env, HOME: home, XDG_CONFIG_HOME: home } });
fs.writeFileSync(join(main, 'bin/fm-spawn.sh'), ''); fs.copyFileSync(new URL('./guard.mjs', import.meta.url), join(copy, 'guard.mjs'));
const preload = join(temp, 'account.cjs'), helper = join(temp, 'caller.cjs'), lock = join(main, 'state/.lock');
fs.writeFileSync(preload, `const os=require('node:os'), original=os.userInfo; os.userInfo=()=>({...original(),homedir:${JSON.stringify(home)}}); require('node:module').syncBuiltinESMExports();`);
fs.writeFileSync(helper, `const fs=require('node:fs'),{spawnSync}=require('node:child_process'); process.title=process.argv[2]==='lead'?'claude':'codex';
const [role,guard,preload,lock]=process.argv.slice(2); if(role==='main') fs.writeFileSync(lock,process.pid+'\\n');
process.on('message',({command,execute})=>{const r=spawnSync(process.execPath,['--require',preload,guard,'--caller',String(process.pid),'--reason','kill stuck --token=fixture-secret'],{input:JSON.stringify({tool_input:{command}}),encoding:'utf8'}); const sent=r.status===0&&execute?spawnSync('/bin/kill',[command.split(' ').at(-1)]).status:null; process.send({status:r.status,stderr:r.stderr,sent});}); process.send({ready:true});`);
const run = (agent, command, execute = false) => new Promise(resolve => { agent.once('message', resolve); agent.send({command,execute}); });
const stopped = child => child.exitCode !== null || child.signalCode !== null ? Promise.resolve() : new Promise(resolve => child.once('exit', resolve));
try {
  for (const [i, role] of ['main', 'worker', 'lead'].entries()) { const a = fork(helper, [role, join(copy, 'guard.mjs'), preload, lock], { cwd: dirs[i], stdio: ['ignore', 'ignore', 'inherit', 'ipc'] }); agents.push(a); await new Promise(resolve => a.once('message', resolve)); }
  const sleep = spawn('sleep', ['120'], { cwd: join(main, 'projects/demo') }); children.push(sleep); await new Promise(resolve => sleep.once('spawn', resolve));
  fs.writeFileSync(join(temp, 'no-mistakes/fixture.cjs'), 'setInterval(()=>{},1000);');
  const protectedProcess = spawn(process.execPath, [join(temp, 'no-mistakes/fixture.cjs'), 'daemon'], { cwd: main }); children.push(protectedProcess); await new Promise(resolve => protectedProcess.once('spawn', resolve));
  log('Real guard CLI: verified Main approves an audited fleet sleep; worker/lead, protected service and pattern kills are blocked.');
  log('Isolation: disposable guard, OS account-home fixture and private lock; kernel PID/starttime/ancestry are real. Only task-owned sleeps and inert fixtures run; no installed tools or real services are signalled.');
  const command = `kill ${sleep.pid}`, result = await run(agents[0], command); assert.equal(result.status, 0, result.stderr);
  const row = JSON.parse(fs.readFileSync(join(copy, 'state/main-kills.jsonl'), 'utf8').trim()); assert.equal(row.pid, sleep.pid); assert.equal(row.caller, agents[0].pid); assert(!JSON.stringify(row).includes('fixture-secret'));
  log(`\n1. Main fleet sleep: ${command} -> approved (exit 0). Sleep parent ${process.pid}, Main caller ${agents[0].pid}: sibling ownership requires the Main allowance.\nAudit: ${JSON.stringify(row)}\nSignal deferred until the identical worker/lead checks finish.`);
  for (const [i, role] of [[1, 'worker'], [2, 'lead']]) { const r = await run(agents[i], command); assert.equal(r.status, 2); assert.match(r.stderr, /which this task did not start/); log(`\n2. Same ${command} as ${role} -> blocked (exit 2):\n${r.stderr.trim()}`); }
  const protectedResult = await run(agents[0], `kill ${protectedProcess.pid}`); assert.equal(protectedResult.status, 2); assert.match(protectedResult.stderr, /protected service/); log(`\n3. Main targets inert no-mistakes-style fixture -> blocked (exit 2):\n${protectedResult.stderr.trim()}`);
  const pattern = await run(agents[0], 'pkill -f sleep'); assert.equal(pattern.status, 2); assert.match(pattern.stderr, /name\/pattern kills are forbidden/); log(`\n4. Main pkill -> blocked (exit 2):\n${pattern.stderr.trim()}`);
  const delivery = await run(agents[0], command, true); assert.equal(delivery.status, 0); assert.equal(delivery.sent, 0); await stopped(sleep); assert.equal(sleep.signalCode, 'SIGTERM'); log(`\nDelivery: Main rechecked approval and sent the literal PID kill; the task-owned sleep received SIGTERM and exited. PASS: Main audit recorded; worker, lead, protected fixture and pattern denials shown above.`);
  const version = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: dirname(fileURLToPath(import.meta.url)), encoding: 'utf8' }).trim();
  fs.writeFileSync(join(ev, 'steps.json'), JSON.stringify({ target: { version }, start: 'Disposable guard CLI, isolated account/home lock; live task-owned sibling sleep and inert service fixture.', steps: ['Main approves fleet sleep and shows redacted audit', 'Worker and lead try the identical live target and are refused', 'Main tries protected fixture and pkill and is refused', 'Deliver approved SIGTERM only to the task-owned sleep'], result: 'the guard lets verified primary Main stop a fleet-owned process with an audit line, and still blocks workers, protected services and pattern kills' }, null, 2));
} finally { for (const child of [...agents, ...children]) if (child.exitCode === null && child.signalCode === null) child.kill(); await Promise.all([...agents, ...children].map(stopped)); fs.rmSync(temp, { recursive: true, force: true }); }
