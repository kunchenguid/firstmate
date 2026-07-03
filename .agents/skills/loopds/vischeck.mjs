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

import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { resolve } from 'node:path'
import { inflateSync } from 'node:zlib'

export const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

// ────────────────────────── 纯函数(确定性可测,判决全在这里) ──────────────────────────

// 解析 `sips -g pixelWidth -g pixelHeight <img>` 的输出 → {width,height}
export function parseSipsDims(out) {
  const w = /pixelWidth:\s*(\d+)/.exec(out)
  const h = /pixelHeight:\s*(\d+)/.exec(out)
  return { width: w ? +w[1] : 0, height: h ? +h[1] : 0 }
}

export function pngPixelStats(input) {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(input)
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  if (buf.length < sig.length || !buf.subarray(0, sig.length).equals(sig)) throw new Error('not-png')

  let offset = sig.length
  let width = 0
  let height = 0
  let bitDepth = 0
  let colorType = 0
  const idats = []

  while (offset + 8 <= buf.length) {
    const chunkLen = buf.readUInt32BE(offset)
    offset += 4
    const type = buf.toString('ascii', offset, offset + 4)
    offset += 4
    const dataStart = offset
    const dataEnd = offset + chunkLen
    if (dataEnd + 4 > buf.length) throw new Error('truncated-png')
    const data = buf.subarray(dataStart, dataEnd)
    offset = dataEnd + 4
    if (type === 'IHDR') {
      width = data.readUInt32BE(0)
      height = data.readUInt32BE(4)
      bitDepth = data[8]
      colorType = data[9]
    } else if (type === 'IDAT') {
      idats.push(data)
    } else if (type === 'IEND') {
      break
    }
  }

  const channelsByType = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }
  const channels = channelsByType[colorType]
  if (!(width > 0 && height > 0 && bitDepth === 8 && channels)) throw new Error('unsupported-png-format')
  if (idats.length === 0) throw new Error('png-missing-idat')

  const data = inflateSync(Buffer.concat(idats))
  const rowBytes = width * channels
  if (data.length < (rowBytes + 1) * height) throw new Error('truncated-png-data')

  let pos = 0
  let prev = Buffer.alloc(rowBytes)
  let row = Buffer.alloc(rowBytes)
  let minR = 255, minG = 255, minB = 255, minA = 255
  let maxR = 0, maxG = 0, maxB = 0, maxA = 0
  const distinct = new Set()
  let pixels = 0

  for (let y = 0; y < height; y++) {
    const filter = data[pos++]
    for (let i = 0; i < rowBytes; i++) {
      const raw = data[pos++]
      const left = i >= channels ? row[i - channels] : 0
      const up = prev[i]
      const upLeft = i >= channels ? prev[i - channels] : 0
      let pred = 0
      if (filter === 1) pred = left
      else if (filter === 2) pred = up
      else if (filter === 3) pred = Math.floor((left + up) / 2)
      else if (filter === 4) {
        const p = left + up - upLeft
        const pa = Math.abs(p - left)
        const pb = Math.abs(p - up)
        const pc = Math.abs(p - upLeft)
        pred = pa <= pb && pa <= pc ? left : (pb <= pc ? up : upLeft)
      } else if (filter !== 0) {
        throw new Error('unsupported-png-filter')
      }
      row[i] = (raw + pred) & 255
    }

    for (let i = 0; i < rowBytes; i += channels) {
      let r, g, b, a
      if (colorType === 0) {
        r = g = b = row[i]; a = 255
      } else if (colorType === 2) {
        r = row[i]; g = row[i + 1]; b = row[i + 2]; a = 255
      } else if (colorType === 3) {
        r = g = b = row[i]; a = 255
      } else if (colorType === 4) {
        r = g = b = row[i]; a = row[i + 1]
      } else {
        r = row[i]; g = row[i + 1]; b = row[i + 2]; a = row[i + 3]
      }
      if (r < minR) minR = r; if (g < minG) minG = g; if (b < minB) minB = b; if (a < minA) minA = a
      if (r > maxR) maxR = r; if (g > maxG) maxG = g; if (b > maxB) maxB = b; if (a > maxA) maxA = a
      if (distinct.size < 257) distinct.add(r + ',' + g + ',' + b + ',' + a)
      pixels++
    }

    const tmp = prev
    prev = row
    row = tmp
  }

  return {
    ok: true,
    width,
    height,
    bitDepth,
    colorType,
    pixels,
    distinctColors: distinct.size,
    channelRange: Math.max(maxR - minR, maxG - minG, maxB - minB, maxA - minA)
  }
}

export function nonblankVerdict({ width, height, bytes, pixelStats }, minBytes = 1024) {
  const base = { width, height, bytes, minBytes }
  if (!(width > 0 && height > 0)) return { ...base, pass: false, reason: 'empty-dimensions' }
  if (!(bytes >= minBytes)) return { ...base, pass: false, reason: 'below-byte-floor' }
  if (!pixelStats || pixelStats.ok !== true) {
    return { ...base, pass: false, reason: pixelStats?.reason || 'missing-pixel-stats', pixelStats }
  }
  const pixelSamples = pixelStats.pixels || 0
  const distinctColors = pixelStats.distinctColors || 0
  const channelRange = pixelStats.channelRange || 0
  const pass = pixelSamples > 0 && distinctColors > 1 && channelRange > 0
  return { ...base, pass, pixelSamples, distinctColors, channelRange, reason: pass ? undefined : 'flat-pixels' }
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
  const m = /^(\d+(?:\.\d+)?)(?:\s+\(\d+(?:\.\d+)?\))?$/.exec(String(text || '').trim())
  if (!m) throw new Error('invalid-ae-metric')
  return Math.round(parseFloat(m[1]))
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
  let pixelStats
  try { pixelStats = pngPixelStats(readFileSync(img)) }
  catch (e) { pixelStats = { ok: false, reason: e.message } }
  const v = nonblankVerdict({ ...dims, bytes, pixelStats }, minBytes ? +minBytes : 1024)
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
  const r = spawnSync(bin, argv, { encoding: 'utf8' })
  const out = String(r.stderr || r.stdout || '').trim()
  if (r.error || (r.status !== 0 && r.status !== 1)) {
    console.error('像素 diff 命令失败:' + (r.error?.message || out || 'exit ' + r.status))
    process.exit(2)
  }
  let ae
  try { ae = parseAE(out) }
  catch {
    console.error('像素 diff 未产出有效 AE 指标:' + (out || 'empty output'))
    process.exit(2)
  }
  const sips = execFileSync('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', a], { encoding: 'utf8' })
  const { width, height } = parseSipsDims(sips)
  const v = diffVerdict(ae, width * height, parseFloat(threshold))
  console.log(JSON.stringify(v))
  process.exit(v.pass ? 0 : 1)
}

// ────────────────────────── CLI 分发(import 时不跑) ──────────────────────────

export function parseFlags(rest) {
  const o = { includes: [], excludes: [], minCount: {} }
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === '--inc') {
      const value = rest[++i]
      if (value === undefined || value.startsWith('--')) throw new Error('--inc requires a value')
      o.includes.push(value)
    } else if (rest[i] === '--exc') {
      const value = rest[++i]
      if (value === undefined || value.startsWith('--')) throw new Error('--exc requires a value')
      o.excludes.push(value)
    } else if (rest[i] === '--min') {
      const spec = rest[++i]
      if (spec === undefined || spec.startsWith('--')) throw new Error('--min requires selector=count')
      const eq = spec.lastIndexOf('=')
      if (eq <= 0 || eq === spec.length - 1) throw new Error('--min requires selector=count')
      const s = spec.slice(0, eq)
      const n = spec.slice(eq + 1)
      if (!/^\d+$/.test(n)) throw new Error('--min count must be a non-negative integer: ' + spec)
      o.minCount[s] = Number(n)
    } else {
      throw new Error('unknown flag: ' + rest[i])
    }
  }
  return o
}

const isMain = import.meta.url === ('file://' + process.argv[1])
if (isMain) {
  const [cmd, ...rest] = process.argv.slice(2)
  if (cmd === 'render') render(rest[0], rest[1], rest[2], rest[3])
  else if (cmd === 'dom') dumpDom(rest[0])
  else if (cmd === 'nonblank') nonblank(rest[0], rest[1])
  else if (cmd === 'domcheck') {
    let flags
    try { flags = parseFlags(rest.slice(1)) }
    catch (e) { console.error(e.message); process.exit(2) }
    domcheck(rest[0], flags)
  }
  else if (cmd === 'diff') diff(rest[0], rest[1], rest[2])
  else { console.error('用法: render|dom|nonblank|domcheck|diff  (详见文件头注释)'); process.exit(2) }
}
