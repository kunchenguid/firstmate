#!/usr/bin/env bash
# Capture the real GitHub README before and after this branch. Candidate must be pushed.
set -euo pipefail
: "${DONE_DONE_EVIDENCE_ROOT:?run with done-done run readme-render}"
export CHROME_DEVTOOLS_AXI_SESSION="readme-addons-$$"
trap 'chrome-devtools-axi stop >/dev/null 2>&1 || true' EXIT
before=c14552a03a23
head=$(git rev-parse HEAD)
export README_PROOF_HEAD="$head"
chrome-devtools-axi selectpage 1 >/dev/null 2>&1 || true
for phase in before after; do
  ref=$before
  [ "$phase" = before ] || ref=$head
  for width in 390 1280; do
    height=800
    [ "$width" = 1280 ] || height=844
    for theme in light dark; do
      name="$phase-$width-$theme"
      chrome-devtools-axi emulate --viewport "${width}x${height}x1" --color-scheme "$theme" >/dev/null
      chrome-devtools-axi open "https://github.com/umeranjum17/firstmate-addons/tree/$ref#readme" >/dev/null
      # GitHub persists its site theme; apply the requested documented theme to the real page.
      chrome-devtools-axi eval "(() => { document.documentElement.setAttribute('data-color-mode', '$theme'); document.documentElement.setAttribute('data-light-theme','light'); document.documentElement.setAttribute('data-dark-theme','dark'); const a = document.querySelector('article.markdown-body'); scrollTo({top:scrollY+a.getBoundingClientRect().top-72,behavior:'instant'}); return document.title })()" > "$DONE_DONE_EVIDENCE_ROOT/$name-title.txt"
      chrome-devtools-axi eval '(() => { const a=document.querySelector("article.markdown-body"), top=a.getBoundingClientRect().top; if(Math.abs(top-72)>12) throw new Error("README framing moved: top="+top); return JSON.stringify({url:location.href,width:innerWidth,articleTop:top,theme:document.documentElement.getAttribute("data-color-mode"),text:a.innerText,scrollContainers:[...a.querySelectorAll("*")].filter(e=>e.scrollWidth>e.clientWidth+1&&getComputedStyle(e).overflowX==="auto").length}) })()' > "$DONE_DONE_EVIDENCE_ROOT/$name-page.txt"
      chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/$name.png" >/dev/null
    done
  done
done
# Phone-width Choose your job viewports (candidate only): scroll the heading into frame and capture.
for theme in light dark; do
  name="choose-job-390-$theme"
  chrome-devtools-axi emulate --viewport "390x844x1" --color-scheme "$theme" >/dev/null
  chrome-devtools-axi open "https://github.com/umeranjum17/firstmate-addons/tree/$head#readme" >/dev/null
  chrome-devtools-axi eval "(() => {
    document.documentElement.setAttribute('data-color-mode', '$theme');
    document.documentElement.setAttribute('data-light-theme','light');
    document.documentElement.setAttribute('data-dark-theme','dark');
    const a = document.querySelector('article.markdown-body');
    const h = [...a.querySelectorAll('h1,h2,h3')].find(e => /Choose your job/i.test(e.textContent || ''));
    if (!h) throw new Error('Choose your job heading missing');
    scrollTo({top: scrollY + h.getBoundingClientRect().top - 72, behavior: 'instant'});
    const top = h.getBoundingClientRect().top;
    if (top < 60 || top > 120) throw new Error('Choose your job framing moved: top=' + top);
    const clipped = [...a.querySelectorAll('pre, table, code')].filter(e => e.scrollWidth > e.clientWidth + 1);
    if (clipped.length) throw new Error('horizontal clip: ' + clipped.map(e => e.tagName).join(','));
    return JSON.stringify({theme: '$theme', headingTop: top, heading: h.textContent.trim()});
  })()" > "$DONE_DONE_EVIDENCE_ROOT/$name.txt"
  chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/$name.png" >/dev/null
done
python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ['DONE_DONE_EVIDENCE_ROOT'])
(root / 'steps.json').write_text(json.dumps({
    'target': {'version': os.environ['README_PROOF_HEAD']},
    'start': 'The original GitHub README at c14552a03a23; candidate branch is pushed.',
    'steps': [
        'Open the actual original and candidate GitHub repository README.',
        'Set phone width (390) and desktop (1280) viewports in light and dark.',
        'Scroll the rendered article into view and capture viewport frames and page text.',
        'On phone width, open Choose your job and capture light and dark viewports with every install line fully visible without horizontal scroll.',
    ],
    'result': 'On phone width (390) GitHub, every Choose your job install line is fully visible without horizontal scroll.',
}, indent=2) + '\n')
(root / 'transcript.txt').write_text(
    'On phone width (390) GitHub, every Choose your job install line is fully visible without horizontal scroll.\n'
    f'candidate={os.environ["README_PROOF_HEAD"]}\n'
)
PY
