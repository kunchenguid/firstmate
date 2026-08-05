---
name: frontend-evaluator
description: >-
  Agent-only playbook for the browser evaluation gate on frontend and UI work.
  Use when a frontend, UI, or visual task in a project with a web interface has reached a green test gate but has not landed yet.
  Use before relaying evaluation findings back to the generator, and before spawning a re-evaluation round.
  Use when deciding whether an evaluation verdict blocks landing.
  Loaded only for projects that have a runnable web interface.
user-invocable: false
metadata:
  internal: true
---

# frontend-evaluator

This skill owns the browser evaluation gate: who evaluates frontend work, how they drive the running app, what counts as a blocking defect, and how findings travel back to the worker that wrote the code.

It exists because a DOM assertion suite and an agent's own judgement both miss the same class of defect: an element that renders correctly, passes every selector check, and does nothing when a user clicks it. That is not hypothetical here - a landing redesign shipped to the test stand with most of its new buttons inert while `make test` was green.

## The generator never evaluates itself

An agent asked to judge work it produced praises it.
The generator is the crewmate that wrote the code; the evaluator is a **separate spawn with its own context** that did not write it.
Never ask the generator to confirm its own UI works, and never accept "I verified it visually" from the agent that built it as evidence.
Independence comes from two places, and the second was added deliberately: the evaluator has its own context, **and it runs on a different vendor**. The generator builds on `claude`; the evaluator runs on `codex`. A critic that shares the builder's model shares its blind spots and its taste, so a separate vendor buys a genuinely different read of the same page rather than a second opinion from the same mind.

Model comes from the dispatch profile, not from this file - `config/crew-dispatch.json` carries `gpt-5.6-terra` as the primary with `gpt-5.6-luna` behind it, and `quota-array-dispatch` picks between them on remaining headroom.

Two verified traps, both of which cost a diagnosis on 2026-08-05:

- **`codex`'s model picker is not an entitlement list.** It offers `gpt-5.6-sol` as the default frontier model, but a live call on a ChatGPT-account auth returns `400 ... not supported when using Codex with a ChatGPT account`. Test a slug with a real call before putting it in a profile.
- **`codex login status` and `codex doctor` both report success on a spent token.** They read the stored auth mode, not liveness; only a real request surfaces `refresh token was already used`. When every model fails identically, suspect auth rather than the model name, and fix it with `codex logout && codex login`.

The evaluator reads and drives. It never edits code, never commits, and never lands anything.
A `pass` verdict is permission to continue through the project's normal gates, never a substitute for any of them.

## Preconditions

The generator's work must be committed to its own branch before evaluation - the evaluator gets its own worktree and can only see committed state.
Uncommitted work in the generator's tree is invisible to the evaluator, and evaluating stale code is worse than not evaluating.
The project's own test gate must already be green: the evaluator judges what actually built and passed, not a work in progress.

## Standing the app up

Run the app on a **free lane**, never on the default dev ports, so a concurrent test run or the captain's own dev stack is untouched.
The project owns the lane math; in `parlino` it is `frontend/e2e/fixtures/ports.mjs` (`E2E_LANE=<0..99>`, stride 10, so lane 1 is frontend 5209 / backend 8209 / worker-stub 8208), and it already exports `busyPorts()` for picking a free one.

**Never free a port by killing whatever holds it.** A busy port is somebody else's test run or dev stand. Pick another lane. This prohibition is already stated in the project `Makefile`, its `AGENTS.md`, and its port preflight; it is repeated here because the evaluator is the most likely agent to meet a busy port.

Shut the stand down when the evaluation ends, including on failure.

## Driving the browser

Use `chrome-devtools-axi`, a CLI, so this works from any harness with no MCP account binding.
Isolate every evaluator with its own session: `CHROME_DEVTOOLS_AXI_SESSION=eval-<task-id>`, so parallel evaluations never share a browser.
Consult `chrome-devtools-axi --help` for current commands rather than trusting remembered flags.

The loop, per surface under test:

1. `open <url>` the page the task touched.
2. `snapshot` to get the interactive elements and their uids - this is what makes the pass adaptive rather than a fixed script.
3. For **every element the task added or changed**: `click` / `fill` / `press` it and observe what actually happened. A button that produces no navigation, no request, and no state change is a defect regardless of how it looks.
4. `console` and `network` after the interactions - a clean-looking page throwing a `TypeError` on click, or firing a request that 404s, fails.
5. `screenshot` the surface at desktop width, then `resize` to 375px and screenshot again.

Study the screenshots before writing a verdict. The point of this gate is that someone looks at the page; producing a verdict without having looked reproduces exactly the failure it exists to prevent.

## Criteria

This table is the owner of what blocks. A finding in any row is blocking.

| Criterion | Blocking failure |
|---|---|
| Functionality | An element does not do what it promises: a click with no effect, a form that does not submit, a control that changes nothing, a link to nowhere. |
| Console and network | Any console error, or any failed request, during an ordinary user path. |
| Mobile | Horizontal scroll, overlap, clipped text, or an unreachable control at 375px. |
| Design system | A new colour, shadow, or button style invented where the project already has a token or class for it; a broken CTA hierarchy. |

The design-system row is judged against the project's own documented invariants, not against taste - read the project's `AGENTS.md` before scoring it.
In `parlino` those are concrete and checkable: exactly one `.btn-accent` on the page, `.btn-lime` reserved for the demo call, `--text-graphite` and `--shadow-float` tokens, the bento grid tiling 4x3 with no holes, glass panels over the gradient rather than flat white, page height constant at rest, one shared `LandingModal`, illustrations as inline SVG in the page palette.

Report anything that is merely an opinion separately and mark it non-blocking. The gate is for defects, not preferences.

## Findings

Write `data/<task-id>/evaluation-<round>.md`, and keep it specific enough to act on without re-deriving anything:

- The verdict: `pass` or `fail`.
- One entry per finding: what was interacted with, what was expected, what actually happened, which criterion it violates, and the screenshot path.
- Absolute paths to every screenshot taken.
- Non-blocking observations in their own clearly marked section.

"Some buttons seem broken" is not a finding. "Clicked `Запустить пилот` in the pricing card (uid 42): expected the pilot form to open, nothing happened, no console output, no request; screenshot at /abs/path.png" is.

The file is the handoff. Close with a status line pointing at it so the parent is woken.

## The loop

Evaluate -> relay findings to the generator -> generator fixes, re-runs `/simplify` and the test gate -> evaluate again.

**Three rounds maximum.** If the verdict is still `fail` after the third, stop and report to the captain with what remains and why it did not converge, per `AGENTS.md` section 9. Do not keep spawning rounds; a defect that survives three targeted attempts needs a human decision, not a fourth attempt.

A `fail` verdict blocks landing. Work does not merge onward while an unresolved blocking finding stands.
