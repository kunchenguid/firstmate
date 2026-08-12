# Feishu channel

The Feishu channel is an opt-in private captain channel for a Firstmate session running in Pi.
It keeps one Feishu P2P conversation and the local TUI on the same live Pi process and the same in-memory `AgentSession`.
It never starts another Pi process, RPC process, SDK AgentSession, model, tool runner, or session-file writer.
The network side uses the official `@larksuiteoapi/node-sdk` long-connection client and does not expose a webhook.

## Supported scope

The MVP allows one exact Feishu user in one exact P2P chat.
Inbound supports plain text only.
Outbound mirrors every finalized non-empty Assistant text persisted after the binding boundary, regardless of whether Feishu, native TUI, watcher, turn-end, or another normal Pi source caused the turn.
The exact fixed response `Captain, shipshape.` stays local and is never pushed.
Mirroring adds no classification, summarization, rewriting, or second model call.
Group chats, cards, attachments, webhooks, multi-home routing, remote slash commands, and attachment downloads are unsupported.
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
Grant only the app-identity scopes required by the developer console for P2P message reception, `im.v1.chat.get`, and bot message creation.

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
No `/fm-feishu-pair`, `/fm-feishu-bind`, `/fm-feishu-rebind`, credential export, or manual transport start is required.
Healthy startup is silent and idempotent.
Pi's initial `session_start` callback can run before the operational session-start turn has acquired the Firstmate lock.
After that turn settles, the tracked Pi extensions retry activation for the same session through their process-local lifecycle boundary, so normal startup needs neither a second Pi process nor `/reload`.
The binding records the complete session UUID, exact session file, session cwd, persisted header identity, canonical Firstmate home, generation, and the last persisted session entry at first bind or replacement as the outbound history boundary.
Pre-binding Assistant history is never backfilled.
An ephemeral `--no-session` session cannot bind.
The bridge activates only in trusted TUI mode while the current process owns the Firstmate session lock and every stored identity matches.

Starting, resuming, forking, or replacing the eligible persisted Pi session converges the binding to that exact current session.
`/reload` reconstructs the extensions but deliberately does not rerun the ownership-acquiring operational session-start digest.
It therefore converges only when this Pi already owns the lock; reload while ownership is missing or belongs to another session remains safely inert, and a later owned agent start retries without duplicating the transport.
Replacement validates credentials and P2P identity first, then waits for the verified prior transport to stop, rejects any event already submitted to the prior Pi native queue, increments the binding generation, and starts one new transport.
The prior transport is fully stopped before binding publication, so an old-generation send cannot race the replacement.
Pending events retarget only when none already belongs to the prior Pi native queue.
Changing the configured app, user, or chat supersedes unsent events from the prior authorization identity rather than redirecting them.

Use `/fm-feishu-disable` to stop the verified transport gracefully, retire the pairing and binding, and atomically set `FM_FEISHU_ENABLED=false`.
Use `/fm-feishu-status` for the detailed local identity and queue view.
No Feishu message can enable, disable, pair, bind, rebind, or move the channel.

## Direct SDK long connection

Automatic startup invokes `bin/fm-feishu-transport.sh` for configuration validation, credential probing, graceful replacement, and one dedicated no-Agent transport.
`bin/fm-feishu-transport.sh start` remains an explicit local recovery control and reads the same protected file.
`bin/fm-feishu-transport.sh stop` signals only the exact owner process after home, module, nonce, PID incarnation, and process-title verification.
`bin/fm-feishu-transport.sh restart` performs the same controlled stop followed by start.
`bin/fm-feishu-transport.sh status` prints a body-free and identifier-free health summary.

The transport creates one SDK `WSClient` and one `EventDispatcher` for `im.message.receive_v1`.
It uses one SDK `Client` for P2P chat verification and canonical outbound `message.create` calls to the bound chat.
It verifies the configured app ID against the derived paired fingerprint and verifies `chat_mode=p2p` before changing a configured binding, before starting the long connection, and after reconnect.
A current owner and binding generation must still match before any outbound claim or inbound publication.
A second transport owner for the same Firstmate home is refused.
The official SDK owns app-token acquisition, refresh, long-connection authentication, event decoding, and REST requests.

The SDK event callback performs only bounded validation and private durable publication.
It does not wait for Pi, execute a model, execute a tool, or send an outbound response.
An accepted callback validates the authenticated app identity when present, sender type and open ID, exact chat and P2P mode, text message shape, body size, active binding, and capacity before durable handoff.
Unauthorized, malformed, unsupported, duplicate, overlength, or resource-pressure events never reach Pi.
A durability failure throws from the callback so the SDK can report failure to Feishu rather than acknowledging memory-only receipt.

The SDK owns reconnect and protocol replay behavior.
Firstmate does not poll message history or invent a second replay protocol.
Replayed `event_id` or `message_id` values converge through the durable indexes.
A replay that reaches the adapter after another accepted event receives a later local sequence because local durable commit order remains the audit order.
The channel does not claim source-to-disk exactly-once delivery or recovery of an event the platform never redelivers.

## Pi native queue boundary

Native TUI input is never intercepted, transformed, durably copied, acknowledged, or reinjected by the Feishu extension.
Local images remain entirely Pi-owned.
Watcher and turn-end operational prompts call Pi's supported `sendUserMessage(..., { deliverAs: "followUp" })` path directly.
They do not enter Feishu state.

An accepted Feishu event remains pending until the exact bound live Pi session and current transport identity are available.
Transient contention from a live Feishu state-lock owner leaves accepted events pending, and the existing bridge pump retries with bounded backoff after contention clears without restarting Pi or the transport or adding another scheduler.
The bridge records one owner-fenced submission attempt and calls `sendUserMessage` with Pi's native `steer` mode.
While Pi is busy, each accepted Feishu message is delivered after the current Assistant turn finishes its tool calls and before the next model call.
While Pi is idle, the same call starts a normal turn immediately.
It submits every pending event once to Pi and does not wait for one event to finish before offering the next one to Pi's own queue.
Pi owns turn sequencing, steering order, and pending-message scheduling.
Firstmate does not maintain a cross-channel scheduler.

A privacy-safe leading marker carries only the derived delivery reference and binding generation.
It carries no app ID, open ID, chat ID, credential, or path.
A session restart scans exact persisted Feishu markers to settle prior native-queue submissions.
An owner change resets an unpersisted prior submission to pending instead of redirecting it to another session.
A wrong session, stale generation, lost lock, or closed live owner leaves durable input suspended.

The marker exists only to reconcile accepted inbound submission after restart and to render the authorized Feishu source badge.
It does not control outbound eligibility.
Native TUI and operational user messages remain unmodified and need no synthetic provenance.

## Outbound delivery

After Pi has persisted a finalized Assistant message, the extension scans session entries strictly after the binding's history boundary.
Each eligible entry is identified by its persisted session-entry ID, session order, timestamp, session ID, binding generation, and exact text hash.
That identity makes capture and restart replay converge without depending on source markers, originating Feishu messages, transient ordinals, or text hash alone.
Every finalized non-empty Assistant text is eligible regardless of source, including replies caused by Feishu, native TUI, watcher, and turn-end input.
The exact fixed response `Captain, shipshape.` and empty Assistant text are skipped.
Thinking blocks, partial streams, tool calls and results, user/system/custom messages, and TUI-only alerts are not mirrored.

Each eligible message is sent with SDK `message.create` to the exact bound P2P chat.
General Assistant delivery never requires or replies to an originating Feishu message.
A fixed credential-pattern match refuses the whole message before its text is persisted in channel state and raises one local alert.

Long output is split only at deterministic UTF-8, paragraph, line, or word boundaries.
A complete URL is never split or truncated.
Every chunk carries a stable SDK `uuid` derived from the durable event and chunk index.
The SDK response message ID and chat ID become the durable receipt.
A definite SDK error remains retryable with its bounded delay.
An ambiguous request-without-response retries the same UUID only inside the one-hour idempotency window and then becomes delivery uncertainty.

## Private state and diagnostics

Pairing and binding records live under `data/feishu/`.
Durable accepted events, ledgers, pending indexes, Assistant-registration intents, outbox records, attempts, receipts, quarantine records, alerts, owner identity, and health live under `state/feishu/`.
Directories are mode `0700` and files are mode `0600`.
Raw identity is never used as a filename.
Symlinks, hardlinks, partial files, malformed schemas, cross-record mismatches, and cross-home paths are rejected.
A live lock owner is distinguishable from stale dead-owner reclamation, a fresh dead owner still inside the stale-owner grace period, and malformed or unsafe lock state; only live-owner contention is retried by the active ingress pump.

Healthy normal startup prints no Feishu status or success line.
Public status shows only enabled state, binding status, generation, body-free transport phase, and aggregate counts.
They do not show credentials, app IDs, user/chat IDs, message bodies, session paths, or raw diagnostics.
A malformed, unsafe, incomplete, or credential-rejected configuration stops activation safely, preserves unrelated Pi and Firstmate operation, and reports one body-free local remediation.
A missing SDK dependency reports its existing optional-feature prerequisite without activating the channel.

## Verification boundary

The focused regression uses a local mock of the official SDK constructor, long-connection callbacks, reconnect callbacks, P2P chat API, and message APIs.
It performs no real authentication, network connection, app configuration, event consumption, Pi-session mutation, or Feishu send.
It proves absent and disabled inertness, strict data parsing, ownership and permission refusal, symlink refusal, silent idempotent activation, session replacement, owner replacement, transport recovery, durable disable, credential rejection and redaction, native TUI non-interception, direct operational follow-up delivery, native Feishu steer submission, exact session and generation fencing, all-origin finalized Assistant mirroring, pre-binding-history exclusion, exact routine-response exclusion, restart deduplication, non-Assistant exclusion, canonical bound-chat `message.create`, replay deduplication, app/chat refusal, stable outbound UUIDs, ambiguous retry handling, owner-verified stop, and absence of the former command transport path.

That mock does not prove a real app's scopes, developer-console long-connection selection, tenant policy, or production network reachability.
A future live integration check requires explicit operator authorization and disposable app credentials.
The current dated maintainer evidence is in [Feishu channel verification](verification/feishu-channel.md).
