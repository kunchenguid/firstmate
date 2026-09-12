import {
  clean, buffer, put, diff, palette, glyphs, fit, left, pace, paceWord, reset, header, footer,
  metrics, row, countdown as formatReset, bandInk, paceInk,
} from '../../../fm-tui-core/src/index.mjs';

export const countdown = formatReset;

function rank(pool) {
  const status = pool.tags[0];
  if (status === 'HOT') return 0;
  if (status === 'UNDER' || status === 'ON PACE') return 1;
  if (status === 'PACE UNKNOWN') return 2;
  return 3;
}

function binding(pool) {
  const measured = pool.windows.filter(row => row.remaining !== null);
  if (!measured.length) return null;
  return measured.find(row => row.remaining === pool.remaining) ||
    measured.reduce((a, b) => a.remaining <= b.remaining ? a : b);
}

function windowTag(row) {
  const name = clean(row.label || row.id || '');
  if (name) return name.length > 8 ? name.slice(0, 7) + '~' : name;
  const s = row.windowSeconds;
  if (typeof s === 'number' && s >= 86400) return `${Math.round(s / 86400)}d`;
  if (typeof s === 'number' && s >= 3600) return `${Math.round(s / 3600)}h`;
  return '?';
}

function binds(row) {
  const tag = row && windowTag(row);
  return tag && tag !== '?' ? `${tag} binds` : '';
}

function notes(pool, frame, ascii, status) {
  const bits = [];
  if (!ascii && paceWord(status) === 'HOT') bits.unshift('over pace');
  if (pool.tags.includes('DUPLICATE ACCOUNT')) {
    const other = frame.pools.find(row => row !== pool && row.provider === pool.provider && row.tags.includes('DUPLICATE ACCOUNT'));
    bits.push(`DUPLICATE of ${clean(other?.id || other?.label || '?')}`);
  }
  if (pool.tags.includes('IDENTITY MISMATCH')) bits.push('IDENTITY MISMATCH');
  const bound = binding(pool);
  if (bound && pool.windows.length > 1) bits.push(binds(bound));
  if (pool.tags[0] === 'PACE UNKNOWN') bits.push('pace unknown: no window start');
  if (ascii && pool.email) bits.unshift(clean(pool.email));
  return bits.join(ascii ? ' | ' : ' · ');
}

function windowLines(pool, width, ascii, m) {
  if (pool.windows.length < 2) return [];
  if (new Set(pool.windows.map(w => w.remaining)).size < 2) return [];
  const set = glyphs(ascii);
  return pool.windows.map(w => {
    const cols = [
      { text: `  ${windowTag(w)}`, width: m.label },
      { text: left(w.remaining, set), width: 18 },
      { text: pace(w.status, w.delta), width: 11 },
      { text: reset(w.resetsIn), width: 6, align: 'right' },
    ];
    if (m.ident) cols.push({ text: '', width: 11 });
    cols.push({ text: '' });
    return { kind: 'window', text: row(cols, width), status: w.status };
  });
}

function title(pool) {
  const name = clean(pool.label || pool.id);
  return pool.plan ? `${name} ${clean(pool.plan)}` : name;
}

function clock(ts, next, ascii) {
  const t = Date.parse(ts);
  const when = Number.isFinite(t) ? `${new Date(t).toISOString().slice(11, 19)}Z` : '?';
  const sep = ascii ? '  ' : ' · ';
  return `data ${when}${sep}age 0s${sep}next ${next}s`;
}

function countsOf(frame) {
  const tag = name => frame.pools.filter(pool => pool.tags[0] === name).length;
  return {
    pools: frame.pools.length,
    hot: tag('HOT'),
    under: tag('UNDER'),
    even: tag('ON PACE'),
    unknown: tag('PACE UNKNOWN'),
    unavailable: tag('UNAVAILABLE'),
  };
}

function layout(frame, { width = 100, clean: ascii = false, refreshSeconds = 60 } = {}) {
  const set = glyphs(ascii);
  const m = metrics(width);
  const sep = ascii ? ' / ' : ' · ';
  const heading = [
    { text: 'POOL', width: m.label },
    { text: 'LEFT', width: 18 },
    { text: 'PACE', width: 11 },
    { text: 'RESET', width: 6 },
  ];
  if (m.ident) heading.push({ text: 'ACCOUNT', width: 11 });
  heading.push({ text: 'NOTE' });
  const live = frame.pools.map((pool, index) => ({ pool, index }))
    .filter(({ pool }) => pool.tags[0] !== 'UNAVAILABLE')
    .sort((a, b) => rank(a.pool) - rank(b.pool) ||
      (a.pool.remaining === null) - (b.pool.remaining === null) ||
      (a.pool.remaining ?? 0) - (b.pool.remaining ?? 0) || a.index - b.index)
    .map(({ pool }) => pool);
  const lines = [
    { kind: 'header', text: header(`MARVIN  quota left${sep}pace`, clock(frame.ts, refreshSeconds, ascii), width), m },
    { kind: 'heading', text: row(heading, width), m },
  ];
  if (!frame.pools.length) {
    lines.push({ kind: 'empty', text: fit('no quota pools configured or discovered - see config/marvin.json', width) });
  }
  for (const pool of live) {
    const bound = binding(pool);
    const status = bound?.status || pool.tags[0];
    const delta = bound?.delta ?? null;
    const resetsIn = bound?.resetsIn ?? null;
    const ident = ascii ? (pool.email || pool.id) : pool.id;
    const cols = [
      { text: title(pool), width: m.label },
      { text: left(pool.remaining, set), width: 18 },
      { text: pace(status, delta), width: 11 },
      { text: reset(resetsIn), width: 6, align: 'right' },
    ];
    if (m.ident) cols.push({ text: clean(ident || ''), width: 11 });
    cols.push({ text: notes(pool, frame, ascii, status) });
    lines.push({ kind: 'pool', text: row(cols, width), remaining: pool.remaining, status, delta, resetsIn, m });
    for (const extra of windowLines(pool, width, ascii, m)) lines.push(extra);
  }
  const foot = footer(countsOf(frame), 'bar=left  !=<50%  !!=<25%  pt=vs ideal  Ctrl+C exit', width);
  lines.push({ kind: 'footer', text: foot[0] });
  if (foot[1]) lines.push({ kind: 'legend', text: foot[1] });
  return lines;
}

function sgr(text, { ink = 0, dim = false, bold = false } = {}) {
  let out = '';
  if (bold) out += '\x1b[1m';
  if (dim) out += '\x1b[2m';
  if (ink) out += `\x1b[38;5;${palette[ink]}m`;
  return out ? `${out}${text}\x1b[0m` : text;
}

function emitPool(line) {
  const m = line.m, t = line.text, g = 2;
  let i = 0, out = sgr(t.slice(0, m.label), { bold: true });
  i = m.label;
  out += t.slice(i, i + g); i += g;
  out += sgr(t.slice(i, i + 18), { ink: bandInk(line.remaining) }); i += 18;
  out += t.slice(i, i + g); i += g;
  const paceCell = t.slice(i, i + 11); i += 11;
  const word = paceCell.slice(0, 5), pts = paceCell.slice(5);
  const pw = paceWord(line.status);
  out += pw === 'EVEN' ? sgr(word, { ink: 4, dim: true })
    : pw === '?' ? sgr(word, { dim: true })
    : sgr(word, { ink: pw === 'HOT' ? 5 : 4 });
  if (pw === '?' || line.delta === null || !Number.isFinite(line.delta)) out += sgr(pts, { dim: true });
  else if (line.delta < 0) out += sgr(pts, { ink: 5 });
  else out += sgr(pts, { ink: 4, dim: pw === 'EVEN' });
  out += t.slice(i, i + g); i += g;
  const resetCell = t.slice(i, i + 6); i += 6;
  out += (line.resetsIn !== null && line.resetsIn < 7200) ? sgr(resetCell, { ink: 3 }) : sgr(resetCell, { dim: true });
  return out + t.slice(i);
}

function emit(line, color) {
  const t = line.text.trimEnd();
  if (!color) return t;
  if (line.kind === 'header' || line.kind === 'heading' || line.kind === 'legend' || line.kind === 'empty') return sgr(t, { dim: true });
  if (line.kind === 'footer') return t.replace(/unavailable \d+/g, s => sgr(s, { dim: true }));
  if (line.kind === 'window') return `\x1b[2m${t.replace(/HOT/g, `\x1b[0m${sgr('HOT', { ink: 5 })}\x1b[2m`)}\x1b[0m`;
  if (line.kind === 'pool') return emitPool(line).trimEnd();
  return t;
}

function textFrame(lines, color) {
  return lines.map(line => emit(line, color)).join('\n') + '\n';
}

export function renderFrame(frame, options = {}) {
  return textFrame(layout(frame, options), options.color && !options.clean);
}

function paint(lines, width, color) {
  const grid = buffer(width + 1, Math.max(1, lines.length));
  lines.forEach((line, y) => {
    const t = line.text;
    const base = !color ? 0 : (line.kind === 'header' || line.kind === 'heading' || line.kind === 'legend' || line.kind === 'window' || line.kind === 'empty') ? 2 : 0;
    put(grid, 0, y, t, base);
    if (!color) return;
    if (line.kind === 'pool') {
      const m = line.m, g = 2;
      put(grid, 0, y, t.slice(0, m.label), 1);
      const leftAt = m.label + g;
      put(grid, leftAt, y, t.slice(leftAt, leftAt + 18), bandInk(line.remaining));
      const paceAt = leftAt + 18 + g;
      put(grid, paceAt, y, t.slice(paceAt, paceAt + 11), paceInk(line.status));
      const resetAt = paceAt + 11 + g;
      put(grid, resetAt, y, t.slice(resetAt, resetAt + 6), (line.resetsIn !== null && line.resetsIn < 7200) ? 3 : 2);
    }
    if (line.kind === 'window') {
      let at = 0;
      while ((at = t.indexOf('HOT', at)) >= 0) { put(grid, at, y, 'HOT', 5); at += 3; }
    }
    if (line.kind === 'footer') {
      const u = t.match(/unavailable \d+/);
      if (u) put(grid, t.indexOf(u[0]), y, u[0], 2);
    }
  });
  return grid;
}

export function terminalRenderer(output, options) {
  let previous, previousKey;
  return { render(frame) {
    const width = options.width();
    const view = { width, clean: options.clean, refreshSeconds: options.refreshSeconds || 60 };
    const lines = options.json ? null : layout(frame, view);
    const text = options.json ? JSON.stringify(frame) + '\n' : textFrame(lines, false);
    const key = JSON.stringify([width, frame.pools, frame.counts]);
    if (options.watch && output.tty && !options.clean && !options.json) {
      if (key !== previousKey) {
        const grid = paint(lines, width, output.color);
        if (!previous || previous.length !== grid.length || previous[0].length !== grid[0].length) {
          output.write('\x1b[H\x1b[2J'); previous = null;
        }
        output.write(diff(previous, grid, output.color));
        previous = grid;
      }
    } else output.write(options.json ? text : textFrame(lines, output.color && !options.clean));
    previousKey = key;
    return text;
  } };
}

export function renderHistory(records) {
  const lines = ['QUOTA HISTORY | UTC | pool / window | LEFT | ideal | PACE'];
  for (const record of records.filter(row => row.event === 'sample')) {
    for (const pool of record.pools || []) for (const row of pool.windows || []) {
      const delta = row.delta === null ? '?' : `${row.delta >= 0 ? '+' : ''}${Math.round(row.delta)}pt`;
      lines.push(clean(`${record.ts} ${pool.id}/${row.id} ${row.remaining === null ? '?' : `${Math.floor(row.remaining)}%`} ideal ${row.idealPercent === null ? '?' : `${Math.round(row.idealPercent)}%`} ${delta} ${row.status}`));
    }
  }
  if (lines.length === 1) lines.push('No samples in the last 7 days. Run status or watch to record quota.');
  return lines.join('\n') + '\n';
}
