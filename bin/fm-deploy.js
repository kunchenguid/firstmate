#!/usr/bin/env node
/*
 * Default-off, one-shot deployment capability.
 *
 * This program intentionally accepts only profile-owned fixed argv and reads
 * secret bytes only after task, project, origin, worktree, HEAD, grant, and
 * destination checks succeed. It never serializes a secret or its hash.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawn, spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const HOME = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || ROOT;
const STATE = process.env.FM_STATE_OVERRIDE || path.join(HOME, 'state');
const DATA = process.env.FM_DATA_OVERRIDE || path.join(HOME, 'data');
const CONFIG = process.env.FM_CONFIG_OVERRIDE || path.join(HOME, 'config');
const PROJECTS = process.env.FM_PROJECTS_OVERRIDE || path.join(HOME, 'projects');
const CONFIG_FILE = path.join(CONFIG, 'deployment-capabilities.json');
const NAME = /^[a-z][a-z0-9-]{0,63}$/;
const ID = /^[A-Za-z0-9._-]+$/;
const AUTHORITY = /^[a-z][a-z0-9-]{0,127}$/;
const MAX_KEY_BYTES = 33;
const GRANT_TTL_MS = 10 * 60 * 1000;

function safeError(message, code = 1) { return { message, code }; }
function mode(stat) { return stat.mode & 0o777; }
function exactMode(stat, expected) { return mode(stat) === expected; }
function sameIdentity(a, b) {
  return a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeMs === b.mtimeMs;
}
function lstatRegular(file, expectedMode) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || (expectedMode !== undefined && !exactMode(stat, expectedMode))) {
    throw safeError('refused unsafe file identity');
  }
  return stat;
}
function lstatDir(dir) {
  const stat = fs.lstatSync(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw safeError('refused unsafe directory identity');
  return stat;
}
function mkdirPrivate(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stat = lstatDir(dir);
  if (!exactMode(stat, 0o700)) fs.chmodSync(dir, 0o700);
  return dir;
}
function privateFile(file, contents) {
  const parent = path.dirname(file);
  mkdirPrivate(parent);
  const temp = path.join(parent, `.${path.basename(file)}.${crypto.randomBytes(8).toString('hex')}`);
  const fd = fs.openSync(temp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
  try { fs.writeFileSync(fd, contents, { encoding: 'utf8' }); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(temp, file);
  fs.chmodSync(file, 0o600);
}
function readPrivateJson(file) {
  const stat = lstatRegular(file, 0o600);
  if (stat.uid !== process.getuid()) throw safeError('private file owner mismatch');
  return parseStrictJson(fs.readFileSync(file, 'utf8'));
}

// JSON.parse loses duplicate-key information. This small parser rejects it while
// remaining deliberately limited to standard JSON values.
function parseStrictJson(text) {
  let i = 0;
  const whitespace = () => { while (/\s/.test(text[i] || '')) i++; };
  const string = () => {
    if (text[i++] !== '"') throw safeError('invalid JSON');
    let out = '';
    while (i < text.length) {
      const c = text[i++];
      if (c === '"') return out;
      if (c === '\\') {
        const e = text[i++];
        const map = { '"': '"', '\\': '\\', '/': '/', b: '\b', f: '\f', n: '\n', r: '\r', t: '\t' };
        if (e === 'u') {
          const hex = text.slice(i, i + 4);
          if (!/^[0-9a-fA-F]{4}$/.test(hex)) throw safeError('invalid JSON');
          out += String.fromCharCode(parseInt(hex, 16)); i += 4;
        } else if (Object.prototype.hasOwnProperty.call(map, e)) out += map[e];
        else throw safeError('invalid JSON');
      } else {
        if (c < ' ') throw safeError('invalid JSON');
        out += c;
      }
    }
    throw safeError('invalid JSON');
  };
  const value = () => {
    whitespace(); const c = text[i];
    if (c === '"') return string();
    if (c === '{') {
      i++; whitespace(); const result = {}; const seen = new Set();
      if (text[i] === '}') { i++; return result; }
      for (;;) {
        whitespace(); const key = string();
        if (seen.has(key)) throw safeError('duplicate JSON object key');
        seen.add(key); whitespace(); if (text[i++] !== ':') throw safeError('invalid JSON');
        result[key] = value(); whitespace();
        if (text[i] === '}') { i++; return result; }
        if (text[i++] !== ',') throw safeError('invalid JSON');
      }
    }
    if (c === '[') {
      i++; const result = []; whitespace(); if (text[i] === ']') { i++; return result; }
      for (;;) { result.push(value()); whitespace(); if (text[i] === ']') { i++; return result; } if (text[i++] !== ',') throw safeError('invalid JSON'); }
    }
    const remainder = text.slice(i);
    const token = /^(true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/.exec(remainder);
    if (!token) throw safeError('invalid JSON');
    i += token[0].length;
    return token[0] === 'true' ? true : token[0] === 'false' ? false : token[0] === 'null' ? null : Number(token[0]);
  };
  const result = value(); whitespace(); if (i !== text.length) throw safeError('invalid JSON'); return result;
}
function object(value, label) {
  if (!value || Array.isArray(value) || typeof value !== 'object') throw safeError(`invalid ${label}`);
  return value;
}
function keysExactly(value, allowed, label) {
  object(value, label);
  for (const key of Object.keys(value)) if (!allowed.includes(key)) throw safeError(`unknown ${label} field`);
}
function string(value, label) { if (typeof value !== 'string' || !value) throw safeError(`invalid ${label}`); return value; }
function named(value, label) { value = string(value, label); if (!NAME.test(value)) throw safeError(`invalid ${label}`); return value; }
function regularPath(value, label) { value = string(value, label); if (value.includes('\0')) throw safeError(`invalid ${label}`); return value; }
function safeRelative(value, label) {
  value = regularPath(value, label);
  if (path.isAbsolute(value) || value.split('/').some(x => !x || x === '.' || x === '..')) throw safeError(`invalid ${label}`);
  return value;
}
function validateConfig(config) {
  keysExactly(config, ['version', 'source_roots', 'projects'], 'config');
  if (config.version !== 1) throw safeError('unsupported deployment capability version');
  object(config.source_roots, 'source_roots'); object(config.projects, 'projects');
  if (!Object.keys(config.source_roots).length || !Object.keys(config.projects).length) throw safeError('empty required config object');
  for (const [rootName, root] of Object.entries(config.source_roots)) {
    named(rootName, 'source root name'); keysExactly(root, ['path', 'owner', 'allow_group_or_world_write'], 'source root');
    const rootPath = regularPath(root.path, 'source root path');
    if (!path.isAbsolute(rootPath) || root.owner !== 'current-user' || root.allow_group_or_world_write !== false) throw safeError('invalid source root');
  }
  for (const [projectName, project] of Object.entries(config.projects)) {
    named(projectName, 'project name'); keysExactly(project, ['origin', 'profiles'], 'project');
    keysExactly(project.origin, ['remote', 'url'], 'origin'); string(project.origin.remote, 'origin remote'); string(project.origin.url, 'origin url');
    object(project.profiles, 'profiles'); if (!Object.keys(project.profiles).length) throw safeError('empty profiles');
    for (const [profileName, profile] of Object.entries(project.profiles)) {
      named(profileName, 'profile name'); keysExactly(profile, ['kind', 'destination', 'source', 'command', 'required_credentials', 'destination_manifest'], 'profile');
      if (profile.kind !== 'rails-kamal-key-file-v1') throw safeError('unsupported profile kind');
      const destination = named(profile.destination, 'destination');
      keysExactly(profile.source, ['root', 'relative_path', 'owner', 'mode', 'links'], 'source');
      named(profile.source.root, 'source root'); safeRelative(profile.source.relative_path, 'source relative_path');
      if (profile.source.owner !== 'current-user' || profile.source.mode !== '0600' || profile.source.links !== 1 || !config.source_roots[profile.source.root]) throw safeError('invalid source');
      if (!Array.isArray(profile.command) || profile.command.length !== 2 || profile.command[0] !== 'bin/deploy' || profile.command[1] !== destination) throw safeError('invalid fixed deployment command');
      if (!Array.isArray(profile.required_credentials) || !profile.required_credentials.length || new Set(profile.required_credentials).size !== profile.required_credentials.length || !profile.required_credentials.every(x => typeof x === 'string' && /^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*$/.test(x))) throw safeError('invalid required_credentials');
      safeRelative(profile.destination_manifest, 'destination manifest');
    }
  }
  return config;
}
function loadConfig() {
  if (!fs.existsSync(CONFIG_FILE)) throw safeError('deployment capability is not configured');
  return validateConfig(readPrivateJson(CONFIG_FILE));
}
function metaValue(meta, key) {
  const lines = meta.split(/\n/).filter(line => line.startsWith(`${key}=`));
  if (lines.length !== 1 || !lines[0].slice(key.length + 1)) throw safeError('invalid task metadata');
  return lines[0].slice(key.length + 1);
}
function git(cwd, args) {
  const result = spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8' });
  if (result.status !== 0) throw safeError('task git identity could not be verified');
  return result.stdout.trim();
}
function real(file) { return fs.realpathSync(file); }
function registeredProject(name, project) {
  const registry = path.join(DATA, 'projects.md');
  lstatRegular(registry);
  if (!fs.readFileSync(registry, 'utf8').split('\n').some(line => line.startsWith(`- ${name} `) || line === `- ${name}`)) throw safeError('project is not registered');
  if (real(path.join(PROJECTS, name)) !== real(project)) throw safeError('task project does not match registered project');
}
function validateTask(taskId, config, requestedProfile) {
  if (!ID.test(taskId)) throw safeError('invalid task id');
  const metaFile = path.join(STATE, `${taskId}.meta`);
  const metaStat = lstatRegular(metaFile);
  if (metaStat.uid !== process.getuid()) throw safeError('task metadata owner mismatch');
  const meta = fs.readFileSync(metaFile, 'utf8');
  const kind = metaValue(meta, 'kind');
  if (kind !== 'ship') throw safeError('deployment requires a ship task');
  const project = metaValue(meta, 'project');
  const worktree = metaValue(meta, 'worktree');
  if (project.includes('\n') || worktree.includes('\n')) throw safeError('invalid task metadata');
  const backend = (meta.match(/^backend=(.*)$/m) || [])[1] || 'tmux';
  const projectReal = real(project); const worktreeReal = real(worktree);
  if (projectReal === worktreeReal) throw safeError('deployment requires an isolated worktree');
  const candidates = Object.entries(config.projects).filter(([name, projectConfig]) => {
    try { registeredProject(name, projectReal); return projectConfig.profiles[requestedProfile] !== undefined; } catch (_) { return false; }
  });
  if (candidates.length !== 1) throw safeError('profile is not bound to this registered project');
  const [projectName, projectConfig] = candidates[0]; const profile = projectConfig.profiles[requestedProfile];
  const remote = git(worktreeReal, ['remote', 'get-url', projectConfig.origin.remote]);
  if (remote !== projectConfig.origin.url) throw safeError('origin URL does not exactly match the profile');
  if (git(worktreeReal, ['rev-parse', '--show-toplevel']) !== worktreeReal) throw safeError('worktree top-level mismatch');
  const projectCommon = path.resolve(projectReal, git(projectReal, ['rev-parse', '--git-common-dir']));
  const worktreeCommon = path.resolve(worktreeReal, git(worktreeReal, ['rev-parse', '--git-common-dir']));
  if (real(projectCommon) !== real(worktreeCommon)) throw safeError('worktree does not belong to recorded project');
  if (git(worktreeReal, ['status', '--porcelain', '--untracked-files=all']) !== '') throw safeError('worktree is not clean');
  if (backend === 'orca') {
    const worktreeId = metaValue(meta, 'orca_worktree_id');
    if (!/^[A-Za-z0-9._:-]+$/.test(worktreeId)) throw safeError('invalid Orca worktree binding');
    const response = spawnSync('orca', ['worktree', 'show', '--worktree', `id:${worktreeId}`, '--json'], { encoding: 'utf8' });
    if (response.status !== 0) throw safeError('Orca worktree could not be verified');
    let parsed; try { parsed = JSON.parse(response.stdout); } catch (_) { throw safeError('invalid Orca worktree response'); }
    const orcaPath = parsed.result && ((parsed.result.worktree || parsed.result.item || parsed.result).path || parsed.result.path);
    if (parsed.ok === false || typeof orcaPath !== 'string' || real(orcaPath) !== worktreeReal) throw safeError('Orca worktree binding mismatch');
  } else if (!['tmux', 'herdr', 'zellij', 'cmux'].includes(backend)) throw safeError('unsupported task runtime binding');
  return { taskId, project: projectName, projectConfig, profile, projectPath: projectReal, worktree: worktreeReal, head: git(worktreeReal, ['rev-parse', 'HEAD']), backend };
}
function grantDirectory(taskId) { return path.join(STATE, 'deployment-grants', taskId); }
function grantPath(taskId, grantId) { return path.join(grantDirectory(taskId), `${grantId}.json`); }
function receiptPath(taskId, transaction) { return path.join(STATE, 'deploy-runtime', taskId, `${transaction}.json`); }
function ledgerPath() { return path.join(DATA, 'deployment-receipts.jsonl'); }
function now() { return new Date().toISOString(); }
function randomId() { return crypto.randomBytes(16).toString('hex'); }
function lockPath(project, destination) { return path.join(STATE, 'deployment-locks', `${project}-${destination}.lock`); }
function acquireLock(project, destination) {
  const lock = lockPath(project, destination); mkdirPrivate(path.dirname(lock));
  try { fs.mkdirSync(lock, 0o700); } catch (_) { throw safeError('deployment destination is already in use'); }
  return () => { try { fs.rmdirSync(lock); } catch (_) {} };
}
function writeGrant(grant) { privateFile(grantPath(grant.task_id, grant.grant_id), `${JSON.stringify(grant)}\n`); }
function readGrant(grantId) {
  if (!/^[0-9a-f]{32}$/.test(grantId)) throw safeError('invalid grant id');
  const root = path.join(STATE, 'deployment-grants');
  if (!fs.existsSync(root)) throw safeError('grant was not found');
  for (const task of fs.readdirSync(root)) {
    const candidate = grantPath(task, grantId);
    if (fs.existsSync(candidate)) return { file: candidate, grant: readPrivateJson(candidate) };
  }
  throw safeError('grant was not found');
}
function validateGrant(grant) {
  keysExactly(grant, ['version', 'grant_id', 'task_id', 'project', 'profile', 'destination', 'worktree', 'head', 'created_at', 'expires_at', 'max_uses', 'authority_ref', 'state'], 'grant');
  if (grant.version !== 1 || !/^[0-9a-f]{32}$/.test(grant.grant_id) || !ID.test(grant.task_id) || !NAME.test(grant.project) || !NAME.test(grant.profile) || !NAME.test(grant.destination) || !AUTHORITY.test(grant.authority_ref) || grant.max_uses !== 1 || !['pending', 'consumed', 'revoked', 'expired'].includes(grant.state)) throw safeError('invalid grant');
  if (Date.parse(grant.expires_at) <= Date.now()) throw safeError('grant has expired');
}
function appendLedger(record) {
  mkdirPrivate(DATA);
  const file = ledgerPath();
  if (!fs.existsSync(file)) privateFile(file, '');
  lstatRegular(file, 0o600);
  fs.appendFileSync(file, `${JSON.stringify(record)}\n`, { encoding: 'utf8', mode: 0o600 });
}
function sourceBytes(config, profile) {
  const root = config.source_roots[profile.source.root];
  const rootPath = root.path;
  const rootStat = lstatDir(rootPath);
  if (rootStat.uid !== process.getuid() || (mode(rootStat) & 0o022)) throw safeError('unsafe source root');
  let current = rootPath;
  const components = profile.source.relative_path.split('/');
  for (const [index, component] of components.entries()) {
    current = path.join(current, component);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink() || (index < components.length - 1 && (!stat.isDirectory() || stat.uid !== process.getuid() || (mode(stat) & 0o022)))) throw safeError('source path contains an unsafe component');
  }
  const before = fs.lstatSync(current);
  if (!before.isFile() || before.uid !== process.getuid() || !exactMode(before, 0o600) || before.nlink !== 1 || before.size < 1 || before.size > MAX_KEY_BYTES) throw safeError('unsafe source key identity');
  const fd = fs.openSync(current, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  let bytes, opened, after;
  try { opened = fs.fstatSync(fd); if (!sameIdentity(before, opened)) throw safeError('source changed before read'); bytes = fs.readFileSync(fd); after = fs.fstatSync(fd); } finally { fs.closeSync(fd); }
  if (!sameIdentity(opened, after)) throw safeError('source changed during read');
  const text = bytes.toString('utf8');
  if (!Buffer.from(text, 'utf8').equals(bytes) || !/^[0-9a-fA-F]{32}\n?$/.test(text)) throw safeError('source key has invalid format');
  return { key: text.trim(), identity: { root: profile.source.root, relative_path: profile.source.relative_path, dev: before.dev, ino: before.ino, uid: before.uid, mode: mode(before), links: before.nlink } };
}
function writeTemp(task, transaction, key, source) {
  const root = path.join(path.dirname(path.join('/tmp', `fm-${task.taskId}`)), `fm-${task.taskId}`, 'deploy-runtime');
  // tasktmp is metadata-owned where available; never write in the project copy.
  const meta = fs.readFileSync(path.join(STATE, `${task.taskId}.meta`), 'utf8');
  const taskTmpLine = (meta.match(/^tasktmp=(.*)$/m) || [])[1];
  const runtimeRoot = taskTmpLine && path.isAbsolute(taskTmpLine) ? path.join(taskTmpLine, 'deploy-runtime') : root;
  mkdirPrivate(runtimeRoot);
  const directory = path.join(runtimeRoot, transaction);
  fs.mkdirSync(directory, { mode: 0o700 }); fs.chmodSync(directory, 0o700);
  const rails = path.join(directory, 'rails.key'); const secrets = path.join(directory, `secrets.${task.profile.destination}`);
  for (const [file, contents] of [[rails, `${key}\n`], [secrets, `RAILS_MASTER_KEY=${key}\n`]]) {
    const fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try { fs.writeFileSync(fd, contents, { encoding: 'utf8' }); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    const stat = lstatRegular(file, 0o600); if (stat.uid !== process.getuid()) throw safeError('temporary deployment file owner mismatch');
  }
  return { directory, rails, secrets, source };
}
function tempIdentity(file) { const stat = lstatRegular(file, 0o600); return { path: file, dev: stat.dev, ino: stat.ino, uid: stat.uid, mode: mode(stat) }; }
function unlinkExact(identity) {
  const stat = lstatRegular(identity.path, 0o600);
  if (stat.dev !== identity.dev || stat.ino !== identity.ino || stat.uid !== identity.uid || mode(stat) !== identity.mode) throw safeError('temporary deployment file identity changed');
  fs.unlinkSync(identity.path);
}
function cleanupReceipt(receipt) {
  unlinkExact(receipt.rails); unlinkExact(receipt.secrets);
  const stat = lstatDir(receipt.directory); if (stat.uid !== process.getuid() || !exactMode(stat, 0o700)) throw safeError('temporary deployment directory identity changed');
  fs.rmdirSync(receipt.directory);
}
function sanitizedEnv(rails, secrets) {
  const allowed = ['HOME', 'USER', 'LOGNAME', 'PATH', 'TMPDIR', 'SSH_AUTH_SOCK', 'DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_CONFIG'];
  const env = {};
  for (const key of allowed) if (process.env[key]) env[key] = process.env[key];
  env.KG_METALL_RAILS_KEY_PATH = rails;
  env.KAMAL_SECRETS_PATH = secrets.slice(0, -`.${path.basename(secrets).split('.').pop()}`.length);
  return env;
}
function streamRedacted(child, key) {
  const needle = Buffer.from(key); let pending = Buffer.alloc(0);
  const emit = (data, final) => {
    let keep = 0;
    if (!final) {
      for (let size = Math.min(needle.length - 1, data.length); size > 0; size--) {
        if (data.subarray(data.length - size).equals(needle.subarray(0, size))) { keep = size; break; }
      }
    }
    const end = data.length - keep; let cursor = 0; let match;
    while ((match = data.indexOf(needle, cursor)) !== -1 && match + needle.length <= end) {
      if (match > cursor) process.stdout.write(data.subarray(cursor, match));
      process.stdout.write('[REDACTED]'); cursor = match + needle.length;
    }
    if (cursor < end) process.stdout.write(data.subarray(cursor, end));
    pending = data.subarray(end);
  };
  const write = chunk => emit(Buffer.concat([pending, chunk]), false);
  child.stdout.on('data', write); child.stderr.on('data', write);
  return () => { if (pending.length) emit(pending, true); };
}
function processStartToken(pid) {
  try {
    if (process.platform === 'linux') return fs.readFileSync(`/proc/${pid}/stat`, 'utf8').trim().split(' ')[21] || '';
    const result = spawnSync('ps', ['-o', 'lstart=', '-p', String(pid)], { encoding: 'utf8' });
    return result.status === 0 ? result.stdout.trim() : '';
  } catch (_) { return ''; }
}
function receiptChildIsAlive(receipt) {
  if (!receipt.child || !Number.isInteger(receipt.child.pid) || !receipt.child.start) return false;
  try { process.kill(receipt.child.pid, 0); } catch (_) { return false; }
  return processStartToken(receipt.child.pid) === receipt.child.start;
}
function runFixed(task, temp, key, argv, onStarted) {
  return new Promise((resolve, reject) => {
    const child = spawn(argv[0], argv.slice(1), { cwd: task.worktree, env: sanitizedEnv(temp.rails, temp.secrets), stdio: ['ignore', 'pipe', 'pipe'], detached: true, shell: false });
    if (onStarted) onStarted(child.pid, processStartToken(child.pid));
    const flush = streamRedacted(child, key);
    child.once('error', reject);
    child.once('close', code => { flush(); resolve(code === 0 ? 0 : (code || 1)); });
  });
}
async function issue(taskId, profileName, authorityRef) {
  if (!AUTHORITY.test(authorityRef)) throw safeError('invalid authority reference');
  const config = loadConfig(); const task = validateTask(taskId, config, profileName); const release = acquireLock(task.project, task.profile.destination);
  try {
    const existingDir = grantDirectory(task.taskId);
    if (fs.existsSync(existingDir)) {
      lstatDir(existingDir);
      for (const file of fs.readdirSync(existingDir)) {
        if (!/^[0-9a-f]{32}\.json$/.test(file)) throw safeError('unsafe grant record');
        const existing = readPrivateJson(path.join(existingDir, file));
        if (existing.profile === profileName && existing.state === 'pending' && Date.parse(existing.expires_at) > Date.now()) throw safeError('a pending grant already exists for this task and destination');
      }
    }
    const grant = { version: 1, grant_id: randomId(), task_id: task.taskId, project: task.project, profile: profileName, destination: task.profile.destination, worktree: task.worktree, head: task.head, created_at: now(), expires_at: new Date(Date.now() + GRANT_TTL_MS).toISOString(), max_uses: 1, authority_ref: authorityRef, state: 'pending' };
    writeGrant(grant); process.stdout.write(`${grant.grant_id}\n`); return grant.grant_id;
  } finally { release(); }
}
async function run(grantId) {
  const found = readGrant(grantId); const grant = found.grant; validateGrant(grant);
  const config = loadConfig(); const task = validateTask(grant.task_id, config, grant.profile);
  if (task.project !== grant.project || task.profile.destination !== grant.destination || task.worktree !== grant.worktree || task.head !== grant.head) throw safeError('grant task identity changed');
  const release = acquireLock(task.project, task.profile.destination); let transaction; let receipt; let key;
  try {
    validateGrant(grant); if (grant.state !== 'pending') throw safeError('grant is not pending');
    grant.state = 'consumed'; privateFile(found.file, `${JSON.stringify(grant)}\n`);
    transaction = randomId(); const source = sourceBytes(config, task.profile); key = source.key;
    const temp = writeTemp(task, transaction, key, source.identity);
    receipt = { version: 1, transaction, grant_id: grant.grant_id, task_id: task.taskId, project: task.project, profile: grant.profile, destination: grant.destination, head: task.head, phase: 'prepared', started_at: now(), directory: temp.directory, rails: tempIdentity(temp.rails), secrets: tempIdentity(temp.secrets), source: source.identity };
    privateFile(receiptPath(task.taskId, transaction), `${JSON.stringify(receipt)}\n`);
    let exit = await runFixed(task, temp, key, ['bin/deploy', 'preflight', task.profile.destination]);
    if (exit !== 0) { appendLedger({ version: 1, transaction, task_id: task.taskId, project: task.project, profile: grant.profile, destination: grant.destination, head: task.head, authority_ref: grant.authority_ref, started_at: receipt.started_at, finished_at: now(), result: 'preflight-failed', exit_code: exit, preflight_passed: false, remote_phase_reached: false }); return exit; }
    receipt.phase = 'preflight-passed'; privateFile(receiptPath(task.taskId, transaction), `${JSON.stringify(receipt)}\n`);
    receipt.phase = 'launching'; privateFile(receiptPath(task.taskId, transaction), `${JSON.stringify(receipt)}\n`);
    exit = await runFixed(task, temp, key, task.profile.command, (pid, start) => {
      receipt.child = { pid, start };
      receipt.phase = 'remote-started';
      privateFile(receiptPath(task.taskId, transaction), `${JSON.stringify(receipt)}\n`);
    });
    appendLedger({ version: 1, transaction, task_id: task.taskId, project: task.project, profile: grant.profile, destination: grant.destination, head: task.head, authority_ref: grant.authority_ref, started_at: receipt.started_at, finished_at: now(), result: exit === 0 ? 'completed' : 'deploy-failed', exit_code: exit, preflight_passed: true, remote_phase_reached: true });
    return exit;
  } finally {
    if (receipt) {
      try {
        cleanupReceipt(receipt);
        fs.unlinkSync(receiptPath(task.taskId, transaction));
      } catch (_) {
        release();
        throw safeError('cleanup requires manual inspection');
      }
    }
    release();
  }
}
function recover(taskId) {
  if (!ID.test(taskId)) throw safeError('invalid task id');
  const dir = path.join(STATE, 'deploy-runtime', taskId); if (!fs.existsSync(dir)) return;
  lstatDir(dir);
  for (const file of fs.readdirSync(dir)) {
    if (!/^[0-9a-f]{32}\.json$/.test(file)) throw safeError('unsafe deployment recovery record');
    const receiptFile = path.join(dir, file); const receipt = readPrivateJson(receiptFile);
    if (receipt.task_id !== taskId || !receipt.rails || !receipt.secrets || !receipt.directory) throw safeError('deployment recovery requires manual inspection');
    if (receiptChildIsAlive(receipt)) throw safeError('deployment recovery found a live recorded operation');
    const remoteReached = receipt.phase === 'remote-started' || receipt.phase === 'launching';
    cleanupReceipt(receipt); fs.unlinkSync(receiptFile);
    appendLedger({ version: 1, transaction: receipt.transaction, task_id: receipt.task_id, project: receipt.project, profile: receipt.profile, destination: receipt.destination, head: receipt.head, started_at: receipt.started_at, finished_at: now(), result: remoteReached ? 'unknown-after-remote' : 'recovered-before-remote', preflight_passed: receipt.phase === 'preflight-passed', remote_phase_reached: remoteReached });
  }
}
function recoverStale() {
  const root = path.join(STATE, 'deploy-runtime'); if (!fs.existsSync(root)) return;
  lstatDir(root); for (const task of fs.readdirSync(root)) recover(task);
}
async function main() {
  const args = process.argv.slice(2); const command = args.shift();
  if (command === 'validate-config' && args.length === 0) { loadConfig(); return; }
  if (command === 'issue' && args.length === 4 && args[2] === '--authority-ref') { await issue(args[0], args[1], args[3]); return; }
  if (command === 'run' && args.length === 1) { const code = await run(args[0]); process.exitCode = code; return; }
  if (command === 'deploy' && args.length === 4 && args[2] === '--authority-ref') { const grant = await issue(args[0], args[1], args[3]); process.exitCode = await run(grant); return; }
  if (command === 'revoke' && args.length === 1) { const found = readGrant(args[0]); validateGrant(found.grant); if (found.grant.state !== 'pending') throw safeError('grant cannot be revoked'); found.grant.state = 'revoked'; privateFile(found.file, `${JSON.stringify(found.grant)}\n`); return; }
  if (command === 'recover' && args.length === 1) { recover(args[0]); return; }
  if (command === 'recover-stale' && args.length === 0) { recoverStale(); return; }
  throw safeError('usage: fm-deploy.sh validate-config|issue|run|deploy|revoke|recover|recover-stale', 2);
}
main().catch(error => { if (error && error.message === '__fm_deploy_handled__') return; const detail = error && error.message ? error.message : 'refused unsafe deployment request'; process.stderr.write(`fm-deploy: ${detail}\n`); process.exitCode = error && error.code ? error.code : 1; });
