import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

export function checkDirectory(dir) {
  for (let at = dir; at !== path.dirname(at); at = path.dirname(at)) {
    try { if (!fs.lstatSync(at).isDirectory()) throw new Error('unsafe output directory'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}
export function directory(dir) {
  checkDirectory(dir);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
}
export function readText(file, maximum = 64 * 1024 * 1024) {
  checkDirectory(path.dirname(file));
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.nlink !== 1 || stat.size > maximum) throw new Error('unsafe or oversized owned record');
    return fs.readFileSync(fd, 'utf8');
  } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  finally { if (fd !== undefined) fs.closeSync(fd); }
}
export function parseJSON(text) {
  try { return JSON.parse(text); } catch { throw new Error('malformed JSON record'); }
}
export const readJSON = file => { const text = readText(file); return text === null ? null : parseJSON(text); };
export const readLines = file => (readText(file) ?? '').split('\n').filter(Boolean).map(parseJSON);
export function writeJSON(file, value, append = false) {
  directory(path.dirname(file));
  if (fs.existsSync(file)) {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.nlink !== 1) throw new Error('unsafe output file');
  }
  const text = `${JSON.stringify(value)}\n`;
  if (append && Buffer.byteLength(text) > 65536) throw new Error('event exceeds 64 KiB');
  const target = append ? file : `${file}.${crypto.randomUUID()}.tmp`;
  const fd = fs.openSync(target, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW | (append ? fs.constants.O_APPEND : fs.constants.O_EXCL), 0o600);
  try { fs.fchmodSync(fd, 0o600); fs.writeFileSync(fd, text); fs.fsyncSync(fd); }
  finally { fs.closeSync(fd); }
  if (!append) fs.renameSync(target, file);
}

// The existing portable owner supplies bounded acquisition, stale-owner
// recovery, and release. Keeping it alive until stdin closes binds the lease
// to this transaction and releases it when the application exits unexpectedly.
async function exclusive(root, home, lock, work) {
  directory(path.dirname(lock));
  const keeper = spawn('bash', [path.join(root, 'modules/tachikoma/src/adapters/lock.sh'), root, lock], { env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: path.join(home, 'state') }, stdio: ['pipe', 'pipe', 'pipe'] });
  let ended = false;
  const exit = new Promise(resolve => keeper.once('close', code => { ended = true; resolve(code); }));
  keeper.stderr.resume();
  await new Promise((resolve, reject) => {
    let text = '';
    keeper.once('error', () => reject(new Error('journal lock owner unavailable')));
    keeper.once('close', () => reject(new Error('journal lock unavailable')));
    keeper.stdout.on('data', chunk => { text += chunk; if (text.includes('locked\n')) resolve(); });
  });
  try {
    const result = await work(() => { if (ended) throw new Error('journal lock was lost'); });
    if (ended) throw new Error('journal lock was lost');
    return result;
  } finally {
    keeper.stdin.on('error', () => {});
    keeper.stdin.end('release\n');
    await exit;
  }
}

export function journal({ root, home, data, state }) {
  const base = path.join(data, 'tachikoma');
  let checkLock;
  const requireLock = () => { if (!checkLock) throw new Error('journal mutation requires its transaction'); checkLock(); };
  return {
    async exclusive(work) {
      return exclusive(root, home, path.join(state, 'tachikoma', '.journal.lock'), async check => {
        checkLock = check;
        try { return await work(); } finally { checkLock = undefined; }
      });
    },
    async readDecisions() {
      return readLines(path.join(base, 'decisions.jsonl')).map(row => {
        if (row.schemaVersion !== 1 || typeof row.decisionId !== 'string' || !Number.isFinite(Date.parse(row.recordedAt))) throw new Error('invalid routing decision record');
        return row;
      });
    },
    async readCards() {
      const receipt = readJSON(path.join(base, 'sync.json'));
      if (!receipt) return [];
      if (!Array.isArray(receipt.models) || receipt.models.some(model => typeof model !== 'string')) throw new Error('invalid sync receipt');
      return receipt.models.map(model => {
        const card = readJSON(path.join(base, 'cards', `${encodeURIComponent(model)}.json`));
        if (!card || card.schemaVersion !== 1 || card.model !== model || !card.classes) throw new Error('invalid model card');
        return card;
      });
    },
    async appendDecision(decision) { requireLock(); writeJSON(path.join(base, 'decisions.jsonl'), decision, true); },
    async replaceCards(cards, receipt) {
      requireLock();
      for (const card of cards) writeJSON(path.join(base, 'cards', `${encodeURIComponent(card.model)}.json`), card);
      writeJSON(path.join(base, 'sync.json'), receipt);
    },
  };
}
