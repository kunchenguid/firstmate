# Pi Calm mode

Calm is a Pi-only conversation presentation toggle.
It is off by default, and the last `/calm` choice persists for the effective Firstmate home across Pi session starts and resumes.

While Calm is active and an agent run is under way, Calm hides Pi's built-in `Working...` row and shows a small two-row animated boat in its place, and no separate Calm status row is added.
The water fills the usable width in standard ANSI blue and the complete boat is standard ANSI yellow.
The boat is deliberately calm: it moves one column every 880ms, while the water ripples on its own faster cadence so the surface stays alive between boat steps.
Its mainsail is directional, showing `<|` while travelling right and `|>` while travelling left, and it flips on the exact frame the boat turns at either edge.
Every resize reflows the sprite without wrapping, and it disappears when the run settles, aborts, or fails.
Within one Pi session and Calm extension lifetime, the next working period resumes the boat from its last rendered column and travel direction rather than restarting at the left edge.
Hidden elapsed time does not advance the animation, and a resize while hidden clamps the frozen boat to the new width without changing its valid travel direction.
A fresh Pi session or new Calm extension lifetime starts at the normal initial position.
Very narrow terminals fall back to a smaller deterministic sprite.
While Calm is off, Pi's stock working row is left exactly as Pi renders it.
Calm hides collapsed thinking labels, mid-turn assistant working notes, the shells for the Pi built-in tool names Calm owns, the `fm_watch_arm_pi` tool shell, and canonically classified Firstmate operational user rows.
A mid-turn working note is assistant text in a message the model did not end its response with, identified by that message's own `stopReason` of `toolUse`, or of `length` with tool calls present.
Hiding it removes the narration a model emits alongside its tool calls, while the genuine reply that ends a response stays visible.
Text that is still streaming is never hidden, because suppressing it would also stop a genuine reply from streaming, so a working note is briefly visible before its row collapses.
The narration is hidden only from the live transcript presentation, and remains in the message, model context, session storage, and `/export` artifacts.
The operational inputs remain ordinary user-role messages, while Pi's transcript layout renders their complete rows at zero height.
The session-start nudge remains on its existing non-displayed custom-message path.

Outside Pi's same-name built-in override collision described below, Calm changes presentation only.
Calm's built-in wrappers preserve Pi's execution behavior, and input delivery, ordering, model context, session storage, diagnostics, and `/export` and `/share` operation remain unchanged.
Every hidden Firstmate input remains available to the model and in serialized session data and exported artifacts.
Legacy operational custom messages remain in session data and Pi's sidebar tree, although the main HTML transcript may omit them.
Toggling Calm off restores ordinary rendering, and `Ctrl+O` expansion state is preserved.

Pi's supported presentation API does not expose a global transcript filter.
Expanded reasoning and its reserved spacing, built-in tool images, user-bash rows, skill and summary rows, generic status notices, and arbitrary custom-tool or extension rows remain visible.
These are supported-API boundaries rather than hidden-content failures.

## Supervised worker sessions

Firstmate loads this same tracked `fm-calm.ts` implementation explicitly for every ordinary Pi and Pi-signed ship or scout worker.
The launch binds the worker to the spawning Firstmate home's resolved `FM_HOME` and config directory, so the extension reads that home's `config/calm` even though the worker runs in an isolated task repository.
The launch contributes exactly one Calm extension path outside that repository, requires no project-local copy or project trust, and keeps the generated supervision extension separate so presentation and supervision retain their existing owners.
The [home-local preference contract](configuration.md#pi-calm-preference-configcalm) is unchanged; the worker launch only selects the owning home's path, and an active preference applies the same presentation-only behavior described above without changing tool execution, message ordering, session storage, or exports.
Non-Pi workers receive no Calm launch integration.
Persistent second mates also receive no ordinary-worker integration because a Pi-family second mate already starts as a primary Firstmate session under its own tracked extension contract.

A worker reads the preference when its Pi extension starts and again on Pi `session_start` events, but it does not poll the file while an existing session sits unchanged.
Changing the preference in another Pi session therefore applies automatically to workers started later and to a running worker only after that worker naturally starts or reloads a Pi session.
Firstmate does not inject live extension code or force a reload into a running worker.
Use the [supported control-plane relaunch](agent-control.md#transactional-relaunch) when the new presentation must apply immediately: it preserves the task's isolated local copy and durable progress while starting a replacement Pi session, and the prior Pi transcript remains stored normally.

## Pi compatibility

Calm has no numeric Pi version minimum or maximum and never refuses Pi solely because its version is newer than a previously verified version.
The collapsed-thinking and operational-user-row presentation adapters probe the exact Pi API seam they patch when Calm loads.
If Pi removes one of those seams, Calm logs a diagnostic naming the unavailable adapter and skips only that adapter; `/calm`, the other adapter, and unrelated Pi extensions remain available.

Calm's built-in tool presentation (`bash`, `read`, `edit`, `write`, `grep`, `find`, `ls`) shares Pi's single, unmerged override slot per name with any other extension that overrides the same tool.
While the persisted Calm preference is off, Calm registers none of those overrides and therefore contests no built-in tool name.
The first time Calm turns on in a session that started off, it claims every built-in name no other extension already owns, leaves every contested tool intact and callable, and displays a prominent warning naming the tools it skipped.
Tool-call rows already on screen before that first toggle do not retroactively collapse; later rows for the names Calm claimed use Calm presentation.
When a session starts or reloads with Calm already on, Calm must instead register all seven overrides synchronously so Pi can render restored rows with them.
Pi provides no ownership check early enough for that load-time path, and the first registrant wins the complete tool definition.
If the other extension wins, a session-start console diagnostic names the tool and winning extension; if Calm wins, Pi does not expose the losing registration, so the other extension's override is unavailable and cannot be named.

[`calm-mode-feasibility.md`](calm-mode-feasibility.md) owns the version-scoped renderer taxonomy, built-in override constraints, and empirical evidence.
[`configuration.md`](configuration.md#pi-calm-preference-configcalm) owns the persisted preference file and resolution rules.
`.pi/extensions/lib/fm-calm-visibility.ts` owns the visibility policy, `.pi/extensions/lib/fm-calm-operational-user-layout.ts` owns the zero-height operational-user row adapter, and `.pi/extensions/lib/fm-calm-working-ship.ts` owns the animated working presentation.

Regression entry points:

```sh
tests/fm-spawn-dispatch-profile.test.sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-primary-types.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```
