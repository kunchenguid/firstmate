# Hermes Telegram bridge

Firstmate includes an opt-in, repo-owned Hermes plugin that turns explicit private Telegram `/firstmate` text or voice commands into normal Firstmate requests.
Hermes remains the Telegram transport and authorization owner; the bridge never modifies Hermes core, launches Pi, or bypasses Firstmate's ordinary project, worker, validation, merge, and supervision lifecycle.

## Security boundary

The plugin intercepts only `/firstmate <request>` (including a bot username suffix) and spoken `firstmate <request>` or `first mate <request>` after Hermes voice transcription.
All other messages continue through Hermes unchanged.
Before intake, the plugin requires both Hermes' current Telegram authorization decision and an exact configured numeric owner ID.
It then sends a versioned envelope over a local subprocess pipe, authenticated with a private mode-`0600` HMAC key.
The envelope binds platform, owner, chat, thread, message, timestamp, command kind, normalized text, and a deterministic opaque request ID.
Firstmate independently verifies the HMAC, owner, shape, two-minute timestamp window, and `/firstmate` boundary before atomically publishing mode-`0600` inbox and reply-context records in mode-`0700` directories.
Raw Telegram IDs remain only in the private signed context and never enter worker instructions, task metadata, notifications, or logs.

Replay of the same Telegram message resolves to the same request ID and cannot publish or run a second request.
A registered byte-bound watcher check emits only that opaque ID; Firstmate processes the request through `.agents/skills/telegram-respond/SKILL.md`.
Intake refuses requests while Firstmate supervision is offline, so Hermes can tell the sender to retry instead of silently losing work.

Replies use `hermes send` with the signed context's numeric chat and optional thread target.
Each delivery is journaled before sending; identical completed delivery retries are no-ops, while interrupted or failed delivery is marked unresolved and is never retried automatically.
Replies are split below Telegram limits, capped at ten messages, bounded to three task follow-ups over seven days, and rejected if they contain common credential forms.
Machine hostnames are replaced with `[local host]`.

Authentication protects the local spool and correlation, but does not make voice transcription authoritative for destructive, irreversible, security-sensitive, merge, or credential actions.
Those voice requests require confirmation in the primary chat.
All existing Firstmate approval boundaries continue to apply to text requests.

## Install

Prerequisites:

- Hermes is installed and its Telegram gateway is already configured.
- The captain's Telegram account is authorized through Hermes pairing or its configured allowlist.
- Firstmate supervision is active.
- The numeric Telegram user ID is known; do not use a username.

Install is explicit and inert until `--enable` is supplied:

```bash
bin/fm-telegram-bridge.sh install \
  --enable \
  --owner-id 123456789 \
  --hermes-home "$HOME/.hermes"
```

Use `--hermes-bin /absolute/path/to/hermes` when `hermes` is not on `PATH`, and `--fm-home /absolute/path` for another Firstmate home.
The installer copies only `integrations/hermes/firstmate-telegram/` into that Hermes home's plugin directory, creates private local config and HMAC material, enables the plugin through Hermes' plugin command, and registers the Firstmate watcher check.
It never reads or changes the Telegram bot token.
Restart the Hermes gateway once after install or uninstall so Hermes reloads its plugin set.
Do not restart it merely for `start`, `stop`, status, or owner-preserving reinstall.

Verify without exposing secrets:

```bash
bin/fm-telegram-bridge.sh status
```

Then send a private Telegram message such as:

```text
/firstmate summarize what is currently in flight
```

A healthy bridge replies `Firstmate accepted your request.` and later returns the correlated result in the same chat and topic.
Unprefixed text remains ordinary Hermes input.
Unauthorized senders receive no Firstmate acknowledgement and cannot create spool records.

## Lifecycle commands

```bash
bin/fm-telegram-bridge.sh stop
bin/fm-telegram-bridge.sh start
bin/fm-telegram-bridge.sh configure --owner-id 123456789
bin/fm-telegram-bridge.sh uninstall
```

`stop` disables intake and removes its watcher check without deleting private records.
`start` is idempotent and restores both.
`configure` refuses an owner change while correlated contexts remain.
`uninstall` refuses while pending or unresolved records remain; after inspection, `--purge` explicitly authorizes removal.
Repeated install, start, stop, status, reply, and uninstall calls are safe: completed operations are reused or reported, and ambiguous transport outcomes stop for inspection instead of duplicating messages.

## Operations and recovery

Private state is under `state/telegram-{inbox,context,offers,deliveries,final,outbox}/`; local configuration is under `config/telegram-bridge/`.
Never copy these files into a task, report, log, or chat.
A signed context expires after seven days.
If status reports a missing plugin, invalid private authentication, or stopped intake, run `stop`, inspect ownership and modes without printing contents, then run `start`.
If a reply reports an unresolved delivery, inspect only its private journal metadata and Telegram delivery externally; do not delete the journal or retry until duplicate risk is resolved.
Rotate the Telegram bot token only through Hermes' existing setup, then restart Hermes; the bridge stores no bot token and needs no reconfiguration.
To change captain accounts, finish or explicitly purge existing correlated requests before `configure --owner-id`.

Tests use a fake Hermes transport and never send real Telegram messages.
The real lifecycle test uses only `bin/fm-herdr-lab.sh` with a generated `fm-lab-*` session and a trapped teardown; it never addresses Herdr's `default` session.
