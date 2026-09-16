---
name: calm
description: >-
  Toggle Firstmate Calm presentation for this home when the captain invokes /calm
  or asks to turn Calm on or off.
  It writes the shared home-local config/calm preference and, on Cursor, applies
  quieter operational chatter while keeping genuine captain prompts and final replies.
user-invocable: true
metadata:
  internal: true
---

# calm

Toggle Firstmate's home-local Calm preference, the same `config/calm` file Pi and Claude Code use.
[`docs/configuration.md`](../../../docs/configuration.md#calm-preference-configcalm) owns the file and values.
[`docs/calm.md`](../../../docs/calm.md) owns the captain-facing contract, including what Cursor can and cannot present.

Ignore extra `/calm` arguments.
There is no on/off subcommand; each invocation flips the stored choice.

## What to do

1. From this repository root, run `bin/fm-calm-preference.sh toggle`.
   Persist happens before you change anything else.
   If the command exits nonzero, leave the current choice unchanged and say that Calm could not be saved.
   Do not claim the other state.
2. The command prints `on` or `off` on success.
   Tell the captain that result in one short sentence.
3. If the new state is `on`, run `bin/fm-calm-preference.sh context` and follow that policy for the rest of this session.
   If the new state is `off`, stop applying that policy and resume ordinary replies.

## Cursor honesty

Cursor has no Pi-equivalent transcript filter, tool-shell override, or working-ship widget.
Do not hide, collapse, or claim to hide tool rows in the Cursor TUI.
Do not draw, animate, or describe a boat in place of the working indicator.
The supported Cursor surface is this preference plus quieter replies: keep genuine captain prompts and your final answers, and skip tool narration, mid-turn working notes, and Firstmate operational chatter.
Keep using tools.
Do not change delivery, tool execution, model context, session storage, or export behavior.

On Pi, `/calm` is the native extension command and owns live TUI presentation.
On Claude Code, the `firstmate-calm` mod owns live TUI presentation when its opt-in flag is on.
This skill still toggles the shared file on those harnesses; it does not replace their adapters.

This preference is home-local and is not inherited by secondmate homes.
