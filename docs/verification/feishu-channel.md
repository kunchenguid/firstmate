# Feishu channel verification

This record contains current deterministic evidence for the optional Feishu current-Pi channel.
The operator contract is [`docs/feishu-channel.md`](../feishu-channel.md), and the maintainer ownership boundary is [`docs/architecture.md`](../architecture.md#feishu-current-pi-channel).

## 2026-08-11 compatibility baseline

Installed versions:

```text
$ pi --version
0.84.1

$ lark-cli --version
lark-cli version 1.0.85
```

The current Pi extension API, TUI, SDK, sessions, session-format, and settings documentation were read from the installed `@earendil-works/pi-coding-agent` package before implementation.
The current installed `lark-event`, `lark-im`, `lark-contact`, and `lark-shared` skill contracts and the event, send, reply, and chat-history references were read before implementation.
No bot was created or configured, no authentication flow was run, no live event was consumed, no real Feishu message was sent, and no live Pi session was modified.

A complete `bin/fm-test-run.sh --all` attempt ran all 133 scripts: 130 passed and 3 failed outside the Feishu implementation.
The unchanged cmux fixture expected `send-failed` but received `unknown`, the unchanged real-Herdr presentation fixture observed its existing concurrent cleanup-ordering failure, and the Calm browser assertion could not run because Chrome/Chromium is absent on this host.
The Feishu test and affected Pi, watcher, turn-end, session-start, bootstrap, lint, documentation, and type regressions passed independently.

## Deterministic channel regression

Command:

```text
$ bash tests/fm-feishu-channel.test.sh
ok - current-Pi Feishu ingress, persistence ordering, fences, egress recovery, and private-state validation
ok - local Pi bridge registers only the explicit pairing and binding control surface
ok - no-Agent transport fails closed and preserves bounded single-flight delivery
```

This test uses private disposable homes, persisted fake Pi session headers, a fake current-session extension boundary, and one fake `lark-cli` executable.
It covers one-at-a-time durable ingress, simultaneous TUI and Feishu ordering, busy steer and follow-up semantics, exact ACK and interrupted-publication recovery, wrong-session suspension, explicit generation rebind, lock loss, deduplication, authorization, quarantine, durable outbound-registration recovery, fixed skip rules, whole-message secret refusal, URL-preserving chunking, exact source reply, stable ambiguous retry, exact decision correlation, terminal-proof validation, and shell-inert argv delivery.
It asserts that a remote slash-like string remains ordinary message text, that every Feishu-originated non-allowlisted tool effect needs an exact one-time local confirmation, and that no sentinel shell effect occurs.
The fake boundary creates no Pi process, AgentSession, RPC process, SDK session, or Pi-session writer.

## Pi extension type compatibility

Command:

```text
$ bash tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.1
```

The check compiles the bridge, coordinator, watcher integration, turn-end integration, and shared state declarations with strict TypeScript settings against the installed Pi declarations.

## Existing integration regressions

Commands and current results:

```text
$ bash tests/fm-pi-watch-extension.test.sh
ok - Pi extension and OpenCode watcher regressions passed

$ bash tests/fm-turnend-guard.test.sh
ok - Pi and supported turn-end guard regressions passed

$ bash tests/fm-sessionstart-nudge.test.sh
ok - session-start nudge and large Pi delivery regressions passed
```

The exact individual assertions remain in the named test output rather than being duplicated into this record.

## Refresh procedure

Run the focused channel test, strict Pi type check, affected watcher and turn-end tests, session-start tests, documentation audience check, lint, and the complete repository test runner.
If `FM_PI_LIVE_E2E=1` is available, run `bash tests/fm-pi-primary-live-e2e.test.sh` only in its existing isolated disposable environment.
Never use live verification to create a bot, change bot scopes, log in, consume the captain's real events, send a real message, install this branch into a live Firstmate home, or restart the captain's current Pi session.
