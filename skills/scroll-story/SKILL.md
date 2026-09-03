---
name: scroll-story
description: Create self-contained scroll-driven technical explainers with a pinned diagram, code panel, or schema beside narrative steps. Use for visual code reviews, PR walkthroughs, architecture or data-flow narratives, and requests for scrollytelling, sticky-scroll, pinned-diagram, or scroll-driven explainer pages.
user-invocable: true
---

<!-- maintainers: this is a public, installer-facing skill. Keep it standalone, with no private project paths, environment branching, or assumptions about fleet-only tools. -->

# scroll-story

Turn a technical change into one self-contained HTML page where the narrative scrolls and a bounded stage stays pinned while its focus changes.
Start by copying [`template.html`](template.html), then replace its example story, stage artwork, state map, and colors with evidence from the user's diff or system.

## Build the story first

Inspect the change, trace the real call and data paths, and choose only the beats needed to explain it.
Use this sequence as a starting template, not a fixed six-step form:

1. Show the trigger or entry point, such as the call site, route, or endpoint.
2. Trace the call flow or stack, such as controller to service to repository.
3. Reveal the new code in a code panel, with added lines highlighted like a diff.
4. Show systems talking to each other by drawing each service-to-service edge when its beat is reached.
5. Move into the data layer and light the affected tables and specific changed columns.
6. End on the result and side effects, including emitted events, invalidated caches, and downstream consumers.

Split or omit beats to match the actual change.
Make every claim traceable to the supplied code, diff, schema, or architecture.

Apply two hard design rules throughout:

- Put one idea in each scroll step.
- Change exactly one thing on the stage per step so the reader always knows what moved.

A single focal path or schema delta may involve several related SVG elements, but it must read as one semantic change rather than several simultaneous revelations.

## Use the bounded sticky layout

Put the sticky stage and scrolling steps in the same `.scrolly` container.
The container's height is established by the steps column, so it bounds the sticky element and releases it when the story ends.
Use two columns on wide screens, vertically center the stage with `top: 50vh` plus a transform, and give the steps generous vertical spacing.

```css
:root {
  --stage-height: min(68vh, 42rem);
}

.scrolly {
  display: grid;
  grid-template-columns: minmax(0, 1.25fr) minmax(18rem, 0.75fr);
  gap: clamp(2rem, 6vw, 6rem);
  align-items: stretch;
  position: relative;
}

.stage-column {
  min-width: 0;
  align-self: stretch;
}

.stage {
  position: sticky;
  top: 50vh;
  transform: translateY(-50%);
  height: var(--stage-height);
  overflow: hidden;
}

.steps {
  min-width: 0;
  display: grid;
  gap: 38vh;
  padding-block: 34vh 54vh;
}

.step {
  min-height: 32vh;
}

@media (max-width: 50rem) {
  .scrolly {
    display: block;
  }

  .stage {
    position: relative;
    top: auto;
    transform: none;
    height: min(70vh, 32rem);
  }

  .steps {
    gap: 1rem;
    padding-block: 2rem;
  }

  .step {
    min-height: auto;
  }
}
```

Do not place `overflow: hidden`, `auto`, or `scroll` on an ancestor of the sticky stage unless that ancestor is intentionally the scroll container.
Reserve enough top and bottom padding in `.steps` for the first and last beats to cross the reading line while the stage is still visible.

## Build stage types

Choose the stage type that gives each beat a concrete visual target.
Keep stable geometry within a stage so attention moves without the page jumping.

### Inline SVG architecture diagram

Draw architecture artwork as inline SVG so CSS and JavaScript can address it directly.
Give every focusable node and edge a stable id, add `data-focusable` to nodes, and set `pathLength="1"` on animated edges.

```html
<svg viewBox="0 0 800 500" role="img" aria-labelledby="diagram-title diagram-desc">
  <title id="diagram-title">Request processing architecture</title>
  <desc id="diagram-desc">The endpoint calls the service, which writes the database and publishes an event.</desc>
  <path id="edge-service-db" class="edge" pathLength="1" d="M 390 220 C 470 220 500 320 590 320" />
  <g id="service" data-focusable class="node">...</g>
</svg>
```

```css
.node {
  opacity: 0.22;
  transition: opacity 280ms ease, filter 280ms ease;
}

.node.is-active {
  opacity: 1;
  filter: drop-shadow(0 0 10px var(--accent));
}

.edge {
  fill: none;
  stroke: var(--accent);
  stroke-dasharray: 1;
  stroke-dashoffset: 1;
  opacity: 0.16;
  transition: stroke-dashoffset 650ms ease, opacity 220ms ease;
}

.edge.is-drawn {
  stroke-dashoffset: 0;
  opacity: 1;
}
```

Focus a node by adding `.is-active`, dim the remaining nodes with their base opacity, and draw only the edge named by the active state.
Use SVG markers for arrowheads and keep labels inside the SVG so they stay aligned while scaling.

### Code and diff panels

Render code as a `<pre><code>` block containing one span per line.
Give each line a stable `data-line` value, mark additions with `.added`, and let the active state name a line or inclusive range.

```html
<pre class="code-panel"><code>
<span class="code-line" data-line="1">async function createOrder(input) {</span>
<span class="code-line added" data-line="2">  const event = await outbox.insert(input);</span>
<span class="code-line" data-line="3">}</span>
</code></pre>
```

```css
.code-line {
  display: block;
  border-left: 3px solid transparent;
  opacity: 0.42;
}

.code-line.added::before {
  content: "+";
  color: var(--success);
  margin-right: 0.75rem;
}

.code-line.is-active {
  opacity: 1;
  border-left-color: var(--accent);
  background: var(--code-highlight);
}

.code-line.added.is-active {
  box-shadow: inset 0 0 1.5rem var(--added-glow);
}
```

Keep line numbers and the diff marker outside the copied code text when practical.
Highlight only the line range discussed by the current step.

### Table and schema stages

Model each table as a card with a stable id and each row as a stable `data-column` target.
Dim unaffected tables, light the affected table, and apply a stronger treatment only to the columns the prose names.

```html
<section id="orders" class="schema-table" aria-label="orders table">
  <h3>orders</h3>
  <div class="schema-column" data-column="orders.status"><code>status</code><span>text</span></div>
</section>
```

```css
.schema-table {
  opacity: 0.28;
  transition: opacity 280ms ease, border-color 280ms ease;
}

.schema-table.is-active {
  opacity: 1;
  border-color: var(--accent);
}

.schema-column.is-active {
  color: var(--text);
  background: var(--schema-highlight);
}
```

Keep keys, types, and relationships visible in neutral form so the highlighted delta still has context.

### Swap stage types without jumping

Use one fixed-height stage and absolutely position every stage layer in the same inset box.
Cross-fade opacity and visibility instead of inserting, removing, or resizing content.

```css
.stage-body {
  position: relative;
  height: 100%;
}

.stage-layer {
  position: absolute;
  inset: 0;
  min-width: 0;
  opacity: 0;
  visibility: hidden;
  pointer-events: none;
  transition: opacity 240ms ease, visibility 0s linear 240ms;
}

.stage-layer.is-active {
  opacity: 1;
  visibility: visible;
  pointer-events: auto;
  transition-delay: 0s;
}
```

## Activate steps declaratively

Give every step a unique `data-step` id.
Define one state object per id, observe the steps at a reading line near the middle of the viewport, and pass the selected id to one render function.

```js
const steps = [...document.querySelectorAll("[data-step]")];
const states = {
  entry: { layer: "architecture", nodes: ["endpoint"] },
  code: { layer: "code", lines: [2, 3] },
  data: { layer: "schema", tables: ["orders"], columns: ["orders.status"] }
};

function render(stepId) {
  const state = states[stepId];
  if (!state) return;

  document.documentElement.dataset.activeStep = stepId;
  steps.forEach((step) => step.classList.toggle("is-active", step.dataset.step === stepId));
  document.querySelectorAll("[data-layer]").forEach((layer) => {
    layer.classList.toggle("is-active", layer.dataset.layer === state.layer);
  });

  // Reset every focus class, then apply only state.nodes, state.edges,
  // state.lines, state.tables, and state.columns here.
}

const observer = new IntersectionObserver((entries) => {
  const crossing = entries
    .filter((entry) => entry.isIntersecting)
    .sort((a, b) => Math.abs(a.boundingClientRect.top - innerHeight * 0.5)
      - Math.abs(b.boundingClientRect.top - innerHeight * 0.5));

  if (crossing[0]) render(crossing[0].target.dataset.step);
}, { rootMargin: "-46% 0px -46% 0px", threshold: 0 });

steps.forEach((step) => observer.observe(step));
render(steps[0].dataset.step);
```

Keep `states` as the declarative source of truth and make `render` idempotent so fast scrolling and reverse scrolling always reconstruct the complete stage state.
Do not use a scroll listener that repeatedly calls `getBoundingClientRect()` across all steps.
Do not scatter ad hoc DOM mutations through per-step callbacks.

## Meet responsive and accessibility requirements

Treat these as release requirements:

- Collapse the sticky two-column layout on narrow screens into a stage-above-story or another non-sticky stacked flow.
- Make every step complete, understandable prose when the stage is absent.
- Mark a redundant visual stage `aria-hidden="true"`, or give an informative stage a concise accessible name and description.
- Never put a fact only in a color, glow, arrow, animation, or highlighted line.
- Preserve visible keyboard focus for any interactive controls.
- Honor reduced motion by removing transitions and showing every shape in its final geometric position.

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    scroll-behavior: auto !important;
    transition-duration: 0.01ms !important;
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
  }

  .edge {
    stroke-dashoffset: 0;
  }
}
```

## Keep the output self-contained

Deliver one HTML file with inline CSS, inline JavaScript, inline SVG, and no CDN or external dependency.
Define theme-aware colors as custom properties on `:root` and override them with `prefers-color-scheme: dark`.

```css
:root {
  color-scheme: light dark;
  --page: #f4f1e8;
  --panel: #ffffff;
  --text: #18201f;
  --muted: #5c6966;
  --accent: #176b87;
  --success: #18794e;
}

@media (prefers-color-scheme: dark) {
  :root {
    --page: #0d1415;
    --panel: #152022;
    --text: #eef5f3;
    --muted: #a6b6b2;
    --accent: #68d7ff;
    --success: #71e0a5;
  }
}
```

The result must work when opened directly as a plain file and when hosted as a published artifact.

## Ship checklist

Before handing over the page, verify every item in a real browser:

- [ ] Every step maps to exactly one stage state, and every stage state has one step.
- [ ] Every scroll step contains one idea.
- [ ] The stage changes exactly one thing per step.
- [ ] The first and last steps have enough scroll room to activate.
- [ ] The stage remains pinned inside the story and releases at the story's end.
- [ ] Fast forward scrolling and reverse scrolling reconstruct the correct state.
- [ ] The layout collapses into a non-sticky flow at phone width.
- [ ] Reduced motion removes transitions and leaves arrows and shapes in their final geometric positions.
- [ ] Every step remains understandable without the stage, and the stage has correct accessible treatment.
- [ ] The page has no horizontal scroll at desktop or phone width.
- [ ] The browser console has no errors.
- [ ] The file has no external requests or dependencies.
