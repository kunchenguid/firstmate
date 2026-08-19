# Feishu channel verification

This record contains current deterministic evidence for the optional Feishu current-Pi channel.
The configuration-driven lifecycle, native inbound image path, and outbound post Markdown path were verified on 2026-08-19 against Pi `0.84.2` and the official Feishu Node SDK package metadata for `@larksuiteoapi/node-sdk` `1.73.0`.

## Official SDK selection evidence

```console
$ npm view @larksuiteoapi/node-sdk version dist-tags --json
{
  "version": "1.73.0",
  "dist-tags": {
    "latest": "1.73.0",
    "alpha": "1.51.0-alpha.0",
    "beta": "1.57.0-beta.1"
  }
}
```

The package README's long-connection section documents `WSClient.start({ eventDispatcher })` with `EventDispatcher.register({ "im.message.receive_v1": ... })`.
The package declarations expose `WSClient` lifecycle callbacks and `close()`, `Client.im.v1.chat.get`, `Client.im.v1.message.create`, `Client.im.v1.messageResource.get({ params: { type }, path: { message_id, file_key } })`, and message `uuid` fields used for idempotency.
The resource response exposes a one-consumption `getReadableStream()` and response headers.
The official message-create contract accepts `msg_type: "post"` with a JSON-stringified locale/content matrix, and the post content contract accepts an `md` element carrying Markdown text.
Pi's installed declarations expose `sendUserMessage(content: string | (TextContent | ImageContent)[], options)` and native image content as `{ type: "image", data: string, mimeType: string }`.
The focused regression exercises that exact extension boundary as well as the fixed outbound `zh_cn` matrix with one row and one `{ "tag": "md", "text": ... }` element.
The package is pinned in `package.json` and `package-lock.json`.
No project dependency was installed into this worktree while recording this evidence.

## Safety boundary

No app was created or configured.
No app credential was obtained or written.
No authentication flow, real long connection, webhook, event consumption, real Feishu send, installation into a live Firstmate home, or live Pi-session mutation was performed.
All configuration credentials in the executable fixture are synthetic.

The transport test replaces only the SDK boundary with one local module.
It does not assert that a real app has the required scopes, developer-console subscription mode, tenant policy, or production network route.
A post-PR real-image check remains an explicit captain action using the already configured bound channel.

## Focused behavioral result

```console
$ bash tests/fm-feishu-channel.test.sh
ok - native Pi steering, lock-contention recovery, state safety, and all-origin Assistant mirroring
ok - local Pi bridge converges after delayed ownership and exposes safe local status, rebind, and disable controls
ok - secure config parsing and automatic Feishu lifecycle converge silently and fail closed
ok - official-SDK long-connection transport is inert, identity-fenced, deduplicated, and durably serialized post Markdown outbound
```

The first section uses disposable private homes and persisted fake Pi session headers.
It proves that the extension registers no TUI input, message-end, turn-start, or tool-call hook.
It proves that native TUI and ordinary Firstmate operational input do not enter Feishu state.
It proves that accepted Feishu text is durably recorded and offered to Pi through native steer delivery with an exact session and generation fence.
It also proves image-only and ordered text-plus-multiple-image delivery as native Pi content, exact byte preservation, private `0600` envelopes/cache files, resource/message replay convergence, stale-claim substitution refusal, MIME and object-size mismatch refusal, retry after partial download, attachment-count and malformed-key refusal, unsupported-type metadata, symlink containment, bounded terminal cleanup, and media-originated parity with Pi's existing tool path.
A separate live process holds the pairing lock beyond the normal acquisition wait while the public Pi lifecycle pump runs; the test proves one retry notice, pending-message preservation, automatic recovery after release, and one native-queue offer across repeated timer ticks.
It separately proves stale dead-owner reclamation, refusal of a fresh dead owner during its grace period, malformed and unsafe lock refusal, non-retryable state-corruption shutdown, changed-generation refusal, marker reconciliation after exact resume, wrong-session suspension, event-ID and message-ID deduplication, allowlist and P2P refusal, finalized Assistant mirroring for Feishu, native TUI, and operational turns, pre-binding-history exclusion, exact `Captain, shipshape.`, `Captain，shipshape.`, and `船长，处理中。` exclusion with surrounding-whitespace normalization, close non-exact delivery, and local neutralization of a historical whitespace-carrying pending routine record, non-Assistant exclusion, restart deduplication, deterministic and idempotent post Markdown rendering, supported Markdown preservation, unsupported-source literal preservation, URL-, link-, code-span-, code-block-, table-, quote-, and list-preserving chunking, oversize-construct refusal, rendered-output resource refusal, pre-persistence credential refusal, and private-state symlink and hardlink rejection.

The bridge lifecycle section reproduces the startup-order failure through the real Pi extension factories and their public lifecycle handlers.
The initiating trigger is Pi's initial `session_start`; the masking condition is that Firstmate lock ownership becomes valid only after the bridge's first callback has returned; the visible symptom is an absent loaded marker with no pairing, binding, or transport.
The real turn-end/session-start extension then acquires fixture ownership through its operational startup hook and emits the shared process-local settled event.
The test proves that the bridge converges the exact current persisted session at that boundary, publishes its marker, and starts one transport; repeated settled and `agent_start` boundaries remain idempotent.
It also proves that `/reload` cannot repair a missing owner because reload does not rerun the ownership-acquiring startup digest, that wrong-owner reload and `agent_start` remain inert, that a later owned `agent_start` can retry safely, and that disabled configuration creates no channel state or transport.
It exercises `/fm-feishu-rebind` through the registered Pi command and proves stale-session replacement, exact current-session binding, already-current idempotence, wrong-owner and invalid-configuration refusal, concise body-free output, no credential or private-identifier leakage, and that slash-like Feishu message text remains ordinary native-queue content rather than command execution.
The shared state-owner checks separately prove that manual rebind refuses pending and offered inbound work, pending outbound work, and terminal delivery uncertainty.

The configuration lifecycle section drives `bin/fm-feishu-transport.sh config-check`, `bin/fm-feishu-lifecycle.mjs reconcile`, the real pairing and binding state owner, verified process-owner stop, and the mocked official SDK boundary.
It proves absent-config inertness without private state creation, strict key parsing, missing-field refusal, duplicate and unsupported-field refusal, exact `0600` enforcement, symlink and wrong-owner refusal, credential and P2P probing before binding mutation, silent first activation, unchanged-session idempotence, exact-session replacement with generation increment, prior-owner shutdown, stopped-transport recovery without generation churn, config-persisted disable, process-argument redaction, state-record redaction, and credential-rejection failure before binding state exists.

The SDK section uses a local module implementing the documented `Client`, `WSClient`, `EventDispatcher`, and `messageResource.get` calls.
It proves unconfigured inertness, app-fingerprint refusal before SDK import, P2P verification before long-connection start, callback validation before durable ingress, authorized image download only after admission, no download for an unauthorized image event, bounded stream consumption and actual-image verification, reconnect callback handling, replay deduplication, canonical bound-chat SDK `message.create`, the exact post locale/content matrix, supported and literal-preserved Markdown in the `md` element, routine-response zero-send with ordinary sibling delivery, stable UUID retry, unsupported-response refusal without card or plain-text fallback, Retry-After preservation, structured multi-chunk delivery, outbound single-flight serialization, body-free health, and owner-verified graceful stop.
A sentinel executable on `PATH` proves the transport does not invoke the former command transport.

## Pi compatibility results

```console
$ bash tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.2
```

The check compiles the bridge, native-queue channel, watcher integration, turn-end integration, and shared state declarations with strict TypeScript settings against the installed Pi declarations.

```console
$ bash tests/fm-pi-watch-extension.test.sh
...
ok - Pi extension reports external healthy watcher output
...
ok - OpenCode healthy arm output does not suppress the turn-end guard
```

```console
$ bash tests/fm-turnend-guard.test.sh
...
ok - .pi primary extension: no-tool and multi-tool runs each inject exactly one guard follow-up
ok - .pi primary extension: delivery failure resets the logical-run latch
...
```

The watcher and turn-end tests exercise direct native `sendUserMessage(..., { deliverAs: "followUp" })` delivery without loading or writing Feishu state, independently of Feishu's steer mode.
