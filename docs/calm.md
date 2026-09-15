# Calm presentation

`/calm` is a Pi-only conversation presentation toggle.
It is off by default, and the last `/calm` choice persists for the effective Firstmate home across Pi session starts and resumes.

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
Calm hides collapsed thinking labels, mid-turn assistant working notes, the shells for the Pi built-in tool names Calm owns, the `fm_watch_arm_pi` and `fm_branch_outcomes` tool shells, and canonically classified Firstmate operational user rows.
A mid-turn working note is assistant text in a message the model did not end its response with, identified by that message's own `stopReason` of `toolUse`, or of `length` with tool calls present.
Hiding it removes the narration a model emits alongside its tool calls, while the genuine reply that ends a response stays visible.
Text that is still streaming is never hidden, because suppressing it would also stop a genuine reply from streaming, so a working note is briefly visible before its row collapses.
The narration is hidden only from the live transcript presentation, and remains in the message, model context, session storage, and `/export` artifacts.
The operational inputs Calm classifies remain ordinary user-role messages, while Pi's transcript layout renders their complete rows at zero height.
The session-start nudge remains on its existing non-displayed custom-message path.

Outside Pi's same-name built-in override collision described below, Calm changes presentation only.
Calm's built-in wrappers preserve Pi's execution behavior, and input delivery, ordering, model context, session storage, diagnostics, and `/export` and `/share` operation remain unchanged.
Every hidden Firstmate input remains available to the model and in serialized session data and exported artifacts.
Legacy operational custom messages remain in session data and Pi's sidebar tree, although the main HTML transcript may omit them.
Toggling Calm off restores ordinary rendering, and `Ctrl+O` expansion state is preserved.

Pi's supported presentation API does not expose a global transcript filter.
Expanded reasoning and its reserved spacing, built-in tool images, user-bash rows, skill and summary rows, generic status notices, and other arbitrary custom-tool or extension rows remain visible.
These are supported-API boundaries rather than hidden-content failures.

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
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-branch-extension.test.sh
tests/fm-pi-primary-types.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```

## OMP tool visibility

The OMP extension `.omp/extensions/fm-calm-omp.ts` provides `/calm-omp` as a toggle for OMP's native **Hide Tool Activity** setting.
Start a fresh OMP session after installing the extension, then run `/calm-omp` without arguments.
The same setting is available through `Ctrl+Shift+O` and `/settings` > Appearance > Display > Hide Tool Activity.
OMP owns persistence, so command, shortcut, and settings changes stay synchronized without a separate Firstmate preference file.

This hides model tool calls, tool results, and their associated images, including existing transcript history.
Toggling again restores tool activity with OMP's native collapsed expansion state.
Session data, model context, and tool execution remain intact.
While tool activity is hidden and an agent run is active, a two-row blue-water and yellow-boat animation appears above the editor, using the same sprite, cadence, resize behavior, and freeze/resume geometry as Pi Calm.
The boat follows command, shortcut, and settings changes during a run, and starts automatically when the saved native setting is enabled.
It stays through tool continuations and disappears when the run finishes, aborts, or fails.
Hidden time does not advance the boat, and a fresh session or extension reload resets its position.
The stock working indicator remains alongside the boat because OMP's public extension API cannot hide it.
Advisor cards, TODO displays, and canonically classified text-only Firstmate operational user messages, including watcher wakes, are also concealed while calm is enabled.
Their stored content and model delivery are unchanged; toggling calm off restores them.
Thinking, assistant narration, ordinary captain messages, attachments, and Firstmate outcome cards retain OMP's normal presentation.

OMP does not expose a public extension API setter for tool visibility.
The extension briefly uses a zero-height widget factory to obtain the live TUI, removes the widget, then calls the focused editor's existing native visibility action.
It checks that capability on every command and does not cache editor instances.
A session-scoped adapter wraps live OMP presentation components for advisor, TODO, and operational input hiding.
If the editor action is unavailable, it reports a warning directing the operator to OMP's native controls.
This bridge depends on OMP's editor callback and needs the live regression rerun after OMP upgrades.
The boat reads the live OMP namespace's native display preference and uses the public widget API, with one animation timer running only during an agent run.
If OMP's native setting accessor is unavailable, the extension warns and leaves tool toggling available without the boat.
Session shutdown and extension reload dispose the widget and timer without changing transcript content or the native preference.

Run `tests/fm-calm-omp-live-e2e.test.sh` for command capability checks and the installed OMP terminal integration guard.
