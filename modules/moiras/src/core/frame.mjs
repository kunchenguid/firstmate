import { buffer, put as cell, sprite, ticker } from '../../../fm-tui-core/src/index.mjs';
import { safe } from '../../../fm-state-reader/src/index.mjs';
import { digest } from './findings.mjs';
// Original approved silhouettes: robust half/full blocks, fixed robe texture, six shared inks.
const shapes = [
  ['    ▄████▄', '  ▄██▀   ▀█', ' ██       ▄▀', '▄███▄   ▄█▀', '█████▀▀██▄', '██▓▓████▓██▄▄', ' ▀██▓▓▓▓▓██▀', ' ▄██████████▄'],
  ['     ▄██▄', '   ▄██▀ ▀█', '  ██      ▄▀', ' ▄██▄   ▄█▀', ' ██▓██▀██', ' ██▓▓█▓▓█▄▄', ' ██▓▓█▓▓██', '▄███▓█▓████▄'],
  ['   ▄████▄', ' ▄██▀   ▀█', '██        ▄▀', '███▄    ▄█▀', ' ▀███▀▀██▄', ' ▄█▓▓██▓▓██▄', ' ██▓▓▓██▓▓██', '▄████████████▄'],
];
export function frame(data, elapsed = 0, width = 100, height = 30) {
  const grid = buffer(width, height), put = (x, y, text, ink = 0) => cell(grid, x, y, text, ink);
  const line = (y, text, ink = 0) => put(2, y, safe(text), ink);
  const workers = data.workers ?? [], findings = data.findings ?? [], art = width >= 76 && height >= 24;
  const time = Math.max(0, elapsed), ageOffset = Number.isFinite(data.now) && Number.isFinite(data.renderNow) ? Math.max(0, data.renderNow - data.now) : 0;
  line(0, `MOIRAS   ${data.demo ? 'DEMONSTRATION' : 'OBSERVE ONLY'}   ${workers.length} ${workers.length === 1 ? 'thread' : 'threads'}   ${findings.length} ${findings.length === 1 ? 'finding' : 'findings'}`, 3);
  if (art) {
    const centers = [Math.floor(width / 6), Math.floor(width / 2), Math.floor(width * 5 / 6)];
    shapes.forEach((rows, i) => sprite(grid, centers[i] - 7, 4, rows, 1));
    // Six seconds still, two seconds easing to the next holder; no perpetual motion.
    const holder = Math.floor(time / 8000) % 3, phase = time % 8000;
    const t = Math.max(0, (phase - 6000) / 2000), eased = (1 - Math.cos(Math.PI * t)) / 2;
    centers.forEach(c => put(c - 1, 6, '─', 2));
    const eyeX = Math.round(centers[holder] + (centers[(holder + 1) % 3] - centers[holder]) * eased) - 2;
    put(eyeX, 6 - Math.round(2 * Math.sin(Math.PI * t)), '(◉)', 3);
    // A one-second beat per four-second window survives the low-resource redraw cadence.
    const idle = phase < 6000 && time % 4000 >= 3000 ? parseInt(digest(`${data.idleSeed ?? 0}:${Math.floor(time / 4000)}`).slice(0, 8), 16) % 3 : -1;
    const sway = idle === 0 ? 1 : 0, tick = idle === 1 ? 1 : 0, blink = idle === 2;
    put(Math.max(3, centers[0] - 12) + sway, 9, '│', 3); put(Math.max(2, centers[0] - 13) + sway, 10, '╶┼╴', 3);
    put(centers[1] + 7, 8 + tick, '├', 4); put(centers[1] + 7, 9 + tick, '┤', 4); put(centers[1] + 7, 10 + tick, '├', 4);
    const raised = blink && findings.some(f => f.cut), sx = centers[2] + 8, sy = raised ? 7 : 9;
    put(sx, sy, blink ? '╳' : '╲╱', 5); put(sx, sy + 1, blink ? '╲╱' : '╳', 5); put(sx, sy + 2, '○ ○', 5);
    ['CLOTHO / spins', 'LACHESIS / measures', 'ATROPOS / proposes'].forEach((s, i) => put(centers[i] - Math.floor(s.length / 2), 13, s, 2));
    put(2, 15, '─'.repeat(width - 5), 2);
    if (raised) put(centers[2], 15, ' ╳ ', 5);
  }
  const start = art ? 17 : 2, room = Math.max(1, Math.floor((height - start - 5) / 2));
  const page = workers.length ? Math.floor(time / 16000) % Math.ceil(workers.length / room) : 0;
  if (!workers.length) line(start, 'No threads to measure. Even fate gets a quiet afternoon.', 2);
  workers.slice(page * room, (page + 1) * room).forEach((w, i) => {
    const age = Number.isFinite(w.age) ? Math.max(0, Math.floor((w.age + ageOffset) / 60)) : null, bars = age === null ? 0 : Math.min(8, Math.floor(age / 10));
    const warning = findings.some(f => f.rule === 'busy-but-silent' && f.task === w.id);
    if (warning) { put(2, start + i * 2, '⚠️', 5); put(6, start + i * 2, safe(`${w.id}  ${w.harness}/${w.model}  ${w.effort}  ${w.busy ?? 'unknown'}`)); }
    else line(start + i * 2, `${w.id}  ${w.harness}/${w.model}  ${w.effort}  ${w.busy ?? 'unknown'}`);
    put(2, start + i * 2 + 1, '━'.repeat(bars) + '┄'.repeat(8 - bars), 4);
    put(12, start + i * 2 + 1, safe(`${age === null ? '?' : age}m since status  ${w.last}`), 2);
  });
  const proposal = ticker(findings, time, 16000);
  line(height - 4, proposal ? `? ${String(proposal.id).slice(0, 8)}  ${proposal.rule}: ${proposal.task}` : 'No proposed cuts. The scissors remain a suggestion.', proposal ? 5 : 2);
  line(height - 3, proposal ? `default: ${proposal.default} | confirm only after checking current evidence` : '', 2);
  line(height - 2, ticker(data.facts ?? ['PRs, pool and beacon: unknown'], time, 16000), 4);
  line(height - 1, `ctrl+c exits | no task actions | ${page + 1}/${Math.max(1, Math.ceil(workers.length / room))} pages`, 2);
  return grid;
}
export function plainStatus(data) {
  return [`MOIRAS - ${data.demo ? 'DEMONSTRATION' : 'OBSERVE ONLY'}`,  ...(data.workers ?? []).map(w => `${w.id} ${w.harness}/${w.model} ${w.effort} ${w.busy}; ${Math.floor(w.age)}s since status; ${w.last}`),
    ...(data.findings ?? []).map(f => `${f.id} ${f.rule}: ${f.task}; default ${f.default}`), ...(data.facts ?? [])].map(safe).join('\n') + '\n';
}
