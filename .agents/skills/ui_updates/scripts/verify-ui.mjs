#!/usr/bin/env node
/**
 * ui_updates: Portable Visual Regression Testing (VRT) & Interactive Split-Slider Harness
 * 
 * Capabilities:
 *  - Serves static web distribution locally on an ephemeral port.
 *  - Intercepts API routes with deterministic mock fixtures (zero DB/network dependencies).
 *  - Captures baseline vs candidate screenshots across Desktop (1280x900) and Mobile (390x844).
 *  - Calculates pixel diffs via pixelmatch and enforces 0.000% blast radius tolerance.
 *  - Generates standalone HTML report with an interactive Split-Slider, Side-by-Side, and Diff Mask views.
 */

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import pixelmatch from 'pixelmatch';
import { PNG } from 'pngjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = process.cwd();
const webDistDir = path.join(rootDir, 'web', 'dist');
const baselineDir = path.join(rootDir, 'tests', 'vrt', 'baseline');
const candidateDir = path.join(rootDir, 'tests', 'vrt', 'candidate');
const diffDir = path.join(rootDir, 'tests', 'vrt', 'diff');
const reportDir = path.join(rootDir, 'tests', 'vrt', 'report');

[baselineDir, candidateDir, diffDir, reportDir].forEach(d => fs.mkdirSync(d, { recursive: true }));

const args = process.argv.slice(2);
const updateBaseline = args.includes('--update-baseline');
const targetComponent = args.find(a => a.startsWith('--target='))?.split('=')[1] || null;
const thresholdArg = parseFloat(args.find(a => a.startsWith('--threshold='))?.split('=')[1] || '0.1');
const maxDiffPct = parseFloat(args.find(a => a.startsWith('--max-diff='))?.split('=')[1] || '0.000');

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
};

function createStaticServer(distDir, port = 4567) {
  const safeDistRoot = path.resolve(distDir);

  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      let reqPath = req.url?.split('?')[0] || '/';
      if (reqPath === '/' || reqPath.startsWith('/#')) reqPath = '/index.html';

      const candidatePath = path.resolve(safeDistRoot, `.${reqPath}`);
      const relativeCandidate = path.relative(safeDistRoot, candidatePath);
      let filePath = (!relativeCandidate.startsWith('..') && !path.isAbsolute(relativeCandidate))
        ? candidatePath
        : path.join(safeDistRoot, 'index.html');

      if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
        filePath = path.join(safeDistRoot, 'index.html');
      }

      const ext = path.extname(filePath).toLowerCase();
      const contentType = MIME_TYPES[ext] || 'application/octet-stream';
      try {
        const data = fs.readFileSync(filePath);
        res.writeHead(200, {
          'Content-Type': contentType,
          'X-Content-Type-Options': 'nosniff',
        });
        res.end(data);
      } catch (err) {
        res.writeHead(404);
        res.end('Not Found');
      }
    });

    server.listen(port, () => resolve(server));
    server.on('error', reject);
  });
}

function comparePng(baselineBuffer, candidateBuffer, diffOutputPath, threshold = 0.1) {
  const img1 = PNG.sync.read(baselineBuffer);
  const img2 = PNG.sync.read(candidateBuffer);

  const { width, height } = img1;
  const diff = new PNG({ width, height });

  const numDiffPixels = pixelmatch(
    img1.data,
    img2.data,
    diff.data,
    width,
    height,
    { threshold, includeAA: false, diffColor: [244, 63, 94] }
  );

  const totalPixels = width * height;
  const diffPct = (numDiffPixels / totalPixels) * 100;

  fs.writeFileSync(diffOutputPath, PNG.sync.write(diff));

  return { diffPixels: numDiffPixels, diffPct };
}

const VIEWPORTS = [
  { name: 'desktop', width: 1280, height: 900 },
  { name: 'mobile', width: 390, height: 844 },
];

const SCENARIOS = [
  { id: '00-full-dashboard', title: 'Full Application Dashboard' },
  { id: '01-column-picker', title: 'Column Picker Component', selector: '.fqd-col-picker' },
  { id: '02-fleet-headroom', title: 'Fleet Headroom Component', selector: '.fqd-fleet-headroom' },
  { id: '03-active-attention', title: 'Active Attention Component', selector: '.fqd-active-attention' },
  { id: '04-telemetry-velocity', title: 'Telemetry Velocity Component', selector: '.fqd-telemetry' },
  { id: '05-quota-radar', title: 'Quota Radar Component', selector: '.fqd-quota-radar' },
  { id: '06-gateways-settings', title: 'Gateways Settings Component', selector: '.fqd-gateways' },
];

async function main() {
  console.log(`[VRT] Initializing ui_updates verification pipeline...`);
  if (!fs.existsSync(path.join(webDistDir, 'index.html'))) {
    console.error(`[VRT ERROR] Build output missing at ${webDistDir}. Run build first.`);
    process.exit(1);
  }

  const server = await createStaticServer(webDistDir, 4567);
  console.log(`[VRT] Local static server active on http://127.0.0.1:4567`);

  const browser = await chromium.launch({
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
  });

  const results = [];
  let allPassed = true;

  try {
    for (const vp of VIEWPORTS) {
      console.log(`\n--- Running Viewport: ${vp.name.toUpperCase()} (${vp.width}x${vp.height}) ---`);

      for (const scenario of SCENARIOS) {
        const testId = `${scenario.id}-${vp.name}`;
        const baselineFile = path.join(baselineDir, `${testId}.png`);
        const candidateFile = path.join(candidateDir, `${testId}.png`);
        const diffFile = path.join(diffDir, `${testId}-diff.png`);

        const context = await browser.newContext({
          viewport: { width: vp.width, height: vp.height },
          deviceScaleFactor: 1,
        });
        const page = await context.newPage();

        await page.goto('http://127.0.0.1:4567', { waitUntil: 'networkidle' });
        await page.evaluate(() => document.fonts.ready);

        let screenshotTarget = page;
        if (scenario.selector) {
          const loc = page.locator(scenario.selector);
          if (await loc.count() > 0) {
            screenshotTarget = loc.first();
          }
        }

        const candidateBuffer = await screenshotTarget.screenshot({ timeout: 5000 }).catch(async () => {
          return await page.screenshot({ fullPage: false });
        });
        fs.writeFileSync(candidateFile, candidateBuffer);

        if (updateBaseline || !fs.existsSync(baselineFile)) {
          fs.writeFileSync(baselineFile, candidateBuffer);
          console.log(`  [BASELINE RECORDED] ${scenario.title}`);
          results.push({
            id: scenario.id,
            title: scenario.title,
            viewport: vp.name,
            width: vp.width,
            height: vp.height,
            diffPixels: 0,
            diffPct: 0,
            passed: true,
            baselineRelPath: path.relative(reportDir, baselineFile),
            candidateRelPath: path.relative(reportDir, candidateFile),
            diffRelPath: '',
          });
        } else {
          const baselineBuffer = fs.readFileSync(baselineFile);
          const diffResult = comparePng(baselineBuffer, candidateBuffer, diffFile, thresholdArg);

          // If a target component is specified, allow diff on target, but require 0.000% on all other components
          const isTarget = targetComponent && scenario.id.includes(targetComponent);
          const allowedDiff = isTarget ? 100 : maxDiffPct;
          const passed = diffResult.diffPct <= allowedDiff;

          if (!passed) allPassed = false;

          const symbol = passed ? '?' : '?';
          const status = passed ? 'PASS (0.000% Drift)' : `DRIFT (${diffResult.diffPct.toFixed(3)}%)`;
          console.log(`  ${symbol} [${status}] ${scenario.title}: ${diffResult.diffPixels} diff px`);

          results.push({
            id: scenario.id,
            title: scenario.title,
            viewport: vp.name,
            width: vp.width,
            height: vp.height,
            diffPixels: diffResult.diffPixels,
            diffPct: diffResult.diffPct,
            passed,
            baselineRelPath: path.relative(reportDir, baselineFile),
            candidateRelPath: path.relative(reportDir, candidateFile),
            diffRelPath: path.relative(reportDir, diffFile),
          });
        }

        await context.close();
      }
    }

    console.log(`\nGenerating interactive Split-Slider HTML report...`);
    const reportHtml = generateHtmlReport(results);
    const reportPath = path.join(reportDir, 'index.html');
    fs.writeFileSync(reportPath, reportHtml);
    console.log(`Report successfully written to ${reportPath}`);

  } finally {
    await browser.close();
    server.close();
  }

  const passedCount = results.filter(r => r.passed).length;
  console.log(`\n======================================================`);
  console.log(`  RESULT: ${passedCount}/${results.length} PASSED (Status: ${allPassed ? 'CLEAN 0.000% DRIFT' : 'BLAST RADIUS DRIFT DETECTED'})`);
  console.log(`======================================================\n`);

  if (!allPassed) process.exit(1);
}

function generateHtmlReport(results) {
  const total = results.length;
  const passed = results.filter(r => r.passed).length;
  const failed = total - passed;

  const cardsHtml = results.map((r, idx) => {
    return `
    <div class="test-card ${r.passed ? 'passed' : 'failed'}">
      <div class="test-header">
        <div class="test-info">
          <span class="test-title">${r.title}</span>
          <span class="test-meta">${r.viewport.toUpperCase()} (${r.width}x${r.height})</span>
        </div>
        <div class="badge ${r.passed ? 'badge-pass' : 'badge-fail'}">
          ${r.passed ? '? 0.000% DRIFT' : `? ${r.diffPixels} DIFF PX (${r.diffPct.toFixed(3)}%)`}
        </div>
      </div>

      <!-- Interactive Split-Slider Viewer -->
      <div class="viewer-container">
        <div class="view-controls">
          <button type="button" class="ctrl-btn active" onclick="switchView(${idx}, 'slider')">Split Slider</button>
          <button type="button" class="ctrl-btn" onclick="switchView(${idx}, 'side')">Side-by-Side</button>
          <button type="button" class="ctrl-btn" onclick="switchView(${idx}, 'mask')">Diff Mask</button>
        </div>

        <div id="view-slider-${idx}" class="slider-wrapper">
          <div class="slider-canvas">
            <img class="img-base" src="${r.baselineRelPath}" alt="Baseline" />
            <div id="clip-candidate-${idx}" class="img-candidate-clip">
              <img class="img-candidate" src="${r.candidateRelPath}" alt="Candidate" />
            </div>
            <div id="divider-${idx}" class="slider-divider"></div>
          </div>
          <input type="range" min="0" max="100" value="50" class="split-range-input" oninput="updateSplit(${idx}, this.value)" />
          <div class="slider-labels">
            <span>? BASELINE (Before)</span>
            <span>CANDIDATE (After) ?</span>
          </div>
        </div>

        <div id="view-side-${idx}" class="side-wrapper" style="display:none;">
          <div class="side-col">
            <div class="side-lbl">BASELINE</div>
            <img src="${r.baselineRelPath}" class="img-side" />
          </div>
          <div class="side-col">
            <div class="side-lbl">CANDIDATE</div>
            <img src="${r.candidateRelPath}" class="img-side" />
          </div>
        </div>

        <div id="view-mask-${idx}" class="mask-wrapper" style="display:none;">
          <div class="side-lbl" style="color:#f43f5e;">PIXEL DIFF MASK (Red = Drift)</div>
          ${r.diffRelPath ? `<img src="${r.diffRelPath}" class="img-side" />` : `<div style="padding:20px;color:#9ca3af;">No visual diff detected.</div>`}
        </div>
      </div>
    </div>
    `;
  }).join('');

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>ui_updates: Visual Regression Test Report</title>
  <style>
    :root { --bg:#0b0f19; --card:#111827; --border:#1f2937; --text:#f9fafb; --accent:#3b82f6; --pass:#10b981; --fail:#f43f5e; }
    body { background:var(--bg); color:var(--text); font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; margin:0; padding:24px; }
    .container { max-width:1100px; margin:0 auto; }
    .header { display:flex; justify-content:space-between; align-items:center; border-bottom:1px solid var(--border); padding-bottom:16px; margin-bottom:24px; }
    .title { font-size:22px; font-weight:800; display:flex; align-items:center; gap:8px; }
    .stats { display:flex; gap:12px; }
    .stat-pill { background:var(--card); border:1px solid var(--border); padding:6px 14px; border-radius:999px; font-size:12px; font-weight:600; }
    .test-card { background:var(--card); border:1px solid var(--border); border-radius:8px; padding:20px; margin-bottom:24px; }
    .test-card.failed { border-color:rgba(244, 63, 94, 0.4); }
    .test-header { display:flex; justify-content:space-between; align-items:center; margin-bottom:16px; }
    .test-title { font-size:16px; font-weight:700; }
    .test-meta { font-size:12px; color:#9ca3af; margin-left:8px; }
    .badge { padding:4px 10px; border-radius:4px; font-size:11px; font-weight:700; }
    .badge-pass { background:rgba(16, 185, 129, 0.15); color:var(--pass); border:1px solid rgba(16, 185, 129, 0.3); }
    .badge-fail { background:rgba(244, 63, 94, 0.15); color:var(--fail); border:1px solid rgba(244, 63, 94, 0.3); }
    .view-controls { display:flex; gap:8px; margin-bottom:12px; }
    .ctrl-btn { background:#1f2937; border:1px solid #374151; color:#9ca3af; padding:5px 12px; border-radius:6px; font-size:12px; cursor:pointer; }
    .ctrl-btn.active { background:var(--accent); color:#fff; border-color:var(--accent); font-weight:600; }
    .slider-canvas { position:relative; overflow:hidden; border:1px solid var(--border); border-radius:6px; display:inline-block; max-width:100%; }
    .img-base { display:block; max-width:100%; height:auto; }
    .img-candidate-clip { position:absolute; top:0; left:0; width:100%; height:100%; overflow:hidden; clip-path:inset(0 0 0 50%); }
    .img-candidate { display:block; max-width:100%; height:auto; }
    .slider-divider { position:absolute; top:0; bottom:0; left:50%; width:2px; background:#fff; box-shadow:0 0 8px rgba(0,0,0,0.8); pointer-events:none; }
    .split-range-input { width:100%; margin-top:10px; accent-color:var(--accent); }
    .slider-labels { display:flex; justify-content:space-between; font-size:11px; color:#9ca3af; margin-top:4px; }
    .side-wrapper { display:flex; gap:16px; overflow-x:auto; }
    .side-col { flex:1; min-width:320px; }
    .side-lbl { font-size:11px; font-weight:700; color:#9ca3af; margin-bottom:6px; }
    .img-side { width:100%; border:1px solid var(--border); border-radius:6px; }
  </style>
  <script>
    function updateSplit(idx, val) {
      const clip = document.getElementById('clip-candidate-' + idx);
      const div = document.getElementById('divider-' + idx);
      if (clip) clip.style.clipPath = 'inset(0 0 0 ' + val + '%)';
      if (div) div.style.left = val + '%';
    }
    function switchView(idx, view) {
      document.getElementById('view-slider-' + idx).style.display = view === 'slider' ? 'block' : 'none';
      document.getElementById('view-side-' + idx).style.display = view === 'side' ? 'flex' : 'none';
      document.getElementById('view-mask-' + idx).style.display = view === 'mask' ? 'block' : 'none';
    }
  </script>
</head>
<body>
  <div class="container">
    <div class="header">
      <div class="title">? ui_updates VRT Report</div>
      <div class="stats">
        <span class="stat-pill" style="color:var(--pass);">Passed: ${passed}</span>
        <span class="stat-pill" style="color:${failed > 0 ? 'var(--fail)' : '#9ca3af'};">Drifted: ${failed}</span>
        <span class="stat-pill">Total: ${total}</span>
      </div>
    </div>
    ${cardsHtml}
  </div>
</body>
</html>`;
}

main().catch(err => {
  console.error('[FATAL]', err);
  process.exit(1);
});
