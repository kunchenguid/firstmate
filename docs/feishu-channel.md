# Feishu channel

The Feishu channel is an opt-in private captain channel for a Firstmate session running in Pi.
It keeps the local TUI and one Feishu P2P conversation on the same live Pi process and the same in-memory `AgentSession`.
It never starts a second Pi, an RPC process, an SDK session, or another writer for the Pi session file.

The maintainer architecture and ownership boundaries live in [Architecture](architecture.md#feishu-current-pi-channel).
The private state implementation and exact schemas live in [`bin/fm-feishu-state.mjs`](../bin/fm-feishu-state.mjs).

## Supported MVP

The MVP allows one exact Feishu user in one exact P2P chat.
Inbound plain `text` messages are supported.
Outbound messages preserve the final Assistant text as plain text, including complete URLs.
Group chats, cards, attachments, webhooks, multi-home routing, arbitrary remote commands, and attachment downloads are not supported.
A remote string beginning with `/` is ordinary user content and cannot invoke a Pi command, skill, prompt template, shell, or tool directly.
A Feishu request to merge, discard, perform a destructive or irreversible action, change credentials, or make a security-sensitive choice still needs an exact one-time confirmation through `/fm-feishu-confirm <code>` in the local TUI.

## Prerequisites

Use a supported Pi version and a current `lark-cli` installation.
Configure the Feishu app and bot through the normal `lark-cli` setup outside Firstmate before pairing.
The minimum bot scopes are the P2P receive scope reported by `lark-cli event schema im.message.receive_v1 --json`, message history read access for overlap reconciliation, and `im:message:send_as_bot` for replies.
Enable the `im.message.receive_v1` event for the bot in the Feishu developer console.
Do not run `lark-cli auth login` for bot identity.
Use the installed `lark-shared`, `lark-contact`, `lark-event`, and `lark-im` skill contracts when resolving identities or diagnosing scopes.
Firstmate never stores an app secret, token, credential, or Authorization value in its channel state.

## Pair and bind locally

All channel control commands are local Pi TUI extension commands.
They are intentionally unavailable as remotely injected commands.

1. Find the stable bot open ID, captain open ID, and P2P chat ID through the current Feishu operator workflow.
2. In the local trusted Pi TUI, run `/fm-feishu-pair <bot-open-id> <captain-open-id> <p2p-chat-id> [app-profile] [sha256:<app-id-hash>]`.
3. Review the local result, then run `/fm-feishu-bind` to bind the exact current persisted Pi session.
4. Run `/fm-feishu-status` to inspect the canonical home, full Pi session UUID, session file, cwd, binding generation, exact user and chat, queue counts, and transport health.

Pairing performs no login, network call, subscription, or message send.
The optional app-ID fingerprint is the lowercase SHA-256 digest of the exact Feishu `app_id`; when present, the transport verifies it together with the selected app profile and bot open ID before opening the event consumer.
Binding refuses an ephemeral `--no-session` session because crash recovery cannot prove its identity.
The bind command reloads the same session after publishing the binding so the extension can activate the exact fence.

Use `/fm-feishu-rebind` only from the local TUI when intentionally moving the channel to the exact current Pi session.
Rebinding increments the generation and fences every callback from the previous generation.
A Pi restart or resume of the same session UUID, file, and cwd continues automatically.
`/new`, `/fork`, `/clone`, import, or resuming another session suspends injection until that explicit local rebind.

Use `/fm-feishu-disable` to disable pairing and request a graceful transport stop.
Disable never force-kills the transport.

## Transport operation

`bin/fm-feishu-transport.sh start` starts the dedicated no-Agent transport after an active pairing and binding exist.
`bin/fm-feishu-transport.sh stop` sends `SIGTERM` only to the identity-checked owner and refuses to force-kill a process that does not stop.
`bin/fm-feishu-transport.sh restart` performs that controlled stop followed by start.
`bin/fm-feishu-transport.sh status` prints a body-free and identifier-free JSON health summary.

The transport executes fixed `lark-cli` argv arrays directly and never interpolates message text into a shell command.
It first verifies `lark-cli whoami --as bot` against the paired app profile, bot open ID, and optional app-ID fingerprint, then waits for the documented `[event] ready event_key=im.message.receive_v1` stderr marker.
It preserves body-free drop and backpressure diagnostics privately, reconnects with a bound, and runs overlapping bot-history reconciliation before marking live dispatch healthy.
The pre-reconciliation live buffer is capped at 1,000 events and 8 MiB, each consumer line is capped at 256 KiB, durable pending ingress is capped at 10,000 items, and publishing stops when the state filesystem has less than 64 MiB free.
`FM_FEISHU_MAX_BUFFERED_EVENTS`, `FM_FEISHU_MAX_LIVE_BUFFER_BYTES`, `FM_FEISHU_MAX_CONSUMER_LINE_BYTES`, `FM_FEISHU_MAX_PENDING_INBOUND`, and `FM_FEISHU_MIN_FREE_BYTES` may lower or raise those local operator thresholds.
Buffer overflow publishes the already buffered events durably, records a body-free diagnostic, and forces overlap reconciliation before resuming; a queue or free-space refusal records one local alert.
It does not use `--quiet`, download resources, run an Agent, inspect the Pi session, or choose a different session.

The Pi extension starts the transport best-effort when an exact active binding resumes.
The transport may remain running while Pi is closed so already received messages stay durable until that exact session returns.

## Delivery behavior

Every authorized inbound message is committed privately before it is eligible for Pi injection.
The exact Feishu `message_id` is the deduplication key.
The local durable sequence, not Feishu wall-clock time, determines acceptance order.
A single-flight coordinator covers local TUI text and images, Feishu text, watcher input, and turn-end input.
Local Pi images remain private durable TUI ingress and are capped at 20 MiB of encoded image data by default (`FM_FEISHU_MAX_LOCAL_IMAGE_BYTES`); Feishu attachments remain unsupported.
Busy local Enter retains steer behavior, busy local Alt+Enter retains follow-up behavior, and busy Feishu input uses follow-up behavior.
The next durable item is not submitted until Pi observes acceptance of the prior user message.

The Pi session contains a privacy-safe delivery marker but no Feishu open ID or chat ID.
A TUI-only Markdown transform shows the source as `Feishu - authorized P2P` or `Local TUI` without changing model context.
The coordinator waits for the post-persistence `turn_start` boundary and ACKs only the exact user entry already present in Pi's SessionManager.
On restart, the extension scans the exact session for markers and repairs an ACK written after Pi persistence but before a crash instead of injecting a duplicate turn.

After `agent_settled`, the final Assistant text is registered directly in the durable outbox.
Partial output, tool output, system messages, user messages, retry intermediates, empty output, exact `Captain, shipshape.`, and purely internal operational turns are not sent.
There is no importance classifier, second model call, summary, rewrite, or semantic redaction layer.
If a fixed credential pattern matches, the entire outbound message stays private and one local actionable alert is recorded.
Long text is split only at deterministic UTF-8, paragraph, line, word, and platform-size boundaries, and a complete URL is never split.
A final response larger than 1 MiB stays local by default; `FM_FEISHU_MAX_OUTBOUND_BYTES` controls that operator limit.

A Feishu-originated final response replies to its exact triggering message.
A local-TUI-originated final response sends to the active bound P2P chat.
Every chunk has a stable identity and a stable Feishu idempotency key.
The transport records a pre-send attempt and a post-send receipt.
An ambiguous result retries the same key only within Feishu's one-hour idempotency window, then becomes locally actionable delivery uncertainty instead of using a new key.

## Exact decision replies

A decision reply is correlated only through the Feishu parent `message_id` mapped from a durable outbound receipt.
An unrelated message cannot resolve a decision even if only one decision appears open.
Before a final response asks for a decision over this channel, register the existing exact mapping from inside the current Pi turn with `bin/fm-feishu-decision.sh register <decision-ref> <decision-key>`.
This helper records correlation only and does not create text, classify importance, or send a message.
If more than one unbound decision registration exists for the same final response, Firstmate records a local alert and guesses none.

## State and privacy

Durable pairing and generation history live under private `data/feishu/`.
Inbox, ledgers, ACKs, outbox, attempts, receipts, correlation maps, quarantine, live ownership, diagnostics, alerts, and health live under private `state/feishu/`.
Directories are owner-only and files are non-executable owner-only regular files.
Raw IDs are hashed in path components, and message bodies never appear in startup or health output.
Credentials remain in the `lark-cli` credential store.
Removing pairing leaves the rest of Firstmate inert and creates no Feishu network process.

## Health and recovery

A paired home prints one body-free `FEISHU:` line in the session-start bootstrap section.
`transport=healthy` means the consumer reached its ready marker and completed overlap reconciliation for the current connection.
`transport=reconciling` or `transport=degraded` means Feishu-originated durable items wait rather than crossing an unverified history boundary.
A missing `lark-cli` appears only after pairing as an optional-feature bootstrap diagnostic.

A malformed private file, unsafe symlink or hardlink, disk failure, lost session lock, wrong session identity, stale binding generation, or competing live Pi suspends injection instead of guessing.
Transport stderr diagnostics and health never contain message bodies or credentials.
Use `/fm-feishu-status`, `bin/fm-feishu-transport.sh status`, and the single `FEISHU:` startup line for diagnosis.

## Verification

Run `bash tests/fm-feishu-channel.test.sh` for deterministic state, current-Pi, transport, direct-output, safety, and correlation fixtures.
Run `bash tests/fm-pi-primary-types.test.sh` for the strict extension type check against the installed Pi package.
Run `bash tests/fm-pi-watch-extension.test.sh`, `bash tests/fm-turnend-guard.test.sh`, and `bash tests/fm-session-start.test.sh` for affected integration regressions.
Run `bin/fm-lint.sh`, `bin/fm-doc-audience-check.sh`, and `bin/fm-test-run.sh --all` before delivery.
The current dated maintainer evidence is in [Feishu channel verification](verification/feishu-channel.md).
