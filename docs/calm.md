# Pi Calm mode

Calm is a Pi-only conversation presentation preference.
On a certified Pi version, Calm is on when `config/calm` is absent, while an explicit `off` preference always wins and persists across session starts and resumes.
Use `/calm on`, `/calm off`, or `/calm status`; bare `/calm` remains a backward-compatible toggle.

While Calm is active, Pi's built-in `Working...` activity remains visible and no separate Calm status row is added.
When Pi's tool display is collapsed, successful rows for Pi's seven built-in tools and `fm_watch_arm_pi` occupy zero lines.
Pi's standard `Ctrl+O` restores those known tools' complete stock call and result rendering in place without re-execution, and a second `Ctrl+O` collapses them again without losing data.
A collapsed known-tool error keeps one concise text-labeled failure message with the configured reveal-key hint, while expansion shows its complete stock evidence.
Collapsed thinking labels, canonically classified Firstmate operational user rows, and legacy synthetic presentation entries remain zero-height at their separately certified presentation seams.
Pi's `Ctrl+T` reasoning expansion remains independent from tool expansion.
The session-start nudge remains on its existing non-displayed custom-message path.

Calm changes presentation only.
Tool execution, input delivery, ordering, model context, session storage, diagnostics, and `/export` and `/share` operation remain unchanged.
Every hidden Firstmate input and tool result remains available to the model, serialized session data, and exported artifacts.
Legacy operational custom messages remain in session data and Pi's sidebar tree, although the main HTML transcript may omit them.
`/calm off` restores ordinary stock rendering.

The extension certifies the installed Pi version and every required renderer seam before applying any Calm override.
An unsupported version or missing seam receives no partial Calm behavior, keeps stock rendering, and shows one actionable compatibility warning.

Pi's supported presentation API does not expose a global transcript filter.
Expanded reasoning, built-in tool images, user-bash rows, skill and summary rows, generic status notices, and arbitrary custom-tool or extension rows remain visible.
These are supported-API boundaries rather than hidden-content failures.

[`calm-mode-feasibility.md`](calm-mode-feasibility.md) owns the version-scoped renderer taxonomy and empirical evidence.
[`configuration.md`](configuration.md#pi-calm-preference-configcalm) owns the persisted preference file and resolution rules.
`.pi/extensions/lib/fm-calm-visibility.ts` owns the visibility and collapsed-failure policy, and `.pi/extensions/lib/fm-calm-compatibility.ts` owns the certified Pi matrix and required surface result.

Regression entry points:

```sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-primary-types.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```
