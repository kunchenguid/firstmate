# Calm-mode harness feasibility

This document owns the version-scoped feasibility evidence, Pi transcript taxonomy, and supported-API boundaries for Firstmate calm mode.
The README owns the user-facing `/calm` usage and limitation contract.

## Required extension surface

A qualifying implementation must auto-load from the trusted project, keep the toggle session-local, redraw already-rendered controllable rows, restore ordinary rendering, and leave delivery, tool execution, model context, session storage, export and share operation, diagnostics, and expansion state unchanged.
The governing presentation policy allows only genuine original user prompts and genuine user-facing assistant text.
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

The smallest counterfactuals produced these results:

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
- Pi's HTML exporter ignores plain custom entries and `display: false` custom messages and does not invoke TUI renderers, so synthetic control inputs cannot retain stock user styling in exported or shared HTML through Pi 0.81.1's supported API.

The disconfirming checks deliberately retained contradictory evidence.
An arbitrary third-party custom tool and a built-in read image remain visible because Pi exposes neither a global tool renderer nor image-row control.
An expanded thinking fixture remains visible, and an empty collapsed-thinking label leaves blank spacing, so this implementation does not claim complete reasoning-row removal.
An ordinary user prompt may quote or reuse watcher, guard, startup, or supervisor wording and remains visible unless it carries a structurally valid operational envelope.

## Central visibility and injection policy

`.pi/extensions/lib/fm-calm-visibility.ts` owns the allowlist-style transcript policy and delivery into Pi's structured hidden context entries.
`bin/fm-operational-input.sh` owns current cross-language operational-input construction and parsing, while the thin Pi adapter lives at `.pi/extensions/lib/fm-operational-input.ts`.
Only `genuine-user-prompt` and `genuine-agent-response` are policy-visible.
Every other audited class is policy-hidden even when Pi currently lacks a supported renderer for enforcing that result.

Current session-start, watcher, turn-end guard, away supervisor, and launch-brief inputs use the versioned kind carried after the landed U+2063 `FIRSTMATE_OP: ` prefix.
The established leading `[fm-from-firstmate]` plus U+2063 routing carrier remains current and is parsed as `from-firstmate` through the same owner so running secondmate charters remain compatible.
Pi persists the resulting exact kind in both the presentation entry and the non-displayed context message.
A landed untyped `FIRSTMATE_OP` input is retained as `legacy-operational` rather than having a subtype inferred from its body.
Narrow pre-protocol parsing for the exact startup line, watcher and guard shapes, and bare-marker away escalation is isolated from the current parser.
The per-process `FM_FIRSTMATE_PI_LAUNCH_BRIEF` binding remains only as compatibility for a raw launch created before typed launch instructions.

Positive fixtures cover every current kind and a separate legacy matrix.
Near-miss fixtures cover quoted operational content, ASCII-only labels, arbitrary U+2063-prefixed text, altered legacy text, visible routing labels without U+2063, and launch-brief text without its source binding.

Synthetic inputs that would otherwise render as user rows are rerouted only at Pi input presentation time.
Their full text is persisted in a non-displayed custom message that Pi converts back to an ordinary user message for provider context, and a TUI-only custom entry restores stock user styling while Calm is off.
The session-start nudge already uses a non-displayed custom message at its authoritative source, so it remains on that existing hidden presentation path while retaining model context and session persistence.
The custom-entry host omits the complete row when the renderer returns undefined under Calm, including its normally conditional leading spacer.
Cycling tool expansion and restoring its original value rebuilds those custom entries and leaves final `Ctrl+O` state unchanged.
Exported and shared HTML retain genuine user prompts, genuine assistant responses, and ordinary tool rendering, while omitting the synthetic presentation entry and hidden context message at the documented Pi 0.81.1 exporter boundary.

## Complete currently reachable Pi transcript taxonomy

The taxonomy was derived from Pi 0.81.1's installed public declarations, documentation, examples, `interactive-mode.js`, and its exported component implementations.
The test fixture enumerates every class below through the centralized policy, and the interactive fixture exercises the screenshot classes plus positive and negative synthetic user presentation.

| Policy class | Pi transcript path | Calm result on Pi 0.81.1 |
| --- | --- | --- |
| `genuine-user-prompt` | `UserMessageComponent` | Visible. |
| `genuine-agent-response` | Assistant text in `AssistantMessageComponent` | Visible. |
| `assistant-thinking` | Working indicator and thinking content in `AssistantMessageComponent` | Live working row and collapsed labels hidden; expanded reasoning and reserved collapsed spacing remain unsupported boundaries. |
| `assistant-tool-call` | `ToolExecutionComponent` | Seven built-ins and `fm_watch_arm_pi` hidden; arbitrary custom tools remain an unsupported boundary. |
| `tool-result` | `ToolExecutionComponent` | Text results for the controlled tools hidden; arbitrary custom results remain an unsupported boundary. |
| `tool-image` | Image children appended outside tool renderer slots | Unsupported boundary; remains visible. |
| `user-bash` | `BashExecutionComponent` for `!` and `!!` | Unsupported boundary; remains visible. |
| `skill-invocation` | `SkillInvocationMessageComponent` plus parsed user text | Unsupported boundary; remains visible. |
| `custom-message` | `CustomMessageComponent` when `display` is true | Firstmate's known synthetic context messages use `display: false`; arbitrary extension messages remain an unsupported boundary. |
| `custom-entry` | `CustomEntryComponent` with a registered renderer | Firstmate's synthetic presentation entry is mounted synchronously, rebuilt to zero children without a residual spacer, and restored by the ordinary expansion redraw; arbitrary extension entries remain an unsupported boundary. |
| `compaction-summary` | `CompactionSummaryMessageComponent` | Unsupported boundary; remains visible. |
| `branch-summary` | `BranchSummaryMessageComponent` | Unsupported boundary; remains visible. |
| `working-status` | `WorkingStatusIndicator` | Hidden through `setWorkingVisible(false)`. |
| `command-status` | Interactive command result and status rows | Calm emits no enable notice, but generic Pi command rows remain an unsupported boundary. |
| `system-notice` | `showStatus`, `showError`, compaction, retry, and startup warning rows | Unsupported boundary; remains visible. |
| `cache-notice` | Non-persisted cache-miss `Text` row | Unsupported boundary; remains visible. |
| `project-trust-warning` | Non-persisted startup `Text` row | Unsupported boundary; remains visible. |
| `synthetic-user` | Firstmate extension `sendUserMessage`, terminal-injected input, Firstmate-generated Pi positional brief, or the already non-displayed session-start nudge | Forms that ordinarily render as user rows are rerouted to hidden context plus a gapless controllable presentation entry; the session-start nudge retains its existing non-displayed custom-message path. |
| `synthetic-assistant` | No authoritative Firstmate source found | Policy-hidden, but Pi exposes no generic assistant-role renderer. |
| `unknown` | Future or unclassified transcript component | Policy-hidden, but no generic renderer exists; never claimed as covered. |

The installed extension API has no supported global transcript filter, user-message renderer, assistant-message renderer, chat-container access, or generic custom-tool wrapper.
Runtime prototype replacement, ANSI cursor erasure, provider-context mutation, and installed-file patching were rejected as unsupported or preservation-breaking workarounds.

## Cross-harness verification record

The original five-harness inspection was performed on 2026-07-22, with Pi reverified at 0.81.1 for this change.

```text
$ claude --version
2.1.216 (Claude Code)
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
| Claude Code 2.1.216 | Not feasible through the inspected supported project surface. | Project hooks can observe lifecycle and tool events, while the plugin CLI packages supported components; neither inspected surface exposes a transcript-row renderer or transcript-wide redraw API. |
| Codex CLI 0.144.6 | Not feasible through the inspected supported project surface. | The tracked hooks expose session, pre-tool, and stop handling, while the plugin and feature inventories expose no TUI tool-row renderer or transcript redraw control. |
| OpenCode 1.17.18 | Not feasible without violating the preservation boundary. | Plugins expose events and tool execution hooks, not a built-in transcript-row renderer; same-name tool replacement changes execution rather than presentation alone. |
| Pi 0.81.1 | Partially feasible and implemented to the supported boundary. | Public APIs control working visibility, collapsed labels, known tool slots, custom entries, and expansion redraws, but not built-in message containers or generic tool and status rows. |
| Grok CLI 0.2.106 | Not feasible through the inspected supported project surface. | Project hooks expose lifecycle and tool interception, while the plugin CLI exposes no row-renderer contract; `--minimal` changes the whole screen mode rather than selected transcript rows. |

These conclusions are deliberately limited to the named versions and supported surfaces.
They do not claim that a harness can never add the missing renderer API.

## Regression coverage

`tests/fm-calm-pi-extension.test.sh` compares wrapped and stock renderers, verifies all seven built-ins plus `fm_watch_arm_pi`, exercises redraw of already-rendered tool and synthetic rows, checks the gapless mounted custom-entry lifecycle, preserves a transient diagnostic while restoring an entry received under Calm, covers every policy class and synthetic fixture, covers session reset reasons, asserts the rendered export DOM, and drives a genuine 180 by 44 interactive terminal fixture.
`tests/fm-pi-primary-types.test.sh` performs strict no-emit TypeScript checking against the installed Pi 0.81.1 declarations.

The relevant commands are:

```sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-primary-types.test.sh
```
