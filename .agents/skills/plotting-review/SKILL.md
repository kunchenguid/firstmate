---
name: plotting-review
description: >-
  Agent-only procedure for explicit plotting architecture reviews and audits, or investigations where plotting ownership and compatibility are central.
  Do not load for ordinary feature work merely because it draws a chart.
metadata:
  internal: true
---

# plotting-review

Use this skill to establish the observable contract of Matplotlib- or seaborn-style plotting code before recommending or reviewing changes.
Keep project-specific paths, APIs, palettes, and migration decisions in the task report rather than promoting them into this procedure.

## Establish the public contract

Inspect current source, exports, signatures, annotations, documented call forms, and runtime return values.
Find direct and indirect callers in tests, examples, notebooks, and documentation, including callers that ignore a return or rely on positional arguments.
Record whether an omitted axes argument creates a figure, reuses the current axes, or follows another fallback.
When an axes is supplied, prove whether the exact object is targeted with an identity assertion, not merely an equivalent figure or axes count.

Inventory resource ownership and side effects separately:

- Which layer creates each figure and axes, and which object becomes current.
- Whether the renderer shows, saves, closes, resizes, or applies figure-level layout.
- Whether those actions affect only renderer-created resources or also caller-owned figures.
- Whether colorbars, legends, twins, insets, or faceting create additional axes.
- Every process-global style change, including the complete `matplotlib.rcParams` diff rather than a few expected keys.

Treat explicit axes composition, implicit pyplot state, and newly created figures as distinct runtime paths.
Treat return identity and figure ownership as public behavior even when neither is documented.

## Gather runtime evidence

Use a non-interactive backend selected before importing `pyplot`.
Probe representative fresh-state, caller-current-axes, and explicit-axes calls where the public surface permits them.
Snapshot managed figure numbers, current figure and current axes identities, full `rcParams`, renderer returns, figure axes lists, and patched show, save, and close calls before and after each call.
Draw the canvas before inspecting artist geometry.
Read [references/runtime-probe.md](references/runtime-probe.md) when constructing the probe or translating it into tests.

Inspect artists at the level that represents user-visible behavior.
Depending on the plot, assert line data, image or collection arrays, normalization, labels, titles, ticks, legends, annotations, colorbars, and axes counts instead of relying on a no-exception smoke test.
For annotations, check rendered bounds at representative small and dense sizes and verify foreground-to-background contrast from rendered or mapped colors.
Use image comparison only when artist and geometry assertions cannot express the contract reliably, and control backend, fonts, dimensions, and tolerances when doing so.

Close only resources the probe or test owns, preferably in guaranteed cleanup.
Never infer that a renderer owns a caller-provided figure merely because it mutated that figure.

## Inspect notebooks and documentation safely

Search notebook code and Markdown through structured extraction, for example:

```sh
jq -r '.cells[] | select(.cell_type == "code" or .cell_type == "markdown") | .source | if type == "array" then .[] else . end' example.ipynb | rg -n 'plot|show|savefig|Axes'
```

Adjust the targeted terms to the project and inspect only the relevant extracted cells.
Never dump raw notebook ranges because embedded image payloads can overwhelm output and conceal the caller evidence.
Treat saved notebook output as illustrative evidence unless execution proves the current behavior.
Inspect hand-authored documentation, generated API documentation and its source, examples, and release notes for signature, return, lifecycle, and display expectations.

## Establish compatibility intent

Inspect blame and focused history for the public surface, its tests, examples, and documentation.
Treat closed branches and unmerged pull requests as design precedent, not current behavior.
Inspect later split or narrower work before inferring that a broader design was rejected.
Distinguish intentional compatibility from accidental behavior, but report observable accidental behavior as a risk until an authorized change resolves it.

## Report and recommend

Label observed facts separately from inference.
Record the exact revision inspected, relevant environment and dependency versions, commands with outcomes, and untested boundaries.
State public compatibility risks explicitly, including signatures, positional and keyword calls, returns, axes identity and fallback, figure lifecycle, global state, artist structure, notebook display, and documentation.
Recommend tests that preserve intended behavior and expose accidental coupling, with focused runtime tests before broader headless notebook or image checks.
Do not present a proposed architecture or historical prototype as current behavior.

Before completing the review, verify that the report answers these questions:

- Who owns every figure and axes, and what remains open after the call?
- Which exact axes receives every artist, including colorbars and auxiliary axes?
- What show, save, close, layout, and global-style effects occurred?
- What do existing callers observe from signatures, returns, pyplot state, artists, notebooks, and docs?
- Which claims are runtime-proven, inferred, historical, or still untested?
