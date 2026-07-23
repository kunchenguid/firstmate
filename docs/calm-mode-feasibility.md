# Calm-mode harness feasibility

This document owns the version-scoped feasibility evidence, Pi transcript taxonomy, and supported-API boundaries for Firstmate calm mode.
The README owns the user-facing `/calm` usage and limitation contract.

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

The pre-cleanup reproduction used a real isolated Pi TUI at 180 columns by 44 rows with the tracked Calm and watcher extensions, an isolated `FM_HOME`, and a live home-owned watcher cycle.
The model called `fm_watch_arm_pi`, the real tool returned `watcher: started Pi extension arm child 1`, and a `done:` status write caused the watcher extension to inject `FIRSTMATE WATCHER WAKE: signal: ...` followed by the stable drain instruction.
With Calm off, the captured transcript contained the genuine user prompt, the full watcher tool shell, the synthetic user-role wake, four collapsed `Thinking...` labels, built-in tool rows from wake handling, and the final assistant response.
With the pre-cleanup implementation's Calm mode on, the existing seven built-in tool rows disappeared, but the watcher tool shell, synthetic wake, and all four `Thinking...` labels remained.
The final screenshot-scale regression reproduced the same transcript after the cleanup and verified that Calm removed those remaining controlled rows while retaining the genuine prompt, a watcher-shaped genuine near-miss prompt, and the genuine assistant responses.

The observed causal separation was:

| Row | Initiating trigger | Masking condition | Visible symptom |
| --- | --- | --- | --- |
| Collapsed thinking | A model assistant turn contained non-empty `thinking` content. | Pi's thinking setting was collapsed, so `AssistantMessageComponent` rendered its configured hidden-thinking label instead of full reasoning; Calm previously touched only tool definitions. | One italic `Thinking...` row remained for each reasoning-bearing assistant turn. |
| Firstmate watcher tool | The model called the tracked `fm_watch_arm_pi` custom tool. | Calm overrode only Pi's seven built-ins, while this tool followed Pi's custom-tool fallback renderer. | The full custom call and result shell remained. |
| Synthetic watcher input | The live watcher closed on an actionable signal and `fm-primary-pi-watch.ts` called `sendUserMessage`. | Pi stored and rendered the injected content as an ordinary `user` role with no origin renderer hook. | The wake prefix and stable drain instruction looked like a captain-authored prompt. |

The proven comparison path was a built-in text tool.
Calm already owned both of that tool's supported renderer slots and switched its shell to `renderShell: "self"`, so returning empty components removed the complete row and `setToolsExpanded` redrew existing tool components.
The earliest divergence for the watcher was its separate custom fallback definition, and the earliest divergence for thinking and user-role injections was Pi's built-in message component path rather than `ToolExecutionComponent`.

The original presentation-feasibility counterfactuals produced these results.
The later duplicate-turn evidence below supersedes custom-message rerouting as an acceptable implementation even where these rendering observations remain true.

- Calling `setWorkingVisible(false)` removed the live working row without reserving space.
- Calling `setHiddenThinkingLabel("")` removed every collapsed `Thinking...` label, but Pi's `AssistantMessageComponent` retained one leading spacer for each reasoning-bearing message.
- Expanding thinking still rendered full reasoning because Pi exposes no supported getter or setter for the transcript-wide thinking expansion state.
- Adding supported empty renderer slots to a scratch copy of `fm_watch_arm_pi` removed its row while the real watcher still started and the model still returned `PROBE_COMPLETE`.
- Delivering a scratch custom message with `display: false` still produced the model response `SYNTHETIC_DELIVERED` and persisted the full custom message in session JSONL.
- Pairing that hidden context message with a TUI-only custom entry allowed Calm to hide and restore the synthetic user presentation with no content loss.
- Pi's `CustomMessageComponent` unconditionally adds a leading spacer before invoking a registered message renderer, so returning an empty component cannot hide the whole row.
- Pi's `CustomEntryComponent` adds spacing only when its renderer returns content, so an undefined Calm renderer result removes the complete live row without a residual gap.
- Pi does not add a `CustomEntryComponent` whose initial renderer result is undefined, while a component already added to the chat remains mounted after a later expansion rebuild clears all of its children.
- Synthetic delivery therefore mounts its presentation synchronously before Pi's `entry_appended` event returns, then immediately cycles the supported expansion state so Calm removes the host spacer and content while retaining the zero-height parent for later restoration.
- Pi coalesces those synchronous render requests, so the genuine interactive fixture shows neither the temporary presentation nor a blank gap.
- Whole-transcript reconstruction was rejected because it drops non-persisted diagnostics and adds an unrelated navigation status row.
- Pi's HTML exporter omits plain custom entries and `display: false` custom messages from the main message transcript and does not invoke TUI renderers, but the complete artifact retains legacy hidden operational text in serialized session data and the sidebar tree.

The disconfirming checks deliberately retained contradictory evidence.
An arbitrary third-party custom tool and a built-in read image remain visible because Pi exposes neither a global tool renderer nor image-row control.
An expanded thinking fixture remains visible, and an empty collapsed-thinking label leaves blank spacing, so this implementation does not claim complete reasoning-row removal.
Every ordinary user-role message remains visible, including a genuine captain prompt that quotes watcher, guard, startup, or supervisor wording and a structurally valid operational envelope.

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

Pi 0.81.1 exposes no supported renderer for ordinary user-role rows.
The fix therefore removes Calm's input handler and custom-message delivery path completely.
Current operational input remains an exact ordinary user-role message, keeps its ordering and authority, and remains visible under Calm rather than risking duplicate or lost processing.
Legacy `firstmate-synthetic-input-presentation` entries remain renderable so existing sessions still preserve their stored presentation and zero-height hidden-row behavior.
A final 120 by 28 native Pi TUI capture with Calm persisted on showed one genuine captain row, one captain answer, one visible exact watcher row, and one monitoring result with only Pi's standard message spacing.
It showed no duplicate assistant row, residual hidden-row gap, Calm status, lost native activity control, or hidden captain content.

## Central visibility and input policy

`.pi/extensions/lib/fm-calm-visibility.ts` owns only the allowlist-style transcript presentation policy.
`bin/fm-operational-input.sh` owns current cross-language operational-input construction and parsing, while the thin Pi adapter lives at `.pi/extensions/lib/fm-operational-input.ts`.
Only `genuine-user-prompt`, `genuine-agent-response`, and `working-status` are policy-visible.
Every other audited class is policy-hidden when Pi exposes a supported presentation boundary, but semantic input is never transformed to enforce that preference.
The home-local persistence schema is owned by [`docs/configuration.md`](configuration.md#pi-calm-preference-configcalm).

Current session-start, watcher, turn-end guard, away supervisor, and launch-brief inputs retain their versioned U+2063 static envelopes.
The established leading `[fm-from-firstmate]` plus U+2063 routing carrier remains current so running secondmate charters remain compatible.
An exact current static envelope remains sufficient provenance without nonce, source-authentication, replay-prevention, secondary-token, blocking, redaction, or private-retrieval machinery.
Calm does not classify, replace, reorder, or weaken those messages.

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
| `genuine-user-prompt` | `UserMessageComponent` | Visible. |
| `genuine-agent-response` | Assistant text in `AssistantMessageComponent` | Visible. |
| `assistant-thinking` | Thinking content in `AssistantMessageComponent` | Collapsed labels hidden; expanded reasoning and reserved collapsed spacing remain unsupported boundaries. |
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
| `synthetic-user` | Firstmate extension `sendUserMessage`, terminal-injected input, Firstmate-generated Pi positional brief, or the already non-displayed session-start nudge | Current user-role forms remain ordinary visible user rows because Pi has no safe renderer for them; legacy Calm presentation entries stay gaplessly controllable, and the session-start nudge retains its existing non-displayed custom-message path. |
| `synthetic-assistant` | No authoritative Firstmate source found | Policy-hidden, but Pi exposes no generic assistant-role renderer. |
| `unknown` | Future or unclassified transcript component | Policy-hidden, but no generic renderer exists; never claimed as covered. |

The installed extension API has no supported global transcript filter, user-message renderer, assistant-message renderer, chat-container access, or generic custom-tool wrapper.
Runtime prototype replacement, ANSI cursor erasure, provider-context mutation, and installed-file patching were rejected as unsupported or preservation-breaking workarounds.

## Cross-harness verification record

The original five-harness inspection was performed on 2026-07-22, with every integration surface rechecked and Pi reverified at 0.81.1 on 2026-07-23 for this change.

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
| Pi 0.81.1 | Partially feasible and implemented to the supported boundary. | Public APIs control working visibility, collapsed labels, known tool slots, custom entries, and expansion redraws, but not built-in message containers or generic tool and status rows. |
| Grok CLI 0.2.106 | Not feasible through the inspected supported project surface. | Project hooks expose lifecycle and tool interception, while the plugin CLI exposes no row-renderer contract; `--minimal` changes the whole screen mode rather than selected transcript rows. |

These conclusions are deliberately limited to the named versions and supported surfaces.
They do not claim that a harness can never add the missing renderer API.
For the duplicate-turn fix, the launch templates for Claude, Codex, OpenCode, Pi, and Grok and the watcher, turn-end, session-start, away-supervisor, and from-firstmate producers were re-inspected.
The canonical encoder and every non-Pi delivery path remain unchanged, and the tmux, Herdr, Zellij, Orca, and cmux runtime surfaces continue to transport the same input selected by the harness adapter.
Only Pi's obsolete Calm launch binding and semantic input interceptor were removed.

## Regression coverage

`tests/fm-calm-pi-extension.test.sh` compares wrapped and stock renderers, verifies all seven built-ins plus `fm_watch_arm_pi`, exercises redraw of already-rendered tool and legacy synthetic rows, checks zero-height hidden legacy entries, covers every policy class, covers persisted preference restoration across session-start reasons and a real restart/resume, proves Pi's native `Working...` row through a delayed deterministic provider, asserts no Calm status row, verifies current operational rows remain ordinary user messages in the TUI and complete exports, and drives a genuine 180 by 44 interactive terminal fixture.
The same test runs a native deterministic Pi provider path that fails on landed PR 927 and covers Calm loaded on, loaded off, extension absent, restart with persisted state, a genuine captain prompt, and adjacent notifications coalesced into one intended processing turn.
It asserts one persisted and rendered captain answer, exact user-role operational envelopes in order, no replacement custom messages, and one processing result.
`tests/fm-pi-primary-live-e2e.test.sh` also proves the unchanged built-in `Working...` row while Calm is active on the credentialed provider path before continuing its ordinary watcher lifecycle.
`tests/fm-pi-primary-types.test.sh` performs strict no-emit TypeScript checking against the installed Pi 0.81.1 declarations.

The relevant commands are:

```sh
tests/fm-calm-pi-extension.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
tests/fm-pi-primary-types.test.sh
```
