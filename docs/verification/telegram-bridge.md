# Telegram bridge verification

Active empirical evidence for the guarantees the private Telegram bridge claims.
Behavior, setup, and tunables are owned by [`configuration.md`](../configuration.md#telegram-bridge-env); design rationale by [`architecture.md`](../architecture.md#optional-telegram-bridge).
Re-run everything here after changing `bin/fm-tg-*`, `bin/fm-private-artifact-lib.sh`, `bin/fm-message-split-lib.sh`, `bin/fm-env-file-lib.sh`, the watcher check sweep, the PR-check migration, the arm command policy, or the Claude Stop auto-arm.
`bin/fm-test-run.sh` encodes that list, so a change to any of them selects this suite.

Recorded 2026-07-28 on macOS (Darwin 25.5.0, arm64), GNU bash 5.3.9, ShellCheck 0.11.0.

## Regression suite

```sh
bin/fm-test-run.sh --family telegram-bridge
```

46 checks pass, covering: inert-by-default, token secrecy and file modes, pairing success/expiry/replay/wrong-code/wrong-identity/re-pair/revoke, exactly-once acceptance, duplicate delivery, both crash windows, offset confirmation, the recovery sweep and its per-entry budget, the long poll's fit inside the watcher's kill budget, one budget shared across a check's calls, orphaned publication temporaries, refusal of unpaired/group/channel/bot senders, unsupported and oversized payloads, injection inertness, rate limiting, project routing, the two-step publish gate, reply escaping/splitting/retry/final cleanup, bootstrap arm and disarm, supervision eligibility, cross-channel coexistence, sweep rotation, gate-agent refusal, home isolation, and the three channel-aware shared surfaces below.

The Bot API is served by the fake local server in `tests/telegram-helpers.sh`: a stateful implementation of `getUpdates` and `sendMessage` reached through the client's real `curl --config` transport, read from the same stdin stream the client pipes.
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

`test_a_killed_poll_leaves_no_token_on_disk` covers the path the watcher actually takes: the fake server holds the long poll open, the poll is `SIGKILL`ed mid-call, and no cleanup can run.
It asserts both halves too - the fake server's `token-seen.log` shows the killed call really carried the token, the kill really did strand temporaries in `TMPDIR`, and none of those temporaries contains the token.

## Exactly-once delivery across crashes

Each case rewinds the confirmed offset the way a real crash would, then re-queues the same update in the fake server, which honors Telegram's real "confirming an offset deletes everything below it" contract.

| Crash point | Expected | Test |
| --- | --- | --- |
| after the offset was confirmed | redelivery impossible; a second poll is silent | `test_paired_text_is_accepted_exactly_once` |
| after the wake, before the offset write | redelivery dropped, entry unchanged | `test_duplicate_delivery_never_duplicates_work` |
| after the inbox claim, before the seen marker | redelivered once, no duplicate entry | `test_crash_before_seen_claim_still_delivers_once` |
| after the agent drained the entry | never resurrected | `test_drained_message_is_never_resurrected` |
| after the seen marker, before the wake | re-announced by the bounded sweep | `test_pending_message_is_re_announced_after_a_lost_wake` |
| the agent can never drain the entry | re-announced a bounded number of times, reported once, kept | `test_re_announcement_budget_retires_a_stuck_entry` |

## The poll fits the budget it runs under

The watcher runs the poll as one `*.check.sh` under `timeout $FM_CHECK_TIMEOUT` and a killed check produces no output at all, which the sweep cannot tell from "nothing to report" - so a long poll that outran the budget would stop delivering messages silently.
`test_long_poll_stays_inside_the_watcher_kill_budget` asserts the deadlines the client actually sent, read back from the fake server: at the documented-valid `FM_TELEGRAM_POLL_TIMEOUT=45` under the default 30-second budget, the `curl` deadline is inside the budget and the long poll ends before that deadline; at `FM_CHECK_TIMEOUT=60` the configured 45-second poll is restored, so the ceiling follows the budget rather than replacing it.

The budget is per check, and one check can issue two calls - the long poll, then the pairing confirmation for a code redeemed inside it.
`test_one_check_spends_one_budget_across_its_calls` holds the fake server's `getUpdates` open for two seconds and asserts the confirmation's deadline is at least that much shorter than the poll's, and still long enough to succeed - so the second call provably spends what the first left rather than starting a fresh full-length request the watcher would kill.

## Silence to unpaired chats

`test_wrong_code_is_silent_and_bounded`, `test_expired_code_does_not_pair`, and `test_non_private_and_bot_senders_get_no_access` assert the delivered-message count stays at the single pairing confirmation across wrong codes, expired codes, group/supergroup/channel messages, bot senders, and unpaired private users.
`test_reply_without_a_peer_sends_nothing` asserts `sendMessage` never runs at all before a pairing exists.

## Compatibility axes

Both changed shared surfaces were inspected, not assumed.

**Primary harnesses.** The bridge adds one cadence state line and one repair-line clause, rendered by `bin/fm-supervision-instructions.sh` for whichever snippet the harness selects. Every supported harness renders it, including `kimi`, which maps to the `unknown` snippet:

```sh
$ for h in claude codex opencode pi pi-signed grok kimi unknown; do
    printf '%-10s %s\n' "$h" "$(bin/fm-supervision-instructions.sh --harness "$h" --telegram 1 \
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

**Other channel-aware shared surfaces.** An earlier revision of this record claimed the compatibility axes had been inspected while only the supervision renderer and the supervision-eligibility predicate actually had been.
Three further surfaces hard-code X mode's artifact name and were missed; all three are now fixed and pinned by a test that fails without its fix:

| Surface | What it did to a bridged home | Regression |
| --- | --- | --- |
| `bin/fm-pr-check-migrate.sh` | quarantined the valid bridge shim, disarming the bridge on every watcher start | `test_migration_does_not_quarantine_the_bridge_shim` |
| `bin/fm-arm-command-policy.mjs` | denied the arm command the supervision renderer itself emits | `test_arm_seatbelt_allows_the_rendered_bridge_arm` |
| `bin/fm-claude-stop-autoarm.sh` | armed at the 300s default instead of 30s on the default harness | `test_stop_autoarm_inherits_the_bridge_cadence` |

The migration exemption now has one owner (`channel_shim_exempt`) covering all four scan sites, rather than four copies of a single-channel condition - which is how the bridge came to be exempt in none of them.
The two remaining X-only paths there, `x_shim_locked_scan_needed` and `refresh_v1_x_shim`, are correctly X-only: they migrate a legacy mode-0755 v1 shim, and the bridge shim has no v1 legacy.
Each regression was verified to fail with only its own fix reverted, so none of them passes vacuously.

**Runtime backends.** Not applicable, after inspecting the integration surface rather than assuming it. The bridge adds exactly two things to shared paths, and neither reaches a backend:

- the check-sweep arm in `bin/fm-watch.sh` validates the shim's bytes and calls `run_check_capture` on a repository script - no endpoint, session, pane, or `fm_backend_*` call;
- `fm_supervision_status` in `bin/fm-supervision-lib.sh` adds one `[ -f "$state/telegram-watch.check.sh" ]` test; `grep -c fm_backend bin/fm-supervision-lib.sh` returns 0.

The bridge spawns nothing and owns no endpoint, so tmux, herdr, zellij, orca, and cmux are unaffected.

**Cross-channel.** `bin/fm-x-lib.sh` now sources the three extracted libraries instead of defining their contracts, so `bin/fm-test-run.sh` selects both the `pr-forge` and `telegram-bridge` families when any of them changes. `bin/fm-test-run.sh --family pr-forge` (which includes `tests/fm-x-mode.test.sh`, 102 checks) passes unchanged after the extraction.

## Only firstmate reaches the channel

`bin/fm-tg-reply.sh`, `bin/fm-tg-pair.sh`, and `bin/fm-tg-task.sh` call `fm_refuse_if_gate_agent` before anything else.
A no-mistakes gate agent runs inside a firstmate checkout and auto-loads `AGENTS.md`, so it can read that this channel exists; the same capability-removal guard the fleet entrypoints use keeps it away from a channel that reaches someone outside the fleet.

```sh
$ NO_MISTAKES_GATE=1 bin/fm-tg-reply.sh x --text-file /dev/null; echo "exit=$?"
error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)
exit=3
```

`test_gate_agent_cannot_reach_the_channel` asserts the refusal for messaging, revoking, and arming a publish, and that no message was delivered.

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
