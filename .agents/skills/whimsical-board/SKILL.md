---
name: whimsical-board
description: Load before creating or revising a Whimsical board.
user-invocable: false
metadata:
  internal: true
---

# whimsical-board

Load this before creating or revising a Whimsical board.
This skill owns readability layout for that board.
It is not an architecture-writing guide or a security policy.

Edit a board only with explicit authorization, through the authenticated Whimsical UI.
Never use unauthenticated creation endpoints.

## Sections and layout

Organize the board into ordered, clearly titled bands.
Give each band a one-line purpose.
Add Present-mode sections in that same order so the board can be navigated section by section.
Keep each diagram compact, and keep diagrams separate from each other.
Recreate tabular content as native tables.
Use consistent spacing and a restrained legend.
Put citations in a companion table rather than in diagram labels.

## Final inspection

Visually inspect the finished board for overlaps, cramped labels, and readability at typical view sizes.
Sequence-participant colors may remain automatic.
State-diagram labels may still need spacing adjustments.
