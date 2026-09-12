// Fixed-width row fragments. Callers pass the writable width (last column already reserved).
export const UNICODE = { full: '█', empty: '░', unknown: '·' };
export const ASCII = { full: '#', empty: '-', unknown: '.' };
export const glyphs = ascii => ascii ? ASCII : UNICODE;

export function fit(text, width, align = 'left') {
  const value = String(text ?? '');
  if (width <= 0) return '';
  if (value.length > width) return width === 1 ? '~' : value.slice(0, width - 1) + '~';
  return align === 'right' ? value.padStart(width) : value.padEnd(width);
}

export function label(text, width) {
  return fit(text, width);
}

export function floorPercent(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null;
  if (value < 0) return 0;
  if (value > 100) return 100;
  return Math.floor(value);
}

function fillCount(floored) {
  if (floored <= 0) return 0;
  if (floored >= 100) return 10;
  const tenth = floored / 10;
  let n = Math.floor(tenth + 0.5);
  if (tenth % 1 === 0.5 && n % 2) n -= 1;
  return Math.min(9, Math.max(1, n));
}

export function bandMark(value) {
  const n = floorPercent(value);
  if (n === null) return '??';
  if (n < 25) return '!!';
  if (n < 50) return '! ';
  return '  ';
}

export function left(value, set = UNICODE) {
  const n = floorPercent(value);
  const bar = n === null ? set.unknown.repeat(10)
    : set.full.repeat(fillCount(n)) + set.empty.repeat(10 - fillCount(n));
  return bar + (n === null ? '?' : `${n}%`).padStart(5) + ' ' + bandMark(n);
}

export function paceWord(status) {
  if (status === 'HOT' || status === 'UNDER') return status;
  if (status === 'ON PACE' || status === 'EVEN') return 'EVEN';
  return '?';
}

export function pace(status, delta) {
  const word = paceWord(status).padEnd(5);
  if (paceWord(status) === '?' || typeof delta !== 'number' || !Number.isFinite(delta)) return word + '      ';
  const n = Math.round(delta);
  return word + `${n >= 0 ? '+' : ''}${n}pt`.padStart(6);
}

export function countdown(seconds) {
  if (seconds === null || seconds === undefined || !Number.isFinite(seconds)) return '?';
  const s = Math.max(0, Math.floor(seconds));
  if (s >= 86400) return `${Math.floor(s / 86400)}d${String(Math.floor(s % 86400 / 3600)).padStart(2, '0')}h`;
  return `${Math.floor(s / 3600)}h${String(Math.floor(s % 3600 / 60)).padStart(2, '0')}m`;
}

export function reset(seconds) {
  return fit(countdown(seconds), 6, 'right');
}

export function header(title, right, width) {
  const clock = String(right ?? '');
  if (!clock) return fit(title, width);
  if (clock.length >= width) return fit(clock, width);
  return fit(title, width - clock.length) + clock;
}

export function footer(counts, legend, width) {
  const line = ['pools', 'HOT', 'UNDER', 'EVEN', '?', 'unavailable']
    .map(key => `${key} ${counts[key === 'pools' ? 'pools' : key === '?' ? 'unknown' : key.toLowerCase()]}`)
    .join('  ');
  const joined = `${line}   ${legend}`;
  if (width >= 100 && joined.length <= width) return [joined];
  return [fit(line, width).trimEnd(), fit(legend, width).trimEnd()];
}

export function unavailable(entries, width, ascii = false) {
  if (!entries.length) return '';
  const sep = ascii ? ' | ' : ' · ';
  const bits = entries.map(row => row.reason ? `${row.label} ${row.reason}` : row.label);
  return fit(`unavailable ${entries.length}  ${bits.join(sep)}`, width).trimEnd();
}

export function metrics(width) {
  const wide = width >= 100;
  return { wide, label: wide ? 13 : 12, left: 18, pace: 11, reset: 6, ident: wide ? 11 : 0, gap: 2 };
}

export function row(cols, width, gap = 2) {
  const spacer = ' '.repeat(gap);
  let used = 0, out = '';
  for (let i = 0; i < cols.length; i++) {
    if (i) { out += spacer; used += gap; }
    const last = i === cols.length - 1;
    const w = last ? Math.max(0, width - used) : cols[i].width;
    out += fit(cols[i].text, w, cols[i].align || 'left');
    used += w;
  }
  return out.slice(0, width);
}

export function bandInk(value) {
  const n = floorPercent(value);
  return n === null ? 2 : n < 25 ? 5 : n < 50 ? 3 : 4;
}

export function paceInk(status) {
  const word = paceWord(status);
  return word === 'HOT' ? 5 : word === 'UNDER' ? 4 : word === '?' ? 2 : 0;
}
