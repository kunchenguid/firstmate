# Session keepalive

External revival of a PRIMARY firstmate session whose own turn died while fleet work was still in flight.
This page is the contract owner: the detection evidence, the injected input, the backoff and cap, the away-mode division of duty, and the authority boundary.
`bin/fm-keepalive.sh`'s header and `--help` own the exact flags, state-file names, and mechanics.

## The gap it closes

When a crewmate dies, the primary notices and relaunches it.
When the primary's own turn dies - a fatal API overload after the harness's internal retries, or any other hard stop - nothing inside that session can start another turn.
In-flight work then sits frozen until a human types something, which overnight can mean hours.

The keepalive is a small loop outside the session that watches durable records and, on proof that the session is alive but idle with lapsed supervision, injects one typed input so the primary resumes supervision itself.
It never classifies why a turn died and never changes the harness's own retry behavior.

## Opt in

The mechanism ships inert.
Put `on` in the local, gitignored `config/keepalive` file under the effective firstmate home to enable it; an absent file, an empty file, or `off` keeps it off.
An unrecognized value is never treated as `on`: session start reports a `KEEPALIVE:` diagnostic so the typo gets fixed, and revival stays off until it does.
See [configuration.md](configuration.md#session-keepalive-configkeepalive) for the file and every environment knob.

Once opted in, the locked session-start bootstrap sweep arms the loop from the primary's own pane, so the endpoint it captures is the primary session's.
Arming is idempotent: an already-running loop is left alone, and a recorded-but-dead terminal from a crash is closed by its exact id first.
Removing the opt-in value makes the running loop stand down cleanly on its next tick.

## Detection evidence

Revival happens only when every one of these holds.
A false revival is worse than none - it interrupts a live turn and can duplicate actions - so each condition is proven from a durable record or a real endpoint read, never from elapsed time alone.

| Evidence | Requirement for revival |
| --- | --- |
| `state/*.meta` | At least one task is in flight. No work means nothing to revive, and the loop stays silent. |
| `state/.afk` | Absent. Away mode owns injection into the primary pane, so away mode also owns revival. |
| `state/.lock` | Present and its recorded harness process is still alive. A live harness with a dead turn is revivable; a dead holder means the whole session is gone and typing cannot revive it. |
| `state/.last-watcher-beat` | Missing or older than the stale-beacon threshold. A healthy primary re-arms supervision every turn, so a stale beacon with work in flight is the lapse signal. |
| The primary's busy footer | Absent. A long-thinking turn or a foreground tool call reads as busy and is never revived. |
| The primary's composer | Affirmatively empty. Half-typed human input reads as pending and a bare shell prompt reads as unknown; both defer, so nothing is ever typed over a person's input or into a dead shell. |
| `state/.keepalive-suspect` | The lapse has held continuously through the confirm window. A momentary between-turns gap cannot trigger a revival. |

Any condition that breaks resets the continuous-lapse window, while the durable attempt count survives, so a session that is revived and then dies again keeps growing its backoff instead of restarting it.

The verdict for one pass is printable without changing anything: `bin/fm-keepalive.sh evaluate` prints `<verdict>|<detail>`, and `bin/fm-keepalive.sh status` adds loop liveness, the opt-in value, and attempt state.
The verdicts are `off`, `no-session`, `idle`, `afk`, `healthy`, `agent-gone`, `endpoint-gone`, `busy`, `unsafe`, `confirming`, `backoff`, `exhausted`, `revived`, and `revive-failed`.

## The injected input

The revival input is constructed through the shared operational-input protocol (`bin/fm-operational-input.sh`) as the typed `session-revive` kind, so the primary recognizes it structurally as internal rather than as a captain message, exactly like an away-mode escalation.
Its body states what happened, tells the primary to resume supervision - drain queued wakes, reconcile in-flight work from durable records, re-arm the supervision cycle - and explicitly tells it not to start new work or repeat work a record already shows as finished.

Injection uses the same submit primitive as the away-mode daemon: type once, then retry only Enter.
An unconfirmed submit leaves the text in the composer, which the next pass reads as a non-empty composer and defers on, so two revival inputs can never be concatenated into one corrupted turn.

## Backoff, cap, and giving up

An overloaded API rejects an immediate retry too, so revival attempts are spaced exponentially: the first attempt fires as soon as the confirm window closes, and attempt N+1 waits `FM_KEEPALIVE_BACKOFF_BASE * 2^(N-1)` seconds, capped at the `FM_KEEPALIVE_BACKOFF_MAX` ceiling.
With the defaults that is 60s, 120s, 240s, 480s, then the 900s ceiling.
There is never a tight retry loop: the loop's own poll interval bounds how often it even looks.

After `FM_KEEPALIVE_MAX_ATTEMPTS` attempts (default 5) the loop stops injecting and writes `state/.keepalive-exhausted` with the evidence.
`bin/fm-guard.sh` surfaces that report on every guarded command until it is read and removed, so the gap becomes visible on the very next fleet action rather than staying silent.
The same report is written when the session lock's harness process is confirmed gone for the length of the confirm window, because input cannot revive a session that no longer exists; the loop then stands down instead of watching a closed session forever, and so does a primary endpoint that stays absent past `FM_KEEPALIVE_GONE_EXIT_SECS`.
A single unreadable process or endpoint check is never enough for either: both need the same continuous confirmation a lapse does.
Nothing is discarded in either case: queued wakes, task metadata, status events, and crew work all survive, and a session that recovers on its own clears the episode and logs the recovery.

## Away mode owns its own revival

Two injectors competing for one composer would corrupt a turn, so the duty is split by mode and never shared.

- Away mode on (`state/.afk` present): the sub-supervisor daemon owns the primary pane.
  It already injects batched escalations into an idle-empty composer, which starts a turn, and its wedge alarm owns the active out-of-band alert when delivery cannot be confirmed.
  The keepalive loop reports the `afk` verdict and injects nothing.
- Away mode off: the keepalive loop owns revival, and its exhaustion report is what surfaces the failure to the next turn.

Entering or leaving away mode needs no keepalive action; the flag alone moves the duty.

## Authority

A revived turn inherits exactly the standing authority it already had.
Revival is not approval for anything: merges, ask-user findings, and destructive, irreversible, or security-sensitive choices keep the same captain boundaries they had before the turn died, and the injected body says so in the input itself.
Away mode does not expand that authority either, and neither does an exhausted revival.

## Supported endpoints

Revival needs verified composer, busy, and submit primitives for the primary's own pane, so it supports the same supervisor backends as away-mode injection: `tmux` and `herdr`.
Any other supervisor backend refuses loudly at startup instead of running tmux primitives against a pane that is not a tmux pane.
`FM_SUPERVISOR_TARGET` and `FM_SUPERVISOR_BACKEND` override the discovered primary pane, resolved by the same owner the away-mode daemon uses.

Active empirical evidence for this mechanism is in [verification/supervision.md](verification/supervision.md#session-keepalive-revival).
