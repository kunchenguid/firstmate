---
name: stakeholder-demo
description: "Create a polished, on-brand stakeholder demo microsite for any client or GTM AI project. Use this skill whenever the user asks for a demo, demo site, demo microsite, stakeholder demo, interactive demo, or a shareable 'see it in action' page for a project. Trigger on: 'make a demo', 'build a demo site', 'create a demo for X', 'add a demo to the collateral', 'demo microsite'. This skill produces a single self-contained HTML file encoding the four-tab framework (What it is, See it in action, How it works, What's next), a single-loop animated flow on the client's own product surface, a visual-first layer stack with arrows and a closed loop, and a connected milestone timeline. Adapt the design tokens to the client's brand before shipping."
---

# Stakeholder Demo Microsite Skill

Produce a production-quality, self-contained stakeholder demo for any client or GTM AI project.
This skill encodes the finalized Clario SalesOps demo framework as its base foundation.
The merged Clario demo (`projects/clario/demo/clario-demo.html`) is the canonical reference implementation.
Every demo built with this skill reproduces this exact four-tab structure, visual style, and governance-forward tone.
Parameterize only the client's brand tokens, simulated product surfaces, and domain workflow.

## Deliverable Contract

Every build produces a single self-contained HTML file: `projects/<name>/demo/<slug>-demo.html` (or `projects/<name>/docs/collateral/<slug>-demo.html`).
The HTML file has zero external runtime dependencies.
Do not link external CDNs, Google Fonts stylesheets, remote CSS libraries, or remote scripts.
The demo must run completely offline when opened directly from disk or served statically from nginx.
Every demo is styled for a browser window with full-screen support, generous whitespace, and responsive scaling.

Optionally, when Cloud Run hosting is requested, produce:
- `projects/<name>/docs/collateral/cloudrun/index.html` (copy of the demo HTML)
- `projects/<name>/docs/collateral/cloudrun/Dockerfile`
- `projects/<name>/docs/collateral/cloudrun/nginx.conf`

## Tone and Style Rules

Adopt a concrete, governance-forward tone across all copy, captions, and visual cards.
Highlight auditable guardrails, fail-closed assertions, reversible actions, and operational metrics.
Never use marketing slogans or breathless claims such as revolutionary AI or autonomous magic.
Never use personal names in operator workflows or approvals.
Refer to participants by titles only, such as "The VP of Sales", "The AE", "Sales Manager", "Security Lead", or "Compliance Officer".
Fictional CRM contact names on mock records are acceptable, but all operational governance and operator roles use titles only.
Use whitespace-first layouts so elements breathe cleanly in standard and full-screen viewports.
Use plain dashes `-` everywhere.
Never use em dashes in tracked markdown, HTML, CSS, or JavaScript strings.

## The Four-Tab Shell

Every demo organizes into exactly four tabs in this fixed sequence:
1. "What it is"
2. "See it in action"
3. "How it works"
4. "What's next"

Header markup pattern:
```html
<header class="site-head">
  <div class="brand-group">
    <svg class="brand-icon" viewBox="0 0 27 27" fill="none">
      <!-- client SVG mark -->
    </svg>
    <div class="brand-text">
      <h1>[Client] · [Project Title]</h1>
    </div>
  </div>
  <nav class="tabs" id="tabs" aria-label="Demo sections">
    <button class="tab active" data-tab="overview">What it is</button>
    <button class="tab" data-tab="demo">See it in action</button>
    <button class="tab" data-tab="how">How it works</button>
    <button class="tab" data-tab="next">What's next</button>
  </nav>
</header>
```

Tab container CSS:
```css
.tabs { display: flex; gap: 4px; background: rgba(255,255,255,.1); border-radius: var(--r-full); padding: 3px; }
.tab { font-family: var(--sans); font-size: 12.5px; font-weight: 500; color: rgba(255,255,255,.75); background: none; border: none; border-radius: var(--r-full); padding: 5px 14px; cursor: pointer; transition: all .15s ease; }
.tab:hover { color: #fff; background: rgba(255,255,255,.08); }
.tab.active { background: var(--teal); color: #fff; font-weight: 600; box-shadow: 0 1px 3px rgba(0,0,0,.2); }
.panel { display: none; flex-direction: column; align-items: center; width: 100%; }
.panel.active { display: flex; }
```

## Tab 1: What it is (~10-Second Hook)

Tab 1 delivers an immediate, high-impact hook designed to be understood in 10 seconds.
The entire tab centers on a single card (`.overview-hero`).

Required components:
1. **One headline:** A concise display title (`.hero-title`, e.g. "A single agent").
2. **One line:** A single subhead sentence (`.hero-lead`) defining the core outcome.
3. **At most three tight bullets:** A bulleted list (`.hero-bullets`) with at most 3 items.
   - Each bullet starts with a bold category label (`<strong>Label:</strong>`).
   - Every bullet must fit 1 to 2 lines of text.
   - Never write a 3-line paragraph in this list.
4. **"See it in action" CTA:** A dedicated action row (`.hero-cta-wrap`) containing an invitation sentence and an action button (`#ctaDemo`).
   - Clicking `#ctaDemo` switches to the "See it in action" tab and smoothly scrolls the demo panel into view.

Tab 1 markup template:
```html
<section class="panel active" id="panel-overview">
  <div class="overview-hero">
    <h2 class="hero-title">[One Bold Headline]</h2>
    <p class="hero-lead">[One concise sentence summarizing the core deliverable and outcome.]</p>

    <ul class="hero-bullets">
      <li><strong>[Category One]:</strong> [Tight 1-2 line description of proactive capability.]</li>
      <li><strong>[Category Two]:</strong> [Tight 1-2 line description of enablement or integration.]</li>
      <li><strong>[Category Three]:</strong> [Tight 1-2 line description of human governance and audit control.]</li>
    </ul>

    <div class="hero-cta-wrap">
      <span>Explore the interactive workflow in the live environment:</span>
      <button type="button" id="ctaDemo">See it in action &rarr;</button>
    </div>
  </div>
</section>
```

## Tab 2: See it in action (Centerpiece Single-Loop Flow)

Tab 2 is the centerpiece of the entire microsite.
It presents a single-loop animated flow on the client's own product surface.
Show one coherent journey with clear touch points across a journey rail, not five repeated wireframes.

### 1. Journey Rail
Place a journey rail (`.journey-rail`) at the top of the demo shell.
The rail displays 4 to 5 sequential beats (e.g. 01 · WATCH, 02 · EVALUATE, 03 · ASSEMBLE, 04 · GOVERN, 05 · COMPOUND).
Each step includes:
- A step number and category pill (`.step-num`, e.g. "01 · WATCH").
- A short step name (`.step-name`, e.g. "Signal").
- A brief subtitle (`.step-desc`, e.g. "Webhooks, calendar, staleness").
Clicking any rail step scrubs directly to that beat.

### 2. Beat Explainer Banner
Below the journey rail, render a synchronized 3-column explainer banner (`.beat-banner`):
- Column 1: Agent Action (what the background runtime is actively doing).
- Column 2: Operator Experience (what the human operator sees or avoids doing).
- Column 3: Components Active (badges showing active subsystem tags, `.uc-pill active`).

### 3. Client Product Surface Window
Wrap the simulated application in realistic desktop or browser window chrome (`.sf-window`):
- Window top bar with window dots (traffic-light controls: red, yellow, green), window title, and live telemetry status pill.
- Navigation bar matching the client's primary enterprise application (e.g. Salesforce, HubSpot, Slack, Jira, or custom console).
- Record highlights header displaying record ID, account name, status tags, and stage chevron path (`.stage-path`).
- Main body grid displaying dynamic panels: opportunity fields, telemetry log feeds, intelligence summaries, and pre-call dossiers.

### 4. Mandatory Human-in-the-Loop Governance Touch Point
The journey must feature a clear human governance step (typically Beat 4 / Approval).
In this beat, display an interactive approval surface, such as an interactive Slack card (`.slack-card`).
Include a 1-click approval button (`#simApproveBtn` with text "Approve & Send Touch").
When clicked, the button provides immediate visual feedback ("Approved - advancing...") and advances the journey to the final outcome beat.
This concretely demonstrates that autonomous actions never contact external parties without explicit human sign-off.

### 5. Transport Controls
Place a dedicated transport bar (`.transport-bar`) directly beneath the simulated window:
- Play/pause toggle button with play/pause icons.
- Scrubber slider (`.scrub-slider`) with discrete step ticks for each beat.
- Beat counter (`#timeDisplay`, e.g. "Beat 1 of 5").
- Playback speed toggle button (`#speedBtn`, cycling through 1.0x, 1.5x, 2.0x).
- Fullscreen toggle button (`#fsBtn`).
- Keyboard shortcuts: Space (play/pause), ArrowLeft/ArrowRight (scrub previous/next beat), F (toggle fullscreen).

### 6. Value-Proposition Summary Cards
Below the transport controls, render 3 architectural summary cards (`.vc-summary-grid`):
- Card 1: Unified sensory core and trigger ingestion.
- Card 2: Grounded human governance and fail-closed validation.
- Card 3: Compounding flywheel and closed-loop optimization.

## Tab 3: How it works (Visual-First 3-Layer Stack & Closed Loop)

Tab 3 is visual-first.
Do not use bullet prose or long paragraphs.
Present a structured layer visual stack with directional flow connectors and a closed return feedback loop.

### 1. Three-Layer Visual Stack (`.arch-stack`)
Structure the architecture into 3 visual layer boxes:
- **Layer 1: Sensory Ingest (`.stack-box.layer-ingest`):**
  - Left border accent in secondary brand color.
  - Category badge: "Layer 1 · Sensory Ingest".
  - 4-column grid of mini tiles (`.mini-tile`), each with an icon, title (`.m-txt`), and subtitle (`.m-sub`).
- **Down connector 1 (`.flow-arrow-down`):**
  - Center arrow pill (`.arrow-pill`): "Streaming Telemetry & Signal Events".
- **Layer 2: Single Agent Runtime (`.stack-box.layer-core`):**
  - Prominent brand accent border and subtle card glow.
  - Category badge: "Layer 2 · Single Agent Runtime".
  - 4-column grid of core capability tiles (e.g. Signal Scoring, Citation Grounding, Drafting Engine, Scoped Guardrails).
- **Down connector 2 (`.flow-arrow-down`):**
  - Center arrow pill (`.arrow-pill`): "Governed Action Proposals".
- **Layer 3: Governed Execution (`.stack-box.layer-exec`):**
  - Left border accent in green/success color.
  - Category badge: "Layer 3 · Governed Execution".
  - 4-column grid of execution tiles (e.g. Slack 1-Click Approval, CRM Writeback, Append-Only Audit, Outcome Attribution).
- **Return Feedback Loop (`.return-loop-banner`):**
  - Dashed accent border with a prominent closed loop badge: "CLOSED LEARNING LOOP".
  - Concise one-line text explaining how execution outcomes feed back into sensory ingestion and prompt/playbook tuning.

### 2. Autonomy Boundaries Swimlanes (`.swimlane-wrap`)
Directly beneath the 3-layer stack, render an Autonomy Boundaries comparison:
- **Autonomous Swimlane (`.swimlane.auto`):**
  - Green left border with "Autonomous / Runs Automatically" header.
  - Row of automated step pills connected with chevrons (`➔`).
  - Examples: scheduled pipeline sweeps, vector grounding, pre-call brief drafting, priority scoring, audit logging.
- **Human Gate Swimlane (`.swimlane.human`):**
  - Amber left border with "Human Gate / 1-Click Rep Sign-Off" header.
  - Row of human-governed step pills connected with chevrons (`➔`).
  - Examples: external emails (never auto-sent), pricing proposals, CRM stage transitions, unverified claim suppression.

Tab 3 visual stack markup template:
```html
<section class="panel" id="panel-how">
  <div class="section">
    <h2>Architecture: Three-Layer Closed Loop</h2>
  </div>

  <div class="arch-stack">
    <div class="stack-box layer-ingest">
      <div class="box-badge">Layer 1 · Sensory Ingest</div>
      <div class="box-grid four-col">
        <div class="mini-tile"><span class="m-icon">📊</span><span class="m-txt">[Source 1]</span><span class="m-sub">[cadence/trigger]</span></div>
        <div class="mini-tile"><span class="m-icon">⚡</span><span class="m-txt">[Source 2]</span><span class="m-sub">[webhook/listener]</span></div>
        <div class="mini-tile"><span class="m-icon">📅</span><span class="m-txt">[Source 3]</span><span class="m-sub">[calendar/schedule]</span></div>
        <div class="mini-tile"><span class="m-icon">📄</span><span class="m-txt">[Source 4]</span><span class="m-sub">[primary documents]</span></div>
      </div>
    </div>

    <div class="flow-arrow-down">
      <div class="arrow-line"></div>
      <div class="arrow-pill">&darr; Streaming Telemetry &amp; Signal Events</div>
      <div class="arrow-line"></div>
    </div>

    <div class="stack-box layer-core">
      <div class="box-badge core-badge">Layer 2 · Single Agent Runtime</div>
      <div class="box-grid four-col">
        <div class="mini-tile core-tile"><span class="m-icon">🔍</span><span class="m-txt">[Scoring/Triage]</span><span class="m-sub">[priority filter]</span></div>
        <div class="mini-tile core-tile"><span class="m-icon">🛡️</span><span class="m-txt">[Grounding]</span><span class="m-sub">[fail-closed citations]</span></div>
        <div class="mini-tile core-tile"><span class="m-icon">✍️</span><span class="m-txt">[Drafting Engine]</span><span class="m-sub">[structured artifacts]</span></div>
        <div class="mini-tile core-tile"><span class="m-icon">🔒</span><span class="m-txt">[Guardrails]</span><span class="m-sub">[retention boundary]</span></div>
      </div>
    </div>

    <div class="flow-arrow-down">
      <div class="arrow-line"></div>
      <div class="arrow-pill">&darr; Governed Action Proposals</div>
      <div class="arrow-line"></div>
    </div>

    <div class="stack-box layer-exec">
      <div class="box-badge">Layer 3 · Governed Execution</div>
      <div class="box-grid four-col">
        <div class="mini-tile"><span class="m-icon">💬</span><span class="m-txt">[Human Approval]</span><span class="m-sub">[1-click sign-off]</span></div>
        <div class="mini-tile"><span class="m-icon">📝</span><span class="m-txt">[CRM Writeback]</span><span class="m-sub">[reversible updates]</span></div>
        <div class="mini-tile"><span class="m-icon">🔐</span><span class="m-txt">[Audit Log]</span><span class="m-sub">[append-only trail]</span></div>
        <div class="mini-tile"><span class="m-icon">📈</span><span class="m-txt">[Outcome Learning]</span><span class="m-sub">[flywheel attribution]</span></div>
      </div>
    </div>

    <div class="return-loop-banner">
      <span class="loop-badge">&#128257; CLOSED LEARNING LOOP</span>
      <span class="loop-text">Outcomes automatically tune detection thresholds, objection handles, and prompt playbooks.</span>
    </div>
  </div>

  <div class="section" style="margin-top:20px">
    <h2>Autonomy Boundaries: Automated vs. Human Gate</h2>
  </div>

  <div class="swimlane-wrap">
    <div class="swimlane auto">
      <div class="swimtag">
        <span class="swim-pill">Autonomous</span>
        <strong>Runs Automatically</strong>
      </div>
      <div class="swim-nodes">
        <span class="swim-node">[Task 1]</span><span class="swim-sep">&rarr;</span>
        <span class="swim-node">[Task 2]</span><span class="swim-sep">&rarr;</span>
        <span class="swim-node">[Task 3]</span><span class="swim-sep">&rarr;</span>
        <span class="swim-node">[Task 4]</span>
      </div>
    </div>

    <div class="swimlane human">
      <div class="swim-tag">
        <span class="swim-pill">Human Gate</span>
        <strong>1-Click Sign-Off</strong>
      </div>
      <div class="swim-nodes">
        <span class="swim-node">[Approval 1]</span><span class="swim-sep">&rarr;</span>
        <span class="swim-node">[Approval 2]</span><span class="swim-sep">&rarr;</span>
        <span class="swim-node">[Approval 3]</span>
      </div>
    </div>
  </div>
</section>
```

## Tab 4: What's next (Visual-First Milestone Timeline)

Tab 4 is visual-first.
Do not use narrative paragraphs.
Present an immediate sign-off goal bar, a 4-phase connected milestone timeline, and a kickoff prerequisites strip.

### 1. Immediate Goal Hero Bar (`.goal-hero-bar`)
Render a high-contrast hero banner at the top of Tab 4:
- Left: An "IMMEDIATE GOAL" badge and the target milestone title (e.g. "Sign-Off to Build the Runtime Skeleton").
- Right: A concrete deliverable timeline commitment (e.g. "Live prototype in #client-test within 14 days").

### 2. Connected Milestone Timeline (`.timeline-visual`)
Build a 4-column connected timeline on a continuous horizontal connector rail (`.timeline-rail`):
- Milestone 1 is highlighted as the immediate target (`.tl-card.target-card` with badge `.tl-chip-target` "APPROVAL TARGET").
- Milestones 2 through 4 represent rollout phases (`.tl-chip-next` e.g. "PHASE 2", "PHASE 3", "PHASE 4").
- Each card displays:
  - Numbered circular badge (`.tl-circle`, active with accent background on Phase 1).
  - Target badge pill.
  - Phase title (`<h4>Phase Name</h4>`).
  - Duration text (`.tl-duration`, e.g. "Weeks 1-3", "Weeks 4-6").
  - 3 to 4 deliverable badge pills (`.tl-items .item`).
  - Keep descriptions to a few words per item.

### 3. Kickoff Prerequisites Strip (`.kickoff-strip`)
Below the timeline, provide a 4-tile grid detailing exactly what is required from the client to start:
- Tile 1: Sandbox / API Access (e.g. CRM read access, OAuth credentials).
- Tile 2: Communication Channel (e.g. Slack channel with key stakeholders).
- Tile 3: Primary Documentation (e.g. 3-5 approved whitepapers, product specs, battle cards).
- Tile 4: Model Credentials & Policy (e.g. API keys with Zero Data Retention agreements).

Tab 4 markup template:
```html
<section class="panel" id="panel-next">
  <div class="section">
    <h2>Approval Target: Milestone 1 Skeleton</h2>
  </div>

  <div class="goal-hero-bar">
    <h3><span class="goal-badge">IMMEDIATE GOAL</span> Sign-Off to Build the Runtime Skeleton</h3>
    <span class="goal-sub">Live prototype in <strong>#[client]-test</strong> within 14 days</span>
  </div>

  <div class="section" style="margin-top:16px">
    <h2>4-Phase Production Timeline</h2>
  </div>

  <div class="timeline-visual">
    <div class="timeline-rail"></div>
    <div class="timeline-nodes">
      <div class="tl-card target-card">
        <div class="tl-circle current">1</div>
        <span class="tl-chip-target">APPROVAL TARGET</span>
        <h4>Phase 1: Skeleton</h4>
        <span class="tl-duration">Weeks 1-3</span>
        <div class="tl-items">
          <span class="item">[Deliverable 1]</span>
          <span class="item">[Deliverable 2]</span>
          <span class="item">[Deliverable 3]</span>
          <span class="item">[Deliverable 4]</span>
        </div>
      </div>

      <div class="tl-card">
        <div class="tl-circle">2</div>
        <span class="tl-chip-next">PHASE 2</span>
        <h4>Phase 2: Enablement</h4>
        <span class="tl-duration">Weeks 4-6</span>
        <div class="tl-items">
          <span class="item">[Deliverable 1]</span>
          <span class="item">[Deliverable 2]</span>
          <span class="item">[Deliverable 3]</span>
          <span class="item">[Deliverable 4]</span>
        </div>
      </div>

      <div class="tl-card">
        <div class="tl-circle">3</div>
        <span class="tl-chip-next">PHASE 3</span>
        <h4>Phase 3: Integration</h4>
        <span class="tl-duration">Weeks 7-9</span>
        <div class="tl-items">
          <span class="item">[Deliverable 1]</span>
          <span class="item">[Deliverable 2]</span>
          <span class="item">[Deliverable 3]</span>
          <span class="item">[Deliverable 4]</span>
        </div>
      </div>

      <div class="tl-card">
        <div class="tl-circle">4</div>
        <span class="tl-chip-next">PHASE 4</span>
        <h4>Phase 4: Compounding</h4>
        <span class="tl-duration">Weeks 10-12</span>
        <div class="tl-items">
          <span class="item">[Deliverable 1]</span>
          <span class="item">[Deliverable 2]</span>
          <span class="item">[Deliverable 3]</span>
          <span class="item">[Deliverable 4]</span>
        </div>
      </div>
    </div>
  </div>

  <div class="section" style="margin-top:20px">
    <h2>Kickoff Prerequisites (What We Need to Start)</h2>
  </div>

  <div class="kickoff-strip">
    <div class="k-tile">
      <span class="k-icon">&#128273;</span>
      <strong>[Prerequisite 1]</strong>
      <span class="k-label">[Access scope and permissions]</span>
    </div>
    <div class="k-tile">
      <span class="k-icon">&#128172;</span>
      <strong>[Prerequisite 2]</strong>
      <span class="k-label">[Review channel and roles]</span>
    </div>
    <div class="k-tile">
      <span class="k-icon">&#128196;</span>
      <strong>[Prerequisite 3]</strong>
      <span class="k-label">[Corpus files and collateral]</span>
    </div>
    <div class="k-tile">
      <span class="k-icon">&#9889;</span>
      <strong>[Prerequisite 4]</strong>
      <span class="k-label">[API credentials and policy]</span>
    </div>
  </div>
</section>
```

## Fullscreen Mode and Whitespace-First Layout

Ensure the demo fits cleanly in standard browser windows and full-screen presentation modes.
The fullscreen implementation expands widths, increases padding, scales font sizes, and hides top site chrome.

Required fullscreen styles:
```css
#panel-demo.fs {
  position: fixed;
  inset: 0;
  z-index: 1000;
  background: #f4f6f9;
  padding: 24px 40px 40px;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  width: 100vw;
  height: 100vh;
}
body.fs-on { overflow: hidden; }
body.fs-on .site-head { display: none; }
#panel-demo.fs .flow-shell { max-width: 1540px; width: 100%; margin: 0 auto; gap: 18px; }
#panel-demo.fs .sf-body-grid { min-height: 460px; gap: 18px; padding: 18px 24px; }
#panel-demo.fs .sf-panel { padding: 18px 22px; gap: 14px; }
#panel-demo.fs .journey-rail { padding: 16px 22px; }
#panel-demo.fs .rail-step { padding: 10px 14px; }
#panel-demo.fs .beat-banner { padding: 14px 22px; }
#panel-demo.fs .vc-card { padding: 20px; }
```

Fullscreen JavaScript toggle:
```javascript
function toggleFullscreen() {
  const isFs = demoPanel.classList.contains('fs') || !!document.fullscreenElement;
  if (!isFs) {
    demoPanel.classList.add('fs');
    document.body.classList.add('fs-on');
    if (document.documentElement.requestFullscreen) {
      document.documentElement.requestFullscreen().catch(() => {});
    }
  } else {
    demoPanel.classList.remove('fs');
    document.body.classList.remove('fs-on');
    if (document.fullscreenElement) {
      document.exitFullscreen().catch(() => {});
    }
  }
}
fsBtn.addEventListener('click', toggleFullscreen);
document.addEventListener('fullscreenchange', () => {
  if (!document.fullscreenElement && demoPanel.classList.contains('fs')) {
    demoPanel.classList.remove('fs');
    document.body.classList.remove('fs-on');
  }
});
```

## JavaScript Playback Engine Pattern

The demo operates on a deterministic beat loop.
Every beat updates the rail, banner, window status, record header, body panels, and scrub slider.

Playback engine skeleton:
```javascript
let currentBeat = 0;
let playing = false;
let playTimer = null;
let speed = 1.0;
const DWELL_MS = 6500;

function renderBeat(idx) {
  currentBeat = idx;
  const b = BEATS[idx];

  Array.from(railSteps.children).forEach((stepEl, i) => {
    stepEl.classList.toggle('active', i === idx);
  });

  agentActionText.textContent = b.agentAction;
  humanActionText.textContent = b.humanAction;
  ucBadges.innerHTML = b.activePills.map(p => `<span class="uc-pill active">${p}</span>`).join('');

  winStatus.textContent = b.windowStatus;
  oppBadge.textContent = b.oppBadge.text;
  oppBadge.className = 'badge-pill ' + b.oppBadge.cls;

  sfBodyGrid.innerHTML = b.render();
  scrubSlider.value = idx;
  timeDisplay.textContent = `Beat ${idx + 1} of ${BEATS.length}`;

  const approveBtn = document.getElementById('simApproveBtn');
  if (approveBtn) {
    approveBtn.addEventListener('click', () => {
      approveBtn.textContent = '✓ Approved! Advancing...';
      approveBtn.style.background = 'var(--green)';
      setTimeout(() => nextBeat(), 800);
    });
  }
}

function play() {
  playing = true;
  playIcon.innerHTML = '<path d="M4 3h3v10H4zm5 0h3v10H9z"/>';
  scheduleNext();
}

function pause() {
  playing = false;
  playIcon.innerHTML = '<path d="M4 2.5v11l9-5.5z"/>';
  if (playTimer) clearTimeout(playTimer);
  playTimer = null;
}

function scheduleNext() {
  if (playTimer) clearTimeout(playTimer);
  if (!playing) return;
  playTimer = setTimeout(() => {
    nextBeat();
  }, DWELL_MS / speed);
}

function nextBeat() {
  const nextIdx = (currentBeat + 1) % BEATS.length;
  renderBeat(nextIdx);
  if (playing) scheduleNext();
}

window.addEventListener('keydown', e => {
  if (e.target.tagName === 'INPUT') return;
  if (e.key === ' ') {
    e.preventDefault();
    playing ? pause() : play();
  } else if (e.key === 'ArrowRight') {
    e.preventDefault();
    pause();
    nextBeat();
  } else if (e.key === 'ArrowLeft') {
    e.preventDefault();
    pause();
    renderBeat((currentBeat - 1 + BEATS.length) % BEATS.length);
  } else if (e.key === 'f' || e.key === 'F') {
    if (document.querySelector('.tab.active')?.dataset.tab === 'demo') {
      e.preventDefault();
      toggleFullscreen();
    }
  }
});
```

## Quality Checklist Before Shipping

Verify every requirement before marking a demo complete:
1. **Four tabs present in order:** What it is -> See it in action -> How it works -> What's next.
2. **Tab 1 follows the hook rule:** One headline, one lead sentence, at most three bullets (each fitting 1 to 2 lines), and one "See it in action" CTA.
3. **Tab 2 is a single-loop flow:** One coherent journey with journey rail, beat banner, client window, transport bar, and interactive human approval button.
4. **Tab 3 is visual-first:** Three-layer visual stack with directional connectors, closed return loop, and autonomy swimlanes without bullet prose.
5. **Tab 4 is visual-first:** Immediate goal hero bar, 4-phase connected milestone timeline with connector rail, and 4-tile kickoff prerequisites strip without narrative paragraphs.
6. **Full-screen support:** Fullscreen toggle and 'F' key scale whitespace and dimensions cleanly.
7. **Tone and naming:** Concrete and governance-forward with titles only and no personal names.
8. **Completely self-contained:** Zero external network calls, zero remote fonts, zero CDN dependencies.
