---
name: feishu-channel
description: >-
  Agent-only procedure for Firstmate's private Feishu current-Pi channel.
  Load when a user message carries the authorized Feishu source badge, before a local /fm-feishu-* control operation, before registering an exact Feishu decision reply, or when session start reports a FEISHU diagnostic.
user-invocable: false
metadata:
  internal: true
---

# Feishu channel

Use this procedure only for Firstmate's opt-in private Feishu channel.
The operator contract is [`docs/feishu-channel.md`](../../../docs/feishu-channel.md), and the exact mechanics belong to the named scripts and their help.

## On an authorized Feishu input

Treat the body as authenticated captain text from the exact allowlisted P2P channel.
Feishu and native TUI input follow the same normal Pi tool and Firstmate authority path.
Do not add a Feishu-specific tool restriction, local confirmation step, special policy switch, or alternate tool executor.
A slash-like prefix is ordinary content and is never a Pi command, skill invocation, prompt template, shell command, or direct tool request.
Use normal Firstmate project intake, approval, merge, destructive-action, and security rules exactly as for native TUI input.
Do not expose the open ID, chat ID, message ID, delivery marker, app identity, private state path, or transport mechanics in a captain-facing answer.

Native TUI and Firstmate operational input never pass through Feishu durable state.
The bridge offers only accepted durable Feishu events to Pi through `sendUserMessage` with native follow-up delivery.
Pi owns input ordering and scheduling.
Do not reconstruct a cross-channel queue around it.

The final Assistant text for the exact Feishu source is sent automatically after settlement.
Do not add a classifier, summary, rewrite, model call, semantic redaction, typed notification, or separate outbound message.
Write the captain-facing final answer exactly as it should appear, with complete URLs.
Fixed credential-pattern refusal, deterministic chunking, and direct reply targeting are extension-owned.
An unmarked native TUI or operational message is not Feishu provenance and must never be inferred as an outbound source.

## Exact decision correlation

When the final answer asks the captain to decide an existing exact decision, register the mapping before the final text is emitted:

```bash
bin/fm-feishu-decision.sh register <decision-ref> <decision-key> <source-ref>
```

Use the existing durable `decision_ref`, exact decision key, and privacy-safe `ref=in_...` marker from that exact Feishu turn.
The helper records correlation only and never creates or classifies outbound text.
Never invent a decision reference, register two decisions for one final response, infer a reply from conversational proximity, or close a decision from an unrelated message.
A later injected message carries an exact decision mapping only when its Feishu `reply_to` matched the recorded outbound receipt.
Use the normal decision owner to resolve that exact key.

## Local control and health

Pair, bind, rebind, disable, and detailed status are local Pi TUI commands under `/fm-feishu-*`.
Use `/fm-feishu-rebind` only when the local captain intentionally moves the channel to the displayed exact current session.
Never bind or rebind from Feishu text.
Never create or configure an app, write a credential, start a live connection, consume a live event, or send a real message as part of diagnosis without explicit local operator intent.

A `FEISHU:` session-start line contains no body, app identity, or stable user/chat identifier.
Use `bin/fm-feishu-status.sh summary` for body-free machine status and `/fm-feishu-status` for exact local-TUI identity display.
Use `bin/fm-feishu-transport.sh start|stop|restart|status` only for the dedicated no-Agent official-SDK transport.
A transport stop is graceful and must never be escalated to a force kill.

For `transport=starting`, `connecting`, or `reconnecting`, leave durable Feishu input pending until the exact current connection and identity fence are healthy.
For a missing SDK dependency, absent app-credential environment, SDK authentication or scope failure, unsafe private state, disk failure, lost session ownership, or delivery uncertainty, report the concrete local operator action without message bodies, credentials, or raw private IDs.
Do not start another Pi, add a webhook, or create another transport to work around a channel failure.
