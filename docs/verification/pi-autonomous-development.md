# Pi autonomous-development verification

This record supports the active guarantees in [Pi autonomous development](../pi-autonomous-development.md).
It is maintainer evidence, not operator setup.
[Configuration](../configuration.md#pi-linear-autonomy-configpi-autonomyjson) owns setup.

## Fixture boundary

The implementation and standard regressions are source-only.
They do not read a real Linear credential, call a live Linear workspace, mutate an external project, create a worker endpoint, push a branch, open a PR, or merge anything.
The Linear transport is injected with recorded GraphQL responses, and project, delivery, and landing adapters are fixture implementations.
Live credentialed activation remains a separate captain-facing setup step after the delivering PR lands.

## Accepted held-out baseline

Accepted on 2026-08-25.

- Decision contract version: `2026-08-25.10`.
- Contract fingerprint: `contract-d790ac73dac4fb4af15f15d0`.
- Stable prompt SHA-256: `a74e3e79ea2690c90fb4109ce2f4457fc57668e9f5c3a20950b6a93644c26c22`.
- Recorded classifier outputs SHA-256: `664a96544e7d9416851d0a84e033d2f1ea3c5c70b11a617a6b3109078d30236c`.
- Model policy: the selected supervision model must be runtime-authenticated without any Linear-credential collision, fit the configured context ceiling, remain distinct and strictly cheaper across main-model changes, and preflight each bounded turn against the cost window, while worker dispatch preserves Firstmate's existing reasoning policy.
- Cases: 11 passed, 0 failed.
- Corpus: `tests/fixtures/fm-autonomy-heldout.json`.
- Production-interface recordings: `tests/fixtures/fm-autonomy-recorded-outputs.json`.
- Baseline: `tests/fixtures/fm-autonomy-baseline.json`.

The retained disconfirming cases prove seven easy-to-miss directions.
Same-repository work can be independent with concrete disjoint evidence.
Different repositories can collide through one shared mutable resource.
A docs-only quote containing the word production is not automatically a production operation.
A small authorization change remains security-sensitive whatever its diff size.
Routine retained context waits for `nextTurn` without waking main.
Only exact already-accounted duplicate evidence coalesces.
A routine event still wakes main when it requires a main-session operation.

Refresh command:

```sh
bin/fm-autonomy.sh eval
```

Exact accepted output fields:

```text
"passed":11
"failed":0
"accepted":true
```

A prompt, model-selection policy, tool-schema, collision, or stronger-boundary change is incomplete until this command compares against the baseline and the accepted baseline is deliberately reviewed with every disconfirming case retained.

## Portable executable interfaces

Observed on 2026-08-25 with Node 22.22.3 and Pi coding-agent 0.84.2.

```sh
bin/fm-test-run.sh tests/fm-autonomy-core.test.sh
bin/fm-test-run.sh tests/fm-autonomy-cli.test.sh
bin/fm-test-run.sh tests/fm-pi-autonomy-extension.test.sh
bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh
bin/fm-test-run.sh tests/fm-pr-merge.test.sh
```

Observed outcomes:

```text
ok - Pi autonomy core executable interface and held-out baseline hold
ok - Pi autonomy CLI is inert by default, reports exact config failures, preserves work under kill, and enforces the held-out baseline
ok - active Pi autonomy extension behavior holds
ok - branch owns accepted wakes with a stable prefix contract and verdict-driven merge delivery
ok - fm-pr-merge binds the green autonomous GitHub merge to the exact current head
ok - fm-pr-merge refuses moved and red autonomous GitHub heads before mutation
ok - fm-pr-merge autonomous green path accepts no caller-controlled merge arguments
```

The core regression covers stable event ordering and dedupe, finalized visible transcript commits, structured decision validation, routine `nextTurn`, idle urgent wake, working-main steer, crash replay, persisted acknowledgement, usage and cache totals, preflight cost refusal with retained events, Linear pagination, reset-header retry, GraphQL errors, workspace and label refusal, issue dependency direction, exact claim ownership, marker-injection neutralization, issue-ID-plus-URL attachment idempotence, restart reconciliation after a landed-but-unrecorded merge, policy-binding tamper refusal, conflict edges, independent-set capacity, heavy-validation capacity, durable capacity-deferral replay, kill behavior, merge-before-close ordering, red refusal, and stronger-boundary refusal.
The active extension regression proves lock-refused startup performs no model-auth resolution, lock-owned activation is deferred safely, the configured cheaper model is revalidated after a main-model change, output is capped, only one narrow terminating decision tool exists, bash is never created, the prompt is byte-stable, idle and working delivery modes are exact, visible transcript mirrors stay silent, hidden/tool/operational content is excluded, autonomy-session persistence is contract-bound, over-cap context rotates with bounded recent transcript replay, usage is journaled, and the Linear credential leaves provider and worker ambient environments.
The PR helper regression proves the current head is reread, the check summary requires at least one pass with none failed or pending, moved and red heads stop before the mutation, and GitHub's merge uses `expectedHeadOid` through `gh-axi`.

## Real Pi SDK compatibility

The strict no-emit check compiles every tracked Pi extension and its autonomy module against the installed Pi declarations:

```sh
bin/fm-test-run.sh tests/fm-pi-primary-types.test.sh
```

The existing credential-free real-SDK guard remains the on-demand construction check:

```sh
FM_PI_BRANCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh
```

On 2026-08-25 against Pi SDK 0.84.2 that credential-free branch guard printed `ok - real Pi SDK 0.84.2 accepts the branch session construction and preserves an unpromptable wake`.
It intentionally has no autonomy config or credential, so it proves the default path stays unchanged and inert.

The active-autonomy guard uses the installed Pi SDK, configured provider authentication, a real cheaper-model `AgentSession`, and the production `fm_supervision_decide` contract. It performs one model classification against a no-claim held-out event and never constructs a Linear, Firstmate project, forge, dispatch, or merge adapter:

```sh
FM_PI_AUTONOMY_LIVE_E2E=1 \
FM_PI_AUTONOMY_LIVE_PROVIDER=<provider> \
FM_PI_AUTONOMY_LIVE_MODEL=<model-id> \
bin/fm-test-run.sh tests/fm-pi-autonomy-live-e2e.test.sh
```

The authenticated active-autonomy guard has not been observed in this credential-free repository verification environment; activation requires an explicitly configured provider/model pair and provider authentication.
A live Linear mutation is deliberately not part of repository validation.
They belong to the captain's post-merge activation check.

## Supported primary and runtime consequences

Pi and pi-signed share the tracked Pi extension surface, so a valid home-local config selects the same read-only branch behavior in either Pi-family primary.
The configured intelligence does not alter which primary executable launches.
Claude, Codex, OpenCode, Grok, Kimi, Cursor, and Muse do not load `.pi/extensions/fm-branch-supervision.ts`, so the config and state paths are inert for those primaries.
All worker harnesses remain selected through the existing dispatch-profile and `fm-spawn` contracts.
Main must still resolve registered secondmate scopes before claim; cross-home claim handoff is not an autonomous v1 path and therefore routes to main instead of being guessed locally.
The autonomy module introduces no worker-harness launch flags.

The Firstmate adapter delegates endpoint isolation to `fm-spawn`, so tmux, Herdr, Zellij, Orca, and cmux retain their existing capability checks, worktree ownership, and cleanup rules.
An explicit backend is accepted only as a main-resolved per-task profile input.
The autonomy module does not auto-select a backend and cannot make an unsupported secondmate or runtime combination valid.
Machine capacity is checked before claim and separately limits heavy validation, so parallel issue selection does not imply parallel no-mistakes work beyond the configured local ceiling.

## Linear contract evidence

The adapter contract was checked against Linear's official current references on 2026-08-25:

- [GraphQL](https://linear.app/developers/graphql).
- [Pagination](https://linear.app/developers/pagination).
- [Filtering](https://linear.app/developers/filtering).
- [Rate limiting](https://linear.app/developers/rate-limiting).
- [Webhooks](https://linear.app/developers/webhooks).
- [Attachments](https://linear.app/developers/attachments).

The fixture pins personal-key and OAuth authorization shapes, GraphQL errors at HTTP 200, `RATELIMITED`, reset headers, Relay cursors, workspace identity, team/project/state filters, local all-required-label and blocked-label checks, directional `blocks` relations, `issueUpdate`, `commentCreate`, and `attachmentCreate`.
No account limit is hard-coded because the official rate-limit page and returned account policy can change.
