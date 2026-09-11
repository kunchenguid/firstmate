// Context Atlas's read-only dispatcher. The Pi entry point owns invocation help.
import { execFileSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { constants, lstatSync, realpathSync, openSync, fstatSync, readSync, closeSync } from 'node:fs';
import { resolve, relative, sep, extname } from 'node:path';

const MAX_FILE = 256 * 1024;
const MAX_RESULT = 8192;
const MAX_ITEMS = 8;
const READ_TOOLS = new Set(['read', 'grep', 'find', 'ls']);
const TEXT = new Set(['.md', '.txt', '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.py', '.sh', '.json', '.yaml', '.yml', '.toml', '.css', '.html', '.rs', '.go', '.c', '.h', '.cpp', '.java', '.rb']);
const DENIED = /^(?:data|state|config|projects|node_modules|vendor|dist|build|target|coverage|env|venv|__pycache__|credentials?|secrets?)$/i;
const SENSITIVE = /(?:^|[._-])(?:env|environment|auth|credentials?|secrets?|tokens?|passwords?|id_rsa|id_ed25519|id_ecdsa|id_dsa)(?:$|[._-])|\.(?:pem|key|p12|pfx|keystore|lock|log|map|sqlite|db)$/i;
const hash = value => createHash('sha256').update(value).digest('hex');
const bytes = value => Buffer.byteLength(JSON.stringify(value));
const stamp = s => [s.dev, s.ino, s.mode, s.nlink, s.size, s.mtimeNs, s.ctimeNs].join(':');
const metadata = t => ({ name: t.name, description: t.description, parameters: t.parameters, promptGuidelines: t.promptGuidelines, sourceInfo: t.sourceInfo });
const toolStamp = t => hash(JSON.stringify(metadata(t)));
const activatable = t => READ_TOOLS.has(t.name) && t.sourceInfo?.source === 'builtin' && t.sourceInfo?.path === `<builtin:${t.name}>`;

// No caller-controlled shell or argv. Ignore Git environment redirection and
// fsmonitor hooks; ls-files and check-ignore neither run filters nor publish.
function git(root, args, input) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('GIT_')));
  return execFileSync('git', ['-c', 'core.fsmonitor=false', '-C', root, ...args], {
    env: { ...env, GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0' },
    encoding: 'utf8', input, maxBuffer: 2 * 1024 * 1024, timeout: 5000,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
}

/**
 * @param {{root: string, read?: boolean, exclusions?: string[],
 * tools: () => import('@earendil-works/pi-coding-agent').ToolInfo[],
 * active: () => string[],
 * activate: (tool: import('@earendil-works/pi-coding-agent').ToolInfo) => boolean}} options
 */
export function createAtlas({ root, read = false, exclusions = [], tools, active, activate }) {
  const canonicalRoot = realpathSync(root);
  if (realpathSync(git(canonicalRoot, ['rev-parse', '--show-toplevel']).trim()) !== canonicalRoot) {
    throw new Error('atlas_root_must_be_git_toplevel');
  }
  if (exclusions.some(p => typeof p !== 'string' || !p || p.startsWith('/') || p.split('/').some(c => !c || c === '.' || c === '..'))) {
    throw new Error('atlas_invalid_exclusion');
  }
  let generation = null;
  let entries = new Map();
  let ordered = [];

  function allowed(path) {
    return typeof path === 'string' && path.length <= 400 && !path.includes('\\') && !/[\x00-\x1f\x7f]/.test(path) &&
      path.split('/').every(p => p && !p.startsWith('.') && !DENIED.test(p) && !SENSITIVE.test(p)) &&
      !exclusions.some(p => path === p || path.startsWith(p + '/'));
  }
  function inventory() {
    const paths = [...new Set(git(canonicalRoot, ['ls-files', '-z', '--cached', '--others', '--exclude-standard']).split('\0').filter(Boolean))];
    if (paths.length > 20000) throw new Error('atlas_inventory_too_large');
    if (!paths.length) return [];
    let ignored = '';
    try {
      ignored = git(canonicalRoot, ['check-ignore', '--no-index', '-z', '--stdin'], paths.join('\0') + '\0');
    } catch (error) {
      if (error.status !== 1) throw new Error('atlas_inventory_unavailable');
    }
    const excluded = new Set(ignored.split('\0'));
    return paths.filter(p => allowed(p) && !excluded.has(p)).sort();
  }
  function fileStat(path) {
    if (!allowed(path)) throw new Error('atlas_path_denied');
    const absolute = resolve(canonicalRoot, path);
    if (relative(canonicalRoot, absolute).split(sep).join('/') !== path || realpathSync(absolute) !== absolute) throw new Error('atlas_path_denied');
    // Reject symlinks at every level, including an in-root directory alias.
    let current = canonicalRoot;
    for (const part of path.split('/')) {
      current = resolve(current, part);
      if (lstatSync(current).isSymbolicLink()) throw new Error('atlas_path_denied');
    }
    const stat = lstatSync(absolute, { bigint: true });
    if (!stat.isFile() || stat.nlink !== 1n) throw new Error('atlas_path_denied');
    return stat;
  }
  function refresh() {
    const next = [];
    for (const path of inventory()) {
      let stat;
      try { stat = fileStat(path); } catch { continue; }
      const version = stamp(stat);
      next.push({ kind: 'file', identity: path, handle: 'f:' + hash(canonicalRoot + '/' + path).slice(0, 20) + '.' + hash(version).slice(0, 12), version, size: Number(stat.size) });
    }
    for (const t of tools()) {
      if (t.name === 'atlas') continue;
      if (typeof t.name !== 'string' || t.name.length > 200 || !t.sourceInfo || !t.parameters) throw new Error('atlas_tool_metadata_unavailable');
      const version = toolStamp(t);
      next.push({ kind: 'tool', identity: t.name, handle: 't:' + version.slice(0, 32), version });
    }
    if (next.length > 22000 || new Set(next.map(e => e.handle)).size !== next.length) throw new Error('atlas_catalog_collision_or_limit');
    entries = new Map(next.map(e => [e.handle, e]));
    ordered = next.sort((a, b) => a.handle.localeCompare(b.handle));
    generation = randomBytes(8).toString('hex');
  }
  const item = e => ({ kind: e.kind, identity: e.identity, ref: e.handle });
  function current(e) {
    if (e.kind === 'tool') {
      const t = tools().find(t => t.name === e.identity);
      if (!t) return 'unavailable';
      return toolStamp(t) === e.version ? 'fresh' : 'stale';
    }
    try {
      if (!inventory().includes(e.identity)) return 'excluded';
      return stamp(fileStat(e.identity)) === e.version ? 'fresh' : 'stale';
    } catch { return 'unavailable'; }
  }
  function readLines(e, at, count) {
    if (!read) return { outcome: 'read_not_authorized' };
    if (!(TEXT.has(extname(e.identity).toLowerCase()) || /(?:^|\/)(?:README|LICENSE|Makefile)$/.test(e.identity))) return { outcome: 'unsupported_file_type' };
    if (e.size > MAX_FILE) return { outcome: 'file_too_large', fileBytes: e.size };
    const fd = openSync(resolve(canonicalRoot, e.identity), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      if (stamp(fstatSync(fd, { bigint: true })) !== e.version) return { outcome: 'stale_handle', freshness: 'stale' };
      const buffer = Buffer.alloc(e.size + 1);
      let size = 0;
      while (size < buffer.length) {
        const n = readSync(fd, buffer, size, buffer.length - size, null);
        if (!n) break;
        size += n;
      }
      if (size !== e.size || stamp(fstatSync(fd, { bigint: true })) !== e.version || stamp(fileStat(e.identity)) !== e.version) return { outcome: 'stale_handle', freshness: 'stale' };
      const data = buffer.subarray(0, size);
      if (data.includes(0)) return { outcome: 'unsupported_file_type' };
      let text;
      try { text = new TextDecoder('utf-8', { fatal: true }).decode(data); } catch { return { outcome: 'unsupported_encoding' }; }
      const lines = text.split('\n');
      if (text.endsWith('\n')) lines.pop();
      if (at > lines.length && !(at === 1 && lines.length === 0)) return { outcome: 'line_out_of_range', totalLines: lines.length };
      const content = lines.slice(at - 1, at - 1 + count).join('\n');
      return { outcome: 'read', content, at, lines: Math.min(count, Math.max(0, lines.length - at + 1)), totalLines: lines.length, more: at - 1 + count < lines.length, contentBytes: Buffer.byteLength(content) };
    } finally { closeSync(fd); }
  }

  // All callers, including Pi's tool_call argument patches, get strict validation.
  return function dispatch(request, signal) {
    let result = { generation, identity: null, selection: 'none', freshness: 'not_checked', outcome: 'invalid_request', truncated: false };
    try {
      signal?.throwIfAborted();
      const p = request;
      if (!p || typeof p !== 'object' || Array.isArray(p) || Object.keys(p).some(k => !['op', 'q', 'ref', 'gen', 'at', 'count'].includes(k)) ||
          !['catalog', 'resolve', 'inspect', 'read', 'activate', 'refresh'].includes(p.op) ||
          ['q', 'ref', 'gen'].some(k => p[k] !== undefined && (typeof p[k] !== 'string' || p[k].length > 400)) ||
          ['at', 'count'].some(k => p[k] !== undefined && (!Number.isSafeInteger(p[k]) || p[k] < 1)) || (p.count !== undefined && p.count > 100)) return finish(result);
      if (p.op === 'refresh') {
        refresh();
        return finish({ ...result, generation, outcome: 'refreshed', selection: 'explicit_refresh', entries: entries.size });
      }
      if (!generation) refresh();
      result.generation = generation;
      if (p.gen !== undefined && p.gen !== generation) return finish({ ...result, outcome: 'stale_snapshot', freshness: 'stale' });
      const queryRead = p.op === 'read' && p.q !== undefined;
      if (queryRead && (p.ref !== undefined || !p.q)) return finish(result);
      if (queryRead && !p.gen) return finish({ ...result, outcome: 'generation_required' });
      let selected;
      let selectionReason;
      if (p.op === 'catalog' || p.op === 'resolve' || queryRead) {
        if (p.op === 'resolve' && !p.q) return finish(result);
        const q = p.q ?? '';
        const kind = q.startsWith('f:') ? 'file' : q.startsWith('t:') ? 'tool' : null;
        const term = kind ? q.slice(2) : q;
        const pool = ordered.filter(e => (!kind || e.kind === kind) && (!queryRead || e.kind === 'file'));
        const exact = pool.filter(e => e.identity === term);
        const matches = exact.length ? exact : pool.filter(e => e.identity.toLowerCase().includes(term.toLowerCase()));
        selectionReason = exact.length ? 'exact_identity' : 'literal_substring';
        if (queryRead && matches.length === 1) {
          selected = matches[0];
        } else {
          // For a query read, at/count are line controls, never candidate paging.
          const start = queryRead ? 0 : (p.at ?? 1) - 1;
          const limit = queryRead ? MAX_ITEMS : Math.min(p.count ?? MAX_ITEMS, MAX_ITEMS);
          const candidates = matches.slice(start, start + limit).map(item);
          result = { ...result, selection: selectionReason, outcome: matches.length === 0 ? 'not_found' : p.op === 'catalog' ? 'catalog' : matches.length === 1 ? 'resolved' : 'ambiguous', candidates, total: matches.length, more: start + candidates.length < matches.length };
          if (matches.length === 1) result.identity = matches[0].identity;
          return finish(result);
        }
      }
      if (!p.gen) return finish({ ...result, outcome: 'generation_required' });
      const e = selected ?? entries.get(p.ref);
      if (!e) return finish({ ...result, outcome: 'unknown_handle' });
      result = { ...result, identity: e.identity, selection: selected ? 'snapshot_' + selectionReason : 'identity_handle', freshness: current(e), ...(selected ? { ref: e.handle } : {}) };
      if (result.freshness !== 'fresh') return finish({ ...result, outcome: 'stale_handle' });
      if (p.op === 'inspect') {
        const info = e.kind === 'file' ? { fileBytes: e.size, readAuthorized: read } : metadata(tools().find(t => t.name === e.identity));
        return finish({ ...result, outcome: 'inspected', info });
      }
      if (p.op === 'read' && e.kind === 'file') return finish({ ...result, ...readLines(e, p.at ?? 1, p.count ?? 40) });
      if (p.op === 'activate' && e.kind === 'tool') {
        const t = tools().find(t => t.name === e.identity);
        if (!activatable(t)) return finish({ ...result, outcome: 'execution_disallowed' });
        // Activation keeps the original definition and its execution hooks.
        // It never executes the tool, and only restores an operator-deferred tool.
        if (!active().includes(t.name) && !activate(t)) return finish({ ...result, outcome: 'activation_not_authorized' });
        return finish({ ...result, outcome: 'active_for_next_call', tool: t.name });
      }
      return finish({ ...result, outcome: 'execution_disallowed' });
    } catch (error) {
      return finish({ ...result, outcome: signal?.aborted ? 'cancelled' : 'unavailable', error: error.message?.startsWith('atlas_') ? error.message : 'atlas_operation_unavailable' });
    }
  };
}

// Count exact model-facing UTF-8 JSON bytes, including the count itself. Oversize
// structured payloads are refused, not cut into invalid JSON or hidden on disk.
function finish(result) {
  if (bytes(result) > MAX_RESULT - 80) {
    result = { generation: result.generation, identity: result.identity, selection: result.selection, freshness: result.freshness, outcome: 'output_too_large', truncated: true, omittedBytes: bytes(result) };
  }
  result.outputBytes = 0;
  while (result.outputBytes !== bytes(result)) result.outputBytes = bytes(result);
  return result;
}

export { activatable, toolStamp };
