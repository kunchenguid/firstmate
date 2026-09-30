Mode: Codex Stop-owned auto-arm (bin/fm-codex-stop-autoarm.sh).

The tracked `.codex/hooks.json` Stop registration carries this auto-arm as an
async hook, so watcher continuity is hook-owned like Claude's: every turn end
arms or attaches exactly one watcher cycle without a model command, and an
actionable close is delivered as a queued `codex queue` user turn whose body
is the U+2063 `FIRSTMATE_OP: v1 watcher:` envelope. That queued message is
Firstmate's, not the captain's; handle it operationally. The synchronous
`fm-turnend-guard.sh --codex` hook reads the same epoch ledger, so an arming
or freshly woken cycle ends its turn without a duplicate continuation.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Ordinary wake (a queued `watcher:` envelope, or any signal/stale/check/heartbeat you can see): drain, handle the wake, and do nothing to arm a cycle - the Stop-owned auto-arm (bin/fm-codex-stop-autoarm.sh) already owns watcher continuity, and the next needed cycle arms when this handling turn ends.
4. First cycle after session start, or failure/missing cycle only: drain queued wakes, inspect the failure, then run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`. If it prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible, and let the turn end; the auto-arm re-arms at the Stop.
5. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
6. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.

Codex cannot reason while a foreground tool call is running, which is why the
checkpoint in step 4 is bounded. Between turns the watcher runs in the auto-
arm's background process tree, so ordinary captain chat needs no checkpoint at
all; the guard only speaks up when a genuinely failed cycle leaves the home
uncovered, and its bounded block plus one attended fail-open replace the old
per-turn nag.
