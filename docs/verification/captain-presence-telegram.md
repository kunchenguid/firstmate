# Captain-presence Telegram routing: live verification

Maintainer-verification record for the HOME/AWAY routing contract owned by [`bin/fm-hermes-notify.sh`](../../bin/fm-hermes-notify.sh).
Refresh this record after changing the presence record, outbound eligibility, inbound command classification, hold correlation, or notification deduplication.

## 2026-09-18

The live run used Hermes Agent v0.21.0 and the branch implementation against the configured Telegram gateway.
The configured private chat identifier is intentionally elided below.

```text
$ bin/fm-hermes-notify.sh presence away
Captain presence is now AWAY.

$ bin/fm-hermes-notify.sh register live-presence-hold --reason-file live-hold-message.txt --label 'Captain presence live test'
sent: live-presence-hold -> telegram:<configured-chat-id>

# Telegram replied: PRESENCE-CORRELATION-20260918
$ bin/fm-hermes-notify.sh inbound state/inbox/<telegram-note>.note
answer:live-presence-hold PRESENCE-CORRELATION-20260918 Captain presence live test

$ printf '<the returned TSV>' | bin/fm-captain-hold.sh answers --source hermes-telegram
$ tasks-axi show live-presence-hold --full
state: done
held: no
hold_kind: captain
Answer: PRESENCE-CORRELATION-20260918

# Telegram then requested: status report
$ bin/fm-hermes-notify.sh inbound state/inbox/<telegram-status-note>.note
request:status status report

$ bin/fm-hermes-notify.sh route status --message-file live-status-message.txt --key live-status-20260918
sent: status/live-status-20260918 -> telegram:<configured-chat-id>

$ bin/fm-hermes-notify.sh presence home
Captain presence is now HOME.

$ bin/fm-hermes-notify.sh route blocker --message-file live-quiet-probe.txt --key live-home-quiet-20260918
skipped: Captain presence is HOME

$ bin/fm-hermes-notify.sh presence status
HOME
```

The mode change did not alter the synthetic hold.
Only the ordinary `answers --source hermes-telegram` intake resolved it after the correlated Telegram reply.
The final HOME probe produced no Hermes send.

The focused executable regression was also run through the repository runner.

```text
$ bin/fm-test-run.sh tests/fm-hermes-notify.test.sh
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0
```
