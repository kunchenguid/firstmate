---
name: frontend-design
description: Guidance for intentional, legible visual design when building or reshaping an HTML surface - telemetry dashboards, the status board, review and report pages. Covers layout, typography, CSS structure, honest data binding, and a mandatory render-and-screenshot verification loop. Adapted from Anthropic's frontend-design skill.
---

# Frontend Design

Design our HTML surfaces - telemetry dashboards, the status board, review and report pages - to be clear, intentional, and honest. The goal is not brand flair; it is a surface someone reads at a glance and trusts. Make deliberate choices about layout, type, and spacing that fit the data at hand, and avoid the templated defaults that make a page read as auto-generated. On captain-facing surfaces you have more room to be expressive; on dense telemetry dashboards, clarity is the whole point.

## Ground it in the real content

Design around the actual data the surface shows, never mock content. Name the surface's single job before you start: what does the reader need to know in the first three seconds? Bind every number, label, and state to a real source. If a value does not exist yet, show it as a labeled gap ("no per-day series exists yet - telemetry gap"), not a fabricated figure. Our surfaces are trusted because they are honest; a plausible-looking mock is worse than an empty panel that says why it is empty.

## Design principles

Lead with the thing that matters most. Open the surface with the single most decision-relevant view - the funnel, the price-and-order-flow panel, the status that changed - not a generic big-number hero unless that number truly is the headline.

Typography carries legibility. Set a clear type scale with intentional weights and spacing, and keep it consistent across every surface so they read as one family. Prefer legible fonts and sizes over decorative ones; these are read quickly, often at a glance.

Structure is information. Numbering, eyebrows, dividers, and labels should encode something true - a real sequence, a real grouping - not decorate. Numbered markers (01 / 02 / 03) are only right when order actually carries meaning the reader needs.

Align by construction, not by eye. When rows must line up - KPI tiles over funnel stages, columns across cards - put them on the same grid with the same column count, and reserve fixed heights for variable-length elements like titles so alignment holds regardless of content length. Ragged edges read as broken.

Match complexity to the job. Dense dashboards need precision in spacing and type; simpler surfaces need restraint. Cut any decoration that does not help the reader.

Use motion sparingly. A dashboard rarely needs animation, and extra motion reads as AI-generated. Reserve it for a captain-facing surface where a reveal genuinely helps the reader.

## CSS discipline (the alignment trap)

Be careful with CSS selector specificity. It is easy to generate classes that cancel each other out - a type-based selector like `.section` fighting an element-based one, or paddings and margins colliding between sections.

The most common alignment bug we hit is a grid mismatch: two rows on different column counts (e.g. one on `repeat(6, ...)`, another on `repeat(7, ...)`) can never line up - their edges only coincide at the far ends. Put rows that must align on the same track count with one item per column, and give variable-height children (titles that may wrap) a fixed `min-height` so the rows below them stay in register.

## Verify what you built (mandatory)

Never hand a visual surface back unverified. We have a headless browser - render the file and screenshot it before calling the work done:

```sh
chrome-devtools-axi open "file:///path/to/surface.html"
chrome-devtools-axi screenshot /path/to/out.png
```

Then look at the screenshot and critique it as a reader would: are the rows aligned, is anything clipped or overflowing, does the most important thing draw the eye first? Fix and re-screenshot until it is right. A picture is worth 1000 tokens; editing HTML blind is how alignment bugs ship.

## Restraint and self-critique

Keep it disciplined: responsive so it does not break at a smaller window, visible keyboard focus, reduced motion respected. Critique your own work as you build. Before you finish, look at it once more and remove one element that is not earning its place.

## Writing on the surface

Words are design material, not decoration. Before writing a label, ask what the reader needs to know and how to say it plainly.

- Name things by what the reader recognizes, not how the system is built. "Awaiting review," not "PR state = open."
- Active voice, specific over clever. A control says what it does; a status says what happened.
- Keep vocabulary consistent across surfaces so a reader learns their way around once.
- Treat empty and failed states as direction, not mood: say what is missing and why, or what to do next. On our dashboards an empty panel should name the telemetry gap rather than sit blank.
- Sentence case, plain verbs, no filler. Let each element do exactly one job.
