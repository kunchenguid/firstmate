# Pi Calm mode

Calm is a Pi-only conversation presentation toggle.
It is off by default, and the last `/calm` choice persists for the effective Firstmate home across Pi session starts and resumes.

While Calm is active and an agent run is under way, Calm hides Pi's built-in `Working...` row and shows a small two-row animated boat in its place.
Each distinct in-progress assistant thinking update accumulates as a compact adjacent numbered `Step N: ...` line above the editor, while assistant commentary remains on Pi's ordinary transcript surface above both.
The water fills the usable width with low one-cell Unicode bars, using standard ANSI blue for troughs and cyan for crests.
The asymmetric three-cell `◿│◣` sail is centered over the five-cell `╲▁▁▁╱` hull, with a smaller standard ANSI yellow quarter sail, a larger standard ANSI red right sail, and a blue zero-height interior that keeps the water visible through the boat.
The boat is deliberately calm: it moves one column every 880ms, while the long smooth wave advances one quarter-cell every 220ms so the surface stays alive between boat steps.
Deterministically varied half-waves stay between nine and thirteen cells, and the boat remains phase-locked inside a broad zero-height trough through movement and edge reversals.
Every resize reflows the sprite without wrapping, and it disappears when the run settles, aborts, or fails.
Within one Pi session and Calm extension lifetime, the next working period resumes the boat from its last rendered column and travel direction rather than restarting at the left edge.
Hidden elapsed time does not advance the animation, and a resize while hidden clamps the frozen boat to the new width without changing its valid travel direction.
A fresh Pi session or new Calm extension lifetime starts at the normal initial position.
Very narrow terminals fall back to a smaller deterministic sprite.
While Calm is off, Pi's stock working row is left exactly as Pi renders it.
Calm hides raw and collapsed assistant thinking, routine supervision notes, every Pi model-tool call, argument, result, image, timing, and collapsed shell, and canonically classified Firstmate operational user rows.
Calm shows each distinct streamed thinking line in the existing above-editor status presentation, prefixed with an increasing `Step N:` counter while the model is streaming.
The lines stay adjacent without blank rows, remain visible after the response settles, and never become planning transcript rows.
Assistant text is commentary rather than a step title and renders through Pi's ordinary assistant transcript component as it streams.
That commentary remains visible exactly once after its tool turn, across later step replacement, finalization, session reload, and repeated Calm toggles, without adding a custom entry or changing the assistant message.
When the response settles, live planning thinking is hidden while assistant commentary and the genuine final response stay visible.
Once Calm has owned planning as step input, that historical planning stays hidden after reload and while Calm is off, including during explicit reasoning expansion, so superseded step titles never return to the conversation.
Hidden planning thinking and routine supervision notes remain in their messages, model context, session storage, and `/export` artifacts.
The accumulated steps reset when a new agent run, session, Calm disable, or shutdown begins, so commentary and the final answer remain ordinary transcript output.
The operational inputs Calm classifies remain ordinary user-role messages, while Pi's transcript layout renders their complete rows at zero height.
The session-start nudge remains on its existing non-displayed custom-message path.

Calm changes presentation only.
It does not register or replace any tool definition, and input delivery, tool execution, ordering, model context, session storage, diagnostics, and `/export` and `/share` operation remain unchanged.
Every hidden Firstmate input remains available to the model and in serialized session data and exported artifacts.
Legacy operational custom messages remain in session data and Pi's sidebar tree, although the main HTML transcript may omit them.
Toggling Calm off restores ordinary rendering except for historical planning Calm has already owned as step input, which remains presentation-hidden, and `Ctrl+O` expansion state is preserved.

Pi's supported presentation API does not expose a global transcript filter.
Calm owns Pi's one interactive `ToolExecutionComponent` boundary, so built-in and custom model-tool calls, arguments, results, images, timing, and collapsed shells all render at zero height while active.
User-bash rows, skill and summary rows, generic status notices, and non-tool extension rows remain visible.

## Pi compatibility

Calm has no numeric Pi version minimum or maximum and never refuses Pi solely because its version is newer than a previously verified version.
The assistant presentation adapter requires Pi's display-only Markdown transformer and also probes the exported assistant component used to remove empty thinking geometry; the tool-row and operational-user-row adapters probe their exported component seams.
If Pi removes one of those seams, Calm logs a diagnostic naming the unavailable adapter and skips only that adapter; `/calm`, the other adapter, and unrelated Pi extensions remain available.

Calm patches only the reload-stable interactive tool component's display method and consults the central visibility state on every render.
That one boundary covers rows created before the first toggle, rows created while active, restored history, built-in and arbitrary custom definitions, and image results without entering Pi's same-name tool-registration arbitration.
Calm off calls Pi's original renderer byte-for-byte, and stock export rendering remains independent of the interactive patch.

[`calm-mode-feasibility.md`](calm-mode-feasibility.md) owns the version-scoped renderer taxonomy, tool-component boundary, and empirical evidence.
[`configuration.md`](configuration.md#pi-calm-preference-configcalm) owns the persisted preference file and resolution rules.
`.pi/extensions/lib/fm-calm-visibility.ts` owns the visibility policy and accumulated-step list, `.pi/extensions/lib/fm-calm-assistant-layout.ts` owns zero-height assistant and tool layout plus streamed-step extraction, `.pi/extensions/fm-calm.ts` owns lifecycle-bound status presentation, `.pi/extensions/lib/fm-calm-operational-user-layout.ts` owns the zero-height operational-user row adapter, `.pi/extensions/lib/fm-calm-working-ship.ts` owns the animated working presentation, and `.pi/extensions/fm-branch-supervision.ts` owns routine supervision-note delivery.

Regression entry points:

```sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-branch-extension.test.sh
tests/fm-pi-primary-types.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_CALM_PI_HERDR_LIVE_E2E=1 tests/fm-calm-pi-herdr-live-e2e.test.sh
FM_CALM_PI_REAL_MODEL_E2E=1 tests/fm-calm-pi-real-model-live-e2e.test.sh
```
