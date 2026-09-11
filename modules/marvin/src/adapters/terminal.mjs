import { clean, buffer, put, diff } from '../../../fm-tui-core/src/index.mjs';
const pct = n => n === null ? '?' : `${Math.round(n)}%`;
const signed = n => n === null ? '?' : `${n >= 0 ? '+' : ''}${Math.round(n)}%`;
export function countdown(seconds) {
  if (seconds === null) return '?';
  if (seconds >= 86400) return `${Math.floor(seconds / 86400)}d${Math.floor(seconds % 86400 / 3600)}h`;
  return `${Math.floor(seconds / 3600)}h${Math.floor(seconds % 3600 / 60)}m`;
}
function gauge(value, size, ascii) {
  if (value === null) return '?'.repeat(size);
  const filled = Math.floor(value / 100 * size);
  return (ascii ? '#' : '▓').repeat(filled) + (ascii ? '-' : '▒').repeat(filled < size && value > 0 ? 1 : 0) +
    (ascii ? '-' : '░').repeat(Math.max(0, size - filled - (filled < size && value > 0 ? 1 : 0)));
}
const fit = (text, width) => [...text].length > width ? [...text].slice(0, width - 1).join('') + '~' : text.padEnd(width);
const wrap = (text, width) => {
  const lines = [];
  for (let i = 0; i < text.length; i += width) lines.push(text.slice(i, i + width));
  return lines;
};

export function renderFrame(frame, { width = 100, clean: ascii = false, color = false } = {}) {
  const columns = ascii ? 1 : Math.min(frame.pools.length || 1, width >= 100 ? Math.max(1, Math.floor(width / 16)) : Math.max(1, Math.floor(width / 26)));
  const cell = Math.floor((width - (columns - 1) * 2) / columns);
  const cards = frame.pools.map(pool => {
    const rows = [clean(`${pool.label.toUpperCase()} ${pool.plan || ''}${ascii ? ` ${pool.tags[0]}` : ''}`),
      ascii ? `${gauge(pool.remaining, 4, true)} ${pct(pool.remaining)} LEFT` :
        pool.remaining === null || pool.tags[0] === 'PACE UNKNOWN' ? pool.tags[0] : `${gauge(pool.remaining, 2, false)} ${pct(pool.remaining)} ${pool.tags[0]}`,
      clean(pool.email || 'identity unknown'), clean(pool.credentialSource || 'source unknown')];
    for (const row of pool.windows) {
      if (ascii) rows.push(clean(`${row.label}: ${pct(row.remaining)} LEFT | ideal ${pct(row.idealPercent)} | ${signed(row.delta)} PACE | RESETS IN ${countdown(row.resetsIn)}`));
      else {
        const duration = row.windowSeconds === 18000 ? '5H' : row.windowSeconds === 604800 ? '7D' : null;
        const label = /fable/i.test(row.label) ? 'FABLE' : duration && /session|week/i.test(row.label) ?
          `${row.id.startsWith('model:') ? 'M' : ''}${duration}` : clean(row.label);
        const metrics = `${gauge(row.remaining, 1, false)} ${pct(row.remaining)} ${signed(row.delta)}`;
        const reset = countdown(row.resetsIn);
        const suffix = width < 100 ? `${metrics} ${reset}` : metrics;
        rows.push(`${label.slice(0, Math.max(1, cell - suffix.length - 1))} ${suffix}`);
        if (width >= 100) rows.push(`ideal ${pct(row.idealPercent)} ${reset}`);
      }
    }
    const resets = pool.windows.map(row => row.resetsIn).filter(n => n !== null);
    rows.push(`RESETS IN ${countdown(resets.length ? Math.min(...resets) : null)}`);
    rows.push(...pool.tags.slice(1).flatMap(tag => ascii ? [tag] : wrap(tag, cell)));
    if (pool.error) rows.push(clean(pool.error));
    return rows;
  });
  const lines = ['MARVIN | LEFT / +/- PACE', clean(frame.ts)];
  for (let i = 0; i < cards.length; i += columns) {
    const group = cards.slice(i, i + columns);
    for (let row = 0; row < Math.max(...group.map(card => card.length)); row++) {
      lines.push(group.map(card => ascii ? (card[row] || '') : fit(card[row] || '', cell)).join('  ').trimEnd());
    }
    if (ascii || width >= 100 || i + columns < cards.length) lines.push('');
  }
  if (!cards.length) lines.push('No quota pools configured or discovered.');
  const c = frame.counts;
  const footer = `${c.agents} agents, ${c.accounts} accounts, ${c.hot} over pace, ${c.unavailable} unavailable, ${c.mismatch} identity mismatch, ${c.duplicate} duplicate, ideal pace now`;
  lines.push(...(ascii ? [footer] : wrap(footer, width)));
  const output = lines.join('\n') + '\n';
  return color && !ascii ? output.replaceAll('HOT', '\x1b[38;5;215mHOT\x1b[0m') : output;
}

export function terminalRenderer(output, options) {
  let previous, previousKey;
  return { render(frame) {
    const width = options.width();
    const text = options.json ? JSON.stringify(frame) + '\n' : renderFrame(frame, { width, clean: options.clean });
    const key = JSON.stringify([width, frame.pools, frame.counts]);
    if (options.watch && output.tty && !options.clean && !options.json) {
      if (key !== previousKey) {
        const lines = text.trimEnd().split('\n');
        const grid = buffer(width + 1, lines.length);
        lines.forEach((line, y) => {
          put(grid, 0, y, line);
          for (const match of line.matchAll(/HOT/g)) put(grid, match.index, y, 'HOT', 3);
        });
        if (!previous || previous.length !== grid.length || previous[0].length !== grid[0].length) {
          output.write('\x1b[H\x1b[2J'); previous = null;
        }
        output.write(diff(previous, grid, output.color));
        previous = grid;
      }
    } else output.write(!options.json && output.color && !options.clean ? text.replaceAll('HOT', '\x1b[38;5;215mHOT\x1b[0m') : text);
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
