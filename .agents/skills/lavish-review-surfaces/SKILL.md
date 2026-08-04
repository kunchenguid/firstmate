---
name: lavish-review-surfaces
description: >-
  Agent-only policy for Firstmate Lavish review artifacts.
  Load before creating, commissioning, or materially revising a Lavish review surface so the review foregrounds the real subject instead of replacing it with a summary-only report.
user-invocable: false
metadata:
  internal: true
---

# lavish-review-surfaces

This skill is the single owner of Firstmate's subject-first contract for Lavish review surfaces.
The installed `lavish-axi --help`, `lavish-axi design`, and matching `lavish-axi playbook ...` output remain authoritative for tool mechanics, visual guidance, polling behavior, supported playbooks, and design-system selection.
Use those current tool instructions instead of building a competing artifact system or memorizing old flags.
Generated secondmate, scout, and worker briefs must point agents here before Lavish review work; `tests/fm-brief.test.sh` covers that routing.

## Core contract

A Lavish review primarily presents the completed work or real subject being reviewed.
It is not primarily a newly designed summary about that work unless no underlying artifact or experiential surface exists.
Reports, rationale, decisions, risks, and meta commentary may frame the surface above or below the subject.
They must not replace the subject or make the subject secondary to commentary.

Identify the concrete subject before writing the artifact.
Place that subject where the captain can annotate it directly, preferably near the top and at the largest useful scale.
Use prose only for context, interpretation, tradeoffs, open questions, and limitations that cannot be shown.
When the only viable artifact is summary-only, state in the artifact why no underlying artifact or experiential surface exists.

## Frontend and user-experience work

Frontend work must show faithful captures of the actual developed page.
Run the app read-only when needed and capture the page the captain would review, rather than describing the current look in prose.
Use real screenshots or video for user-visible failures when they are available.
If direct capture is impossible, include an explicitly labeled faithful recreation and state why direct capture was impossible.

When the frontend has both desktop and mobile presentations, include both as annotatable surfaces.
Use dimensions that represent how users actually encounter the page, and label the capture context only enough to make annotation reliable.
A mockup, design sketch, or reconstructed layout can accompany the captures, but it cannot stand in for them unless it is explicitly labeled as the fallback above.

A faithful screenshot or rendered subject is insufficient when the reviewer can select only the whole image or surrounding report chrome.
Expose meaningful product controls and regions as individually selectable annotation targets while preserving faithful desktop and mobile presentations.
Representative frontend targets include navigation, OAuth or sign-in controls, search and action controls, headings, cards, modules, charts, tables, and error states.
Each target must align semantically and geometrically with the visible product element.
Invisible, misleading, duplicate, report-shell-only, or whole-screenshot-only hotspots do not satisfy the review contract.
Prefer live or faithfully rendered DOM for the subject when practical.
When a bitmap capture is the only faithful base, add visible semantic regions or SVG/HTML target shapes that track the real component bounds and make clear what element will be annotated.
Native controls stay interactive in Lavish, so preserve their behavior and make the surrounding visible control region or module annotatable when the control itself cannot receive an annotation click.

## Code, document, data, and other work

Non-frontend work must foreground the real reviewable evidence appropriate to the work.
For code, show the actual diff, before-and-after code, PR diff, or failing trace that proves the change or defect.
For documents, show the rendered document or the changed sections in their rendered form when rendering is the user-facing artifact.
For data and spreadsheets, show the actual table, computed output, chart, formula evidence, or failure result that the decision depends on.
For diagrams and architecture, show the diagram or model being reviewed, not just a prose description of it.
For operational failures, show the concrete error surface, transcript excerpt, log evidence, screenshot, or faithful recreation the operator would encounter.
Other artifact types must expose the meaningful underlying units where Lavish or the chosen review tool permits it, such as document sections, spreadsheet regions, diagram nodes, code hunks, or evidence findings.

Choose the matching Lavish playbooks after identifying the subject.
The `code`, `table`, `diagram`, `comparison`, `plan`, `input`, and `slides` playbooks are presentation aids for the subject, not replacements for it.

## Delivery check

Before opening the Lavish review, ask whether the artifact lets the captain annotate the thing they actually care about.
If the answer is no, replace or restructure the artifact before presenting it.
If the artifact remains summary-only, the artifact itself must say why that is the only available surface.
For frontend review surfaces with desktop and mobile presentations, validate that at least one meaningful target in each presentation can be selected and queued as feedback.
For other review surfaces, validate a representative underlying unit when the tool permits it.
Rendering overlays alone is not proof; confirm the annotation card or comment enters the review queue through the real interaction path.
