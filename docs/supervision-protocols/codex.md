Mode: Codex daemon-backed normal supervision.

Run `bin/fm-codex-supervise-start.sh` in its own tracked terminal session.
It starts the existing singleton supervisor daemon in explicit `normal-codex` mode, which owns the watcher, re-arms it, and injects captain-relevant escalations only into a confirmed-idle Codex composer.
Do not run a foreground checkpoint while this daemon owns supervision.
The daemon preserves queued wakes, the watcher liveness beacon, and its existing busy/composer guards, so it never merges an escalation into typed input.
Do not use shell `&`, `nohup`, or a Codex background task to launch it.
Away mode remains the same daemon under `/afk`.
The `/afk` skill owns the durable `afk` <-> `normal-codex` ownership-transfer and return contract.

Validation on 2026-07-11 used Codex CLI 0.144.1 in a disposable tmux server with a scratch `FM_HOME` and no `state/.afk` flag.
The supervisor was started with `FM_HOME=<scratch> FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=codex-normal:0 bin/fm-codex-supervise-start.sh`.
After `printf 'done: normal daemon wake smoke\n' > <scratch>/state/smoke.status`, the idle Codex primary received `Supervisor escalate (1 event(s)): smoke.status: done: normal daemon wake smoke (pre-read; re-arm not needed - watcher daemon-managed)` and replied `Acknowledged: normal daemon wake smoke completed; no re-arm needed.`
The daemon lock and watcher liveness beacon existed before that status write, and no primary input was sent after it.

The Herdr path was also validated on 2026-07-11 with Herdr 0.7.3 and Codex CLI 0.144.1 in the guarded lab session `fm-lab-codex-supervise-d4-9256-1249`.
A disposable Codex primary ran in pane `w1:p1` and the normal supervisor daemon ran in pane `w1:p2`; both inherited the same scratch `FM_HOME`.
The daemon target was `fm-lab-codex-supervise-d4-9256-1249:w1:p1`, with `FM_SUPERVISOR_BACKEND=herdr`.
After the primary was visibly idle, an external process wrote `done: real Herdr callback smoke` to `state/smoke.status`; no text, key, foreground checkpoint, or manual wake was sent to the Codex pane afterward.
Codex opened a new turn containing `Supervisor escalate (1 event(s)): smoke.status: done: real Herdr callback smoke (pre-read; re-arm not needed — watcher daemon-managed)`.
Daemon PID `42472` remained live, the watcher beacon advanced from epoch `1783789593` to `1783789628`, and the injected turn's session-start drain left `state/.wake-queue` at zero bytes, with no duplicate wake remaining.
The lab used one-second poll, signal-grace, batch, and housekeeping cadences to shorten the smoke; ownership, idle/composer guards, submit confirmation, queue drain, and watcher re-arm paths were unchanged.

The legacy checkpoint remains a bounded diagnostic and recovery tool only.
It drains an already-durable queue before taking a watcher lock and forces one heartbeat reconciliation for a terminal status missed in an earlier gap.
It cannot provide continuous normal supervision because Codex does not reopen a fully ended session for a later filesystem write.
Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
The PreToolUse seatbelt in `.codex/hooks.json` denies a backgrounded, piped, or bundled watcher command.
