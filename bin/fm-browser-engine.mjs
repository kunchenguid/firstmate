// Page-side implementation for `bin/fm-browser.sh step`.
// The wrapper prepends a JSON `PARAMS` literal and pipes this module to
// `chrome-devtools-axi run`; only the sanitized result is written to stdout.

const INTERACTIVE_ROLES = new Set([
  'button', 'link', 'textbox', 'searchbox', 'combobox', 'checkbox', 'radio',
  'menuitem', 'tab', 'option', 'switch', 'listbox',
]);
const SAFE_ERRORS = new Set([
  'TARGET_NOT_FOUND', 'WITHIN_NOT_FOUND', 'AMBIGUOUS_TARGET', 'EXPECT_TIMEOUT', 'BROWSER_ACTION_FAILED',
]);
const MAX_TIMEOUT_MS = 120_000;

export function normalize(value) {
  return String(value ?? '').normalize('NFKC').toLowerCase().replace(/\s+/g, ' ').trim();
}

export function redact(value) {
  let text = String(value ?? '')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----/g, '[redacted]')
    .replace(/(?:TYPESAFE_API_KEY|OPENROUTER_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|FMX_PAIRING_TOKEN|FM_MAIL_PASS|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID|GITHUB_TOKEN|GH_TOKEN|JEV_API_KEY)=\S+/gi, '[redacted]')
    .replace(/(?:sk-or-|github_pat_|ghp_|cfut_)[^\s"'<>]+/gi, '[redacted]')
    .replace(/\bsk-[A-Za-z0-9_-]{16,}/g, '[redacted]')
    .replace(/https?:\/\/[^\s"'<>]+/gi, '[url]')
    .replace(/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g, '[email]');
  text = text.replace(/(^|[^A-Za-z0-9_\-+/=.])([A-Za-z0-9_\-+/=.]{24,})(?=$|[^A-Za-z0-9_\-+/=.])/g,
    (match, prefix, token) => /[A-Za-z]/.test(token) && /\d/.test(token) ? `${prefix}[opaque]` : match);
  const credential = text.match(/(^|[^A-Za-z0-9])(?:token|key|secret|password|passcode|bearer|authorization|api|otp|pin|credential)(?![A-Za-z0-9])/i);
  if (credential) text = `${text.slice(0, credential.index + credential[0].length)} [redacted]`;
  return text.replace(/\d{6,}/g, '[number]').replace(/\s+/g, ' ').trim();
}

function decodeSnapshotLabel(value) {
  return value.replace(/\\(["\\])/g, '$1');
}

export function parseSnapshot(snapshot) {
  const nodes = [];
  const lines = String(snapshot ?? '').split('\n');
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    const match = line.match(/\buid=(\S+)\s+([\w-]+)(?:\s+"((?:[^"\\]|\\.)*)")?/);
    if (!match) continue;
    const leading = line.match(/^\s*/)?.[0] ?? '';
    nodes.push({
      uid: match[1],
      role: match[2].toLowerCase(),
      label: decodeSnapshotLabel(match[3] ?? ''),
      indent: leading.replace(/\t/g, '  ').length,
      lineIndex,
    });
  }
  return nodes;
}

export function parseSelector(input, { allowTitle = false } = {}) {
  if (typeof input !== 'string') throw new Error('selector must be text');
  const match = input.trim().match(/^([a-z][a-z0-9-]*)(=|~)(.+)$/i);
  if (!match) throw new Error('invalid selector');
  const role = match[1].toLowerCase();
  if (role === 'title' && !allowTitle) throw new Error('unsupported role');
  const label = match[3].trim();
  if (!label) throw new Error('empty selector label');
  return { role, operator: match[2], label };
}

function selectorMatches(node, selector) {
  if (selector.role === 'title') {
    return node.role === 'rootwebarea' && normalize(node.label).includes(normalize(selector.label));
  }
  if (node.role !== selector.role) return false;
  const nodeLabel = normalize(node.label);
  const expected = normalize(selector.label);
  return selector.operator === '=' ? nodeLabel === expected : nodeLabel.includes(expected);
}

function descendantsOf(nodes, container) {
  return nodes.filter((node) => {
    if (node.lineIndex <= container.lineIndex || node.indent <= container.indent) return false;
    return !nodes.some((other) => other.lineIndex > container.lineIndex &&
      other.lineIndex < node.lineIndex && other.indent <= container.indent);
  });
}

export function resolveSelector(nodes, selector, withinSelector = null) {
  let scope = nodes;
  if (withinSelector) {
    const containers = nodes.filter((node) => selectorMatches(node, withinSelector));
    if (!containers.length) return { target: null, error: 'WITHIN_NOT_FOUND' };
    if (containers.length > 1) return { target: null, error: 'AMBIGUOUS_TARGET' };
    scope = descendantsOf(nodes, containers[0]);
  }
  const matches = scope.filter((node) => selectorMatches(node, selector));
  if (!matches.length) return { target: null, error: 'TARGET_NOT_FOUND' };
  if (matches.length > 1) return { target: null, error: 'AMBIGUOUS_TARGET' };
  return { target: matches[0], error: null };
}

function normalizeExpectation(value) {
  if (!value) return null;
  if (value.kind === 'appears' || value.kind === 'gone' || value.kind === 'title') {
    const selector = parseSelector(value.selector, { allowTitle: value.kind === 'title' });
    if ((value.kind === 'title') !== (selector.role === 'title') ||
      (value.kind === 'title' && selector.operator !== '~')) throw new Error('invalid title expectation');
    return { ...value, selector };
  }
  if (value.kind === 'url-path') {
    if (typeof value.path !== 'string' || !value.path.startsWith('/') || /[?#]/.test(value.path)) {
      throw new Error('invalid URL path expectation');
    }
    return value;
  }
  throw new Error('invalid expectation');
}

export function validateParams(params) {
  if (!params || typeof params !== 'object' || Array.isArray(params)) throw new Error('invalid params');
  if (!['click', 'fill', 'select', 'press'].includes(params.action)) throw new Error('invalid action');
  if (params.action === 'press') {
    if (typeof params.key !== 'string' || !params.key.trim() || params.target || params.within) {
      throw new Error('invalid press action');
    }
  } else {
    if (typeof params.target !== 'string') throw new Error('missing target');
    const target = parseSelector(params.target);
    if (!INTERACTIVE_ROLES.has(target.role)) throw new Error('target role is not interactive');
    if (params.action === 'select' && target.role !== 'combobox') throw new Error('select target must be a combobox');
    if (params.within != null) parseSelector(params.within);
  }
  if (params.action === 'fill' && typeof params.value !== 'string') throw new Error('missing fill value');
  if (params.action === 'select' && (typeof params.option !== 'string' || !params.option.trim())) {
    throw new Error('missing option');
  }
  if (params.action !== 'fill' && Object.hasOwn(params, 'value')) throw new Error('unexpected fill value');
  if (params.action !== 'select' && Object.hasOwn(params, 'option')) throw new Error('unexpected option');
  if (params.timeoutMs != null && (!Number.isInteger(params.timeoutMs) || params.timeoutMs < 1 || params.timeoutMs > MAX_TIMEOUT_MS)) {
    throw new Error('invalid timeout');
  }
  if (params.expectation != null) normalizeExpectation(params.expectation);
  return params;
}

function accessibleInteractive(nodes) {
  return nodes.filter((node) => INTERACTIVE_ROLES.has(node.role));
}

function nodePair(node) {
  return `${node.role}|${node.label}`;
}

function diffPairs(before, after) {
  const beforeCounts = new Map();
  const afterCounts = new Map();
  for (const node of before) beforeCounts.set(nodePair(node), (beforeCounts.get(nodePair(node)) ?? 0) + 1);
  for (const node of after) afterCounts.set(nodePair(node), (afterCounts.get(nodePair(node)) ?? 0) + 1);
  const appeared = [];
  const gone = [];
  for (const [pair, count] of afterCounts) {
    const delta = count - (beforeCounts.get(pair) ?? 0);
    for (let index = 0; index < delta; index += 1) appeared.push(pair);
  }
  for (const [pair, count] of beforeCounts) {
    const delta = count - (afterCounts.get(pair) ?? 0);
    for (let index = 0; index < delta; index += 1) gone.push(pair);
  }
  return { appeared, gone };
}

function expectationMet(expectation, nodes, pathname) {
  if (!expectation) return true;
  if (expectation.kind === 'url-path') return pathname === expectation.path;
  const found = nodes.some((node) => selectorMatches(node, expectation.selector));
  return expectation.kind === 'gone' ? !found : found;
}

export function sanitizeResult(result) {
  const safe = {
    step: redact(result?.step ?? 'step').slice(0, 32),
    ok: result?.ok === true,
    verified: result?.ok === true && result?.verified === true,
    appeared: [],
    gone: [],
    ms: Number.isFinite(result?.ms) ? Math.max(0, Math.round(result.ms)) : 0,
  };
  const pairs = [
    ...(Array.isArray(result?.appeared) ? result.appeared.map((label) => ['appeared', label]) : []),
    ...(Array.isArray(result?.gone) ? result.gone.map((label) => ['gone', label]) : []),
  ].slice(0, 12);
  for (const [kind, label] of pairs) safe[kind].push(redact(label).slice(0, 96));
  if (!safe.ok) {
    safe.error = SAFE_ERRORS.has(result?.error) ? result.error : 'BROWSER_ACTION_FAILED';
  }
  return safe;
}

export function selectorFromRoute(target, allowTitle = false) {
  if (!target || typeof target !== 'object' || Array.isArray(target) ||
      typeof target.role !== 'string' || typeof target.label !== 'string') throw new Error('invalid route target');
  const selector = `${target.role}=${target.label}`;
  parseSelector(selector, { allowTitle });
  return selector;
}

function routeExpectation(expect) {
  if (expect == null) return null;
  const keys = Object.keys(expect);
  if (keys.length !== 1 || !['appears', 'gone', 'title', 'url_path'].includes(keys[0])) throw new Error('invalid route expectation');
  const kind = keys[0];
  if (kind === 'url_path') return { kind: 'url-path', path: expect[kind] };
  return { kind: kind === 'appears' ? 'appears' : kind, selector: selectorFromRoute(expect[kind], kind === 'title') };
}

function substituteRouteValue(value, vars) {
  if (typeof value !== 'string') return value;
  return value.replace(/\$\{([A-Za-z][A-Za-z0-9_-]*)\}/g, (_, name) => {
    if (!Object.hasOwn(vars, name)) throw new Error(`missing route variable: ${name}`);
    return vars[name];
  });
}

export function validateRoute(route) {
  if (!route || typeof route !== 'object' || route.version !== 1 ||
      !/^[a-z0-9.-]+$/.test(route.host ?? '') || route.host === '.' || route.host === '..' ||
      !route.host.split('.').every((label) => /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label)) ||
      !/^[a-z0-9][a-z0-9_-]*$/.test(route.route ?? '') ||
      !route.start || typeof route.start.url_path !== 'string' || !route.start.url_path.startsWith('/') || /[?#]/.test(route.start.url_path) ||
      !route.vars || typeof route.vars !== 'object' || Array.isArray(route.vars) || !Array.isArray(route.steps)) {
    throw new Error('invalid version 1 route');
  }
  const ids = new Set();
  for (const [name, definition] of Object.entries(route.vars)) {
    if (!/^[A-Za-z][A-Za-z0-9_-]*$/.test(name) || !definition || typeof definition !== 'object' || typeof definition.required !== 'boolean') {
      throw new Error('invalid route variable definition');
    }
  }
  for (const step of route.steps) {
    if (!step || typeof step !== 'object' || !/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(step.id ?? '') || ids.has(step.id)) throw new Error('invalid or duplicate route step id');
    ids.add(step.id);
    if (!['click', 'fill', 'select', 'press', 'handoff'].includes(step.do)) throw new Error('invalid route action');
    if (step.confirm != null && typeof step.confirm !== 'boolean') throw new Error('invalid confirmation flag');
    if (step.timeoutMs != null && (!Number.isInteger(step.timeoutMs) || step.timeoutMs < 1 || step.timeoutMs > MAX_TIMEOUT_MS)) throw new Error('invalid route timeout');
    if (step.do === 'handoff') {
      if (typeof step.say !== 'string' || !step.say.trim() || !step.expect) throw new Error('handoff needs say and expect');
    } else if (step.do !== 'press') selectorFromRoute(step.target);
    if (step.target?.within) selectorFromRoute(step.target.within);
    if (step.expect) routeExpectation(step.expect);
    if (step.do === 'press' && (typeof step.key !== 'string' || !step.key.trim())) throw new Error('press step needs a key');
    if (step.do === 'fill' && typeof step.value !== 'string') throw new Error('fill step needs a value');
    if (step.do === 'select' && typeof step.option !== 'string') throw new Error('select step needs an option');
  }
  if (!Array.isArray(route.heal_log)) throw new Error('invalid route heal log');
  return route;
}

function tokenSimilarity(left, right) {
  const tokens = (value) => new Set(normalize(value).split(/[^\p{L}\p{N}]+/u).filter(Boolean));
  const a = tokens(left);
  const b = tokens(right);
  if (!a.size || !b.size) return 0;
  let intersection = 0;
  for (const item of a) if (b.has(item)) intersection += 1;
  return intersection / (a.size + b.size - intersection);
}

async function executeRouteStep(step, vars, pageApi) {
  const expectation = routeExpectation(step.expect);
  if (step.do === 'handoff') {
    const normalized = normalizeExpectation(expectation);
    const deadline = Date.now() + (step.timeoutMs ?? 120000);
    for (;;) {
      const nodes = parseSnapshot(await pageApi.snapshot());
      const pathname = normalized.kind === 'url-path' ? await pageApi.eval(() => location.pathname) : null;
      if (expectationMet(normalized, nodes, pathname)) return { ok: true, verified: true };
      if (Date.now() >= deadline) return { ok: false, error: 'EXPECT_TIMEOUT' };
      await pageApi.wait(100);
    }
  }
  if (step.confirm === true) return { ok: false, error: 'CONFIRM_REQUIRED' };
  const params = { action: step.do, expectation };
  if (step.do === 'press') params.key = step.key;
  else {
    params.target = selectorFromRoute(step.target);
    if (step.target.within) params.within = selectorFromRoute(step.target.within);
  }
  if (step.do === 'fill') params.value = substituteRouteValue(step.value, vars);
  if (step.do === 'select') params.option = substituteRouteValue(step.option, vars);
  let result = await executeStep(params, pageApi);
  if (result.error === 'TARGET_NOT_FOUND' && step.confirm !== true) {
    const nodes = parseSnapshot(await pageApi.snapshot());
    const exact = parseSelector(params.target);
    let scope = nodes;
    if (step.target.within) {
      const container = resolveSelector(nodes, parseSelector(selectorFromRoute(step.target.within)));
      if (!container.target) return result;
      scope = descendantsOf(nodes, container.target);
    }
    const candidates = scope.filter((node) => node.role === exact.role)
      .map((node) => ({ node, score: tokenSimilarity(node.label, exact.label) }))
      .filter((candidate) => candidate.score >= 0.6)
      .sort((a, b) => b.score - a.score);
    if (candidates.length && (!candidates[1] || candidates[0].score > candidates[1].score)) {
      params.target = `${exact.role}=${candidates[0].node.label}`;
      result = await executeStep(params, pageApi);
      if (result.ok && result.verified) {
        result.healedTarget = candidates[0].node.label;
        result.healedConfidence = candidates[0].score;
      }
    }
  }
  return result;
}

export async function executeRoute(routeInput, vars = {}, from = null, pageApi) {
  const route = validateRoute(routeInput);
  const known = new Set(Object.keys(route.vars));
  for (const key of Object.keys(vars)) if (!known.has(key)) return { ok: false, error: 'UNKNOWN_VARIABLE' };
  for (const [key, definition] of Object.entries(route.vars)) {
    if (definition.required && !Object.hasOwn(vars, key)) return { ok: false, error: 'MISSING_VARIABLE' };
    if (Object.hasOwn(vars, key) && (typeof vars[key] !== 'string' || /(?:token|secret|pass|key)/i.test(key) || redact(vars[key]) !== vars[key])) {
      return { ok: false, error: 'UNSAFE_VARIABLE' };
    }
  }
  let begin = 0;
  if (from != null) {
    const index = route.steps.findIndex((step) => step.id === from);
    if (index < 0) return { ok: false, error: 'UNKNOWN_RESUME_STEP' };
    begin = index;
  }
  const actual = await pageApi.eval(() => ({ host: location.hostname, path: location.pathname }));
  if (actual.host.toLowerCase() !== route.host || (begin === 0 && actual.path !== route.start.url_path)) {
    return { ok: false, error: 'START_MISMATCH' };
  }
  const completed = [];
  const heals = [];
  for (const step of route.steps.slice(begin)) {
    if (step.confirm === true) return { ok: false, error: 'CONFIRM_REQUIRED', step: step.id, completed };
    const result = await executeRouteStep(step, vars, pageApi);
    if (!result.ok) return { ok: false, error: result.error ?? 'BROWSER_ACTION_FAILED', step: step.id, completed };
    completed.push(step.id);
    if (result.healedTarget) heals.push({ step: step.id, to: redact(result.healedTarget).slice(0, 96), confidence: result.healedConfidence });
    if (step.do === 'handoff') return { ok: true, completed, heals, handoff: { step: step.id, say: redact(step.say).slice(0, 500) } };
  }
  return { ok: true, completed, heals };
}

export async function executeStep(rawParams, pageApi) {
  const started = Date.now();
  let params;
  let before = [];
  let after = [];
  let hasAfterSnapshot = false;
  let result = { step: rawParams?.action ?? 'step', ok: false, verified: false };
  try {
    params = validateParams({ ...rawParams });
    if (params.expectation != null) params.expectation = normalizeExpectation(params.expectation);
    const beforeSnapshot = await pageApi.snapshot();
    before = parseSnapshot(beforeSnapshot);
    let target = null;
    if (params.action !== 'press') {
      const targetSelector = parseSelector(params.target);
      const withinSelector = params.within ? parseSelector(params.within) : null;
      const selected = resolveSelector(before, targetSelector, withinSelector);
      if (!selected.target) {
        result = {
          ...result,
          error: selected.error,
        };
        return sanitizeResult({ ...result, ms: Date.now() - started });
      }
      target = selected.target;
    }
    if (params.action === 'click') await pageApi.click(`@${target.uid}`);
    if (params.action === 'fill') await pageApi.fill(`@${target.uid}`, params.value);
    if (params.action === 'select') await pageApi.fill(`@${target.uid}`, params.option);
    if (params.action === 'press') await pageApi.press(params.key);

    const deadline = Date.now() + (params.timeoutMs ?? 5000);
    let currentPath = null;
    for (;;) {
      const afterSnapshot = await pageApi.snapshot();
      after = parseSnapshot(afterSnapshot);
      hasAfterSnapshot = true;
      if (params.expectation?.kind === 'url-path') {
        currentPath = await pageApi.eval(() => location.pathname);
      }
      if (expectationMet(params.expectation, after, currentPath)) {
        result.ok = true;
        result.verified = Boolean(params.expectation);
        break;
      }
      if (Date.now() >= deadline) {
        result.error = 'EXPECT_TIMEOUT';
        break;
      }
      await pageApi.wait(100);
    }
  } catch {
    result.error = 'BROWSER_ACTION_FAILED';
  }
  const changes = hasAfterSnapshot
    ? diffPairs(accessibleInteractive(before), accessibleInteractive(after))
    : { appeared: [], gone: [] };
  return sanitizeResult({ ...result, ...changes, ms: Date.now() - started });
}

if (typeof page !== 'undefined' && typeof PARAMS !== 'undefined') {
  const result = PARAMS.mode === 'route'
    ? await executeRoute(PARAMS.route, PARAMS.vars, PARAMS.from, page)
    : await executeStep(PARAMS, page);
  if (PARAMS.record && result.ok && result.verified) {
    const location = await page.eval(() => ({ host: location.hostname.toLowerCase(), path: location.pathname }));
    console.log(JSON.stringify({ result, record: { ...PARAMS.record, currentHost: location.host, path: location.path } }));
  } else {
    console.log(JSON.stringify(result));
  }
}
