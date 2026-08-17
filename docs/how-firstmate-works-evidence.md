# How Firstmate works evidence

This note records the principal tracked sources and repeatable validation for [`how-firstmate-works.html`](how-firstmate-works.html).

## Audience and ownership

- The HTML page is a public plain-English map of current behaviour, known limits, and a separately labelled possible enhancement.
- Exact mechanics remain owned by script headers, current command help, tests, and the authoritative documents linked from the page.
- This note is maintainer-verification evidence and contains no task chronology, live home data, credentials, private message bodies, or machine-specific paths.

## Principal authoritative sources

- [`README.md`](../README.md) owns the public product model, supported primary harnesses, visible crew, task shapes, delivery modes, and high-level topology.
- [`docs/architecture.md`](architecture.md) owns supervision, worktree isolation, current-state reconciliation, Second Mate behaviour, delivery modes, and restart-proof design.
- [`docs/configuration.md`](configuration.md) owns the operational-home layout, harness and backend selection, inherited configuration, and Second Mate registry format.
- [`bin/fm-session-start.sh`](../bin/fm-session-start.sh), [`bin/fm-startup-network.sh`](../bin/fm-startup-network.sh), [`bin/fm-wake-drain.sh`](../bin/fm-wake-drain.sh), and [`bin/fm-watch.sh`](../bin/fm-watch.sh) own session-start ordering and the durable supervision loop.
- [`bin/fm-crew-state.sh`](../bin/fm-crew-state.sh) owns current task-state reconciliation, while append-only status files remain notification history.
- [`bin/fm-brief.sh`](../bin/fm-brief.sh), [`bin/fm-spawn.sh`](../bin/fm-spawn.sh), [`bin/fm-send.sh`](../bin/fm-send.sh), [`bin/fm-control.sh`](../bin/fm-control.sh), and [`bin/fm-teardown.sh`](../bin/fm-teardown.sh) own the worker lifecycle mechanics.
- [`docs/turnend-guard.md`](turnend-guard.md), [`docs/arm-pretool-check.md`](arm-pretool-check.md), [`docs/cd-guard.md`](cd-guard.md), and the tracked harness hook files own the structural hook boundaries.
- [`docs/decision-hold-lifecycle.md`](decision-hold-lifecycle.md) and [`bin/fm-decision-hold.sh`](../bin/fm-decision-hold.sh) own durable unresolved-decision handling.
- [`docs/remote-secondmates.md`](remote-secondmates.md), [`bin/fm-home-seed.sh`](../bin/fm-home-seed.sh), and [`bin/fm-backlog-handoff.sh`](../bin/fm-backlog-handoff.sh) own persistent local and remote Second Mate operations.
- [`docs/herdr-backend.md`](herdr-backend.md) owns the distinction between the Herdr runtime backend and optional presentation Spaces.
- [`docs/calm.md`](calm.md), [`docs/calm-mode-feasibility.md`](calm-mode-feasibility.md), and [`.codex/hooks.json`](../.codex/hooks.json) support the Pi-specific Calm boundary and the absence of a tracked Codex transcript-rendering layer.

## Validation performed

Validation was performed on 2026-08-17.

- `bin/fm-doc-audience-check.sh` passed with 69 classified surfaces and 278 resolved maintained-prose links.
- `bin/fm-test-run.sh tests/fm-documentation-audiences.test.sh` passed its four checks with no failed or skipped tests.
- A Python `HTMLParser` audit found 33 unique authored identifiers, 22 matched `details` and `summary` pairs, 75 resolved local targets, and 13 resolved Markdown anchors.
- `chrome-devtools-axi` rendered all three Mermaid diagrams with accessible titles and no console errors at 1440 by 900 and emulated 390 by 844 viewports.
- Browser geometry checks found no document-level horizontal overflow at either viewport, with wide tables contained by their labelled scroll regions.
- Keyboard checks confirmed that the first Tab reaches the skip link, Enter moves focus to the main content, Open technical evidence opens all 22 expanders, and Close expanders closes all 22.
- A mobile Lighthouse snapshot scored 100 for accessibility and 100 for best practices.
- A headless Chrome print-to-PDF check produced tagged A4 output, included normally collapsed evidence, retained the diagram accessibility titles, and omitted screen-only controls.
- `git diff --cached --check` reported no whitespace errors before the evidence note was updated, and the same check was repeated on the final staged diff.
