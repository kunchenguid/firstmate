# Feishu channel

The Feishu channel is an opt-in private captain channel for a Firstmate session running in Pi.
It keeps one Feishu P2P conversation and the local TUI on the same live Pi process and the same in-memory `AgentSession`.
It never starts another Pi process, RPC process, SDK AgentSession, model, tool runner, or session-file writer.
The network side uses the official `@larksuiteoapi/node-sdk` long-connection client and does not expose a webhook.

## Supported scope

The MVP allows one exact Feishu user in one exact P2P chat.
Inbound supports plain text, standalone images, and ordered rich-text messages containing text, links, and images.
Inbound links retain their visible label and exact destination in a deterministic `label (destination)` representation, or the destination alone when the label is empty or identical.
An unsupported or malformed element inside an otherwise representable rich-text message becomes a bounded non-sensitive unavailable marker in its original position, without copying hidden element fields.
An entirely unsupported or malformed rich-text message is quarantined with only deterministic type and encoded-size metadata and produces a private local refusal outcome.
Images are delivered to the exact bound Pi session as Pi-native image content, never as prompt placeholders, Markdown links, data URLs, signed URLs, or private file paths.
Outbound mirrors every finalized non-empty Assistant text persisted after the binding boundary as Feishu post rich text containing one Markdown element, regardless of whether Feishu, native TUI, watcher, turn-end, or another normal Pi source caused the turn.
The exact fixed responses `Captain, shipshape.`, `Captain，shipshape.`, and `船长，处理中。` stay local and are never pushed.
Mirroring adds no model classification, summarization, semantic rewrite, or second model call beyond the deterministic carrier-safety renderer described in the outbound contract.
Group chats, inbound cards, card interactions, non-image attachments, audio/video/files/stickers, webhooks, multi-home routing, and remote slash commands are unsupported.
An unsupported non-rich-text media input is quarantined with only its deterministic type and encoded-size metadata and produces a private local refusal outcome instead of being dropped or flattened.
Slash-like Feishu text is ordinary user content and cannot invoke a Pi slash command or prompt template.

Feishu and native TUI input use the same normal Pi tool path.
The channel adds no Feishu-specific tool restriction, local confirmation command, or alternate tool policy.
The ordinary Firstmate and Pi authorization rules continue to apply equally to both input channels.

## SDK and app prerequisites

The tracked dependency is the official `@larksuiteoapi/node-sdk` version recorded in `package.json` and `package-lock.json`.
Install project dependencies only in the operator's intended Firstmate checkout before enabling the optional channel.
The channel remains inert when `config/feishu.env` is absent or explicitly disabled.

Create a self-built Feishu app through the Feishu developer console outside Firstmate.
Enable bot capability and subscribe to `im.message.receive_v1` using the developer console's long-connection mode.
Do not configure a webhook URL, public endpoint, reverse proxy, or tunnel.
Grant only the app-identity scopes required by the developer console for P2P message reception, `im.v1.chat.get`, message-resource download, and bot message creation.

## Local configuration

Install the safe disabled template, then edit the local file with an editor that does not put values in command arguments:

```console
$ install -m 600 docs/examples/feishu.env config/feishu.env
$ ${EDITOR:-vi} config/feishu.env
```

Set `FM_FEISHU_ENABLED=true` and add the exact App ID, App Secret, captain open ID, and P2P chat ID required by the [configuration schema](configuration.md#feishu-current-pi-channel).
Do not quote values or add shell syntax.
Do not export the credentials.
The file is local and gitignored.
It must remain owned by the current user with mode `0600`.

The App Secret may exist only in this protected file and the dedicated transport process environment.
It never enters Pi, command arguments, tracked files, pairing or binding records, logs, status, diagnostics, or process titles.
The dedicated transport parses the file as data and never sources or executes it.

Run the body-free local check when setup needs diagnosis:

```console
$ bin/fm-feishu-transport.sh config-check
```

The check prints only `absent`, `disabled`, or `enabled` state in JSON.
An invalid file returns one actionable error that contains no configured value.

## Automatic pairing and binding

Normal startup of a trusted local persisted Pi session validates the file, derives the App ID fingerprint, authenticates through the official SDK, verifies the configured chat is P2P, stores the exact pairing, binds the exact current session, and starts or recovers one transport.
No manual command, credential export, or manual transport start is required for healthy startup.
Healthy startup is silent and idempotent.
Pi's initial `session_start` callback can run before the operational session-start turn has acquired the Firstmate lock.
After that turn settles, the tracked Pi extensions retry activation for the same session through their process-local lifecycle boundary, so normal startup needs neither a second Pi process nor `/reload`.
The binding records the complete session UUID, exact session file, session cwd, persisted header identity, canonical Firstmate home, generation, and the last persisted session entry at first bind or replacement as the outbound history boundary.
Pre-binding Assistant history is never backfilled.
An ephemeral `--no-session` session cannot bind.
The bridge activates only in trusted TUI mode while the current process owns the Firstmate session lock and every stored identity matches.

Starting, resuming, forking, replacing, or continuing the eligible persisted Pi session directly hard-binds the channel to that exact current session whenever its live Pi ownership is absent or stale.
`/reload` reconstructs the extensions but deliberately does not rerun the ownership-acquiring operational session-start digest.
It therefore converges only when this Pi already owns the lock; reload while ownership is missing or belongs to another session remains safely inert, and a later owned agent start retries without duplicating the transport.
Replacement validates credentials and P2P identity first, then waits for the verified prior transport to stop, atomically transfers pending and previously offered inbound plus reconcilable outbound work, increments the binding generation, and starts one new transport.
The prior transport is fully stopped before binding publication, so an old-generation send cannot race the replacement.
The same-session recovery path fences any prior live Pi owner and restores current live-session ownership without changing the binding generation or restarting an already healthy matching transport.
Changing the configured app, user, or chat supersedes unsent events from the prior authorization identity rather than redirecting them.

Use `/fm-feishu-disable` to stop the verified transport gracefully, retire the pairing and binding, and atomically set `FM_FEISHU_ENABLED=false`.
Use `/fm-feishu-status` for the detailed local identity and queue view.
The trusted startup and owned-turn lifecycle performs this hard bind directly; it does not depend on a slash command.
The compatibility-named `/fm-feishu-rebind` may still invoke the same action from the trusted local Pi TUI.
After configuration and P2P identity probing and any required graceful prior-transport shutdown, one state-owner transaction advances the binding generation when the session changes, retargets pending inbound and outbound work, clears prior live-session ownership, and publishes the exact current session as the sole owner.
Pending and previously offered inbound keep their stable delivery reference and original order, while the new generation prevents every prior Pi from offering them or mirroring later Assistant entries.
Pending Assistant-registration intents and outbox records keep their stable event and chunk UUID identities across takeover; receipts are reconciled first, and terminal delivery uncertainty remains recorded without replay or blocking the ownership move.
The command has no alternate rebind mode, force flag, or second confirmation, and reports success only after the exact current binding and transport are healthy.
An already-current healthy binding is an idempotent success without generation or transport churn.
On refusal, follow the body-free local status and configuration checks named by the command; never delete private records or restart only the transport to bypass a trust, configuration, or graceful-stop failure.
No Feishu message can enable, disable, pair, bind, rebind, or move the channel.

## Direct SDK long connection

Automatic startup invokes `bin/fm-feishu-transport.sh` for configuration validation, credential probing, graceful replacement, and one dedicated no-Agent transport.
`bin/fm-feishu-transport.sh start` remains an explicit local recovery control and reads the same protected file.
`bin/fm-feishu-transport.sh stop` signals only the exact owner process after home, module, nonce, PID incarnation, and process-title verification.
`bin/fm-feishu-transport.sh restart` performs the same controlled stop followed by start.
`bin/fm-feishu-transport.sh status` prints a body-free and identifier-free health summary.
While an enabled exact binding still has its trusted live Pi owner, an ownerless stopped transport is eligible for automatic process recovery; use `/fm-feishu-disable`, not transport-only stop, to keep the channel disabled.

The transport creates one SDK `WSClient` and one `EventDispatcher` for `im.message.receive_v1`.
It uses one SDK `Client` for P2P chat verification, inbound `messageResource.get` downloads, and canonical outbound post `message.create` calls to the bound chat.
It verifies the configured app ID against the derived paired fingerprint and verifies `chat_mode=p2p` before changing a configured binding, before starting the long connection, and after reconnect.
A current owner and binding generation must still match before any outbound claim or inbound publication.
A second transport owner for the same Firstmate home is refused.
The official SDK owns app-token acquisition, refresh, long-connection authentication, event decoding, and REST requests.

A transient SDK connection error keeps the same transport owner and `WSClient` alive, changes health to non-dispatchable `reconnecting`, and leaves automatic reconnect to the SDK.
Each `onReconnecting` callback increments the durable reconnect count.
Only `onReady` or `onReconnected` followed by successful revalidation of the exact binding generation, owner process incarnation, and P2P chat identity restores healthy state and resumes pending media and outbound draining.
One recovery episode has one five-minute deadline by default, configurable as a positive millisecond value through the transport owner's `FM_FEISHU_RECOVERY_TIMEOUT_MS` environment; a repeated connection error cannot extend that deadline.
Expiry becomes the distinct terminal `sdk-recovery-timeout` outcome, closes the client, and releases the owner instead of leaving a falsely live process.
Structured authentication or authorization failures, configuration or ownership fence loss, reconnect identity failure, and durable event-handoff failure remain terminal rather than entering recovery.
Connection diagnostics retain only bounded error kinds: HTTP status, non-negative numeric SDK code, or fixed structural categories for common connection failures.

If that dedicated process terminates or releases ownership after a retryable terminal outcome, the existing Pi bridge enters the credential-blind lifecycle recovery boundary without replacing the SDK reconnect state machine.
The first replacement attempt waits one second, later retryable failures use exponential delay capped at 60 seconds, and one process-local single-flight continues while the exact current Pi session remains active.
Every attempt revalidates the unchanged protected configuration identity, Firstmate session lock, exact binding and generation, current live Pi owner, absence of a conflicting transport owner, app authentication, and P2P chat before starting one replacement.
Backoff resets only after the replacement health record and owner record agree on the new PID incarnation, nonce, process-start token, configuration identity, exact binding generation, and a fresh successful P2P identity verification.
Transient SDK reconnect under a live owner never starts a replacement.
Disabled or absent configuration remains inert, while malformed or changed configuration, authentication or authorization refusal, lock or session loss, binding mismatch, ambiguous ownership, unsafe or corrupt durable state, and event-handoff failure stop automatic recovery with a local diagnostic.
Pending outbound records remain behind the unhealthy transport fence and retain their event and chunk UUIDs; the replacement drains them only after full health, so recovery neither re-registers nor marks them delivered early.

The SDK event callback performs only bounded validation and private durable publication.
It does not wait for Pi, execute a model, execute a tool, or send an outbound response.
An accepted callback validates the authenticated app identity when present, sender type and open ID, exact chat and P2P mode, message shape, body size, active binding, and capacity before durable handoff.
Only after the authorization fence passes can the transport claim an image resource.
It calls the official SDK resource API with the immutable message and resource identities, streams at most 10 MiB per image and 20 MiB per logical message, permits at most eight images, and requires the response MIME and actual PNG/JPEG/GIF/WebP signature to agree.
The private cache uses generated names, atomic owner-only writes, a SHA-256 byte binding, and no user-controlled path component.
Rich-text bodies are read from one well-formed locale, preferring `zh_cn`, and preserve paragraph order, meaningful line breaks, link labels, and link destinations.
The [supported-scope contract](#supported-scope) owns partial-element fallback and whole-message quarantine behavior.
Download pending, downloading, ready, retryable failure, terminal refusal, Pi offer, and persisted delivery remain distinct durable states.
A retryable download waits on a bounded durable schedule that honors a server `Retry-After` when present and uses bounded exponential delays otherwise, and later accepted inputs hold behind the oldest not-ready media input in local commit order until it becomes ready or is terminally refused.
Unauthorized, wholly malformed, wholly unsupported, duplicate, overlength, or resource-pressure events never reach Pi.
A durability failure throws from the callback so the SDK can report failure to Feishu rather than acknowledging memory-only receipt.

The SDK owns reconnect and protocol replay behavior within the transport's bounded recovery and identity-verification fence.
Firstmate does not poll message history or invent a second replay protocol.
Replayed `event_id` or `message_id` values converge through the durable indexes.
A replay that reaches the adapter after another accepted event receives a later local sequence because local durable commit order remains the audit order.
The channel does not claim source-to-disk exactly-once delivery or recovery of an event the platform never redelivers.

## Pi native queue boundary

Native TUI input is never intercepted, transformed, durably copied, acknowledged, or reinjected by the Feishu extension.
Local TUI images remain entirely Pi-owned.
Watcher and turn-end operational prompts call Pi's supported `sendUserMessage(..., { deliverAs: "followUp" })` path directly.
They do not enter Feishu state.

An accepted Feishu event remains pending until the exact bound live Pi session and current transport identity are available.
Transient contention from a live Feishu state-lock owner leaves accepted events pending, and the existing bridge pump retries with bounded backoff after contention clears without restarting Pi or the transport or adding another scheduler.
The bridge rereads cached bytes through their private generated path, verifies the durable length and SHA-256 binding, records one owner-fenced submission attempt and the immutable exact-content digest of the delivered body, and calls Pi's `sendMessage` with a metadata-bearing custom message, `triggerTurn: true`, and native `steer` delivery.
Text-only input retains a string body.
Image-only and ordered text-plus-image input use Pi's official `TextContent | ImageContent` array with `{ type: "image", data, mimeType }`; the ordered parts remain one logical Pi input and image-only input contains the actual image without invented prose.
While Pi is busy, each accepted Feishu message is delivered after the current Assistant turn finishes its tool calls and before the next model call.
While Pi is idle, the same call starts a normal turn immediately.
It submits every pending event once to Pi and does not wait for one event to finish before offering the next one to Pi's own queue.
Pi owns turn sequencing, steering order, and pending-message scheduling.
Firstmate does not maintain a cross-channel scheduler.

The custom message's private `details` carries only a schema, derived delivery reference, and binding generation.
It carries no app ID, open ID, chat ID, credential, or path, and Pi does not send `details` to the model.
A session restart scans exact persisted Feishu custom-message metadata, and still recognizes the pre-upgrade leading-marker form, to settle prior native-queue submissions.
An owner change resets an unpersisted prior submission to pending instead of redirecting it to another session.
A wrong session, stale generation, lost lock, or closed live owner leaves durable input suspended.

The registered custom renderer verifies that metadata and the exact content against the durable accepted event, then renders only the captain's text and images with no title, source badge, slash instruction, delivery reference, or bridge framing.
Immediately before provider conversion, the context hook performs the same verification and adds the source fence and slash-handling instruction to model text without changing persisted or rendered content.
Verification matches the exact content against the immutable digest recorded in the private inbound ledger when the message is offered to Pi, so routine terminal media cleanup never changes trust, rendering, or fencing, and repeated provider/UI verification reuses that evidence without rereading media bytes or reacquiring Feishu state locks.
Ordinary 250ms ingress polling reads only pending indexes and unfinished publication intents; full inbox/ledger/map integrity recovery runs at startup or an explicit recovery boundary.
The polling ownership check runs asynchronously and then rechecks the current runtime, binding, and live owner before dispatch; it does not cache ownership across ticks.
Pi session-array traversal for Assistant capture remains a separate operation from Feishu directory enumeration and JSON parsing.
A lifecycle-owned five-second pass deletes delivered inbound payloads, ledgers, and delivery maps, and deletes outbound payloads and ledgers only after a complete successful-send receipt proves every chunk posted.
It includes earlier-version empty-body files and already-unlinked payloads whose eligible ledger/map residue remains.
Pending, offered, sending, retryable, partially posted, superseded-unsent, and delivery-uncertain records remain intact without a count cap.
Existing inbound event-ID evidence remains, together with processed delivery-reference membership containing only its schema and binding generation; this rejects same-message replay with a different event ID and filters retired context, but never authorizes message content.
Successful outbound receipts retain the text hash for registration conflict detection and no-repeat delivery; neither these receipts nor processed inbound identities are enumerated by periodic cleanup or ingress polling.
A single transient intent per direction makes interrupted unlink operations recoverable under the existing state lock, without a second historical ledger or archive.
Unknown or unverifiable reserved Feishu custom messages are omitted from provider context, while unsigned native input never gains source authority from marker-shaped text.
It never deletes remote Feishu history.
A message persisted by an earlier build keeps its already-fenced model context, while display strips only its exact legacy prefix after the marker matches the durable accepted event.
The metadata does not control outbound eligibility.
Native TUI and operational user messages remain unmodified, cannot acquire Feishu trust from body text, and need no synthetic provenance.

## Outbound delivery

After Pi has persisted a finalized Assistant message, the extension scans session entries strictly after the binding's history boundary.
Each eligible entry is identified by its persisted session-entry ID, session order, timestamp, session ID, binding generation, and exact text hash.
That identity makes capture and restart replay converge without depending on source markers, originating Feishu messages, transient ordinals, or text hash alone.
Every finalized non-empty Assistant text is eligible regardless of source, including replies caused by Feishu, native TUI, watcher, and turn-end input.
The exact fixed responses `Captain, shipshape.`, `Captain，shipshape.`, and `船长，处理中。`, plus empty Assistant text, are skipped.
Only surrounding whitespace is normalized before that exact match, so a longer response that merely contains one of these phrases as a substring is still delivered, and a historical outbound record persisted by an earlier build whose exact match missed surrounding whitespace is neutralized locally at the next reconciliation without any remote send.
Thinking blocks, partial streams, tool calls and results, user/system/custom messages, and TUI-only alerts are not mirrored.

Each eligible message is sent with SDK `message.create` to the exact bound P2P chat with `msg_type: "post"`.
Its deterministic `zh_cn` locale object has an empty title and exactly one content row containing one `{ "tag": "md", "text": <chunk> }` element.
There is no ordinary-reply interactive-card path, carrier negotiation, or fallback between carriers.
General Assistant delivery never requires or replies to an originating Feishu message.
A fixed credential-pattern match refuses the whole message before its text is persisted in channel state and raises one local alert.

The renderer preserves headings, GFM tables, block quotes, ordered, unordered, and task lists, fenced code blocks and their language labels, inline code, links, emphasis, and strikethrough as Markdown.
It keeps fenced Mermaid source visible as code rather than claiming that Feishu rendered a diagram.
Math, Setext headings, indented code blocks, raw HTML blocks, `<details>` blocks, email autolinks, and footnote references and definitions are represented as inline or fenced literal source.
Markdown images, reference images, Feishu mention markup, and broad mention spellings remain literal rather than uploading an image, inventing a user, or producing a mention side effect.
The transformation is deterministic, bounded to a fixed multiple of the source size, and idempotent.

Long rendered output is split only at deterministic UTF-8, paragraph, line, word, and Markdown-construct boundaries.
Complete URLs, Markdown links, inline code spans, autolinks, fenced code blocks, GFM tables, contiguous block quotes, and list structures are never split or truncated.
If one indivisible construct exceeds the per-chunk limit, the entire response stays local and raises one local alert rather than sending malformed Markdown.
The durable source text and hash remain exact, while the ordered chunks and one rendered-output hash carry the exact post Markdown identity without storing a second complete rendered-text field.
Concatenating all Markdown element contents reproduces that exact rendered output.
Every chunk carries a stable SDK `uuid` derived from the durable event and chunk index.
The SDK response message ID and chat ID become the durable receipt.
A definite unsupported response or SDK error remains retryable with its bounded delay and never falls back to a card or plain text.
An ambiguous request-without-response retries the same post payload and UUID only inside the one-hour idempotency window and then becomes delivery uncertainty.

## Private state and diagnostics

Pairing and binding records live under `data/feishu/`.
Durable accepted events, ledgers, pending indexes, media envelopes and cache bytes, Assistant-registration intents, outbox records, attempts, receipts, quarantine records, alerts, owner identity, and health live under `state/feishu/`.
Directories are mode `0700` and files are mode `0600`.
Raw identity is never used as a filename.
Symlinks and hardlinks in durable record files, partial files, malformed schemas, cross-record mismatches, byte substitution, traversal attempts, and cross-home paths are rejected.
Delivered or terminally refused media is removed after a bounded 24-hour retention window; pending and offered work is retained for recovery.
Existing state locks are opened without following symlinks, read as bounded PID records from that descriptor, and kept bound to the same inode evidence.
A hardlinked regular lock owned by a live PID remains ordinary contention, while a dead owner older than 30 seconds permits removal of only the revalidated canonical lock entry before exclusive reacquisition; no unknown alias is searched for or removed.
Malformed hardlinked locks, fresh dead owners, or changed path/inode/link evidence stop with a body-free hardlink-specific outcome, while symlink and non-regular lock objects remain terminally unsafe.
Only live-owner contention is retried by the active ingress pump.

Healthy normal startup prints no Feishu status or success line.
Public status shows only enabled state, binding status, generation, body-free transport phase, the separate body-free `live_session_owned` ownership bit, and aggregate counts.
`transport_healthy=true` with `live_session_owned=false` means the no-Agent SDK connection is healthy but no current Pi bridge owns native delivery; the next trusted owned Pi boundary performs a same-generation hard bind without a transport-only restart.
They do not show credentials, app IDs, user/chat IDs, message bodies, session paths, or raw diagnostics.
A malformed, unsafe, incomplete, or credential-rejected configuration stops activation safely, preserves unrelated Pi and Firstmate operation, and reports one body-free local remediation.
A missing SDK dependency reports its existing optional-feature prerequisite without activating the channel.

## Verification boundary

The focused regression uses a local mock of the official SDK constructor, long-connection callbacks, reconnect callbacks, P2P chat API, and message APIs.
It performs no real authentication, network connection, app configuration, event consumption, Pi-session mutation, or Feishu send.
It proves absent and disabled inertness, strict data parsing, ownership and permission refusal, symlink refusal, silent idempotent activation, session replacement, owner replacement, transport recovery, durable disable, credential rejection and redaction, native TUI non-interception, direct operational follow-up delivery, native Feishu steer submission, native image content, ordered text plus multiple images, image-only input, media byte binding and private modes, download replay and retry, size/count/MIME/signature refusal, path containment and expiry, exact session and generation fencing, all-origin finalized Assistant mirroring, pre-binding-history exclusion, exact routine-response exclusion and historical-record neutralization, restart deduplication, non-Assistant exclusion, public-lifecycle hard takeover of live and stale owners, pending inbound handoff, pending and uncertain outbound identity reconciliation, old-session fencing, already-current idempotence, Feishu-origin refusal, deterministic post rendering, supported-structure preservation, unsupported-source literal preservation, table, quote, and list-aware chunking and refusal, exact post locale and `md` element encoding, canonical bound-chat `message.create`, replay deduplication, app/chat refusal, stable outbound UUIDs, definite failure without carrier fallback, ambiguous retry handling, single-flight serialization, owner-verified stop, and absence of the former command transport path.

That mock does not prove a real app's scopes, developer-console long-connection selection, tenant policy, or production network reachability.
A post-PR live integration check requires the captain to send one image and one ordered text-plus-image message through the already configured P2P channel, then verify that the exact current Pi can inspect both images.
It must not rebind the channel, replace credentials, or start a second transport.
The current dated maintainer evidence is in [Feishu channel verification](verification/feishu-channel.md).
