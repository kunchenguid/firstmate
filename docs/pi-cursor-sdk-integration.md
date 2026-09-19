# Pi + pi-cursor-sdk integration

Firstmate can run Pi as the primary harness with `cursor/*` models through the [pi-cursor-sdk](https://www.npmjs.com/package/pi-cursor-sdk) bridge.
This document lists the integration problems that stock Firstmate + upstream Pi extensions do not solve alone, and the tracked code in this repository that closes those gaps.

After any change under `.pi/extensions/`, fully quit and restart Pi.

## Profile

- Primary harness: Pi (`pi` or `pi-signed`).
- Model provider: Cursor (`cursor/*` models via pi-cursor-sdk).
- Calm: optional but commonly on for supervision-heavy homes.

## What upstream already covers without this change set

When this integration lands in `main`, do not duplicate:

- Calm substantive mid-turn preservation on stock layout (`fm-calm-preservation.ts`): hide only short single-line working notes; preserve blocks with a newline or at least 240 trimmed characters (`docs/calm.md`).
- Supervision branch framework and branch session lifecycle (`fm-branch-supervision.ts` before the Cursor loader hook).
- Pi watcher extension shell and generation-scoped supervision continuity (`fm-primary-pi-watch.ts` baseline).

This change set adds pi-cursor-sdk-specific glue on top of that floor.

## Issue catalog

### 1. Calm hides captain recaps (flash then blank)

**Symptom:** Calm on → answers flash then vanish; Calm off → the same text stays.

**Cause:** Pi leaves the real answer tagged mid-turn (`stopReason: toolUse`).
pi-cursor-sdk adds empty, tools-only, or incomplete replay rows after it.
Stock Calm layout (`fm-calm-assistant-layout.ts`) applies substantive preservation but does not model replay successor noise or guarantee visibility for **short** final recaps under pi-cursor-sdk.

**Fix:**

- `lib/fm-pi-cursor-calm-assistant-layout.ts` — successor-aware hide rules; ignore replay noise; keep the last tools-tagged recap visible.
- `lib/fm-pi-cursor-calm-operational-user-layout.ts` — operational user rows across turns.
- `fm-calm.ts` selects these layouts when pi-cursor-sdk integration is active.

### 2. Calm vs pi-cursor-sdk tool registration order

**Symptom:** Missing or wrong tools; broken session after Calm and the bridge both register built-ins.

**Cause:** Calm registers read/bash/edit/… before pi-cursor-sdk claims the Cursor tool plane.

**Fix:**

- `.pi/extensions/fm-0-pi-cursor-sdk-integration.ts` loads **before** `fm-calm.ts` (the `fm-0-` prefix enforces sort order).
- Prevents built-in collisions; strips bridge lifecycle noise from thinking; Calm presentation tweaks for replay rows.
- Wraps replay execute together with fail-close in the turn-end guard.

Fully quit Pi once after upgrading from a poisoned session where Calm won the registration race.

### 3. Hung Cursor replay tools

**Symptom:** Pi stalls after a `cursor-replay-*` tool never records completion; Calm boat or turn-end guard wedge until Esc.

**Fix:**

- `lib/fm-cursor-replay-execute.ts` fail-closes missing replay completion and releases the SDK live-run waiter.
- Wired from `fm-0-pi-cursor-sdk-integration.ts` and `fm-primary-turnend-guard.ts`.

### 4. Supervision branch missing Cursor bridge

**Symptom:** Branch on `cursor/*` fails with missing API key; branch breaks; wakes fall back to main.

**Cause:** Branch keeps `noExtensions: true` but Cursor models still require pi-cursor-sdk.

**Fix:**

- `lib/fm-branch-cursor-sdk-loader.ts` resolves the installed pi-cursor-sdk package and adds **only** that path via `additionalExtensionPaths`.
- `fm-branch-supervision.ts` imports the loader and re-selects the branch model after providers register.

See `docs/configuration.md` and `docs/pi-supervision-branch.md`.

### 5. Post-spawn dispatch-return and stuck primary

**Symptom:** After spawning a worker in the same Pi session generation, the primary should arm supervision and end the turn without a redundant model pass; when that fails, the primary can stall with queued input while work is in flight.

**Fix:**

- `bin/fm-spawn.sh` writes `state/.dispatch-return` (`<pi-watch-generation>\\t<task-id>`) when spawn succeeds.
- `fm-primary-pi-watch.ts` consumes the marker for generation-scoped `fm_watch_arm_pi` terminate behavior.
- `lib/fm-primary-stuck-primary.ts` recovers a stalled primary after dispatch-return when terminate did not end the turn.

## Calm recap mechanism (issue 1, technical)

| Layer | Mid-turn hide rule |
|-------|-------------------|
| Stock layout | Hide mid-turn text only when **not** substantive (no newline and under 240 trimmed chars) |
| pi-cursor-sdk layout (`fm-pi-cursor-calm-*`) | Hide mid-turn text only when superseded by later **real** visible text; replay noise does not count |

Presentation-only: stored messages unchanged.

## Regression tests

- `tests/fm-calm-pi-extension.test.sh`
- `tests/fm-0-pi-cursor-sdk-integration.test.sh`
- `tests/fm-pi-branch-extension.test.sh`
- `tests/fm-cursor-replay-execute.test.sh`
- `tests/fm-pi-dispatch-return-e2e.test.sh`
- `tests/fm-pi-stuck-primary-e2e.test.sh`
- `tests/fm-pi-watch-extension.test.sh`
- `tests/fm-primary-stuck-primary.test.sh`

## Operator notes

- On `cursor/*` models, fleet shell commands run through Cursor Shell, not Pi bash; use absolute paths to `bin/fm-*`.
- macOS `EXC_GUARD` after long idle or heavy bridge use is a pi-cursor-sdk platform limit; restart Pi.

## Related docs

- `docs/calm.md` — Calm behavior and pi-cursor-sdk recap pointer.
- `docs/supervision-protocols/pi.md` — watcher, dispatch-return, and stuck-primary protocol.
