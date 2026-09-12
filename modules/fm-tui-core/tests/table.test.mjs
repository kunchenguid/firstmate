import test from 'node:test';
import assert from 'node:assert/strict';
import {
  UNICODE, ASCII, glyphs, fit, label, left, pace, reset, header, footer,
  unavailable, metrics, row, bandMark, bandInk, paceInk, countdown, floorPercent,
} from '../src/core/table.mjs';

const bars = [
  [null, '··········    ? ??', '..........    ? ??'],
  [0,    '░░░░░░░░░░   0% !!', '----------   0% !!'],
  [0.4,  '░░░░░░░░░░   0% !!', '----------   0% !!'],
  [3,    '█░░░░░░░░░   3% !!', '#---------   3% !!'],
  [24.6, '██░░░░░░░░  24% !!', '##--------  24% !!'],
  [25,   '██░░░░░░░░  25% ! ', '##--------  25% ! '],
  [49.5, '█████░░░░░  49% ! ', '#####-----  49% ! '],
  [50,   '█████░░░░░  50%   ', '#####-----  50%   '],
  [71,   '███████░░░  71%   ', '#######---  71%   '],
  [96,   '█████████░  96%   ', '#########-  96%   '],
  [99.4, '█████████░  99%   ', '#########-  99%   '],
  [100,  '██████████ 100%   ', '########## 100%   '],
];

test('left bar matches the remaining-quota fixture in Unicode and ASCII', () => {
  for (const [value, uni, asc] of bars) {
    assert.equal(left(value).length, 18, value);
    assert.equal(left(value, UNICODE), uni, `unicode ${value}`);
    assert.equal(left(value, ASCII), asc, `ascii ${value}`);
    assert.equal(left(value, glyphs(true)), asc);
  }
  assert.equal(bandMark(24.6), '!!');
  assert.equal(bandMark(25), '! ');
  assert.equal(bandMark(50), '  ');
  assert.equal(floorPercent(24.6), 24);
});

test('pace word, signed points, and unknown delta stay eleven cells', () => {
  assert.equal(pace('HOT', -26), 'HOT   -26pt');
  assert.equal(pace('UNDER', 34), 'UNDER +34pt');
  assert.equal(pace('ON PACE', 0), 'EVEN   +0pt');
  assert.equal(pace('EVEN', 0.4), 'EVEN   +0pt');
  assert.equal(pace('PACE UNKNOWN', null), '?          ');
  assert.equal(pace('HOT', null), 'HOT        ');
  for (const text of [pace('HOT', -26), pace('UNDER', 34), pace('EVEN', 0), pace('?', null)]) {
    assert.equal(text.length, 11, text);
  }
});

test('reset is the binding-window countdown, right-aligned to six cells', () => {
  assert.equal(countdown(4 * 86400 + 2 * 3600), '4d02h');
  assert.equal(countdown(3 * 3600 + 43 * 60), '3h43m');
  assert.equal(reset(4 * 86400 + 2 * 3600), ' 4d02h');
  assert.equal(reset(null), '     ?');
  assert.equal(reset(1 * 86400 + 4 * 3600).length, 6);
});

test('fit truncates with ~; label widths follow the 100-column split', () => {
  assert.equal(fit('DUPLICATE ACCOUNT with CODEX #1', 24), 'DUPLICATE ACCOUNT with ~');
  assert.equal(label('CLAUDE max', 13), 'CLAUDE max   ');
  assert.equal(metrics(119).label, 13);
  assert.equal(metrics(79).label, 12);
  assert.equal(metrics(79).ident, 0);
  assert.equal(metrics(119).ident, 11);
});

test('header separates data age from next refresh; footer splits below 100', () => {
  const clock = 'data 00:36:12Z · age 12s · next 48s';
  const wide = header('MARVIN  quota left · pace', clock, 119);
  const narrow = header('MARVIN  quota left · pace', clock, 79);
  assert.equal(wide.length, 119);
  assert.equal(narrow.length, 79);
  assert.match(wide, /^MARVIN  quota left · pace/);
  assert.match(wide, /data 00:36:12Z · age 12s · next 48s$/);
  assert.doesNotMatch(wide + narrow, /\x1b/);
  const counts = { pools: 7, hot: 1, under: 1, even: 1, unknown: 1, unavailable: 3 };
  const legend = 'bar=left  !=<50%  !!=<25%  pt=vs ideal  Ctrl+C exit';
  const one = footer(counts, legend, 119);
  const two = footer(counts, legend, 79);
  assert.equal(one.length, 1);
  assert.equal(two.length, 2);
  assert.match(one[0], /pools 7  HOT 1  UNDER 1  EVEN 1  \? 1  unavailable 3/);
  assert.match(two[1], /bar=left/);
});

test('unavailable collapses to one line and is omitted when empty', () => {
  assert.equal(unavailable([], 79), '');
  const line = unavailable([
    { label: 'copilot', reason: 'STALE 14m' },
    { label: 'z.ai', reason: 'ERR read failed' },
    { label: 'antigravity', reason: 'no quota window' },
  ], 119);
  assert.match(line, /^unavailable 3  copilot STALE 14m · z\.ai ERR read failed · antigravity no quota window$/);
  const ascii = unavailable([{ label: 'z.ai', reason: 'ERR' }, { label: 'offline', reason: 'no window' }], 79, true);
  assert.match(ascii, /unavailable 2  z\.ai ERR \| offline no window/);
  assert.doesNotMatch(ascii, /[^\x20-\x7e]/);
});

test('ink helpers reinforce band and pace without being the only cue', () => {
  assert.equal(bandInk(10), 5);
  assert.equal(bandInk(25), 3);
  assert.equal(bandInk(50), 4);
  assert.equal(bandInk(null), 2);
  assert.equal(paceInk('HOT'), 5);
  assert.equal(paceInk('UNDER'), 4);
  assert.equal(paceInk('EVEN'), 0);
  assert.equal(paceInk('PACE UNKNOWN'), 2);
});

function sample(width, ascii) {
  const m = metrics(width);
  const set = glyphs(ascii);
  const sep = ascii ? ' / ' : ' · ';
  const clockSep = ascii ? '  ' : ' · ';
  const title = `MARVIN  quota left${sep}pace`;
  const clock = `data 00:36:12Z${clockSep}age 12s${clockSep}next 48s`;
  const cols = pool => {
    const cells = [
      { text: pool.label, width: m.label },
      { text: left(pool.left, set), width: 18 },
      { text: pace(pool.status, pool.delta), width: 11 },
      { text: reset(pool.reset), width: 6, align: 'right' },
    ];
    if (m.ident) cells.push({ text: pool.account, width: 11 });
    cells.push({ text: pool.note });
    return cells;
  };
  const heading = [
    { text: 'POOL', width: m.label },
    { text: 'LEFT', width: 18 },
    { text: 'PACE', width: 11 },
    { text: 'RESET', width: 6 },
  ];
  if (m.ident) heading.push({ text: 'ACCOUNT', width: 11 });
  heading.push({ text: 'NOTE' });
  const pools = [
    { label: 'CLAUDE max', left: 32, status: 'HOT', delta: -26, reset: 4 * 86400 + 2 * 3600, account: 'account-A', note: ascii ? '7d binds | fable 10% HOT -48pt' : '7d binds · fable 10% HOT -48pt' },
    { label: 'CODEX #2', left: 44, status: 'UNDER', delta: 34, reset: 2 * 86400 + 22 * 3600, account: 'account-B', note: 'DUPLICATE ACCOUNT with CODEX #1' },
    { label: 'CURSOR ultra', left: 71, status: 'EVEN', delta: 0, reset: 1 * 86400 + 4 * 3600, account: 'account-C', note: '' },
    { label: 'KIMI', left: 58, status: 'PACE UNKNOWN', delta: null, reset: 6 * 86400 + 11 * 3600, account: 'account-D', note: 'pace unknown: no window start' },
  ];
  const lines = [
    header(title, clock, width),
    row(heading, width),
    ...pools.map(pool => row(cols(pool), width).trimEnd()),
    unavailable([
      { label: 'copilot', reason: 'STALE 14m' },
      { label: 'z.ai', reason: ascii ? 'ERR' : 'ERR read failed' },
      { label: 'antigravity', reason: ascii ? 'no window' : 'no quota window' },
    ], width, ascii),
    ...footer({ pools: 7, hot: 1, under: 1, even: 1, unknown: 1, unavailable: 3 },
      'bar=left  !=<50%  !!=<25%  pt=vs ideal  Ctrl+C exit', width),
  ];
  return lines.map(line => line.trimEnd());
}

test('golden frames fit 80 and 120 columns in Unicode and ASCII', () => {
  for (const [term, ascii] of [[80, false], [120, false], [80, true]]) {
    const width = term - 1;
    const lines = sample(width, ascii);
    assert.ok(lines.length <= 15, lines.length);
    for (const line of lines) {
      assert.ok(line.length <= width, `${term} ${ascii ? 'ascii' : 'uni'} ${line.length} ${line}`);
    }
    const text = lines.join('\n');
    assert.match(text, /MARVIN  quota left/);
    assert.match(text, /data 00:36:12Z/);
    assert.match(text, /age 12s/);
    assert.match(text, /next 48s/);
    assert.match(text, /CLAUDE max/);
    assert.match(text, /32% !/);
    assert.match(text, /HOT   -26pt/);
    assert.match(text, /UNDER \+34pt/);
    assert.match(text, /EVEN   \+0pt/);
    assert.match(text, /pace unknown: no window/);
    assert.match(text, /unavailable 3/);
    assert.match(text, /DUPLICATE ACCOUNT/);
    assert.match(text, /bar=left/);
    assert.doesNotMatch(text, /\x1b/);
    if (ascii) {
      assert.doesNotMatch(text, /[^\x20-\x7e\n]/);
      assert.match(text, /###-------  32% !/);
    } else {
      assert.match(text, /███░░░░░░░  32% !/);
    }
    if (term === 120) assert.match(lines[1], /ACCOUNT/);
    if (term === 80) assert.doesNotMatch(lines[1], /ACCOUNT/);
    if (term === 80) assert.equal(lines.length, 9);
  }
});
