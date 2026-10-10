#!/usr/bin/env bash
# Pre-register Codex workspace trust before an unattended worker launch.
# Usage: fm-codex-trust.sh <worktree> <project>
#        fm-codex-trust.sh --secondmate-home <home> <id>
# Only an isolated linked worktree of the given project or a home seeded for
# the given secondmate is eligible. No ancestor or primary checkout is trusted.
# Uses node and the installed codex app-server config/read + config/value/write
# API, without starting a model turn. Codex owns TOML parsing, preservation,
# atomic replacement and version-conflict detection; a conflicting or lost
# concurrent edit is re-read and retried, up to 3 attempts. The exact launch path alone
# is registered in ${CODEX_HOME:-$HOME/.codex}/config.toml; workspace trust never
# changes hook trust. Relative CODEX_HOME, malformed config, explicit untrusted
# entries, symlinked stores and foreign ownership fail closed. Existing trusted
# entries are a no-op. Read-back verifies persistence before reporting success.
# The private stdio server is always stopped (SIGKILL after a 2-second grace);
# it never uses the shared daemon.
set -u
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,16{s/^# \{0,1\}//;p;}' "$0"
  exit 0
fi
command -v node >/dev/null 2>&1 || { echo 'error: Codex trust requires node' >&2; exit 1; }
node - "$@" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const cp = require('node:child_process');
const readline = require('node:readline');
const args = process.argv.slice(2);
const refuse = message => { throw new Error(message); };
const real = value => fs.realpathSync(value);
const gitEnv = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
function git(directory, flag) {
  return real(path.resolve(directory, cp.execFileSync('git', ['-C', directory, 'rev-parse', flag],
    {env: gitEnv, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore']}).trim()));
}
function ownedRegular(file) {
  const info = fs.lstatSync(file);
  if (!info.isFile() || info.uid !== process.getuid()) refuse(`${file} must be a regular file owned by this user`);
}
function checkStore(store) {
  try { ownedRegular(store); } catch (error) { if (error.code !== 'ENOENT') throw error; }
}
let server;
let timer;
let nextId = 0;
const pending = new Map();
function rpc(method, params) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, {resolve, reject});
    server.stdin.write(JSON.stringify({id, method, params}) + '\n');
  });
}
async function main() {
  const secondmate = args.length === 3 && args[0] === '--secondmate-home';
  if (!secondmate && (args.length !== 2 || args[0].startsWith('--')))
    refuse('usage: fm-codex-trust.sh <worktree> <project> | --secondmate-home <home> <id>');
  const target = real(secondmate ? args[1] : args[0]);
  if (!fs.statSync(target).isDirectory() || target === '/' || target === (fs.existsSync(os.homedir()) ? real(os.homedir()) : path.resolve(os.homedir())))
    refuse(`${target} is not a task launch directory`);
  if (git(target, '--show-toplevel') !== target) refuse(`${target} is not a checkout root`);
  if (secondmate) {
    const marker = path.join(target, '.fm-secondmate-home');
    ownedRegular(marker);
    if (!args[2] || fs.readFileSync(marker, 'utf8').trim() !== args[2])
      refuse(`${target} is not seeded for secondmate ${args[2]}`);
    if (!fs.statSync(path.join(target, 'AGENTS.md')).isFile() || !fs.statSync(path.join(target, 'bin')).isDirectory())
      refuse(`${target} is not a Firstmate home`);
    for (const name of ['data', 'state', 'config', 'projects']) {
      const child = path.join(target, name);
      try { fs.lstatSync(child); } catch (error) { if (error.code === 'ENOENT') continue; throw error; }
      if (!fs.statSync(child).isDirectory() || !real(child).startsWith(target + path.sep))
        refuse(`${child} is not a directory inside this home`);
    }
  } else {
    const common = git(target, '--git-common-dir');
    if (git(target, '--absolute-git-dir') === common)
      refuse(`${target} is a primary checkout, not an isolated worktree`);
    if (common !== git(real(args[1]), '--git-common-dir')) refuse(`${target} is not a worktree of ${args[1]}`);
  }
  const configured = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
  if (!path.isAbsolute(configured)) refuse('CODEX_HOME must be absolute so registration and launch read the same store');
  fs.mkdirSync(configured, {recursive: true, mode: 0o700});
  const directory = real(configured);
  if (fs.statSync(directory).uid !== process.getuid() || directory === target)
    refuse(`${directory} is not an eligible Codex configuration directory`);
  const store = path.join(directory, 'config.toml');
  checkStore(store);
  server = cp.spawn('codex', ['app-server', '--listen', 'stdio://'], {
    cwd: directory, env: {...process.env, CODEX_HOME: directory}, stdio: ['pipe', 'pipe', 'ignore']
  });
  const failPending = error => { for (const item of pending.values()) item.reject(error); pending.clear(); };
  server.on('error', failPending);
  server.on('exit', (code, signal) => failPending(new Error(`Codex config server exited (${signal || code})`)));
  server.stdin.on('error', failPending);
  readline.createInterface({input: server.stdout}).on('line', line => {
    let response;
    try { response = JSON.parse(line); } catch { failPending(new Error('Codex config server emitted invalid JSON')); return; }
    const item = pending.get(response.id);
    if (!item) return;
    pending.delete(response.id);
    if (response.error) item.reject(Object.assign(new Error(response.error.message || JSON.stringify(response.error)), {data: response.error.data}));
    else item.resolve(response.result);
  });
  timer = setTimeout(() => failPending(new Error('Codex config server timed out after 15 seconds')), 15000);
  await rpc('initialize', {clientInfo: {name: 'firstmate-workspace-trust', version: '1'}, capabilities: null});
  server.stdin.write(JSON.stringify({method: 'initialized'}) + '\n');
  const userLayer = result => result.layers?.find(item => item.name.type === 'user' && !item.name.profile && item.name.file === store);
  // Each attempt's read verifies the previous write: a version conflict or a
  // concurrent replace that dropped an acknowledged write is re-read and retried.
  for (let attempt = 1; ; attempt++) {
    checkStore(store);
    const layer = userLayer(await rpc('config/read', {includeLayers: true}));
    if (!layer || !layer.version || !layer.config || typeof layer.config !== 'object')
      refuse('Codex did not report a versioned user config layer for the launch store');
    const entry = layer.config.projects?.[target];
    if (entry?.trust_level === 'untrusted') refuse(`existing entry for ${target} is explicitly untrusted`);
    if (entry?.trust_level === 'trusted') break;
    if (attempt > 3) refuse(`${store} did not retain workspace trust; gave up after 3 attempts`);
    let written;
    try {
      written = await rpc('config/value/write', {
        keyPath: `projects.${JSON.stringify(target)}.trust_level`, value: 'trusted',
        mergeStrategy: 'replace', filePath: store, expectedVersion: layer.version
      });
    } catch (error) {
      if (error.data?.config_write_error_code !== 'configVersionConflict') throw error;
      continue;
    }
    if (written.status !== 'ok' || written.filePath !== store) refuse('Codex did not confirm the trust write');
  }
  console.log(`trusted: ${target}`);
}
main().catch(error => {
  console.error(`error: refusing to pre-register Codex workspace trust: ${error.message}`);
  process.exitCode = 1;
}).finally(() => {
  clearTimeout(timer);
  if (!server) return;
  server.stdin.destroy();
  server.kill('SIGTERM');
  // A server that stalls on shutdown must not hold the verdict hostage.
  setTimeout(() => { server.kill('SIGKILL'); server.stdout.destroy(); }, 2000).unref();
});
JS
