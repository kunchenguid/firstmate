// Coordinates are terminal cells. Trusted sprites must use single-cell glyphs.
export const clean = value => String(value ?? '').replace(/[^\x20-\x7e]/g, '?');
export const palette = [39, 141, 245, 222, 115, 174];
export function buffer(width, height) {
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 2 || width > 300 || height < 1 || height > 1000) throw Error('Invalid viewport');
  return Array.from({ length: height }, () => Array.from({ length: width }, () => [' ', 0]));
}
export function put(grid, x, y, text, ink = 0) {
  if (!Number.isInteger(x) || !Number.isInteger(y) || !Number.isInteger(ink) || ink < 0 || ink >= palette.length) throw Error('Invalid cell position or ink');
  [...text].forEach((ch, i) => { if (grid[y]?.[x + i] && x + i < grid[y].length - 1) grid[y][x + i] = [ch, ink]; });
}
// Sprite assets are arrays of rows, not executable loaders or copied artwork.
export const sprite = (grid, x, y, rows, ink = 0) => rows.forEach((row, i) => put(grid, x, y + i, row, ink));
export const ticker = (items, tick, dwell = 40) => items.length ? items[Math.floor(Math.max(0, tick) / Math.max(1, dwell)) % items.length] : '';
export const plain = grid => grid.map(row => row.map(cell => cell[0]).join('').trimEnd()).join('\n') + '\n';
export function diff(before, after, color = true) {
  let output = '';
  for (let y = 0; y < after.length; y++) {
    for (let x = 0; x < after[y].length - 1; x++) {
      const [ch, ink] = after[y][x], old = before?.[y]?.[x];
      if (old?.[0] === ch && old?.[1] === ink) continue;
      output += `\x1b[${y + 1};${x + 1}H` + (color ? `\x1b[${ink ? `38;5;${palette[ink]}` : '39'}m` : '') + ch;
      while (x + 1 < after[y].length - 1 && after[y][x + 1][1] === ink &&
        (before?.[y]?.[x + 1]?.[0] !== after[y][x + 1][0] || before?.[y]?.[x + 1]?.[1] !== ink)) output += after[y][++x][0];
    }
  }
  return output ? output + (color ? '\x1b[0m' : '') : '';
}
