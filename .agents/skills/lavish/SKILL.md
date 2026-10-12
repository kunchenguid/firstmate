---
name: lavish
description: Turn complex or visual agent responses into a rich, reviewable Pulse page the captain reviews in the Parlay panel. Use when about to give a plan, comparison, diagram, table, code diff, report, or anything easier to grasp visually than as prose. The artifact is ALWAYS a Pulse page served at http://localhost:31337/<tag>/ — never a lavish-axi page, ht-ml.app share, or any other artifact host.
argument-hint: <what the artifact should show>
metadata:
  hermes:
    tags: [html, review, artifacts, visualization, parlay, pulse]
    category: productivity
---

# Lavish (Pulse-page review)

Turn a rich HTML artifact into a review surface by publishing it as a **Pulse page**: write the HTML to `~/pulse-pages/<tag>/index.html` and it is served by Pulse at `http://localhost:31337/<tag>/`, reachable from the captain's phone over Tailscale. The Parlay chat panel is injected into every Pulse page, so the captain opens the link, reviews the page, and gives feedback in your channel — the same review loop, no extra tooling. Whenever you are about to give a response easier to understand as a rich page than as prose, build the HTML and publish it as a Pulse page.

**The target is ALWAYS a Pulse page.** Never a lavish-axi page, an ht-ml.app share, or any other artifact host — that tooling is not supported here. The only surface is `~/pulse-pages/<tag>/` served by Pulse.

**This is opt-out, not opt-in:** anything the captain would plausibly want to *see* — a walkthrough, report, plan, comparison, diff, or a decision needing his eyes — goes to a Pulse page by default. Keep only quick factual one-liners in terminal chat.

## Request

$ARGUMENTS

If the request above is non-empty, the captain invoked `/lavish` explicitly — build the page for that request now.
If it is empty, infer what to visualize from the conversation.

## Lavish v2 — markdown-first (DEFAULT since 2026-07-18)

The captain's directive: agent pages are first-class citizens of the pulse-next React app, which owns the design surface. **For content-shaped pages (report, plan, comparison, walkthrough, decision) do NOT hand-write HTML.** Instead:

1. **Write** `~/pulse-pages/<tag>/page.md` — YAML frontmatter (`title`, `agent`, `kind`, `created`) + markdown body. That IS the publish.
2. pulse-next renders it at `/<tag>/` inside the app's design surface — house styling, nav, and the Parlay chat panel, all automatic. Edits are live on the next refresh.
3. **Verify** `curl -s -o /dev/null -w "%{http_code}" http://localhost:31339/<tag>/` → `200`, then `interceptor open http://localhost:31339/<tag>/`.
4. **Commit — required, not optional.** `~/pulse-pages` is a git repo (since 2026-07-18). Publishing is not done until committed, with a semantic message that clearly articulates the change: `git -C ~/pulse-pages add <tag>/ && git -C ~/pulse-pages commit -- <tag>/ -m "feat(<tag>): <what the page shows and why it changed>"` (`feat` new page, `fix` correction, `docs` copy-only, `chore` regeneration). Captain directive 2026-07-18.
5. **Report out** the phone URL: `macbook:31339/<tag>/` (pre-cutover port; becomes 31337 after cutover).

**Precedence:** a tag with `index.html` always wins (back-compat). Raw HTML (`index.html`, the workflow below) remains the right tool for heavily custom visuals — bespoke diagrams, interactive widgets, embedded screenshots — but markdown is the default for everything content-shaped. Never add infra (scripts, components) to `~/pulse-pages` — infrastructure lives in `~/code/pulse-next`; content and infra repos are deliberately separate.

## Tools, paths & URL — raw-HTML path (custom visuals only)

| Step | Tool | Exact form |
| --- | --- | --- |
| Publish | **Write** tool | Write the HTML to `~/pulse-pages/<tag>/index.html`, where `<tag>` is a short kebab slug (e.g. `deploy-plan`). This file IS the publish — no build step, no `lavish`/`lavish-axi`/`npx` command. Re-saving the same path redeploys the same URL. |
| Verify serves | **curl** | `curl -s -o /dev/null -w "%{http_code}" http://localhost:31337/<tag>/` → expect `200` |
| Verify render | **interceptor** | `interceptor open http://localhost:31337/<tag>/` — the mandatory web-verification tool; never skip it |
| Surface / report out | **parlay say** | `parlay say "<one line> — macbook:31337/<tag>/"` on your own channel |

- **Local URL** (your own checks): `http://localhost:31337/<tag>/`
- **Report-out URL** (what you send the captain — Tailscale short name, clickable on his phone): `macbook:31337/<tag>/`. Always report the page this way; never send him a raw `localhost` link (his phone can't open it).

## Workflow

1. Choose `<tag>`; **Write** the HTML to `~/pulse-pages/<tag>/index.html`.
2. **Verify:** `curl …` returns `200`, then `interceptor open http://localhost:31337/<tag>/` to check the render; fix and re-save until it's right.
3. **Surface it** in the panel, reporting the phone-clickable Tailscale URL: `parlay say "<what it is + what to review first> — macbook:31337/<tag>/"`.
4. The captain reviews (desktop or phone) and replies in your channel. Apply the feedback, re-save the file (same URL), tell him it's updated, and keep the loop until the review concludes.

## Key brain resources

- **brain-89jv8** — [Parlay PWA structure](http://localhost:31337/status/#isa-parlay-pwa): same-document injection (no iframe), chat-app shell as degenerate full-screen case, architecture for understanding how Parlay integrates with pages
- **brain-9e1bp** — [Parlay page design best practices](http://localhost:31337/status/#isa-page-design): filesystem-backed state for agent visibility, persistent inputs across reloads/systems, server-update pattern, **web accessibility requirements for all input controls & modals**

## Visual guidance

- Use visual hierarchy so the most important decisions, risks, tradeoffs, and next actions are obvious at a glance.
- Use structure — sections, cards, tables, diagrams, annotated snippets, side-by-side comparisons — instead of long prose. Reserve prose for what cannot be shown: rationale, trade-offs, open questions.
- **Mobile-first (the captain reviews in portrait on his phone):** responsive layout with relative units; diagrams oriented **vertically** (taller than wide, top-to-bottom flow) — never wide left-to-right, which forces horizontal scrolling on a phone. Wide content (tables, code, diagrams) scrolls inside its own `overflow-x:auto` container so the page body never scrolls sideways.
- Prevent horizontal overflow at every nesting level: nested grid/flex children need `minmax(0,1fr)` tracks and `min-width:0`, especially with wide badges/labels or monospace text; wrap, truncate, or contain long unbreakable strings deliberately.
- When the artifact would describe existing UI or state, **show it** — capture screenshots of the real pages (run the app read-only if needed) and embed them — rather than describing the current look in prose.
- Artifact kinds to reach for: diagram (relationships/flow/state/architecture), table (dense records), comparison (options/tradeoffs/current-vs-target), plan (before implementation), code (source/patches/diffs), input (collect a decision/choice inside the page), slides (a requested presentation).
- **For Parlay pages specifically:** refer to brain-9e1bp for state management patterns — all inputs/interactions must use filesystem-based storage for agent visibility; inputs must persist across reloads and systems via server updates following the Parlay input box pattern.

## Rules

- **One surface only:** the page is `~/pulse-pages/<tag>/index.html` → `http://localhost:31337/<tag>/`. Do not invoke any `lavish` binary, `lavish-axi`, `npx` package, ht-ml.app share, or export tool — none are supported. Publishing = writing the file.
- **Self-contained page:** inline all CSS and JS. For images/fonts/scripts, copy them into the same `<tag>/` directory and reference them with **relative paths** — never a leading `/`.
- **One-URL rule:** a durable report/dashboard should also be linked from `/status/` so it is reachable in one click; ephemeral review pages can be left unlinked and cleaned up later.
- **Design direction**, in strict priority: (1) if the captain named a look or design system, use it; (2) else match the subject project's design system — its Tailwind/theme config, CSS variables/design tokens, component library, brand assets, or existing styled pages — so a UI mock faithfully shows that product; (3) only when both come up empty, use a clean self-contained dark theme consistent with Pulse. State which of the three you used when you deliver the page.

---

## This home (firstmate) — read before choosing a surface

This skill was ported from the agent-level skill set (`~/.agents/skills/lavish`) into the
firstmate home so crewmates and secondmates running **here** can publish review pages.

One divergence you must know about, because this home has older lavish machinery:

- **This skill's default surface is the Pulse page** — `~/pulse-pages/<tag>/` served by
  Pulse (pulse-next) on **31339** (`31337` proxied until cutover). That is the captain's
  default and what this skill's workflow describes above.
- **This home also ships a lavish-axi path**: `bin/fm-procevent-lavish.sh` is a thin
  adapter over the `lavish-axi` CLI (installed; v0.1.46) that arms an HTML artifact for the
  generic process→event runner (`bin/fm-procevent.sh`), and existing artifacts live in
  `.lavish/*.html`. That path exists for the **process-event review loop** — it is how a
  published artifact gets armed for durable feedback capture.

So: **publish content pages as Pulse pages** (above). Reach for the lavish-axi procevent
path only when you specifically need the armed process-event loop, and say so when you do.
If the two ever conflict for a task, ask which surface the captain wants rather than
picking silently.
