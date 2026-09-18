# Calm mode

Calm is Firstmate's conversation-only transcript presentation toggle.
It is fully supported on Pi, and available on Claude Code behind that harness's default-off early-access function-hooks flag, as the [Claude Code](#claude-code) section below describes.
It is off by default, and the last `/calm` choice persists for the effective Firstmate home across session starts and resumes on either harness, through the one shared preference file [`configuration.md`](configuration.md#calm-preference-configcalm) owns.
Across both harnesses, Calm evaluates each settled assistant text block from a model step that stopped to call tools, or exhausted its token limit while carrying tool calls.
It hides a block only when its raw text contains no newline and its trimmed length is below `CALM_PRESERVE_MIN_CHARS` (240); a newline or at least 240 trimmed characters preserves the block as substantive captain-facing content, while streaming text and the genuine reply that ends a response remain visible.

## Pi

While Calm is active and an agent run is under way, Calm hides Pi's built-in `Working...` row and shows a small two-row animated boat in its place, and no separate Calm status row is added.
The water fills the usable width with low one-cell Unicode bars, all in standard ANSI blue, so the swell shows through bar height alone.
The asymmetric three-cell `◿│◣` sail is centered over the five-cell `╲▁▁▁╱` hull, and the whole boat, both sail halves, mast, and hull, is one standard ANSI yellow, with the hull's zero-height interior keeping the swell continuous beneath the boat.
The boat is deliberately calm: it moves one column every 880ms, while the long smooth wave advances one quarter-cell every 220ms so the surface stays alive between boat steps.
Deterministically varied half-waves stay between nine and thirteen cells, and the boat remains phase-locked inside a broad zero-height trough through movement and edge reversals.
Every resize reflows the sprite without wrapping, and it disappears when the run settles, aborts, or fails.
Within one Pi session and Calm extension lifetime, the next working period resumes the boat from its last rendered column and travel direction rather than restarting at the left edge.
Hidden elapsed time does not advance the animation, and a resize while hidden clamps the frozen boat to the new width without changing its valid travel direction.
A fresh Pi session or new Calm extension lifetime starts at the normal initial position.
Very narrow terminals fall back to a smaller deterministic sprite.
While Calm is off, Pi's stock working row is left exactly as Pi renders it.
Calm hides collapsed thinking labels, the mid-turn assistant working-note blocks governed by the shared preservation rule above, the shells for the Pi built-in tool names Calm owns, the `fm_watch_arm_pi` and `fm_branch_outcomes` tool shells, and canonically classified Firstmate operational user rows.
Pi applies that rule independently to each text block, so a short working note can hide beside preserved substantive content in the same message.
A working note is briefly visible while it streams before its settled row collapses, except inside a typed Firstmate operational run, whose working ship, assistant reasoning, working text, tool residue, errors, and no-op acknowledgement remain at zero height for the whole run.
A genuine intervention discovered by an operational run renders exactly one clean final human response, with no internal reasoning or envelope.
The narration is hidden only from the live transcript presentation, and remains in the message, model context, session storage, and `/export` artifacts.
The operational inputs Calm classifies remain ordinary user-role messages, while Pi's transcript layout renders their complete rows at zero height.
The session-start nudge remains on its existing non-displayed custom-message path.

Calm changes presentation only.
It does not register or replace any tool definition, and input delivery, tool execution, ordering, model context, session storage, diagnostics, and `/export` and `/share` operation remain unchanged.
Every hidden Firstmate input remains available to the model and in serialized session data and exported artifacts.
Legacy operational custom messages remain in session data and Pi's sidebar tree, although the main HTML transcript may omit them.
Toggling Calm off restores ordinary rendering, and `Ctrl+O` expansion state is preserved; Calm never adds replacement rows or mutates the underlying thinking history.

Pi's supported presentation API does not expose a global transcript filter.
Calm owns Pi's one interactive `ToolExecutionComponent` boundary, so built-in and custom model-tool calls, arguments, results, images, timing, and collapsed shells all render at zero height while active.
User-bash rows, skill and summary rows, generic status notices, and non-tool extension rows remain visible.

## Pi compatibility

Calm has no numeric Pi version minimum or maximum and never refuses Pi solely because its version is newer than a previously verified version.
The assistant presentation adapter requires Pi's display-only Markdown transformer and probes the exported assistant component used to preserve ordinary row geometry; the tool-row and operational-user-row adapters probe their exported component seams.
If Pi removes one of those seams, Calm logs a diagnostic naming the unavailable adapter and skips only that adapter; `/calm`, the other adapter, and unrelated Pi extensions remain available.

Calm patches only the reload-stable interactive tool component's display method and consults the central visibility state on every render.
That one boundary covers rows created before the first toggle, rows created while active, restored history, built-in and arbitrary custom definitions, and image results without entering Pi's same-name tool-registration arbitration.
Calm off calls Pi's original renderer byte-for-byte, and stock export rendering remains independent of the interactive patch.

[`calm-mode-feasibility.md`](calm-mode-feasibility.md) owns the version-scoped renderer taxonomy, built-in override constraints, and empirical evidence.
[`configuration.md`](configuration.md#calm-preference-configcalm) owns the persisted preference file and resolution rules.
`.pi/extensions/lib/fm-calm-visibility.ts` owns the visibility policy and operational-run marker, `.claude/mods/firstmate-calm/lib/fm-calm-preservation.ts` owns the shared substantive mid-turn text rule that Pi imports through its tracked symlink, `.pi/extensions/lib/fm-calm-operational-user-layout.ts` owns the zero-height operational-user row adapter, `.pi/extensions/lib/fm-calm-assistant-layout.ts` owns the zero-height operational-run assistant adapter, and `.pi/extensions/lib/fm-calm-working-ship.ts` owns Pi's animated working presentation over the sprite geometry both harnesses share in `.claude/mods/firstmate-calm/lib/fm-calm-working-ship-sprite.ts`.

Regression entry points:

```sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-branch-extension.test.sh
tests/fm-pi-primary-types.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_CALM_PI_HERDR_LIVE_E2E=1 tests/fm-calm-pi-herdr-live-e2e.test.sh
FM_CALM_PI_REAL_MODEL_E2E=1 tests/fm-calm-pi-real-model-live-e2e.test.sh
```

## Claude Code

Calm on Claude Code is the `firstmate-calm` mod under `.claude/mods/firstmate-calm`: a Claude Code plugin whose whole behavior lives in one function-hooks module.
Claude Code's early-access function-hooks surface is off by default and can load modules through its rollout flag or per session with `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`; the mod independently requires that environment variable to equal `1` before doing anything.
Firstmate never sets that flag in any project or user settings; enabling it is each captain's own explicit opt-in, and without that exact value the mod is a complete no-op even if Claude Code's rollout flag loads the module: there is no `/calm` command, no preference or transcript read, no timer, and every drawing stays exactly as Claude Code draws it, whatever `config/calm` says.
The trusted project auto-loads the mod through the `.claude/skills/firstmate-calm` entry (a symlink into `.claude/mods`), so no `--plugin-dir` or marketplace install is needed.

With the flag on, the mod registers `/calm`, which toggles the same per-home preference Pi's `/calm` uses, so one choice applies on both harnesses.
The toggle answers with a transient "Calm on" or "Calm off" notice under the prompt rather than a transcript row, and a preference that cannot be written leaves the current choice unchanged and says so in that notice.
While Calm is on, the stock working row (`Sauteing... (12s · 300 tokens)`) becomes the same two-row sailboat Pi draws, from the same shared sprite geometry: it fills the row inside the transcript margin, repaints on the boat's 220ms cadence with the hull moving every 880ms, reflows on resize, and appears and disappears exactly where the stock row would.
On Claude Code the boat is painted in Claude Code's own theme colors rather than Pi's standard ANSI codes: every water cell takes the spinner blue of the active theme family (`#93a5ff` on a dark theme, `#5769f7` on a light one) and the whole boat, both sail halves, mast, and hull, takes the Claude orange of the stock spinner (`#d77757`).
The family follows the `theme` setting by its prefix, `dark` or `light`, is re-read when the theme changes, and uses the light set as the both-readable fallback for `auto`, custom, missing, or unreadable values; the Pi extension keeps its standard ANSI blue and yellow.
Tool rows, tool result blocks, and folded tool groups draw at zero height, so a turn that used tools takes the same space as one that did not.
A user row whose text the canonical operational-input parser recognizes, a Firstmate session-start, watcher, turn-end guard, away-supervisor, launch-brief, or branch-outcome envelope, a from-firstmate routed message, or one of the narrow pre-protocol shapes kept for old transcripts, draws at zero height; every other user row, including near misses such as a quoted or ASCII-only marker, stays visible.
Assistant text follows the shared per-block preservation rule above, including when `claude --continue` restores the transcript.
Toggling Calm redraws every hooked row already on screen, so rows drawn before the toggle hide or restore retroactively, and the preference is read before the first row draws.
Nothing is rewritten: hidden rows remain in the message, model context, session storage, and exports, and the mod never touches tool execution, prompts, or the stored transcript.

Bounds of the Claude Code support, each recorded with evidence in [`calm-mode-feasibility.md`](calm-mode-feasibility.md#2026-09-15-claude-code-21272-mods-feasibility-and-the-shipped-mod):

- The function-hooks surface is early access and default-off, and Claude Code states that its API may change between releases without notice; the mod is verified on Claude Code 2.1.272 and refuses nothing newer.
- On the main-screen layout (not the fullscreen alternate screen), a toggle redraws the live screen by clearing and reprinting it, and the terminal's own scrollback keeps the earlier rendering above it; the fullscreen layout has no such stale copy.
- The sailboat is painted through Claude Code's Raster element, whose colors are RGB quantized to 256-color escapes rather than the standard 16-color ANSI codes Pi's widget emits.
- The detailed transcript view (`ctrl+o`) keeps its per-message timestamp and model headers where hidden assistant rows sat, because those headers are not a hookable drawing.
- Collapsed thinking never appears in Claude Code's default view, and the mod has no thinking drawing to hide in other views.

Regression entry points:

```sh
tests/fm-calm-claude-mod.test.sh
tests/fm-calm-claude-mod-plugin.test.sh
FM_CLAUDE_CALM_LIVE_E2E=1 tests/fm-calm-claude-mod-live-e2e.test.sh
```
