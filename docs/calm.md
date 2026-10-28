# Calm mode

Calm is Firstmate's conversation-only transcript presentation toggle.
This page is for operators who turn Calm on and need to know what it hides and keeps visible on Pi and on Claude Code, and which file owns each part of that behavior.

## Harness support and default

| Harness | Support |
| --- | --- |
| Pi | Fully supported. |
| Claude Code | Available behind that harness's default-off early-access function-hooks flag, as the [Claude Code](#claude-code) section below describes. |

Calm is off by default.
The last `/calm` choice persists for the effective Firstmate home across session starts and resumes on either harness.
Both harnesses keep that choice in the one shared preference file that [`configuration.md`](configuration.md#calm-preference-configcalm) owns.

## Shared preservation rule for assistant text

Across both harnesses, Calm evaluates each settled assistant text block from a model step that stopped to call tools, or that exhausted its token limit while carrying tool calls.
Calm hides such a block only in the first case below:

| Settled block | Result |
| --- | --- |
| Raw text contains no newline, and trimmed length is below `CALM_PRESERVE_MIN_CHARS` (240) | Hidden. |
| Raw text contains a newline, or trimmed length is at least 240 | Preserved as substantive captain-facing content. |

Streaming text and the genuine reply that ends a response remain visible.

## Pi

### Working boat

While Calm is active and an agent run is under way, Calm hides Pi's built-in `Working...` row and shows a small two-row animated boat in its place.
No separate Calm status row is added.
The boat claims the same Pi working-row widget slot as the standalone Pi Calm extension, so a session that loads both Calms shows one boat rather than two, and turning Firstmate Calm off does not clear the standalone boat.
While Calm is off, Pi's stock working row is left exactly as Pi renders it.

The boat looks like this:

- The water fills the usable width with low one-cell Unicode bars, all in standard ANSI blue, so the swell shows through bar height alone.
- The asymmetric three-cell `◿│◣` sail is centered over the five-cell `╲▁▁▁╱` hull.
- The whole boat is one standard ANSI yellow, including both sail halves, the mast, and the hull.
- The hull's zero-height interior keeps the swell continuous beneath the boat.
- Very narrow terminals fall back to a smaller deterministic sprite.

### Boat motion

The boat is deliberately calm.
It moves one column every 880ms.
The long smooth wave advances one quarter-cell every 220ms, so the surface stays alive between boat steps.
Deterministically varied half-waves stay between nine and thirteen cells.
The boat remains phase-locked inside a broad zero-height trough through movement and edge reversals.
Every resize reflows the sprite without wrapping.
The boat disappears when the run settles, aborts, or fails.

### Boat position between working periods

Within one Pi session and Calm extension lifetime, the next working period resumes the boat from its last rendered column and travel direction rather than restarting at the left edge.
Hidden elapsed time does not advance the animation.
A resize while hidden clamps the frozen boat to the new width without changing its valid travel direction.
A fresh Pi session or new Calm extension lifetime starts at the normal initial position.

### What Calm hides on Pi

Calm hides these rows:

- Collapsed thinking labels.
- The mid-turn assistant working-note blocks governed by the [shared preservation rule](#shared-preservation-rule-for-assistant-text) above.
- The shells for the Pi built-in tool names Calm owns.
- Firstmate-owned tool shells listed in the [Pi tool audit](calm-mode-feasibility.md#firstmate-pi-tool-audit).
- Canonically classified Firstmate operational user rows.

Pi applies the preservation rule independently to each text block.
A short working note can therefore hide beside preserved substantive content in the same message.
A working note is briefly visible while it streams, before its settled row collapses.

The narration is hidden only from the live transcript presentation.
It remains in the message, model context, session storage, and `/export` artifacts.

The operational inputs Calm classifies remain ordinary user-role messages.
Pi's transcript layout renders their complete rows at zero height.
The session-start nudge remains on its existing non-displayed custom-message path.

### Queued Firstmate inputs on Pi

While a turn runs, Calm also keeps those Firstmate inputs out of Pi's queued-message listing.
The captain's own queued messages stay listed.
Escape and the dequeue key return only the captain's queued messages to the editor.
Hidden Firstmate inputs stay queued in their original order and are never shown as raw text or dropped.
When Escape, or navigating the session tree, stops a run with Firstmate inputs still queued, Pi either drains them itself or Calm starts one new turn to deliver them.
When Calm starts that turn, it shows the one-line notice `Firstmate supervision continues in a new turn.`
Inputs held behind a running compaction stay there until Pi sends them after compaction, so they start and announce no turn of their own.

### What stays unchanged on Pi

Outside Pi's same-name built-in override collision described in [Pi compatibility](#pi-compatibility) below, Calm changes presentation only.
Calm's built-in wrappers preserve Pi's execution behavior.
Input delivery, ordering, model context, session storage, diagnostics, and `/export` and `/share` operation remain unchanged.
Every hidden Firstmate input remains available to the model and in serialized session data and exported artifacts.
Legacy operational custom messages remain in session data and Pi's sidebar tree; depending on the Pi version, the main HTML transcript either omits them or includes them as rows hidden by default.
Toggling Calm off restores ordinary rendering, and `Ctrl+O` expansion state is preserved.

### What stays visible on Pi

Pi's supported presentation API does not expose a global transcript filter.
These rows remain visible:

- Expanded reasoning and its reserved spacing.
- Built-in tool images.
- User-bash rows.
- Skill and summary rows.
- Generic status notices.
- Other arbitrary custom-tool or extension rows.

These are supported-API boundaries rather than hidden-content failures.

## Pi compatibility

### Pi versions and missing API seams

Calm has no numeric Pi version minimum or maximum.
It never refuses Pi solely because its version is newer than a previously verified version.

When Calm loads, the collapsed-thinking, operational-user-row, and queued-operational-row presentation adapters probe the exact Pi API seam they patch.
If Pi removes one of those seams, Calm logs a diagnostic naming the unavailable adapter and skips only that adapter.
`/calm`, the other adapters, and unrelated Pi extensions remain available.

### Session check for queued inputs

Keeping hidden queued inputs across Escape also needs members of Pi's live session, which exist only once a session runs.
Calm checks them for each session on its first queued-listing draw, before hiding anything.
A session missing any of them keeps its queued rows and Escape exactly as stock, and shows one warning.
In that case `tests/fm-calm-pi-queue-retention-live-e2e.test.sh` fails naming the installed Pi version.

### Built-in tool override collisions

Calm's built-in tool presentation (`bash`, `read`, `edit`, `write`, `grep`, `find`, `ls`) shares Pi's single, unmerged override slot per name with any other extension that overrides the same tool.
How Calm handles that shared slot depends on whether Calm was already on when the session started or reloaded.

**Session started with Calm off**

- While the persisted Calm preference is off, Calm registers none of those overrides and therefore contests no built-in tool name.
- The first time Calm turns on in a session that started off, it claims every built-in name no other extension already owns.
- It leaves every contested tool intact and callable, and displays a prominent warning naming the tools it skipped.
- Tool-call rows already on screen before that first toggle do not retroactively collapse.
- Later rows for the names Calm claimed use Calm presentation.

**Session started or reloaded with Calm already on**

- Calm must instead register all seven overrides synchronously so Pi can render restored rows with them.
- Pi provides no ownership check early enough for that load-time path, and the first registrant wins the complete tool definition.
- If the other extension wins, a session-start console diagnostic names the tool and winning extension.
- If Calm wins, Pi does not expose the losing registration, so the other extension's override is unavailable and cannot be named.

### Owning docs and files

- [`calm-mode-feasibility.md`](calm-mode-feasibility.md) owns the version-scoped renderer taxonomy, built-in override constraints, and empirical evidence.
- [`configuration.md`](configuration.md#calm-preference-configcalm) owns the persisted preference file and resolution rules.
- `.pi/extensions/lib/fm-calm-visibility.ts` owns the visibility policy.
- `.claude/mods/firstmate-calm/lib/fm-calm-preservation.ts` owns the shared substantive mid-turn text rule, which Pi imports through its tracked symlink.
- `.pi/extensions/lib/fm-calm-operational-user-layout.ts` owns the zero-height operational-user row adapter.
- `.pi/extensions/lib/fm-calm-pending-operational-layout.ts` owns the queued-row adapter and its session capability check.
- `.pi/extensions/lib/fm-calm-working-ship.ts` owns Pi's animated working presentation over the sprite geometry both harnesses share in `.claude/mods/firstmate-calm/lib/fm-calm-working-ship-sprite.ts`.

### Pi regression entry points

```sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-branch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-calm-pi-queue-retention-live-e2e.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```

## Claude Code

### The Calm mod

Calm on Claude Code is the mod under `.claude/mods/firstmate-calm`, whose plugin name is `fm`.
The mod is a Claude Code plugin whose whole behavior lives in one function-hooks module.
The trusted project auto-loads the mod through the `.claude/skills/firstmate-calm` entry (a symlink into `.claude/mods`), so no `--plugin-dir` or marketplace install is needed.

### Enabling function hooks

Claude Code's early-access function-hooks surface is off by default.
Claude Code can load modules through its rollout flag, or per session with `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`.
The mod independently requires that environment variable to equal `1` before doing anything.
Firstmate never sets that flag in any project or user settings.
Enabling it is each captain's own explicit opt-in.

Without that exact value, the mod is a complete no-op, even if Claude Code's rollout flag loads the module:

- There is no `/calm` command.
- The mod reads neither the preference nor the transcript.
- The mod runs no timer and writes no supervision note.
- Every drawing stays exactly as Claude Code draws it, whatever `config/calm` says.

### Toggling Calm on Claude Code

With the flag on, the mod registers `/calm`.
It toggles the same per-home preference Pi's `/calm` uses, so one choice applies on both harnesses.
The toggle answers with a transient "Calm on" or "Calm off" notice under the prompt rather than a transcript row.
A preference that cannot be written leaves the current choice unchanged, and the notice says so.
The mod reads the preference before the first row draws.
Toggling Calm redraws every hooked row already on screen, so rows drawn before the toggle hide or restore retroactively.

### Working sailboat on Claude Code

While Calm is on, the stock working row (`Sauteing... (12s · 300 tokens)`) becomes the same two-row sailboat Pi draws, from the same shared sprite geometry.
The sailboat fills the row inside the transcript margin.
It repaints on the boat's 220ms cadence, with the hull moving every 880ms.
It reflows on resize, and appears and disappears exactly where the stock row would.

On Claude Code the boat is painted in Claude Code's own theme colors rather than Pi's standard ANSI codes:

| Part | Color source | Dark theme | Light theme |
| --- | --- | --- | --- |
| Every water cell | Spinner blue of the active theme family | `#93a5ff` | `#5769f7` |
| The whole boat: both sail halves, mast, and hull | Claude orange of the stock spinner | `#d77757` | `#d77757` |

The theme family follows the `theme` setting by its prefix, `dark` or `light`, and is re-read when the theme changes.
It uses the light set as the both-readable fallback for `auto`, custom, missing, or unreadable values.
The Pi extension keeps its standard ANSI blue and yellow.

### Supervision notes on Claude Code

With the flag on, the mod shows the supervision notes Pi shows, whether Calm is on or off, because on Pi they are supervision UI rather than Calm UI.
Each note is appended to the transcript as its own system-notice row, which Claude Code draws in gray behind a `⏺` bullet and the plugin's name (`fm:`), which Claude Code adds to every mod's transcript line, and never sends to the model:

| Line | When |
| --- | --- |
| `⛵ <task>: <summary>` | The supervision session recorded a routine outcome that is not silent. |
| `⚓ [seq N] <task>: <summary>` | It recorded a captain outcome; main still receives and processes it as [`supervision-host.md`](supervision-host.md#captain-outcomes) describes. |
| `⛵ Supervision session paused after repeated engine errors; main will handle wakes while it cools down.` | The host's broken-session latch trips. |
| `⛵ Supervision session recovered after a successful cooldown probe.` | That latch clears. |

Silent routine outcomes show nothing.
The mod checks the outcome store's display tail copy and the host's latch file every 3 seconds, so a note can land a few seconds after its outcome.
On the first tail read in a session, it replays unprocessed captain outcomes and unread visible routine outcomes from the bounded copy, showing at most the newest 20 notes with a count of older due notes within that copy.
A home whose outcome store predates the copy gains one at its next locked session start, even while away; if the copy first appears after the mod starts, the replay still uses the read and processed markers captured when the session started.
On later reads, if the copy skips sequence numbers since the last seen outcome, one line counts the missing outcomes.
The display copy's row and byte bounds are owned by [`fm-branch-outcome.sh`](../bin/fm-branch-outcome.sh); older outcomes and oversized rows cannot always be displayed by the mod, while the outcome store and main's delivery remain authoritative.
Claude Code keeps each note in the session as a display-only entry and restores it on `claude --continue`, so the mod remembers in its own plugin store how far each session has followed the outcomes, and a resumed session replays only outcomes it has not shown.
Claude Code keys that store by plugin name, so a session that showed notes before the plugin was renamed from `firstmate-calm` to `fm` and is resumed afterwards replays its still-due notes once.
The mod only reads outcome and host state: the drain owns off-Pi read-cursor advancement, and main explicitly acknowledges captain outcomes as processed.
Only a home that runs the supervision host has outcomes to show.

### What Calm hides on Claude Code

Tool rows, tool result blocks, and folded tool groups draw at zero height, so a turn that used tools takes the same space as one that did not.

A user row draws at zero height when the canonical operational-input parser recognizes its text as one of these:

- A Firstmate session-start, watcher, turn-end guard, away-supervisor, launch-brief, or branch-outcome envelope.
- A from-firstmate routed message.
- One of the narrow pre-protocol shapes kept for old transcripts.

Other user rows, including near misses such as a quoted or ASCII-only marker, stay visible unless backed by an operational record as the next section describes.

Assistant text follows the [shared per-block preservation rule](#shared-preservation-rule-for-assistant-text) above, including when `claude --continue` restores the transcript.

### Record-backed operational doorbell

Claude Code removes the U+2063 that starts those envelopes from every submitted prompt.
Because of that, Firstmate delivers its away-mode escalations to a Claude Code primary as the record-backed doorbell `bin/fm-operational-input.sh` owns.
The doorbell is a plain line naming a record under the home's `state/operational-inbox` that holds the envelope.

Calm reads that record through the mod's file API and hides the doorbell row only when the record holds a current envelope.
A doorbell-shaped line naming no such record therefore stays visible.
A verbatim copy of a live doorbell line, pasted back while its record still exists, is treated as Firstmate's and hides.
Record verdicts are cached until a drawing invalidation (including a `/calm` toggle), which rechecks pruned records on redraw.

### What stays unchanged on Claude Code

Nothing is rewritten.
Hidden rows remain in the message, model context, session storage, and exports.
The mod never touches tool execution or prompts, and adds to the stored transcript only its display-only supervision notes.

### Claude Code support bounds

The bounds of the Claude Code support below are recorded with evidence in [`calm-mode-feasibility.md`](calm-mode-feasibility.md#2026-09-15-claude-code-21272-mods-feasibility-and-the-shipped-mod).
Evidence for 2.1.280 and the record-backed doorbell is also in its [2026-09-25 record](calm-mode-feasibility.md#2026-09-25-claude-code-21280-verification-and-the-record-backed-operational-doorbell) and [2.1.282 reproduction](calm-mode-feasibility.md#2026-09-25-claude-code-21282-reproduction-on-the-installed-build), and for the supervision notes in the [2.1.283 record](calm-mode-feasibility.md#2026-09-28-claude-code-21283-supervision-notes) and their label in the [2.1.284 record](calm-mode-feasibility.md#2026-09-28-claude-code-21284-supervision-note-label-and-the-fm-plugin-name).

- The function-hooks surface is early access and default-off.
  Claude Code states that its API may change between releases without notice.
  The mod is verified on Claude Code 2.1.272, 2.1.280, 2.1.282, 2.1.283, and 2.1.284 and refuses nothing newer.
- Firstmate's typed producers bound for a Claude Code pane ride the record-backed doorbell, so they hide like any operational row.
  Those producers are the away-mode daemon's escalations and a worker's launch brief.
  Only an envelope that reaches Claude Code some other way, as bare typed or launch-prompt text, arrives without its U+2063 and stays visible.
- Every record write prunes operational-inbox records once they reach about seven days of elapsed age (the boundary is approximate).
  Age alone does not remove a record without a later write.
  Once its record is gone, a doorbell is no longer recognized.
  It draws as a visible user row after Calm rechecks it (for example on `/calm` toggle or `claude --continue`), and `/ahoy` treats it as a captain boundary.
- On the main-screen layout (not the fullscreen alternate screen), a toggle redraws the live screen by clearing and reprinting it.
  The terminal's own scrollback keeps the earlier rendering above it.
  The fullscreen layout has no such stale copy.
- The sailboat is painted through Claude Code's Raster element, whose colors are RGB quantized to 256-color escapes rather than the standard 16-color ANSI codes Pi's widget emits.
- The detailed transcript view (`ctrl+o`) keeps its per-message timestamp and model headers where hidden assistant rows sat, because those headers are not a hookable drawing.
- Collapsed thinking never appears in Claude Code's default view.
- Supervision notes are system-notice rows rather than Pi's rendered entries: Claude Code draws them in one gray with its own bullet and the plugin's name, so the glyph cannot take its own color as on Pi.
- A captain outcome still wakes main through a `Stop hook feedback` row, which fires no hookable drawing, so its anchor line appears beside that row rather than replacing it.
- The mod has no thinking drawing to hide in other views.

### Claude Code regression entry points

```sh
tests/fm-calm-claude-mod.test.sh
tests/fm-calm-claude-mod-plugin.test.sh
FM_CLAUDE_CALM_LIVE_E2E=1 tests/fm-calm-claude-mod-live-e2e.test.sh
```
