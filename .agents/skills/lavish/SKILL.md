---
name: lavish
description: >-
  Agent-only reference for delivering a Lavish visual report or review board.
  Load whenever the captain or a task asks for Lavish, a Lavish report, or a review board built with Lavish, including a plain /lavish request, and before firstmate itself builds any one-off visual review surface for the captain.
  Owns the real lavish-axi delivery path - HTML under .lavish/, lavish-axi to open the session, and bin/fm-procevent-lavish.sh arming for feedback - as the only way to deliver Lavish work, and forbids substituting a Claude artifact, a claude.ai artifact link, or any other artifact host.
user-invocable: true
metadata:
  internal: true
---

# lavish

Load this whenever the captain or a task asks for Lavish, a Lavish report, or a visual review board using Lavish, including a plain `/lavish` request.

## Hard rule

Never deliver a Claude artifact, a claude.ai artifact URL, or any other non-`lavish-axi` hosting surface as a substitute for Lavish.
A Lavish ask is an ask for the captain's real annotate-and-poll review surface, not for any HTML page; only `lavish-axi` produces that surface.

## One-owner boundary

- `bearings` owns the fleet board (`/bearings lavish`): its stable board path, `fm-bearings-board.v1` payload, and template belong there alone, so load it instead when the ask is the fleet board specifically.
- `process-event-sources` owns the generic arm, wake, and handled-acknowledgement contract for every process-event source, Lavish included; this skill only says when and how to build, open, and arm a Lavish surface, and never restates that contract.
- `captain-hold-lifecycle` owns closing out any captain decision a review exposes; load it before treating a Lavish review as complete.
- This skill owns everything else: a one-off report or review board for a scout or firstmate, a single decision surface, or a task's own visual iteration loop.

## Procedure

1. Write the HTML under `.lavish/` - `$FM_HOME/.lavish/` for fleet-level material, or a task-scoped path inside that task's own worktree for task-specific work - never as a Claude artifact or any other host.
2. Before writing HTML, consult `lavish-axi help`, `lavish-axi design`, and `lavish-axi playbook <playbook_id>` for the design-system and content-shape guidance those commands give: design routes to the reviewed subject's own design system first and falls back to the CDN Tailwind/DaisyUI baseline only once that yields nothing, while a playbook matches the artifact's actual shape (diagram, table, comparison, plan, code, input, slides).
3. Open the review with `lavish-axi <html-file>`, passing `--reopen` only when the captain asks for further review after ending a session, never to reopen uninvited.
4. When the captain should be able to answer inside the board rather than in chat - a decision, a choice card, structured feedback - arm feedback for the fleet instead of a live foreground poll:
   ```sh
   bin/fm-procevent-lavish.sh arm <html-file>
   ```
   Bind a source that will carry captain-held answers before arming it, per `process-event-sources`.
5. Never run `lavish-axi poll` yourself in a conversational turn; it blocks that turn exactly like any other process-event source's blocking command, and only the armed source's supervised runner should own that wait.
   The one exception is a live investigating scout explicitly authorized to host its own Lavish review loop directly with the captain; that authorization is the worker's own conversational turn, never firstmate's.

## When Lavish is unavailable

An absent or below-floor `lavish-axi` is `bootstrap-diagnostics`'s `PRESENTATION_UNAVAILABLE` case: follow its response and continue nonvisual work with plain text.
Do not substitute another artifact host for the missing tool.
