// vischeck.test.mjs —— 视觉/执行第0档的【判决逻辑】确定性自检
// 只测纯函数(parseSipsDims/pngPixelStats/nonblankVerdict/diffVerdict/domAssert/parseAE),
// 不依赖 Chrome/图片——判决在代码里就该能脱离 I/O 被验证。
// 渲染那半(Chrome 截图/dump-dom)是 I/O,由 SKILL.md 里的冒烟命令验,不进单测。

import { deflateSync } from 'node:zlib'
import { parseSipsDims, pngPixelStats, nonblankVerdict, diffVerdict, domAssert, parseAE, parseFlags } from './vischeck.mjs'

let pass = 0, fail = 0
function ok(name, cond) { if (cond) { pass++ } else { fail++; console.error('✗ ' + name) } }
function eq(name, a, b) { ok(name + ' (got ' + JSON.stringify(a) + ')', JSON.stringify(a) === JSON.stringify(b)) }
function throws(name, fn) {
  try { fn(); fail++; console.error('✗ ' + name) }
  catch { pass++ }
}

function pngChunk(type, data = Buffer.alloc(0)) {
  const len = Buffer.alloc(4)
  len.writeUInt32BE(data.length)
  return Buffer.concat([len, Buffer.from(type), data, Buffer.alloc(4)])
}

function rgbaPng(width, height, pixels) {
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8
  ihdr[9] = 6
  const rows = []
  for (let y = 0; y < height; y++) {
    rows.push(Buffer.from([0]))
    rows.push(Buffer.from(pixels.slice(y * width * 4, (y + 1) * width * 4)))
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', deflateSync(Buffer.concat(rows))),
    pngChunk('IEND')
  ])
}

// —— parseSipsDims ——
const sips = 'page.png\n  pixelWidth: 1200\n  pixelHeight: 800\n'
eq('sips 解析尺寸', parseSipsDims(sips), { width: 1200, height: 800 })
eq('sips 缺字段→0', parseSipsDims('garbage'), { width: 0, height: 0 })

// —— pngPixelStats / nonblankVerdict ——
const whitePng = rgbaPng(2, 1, [255, 255, 255, 255, 255, 255, 255, 255])
const mixedPng = rgbaPng(2, 1, [255, 255, 255, 255, 0, 0, 0, 255])
eq('PNG 纯白 distinct/range', pngPixelStats(whitePng).distinctColors + ':' + pngPixelStats(whitePng).channelRange, '1:0')
ok('PNG 黑白像素有范围', pngPixelStats(mixedPng).channelRange === 255)
ok('正常截图算非空', nonblankVerdict({ width: 1200, height: 800, bytes: 50000, pixelStats: pngPixelStats(mixedPng) }).pass === true)
ok('整页白屏算空', nonblankVerdict({ width: 1200, height: 800, bytes: 50000, pixelStats: pngPixelStats(whitePng) }).pass === false)
ok('零字节算空', nonblankVerdict({ width: 1200, height: 800, bytes: 0, pixelStats: pngPixelStats(mixedPng) }).pass === false)
ok('零尺寸算空', nonblankVerdict({ width: 0, height: 0, bytes: 50000, pixelStats: pngPixelStats(mixedPng) }).pass === false)
ok('字节低于地板算空(白屏兜底)', nonblankVerdict({ width: 1200, height: 800, bytes: 200, pixelStats: pngPixelStats(mixedPng) }, 1024).pass === false)

// —— diffVerdict(像素 diff 比例门)——
ok('完全一致 diff=0 过', diffVerdict(0, 960000, 0.02).pass === true)
ok('小于阈值过', diffVerdict(5000, 960000, 0.02).pass === true)        // ~0.52% ≤ 2%
ok('超过阈值不过', diffVerdict(50000, 960000, 0.02).pass === false)     // ~5.2% > 2%
ok('总像素 0 直接判失败(防除零)', diffVerdict(0, 0, 0.02).pass === false)
eq('比例算对', Math.round(diffVerdict(48000, 960000, 0.1).ratio * 100), 5)

// —— domAssert(结构断言:这才是视觉第0档的主力,不靠像素也能判对错)——
const dom = '<html><body><canvas id="plane"></canvas><div class="row"></div><div class="row"></div></body></html>'
ok('必含命中→过', domAssert(dom, { includes: ['<canvas', 'id="plane"'] }).pass === true)
ok('必含缺失→不过', domAssert(dom, { includes: ['id="missing"'] }).pass === false)
ok('禁现出现→不过(如报错文本)', domAssert('<div>Uncaught TypeError</div>', { excludes: ['Uncaught'] }).pass === false)
ok('计数达标→过', domAssert(dom, { minCount: { '<div class="row"': 2 } }).pass === true)
ok('计数不足→不过', domAssert(dom, { minCount: { '<div class="row"': 3 } }).pass === false)
ok('综合断言全过', domAssert(dom, { includes: ['<canvas'], excludes: ['Error'], minCount: { '<div': 2 } }).pass === true)
ok('失败时给出原因列表', domAssert(dom, { includes: ['x'] }).fails.length === 1)

// —— parseFlags(`--min selector=count`) ——
eq('inc/exc 解析成功', parseFlags(['--inc', '<canvas', '--exc', 'Error']), { includes: ['<canvas'], excludes: ['Error'], minCount: {} })
eq('min 按最后一个等号切 selector/count', parseFlags(['--min', '<div class="row"=3']).minCount, { '<div class="row"': 3 })
throws('min 缺 count 直接失败', () => parseFlags(['--min', '<div class="row"=']))
throws('min 非数字 count 直接失败', () => parseFlags(['--min', '<div class="row"=x']))
throws('inc 缺 value 直接失败', () => parseFlags(['--inc']))
throws('exc 缺 value 直接失败', () => parseFlags(['--exc', '--inc', '<canvas']))
throws('未知 flag 直接失败', () => parseFlags(['--incl', '<canvas']))

// —— parseAE(解析 ImageMagick AE 输出)——
eq('AE 纯数字', parseAE('48000'), 48000)
eq('AE 带括号比例后缀', parseAE('48000 (0.0521)'), 48000)
eq('AE 浮点四舍五入', parseAE('47999.6'), 48000)
throws('AE 空输出直接失败', () => parseAE(''))
throws('AE 工具错误输出直接失败', () => parseAE("compare: unable to open image 'missing.png': No such file or directory @ error/blob.c/OpenBlob/3596."))

console.log((fail === 0 ? '✓ ' : '✗ ') + pass + ' passed, ' + fail + ' failed')
process.exit(fail === 0 ? 0 : 1)
