# Automatic context refresh

Firstmate can replace a long-running Claude primary conversation before context growth degrades its reasoning.
The refresh is a deliberate durable handoff, not compaction and not restoration of the old conversation.
[`configuration.md`](configuration.md#context-restart-budget-configcontext-restart-budget) owns the threshold setting and exact validation rules.

## Turn-boundary detection

`.claude/settings.json` registers `bin/fm-context-restart-claude-hook.sh` as a synchronous Claude `Stop` hook with a 15-second host bound.
Claude supplies a trusted payload containing the session id and transcript path after an assistant turn has completed.
The hook streams the transcript to find the latest assistant usage, computes the current context total defined in the configuration guide, and compares it with the validated budget.
It never checks during a model turn, tool call, or captain input.

Below threshold the hook prints nothing, exits successfully, writes no ordinary crossing state, and spends no model tokens.
Malformed hook payload, transcript JSON, latest usage, or configuration cannot trigger a restart.
Malformed configuration is reported separately by locked session-start bootstrap rather than guessed at inside a Stop hook.

The first observation at or above threshold atomically publishes one home-local crossing record, then returns one typed `context-refresh` operational directive through Claude's normal Stop feedback continuation.
Later Stop firings for the same crossing see that record and stay silent.
If the context later falls below threshold before handoff, the detector rearms, so a later rise is a new crossing and can produce one new directive.

## Durable handoff

The directive tells the running Firstmate to invoke the internal `/stow` skill before doing new work.
That pass captures durable knowledge, corrects the open work records held in conversation, enforces startup-memory budgets, and cascades to registered secondmates under the skill's existing contract.
The session proceeds to exit only when the receipt says it is reset-safe.
If stow exposes an unresolved exception or captain decision, the old session remains available and the durable crossing remains retryable.

After a reset-safe receipt, Firstmate runs the exact `bin/fm-context-restart.sh handoff --session <id> --reset-safe` command carried by the directive.
The command verifies that the caller still owns the home session lock and that the durable crossing belongs to the current Claude session.
It advances the crossing to a reset-safe ready sentinel before asking the current Claude process to terminate.
Repeating the command against the same session and wrapper generation is idempotent.

## Automatic successor

`bin/fm-primary.sh` is the selected automatic successor owner.
It remains as the terminal parent while Claude runs, gives each child generation a private token, and forwards the chosen Claude options.
It restarts only when the exited child left a reset-safe ready sentinel carrying that exact token, so an ordinary exit or crash never becomes a relaunch loop.

After the old Claude process has exited, the wrapper serializes against ordinary session-lock acquisition and removes only the lock that still names that exact dead harness owner.
It retires the completed crossing and starts a new Claude conversation in the same terminal.
The new SessionStart hook acquires the now-free lock and runs the full session-start digest without receiving or restoring the old transcript.
The wrapper then supplies one typed resume turn stating that this digest is authoritative, so the fresh process reconciles durable work and resumes what remains under way.
An initial secondmate launch instruction is deliberately delivered only to the first child and is not replayed after refresh.

Launch the main Claude primary with:

```sh
bin/fm-primary.sh
```

Claude secondmates launched through `bin/fm-spawn.sh` use the same wrapper automatically.

## Why the other successor shapes are not primary

A Stop-hook-driven relaunch was rejected because the hook is a child of the session being replaced and does not own the interactive terminal after that session exits.
Starting a successor from that hook would either overlap the live lock owner or require a detached terminal-specific process, and it would compete with the existing asynchronous watcher hook.

A plain `claude` launch remains the manual fallback.
Threshold detection and stow preparation still work, but the handoff command cannot prove a relaunch parent exists, so it preserves the ready sentinel and tells the operator to exit Claude and relaunch with `bin/fm-primary.sh`.
A fresh manual launch still resumes safely from the ordinary session-start digest, though the operator must send the first turn.

## Interruption and supervision safety

The crossing is durable before the one directive is emitted, and the ready sentinel is durable before termination is requested.
An interruption before stow leaves the existing fleet records authoritative and leaves the crossing available for inspection or retry in the old session.
An interruption during stow leaves that skill's owner-specific writes re-runnable.
An interruption after ready publication leaves a reset-safe manual launch path even if the wrapper itself disappears before starting the successor.

The context hook does not arm, stop, restart, or wait on the fleet watcher.
Claude's existing asynchronous watcher auto-arm and synchronous turn-end guard continue to run on the same Stop event under their existing single-flight and bounded-continuation rules.
The handoff command never acknowledges or removes queued notifications.
The successor's session-start digest therefore presents the same durable queue and open decisions that any ordinary restart would present.

## Other primary harnesses

No other primary harness currently exposes a verified combination of turn-boundary transcript usage and automatic same-terminal replacement.
The context budget remains inert for Codex, OpenCode, Pi, pi-signed, Grok, Kimi, and Cursor primaries.
Adding an adapter later requires a verified turn-boundary context measurement, one-directive crossing deduplication, reset-safe stow handoff, clean session-lock transfer, and an owned successor transport.

## Verification

`tests/fm-context-restart.test.sh` covers exact threshold accounting, malformed transcript and usage rejection, concurrent one-directive publication, and wrapper lock transfer over portable real processes.
`FM_CONTEXT_RESTART_CLAUDE_LIVE_E2E=1 tests/fm-context-restart-claude-live-e2e.test.sh` verifies the installed Claude Stop payload and transcript usage end to end while a high threshold keeps the live turn inert.
[`verification/supervision.md`](verification/supervision.md#claude-context-refresh) records the current versioned live result.
