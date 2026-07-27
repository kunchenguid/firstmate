# Pi Calm mode

Calm is a Pi-only conversation presentation toggle.
It is off by default, and the last `/calm` choice persists for the effective Firstmate home across Pi session starts and resumes.

While Calm is active, Pi's built-in `Working...` activity remains visible and no separate Calm status row is added.
Calm hides collapsed thinking labels, the shells for Pi's seven built-in tools, the `fm_watch_arm_pi` tool shell, and canonically classified Firstmate operational user rows.
The operational inputs remain ordinary user-role messages, while Pi's transcript layout renders their complete rows at zero height.
The session-start nudge remains on its existing non-displayed custom-message path.

Calm changes presentation only.
Tool execution, input delivery, ordering, model context, session storage, diagnostics, and `/export` and `/share` operation remain unchanged.
Every hidden Firstmate input remains available to the model and in serialized session data and exported artifacts.
Legacy operational custom messages remain in session data and Pi's sidebar tree, although the main HTML transcript may omit them.
Toggling Calm off restores ordinary rendering, and `Ctrl+O` expansion state is preserved.

Pi's supported presentation API does not expose a global transcript filter.
Expanded reasoning and its reserved spacing, built-in tool images, user-bash rows, skill and summary rows, generic status notices, and arbitrary custom-tool or extension rows remain visible.
These are supported-API boundaries rather than hidden-content failures.

[`calm-mode-feasibility.md`](calm-mode-feasibility.md) owns the version-scoped renderer taxonomy and empirical evidence.
[`configuration.md`](configuration.md#pi-calm-preference-configcalm) owns the persisted preference file and resolution rules.
`.pi/extensions/lib/fm-calm-visibility.ts` owns the visibility policy, and `.pi/extensions/lib/fm-calm-operational-user-layout.ts` owns the zero-height operational-user row adapter.

Regression entry points:

```sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-primary-types.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```
