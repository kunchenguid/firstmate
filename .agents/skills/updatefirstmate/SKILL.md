---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from origin.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Applies each target home's explicit self-update policy, then re-reads AGENTS.md and nudges each updated secondmate to do the same; absent/default remains guarded fast-forward-only, while a per-home remote-authoritative opt-in may replace that home's tracked Firstmate code after a verified fetch.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running firstmate pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate and every secondmate under each exact target home's independent policy.

The absent/default policy is the historical guarded fast-forward: dirty, diverged, offline, or wrong-branch targets are skipped and reported unchanged.
A home may independently select the explicit remote-authoritative policy, which can replace that home's dirty or diverged tracked Firstmate code only after its origin/default commit is fetched and verified.
[`docs/configuration.md`](../../../docs/configuration.md#self-update-policy-configself-update-policy) is the single owner of accepted values, per-home scope, discard authority, private-path preservation, and failure behavior.
For a remote route, the configured code root and persistent home resolve their own policies independently.
This touches only Firstmate code roots and homes, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It updates this firstmate repo from origin, then updates every registered local or remote secondmate home through its placement-specific policy path.
   It prints one status line per target (`updated <old>..<new>` / `replaced <old>..<new> ... (remote-authoritative)` / `already current` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `nudge-secondmates: fm-<id>...|none`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just updated under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a symlink to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-firstmate: no`, nothing changed for you - skip the re-read.

3. **Nudge each updated live secondmate.**
   For every target listed on the `nudge-secondmates:` line (do nothing when it says `none`), send a one-line re-read nudge so that secondmate picks up its new instructions too:
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   Include `FM_HOME=<this-firstmate-home>` unless `FM_HOME` is already set to the active firstmate home.
   This is a gentle steer, not an interruption: the secondmate's selected update already completed, and the nudge performs no repository operation.
   A secondmate that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

4. **Report to the captain in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without firstmate's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Captain, firstmate and both second mates are now on the latest."
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Per-home authority.**
  Absent/default is fast-forward-only, and one home's remote-authoritative opt-in never applies to another target.
  Treat a `replaced ... (remote-authoritative)` status as an intentional result of that exact home's local policy, not as authority to change another home.
- **Private surfaces remain private.**
  Both policies leave ignored operational material intact and never touch `projects/`; the configuration owner defines the complete guarantee.
- **Failures stop that target.**
  A skipped target remains unchanged and is reported with its concrete reason rather than retried through another policy.
