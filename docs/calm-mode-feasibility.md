# Calm-mode harness feasibility

This document is a dated journal of Calm-mode observations: harness surveys, the Pi transcript taxonomy, and supported-API boundaries for Firstmate calm mode.
Each entry records when an observation was made, which harness version it was made against, and what was actually seen.
An observation is not carried to a version it was not made on; where a survey has not been redone, the gap is stated instead of filled by deduction.
[`calm.md`](calm.md) owns the current user-facing `/calm` usage and limitation contract.

## Required extension surface

A qualifying implementation must auto-load from the trusted project, persist the toggle choice for the effective Firstmate home across Pi session starts and resumes, keep working activity visible, emit no Calm status row, redraw already-rendered controllable rows, remove supported hidden rows without gaps, restore ordinary rendering, and leave delivery, tool execution, model context, session storage, export and share operation, diagnostics, and expansion state unchanged.
The governing presentation policy allows genuine original user prompts, genuine user-facing assistant text, and working activity.
Working activity may be presented through Pi's stock row or through a supported Calm-owned widget, but Calm must leave the stock row untouched whenever Calm is off.
Changing persisted context to remove hidden content, filtering provider context, patching installed harness code, or claiming coverage outside a supported renderer does not satisfy that boundary.

## Compatibility evidence

[`calm.md`](calm.md#pi-compatibility) owns the current Pi compatibility contract.
The Pi installed on 2026-08-16 is 0.84.2.
What was observed against it that day is what the [2026-08-16 verification record](#2026-08-16-pi-0842-installed-version-verification) shows and nothing more: the `pi` and installed-package versions, one clean run of `tests/fm-calm-pi-extension.test.sh`, a declarations recheck of the two exported classes the adapters patch, and a typecheck run that produced no typecheck because `tsc` was absent.
That run is not a uniformly reproducible pass: the follow-up adjacent case intermittently fails a known test-harness race, measured and referenced in the same entry.
No survey in this document has been redone on 0.84.2.
The extension-API survey and the transcript taxonomy were made against Pi 0.81.1 on 2026-07-22.
The cross-harness inspection was made on 2026-07-22, with its Pi row reverified at 0.81.1 on 2026-07-23.
The working-presentation observations were made against the Pi 0.82.0 CLI on 2026-07-30.
Each section below repeats its own date and version.
Pi 0.81.1 was installed when Calm was first built, and Pi 0.82.0 was the later reverification target.
The Pi CHANGELOG read at those two versions showed no relevant presentation API introduced at either, so they were recorded as verification evidence rather than compatibility bounds.
That reading was not repeated release by release afterwards; the later CHANGELOG entries that did touch Calm were found when they broke or changed it and are written up in the dated entries below.
The exported classes used by the adapters (`AssistantMessageComponent` and `InteractiveMode`) are undocumented internals with no stated version guarantee.
`tests/fm-calm-pi-extension.test.sh` records the installed Pi version as evidence without gating on it and covers both newer synthetic versions and an unavailable adapter seam.

### Built-in tool override constraints

[`calm.md`](calm.md#pi-compatibility) owns the current user-facing collision behavior and limitation.
Inspection of Pi 0.80.10 and 0.82.0, recorded on 2026-08-04, established that extensions override a built-in tool by registering the same name, the first registered extension wins the complete `ToolDefinition` without merging, and Pi exposes no unregister operation.
That inspection has not been redone on 0.84.2, so the Pi registration behavior described here is unverified there.
0.84.2's new `defaultTools` setting selects which built-ins Pi starts with and was not tested against Calm; the [2026-08-16 verification record](#2026-08-16-pi-0842-installed-version-verification) owns that gap.
Pi loads project-local extensions before global or CLI-configured extensions, so Firstmate's tracked Calm extension previously won those collisions even when its persisted preference was off.
The losing definition's execution and render functions are both discarded, so unconditionally registering Calm's wrappers would replace another extension's same-named tool rather than changing presentation alone.

Pi's `getAllTools()` exposes tool metadata and source identity but not the executable or rendering functions needed to wrap another extension's full definition.
It is also usable for reliable collision detection only after extension binding, which makes it suitable for the first same-session `/calm` activation but not for synchronous extension loading.
Deferring registration to `session_start` is not an equivalent path: Pi constructs restored tool rows from an earlier tool-registry snapshot during reload, new-session, fork, and session switching, so those rows retain the definition captured before `session_start`.
`tests/fm-calm-pi-extension.test.sh` covers the resulting split contract: no load-time claims while Calm is off, synchronous claims while it is already on, collision-checked first activation with a warning, preservation of a contested tool's execution, and the non-retroactive bound for rows rendered before first activation.

## Pi 0.81.1 end-to-end reproduction

The Pi version installed at the time was verified on 2026-07-22.

```text
$ pi --version
0.81.1
```

### Original transcript cleanup

The pre-cleanup reproduction used a real isolated Pi TUI at 180 columns by 44 rows with the tracked Calm and watcher extensions, an isolated `FM_HOME`, and a live home-owned watcher cycle.
The model called `fm_watch_arm_pi`, the real tool returned `watcher: started Pi extension arm child 1`, and a `done:` status write caused the watcher extension to inject `FIRSTMATE WATCHER WAKE: signal: ...` followed by the stable drain instruction.
With Calm off, the captured transcript contained the genuine user prompt, the full watcher tool shell, the synthetic user-role wake, four collapsed `Thinking...` labels, built-in tool rows from wake handling, and the final assistant response.
With the pre-cleanup implementation's Calm mode on, the existing seven built-in tool rows disappeared, but the watcher tool shell, synthetic wake, and all four `Thinking...` labels remained.
The final screenshot-scale regression reproduced the same transcript after the cleanup and verified that Calm removed those remaining controlled rows while retaining the genuine prompt, a watcher-shaped genuine near-miss prompt, and the genuine assistant responses.

The original proven comparison path was a built-in text tool.
Calm owned both of that tool's supported renderer slots and switched its shell to `renderShell: "self"`, so returning empty components removed the complete row and `setToolsExpanded` redrew existing tool components.
Adding supported empty renderer slots to a scratch copy of `fm_watch_arm_pi` likewise removed its row while the real watcher still started and the model still returned `PROBE_COMPLETE`.
Legacy synthetic presentation entries use `CustomEntryComponent`, whose host adds spacing only when its renderer returns content, so an undefined Calm renderer result removes the complete row and can later restore it through the ordinary expansion redraw.
The later duplicate-turn evidence below supersedes custom-message rerouting as an acceptable implementation for current operational input.

### Hidden-block height regression

The 2026-07-23 end-user-aligned reproduction used the installed Pi 0.81.1 TUI at 100 columns by 44 rows, an isolated project and `FM_HOME`, the real `/skill:ahoy` command path, and a deterministic provider that produced five thinking-bearing read calls, five tool results, final hidden thinking, and a visible final response.
With Calm on and Pi's thinking display collapsed, the completed turn left 14 empty rows between the visible collapsed `[skill] ahoy` content row and the first final assistant row.
With Calm off, the same sequence rendered all six `Thinking...` labels and all five read rows instead of an empty field.
A controlled baseline containing only the skill row and final response had two standard visible-row separators.
Adding one final thinking block increased that gap from two rows to four, while adding a tool call without a result or a completed tool call and result left it at two.
Removing only all six thinking blocks from the failing persisted session left all five tool calls and results intact and reduced the gap from 14 rows to the two-row baseline.
Enabling Pi's `terminal.clearOnShrink` on the unchanged failing session left the gap at 14 rows, which rules out stale terminal allocation as the cause.

The initiating trigger was a non-empty thinking block in an assistant message that Pi rendered through `AssistantMessageComponent`.
The masking condition was the combination of Calm being active and Pi's thinking display being collapsed, because Calm replaced the visible label with an empty string while Calm off or explicit thinking expansion filled those rows with visible content.
The visible symptom was the large empty vertical field between the intentionally visible collapsed skill row and final assistant response.

The earliest divergent layout path was `AssistantMessageComponent.updateContent`, before terminal differential rendering or tool-result composition.
Pi computed `hasVisibleContent` from the original thinking data and added a leading `Spacer` before applying the hidden-thinking presentation.
Pi then styled the empty label before constructing `Text`, so the resulting ANSI-only string occupied one rendered row, and a thinking block followed by assistant text also added its ordinary inter-block spacer.
Each thinking-only tool turn therefore retained two empty rows, while the final thinking-plus-text turn retained two extra rows beyond the final response's normal leading separator.
The proven tool path diverged through `ToolExecutionComponent`, where the Calm self-render shell returned zero lines for both call and result slots and contributed no residual height.

The smallest counterfactual was the thinking-only removal from the same persisted session, which preserved the skill, tools, results, final response, session ordering, and terminal settings while eliminating every unwanted row.
The single-thinking, tool-call-only, tool-result, Calm-off, and `clearOnShrink` controls deliberately sought disconfirming evidence and isolated collapsed thinking layout from skill, tool, result, and terminal-cache candidates.
PR 927 made Calm persistent and described controlled rows as gapless while retaining a documented unsupported boundary for collapsed-thinking spacing.
PR 936 removed the unsafe operational-input reroute and preserved legacy zero-height entries but did not change assistant-message layout.

The fix installs one idempotent presentation adapter on the exported `AssistantMessageComponent.updateContent` method, verified on Pi 0.81.1 on 2026-07-23 and on Pi 0.82.0 on 2026-07-26; no release between or after those two was tested for this adapter beyond what the dated entries below record.
The adapter probes for that exact method and, per the [compatibility contract](calm.md#pi-compatibility), degrades independently with a diagnostic rather than gating on a version number.
Only while Calm is active and Pi has collapsed thinking does the adapter pass a shallow thinking-free presentation copy into Pi's ordinary layout calculation, then retain the original message on the component for invalidation and thinking expansion.
The persisted assistant message, provider context, tool execution, export data, and expansion history remain unchanged.
Collapsed thinking-only assistant messages now render zero rows, thinking before visible assistant text adds no spacing beyond the text-only baseline, and expanding thinking still renders the original reasoning.

The disconfirming checks deliberately retain supported boundaries.
An arbitrary third-party custom tool and a built-in read image remain visible because Pi exposes neither a global tool renderer nor image-row control.
Expanded thinking remains visible by design, while re-collapsing it returns to zero-height Calm presentation.
Ordinary user-role near misses remain visible, including quoted current markers, ASCII-only labels, unrelated text before a marker, unrelated text after U+2063, and image-bearing input.

## Duplicate-turn regression and semantic boundary

The captain-visible regression reproduced three consecutive times in a persisted Pi session under `~/.pi/agent/sessions/`.
Assistant `bb83873b` was followed by hidden custom input `9d087b52` and distinct duplicate assistant `f4232aa3`.
Assistant `3a388d8c` was followed by adjacent hidden custom inputs `e1914f28` and `cfdefb09` and distinct duplicate assistant `47c81eeb`.
Distinct provider response identifiers and signatures prove separate model turns rather than duplicate TUI paint.

The initiating trigger was `pi.sendUserMessage(..., { deliverAs: "followUp" })` from the watcher or turn-end adapter after a captain-facing response.
The exposure condition was Calm's loaded `input` handler from commit `6db3b09`, which ran whether the persisted toggle was on or off, returned `handled`, replaced the user message with `pi.sendMessage`, and triggered a nested custom-message turn.
The visible symptom was a second assistant row repeating the prior captain answer.
The earliest persisted divergence was the operational entry type: Calm loaded produced `custom_message` with role `custom` before provider conversion, while Calm absent produced a normal `message` with role `user`.
The earliest lifecycle divergence was that the replacement path bypassed Pi's normal user-prompt processing after the `input` event.

A native deterministic Pi TUI reproduction on landed PR 927 produced `CAPTAIN_VISIBLE_ANSWER` twice with Calm loaded and explicitly on, and produced the same duplicate with Calm loaded and explicitly off.
The same exact typed notification with Calm absent produced one captain answer followed by `MONITOR_NOTIFICATION_HANDLED`.
Removing only the input reroute from a scratch copy while leaving Calm loaded and on produced the same proven result and restored the operational entry to role `user`.
This is the smallest counterfactual and proves extension loading, not the active toggle, was the required exposure condition.
The extension-absent success path is evidence against an independent Pi-core duplicate-turn cause for the same sequence, but it does not claim Pi core could never contain a separate duplication bug.

PR 936 removed Calm's semantic input handler and custom-message delivery path because Pi 0.81.1 exposes no supported ordinary-user renderer and that replacement duplicated model turns.
That correction preserved current operational input as an exact ordinary user-role message with its ordering and authority unchanged, but deliberately left the row visible until a presentation-only boundary was proven.
Legacy `firstmate-synthetic-input-presentation` entries remained renderable so existing sessions preserved their stored presentation and zero-height hidden-row behavior.

## Operational user-row zero-height regression

The 2026-07-23 end-user-aligned reproduction used the installed Pi 0.81.1 TUI at 160 columns by 36 rows, the tracked Calm extension persisted on, an isolated home and session directory, and a deterministic in-process provider.
The injected user message began with exact U+2063 plus `FIRSTMATE_OP:` and carried the watcher status path from the durable captain screenshot followed by the blank line and stable drain instruction.
The exact U+2063 bytes, both payload lines, user role, and ordering survived live delivery and process restart.
The provider observed one matching user message, returned `OPERATIONAL_PROCESSED occurrences=1`, and the session contained one matching user entry and one matching assistant entry.

The failing viewport rendered the operational input as a five-cell-high user box on rows 1 through 5 and placed the assistant text on row 7 after Pi's normal assistant separator.
The same persisted session reproduced those coordinates after restart.
Calm off rendered the same user component geometry, proving the active toggle had no presentation effect on this path.
The initiating trigger was the exact watcher-generated user message.
The exposure condition was PR 936's safe ordinary-user delivery path combined with the absence of a user-row presentation adapter, not marker loss, event-source drift, failed classification, persistence, replay, or duplicate delivery.
The visible symptom was the complete two-line synthetic user box and its five rows of terminal height.

The earliest meaningful layout divergence from proven hidden presentation entries was `InteractiveMode.addMessageToChat`.
Its ordinary-user branch added a leading `Spacer` when applicable and then a `UserMessageComponent`, whose `Box` contributes vertical padding around the three Markdown lines.
The legacy custom-entry path instead checks renderer content before mounting a transcript child, and the completed assistant-thinking fix removes hidden thinking before assistant layout.
Those behaviors have different owners and remain separate.

The smallest counterfactual returned only from the transcript owner's ordinary-user branch for that exact watcher input.
The real Pi viewport moved the unchanged assistant text from row 7 to row 2, rendered no operational text, and still persisted one exact user entry and one exact response.
The leading cause would have been falsified if the row or height remained, the provider lost or duplicated the message, or the persisted role or bytes changed.
None occurred.

The fix installs a separate idempotent presentation adapter on the exported `InteractiveMode.addMessageToChat` method, verified on Pi 0.81.1 on 2026-07-23 and on Pi 0.82.0 on 2026-07-26; no release between or after those two was tested for this adapter beyond what the dated entries below record.
The adapter probes for that exact method and, per the [compatibility contract](calm.md#pi-compatibility), degrades independently with a diagnostic rather than gating on a version number.
It delegates current recognition to `bin/fm-operational-input.sh`, adds only the evidence-backed bare-U+2063 `Supervisor escalate (` presentation compatibility shape, mounts a `UserMessageComponent` subclass that preserves Pi's stock row plus leading spacer while Calm is off, and returns zero rendered lines while Calm is on.
It never intercepts the input event, rewrites the message, changes its role, filters model context, or changes session data.
Messages containing an image are left on Pi's ordinary path even when their text equals an operational envelope because Firstmate's authoritative producers are text-only.

A native exact-watcher run and its process-restart replay kept the neighboring assistant text at the two-row visible-only spacing while retaining one exact user entry and one processing response.
An adjacent two-notification run retained the same two-row neighboring-assistant coordinates, proving both operational components contributed zero height.
Calm off, an absent Calm preference, and an absent Calm extension retained ordinary rows.
The current exact marker and the narrow bare-U+2063 `Supervisor escalate (` compatibility shape hid under Calm, while quoted markers, ASCII `FIRSTMATE_OP:` without U+2063, ordinary text before the current marker, unrelated text after U+2063, and image-bearing input remained visible.

## Calm working presentation

The Pi behaviors this section relies on - the documented custom working-indicator frames, the `agent_settled` emission point, widget disposal under a repeated key, and the above-editor spacer row - were observed against the Pi 0.82.0 CLI on 2026-07-30, recorded in the [2026-07-30 revision verification](#2026-07-30-calm-working-presentation-revision-verification).
They have not been re-observed on 0.83.x or 0.84.2 and are unverified there; everything else below describes Calm's own implementation.

Calm replaces Pi's stock working row with a small animated boat while Calm is on and one logical agent run is active.
This path uses only public extension API and patches nothing: `ExtensionUIContext.setWorkingVisible(false)` hides the stock row, and `setWidget()` installs a temporary component factory above the editor.
Pi's documented custom working-indicator frames are static and width-blind, so they cannot own responsive geometry; a widget component receives `render(width)` and can.

`.pi/extensions/fm-calm.ts` remains the sole owner of the presentation choice and the only caller of `setWorkingVisible()`, while `.pi/extensions/lib/fm-calm-working-ship.ts` owns the sprite geometry, the bounce track, and the widget.
Visibility follows `agent_start` through `agent_settled` rather than turns or tool calls.
Pi emits `agent_settled` from a `finally` block once a run will not continue automatically, so retries, automatic continuations, queued follow-ups, and compaction inside one run never remove the boat, while settle, abort, and failure all reach the same cleanup.
Repeated `agent_start` events inside one run are idempotent, and Pi disposes the previous component before installing a replacement under the same key and when it clears extension widgets, so the frame timer cannot duplicate or outlive the widget.
Pi's above-editor widget container reserves one spacer row whether or not a widget is present, so removing the boat leaves no residual blank row.

The sprite is two rows when the usable width admits the complete hull: a two-cell mainsail centered over a symmetric `\__/` hull that replaces water on its row rather than adding a third row.
The sail is directional because a mainsail extends aft of the mast, so it renders `<|` while travelling right and `|>` while travelling left.
Direction reverses the moment the boat lands on an endpoint, so the endpoint frame itself already shows the new heading and no frame at or after a bounce shows the previous sail.
The water row fills the complete supplied width, the track is recomputed and clamped from that width on every frame so a resize cannot wrap or strand the boat offscreen, and widths too narrow for the hull fall back to a deterministic single row.

One scheduler drives two logically independent clocks.
Every tick advances a bounded fixed-cell water phase, and only every fourth tick moves the boat, so at a 220ms tick the water ripples several times between boat steps and the boat travels one column every 880ms.
Ticks rather than wall-clock timestamps drive every state change, so tests seek animation time exactly, and disposing the widget stops both clocks together.
Water phases are single-column ASCII, so advancing them never changes visible width, adds a row, or moves the hull column.

Colors are standard ANSI foreground codes rather than theme lookups: blue for every water cell and yellow for the complete boat, with no bright variant, 256-color, or RGB escape.
Each colored run is closed with a default-foreground reset so styling cannot bleed into the sail row's padding, neighbouring UI, or a later frame, and geometry is always computed from visible cells rather than escape bytes.

The presentation is TUI-only and visual-only.
It adds no session entry, transcript row, model context, or export or share content, and its widget takes no keyboard input, so editor focus and Escape abort are unchanged.
Compaction and retry loaders remain stock because Pi exposes no supported replacement for them.

## Central visibility and input policy

`.pi/extensions/lib/fm-calm-visibility.ts` owns only the allowlist-style transcript presentation policy.
`bin/fm-operational-input.sh` owns current cross-language operational-input construction and parsing, while the thin Pi adapter lives at `.pi/extensions/lib/fm-operational-input.ts`.
Only `genuine-user-prompt`, `genuine-agent-response`, and `working-status` are policy-visible.
Every other audited class is policy-hidden when Pi exposes a supported presentation boundary, but semantic input is never transformed to enforce that preference.
The home-local persistence schema is owned by [`docs/configuration.md`](configuration.md#pi-calm-preference-configcalm).

Current session-start, watcher, turn-end guard, away supervisor, and launch-brief inputs retain their versioned U+2063 static envelopes.
The established leading `[fm-from-firstmate]` plus U+2063 routing carrier remains current so running secondmate charters remain compatible.
An exact current static envelope remains sufficient provenance without nonce, source-authentication, replay-prevention, secondary-token, blocking, redaction, or private-retrieval machinery.
Calm classifies only at Pi's transcript-presentation owner through the canonical parser and never replaces, reorders, or weakens those messages.

The session-start nudge already originates as a non-displayed custom message, so it remains on that existing path while retaining model context and session persistence.
Legacy Calm custom entries and messages remain in existing session artifacts, and their presentation entry still uses the supported zero-height renderer while active.
Toggling Calm cycles tool expansion and restores its original value, which rebuilds controllable rows and leaves final `Ctrl+O` state unchanged.
Returning from stock export rendering instead invalidates only the tool rows Calm currently presents: Pi 0.83.0 made every expansion change emit its own status line, and Pi coalesces consecutive status lines, so an expansion cycle there overwrote the `Session exported to:` confirmation the export had just printed.
Exported and shared HTML retain genuine user prompts, genuine assistant responses, current operational user messages, ordinary tool rendering, and the complete session artifact.
Serialized session data and Pi 0.81.1's sidebar tree also retain legacy hidden operational custom messages.

## Pi transcript taxonomy surveyed on Pi 0.81.1

Surveyed on 2026-07-22 against Pi 0.81.1's installed public declarations, documentation, examples, `interactive-mode.js`, and its exported component implementations.
That survey has not been redone on 0.82.0 or 0.84.2, so its transcript paths and every `unsupported boundary` conclusion are 0.81.1 observations and are unverified on later Pi releases.
Two rows postdate it and carry their own dates instead: the Calm working-ship widget named in `working-status` was added on 2026-07-30 against the Pi 0.82.0 CLI, and the whole `assistant-working-note` row, transcript path included, was added on 2026-08-13 with its zero-height result observed on Pi 0.84.1.
What the fixtures exercise against whichever Pi is installed is narrower than the table: `tests/fm-calm-pi-extension.test.sh` walks `CALM_TRANSCRIPT_CLASSES` and asserts only the visible-or-hidden policy classification, while the interactive fixture renders the screenshot classes, current user-role operational input, and legacy synthetic presentation entries.

| Policy class | Pi transcript path | Calm result |
| --- | --- | --- |
| `genuine-user-prompt` | `UserMessageComponent` | Visible, including every tested operational near miss. |
| `genuine-agent-response` | Assistant text in `AssistantMessageComponent` | Visible. |
| `assistant-working-note` | Assistant text in an `AssistantMessageComponent` message the model did not end its response with, identified by its own `stopReason` of `toolUse`, or of `length` with tool calls present | The text blocks are removed from the shallow presentation copy before layout, so a `toolUse` message carrying only narration occupies zero rows (verified on Pi 0.84.1); a still-streaming `pending` message is never filtered, so narration is briefly visible before the marker flips. |
| `assistant-thinking` | Thinking content in `AssistantMessageComponent` | Collapsed reasoning is removed from the shallow presentation copy before layout and occupies zero rows; explicit expansion renders the original reasoning. |
| `assistant-tool-call` | `ToolExecutionComponent` | Seven built-ins and `fm_watch_arm_pi` hidden; arbitrary custom tools remain an unsupported boundary. |
| `tool-result` | `ToolExecutionComponent` | Text results for the controlled tools hidden; arbitrary custom results remain an unsupported boundary. |
| `tool-image` | Image children appended outside tool renderer slots | Unsupported boundary; remains visible. |
| `user-bash` | `BashExecutionComponent` for `!` and `!!` | Unsupported boundary; remains visible. |
| `skill-invocation` | `SkillInvocationMessageComponent` plus parsed user text | Unsupported boundary; remains visible. |
| `custom-message` | `CustomMessageComponent` when `display` is true | The session-start nudge and legacy Calm context messages use `display: false`; arbitrary extension messages remain an unsupported boundary. |
| `custom-entry` | `CustomEntryComponent` with a registered renderer | Legacy Calm presentation entries rebuild to zero children without a residual spacer and restore through ordinary expansion redraw when mounted; arbitrary extension entries remain an unsupported boundary. |
| `compaction-summary` | `CompactionSummaryMessageComponent` | Unsupported boundary; remains visible. |
| `branch-summary` | `BranchSummaryMessageComponent` | Unsupported boundary; remains visible. |
| `working-status` | `WorkingStatusIndicator`, or the Calm working-ship widget while Calm is active | Always visible. Calm off leaves Pi's stock row untouched; Calm on hides that row for the duration of one logical agent run and renders the working ship instead. |
| `command-status` | Interactive command result and status rows | Calm emits no enable notice, but generic Pi command rows remain an unsupported boundary. |
| `system-notice` | `showStatus`, `showError`, compaction, retry, and startup warning rows | Unsupported boundary; remains visible. |
| `cache-notice` | Non-persisted cache-miss `Text` row | Unsupported boundary; remains visible. |
| `project-trust-warning` | Non-persisted startup `Text` row | Unsupported boundary; remains visible. |
| `synthetic-user` | Firstmate extension `sendUserMessage`, terminal-injected input, Firstmate-generated Pi positional brief, or the already non-displayed session-start nudge | Canonically classified text-only operational user messages stay ordinary semantic user messages but render through the zero-height adapter (observed on Pi 0.81.1 and on 0.82.0; re-exercised on the installed 0.84.2 by the 2026-08-16 run, whose follow-up adjacent case is the intermittently failing one recorded there) under Calm; legacy entries stay gaplessly controllable, and the session-start nudge retains its existing non-displayed custom-message path. |
| `synthetic-assistant` | No authoritative Firstmate source found | Policy-hidden, but Pi exposes no generic assistant-role renderer. |
| `unknown` | Future or unclassified transcript component | Policy-hidden, but no generic renderer exists; never claimed as covered. |

The Pi 0.81.1 API survey found no supported global transcript filter, user-message renderer, assistant-message renderer, chat-container API, or generic custom-tool wrapper.
That survey has not been redone since, and the extension API did move afterwards - 0.84.2 adds an `expandPromptTemplates` option to `pi.sendUserMessage()` and a `defaultTools` setting - so the negative finding is unverified on 0.84.2.
`AssistantMessageComponent` and `InteractiveMode` were observed exported on Pi 0.81.1, on 0.82.0, and again on the installed 0.84.2 on 2026-08-16, where both patched hooks are still declared (`updateContent` in `assistant-message.d.ts`, `addMessageToChat` in `interactive-mode.d.ts`); that recheck read the declarations only and exercised nothing else.
Calm uses separate idempotent, API-probed adapters for assistant thinking layout and the complete operational-user transcript row while leaving all message data and non-Calm rendering unchanged; see the [compatibility contract](calm.md#pi-compatibility) for how a future Pi lacking one of those exports is handled.
General component replacement, ANSI cursor erasure, provider-context mutation, and installed-file patching remain rejected as unsupported or preservation-breaking workarounds.

## Cross-harness verification record

The original five-harness inspection was performed on 2026-07-22, with every integration surface rechecked and Pi reverified at 0.81.1 on 2026-07-23 for the latest Calm presentation change.

```text
$ claude --version
2.1.218 (Claude Code)
$ codex --version
codex-cli 0.144.6
$ opencode --version
1.17.18
$ pi --version
0.81.1
$ grok --version
grok 0.2.106 (bde89716f679)
```

Only Pi has been looked at since: on 2026-08-16 the Calm adapters were re-exercised end to end against the installed 0.84.2, recorded in the [2026-08-16 verification record](#2026-08-16-pi-0842-installed-version-verification).
The harness API survey behind the conclusions below was not redone on that version.
Claude Code, Codex CLI, OpenCode, and Grok CLI have not been reinspected since 2026-07-22 and are unverified on any later release.

| Harness | Conclusion | Evidence |
| --- | --- | --- |
| Claude Code 2.1.218 | Not feasible through the inspected supported project surface. | Project hooks can observe lifecycle and tool events, while the plugin CLI packages supported components; neither inspected surface exposes a transcript-row renderer or transcript-wide redraw API. |
| Codex CLI 0.144.6 | Not feasible through the inspected supported project surface. | The tracked hooks expose session, pre-tool, and stop handling, while the plugin and feature inventories expose no TUI tool-row renderer or transcript redraw control. |
| OpenCode 1.17.18 | Not feasible without violating the preservation boundary. | Plugins expose events and tool execution hooks, not a built-in transcript-row renderer; same-name tool replacement changes execution rather than presentation alone. |
| Pi 0.81.1 | Partially feasible with two API-probed exported-class adapters. | Surveyed 2026-07-22 and reverified at 0.81.1 on 2026-07-23: public APIs control working visibility, collapsed labels, known tool slots, custom entries, and expansion redraws; exported assistant and interactive-mode classes provide the collapsed-thinking and operational-user layout boundaries, gated on the exact method's presence rather than a version number, while generic user, tool, and status filtering remains unavailable. The adapter path was re-exercised end to end against the installed 0.84.2 on 2026-08-16; this row's API survey was not redone there. |
| Grok CLI 0.2.106 | Not feasible through the inspected supported project surface. | Project hooks expose lifecycle and tool interception, while the plugin CLI exposes no row-renderer contract; `--minimal` changes the whole screen mode rather than selected transcript rows. |

These conclusions are deliberately limited to the named versions and supported surfaces.
They do not claim that a harness can never add the missing renderer API.
For the duplicate-turn fix and the latest presentation change, the launch templates for Claude, Codex, OpenCode, Pi, and Grok and the watcher, turn-end, session-start, away-supervisor, and from-firstmate producers were re-inspected.
The canonical encoder and every non-Pi delivery path remain unchanged, and the tmux, Herdr, Zellij, Orca, and cmux runtime surfaces continue to transport the same input selected by the harness adapter.
Only Pi's Calm presentation implementation changed; every producer and non-Pi transport remains unchanged.

## Regression coverage

`tests/fm-calm-pi-extension.test.sh` compares wrapped and stock renderers, verifies all seven built-ins plus `fm_watch_arm_pi`, exercises redraw of already-rendered tool, thinking, current operational-user, and legacy synthetic rows, and covers every policy class.
It covers persisted preference restoration across every session-start reason and a real restart, proves the working-ship presentation and Calm-off stock `Working...` row through a delayed deterministic provider, asserts no Calm status row, verifies operational messages remain exact ordinary user-role session entries and complete exports, and drives genuine 100 by 44, 160 by 36, and 180 by 44 terminal fixtures.
A native deterministic `/skill:ahoy` turn produces thinking, tool-call, and tool-result blocks, asserts that the collapsed skill-to-final gap equals the two-row visible-only baseline, expands and re-collapses original thinking, restores Calm-off rendering, verifies persisted hidden history, and repeats the geometry assertion after restart with `terminal.clearOnShrink` explicitly off.
The operational provider path covers Calm loaded on, loaded off, default preference, extension absent, exact watcher delivery, narrow bare-marker legacy input, persisted restart replay, a genuine captain prompt, and adjacent notifications coalesced into one intended processing turn.
It asserts one persisted and rendered captain answer, exact user-role operational envelopes in order, no replacement custom messages, one processing result, zero operational transcript rows, and the two-row neighboring-assistant geometry for live, adjacent, and restart paths.
Quoted current markers, ASCII-only labels, ordinary text before a marker, unrelated U+2063 placement, and image-bearing input remain visible in component and native transcript checks.
`tests/fm-pi-primary-live-e2e.test.sh` also proves the working ship replaces the built-in `Working...` row while Calm is active on the credentialed provider path, and that it clears when the run settles, before continuing its ordinary watcher lifecycle.
`tests/fm-pi-primary-types.test.sh` performs strict no-emit TypeScript checking against the installed Pi declarations, currently package version 0.84.2 as read from the installed package manifest on 2026-08-16.
That package version is independent of the `pi` binary version: the last recorded typecheck ran against Pi 0.80.10 on 2026-08-15.
The test was rerun on 2026-08-16 but performed no typecheck, because `tsc` was absent from that machine and the script skips with `skip: tsc not found for Pi extension typecheck`, so the declarations are unverified against 0.84.2.

The relevant commands are:

```sh
tests/fm-calm-pi-extension.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
tests/fm-pi-primary-types.test.sh
```

## 2026-07-23 verification record

The deterministic provider preserves the complete real Pi TUI rendering path without using credentials.
The credentialed live regression remains opt-in and was not required because this change does not alter watcher delivery or provider integration.

```text
$ pi --version
0.81.1

$ tests/fm-calm-pi-extension.test.sh
ok - Pi calm extension is presentation-only with one persisted visibility choice, no Calm status row, native working visibility, supported redraw controls, and the Firstmate watcher-tool integration
ok - Pi calm resolves its persistent home independently of Pi's launch directory
ok - Pi calm centralizes transcript visibility, preserves execution/export data, keeps native working visible, and persists its choice across session starts
ok - Pi operational follow-up E2E processes exact user-role notifications once while Calm hides current and adjacent rows, Calm off and absent render them, and restart preserves semantics
ok - Pi Calm native /skill:ahoy geometry keeps every collapsed thinking and tool block at zero height while preserving expansion, history, restart, and Calm-off rendering
ok - Pi calm native E2E keeps Working and captain turns visible, hides exact operational user rows without changing persistence, restores them Calm-off, survives restart, and preserves export plus Ctrl+O behavior

$ tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-test-run.sh --changed --base origin/main
FM_TEST_SUMMARY total=38 failed=0 skipped_gate=7 duration_ms=166881
FM_TEST_SUMMARY_FAMILY family=live-harness-optin count=7 duration_ms=192 failed=0
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=31 duration_ms=165384 failed=0

$ tests/fm-pi-primary-live-e2e.test.sh
skip: set FM_PI_LIVE_E2E=1 to run the isolated interactive Pi regression
```

## 2026-07-26 Pi 0.82.0 compatibility verification

Pi 0.82.0 preserved both API-probed presentation seams and every deterministic Calm TUI guarantee.
The globally installed declaration package remained 0.81.1, so the strict typecheck continued to cover that earlier declaration-evidence version while the real CLI exercised 0.82.0.

```text
$ pi --version
0.82.0

$ tests/fm-calm-pi-extension.test.sh
ok - Pi calm extension is presentation-only with one persisted visibility choice, no Calm status row, native working visibility, supported redraw controls, and the Firstmate watcher-tool integration
ok - Pi calm resolves its persistent home independently of Pi's launch directory
ok - Pi calm centralizes transcript visibility, preserves execution/export data, keeps native working visible, and persists its choice across session starts
ok - Pi operational follow-up E2E processes exact user-role notifications once while Calm hides current and adjacent rows, Calm off and absent render them, and restart preserves semantics
ok - Pi Calm native /skill:ahoy geometry keeps every collapsed thinking and tool block at zero height while preserving expansion, history, restart, and Calm-off rendering
ok - Pi calm native E2E keeps Working and captain turns visible, hides exact operational user rows without changing persistence, restores them Calm-off, survives restart, and preserves export plus Ctrl+O behavior

$ tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1
```

## 2026-07-30 Calm working-presentation verification (superseded)

This record captures the first working-presentation implementation and is retained as pipeline history.
Its same-orientation sail, theme-derived colors, and single-cadence motion were all replaced later the same day; the revision record at the end of this document owns current behavior.

The working ship was verified against the installed Pi 0.82.0 CLI with a deterministic in-process provider and no credentials.
The globally installed declaration package remained 0.81.1, so the strict typecheck continued to cover that declaration-evidence version while the real CLI exercised 0.82.0.
The real-TUI regression captures two frames at different hull columns, resizes the same running TUI, asserts the reflowed water row equals the new width on a single wave row, types into the editor while the animation runs, aborts with Escape, and then proves Pi's stock `Working...` row returns with Calm off.

```text
$ pi --version
0.82.0

$ tests/fm-calm-pi-extension.test.sh
ok - Pi calm resolves its persistent home independently of Pi's launch directory
ok - Pi calm compatibility evidence never rejects a Pi version for being newer than 0.82.0, and still fails closed on a missing or malformed version
ok - a missing collapsed-thinking presentation API degrades only that Calm adapter with a clear skip reason, while the rest of Calm still registers
ok - missing Pi presentation class exports reach the independent adapter degradation path
ok - Pi calm centralizes transcript visibility, preserves execution/export data, keeps Pi's stock working row visible while no run is active, and persists its choice across session starts
ok - Pi operational follow-up E2E processes exact user-role notifications once while Calm hides current and adjacent rows, Calm off and absent render them, and restart preserves semantics
ok - Pi Calm native /skill:ahoy geometry keeps every collapsed thinking and tool block at zero height while preserving expansion, history, restart, and Calm-off rendering
ok - Pi Calm working ship renders an exact two-row full-width sprite, clamps every resize, bounces at both edges, falls back deterministically when narrow, and installs and removes one timer-owning widget across starts, settle, abort, failure, shutdown, reload, replacement, and Calm toggles
ok - Pi calm native E2E replaces the stock working row with a moving, resize-clamped working ship that clears on abort, keeps captain turns visible, hides exact operational user rows without changing persistence, restores stock rendering Calm-off, survives restart, and preserves export plus Ctrl+O behavior

$ tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=57 local_links=160

$ bin/fm-test-run.sh --changed --base origin/main
FM_TEST_SUMMARY total=32 failed=0 skipped_gate=7 duration_ms=196009
FM_TEST_SUMMARY_FAMILY family=live-harness-optin count=7 duration_ms=202 failed=0
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=25 duration_ms=194670 failed=0
```

One rendered frame at 120 columns, with Pi's stock working row hidden and the boat directly above the editor:

```text
 |>
\__/~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

The same run after resizing that TUI to 64 columns, showing the waves refilled to the new width on one row with the boat still on screen:

```text
                         |>
~~~~~~~~~~~~~~~~~~~~~~~~\__/~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

Colors at that time were confirmed from an escape-preserving capture as theme-derived entries; the revision below replaced them with standard ANSI blue and yellow.
Pressing Escape during a run left `Operation aborted` with no boat and no residual blank row, and toggling Calm off restored Pi's stock `⠴ Working...` row on the next run.

## 2026-07-30 Calm working-presentation revision verification

The revision replaced the single-cadence, theme-colored, same-orientation sprite with a slower boat over independently animated water, standard ANSI colors, and a directional mainsail.
It was verified against the installed Pi 0.82.0 CLI with a deterministic in-process provider and no credentials.

```text
$ pi --version
0.82.0

$ tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=57 local_links=163

$ bin/fm-test-run.sh --changed --base origin/main
FM_TEST_SUMMARY total=32 failed=0 skipped_gate=7 duration_ms=386738
FM_TEST_SUMMARY_FAMILY family=live-harness-optin count=7 duration_ms=257 failed=0
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=25 duration_ms=383010 failed=0
```

Real Pi TUI observations from the isolated deterministic trial at 100 columns.
The hull column held steady across consecutive samples while the water pattern shifted, then advanced about one column every 880ms, which separates the two cadences:

```text
hull_col=12  water=~-~~~-~~~-~\__/~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~
hull_col=12  water=~~~-~~~-~~~\__/-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-
hull_col=13  water=~~-~~~-~~~-~\__/~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~
hull_col=16  (about 2.6s later)
```

An escape-preserving capture confirmed standard ANSI foreground codes only, blue water and yellow boat, with a default-foreground reset closing each run:

```text
^[[34m~~~-~~~-~~~-~~~^[[33m\__/^[[34m-~~~-~~~-~~~-~~~-...
^[[33m<|^[[39m
```

Resizing the same running TUI to 12 columns shortened the track enough to observe both reversals, each already showing the heading it was about to travel:

```text
left-heading :          |>  over  ~-~~~-~~\__/
right-heading:  <|          over  \__/~~-~~~-~
```

At 3 columns the sprite fell back to a single exact-width row, `<|~`.
Escape aborted the run leaving `Operation aborted`, no boat, and no stale sprite rows, and the trial exited 0 after deleting its temporary state.

## 2026-08-15 Pi 0.84.1 export-confirmation verification

Pi 0.83.0 added a status line to every tool-expansion change, which silently broke the `/export` confirmation under Calm on Pi 0.83.0 and newer.
Pi appends `Session exported to: <path>` through `showStatus`, which updates the previous status line in place whenever two status messages arrive back to back with nothing else added to the chat.
Calm's post-export redraw cycled tool expansion on the macrotask right after that, so both of its expansion status lines coalesced over the confirmation and left no record of where the export landed.
Calm now invalidates only the tool rows it presents and requests the redraw through `setStatus`, neither of which appends to the transcript.

Pi source evidence, from the installed release's own changelog and interactive mode:

```text
$ pi --version
0.84.1

CHANGELOG.md, 0.83.0 "Fixed":
- Added a status line when the tool output expansion is toggled ([#7180](https://github.com/earendil-works/pi/issues/7180)).

interactive-mode setToolsExpanded:
  setToolsExpanded(expanded) {
    if (expanded === this.toolOutputExpanded)
      return;
    ...
    this.showStatus(`Tool output: ${expanded ? "expanded" : "collapsed"}`);
  }
```

The regression is pinned by the real-terminal `/export` case in `tests/fm-calm-pi-extension.test.sh`, which now asserts the confirmation is still on screen after Calm's redraw has settled and that the redraw restored every Calm-hidden row.
Reverting only the extension fix fails that assertion deterministically rather than racing the roughly 50ms window the confirmation used to survive:

```text
not ok - Calm's post-export repaint overwrote Pi's export confirmation (missing: 'Session exported to: .../calm-export.html')
```

```text
$ tests/fm-calm-pi-extension.test.sh
ok - Pi calm resolves its persistent home independently of Pi's launch directory
ok - Pi calm compatibility evidence never rejects a Pi version for being newer than 0.82.0, and still fails closed on a missing or malformed version
ok - a missing collapsed-thinking presentation API degrades only that Calm adapter with a clear skip reason, while the rest of Calm still registers
ok - missing Pi presentation class exports reach the independent adapter degradation path
ok - Calm registers none of its 7 built-in tool wrappers at load while config/calm is off, and all 7 synchronously at load while config/calm is on
ok - Calm's first same-session /calm activation claims every uncontested built-in, leaves a foreign bash tool fully intact and callable, warns prominently and logs the contested name, and only rows constructed before that activation - the documented bound - fail to retroactively collapse
ok - Pi calm centralizes transcript visibility, preserves execution/export data, keeps Pi's stock working row visible while no run is active, and persists its choice across session starts
ok - Pi calm on collapses mid-turn assistant working notes to zero height while Calm off keeps them, leaves streaming, truncated-final, and genuine final replies untouched, never mutates the messages, ignores every /calm argument, and restores a legacy persisted max as ordinary Calm on
ok - Pi operational follow-up E2E processes exact user-role notifications once while Calm hides current and adjacent rows, Calm off and absent render them, and restart preserves semantics
ok - Pi Calm native /skill:ahoy geometry keeps every collapsed thinking and tool block at zero height while preserving expansion, history, restart, and Calm-off rendering
ok - Pi Calm working ship moves on a slow independent cadence over faster fixed-cell blue water, paints the complete boat standard yellow with balanced resets, keeps ANSI-stripped width exact, flips the directional sail on the exact bounce at both edges and every width, clamps visible and hidden resizes, falls back deterministically when narrow, freezes and resumes column/direction across settle/start without hidden-time jumps or duplicate timers, resets only on a fresh session, and installs and removes one scheduler-owning widget across starts, settle, abort, failure, shutdown, reload, replacement, and Calm toggles while leaving Calm-off visibility untouched
ok - Pi calm native E2E replaces the stock working row with a moving, resize-clamped working ship that freezes and resumes across two working periods in one Pi session, clears on abort, keeps captain turns visible, hides exact operational user rows without changing persistence, restores stock rendering Calm-off, survives restart, and preserves export plus Ctrl+O behavior

$ tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.80.10

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=68 local_links=253

$ bin/fm-test-run.sh --changed --base origin/main
FM_TEST_SUMMARY total=46 failed=0 skipped_gate=16 duration_ms=279390
FM_TEST_SUMMARY_FAMILY family=live-harness-optin count=16 duration_ms=431 failed=0
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=30 duration_ms=277700 failed=0
```

## 2026-08-16 Pi 0.84.2 installed-version verification

Observed on 2026-08-16: the installed Pi is 0.84.2, `tests/fm-calm-pi-extension.test.sh` completed one clean run against it, and the two exported classes the adapters patch are still declared with their patched hooks.
That is what this entry records.
The run exercises the 0.84.1 export-confirmation fix and the guarantees the suite covers, and nothing beyond them.
Several 0.84.2 changes fall outside what the suite exercises and were not tested against Calm.
Reading the 0.84.2 CHANGELOG surfaced three that touch Calm's surface: the new `defaultTools` setting, which selects the initial built-in tool set globally or per project, while Calm registers its seven built-in wrappers synchronously at load only when the persisted preference is already on and none while Calm is off (see [Built-in tool override constraints](#built-in-tool-override-constraints)); the changed fallback rendering for extension tool results, which now collapses long output and honors tool expansion; and the experimental strict JSON-schema constrained sampling for the default `read`, `bash`, `edit`, and `write` tools under `PI_EXPERIMENTAL=1`, which covers four of the seven built-ins Calm re-registers under the same names.
That is what one CHANGELOG reading found, not an exhaustive audit of the release.

```text
$ pi --version
0.84.2

$ jq -r .version "$(npm root -g)/@earendil-works/pi-coding-agent/package.json"
0.84.2

$ cd "$(npm root -g)/@earendil-works/pi-coding-agent"

$ grep -oE 'AssistantMessageComponent|InteractiveMode' dist/index.d.ts | sort -u
AssistantMessageComponent
InteractiveMode

$ grep -oE 'updateContent|addMessageToChat' dist/modes/interactive/components/assistant-message.d.ts dist/modes/interactive/interactive-mode.d.ts | sort -u
dist/modes/interactive/components/assistant-message.d.ts:updateContent
dist/modes/interactive/interactive-mode.d.ts:addMessageToChat

$ tests/fm-pi-primary-types.test.sh
skip: tsc not found for Pi extension typecheck

$ tests/fm-calm-pi-extension.test.sh
ok - Pi calm resolves its persistent home independently of Pi's launch directory
ok - Pi calm compatibility evidence never rejects a Pi version for being newer than 0.82.0, and still fails closed on a missing or malformed version
ok - a missing collapsed-thinking presentation API degrades only that Calm adapter with a clear skip reason, while the rest of Calm still registers
ok - missing Pi presentation class exports reach the independent adapter degradation path
ok - Calm registers none of its 7 built-in tool wrappers at load while config/calm is off, and all 7 synchronously at load while config/calm is on
ok - Calm's first same-session /calm activation claims every uncontested built-in, leaves a foreign bash tool fully intact and callable, warns prominently and logs the contested name, and only rows constructed before that activation - the documented bound - fail to retroactively collapse
ok - Pi calm centralizes transcript visibility, preserves execution/export data, keeps Pi's stock working row visible while no run is active, and persists its choice across session starts
ok - Pi calm on collapses mid-turn assistant working notes to zero height while Calm off keeps them, leaves streaming, truncated-final, and genuine final replies untouched, never mutates the messages, ignores every /calm argument, and restores a legacy persisted max as ordinary Calm on
ok - Pi operational follow-up E2E processes exact user-role notifications once while Calm hides current and adjacent rows, Calm off and absent render them, and restart preserves semantics
ok - Pi Calm native /skill:ahoy geometry keeps every collapsed thinking and tool block at zero height while preserving expansion, history, restart, and Calm-off rendering
ok - Pi Calm working ship moves on a slow independent cadence over faster fixed-cell blue water, paints the complete boat standard yellow with balanced resets, keeps ANSI-stripped width exact, flips the directional sail on the exact bounce at both edges and every width, clamps visible and hidden resizes, falls back deterministically when narrow, freezes and resumes column/direction across settle/start without hidden-time jumps or duplicate timers, resets only on a fresh session, and installs and removes one scheduler-owning widget across starts, settle, abort, failure, shutdown, reload, replacement, and Calm toggles while leaving Calm-off visibility untouched
ok - Pi calm native E2E replaces the stock working row with a moving, resize-clamped working ship that freezes and resumes across two working periods in one Pi session, clears on abort, keeps captain turns visible, hides exact operational user rows without changing persistence, restores stock rendering Calm-off, survives restart, and preserves export plus Ctrl+O behavior
```

The follow-up adjacent case intermittently fails a pane-capture timing race (`Pi follow-up adjacent case rendered a duplicate captain answer`), so the run above is a clean run rather than a uniformly reproducible pass.
That race was measured on 2026-08-16 at 9 failures in 24 executions, at the same rate under both interpreters, and diagnosed there as a test-harness race rather than a Calm behavior break.
A fix for it was written the same day in PR #2477 (branch `fm/fm-calm-bash5-regression`, head `adce327`), which was still open and unmerged on 2026-08-16.
That fix is therefore in no branch of this repository, `main` included: the failure is reachable wherever this suite runs today, and the diagnosis rests on that measurement rather than on anything in the code this document describes.
