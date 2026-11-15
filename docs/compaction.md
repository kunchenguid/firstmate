# Compaction

Compaction is the harness cutting a long conversation down to a bounded recent
window so the turn can continue.
It is a safety net, not a workflow.
This page owns the numbers that decide when it fires, how to read them, and why
the fleet digest - not a compaction setting - is what keeps a supervisor turn
inside its context.

## What the numbers mean

Three values decide when a turn is cut:

- `contextWindow` - the model's total context, from the model catalog
  (`~/.pi/agent/models.json`).
- `reserveTokens` - how much of that window is held back for the next turn's
  work. Compaction fires when the conversation reaches
  `contextWindow - reserveTokens`.
- `keepRecentTokens` - how much recent conversation survives the cut.

The derived number is the one that matters:

```
trigger = contextWindow - reserveTokens
```

A reserve that is too small for one unit of work means the turn is cut in the
middle of that work, and the next turn starts by redoing it.
That is the failure mode this page exists to make visible: a sweep that costs
more than `trigger` can never finish, however many times it is compacted.

## Where the values live

`~/.pi/agent/settings.json`:

```json
{
  "compaction": {
    "enabled": true,
    "reserveTokens": 64000,
    "keepRecentTokens": 20000,
    "modelOverrides": {
      "token-pool/claude-fable-5-2": { "reserveTokens": 300000, "keepRecentTokens": 60000 }
    }
  }
}
```

The top-level `reserveTokens` and `keepRecentTokens` apply to every model
without an override.
Absent top-level values mean the harness defaults, 16384 and 20000.
`modelOverrides` is keyed `provider/model`, exactly as the model catalog names
it.

## Reading the effective values

Every session start prints them, per model, immediately after the `BOOTSTRAP` section:

```
compaction: enabled=true default reserveTokens=16384 keepRecentTokens=20000 (harness defaults; /home/aaron/.pi/agent/settings.json)
  token-pool/claude-fable-5-2 reserve=300000 keepRecent=60000 context=1000000 trigger=700000
  openrouter-named/deepseek/deepseek-v4.1-flash-1017 reserve=700000 keepRecent=30000 context=1048576 trigger=348576
```

`bin/fm-session-start.sh`'s `print_compaction_effective` owns that line.
It reads the settings file and the model catalog rather than assuming either, so
a model the catalog does not list prints `trigger=unknown` instead of a guess.
`FM_PI_SETTINGS` and `FM_PI_MODELS` point it at other files.

## Why the fleet digest is the real fix

A supervisor sweep that reads every task's metadata record and status tail costs
roughly 2.9k tokens per task.
On a 260-task fleet that is about 750k tokens - more than any `trigger` above,
so the sweep is cut short on every attempt and the chair never finishes a turn.
No reserve value fixes that; the sweep itself has to get smaller.

`bin/fm-fleet-digest.sh` is that smaller sweep: one line per task, about 40
tokens each, derived from recorded metadata and the newest status line alone.
It writes `state/fleet-ledger.md`, and the post-compaction view reads that one
file instead of re-inlining every record.
`--since` prints only what changed, `--drill <id>` pays for one task's
authoritative state read, and the whole output is byte-capped.

So the order of operations is: make the sweep fit first, then tune the reserve
for the work that remains.
Tuning the reserve against a sweep that cannot fit only moves the cut.

## Related

- `bin/fm-fleet-digest.sh --help` - the digest's own contract.
- `docs/configuration.md` - the operational-home layout and configuration
  schemas.
- `bin/fm-session-start.sh --help` - the digest's sections and the
  post-compaction view's budgets.
