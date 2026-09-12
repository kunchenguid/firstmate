import { clean, buffer, put, diff } from '../../../fm-tui-core/src/index.mjs';
const pct = n => n === null ? '?' : `${Math.round(n)}%`;
const signed = n => n === null ? '?' : `${Math.round(n) >= 0 ? '+' : ''}${Math.round(n)}%`;
export function countdown(seconds) {
  if (seconds === null) return '?';
  if (seconds >= 86400) return `${Math.floor(seconds / 86400)}d${Math.floor(seconds % 86400 / 3600)}h`;
  return `${Math.floor(seconds / 3600)}h${Math.floor(seconds % 3600 / 60)}m`;
}
function gauge(value, size, ascii) {
  if (value === null) return '?'.repeat(size);
  const filled = Math.floor(value / 100 * size);
  return (ascii ? '#' : '▓').repeat(filled) + (ascii ? '-' : '░').repeat(size - filled);
}
const fit = (text, width) => text.length > width ? text.slice(0, width - 1) + '~' : text.padEnd(width);
const wrap = (text, width) => {
  const lines = [];
  for (let i = 0; i < text.length; i += width) lines.push(text.slice(i, i + width));
  return lines;
};
const span = (text, ink = 0) => ({ text, ink });
// Ink indices belong to the shared terminal palette: warm, cool, and muted metadata.
const tone = status => status === 'HOT' ? 3 : status === 'UNDER' ? 1 : 0;
function label(row) {
  const text = clean(row.label).toUpperCase();
  if (/SESSION|5H WINDOW/.test(text) && row.windowSeconds === 18000) return '5H SESSION';
  if (/ALL.MODELS/.test(text) && row.windowSeconds === 604800) return '7D ALL';
  if (/^WEEKLY (LIMIT|QUOTA)$/.test(text)) return 'WEEKLY';
  if (/^API (LIMIT|QUOTA)$/.test(text)) return 'API';
  return text;
}

function layout(frame, { width = 100, clean: ascii = false } = {}) {
  const cell = Math.min(32, width);
  const columns = Math.max(1, Math.floor((width + 2) / 34));
  const cards = frame.pools.map(pool => {
    const badge = `[${clean(pool.tags[0])}]`;
    const title = clean(pool.label.toUpperCase()) + (pool.plan ? ` ${ascii ? '/' : '·'} ${clean(pool.plan)}` : '');
    const rows = [
      [span(fit(title, Math.max(1, cell - badge.length - 1)) + ' '), span(badge, tone(pool.tags[0]))],
      [span(`${gauge(pool.remaining, 12, ascii)}  ${pct(pool.remaining)} LEFT`)],
      [span(fit(clean(pool.email || 'identity unknown'), cell), 2)],
    ];
    for (const row of pool.windows) {
      rows.push([span(`${fit(label(row), 11)} ${gauge(row.remaining, 8, ascii)} ${pct(row.remaining).padStart(4)} `),
        span(signed(row.delta).padStart(5), tone(row.status))]);
    }
    if (!pool.windows.length) rows.push([span('No quota limits available')]);
    for (const tag of pool.tags.slice(1)) rows.push(...wrap(clean(tag), cell).map(text => [span(text)]));
    if (pool.error) rows.push(...wrap(clean(pool.error), cell).map(text => [span(text)]));
    const resets = pool.windows.map(row => row.resetsIn).filter(n => n !== null);
    return { rows, reset: `[RESET ${countdown(resets.length ? Math.min(...resets) : null)}]` };
  });
  const lines = [];
  for (let i = 0; i < cards.length; i += columns) {
    const group = cards.slice(i, i + columns);
    const height = Math.max(...group.map(card => card.rows.length));
    for (let y = 0; y <= height; y++) {
      const line = [];
      for (const [index, card] of group.entries()) {
        if (index) line.push(span('  '));
        const row = y === height ? [span(card.reset.padEnd(cell, ascii ? '-' : '─'), 2)] : card.rows[y] || [];
        let used = 0;
        for (const part of row) {
          const text = part.text.slice(0, cell - used);
          line.push(span(text, part.ink)); used += text.length;
        }
        line.push(span(' '.repeat(cell - used)));
      }
      lines.push(line);
    }
    if (i + columns < cards.length) lines.push([]);
  }
  if (!cards.length) lines.push(...wrap('No quota pools configured or discovered.', width).map(text => [span(text)]));
  const c = frame.counts;
  const footer = `${frame.pools.length} pools | ${c.hot} over pace | ${c.unavailable} unavailable | ${c.mismatch} identity mismatch | ${c.duplicate} duplicate`;
  lines.push(...wrap(footer, width).map(text => [span(text)]));
  lines.push(...wrap(`MARVIN | LEFT / +/- PACE | ${clean(frame.ts)}`, width).map(text => [span(text, 2)]));
  return lines;
}

function textFrame(lines, color) {
  const colors = { 1: 141, 2: 245, 3: 222 };
  return lines.map(line => {
    let remaining = line.map(part => part.text).join('').trimEnd().length;
    return line.map(({ text, ink }) => {
      text = text.slice(0, remaining); remaining -= text.length;
      return color && ink && text ? `\x1b[38;5;${colors[ink]}m${text}\x1b[0m` : text;
    }).join('');
  }).join('\n') + '\n';
}
export function renderFrame(frame, options = {}) {
  return textFrame(layout(frame, options), options.color && !options.clean);
}

export function terminalRenderer(output, options) {
  let previous, previousKey;
  return { render(frame) {
    const width = options.width();
    const lines = options.json ? null : layout(frame, { width, clean: options.clean });
    const text = options.json ? JSON.stringify(frame) + '\n' : textFrame(lines, false);
    const key = JSON.stringify([width, frame.pools, frame.counts]);
    if (options.watch && output.tty && !options.clean && !options.json) {
      if (key !== previousKey) {
        const grid = buffer(width + 1, lines.length);
        lines.forEach((line, y) => {
          let x = 0;
          for (const { text, ink } of line) { put(grid, x, y, text, ink); x += text.length; }
        });
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
      lines.push(clean(`${record.ts} ${pool.id}/${row.id} ${pct(row.remaining)} ideal ${pct(row.idealPercent)} ${signed(row.delta)} ${row.status}`));
    }
  }
  if (lines.length === 1) lines.push('No samples in the last 7 days. Run status or watch to record quota.');
  return lines.join('\n') + '\n';
}
