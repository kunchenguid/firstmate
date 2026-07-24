# Calm-mode harness feasibility

This document owns the version-scoped feasibility evidence, Pi transcript taxonomy, and supported-API boundaries for Firstmate calm mode.
[`calm.md`](calm.md) owns the current user-facing `/calm` usage and limitation contract.

## Required extension surface

A qualifying implementation must auto-load from the trusted project, persist the toggle choice for the effective Firstmate home across Pi session starts and resumes, keep Pi's built-in working activity visible, emit no Calm status row, redraw already-rendered controllable rows, remove supported hidden rows without gaps, restore ordinary rendering, and leave delivery, tool execution, model context, session storage, export and share operation, diagnostics, and expansion state unchanged.
The governing presentation policy allows genuine original user prompts, genuine user-facing assistant text, and Pi's native working activity.
Changing persisted context to remove hidden content, filtering provider context, patching installed harness code, or claiming coverage outside a supported renderer does not satisfy that boundary.

## Pi 0.81.1 end-to-end reproduction

The current installed and regression-supported Pi version was verified on 2026-07-22.

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

The fix installs one idempotent Pi 0.81.1 presentation adapter on the exported `AssistantMessageComponent.updateContent` method.
Only while Calm is active and Pi has collapsed thinking does the adapter pass a shallow thinking-free presentation copy into Pi's ordinary layout calculation, then retain the original message on the component for invalidation and thinking expansion.
The persisted assistant message, provider context, tool execution, export data, and expansion history remain unchanged.
Collapsed thinking-only assistant messages now render zero rows, thinking before visible assistant text adds no spacing beyond the text-only baseline, and expanding thinking still renders the original reasoning.

The disconfirming checks deliberately retain supported boundaries.
An arbitrary third-party custom tool and a built-in read image remain visible because Pi exposes neither a global tool renderer nor image-row control.
Expanded thinking remains visible by design, while re-collapsing it returns to zero-height Calm presentation.
Ordinary user-role near misses remain visible, including quoted current markers, ASCII-only labels, unrelated text before a marker, unrelated text after U+2063, and image-bearing input.

## Duplicate-turn regression and semantic boundary

The captain-visible regression reproduced three consecutive times in the persisted Pi session at `/Users/kunchen/.pi/agent/sessions/--Users-kunchen-github-kunchenguid-firstmate--/2026-07-23T16-37-24-672Z_019f8fd6-c440-7641-b2bf-8065dab1622a.jsonl`.
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

The fix installs a separate idempotent Pi 0.81.1 presentation adapter on the exported `InteractiveMode.addMessageToChat` method.
It delegates current recognition to `bin/fm-operational-input.sh`, adds only the evidence-backed bare-U+2063 `Supervisor escalate (` presentation compatibility shape, mounts a `UserMessageComponent` subclass that preserves Pi's stock row plus leading spacer while Calm is off, and returns zero rendered lines while Calm is on.
It never intercepts the input event, rewrites the message, changes its role, filters model context, or changes session data.
Messages containing an image are left on Pi's ordinary path even when their text equals an operational envelope because Firstmate's authoritative producers are text-only.

A native exact-watcher run and its process-restart replay kept the neighboring assistant text at the two-row visible-only spacing while retaining one exact user entry and one processing response.
An adjacent two-notification run retained the same two-row neighboring-assistant coordinates, proving both operational components contributed zero height.
Calm off, an absent Calm preference, and an absent Calm extension retained ordinary rows.
The current exact marker and the narrow bare-U+2063 `Supervisor escalate (` compatibility shape hid under Calm, while quoted markers, ASCII `FIRSTMATE_OP:` without U+2063, ordinary text before the current marker, unrelated text after U+2063, and image-bearing input remained visible.

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
Cycling tool expansion and restoring its original value rebuilds controllable rows and leaves final `Ctrl+O` state unchanged.
Exported and shared HTML retain genuine user prompts, genuine assistant responses, current operational user messages, ordinary tool rendering, and the complete session artifact.
Serialized session data and Pi 0.81.1's sidebar tree also retain legacy hidden operational custom messages.

## Complete currently reachable Pi transcript taxonomy

The taxonomy was derived from Pi 0.81.1's installed public declarations, documentation, examples, `interactive-mode.js`, and its exported component implementations.
The test fixture enumerates every class below through the centralized policy, and the interactive fixture exercises the screenshot classes, current user-role operational input, and legacy synthetic presentation entries.

| Policy class | Pi transcript path | Calm result on Pi 0.81.1 |
| --- | --- | --- |
| `genuine-user-prompt` | `UserMessageComponent` | Visible, including every tested operational near miss. |
| `genuine-agent-response` | Assistant text in `AssistantMessageComponent` | Visible. |
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
| `working-status` | `WorkingStatusIndicator` | Visible through Pi's unchanged built-in row while Calm is active. |
| `command-status` | Interactive command result and status rows | Calm emits no enable notice, but generic Pi command rows remain an unsupported boundary. |
| `system-notice` | `showStatus`, `showError`, compaction, retry, and startup warning rows | Unsupported boundary; remains visible. |
| `cache-notice` | Non-persisted cache-miss `Text` row | Unsupported boundary; remains visible. |
| `project-trust-warning` | Non-persisted startup `Text` row | Unsupported boundary; remains visible. |
| `synthetic-user` | Firstmate extension `sendUserMessage`, terminal-injected input, Firstmate-generated Pi positional brief, or the already non-displayed session-start nudge | Canonically classified text-only operational user messages stay ordinary semantic user messages but render through the zero-height Pi 0.81.1 adapter under Calm; legacy entries stay gaplessly controllable, and the session-start nudge retains its existing non-displayed custom-message path. |
| `synthetic-assistant` | No authoritative Firstmate source found | Policy-hidden, but Pi exposes no generic assistant-role renderer. |
| `unknown` | Future or unclassified transcript component | Policy-hidden, but no generic renderer exists; never claimed as covered. |

The installed extension API has no supported global transcript filter, user-message renderer, assistant-message renderer, chat-container API, or generic custom-tool wrapper.
Pi 0.81.1 exports `AssistantMessageComponent` and `InteractiveMode`, so Calm uses separate exact-version, idempotent adapters for assistant thinking layout and the complete operational-user transcript row while leaving all message data and non-Calm rendering unchanged.
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

| Harness | Conclusion | Evidence |
| --- | --- | --- |
| Claude Code 2.1.218 | Not feasible through the inspected supported project surface. | Project hooks can observe lifecycle and tool events, while the plugin CLI packages supported components; neither inspected surface exposes a transcript-row renderer or transcript-wide redraw API. |
| Codex CLI 0.144.6 | Not feasible through the inspected supported project surface. | The tracked hooks expose session, pre-tool, and stop handling, while the plugin and feature inventories expose no TUI tool-row renderer or transcript redraw control. |
| OpenCode 1.17.18 | Not feasible without violating the preservation boundary. | Plugins expose events and tool execution hooks, not a built-in transcript-row renderer; same-name tool replacement changes execution rather than presentation alone. |
| Pi 0.81.1 | Partially feasible with two exact-version exported-class adapters. | Public APIs control working visibility, collapsed labels, known tool slots, custom entries, and expansion redraws; exported assistant and interactive-mode classes provide the version-pinned collapsed-thinking and operational-user layout boundaries, while generic user, tool, and status filtering remains unavailable. |
| Grok CLI 0.2.106 | Not feasible through the inspected supported project surface. | Project hooks expose lifecycle and tool interception, while the plugin CLI exposes no row-renderer contract; `--minimal` changes the whole screen mode rather than selected transcript rows. |

These conclusions are deliberately limited to the named versions and supported surfaces.
They do not claim that a harness can never add the missing renderer API.
For the duplicate-turn fix and the latest presentation change, the launch templates for Claude, Codex, OpenCode, Pi, and Grok and the watcher, turn-end, session-start, away-supervisor, and from-firstmate producers were re-inspected.
The canonical encoder and every non-Pi delivery path remain unchanged, and the tmux, Herdr, Zellij, Orca, and cmux runtime surfaces continue to transport the same input selected by the harness adapter.
Only Pi's Calm presentation implementation changed; every producer and non-Pi transport remains unchanged.

## Regression coverage

`tests/fm-calm-pi-extension.test.sh` compares wrapped and stock renderers, verifies all seven built-ins plus `fm_watch_arm_pi`, exercises redraw of already-rendered tool, thinking, current operational-user, and legacy synthetic rows, and covers every policy class.
It covers persisted preference restoration across every session-start reason and a real restart, proves Pi's native `Working...` row through a delayed deterministic provider, asserts no Calm status row, verifies operational messages remain exact ordinary user-role session entries and complete exports, and drives genuine 100 by 44, 160 by 36, and 180 by 44 terminal fixtures.
A native deterministic `/skill:ahoy` turn produces thinking, tool-call, and tool-result blocks, asserts that the collapsed skill-to-final gap equals the two-row visible-only baseline, expands and re-collapses original thinking, restores Calm-off rendering, verifies persisted hidden history, and repeats the geometry assertion after restart with `terminal.clearOnShrink` explicitly off.
The operational provider path covers Calm loaded on, loaded off, default preference, extension absent, exact watcher delivery, narrow bare-marker legacy input, persisted restart replay, a genuine captain prompt, and adjacent notifications coalesced into one intended processing turn.
It asserts one persisted and rendered captain answer, exact user-role operational envelopes in order, no replacement custom messages, one processing result, zero operational transcript rows, and the two-row neighboring-assistant geometry for live, adjacent, and restart paths.
Quoted current markers, ASCII-only labels, ordinary text before a marker, unrelated U+2063 placement, and image-bearing input remain visible in component and native transcript checks.
`tests/fm-pi-primary-live-e2e.test.sh` also proves the unchanged built-in `Working...` row while Calm is active on the credentialed provider path before continuing its ordinary watcher lifecycle.
`tests/fm-pi-primary-types.test.sh` performs strict no-emit TypeScript checking against the installed Pi 0.81.1 declarations.

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
