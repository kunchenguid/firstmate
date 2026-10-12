---
name: pulse-page
description: Publish a rich, reviewable Pulse page (served by Pulse at localhost:31337/<tag>/) — plan, report, comparison, diagram, table, code diff, or any decision the captain should see visually rather than as prose. This is an alias for the `lavish` skill; it runs the exact same Pulse-page workflow. Use when the captain says "pulse page", "make a pulse page", or asks for a visual page to review.
argument-hint: <what the page should show>
metadata:
  hermes:
    tags: [pulse, parlay, page, review, artifacts, visualization]
    category: productivity
---

# Pulse Page → alias for `lavish`

Publishing a Pulse review page IS the `lavish` skill. Do not reimplement it here.

**Invoke `Skill("lavish")` now and follow it**, passing along whatever the captain asked to show. In short, `lavish` writes the HTML to `~/pulse-pages/<tag>/index.html`, served by Pulse at `http://localhost:31337/<tag>/`, and reports it back to the captain as `macbook:31337/<tag>/` for phone review in the panel.

## Request

$ARGUMENTS
