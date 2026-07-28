# Telegram bridge verification

Active empirical evidence for the guarantees the private Telegram bridge claims.
Behavior, setup, and tunables are owned by [`configuration.md`](../configuration.md#telegram-bridge-env); design rationale by [`architecture.md`](../architecture.md#optional-telegram-bridge).
Re-run everything here after changing `bin/fm-tg-*`, `bin/fm-private-artifact-lib.sh`, `bin/fm-message-split-lib.sh`, `bin/fm-env-file-lib.sh`, or the watcher check sweep.

Recorded 2026-07-28 on macOS (Darwin 25.5.0, arm64), GNU bash 5.3.9, ShellCheck 0.11.0.

## Regression suite

```sh
bin/fm-test-run.sh --family telegram-bridge
```

41 checks pass, covering: inert-by-default, token secrecy and file modes, pairing success/expiry/replay/wrong-code/wrong-identity/re-pair/revoke, exactly-once acceptance, duplicate delivery, both crash windows, offset confirmation, the recovery sweep, refusal of unpaired/group/channel/bot senders, unsupported and oversized payloads, injection inertness, rate limiting, project routing, the two-step publish gate, reply escaping/splitting/retry/final cleanup, bootstrap arm and disarm, supervision eligibility, cross-channel coexistence, sweep rotation, and home isolation.

The Bot API is served by the fake local server in `tests/telegram-helpers.sh`: a stateful implementation of `getUpdates` and `sendMessage` reached through the client's real `curl --config` transport.
No socket is bound and no real token exists anywhere in the suite.

## Inert by default

An unconfigured home writes nothing, prints nothing, and contacts nothing.

```sh
$ D=$(mktemp -d); mkdir -p "$D/home/state" "$D/home/config"
$ FM_HOME="$D/home" bin/fm-tg-poll.sh; echo "exit=$?"
exit=0
$ find "$D/home/state" -mindepth 1 | wc -l
       0
```

Bootstrap is equally silent: `tests/fm-telegram-bridge.test.sh` asserts no `FMTG:` line, no `state/telegram-watch.check.sh`, and no `config/telegram.env` for a home with no token, and asserts that steady-state off stays silent after an opt-out has already cleaned up.

## The bot token never enters an argument vector

The Bot API carries the token in the URL path, so the risk is real rather than theoretical: a plain `curl` call would expose it to any local process through `ps`.

`test_token_never_reaches_argv_or_state` asserts both halves, so the negative cannot pass vacuously:

- positive control - the fake server's `token-seen.log` **does** contain the token, proving the request was actually made and carried it;
- the negative - the shim's recorded `argv.log` does **not** contain it, and neither does any file under `state/` or `config/`, and neither does `bin/fm-tg-pair.sh status`.

## Exactly-once delivery across crashes

Each case rewinds the confirmed offset the way a real crash would, then re-queues the same update in the fake server, which honors Telegram's real "confirming an offset deletes everything below it" contract.

| Crash point | Expected | Test |
| --- | --- | --- |
| after the offset was confirmed | redelivery impossible; a second poll is silent | `test_paired_text_is_accepted_exactly_once` |
| after the wake, before the offset write | redelivery dropped, entry unchanged | `test_duplicate_delivery_never_duplicates_work` |
| after the inbox claim, before the seen marker | redelivered once, no duplicate entry | `test_crash_before_seen_claim_still_delivers_once` |
| after the agent drained the entry | never resurrected | `test_drained_message_is_never_resurrected` |
| after the seen marker, before the wake | re-announced by the bounded sweep | `test_pending_message_is_re_announced_after_a_lost_wake` |

## Silence to unpaired chats

`test_wrong_code_is_silent_and_bounded`, `test_expired_code_does_not_pair`, and `test_non_private_and_bot_senders_get_no_access` assert the delivered-message count stays at the single pairing confirmation across wrong codes, expired codes, group/supergroup/channel messages, bot senders, and unpaired private users.
`test_reply_without_a_peer_sends_nothing` asserts `sendMessage` never runs at all before a pairing exists.

## Compatibility axes

Both changed shared surfaces were inspected, not assumed.

**Primary harnesses.** The bridge adds one cadence state line and one repair-line clause, rendered by `bin/fm-supervision-instructions.sh` for whichever snippet the harness selects. Every supported harness renders it, including `kimi`, which maps to the `unknown` snippet:

```sh
$ for h in claude codex opencode pi pi-signed grok kimi unknown; do
    printf '%-10s %s\n' "$h" "$(bin/fm-supervision-instructions.sh --harness "$h" \
      | grep -c '^- Telegram bridge: active')"
  done
claude     1
codex      1
opencode   1
pi         1
pi-signed  1
grok       1
kimi       1
unknown    1
```

`test_cadence_instruction_reaches_every_harness` pins this, and `test_both_channels_coexist_in_one_home` pins the grok arm command sourcing both channels' cadence files when both are armed.

**Runtime backends.** Not applicable, after inspecting the integration surface rather than assuming it. The bridge adds exactly two things to shared paths, and neither reaches a backend:

- the check-sweep arm in `bin/fm-watch.sh` validates the shim's bytes and calls `run_check_capture` on a repository script - no endpoint, session, pane, or `fm_backend_*` call;
- `fm_supervision_status` in `bin/fm-supervision-lib.sh` adds one `[ -f "$state/telegram-watch.check.sh" ]` test; `grep -c fm_backend bin/fm-supervision-lib.sh` returns 0.

The bridge spawns nothing and owns no endpoint, so tmux, herdr, zellij, orca, and cmux are unaffected.

**Cross-channel.** `bin/fm-x-lib.sh` now sources the three extracted libraries instead of defining their contracts, so `bin/fm-test-run.sh` selects both the `pr-forge` and `telegram-bridge` families when any of them changes. `bin/fm-test-run.sh --family pr-forge` (which includes `tests/fm-x-mode.test.sh`, 102 checks) passes unchanged after the extraction.

## Sweep rotation is a real guard

The rotation test fails without the change it protects, so it is a regression test rather than a description.
With the rotation block in `bin/fm-watch.sh` replaced by a no-op, `test_watcher_rotates_between_always_on_channels` reports:

```
not ok - the second sweep did not rotate to the other check, so one always-on channel starves the other
```

## Not verified here

Nothing in this suite contacts Telegram.
Live end-to-end behavior - that BotFather issues a working token, that `getUpdates` long-polls as documented, and that a real device receives a message - is out-of-band operator verification done once at activation, and no such run is recorded here.
The documented delivery limitation (messages arrive only while this machine and firstmate's supervision are running, within Telegram's roughly 24-hour retention) is a property of that live service and is likewise not asserted by any test.
