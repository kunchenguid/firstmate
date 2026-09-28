# Feishu channel verification

This record contains current deterministic evidence for the optional Feishu current-Pi channel.
The configuration-driven lifecycle, bounded SDK reconnect and process-replacement paths, native inbound image path, and outbound post Markdown path were verified on 2026-08-25 against Pi `0.84.3` and the official Feishu Node SDK package metadata for `@larksuiteoapi/node-sdk` `1.73.0`.
The executable inbound body-only rendering, source-metadata, numbered-link, and partial-element fallback cases were rerun on 2026-09-03 with Node `22.22.2`, and the tracked extension typecheck passed against Pi `0.84.4`.

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
The installed `WSClient` implementation routes socket close into its automatic reconnect loop, distinguishes pre-ready success through `onReady` from post-ready success through `onReconnected`, accepts server-provided unbounded retry counts, and exposes `onError` for terminal initial or exhausted retry outcomes.
The resource response exposes a one-consumption `getReadableStream()` and response headers.
The official message-create contract accepts `msg_type: "post"` with a JSON-stringified locale/content matrix, and the post content contract accepts an `md` element carrying Markdown text.
Pi's installed declarations expose `sendMessage` custom content and private `details`, `registerMessageRenderer`, the pre-provider `context` transform, and native image content as `{ type: "image", data: string, mimeType: string }`.
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

The processed-message file cleanup lifecycle was verified on 2026-09-28 with Node `22.22.2` and Pi `0.87.1`.

```console
$ bash tests/fm-feishu-processed-cleanup.test.sh
evidence - message JSON files before=7 after=5; legacy processed files before=7 after=5
ok - five-second Feishu cleanup unlinks only receipt-proven message files and preserves all unfinished work
```

The clock-controlled public-lifecycle fixture proves the pass does not run before five seconds, then reduces the inbound and outbound message-file count from seven to five by unlinking one delivered inbound JSON file and one fully receipted outbound JSON file while retaining five pending, offered, delivery-uncertain, partially posted, or unsent files.
A second clock-controlled cycle starts from the same seven-file count with earlier-version processed empty-body fixtures and again reaches five by unlinking those two legacy message files.
It also proves empty and repeated passes are harmless, runtime shutdown disposes the timer, restart readback does not rehydrate deleted inbound content, retained ledger and receipt identities still deduplicate inbound replay and outbound registration, and superseded inbound, sending, and retryable records remain intact.

```console
$ bash tests/fm-feishu-channel.test.sh
ok - native Pi steering, lock-contention recovery, state safety, and all-origin Assistant mirroring
ok - local Pi bridge hard-binds session ownership and recovers terminal transport processes safely
ok - secure config parsing and automatic Feishu lifecycle converge silently and fail closed
ok - official-SDK long-connection transport is inert, identity-fenced, deduplicated, and durably serialized post Markdown outbound
```

The first section uses disposable private homes and persisted fake Pi session headers.
It proves that the extension registers no TUI input, message-end, turn-start, or tool-call hook.
It proves that native TUI and ordinary Firstmate operational input do not enter Feishu state.
It proves that accepted Feishu text is durably recorded and offered to Pi through metadata-bearing native steer delivery with an exact session and generation fence.
It proves text-only, image-only, ordered text-plus-images, slash-like, and spoof-shaped bodies render as the exact captain body without transport title, source badge, slash instruction, private identifier, or bridge framing.
It proves the pre-upgrade framed prefix is stripped for display only after its marker matches the durable accepted event, while native content without an authenticated marker stays unaltered.
It proves only metadata plus exact-content matches against durable accepted events receive model-context source fencing, while native TUI text, spoofed provenance text, unknown metadata, and metadata paired with changed content remain untrusted.
It proves classification, body-only rendering input, and model-context fencing survive routine terminal media cleanup through the immutable exact-content digest recorded at delivery; changed bodies and substituted image bytes stay untrusted after cleanup, repeated verification does not reacquire the Feishu inbound-state lock while a fresh unverified lookup still does, and session-marker reconciliation refuses foreign custom message types carrying Feishu-shaped metadata.
It also proves image-only and ordered text-plus-multiple-image delivery as native Pi content, exact byte preservation, private `0600` envelopes/cache files, resource/message replay convergence, stale-claim substitution refusal, MIME and object-size mismatch refusal, retry after partial download, bounded durable retry backoff that honors `Retry-After` for retriable media downloads with the retry ceiling preserved, strict ingress FIFO that holds later text behind a not-ready media head until ready or terminal refusal, any-single-locale post acceptance preferring `zh_cn`, partial malformed and unsupported element fallback with valid surrounding content preserved, whole-post malformed and unsupported quarantine without transport failure, attachment-count and malformed-key refusal, unsupported-type metadata, symlink containment, bounded terminal cleanup, and media-originated parity with Pi's existing tool path.
A separate live process holds a real two-link pairing lock beyond the normal acquisition wait while the public Pi lifecycle pump runs; the test proves that neither entry is removed while the owner is live, one retry notice, pending-message preservation, automatic recovery after the owner releases only the canonical entry, and one native-queue offer across repeated timer ticks.
Exact inbound-state fixtures prove stale dead-owner recovery removes only the revalidated canonical entry and reacquires serialization while the unknown alias remains, fresh dead-owner and malformed-record refusal preserve both links, canonical inode replacement refuses without deleting either object, and symlink and directory locks remain terminally unsafe.
The bridge fixture separately proves the hardlink-specific body-free stop outcome, zero native sends, durable pending preservation, lifecycle-boundary recovery, and exactly one native offer after recovery.
The suite also preserves ordinary single-link stale dead-owner reclamation, fresh dead-owner and malformed refusal, non-retryable state-corruption shutdown, changed-generation refusal, marker reconciliation after exact resume, wrong-session suspension, event-ID and message-ID deduplication, allowlist and P2P refusal, finalized Assistant mirroring for Feishu, native TUI, and operational turns, pre-binding-history exclusion, exact `Captain, shipshape.`, `Captain，shipshape.`, and `船长，处理中。` exclusion with surrounding-whitespace normalization, close non-exact delivery, and local neutralization of a historical whitespace-carrying pending routine record, non-Assistant exclusion, restart deduplication, deterministic and idempotent post Markdown rendering, supported Markdown preservation, unsupported-source literal preservation, URL-, link-, code-span-, code-block-, table-, quote-, and list-preserving chunking, oversize-construct refusal, rendered-output resource refusal, pre-persistence credential refusal, and private durable-record symlink and hardlink rejection.

The bridge lifecycle section reproduces the startup-order failure through the real Pi extension factories and their public lifecycle handlers.
The initiating trigger is Pi's initial `session_start`; the masking condition is that Firstmate lock ownership becomes valid only after the bridge's first callback has returned; the visible symptom is an absent loaded marker with no pairing, binding, or transport.
The real turn-end/session-start extension then acquires fixture ownership through its operational startup hook and emits the shared process-local settled event.
The test proves that the bridge directly hard-binds the exact current persisted session at that boundary, publishes its marker, and starts one transport; repeated settled and `agent_start` boundaries remain idempotent while live ownership remains current.
It then reproduces the reported shape with an active exact-session binding and healthy transport but no live Pi owner, proves public status reports those gates separately, and proves the next trusted owned `agent_start` restores sole ownership without a slash command, generation churn, or transport restart.
It also proves that `/reload` cannot repair a missing owner because reload does not rerun the ownership-acquiring startup digest, that wrong-owner reload and `agent_start` remain inert, that a later owned `agent_start` can retry safely, and that disabled configuration creates no channel state or transport.
It exercises session replacement through the registered Pi lifecycle and proves automatic exact current-session hard takeover from an old live owner with offered inbound, pending outbound, and terminal delivery uncertainty present.
The public lifecycle and shared state-owner checks prove stable inbound delivery references, stable outbound event and chunk UUID identities, pending registration-intent transfer, receipt-first uncertainty reconciliation, immediate prior-session inbound and mirroring fences, and already-current idempotence.
The compatibility `/fm-feishu-rebind` command checks prove wrong-owner and invalid-configuration refusal, non-local refusal, concise body-free output, no credential or private-identifier leakage, and that slash-like Feishu message text remains ordinary native-queue content rather than command execution.

The process-recovery fixture starts from the production failure shape: the initiating trigger is a terminal long-connection process outcome, valid configuration and a successful P2P probe are the masking conditions that exclude setup failure, and the visible symptom is degraded transport with one durable outbound response still pending.
It first proves that transient SDK reconnect keeps the original owner incarnation and starts no replacement.
It then removes only the terminated owner while preserving the exact binding, live Pi owner, and pending outbound identity, injects three retryable lifecycle failures, and proves four serialized attempts with exponential delay capped at the configured test ceiling despite pump ticks running faster than each attempt.
The successful replacement preserves the binding generation and configuration identity, publishes a different owner incarnation, becomes dispatchable only after identity-verified health, and delivers the pending chunk exactly once with its original UUID.
A further case terminates the replacement itself before first healthy state and leaves its exact owner record behind, proving the lingering stale incarnation is deferred as retryable, retired by the next strict recovery, and replaced exactly once without duplicate transports.
Separate cases prove session-lock loss cancels the retry loop, a terminal authentication health class starts no recovery, and the local diagnostic contains no private identity or credential.

The configuration lifecycle section drives `bin/fm-feishu-transport.sh config-check`, `bin/fm-feishu-lifecycle.mjs reconcile|recover`, the real pairing and binding state owner, verified process-owner stop, and the mocked official SDK boundary.
It proves absent-config inertness without private state creation, strict key parsing, missing-field refusal, duplicate and unsupported-field refusal, exact `0600` enforcement, symlink and wrong-owner refusal, credential and P2P probing before binding mutation, silent first activation, unchanged-session idempotence, exact-session replacement with generation increment, prior-owner shutdown, stopped-transport recovery without generation churn, config-persisted disable, process-argument redaction, state-record redaction, and credential-rejection failure before binding state exists.
The strict recovery action additionally proves unchanged configuration-file identity and live Pi ownership, exact same-generation restart, new owner fencing, changed-configuration refusal, terminal HTTP authentication refusal, lock-loss refusal, credential redaction, and zero transport start after any terminal refusal.

The SDK section uses a local module implementing the documented `Client`, `WSClient`, `EventDispatcher`, and `messageResource.get` calls.
It proves unconfigured inertness, app-fingerprint refusal before SDK import, P2P verification before long-connection start, callback validation before durable ingress, authorized image download only after admission, no download for an unauthorized image event, bounded stream consumption and actual-image verification, healthy and pre-ready transient recovery under one unchanged owner, counted reconnect callbacks, bounded stalled recovery classified for outer retry, terminal HTTP authentication and ownership-generation failures classified to stop, terminal reconnect identity refusal, sanitized connection diagnostics, no client close or outbound attempt while reconnecting, one exact pending send after verified recovery, duplicate-timer cleanup, clean deliberate stop, replay deduplication, numbered rich-text link normalization through the real transport and native Pi queue boundary, canonical bound-chat SDK `message.create`, the exact post locale/content matrix, supported and literal-preserved Markdown in the `md` element, routine-response zero-send with ordinary sibling delivery, stable UUID retry, unsupported-response refusal without card or plain-text fallback, Retry-After preservation, structured multi-chunk delivery, outbound single-flight serialization, body-free health, and owner-verified graceful stop.
A sentinel executable on `PATH` proves the transport does not invoke the former command transport.

## Pi compatibility results

```console
$ bash tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.87.1
```

The check compiles the bridge, native-queue channel, watcher integration, turn-end integration, and shared state declarations with strict TypeScript settings against the installed Pi declarations.

```console
$ bash tests/fm-pi-watch-extension.test.sh
...
ok - Pi extension reports external healthy watcher output
...
```

```console
$ bash tests/fm-turnend-guard.test.sh
...
ok - .pi primary extension: no-tool and multi-tool runs each inject exactly one guard follow-up
ok - .pi primary extension: delivery failure resets the logical-run latch
...
```

The watcher and turn-end tests exercise direct native `sendUserMessage(..., { deliverAs: "followUp" })` delivery without loading or writing Feishu state, independently of Feishu's steer mode.
