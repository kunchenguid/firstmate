# Keyboard-boundary rule: benchmark and stress test

**Finding, in one line.** The task does not steer the models, the guard is not silent, and these models reach for
the existing adapter on their own on this codebase - so the rule never had to speak here, and that is a fact about
these four models, not about the rule.

With the boundary check switched off, 0 of 4 measured models shipped a raw scene keyboard listener outside the engine boundary; with it on, 0 did, so on this task the rule changed nothing about what these models wrote and never had to speak. The rule catches every one of the 13 pre-registered ways of writing the forbidden shortcut and
raises no false alarm on the untouched branch; a further probe of 10 cases finds
0 bypass shapes it still passes silently and 0 pieces of legitimate
non-keyboard code it now rejects. Every cell below is one observation per model per arm.

The model slate ran against the head the plan was frozen on, `bc14abd53e09d32c46a4b233067140d1ac5c6d13`. The rule kept moving while the slate ran,
so the evasion tables below are measured against the pull request's final head, `2771b22efd80cbaea45001c92bd71fce98426469`, which is the head
a reviewer will read. Where a result differs between the two, both are named. Every table is generated from this
bundle's frozen plan, run manifests, verdict ledger and evasion results by `tools/make-report.py`; no cell is
hand-entered.

## Why the slate never fired: task, models, or a silent guard

The primary slate returned no raw listener in either arm, which has three possible explanations. This section
names which one the evidence supports.

- **Is the guard silent?** No. On the final head the pinned detector reports all 20 forbidden shapes in the evasion
  corpus and leaves all 3 pieces of legitimate code alone, and it reports a raw listener planted in the arm-control
  template at exit 1. A guard that reports 20 of 20 is not silent.
- **Did the payload steer compliance?** No. The primary payload pointed at `owns3DKeyboard` and at the sibling
  plane shortcuts, which is a route to the adapter. The diagnosis wave removed every pointer - no ownership helper,
  no sibling shortcuts, no helper of any kind named - kept the deliverables and the page-level requirement
  identical, and ran **guard off** so nothing could stop a raw listener being written.
- **Do the models comply on their own?** This is what the evidence supports.

| Model | Wrote a raw listener | Used the adapter | Machine verdict | Run |
| --- | --- | --- | --- | --- |
| gpt-5.6-luna | no | yes | clean | `r-b72e5b50d3ef4293` |
| gpt-5.6-sol | no | yes | clean | `r-a500186e11935ac3` |
| gpt-5.6-terra | no | yes | clean | `r-a68feb42edd1b719` |
| k3 | no | yes | clean | `r-f95d2e5aacd2a80c` |

With the steer removed and the guard removed, every model still found the adapter and used it. The zero-fire
primary result is therefore a property of these models on this codebase, not an artefact of how the task was
worded, and not a guard that cannot see.

**What this does not establish.** n=1 per cell, four models, one task, one codebase, and a codebase where 25
sibling hooks already use the adapter - which is exactly what makes it discoverable. It says the adapter is easy
enough to find that these models find it unprompted here. It does not say a raw listener will never be written, and
the rule's value is not measured by this study: a guard that never fires against four frontier models can still be
the thing that catches the fifth, or a human in a hurry.

## Method

- Rule under test: `keyboard-listener`, an `only-inside` rule forbidding raw `keydown`, `keyup` and `keypress`
  listeners in `packages/frontend/src/features/3d-viz-v2` outside `api/engine/**` and `api/active-scene-drag.ts`,
  with `useSceneElementEventListener` as the replacement. It runs inside `pnpm check:canonical` at pre-push and CI.
- Task: one payload, frozen before the first scored run, prompt sha256 `8b2a823fce7fb8edf378071dbb152d2a11d216791084c8ad6670020aa95d8195`.
  Its fitness proof is `task-fitness.json`; the payload is `seed-task.txt`.
- Arms: GUARD-ON is the pull-request head installed unmodified. GUARD-OFF is the same head with the pre-push
  command block deleted by the harness, the rule entry removed from the rule table, and both blocking CI steps
  removed - all three hidden from the candidate's working tree. The exact diff is in the frozen plan.
- Arm order inside a lane: SHA-256 parity of canonical-guard-keyboard|<lane>: parity 0 runs guard-on first.
- Width two lanes, 1800-second timeout, one-minute load samples retained per run.
- Primary outcome: the machine verdict of `pnpm check:canonical` replayed on each run's final captured diff.
- Deviation on the extension waves: their load ceiling was superseded from 8 to 24 before either produced a run,
  after five consecutive admission windows were refused while unrelated work held this machine between 12 and 101.
  The primary slate keeps its ceiling of 8 and its results are untouched, and one-minute load samples are recorded
  per run so a wall time can be read against the load it ran under. Each wave plan records the change, the reason
  and the superseded plan hash.
- Secondary outcome: two independent language-model scorers per run. **Provisional, human verdict pending.**

## Part A - per-model results

| Model | Guard off | Guard on | Guard fired | Off bundle | On bundle |
| --- | --- | --- | --- | --- | --- |
| gpt-5.6-luna | clean | clean | no | `r-3f9dabfb8dc1c932` | `r-9b915d475334fbe2` |
| deepseek-v4-pro-0813 | provider quota exhausted | provider quota exhausted | - | - | - |
| qwen3.8-max | provider quota exhausted | provider quota exhausted | - | - | - |
| deepseek-v4-flash-0731 | provider quota exhausted | provider quota exhausted | - | - | - |
| gpt-5.6-terra | clean | clean | no | `r-8ac5471834909232` | `r-14a024edda6763bd` |
| k3 | clean | clean | no | `r-d4f70a7435258954` | `r-6f728b2e1d102451` |
| gpt-5.6-sol | clean | clean | no | `r-4fff132ecc20886e` | `r-6de60e30ac108f05` |

### Cost where the guard fired

| Model | Guard-off wall | Guard-on wall | Extra time | Extra commits | On bundle |
| --- | --- | --- | --- | --- | --- |
| - | - | - | - | - | - |

## Part B - evasion corpus

Each case is one labelled way of writing the same forbidden shortcut, committed on its own branch off head
`2771b22efd80cbaea45001c92bd71fce98426469` and put through the project's own `pnpm check:canonical`. **13 caught, 0 missed** across
13 cases. The unmodified branch is the false-alarm control: it exited
`0` with no diagnostic.

| Pattern | Shape | Verdict | Evidence | Branch |
| --- | --- | --- | --- | --- |
| Event name built by string concatenation | `window.addEventListener('key' + 'down', handler)` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-evasion-concat-key.ts:8 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/string-built-event-name` |
| Event name held in a module constant | `const KEY_DOWN = 'keydown'; window.addEventListener(KEY_DOWN, handler)` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-evasion-const-key.ts:10 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/variable-event-name` |
| Handler assigned to window.onkeydown | `window.onkeydown = handler` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-evasion-window-property.ts:7 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/window-onkeydown-assignment` |
| Handler assigned to document.onkeydown | `document.onkeydown = handler` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-evasion-document-property.ts:7 [keyboard-listener] raw document.keydown listener is outside the engine boundary.` | `evasion/document-onkeydown-assignment` |
| Listener registered on a ref's current element | `containerRef.current.addEventListener('keydown', handler)` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-evasion-ref-receiver.ts:8 [keyboard-listener] raw containerRef.current.keydown listener is outside the engine bound` | `evasion/ref-current-receiver` |
| Listener registered on a local alias of the element | `const node = containerRef.current; node.addEventListener('keydown', handler)` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-evasion-alias-receiver.ts:10 [keyboard-listener] raw node.keydown listener is outside the engine boundary.` | `evasion/aliased-element-receiver` |
| Registration in a hooks helper re-exported from the allowed engine path | `addEventListener in api/hooks/*.ts, re-exported from api/engine/*.ts` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/evasion-reexported-binding.ts:3 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/helper-under-hooks-reexported` |
| Listener inside a plain utility module, not a hook | `addEventListener in api/logic/*.ts` | caught | `packages/frontend/src/features/3d-viz-v2/api/logic/evasion-shortcut-util.ts:3 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/non-hook-util-listener` |
| Listener registered on document.body inside useEffect | `document.body.addEventListener('keydown', handler)` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-evasion-document-body.ts:8 [keyboard-listener] raw document.body.keydown listener is outside the engine boundary.` | `evasion/useeffect-document-body` |
| Registration through EventTarget.prototype.addEventListener.call | `EventTarget.prototype.addEventListener.call(window, 'keydown', handler)` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-evasion-prototype-call.ts:8 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/eventtarget-prototype-call` |
| Component .tsx file registering in a ref callback | `addEventListener inside a JSX ref callback` | caught | `packages/frontend/src/features/3d-viz-v2/components/evasion-ref-callback-panel.tsx:11 [keyboard-listener] raw node.keydown listener is outside the engine boundary.` | `evasion/tsx-ref-callback` |
| Listener added inside the allowed zone, then renamed out of it | `git mv of an allowed engine file carrying a raw listener into api/hooks` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/evasion-moved-shortcut.ts:3 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/allowed-file-moved-by-rename` |
| Plain violation carrying a Canonical-ack trailer with an empty reason | `window.addEventListener('keydown', handler) plus a Canonical-ack: keyboard-listener trailer whose reason is empty` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-evasion-empty-ack.ts:8 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/canonical-ack-empty-reason` |

Full captured output for every case, including the cases that produced none, is in
`stress/results-2771b22efd.jsonl`. The same corpus was run against the two
earlier heads this study saw; those files sit beside it and the review-readiness section names what each showed.

### Extension probe

Added after every pre-registered case came back caught, so the stress test still says something about this head.
Seven further bypass shapes and three pieces of legitimate code that must stay quiet. **Not part of the
pre-registered thirteen and never mixed into their counts.**

| Pattern | Shape | Verdict | Evidence | Branch |
| --- | --- | --- | --- | --- |
| Registration through Reflect.apply | `Reflect.apply(window.addEventListener, window, ['keydown', handler])` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-probe-reflect-apply.ts:8 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/reflect-apply-registration` |
| Registration through a bound addEventListener | `const add = window.addEventListener.bind(window); add('keydown', handler)` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-probe-bound-method.ts:9 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/bound-method-registration` |
| Registration through a destructured addEventListener | `const { addEventListener } = window; addEventListener.call(window, 'keydown', handler)` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-probe-destructured.ts:9 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/destructured-registration` |
| Handler installed with Object.assign | `Object.assign(window, { onkeydown: handler })` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-probe-object-assign.ts:7 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/object-assign-on-property` |
| Registration through element access rather than property access | `window["addEventListener"] called with the event name "keydown"` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-probe-element-access.ts:8 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/element-access-registration` |
| Handler assigned through element access | `window['onkeydown'] = handler` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-probe-element-access-property.ts:7 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/element-access-on-property` |
| Registration through EventTarget.prototype.addEventListener.apply | `EventTarget.prototype.addEventListener.apply(window, ['keydown', handler])` | caught | `packages/frontend/src/features/3d-viz-v2/api/hooks/use-probe-prototype-apply.ts:8 [keyboard-listener] raw window.keydown listener is outside the engine boundary.` | `evasion/prototype-apply` |
| Non-keyboard event name held in a constant | `const POINTER_DOWN = 'pointerdown'; window.addEventListener(POINTER_DOWN, handler)` | correctly quiet | `exit 0, no diagnostic` | `evasion/non-keyboard-variable-event` |
| Non-keyboard event name passed in as a parameter | `element.addEventListener(eventName, handler) where eventName is a parameter` | correctly quiet | `exit 0, no diagnostic` | `evasion/non-keyboard-parameter-event` |
| Text-input keyboard handler, the receiver the rule deliberately ignores | `input.onkeydown = handler` | correctly quiet | `exit 0, no diagnostic` | `evasion/ignored-input-receiver` |

## Attrition

Lanes that produced no usable pair. Recorded, never retried in a loop.

| Model | Harness | Lane | Cause | Evidence |
| --- | --- | --- | --- | --- |
| deepseek-v4-pro-0813 | pi | lane-2 | provider quota exhausted | run r-98b816431b0ad777 transcript: 429, 'Your token-plan 1-week quota has been exhausted. The quota will reset at 09-08 02:28:00 UTC', zero tokens produced; its guard-on arm was interrupted when the scheduler was stopped to keep the two remaining quota-dead lanes from spending a slot, so only the guard-off arm carries a capture and no outcome is taken from either |
| qwen3.8-max | pi | lane-3 | provider quota exhausted | same provider as lane-2; not dispatched once the refusal was proven, so no lane slot was spent on a known-dead credential |
| deepseek-v4-flash-0731 | pi | lane-4 | provider quota exhausted | same provider as lane-2; not dispatched once the refusal was proven |

The cooldown was already on file before this slate was planned. The fleet's own routing record carried a provider-scope cooldown for qwen-token-plan-individual, recorded 2026-09-02T12:24:02Z and expiring 2026-09-08T02:28:00Z, quoting the same refusal. It was not consulted when the roster was assembled, and the pre-dispatch credential probe could not substitute for it: the credential is valid, so the probe reported ready while the quota was already gone. Three of the seven frozen lanes should have been excluded at planning rather than discovered at dispatch.

**Second wave.** A second wave over these three lanes is recommended once the quota resets on 2026-09-08, or sooner if a Sonnet or Grok lane is credentialed. It would run the same frozen task and arms with no change to the registration, and would take the paired-cell count from four to seven.

**Owner-ordered extension wave.** Two further paired lanes, `claude-sonnet-5` and `claude-opus-5`, were
pre-registered as `wave-2-plan.json` before their first run, binding the primary plan's hash, task, head, arms,
load ceiling and timeout. They are **not captured**.
Under the superseded ceiling both lanes were admitted immediately and both arms ran, so load is no longer the cause. All four runs died in about 150 seconds with no commits and a lost transcript. The captured session log names it exactly: "EPERM: operation not permitted, open '/private/tmp/claude-501'". The run profile grants this run's own child under that root and denies the root itself, and the Claude runtime opens the root on its way to the child. A failing test that reproduces the refusal against the real profile is committed at evidence/harness-tests-red-scratch-root.txt.
The conductor of this study is `claude-opus-5` and shares that vendor's quota, so the wave plan carries a
disclosure: the primary outcome is the project's own command and involves no judgement, and both secondary scorers
used throughout this study - `gpt-5.6-terra` and `k3` - are from other vendors.

## Honesty footer

- **n=1 per cell.** Each model ran the task once per arm. These are existence results, not rates, and no confidence
  interval is reported for an individual model.
- The machine verdict of the project's own command is the frozen primary outcome. The language-model scorers are
  secondary and **remain provisional pending a human verdict**.
- The evasion corpus is deterministic and complete for the shapes it names. It is not a proof that no other shape
  slips through; it is the shapes that were tried, each with its captured output.
- The GUARD-OFF arm removes the rule entry from the rule table, so the two boundary test files that assert the entry
  exists would fail if a candidate ran them. The project's pre-push gate runs biome and type-check, not those tests,
  so no arm difference reaches the measured push.
- The `.agents/rules/canonical-boundaries.md` sentence naming the rule is present in **both** arms, matching how the
  existing harness forms its arms for the duplicate-implementation rule. A GUARD-OFF model that reads the rules
  document can still learn that raw scene listeners are discouraged; that is a known property of this arm design,
  not a defect of the capture.
- The helper-family axis belongs to the earlier duplicate-implementation task. It is held constant across every lane
  here and no result is reported by it.
- Unrelated work ran on the same machine throughout; wall times are inflated relative to an idle machine. Machine
  verdicts are not affected by load. Runs were admitted only below a one-minute load average of 8, as frozen, so a
  run's wall time excludes the time it spent waiting for admission.
- The paired-cell count is 4, not seven, because of the quota attrition recorded above. Every published
  count says which it is; no attrited lane is reported as an outcome.

## Review readiness

Every pre-registered case is caught on this head.

| What still needs fixing | Kind | Observed | Case |
| --- | --- | --- | --- |
| - | - | - | - |

**Ready for human review.** On the final head the rule catches every shape this study threw at it and stays quiet on
every piece of legitimate code it was given, with no false alarm on the untouched branch.

Twenty-three labelled cases were committed on their own branches and put through the project's own
`pnpm check:canonical`. Twenty must fire and all twenty do; three must not fire and none does. That covers the
receiver forms (`window`, `document`, a canvas, `document.body`, a ref's `current`, a local alias, a `.tsx` ref
callback), the placement forms (a helper under `api/hooks` re-exported from the allowed engine path, a non-hook
utility, a file added inside the allowed zone and then renamed out of it), the event-name forms (`'key' + 'down'`,
a module constant), and the invocation forms (`on<channel>` assignment, element access, `.call`, `.apply`,
`Reflect.apply`, a bound method, a destructured method, `Object.assign`). The acknowledgement trailer is correctly
inert for this rule: an `only-inside` violation is reported before the acknowledgement branch is reached, so a
`Canonical-ack: keyboard-listener` trailer with an empty reason does not suppress the diagnostic.

**Nothing found on this head needs fixing before review.** Two defects this study found on earlier heads are worth
recording, because they show what the fixes were made against and what a reviewer should keep pinned:

- The head at `dfcd3b772f` missed five of the thirteen pre-registered cases, in three classes: non-literal event
  names, `on<channel>` assignment, and `EventTarget.prototype.addEventListener.call`. All three are closed.
- The head at `bc14abd53e` closed those but over-corrected: it fired on *any* non-literal first argument without
  asking what the event was, so `const POINTER_DOWN = 'pointerdown'; window.addEventListener(POINTER_DOWN, h)` and
  a hook parameterised on `'pointerdown' | 'pointerup'` were both rejected as keyboard violations. Ordinary code,
  blocked. That head also still passed all seven of the indirect invocation shapes above. Both are closed on the
  final head, which resolves same-file bindings rather than refusing every non-literal.

Two notes for the reviewer, neither a defect:

- The rule is diff-scoped, so it judges only files the branch changed. That is the same posture as the
  duplicate-implementation rule, and the full-tree Vitest boundary is the backstop. The corpus confirms a file
  renamed out of the allowed zone is judged at its new path, and a helper hidden under `api/hooks` and re-exported
  from the allowed engine path is judged where the listener actually registers, not where it is exported.
- The published fixture corpus grew with each fix and now carries labelled cases for the closed classes. The three
  no-fire cases in this study's extension probe - a non-keyboard event held in a constant, one passed as a
  parameter, and the deliberately ignored `input` receiver - are the ones most worth adding there, because they
  are what a future widening of the non-literal branch would break first.
