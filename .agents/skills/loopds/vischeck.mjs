// vischeck.mjs —— loopds 视觉/执行第0档(macOS 原生,无需 npm / 无需联网)
//
// 心法(与 SKILL.md 支柱① 一致):render/run 产物 → 截图 / 取 DOM → 由【代码】判
//   像素 diff / 结构断言 / 非空。**绝不让模型看自己的截图打分**——那是第2档自评,
//   正是 loopds 全力要避开的「模型当自己裁判」。这里所有判决都在确定性代码里。
//
// 依赖优先级(都不装第三方包):
//   - 渲染/取 DOM = 系统里已装的 Google Chrome --headless(零额外安装)
//   - 非空 / 尺寸  = macOS 自带 sips
//   - 像素 diff    = 可选 ImageMagick(magick/compare);没装就明确报、引导改用结构/OCR 档
//
// CLI:
//   node vischeck.mjs render   <url|htmlfile> <out.png> [w] [h]   # 截图,产出即 exit 0
//   node vischeck.mjs dom      <url|htmlfile>                      # 打印渲染后 DOM 到 stdout
//   node vischeck.mjs nonblank <img.png> [minBytes]               # 非空/有尺寸 → exit 0
//   node vischeck.mjs domcheck <url|htmlfile> --inc s --exc s --min "sel=3" ...  # 结构断言
//   node vischeck.mjs diff     <a.png> <b.png> <ratioThreshold>   # 像素 diff(需 ImageMagick)

import { execFileSync } from 'node:child_process'
import { existsSync, statSync } from 'node:fs'
import { resolve } from 'node:path'

export const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

// ────────────────────────── 纯函数(确定性可测,判决全在这里) ──────────────────────────

// 解析 `sips -g pixelWidth -g pixelHeight <img>` 的输出 → {width,height}
export function parseSipsDims(out) {
  const w = /pixelWidth:\s*(\d+)/.exec(out)
  const h = /pixelHeight:\s*(\d+)/.exec(out)
  return { width: w ? +w[1] : 0, height: h ? +h[1] : 0 }
}

// 非空判据:有真实尺寸 + 文件字节数超地板(渲染失败的白屏/空 PNG 通常极小)
export function nonblankVerdict({ width, height, bytes }, minBytes = 1024) {
  const pass = width > 0 && height > 0 && bytes >= minBytes
  return { pass, width, height, bytes, minBytes }
}

// 像素 diff 判据:不同像素占比 ≤ 阈值才过(threshold 是比例,如 0.02 = 2%)
export function diffVerdict(diffPixels, totalPixels, threshold) {
  if (!(totalPixels > 0)) return { pass: false, ratio: 1, reason: 'totalPixels<=0' }
  const ratio = diffPixels / totalPixels
  return { pass: ratio <= threshold, ratio, diffPixels, totalPixels, threshold }
}

// 结构断言:对 dump-dom 出来的 DOM 文本做代码级 yes/no(存在 / 计数 / 不含报错文本)
export function domAssert(dom, { includes = [], excludes = [], minCount = {} } = {}) {
  const fails = []
  for (const s of includes) if (dom.indexOf(s) === -1) fails.push('缺必含: ' + s)
  for (const s of excludes) if (dom.indexOf(s) !== -1) fails.push('出现禁现: ' + s)
  for (const [s, n] of Object.entries(minCount)) {
    const c = dom.split(s).length - 1
    if (c < n) fails.push('计数不足 「' + s + '」: ' + c + ' < ' + n)
  }
  return { pass: fails.length === 0, fails }
}

// 解析 magick/compare 的 AE 指标输出(可能在 stderr,可能带 " (0.0123)" 后缀)→ 整数像素数
export function parseAE(text) {
  const m = /(\d+(?:\.\d+)?)/.exec(String(text || '').trim())
  return m ? Math.round(parseFloat(m[1])) : 0
}

// ────────────────────────── I/O 包装(薄壳,只负责跑命令喂给上面的判决) ──────────────────────────

function toUrl(target) {
  if (/^(https?|file):/.test(target)) return target
  return 'file://' + resolve(target)
}

export function hasImageMagick() {
  for (const bin of ['magick', 'compare']) {
    try { execFileSync(bin, ['-version'], { stdio: 'ignore' }); return bin } catch { /* next */ }
  }
  return null
}

function render(target, out, w = '1200', h = '800') {
  execFileSync(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars',
    '--screenshot=' + resolve(out), '--window-size=' + w + ',' + h, toUrl(target)],
    { stdio: 'ignore', timeout: 60000 })
  if (!existsSync(out)) { console.error('render 失败:Chrome 没产出 ' + out); process.exit(1) }
  console.log('rendered ' + out + ' (' + statSync(out).size + ' B)')
}

function dumpDom(target) {
  const dom = execFileSync(CHROME, ['--headless=new', '--disable-gpu', '--dump-dom', toUrl(target)],
    { encoding: 'utf8', timeout: 60000, maxBuffer: 64 * 1024 * 1024 })
  process.stdout.write(dom)
}

function nonblank(img, minBytes) {
  const sips = execFileSync('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', img], { encoding: 'utf8' })
  const dims = parseSipsDims(sips)
  const bytes = existsSync(img) ? statSync(img).size : 0
  const v = nonblankVerdict({ ...dims, bytes }, minBytes ? +minBytes : 1024)
  console.log(JSON.stringify(v))
  process.exit(v.pass ? 0 : 1)
}

function domcheck(target, opts) {
  const dom = execFileSync(CHROME, ['--headless=new', '--disable-gpu', '--dump-dom', toUrl(target)],
    { encoding: 'utf8', timeout: 60000, maxBuffer: 64 * 1024 * 1024 })
  const v = domAssert(dom, opts)
  console.log(JSON.stringify(v))
  process.exit(v.pass ? 0 : 1)
}

function diff(a, b, threshold) {
  const bin = hasImageMagick()
  if (!bin) {
    console.error('像素 diff 需要 ImageMagick(brew install imagemagick)。没装就改用 domcheck 结构断言 / nonblank / OCR 这几档第0档。')
    process.exit(2)
  }
  const argv = bin === 'magick' ? ['compare', '-metric', 'AE', a, b, 'null:'] : ['-metric', 'AE', a, b, 'null:']
  let ae = 0
  try { const o = execFileSync(bin, argv, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }); ae = parseAE(o) }
  catch (e) { ae = parseAE(e.stderr || e.stdout || '0') }  // compare 在图不同时退出码非 0,AE 在 stderr
  const sips = execFileSync('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', a], { encoding: 'utf8' })
  const { width, height } = parseSipsDims(sips)
  const v = diffVerdict(ae, width * height, parseFloat(threshold))
  console.log(JSON.stringify(v))
  process.exit(v.pass ? 0 : 1)
}

// ────────────────────────── CLI 分发(import 时不跑) ──────────────────────────

function parseFlags(rest) {
  const o = { includes: [], excludes: [], minCount: {} }
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === '--inc') o.includes.push(rest[++i])
    else if (rest[i] === '--exc') o.excludes.push(rest[++i])
    else if (rest[i] === '--min') { const [s, n] = rest[++i].split('='); o.minCount[s] = +n }
  }
  return o
}

const isMain = import.meta.url === ('file://' + process.argv[1])
if (isMain) {
  const [cmd, ...rest] = process.argv.slice(2)
  if (cmd === 'render') render(rest[0], rest[1], rest[2], rest[3])
  else if (cmd === 'dom') dumpDom(rest[0])
  else if (cmd === 'nonblank') nonblank(rest[0], rest[1])
  else if (cmd === 'domcheck') domcheck(rest[0], parseFlags(rest.slice(1)))
  else if (cmd === 'diff') diff(rest[0], rest[1], rest[2])
  else { console.error('用法: render|dom|nonblank|domcheck|diff  (详见文件头注释)'); process.exit(2) }
}
