// Bounded, model-free native lease/lifetime controls; no production home involved.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';
import { randomUUID, createHash } from 'node:crypto';
const directory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../data/native-candidate-validation');
const read = name => JSON.parse(fs.readFileSync(name, 'utf8').replace(/^\uFEFF/, ''));
const build = read(path.join(directory, 'build.json'));
const root = path.join(build.root, 'lifecycle-' + randomUUID()); fs.mkdirSync(root);
const records = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const hash = name => createHash('sha256').update(fs.readFileSync(name)).digest('hex');
function start(name, leaseHome, milliseconds = 100, abandonAfterLaunch = false, boundaries = false) {
  const home = path.join(root, name); fs.mkdirSync(home);
  const spec = { home, leaseHome, executable: build.binary, arguments: boundaries ? 'fixture' : `sleep ${milliseconds}`, timeoutSeconds: 20, outsider: boundaries, boundaries, assignJob: true, pipeAcl: 'UserOnly', abandonAfterLaunch };
  const config = path.join(home, 'spec.json'); fs.writeFileSync(config, JSON.stringify(spec, null, 2));
  const child = spawn(build.binary, ['run', config], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '', stderr = '';
  child.stdout.on('data', data => stdout += data); child.stderr.on('data', data => stderr += data);
  const done = new Promise((resolve, reject) => { child.on('error', reject); child.on('exit', code => {
    const result = { name, home, code, stdout, stderr }; records.push(result);
    fs.writeFileSync(path.join(home, 'controller.json'), JSON.stringify(result, null, 2)); resolve(result);
  }); });
  return { home, done };
}
async function waitOwner(home, oldGeneration) {
  for (let attempt = 0; attempt < 200; attempt++) {
    try { const value = read(path.join(home, 'owner-probe.json')); if (value.state === 'live' && value.generation !== oldGeneration) return value; } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    await sleep(20);
  }
  throw Error('Owner did not publish in time');
}
function check(home, generation) {
  const result = spawnSync(build.binary, ['lease-check', home, generation], { encoding: 'utf8' });
  if (result.status !== 0) throw Error(result.stderr);
  return JSON.parse(result.stdout);
}
function assert(condition, message) { if (!condition) throw Error(message); }
const shared = path.join(root, 'shared');
const first = start('first', shared, 2500);
const firstOwner = await waitOwner(shared);
assert(check(shared, firstOwner.generation).probeOwnerCurrent, 'Initial current-owner check failed');
const original = hash(path.join(shared, 'owner-probe.json'));
const competitor = await start('competitor', shared).done;
assert(competitor.code !== 0 && !fs.existsSync(path.join(competitor.home, 'result.json')), 'Competing controller started a root');
assert(hash(path.join(shared, 'owner-probe.json')) === original, 'Competing controller changed owner record');
assert((await first.done).code === 0, 'First owner failed');
assert(!check(shared, firstOwner.generation).probeOwnerCurrent, 'Exited owner remained current');
const next = start('restart', shared, 1800);
const nextOwner = await waitOwner(shared, firstOwner.generation);
assert(nextOwner.generation !== firstOwner.generation, 'Generation reused');
assert(!check(shared, firstOwner.generation).probeOwnerCurrent, 'Old generation accepted after restart');
assert(check(shared, nextOwner.generation).probeOwnerCurrent, 'New generation rejected');
assert((await next.done).code === 0, 'Restart failed');
const crashHome = path.join(root, 'controller-loss');
const abandoned = await start('abandon-controller', crashHome, 3500, true).done;
assert(abandoned.code === 86, 'Controlled broker-loss fixture failed');
const survivor = read(path.join(crashHome, 'owner-probe.json'));
assert(check(crashHome, survivor.generation).probeOwnerCurrent, 'Primary did not survive its controller');
const before = hash(path.join(crashHome, 'owner-probe.json'));
const refused = await start('live-primary-refusal', crashHome).done;
assert(refused.code !== 0 && refused.stderr.includes('Recorded primary is still alive'), 'Live orphan was not protected');
assert(hash(path.join(crashHome, 'owner-probe.json')) === before, 'Live orphan record changed');
let alive = true;
for (let attempt = 0; attempt < 100; attempt++) { alive = check(crashHome, survivor.generation).probeOwnerCurrent; if (!alive) break; await sleep(50); }
assert(!alive, 'Bounded orphan did not exit');
assert((await start('recover-after-primary-exit', crashHome).done).code === 0, 'Proven-dead owner prevented new session');
for (const [name, content] of [['pending', '{"state":"pending"}'], ['empty', ''], ['malformed', '{broken']]) {
  const home = path.join(root, 'ambiguous-' + name); fs.mkdirSync(home);
  const filename = path.join(home, 'owner-probe.json'); fs.writeFileSync(filename, content);
  const beforeHash = hash(filename);
  assert((await start('reject-' + name, home).done).code !== 0, 'Ambiguous record was accepted');
  assert(hash(filename) === beforeHash, 'Ambiguous record was overwritten');
}
const boundary = await start('registered-boundaries', path.join(root, 'boundary-owner'), 100, false, true).done;
assert(boundary.code === 0, 'Boundary fixture failed');
const result = read(path.join(boundary.home, 'result.json'));
assert(result.observations.length === 12 && result.probeLeaseHeld && !result.authorityImplemented, 'Boundary evidence incomplete');
for (const role of ['worker', 'nested-primary']) for (const suffix of ['', '-descendant']) {
  const row = result.observations.find(row => row.case === `scope-${role}${suffix}`);
  assert(row?.hostClassification === `registered-${role}` && !row.authorityGranted, 'Inherited role escaped its registration');
}
assert(result.observations.every(row => row.authorityGranted === false), 'Production authority unexpectedly granted');
fs.writeFileSync(path.join(directory, 'lifecycle-latest.json'), JSON.stringify({ root, passed: true, records }, null, 2));
console.log('PASS: exclusive acquisition, unchanged competing record, normal exit, fresh generation, stale-generation rejection, controller-loss protection, recovery after root exit, three ambiguous-record refusals, and twelve child-boundary observations.');
