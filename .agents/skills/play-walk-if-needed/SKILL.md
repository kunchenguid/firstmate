---
name: play-walk-if-needed
description: >-
  Play: walk the system only when the change crosses into unfamiliar areas or shared boundaries, and otherwise write one line saying why you skipped the walk.
  Loaded only when the task brief names it.
user-invocable: false
metadata:
  internal: true
---

# Walk if needed

Before changing code, decide whether the change crosses into unfamiliar territory or a shared boundary.
Run the walk when it does: an area you have not read in this task, an interface other code depends on, a data flow that spans modules, or a diagnosis whose cause is not yet isolated.
The walk is a read of the real code along the affected path: entry point to effect, actual call sites, and the non-obvious bits a newcomer would get wrong.
Trace it far enough to place the change correctly and name what it touches; you are building a working mental model, not annotating source.
Read the code itself, never file names alone.

When the change does not cross into unfamiliar or shared territory, skip the walk.
A skip is never silent: write one line saying why, such as an ordinary local edit in a file this task already covers, then move on.
Do not turn every change into a research program, and do not skip silently.