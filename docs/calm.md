# Pi Calm mode

Calm is Firstmate's Pi-only conversation presentation toggle.
The last `/calm` choice persists for the effective Firstmate home across Pi startup, reload, new-session, resume, and fork flows.
An absent or unrecognized preference remains off, while a home with `config/calm` set to `on` opens directly in Calm presentation.

While Calm is active, Pi's transcript shows genuine captain prompts and normal assistant replies.
It removes thinking blocks, tool call and result rows, tool images and shells, Pi's working row, canonically classified Firstmate operational user rows, and legacy Calm operational presentation entries.
The hidden operational kinds are session start, watcher, turn-end guard, away supervisor, from-firstmate routing, and launch briefs.
Calm adds no enable banner, footer chip, replacement status, or other presentation row.
Interactive dialogs and explicit Pi errors remain visible so the captain can respond.
An errored tool row keeps only its plain error text, so aborts, provider failures, and tool failures stay visible without exposing routine tool call, result, image, or shell content.
When one assistant turn attaches the same text to several tool rows, Calm shows that message once and keeps distinct errors separate, and each separately interrupted turn keeps its own message after a reload or resume.

Calm changes presentation only.
Tool execution, operational input delivery, ordering, model context, session storage, diagnostics, and `/export` and `/share` data remain unchanged.
Every hidden Firstmate input remains available to the model and in serialized session data and exported artifacts.
Toggling Calm off restores Pi's ordinary rendering, and the existing tool-expansion choice is preserved.

Calm presentation activates only in a trusted interactive Pi TUI.
RPC, JSON, print, and untrusted contexts keep stock presentation even when the home preference is on.

## Pi compatibility

Calm has no numeric Pi version minimum or maximum and never refuses Pi solely because its version is newer than a previously verified version.
Pi 0.81.1 through 0.82.1 are current empirical evidence.
The assistant-thinking, complete-tool-row, tool-error-turn, and operational-user-row adapters probe the exact exported Pi methods they patch, including the tool-row result seam and column helpers behind the actionable-error surface.
If Pi removes one of those seams, Calm logs a diagnostic naming the unavailable adapter and skips only that adapter while `/calm`, the remaining adapters, and unrelated Pi extensions continue to load.
The seven built-in tool renderers remain independently wrapped as a supported-API fallback for text tool rows if the complete-tool-row adapter is unavailable.

[`calm-mode-feasibility.md`](calm-mode-feasibility.md) owns the version-scoped renderer taxonomy and empirical evidence.
[`configuration.md`](configuration.md#pi-calm-preference-configcalm) owns the persisted preference file and resolution rules.
`.pi/extensions/lib/fm-calm-visibility.ts` owns the visibility policy.

Regression entry points:

```sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-primary-types.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```
